import Foundation
import QuartzCore
import Combine
import PlaybackKit

public enum ShuttleStepResult: Equatable, Sendable {
    case active(gear: Int)
    case exitedToNormalPlayback(commitTime: TimeInterval)
}

/// 仿 AuraTV 最新版闭环测速同步快进/快退控制器（适配 CineDeckTV Liquid Glass 悬浮胶囊）：
/// - 60Hz 闭环时钟 + 无死上限动态前瞻窗口 (`max(0.8, speed * 0.45)`)，兼顾低速丝滑与高速 60x~240x 穿透力
/// - 根据最近 0.65s 真实画面时间戳计算 `actualVisualSpeed`，显示倍速与胶囊进度条始终与画面真实推进锁步
/// - 支持：短按定长连点跳秒 / 多级倍速穿梭 (`2x~128x`) / 长按非线性平滑加速 / Siri Remote 触控板划屏
@MainActor
public final class MXScrubController: ObservableObject {
    public enum Direction: Equatable, Sendable { case forward, backward }

    public enum Mode: Equatable, Sendable {
        case idle
        case shortStep(Direction)
        case shuttle(gear: Int)
        case hold(Direction)
        case touchpad
    }

    public typealias PreviewSeekHandler = @MainActor (TimeInterval) async -> TimeInterval

    public static let shuttleSpeedTable: [Int] = [0, 2, 4, 8, 16, 32, 64, 128]

    @Published public private(set) var isScrubbing: Bool = false
    @Published public private(set) var isShowingBar: Bool = false
    @Published public private(set) var activeMode: Mode = .idle
    @Published public private(set) var targetTime: TimeInterval = 0
    @Published public private(set) var displayedFrameTime: TimeInterval = 0
    @Published public private(set) var actualVisualSpeed: Double = 0
    @Published public private(set) var requestedSpeed: Double = 0

    private var anchorTime: TimeInterval = 0
    private var currentDuration: TimeInterval = 0
    private var activeProfile: ScrubProfile = .standard
    private var pressStartWallTime: CFTimeInterval = 0
    private var lastFrameWallTime: CFTimeInterval = 0
    private var currentDirectionSign: Double = 1.0
    private var hasRenderedFrameInSession: Bool = false
    private var speedSamples: [(wall: CFTimeInterval, media: TimeInterval)] = []

    private var tickTask: Task<Void, Never>?
    private var decodeLoopTask: Task<Void, Never>?
    private var shortCommitTask: Task<Void, Never>?
    private var barHideTask: Task<Void, Never>?
    private var pendingPreviewTarget: TimeInterval?
    private var lastDecodedRequestTarget: TimeInterval = -.infinity
    private var sessionEpoch: UInt64 = 0

    private let tickIntervalNs: UInt64 = 16_666_667 // ~60 Hz

    public init() {}

    public var isShuttleActive: Bool {
        if case .shuttle = activeMode { return true }
        return false
    }

    public var synchronizedDisplayTime: TimeInterval {
        if case .shortStep = activeMode {
            return targetTime
        }
        return hasRenderedFrameInSession ? displayedFrameTime : targetTime
    }

    public var synchronizedDeltaSeconds: TimeInterval {
        synchronizedDisplayTime - anchorTime
    }

    public var speedLabel: String {
        switch activeMode {
        case .idle:
            return ""
        case .shortStep(let dir):
            return dir == .forward ? ">>>" : "<<<"
        case .shuttle(let gear):
            let synced = synchronizedDisplaySpeed(requested: requestedSpeed)
            return gear >= 0 ? ">>> \(synced)x" : "<<< -\(synced)x"
        case .hold(let dir):
            let synced = synchronizedDisplaySpeed(requested: requestedSpeed)
            return dir == .forward ? ">>> \(synced)x" : "<<< -\(synced)x"
        case .touchpad:
            return synchronizedDeltaSeconds >= 0 ? ">>>" : "<<<"
        }
    }

    private func synchronizedDisplaySpeed(requested: Double) -> Int {
        let req = max(1.0, requested)
        if actualVisualSpeed < 0.5 {
            return max(1, Int(req.rounded()))
        }
        if abs(actualVisualSpeed - req) / req <= 0.18 {
            return max(1, Int(req.rounded()))
        }
        return max(1, Int(actualVisualSpeed.rounded()))
    }

    // MARK: - Mode 0: 短按连点定长跳秒

    public func triggerShortStep(
        direction: Direction,
        stepSeconds: Double,
        currentTime: TimeInterval,
        duration: TimeInterval,
        onPreviewFrame: @escaping PreviewSeekHandler,
        onCommit: @escaping @MainActor (TimeInterval) async -> Void
    ) {
        barHideTask?.cancel()
        shortCommitTask?.cancel()
        tickTask?.cancel()
        tickTask = nil

        let continuingSameShortStep: Bool
        if case .shortStep = activeMode, isScrubbing {
            continuingSameShortStep = true
        } else {
            continuingSameShortStep = false
        }

        if !continuingSameShortStep {
            beginSession(anchor: currentTime, duration: duration)
        } else {
            currentDuration = duration
        }

        let dirSign = direction == .forward ? 1.0 : -1.0
        let step = max(5.0, stepSeconds) * dirSign
        targetTime = clampTime(targetTime + step, duration: duration)
        displayedFrameTime = targetTime
        activeMode = .shortStep(direction)
        isShowingBar = true
        requestedSpeed = 8.0
        currentDirectionSign = dirSign
        pendingPreviewTarget = targetTime

        startDecodeLoopIfNeeded(onPreviewFrame: onPreviewFrame)

        shortCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard let self, !Task.isCancelled else { return }
            if case .shortStep = self.activeMode {
                self.commit(keepBarBriefly: true, onCommit: onCommit)
            }
        }
    }

    // MARK: - Mode 1: 多级倍速穿梭 (2x -> 4x -> 8x -> 16x -> 32x -> 64x -> 128x)

    @discardableResult
    public func stepShuttle(
        direction: Direction,
        currentTime: TimeInterval,
        duration: TimeInterval,
        onPreviewFrame: @escaping PreviewSeekHandler
    ) -> ShuttleStepResult {
        barHideTask?.cancel()
        shortCommitTask?.cancel()

        let currentGear: Int
        if case .shuttle(let g) = activeMode {
            currentGear = g
        } else {
            currentGear = 0
        }

        let maxGear = Self.shuttleSpeedTable.count - 1
        let step = direction == .forward ? 1 : -1
        let nextGear = max(-maxGear, min(maxGear, currentGear + step))
        if nextGear == 0 {
            return .exitedToNormalPlayback(commitTime: synchronizedDisplayTime)
        }

        if !isScrubbing {
            beginSession(anchor: currentTime, duration: duration)
            let initStep = 0.25 * Double(step)
            targetTime = clampTime(targetTime + initStep, duration: duration)
            pendingPreviewTarget = targetTime
        } else {
            currentDuration = duration
        }

        let absG = min(max(abs(nextGear), 1), maxGear)
        let speed = Double(Self.shuttleSpeedTable[absG])
        currentDirectionSign = nextGear >= 0 ? 1.0 : -1.0
        requestedSpeed = speed
        activeMode = .shuttle(gear: nextGear)
        isShowingBar = true

        startShuttleTickLoop(speed: speed, dirSign: currentDirectionSign)
        startDecodeLoopIfNeeded(onPreviewFrame: onPreviewFrame)
        return .active(gear: nextGear)
    }

    // MARK: - Mode 2: 长按闭环同步快进 / 快退

    public func beginHold(
        direction: Direction,
        currentTime: TimeInterval,
        duration: TimeInterval,
        profile: ScrubProfile,
        onPreviewFrame: @escaping PreviewSeekHandler
    ) {
        barHideTask?.cancel()
        shortCommitTask?.cancel()

        if !isScrubbing {
            beginSession(anchor: currentTime, duration: duration)
        } else {
            currentDuration = duration
        }

        activeProfile = profile
        activeMode = .hold(direction)
        isShowingBar = true
        currentDirectionSign = direction == .forward ? 1.0 : -1.0
        pressStartWallTime = CACurrentMediaTime()
        requestedSpeed = profile.initialRate
        pendingPreviewTarget = targetTime

        let math = ScrubMath(profile: profile, duration: max(duration, 1))
        let tickDelay = tickIntervalNs

        tickTask?.cancel()
        tickTask = Task { [weak self] in
            guard let self else { return }
            var lastWall = CACurrentMediaTime()
            try? await Task.sleep(nanoseconds: tickDelay)
            while !Task.isCancelled && self.isScrubbing {
                let now = CACurrentMediaTime()
                let dt = min(0.05, max(0.004, now - lastWall))
                lastWall = now
                let elapsed = max(0, now - self.pressStartWallTime)
                let rawRate = math.rate(after: elapsed)
                let speed = rawRate > 0 ? rawRate : profile.initialRate
                self.advanceClock(speed: speed, dt: dt, dirSign: self.currentDirectionSign)
                try? await Task.sleep(nanoseconds: tickDelay)
            }
        }

        startDecodeLoopIfNeeded(onPreviewFrame: onPreviewFrame)
    }

    public func commitHold(onCommit: @escaping @MainActor (TimeInterval) async -> Void) {
        guard isScrubbing else { return }
        commit(keepBarBriefly: false, onCommit: onCommit)
    }

    // MARK: - Mode 3: Siri Remote 触控板划屏

    public func beginTouchpadPan(
        currentTime: TimeInterval,
        duration: TimeInterval,
        onPreviewFrame: @escaping PreviewSeekHandler
    ) {
        barHideTask?.cancel()
        shortCommitTask?.cancel()
        tickTask?.cancel()
        tickTask = nil

        if !isScrubbing {
            beginSession(anchor: currentTime, duration: duration)
        } else {
            currentDuration = duration
        }
        activeMode = .touchpad
        isShowingBar = true
        requestedSpeed = 8.0
        pendingPreviewTarget = targetTime
        startDecodeLoopIfNeeded(onPreviewFrame: onPreviewFrame)
    }

    public func updateTouchpadPan(deltaFromOrigin: Double) {
        guard isScrubbing, activeMode == .touchpad else { return }
        let next = clampTime(anchorTime + deltaFromOrigin, duration: currentDuration)
        currentDirectionSign = next >= targetTime ? 1.0 : -1.0
        targetTime = next
        pendingPreviewTarget = next
    }

    public func commitTouchpadPan(onCommit: @escaping @MainActor (TimeInterval) async -> Void) {
        guard isScrubbing else { return }
        commit(keepBarBriefly: false, onCommit: onCommit)
    }

    // MARK: - 提交与取消

    public func commit(
        keepBarBriefly: Bool = false,
        onCommit: @escaping @MainActor (TimeInterval) async -> Void
    ) {
        let finalTarget = synchronizedDisplayTime
        stopLoopsOnly()
        isScrubbing = false
        if !keepBarBriefly {
            isShowingBar = false
            activeMode = .idle
        }
        sessionEpoch &+= 1
        let epoch = sessionEpoch

        Task { @MainActor [weak self] in
            await onCommit(finalTarget)
            guard let self, self.sessionEpoch == epoch, !self.isScrubbing else { return }
            if keepBarBriefly {
                self.barHideTask?.cancel()
                self.barHideTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    guard let self, !Task.isCancelled, !self.isScrubbing else { return }
                    self.isShowingBar = false
                    self.activeMode = .idle
                }
            }
        }
    }

    public func cancelAll() {
        stopLoopsOnly()
        barHideTask?.cancel()
        barHideTask = nil
        sessionEpoch &+= 1
        isScrubbing = false
        isShowingBar = false
        activeMode = .idle
        actualVisualSpeed = 0
        requestedSpeed = 0
        hasRenderedFrameInSession = false
        speedSamples.removeAll(keepingCapacity: true)
    }

    // MARK: - 内部闭环时钟与单飞预览循环

    private func beginSession(anchor: TimeInterval, duration: TimeInterval) {
        sessionEpoch &+= 1
        barHideTask?.cancel()
        isScrubbing = true
        anchorTime = max(0, anchor)
        targetTime = anchorTime
        displayedFrameTime = anchorTime
        currentDuration = max(0, duration)
        lastDecodedRequestTarget = -.infinity
        actualVisualSpeed = 0
        requestedSpeed = 0
        hasRenderedFrameInSession = false
        speedSamples.removeAll(keepingCapacity: true)
        lastFrameWallTime = CACurrentMediaTime()
    }

    private func startShuttleTickLoop(speed: Double, dirSign: Double) {
        let tickDelay = tickIntervalNs
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            guard let self else { return }
            var lastWall = CACurrentMediaTime()
            while !Task.isCancelled && self.isScrubbing {
                try? await Task.sleep(nanoseconds: tickDelay)
                guard !Task.isCancelled && self.isScrubbing else { break }
                let now = CACurrentMediaTime()
                let dt = min(0.05, max(0.004, now - lastWall))
                lastWall = now
                self.advanceClock(speed: speed, dt: dt, dirSign: dirSign)
            }
        }
    }

    private func advanceClock(speed: Double, dt: Double, dirSign: Double) {
        requestedSpeed = speed
        var desired = clampTime(targetTime + speed * dt * dirSign, duration: currentDuration)

        if hasRenderedFrameInSession {
            let maxLead = max(0.8, speed * 0.45)
            if dirSign > 0 {
                if desired > displayedFrameTime + maxLead {
                    desired = max(targetTime, displayedFrameTime + maxLead)
                }
            } else {
                if desired < displayedFrameTime - maxLead {
                    desired = min(targetTime, displayedFrameTime - maxLead)
                }
            }
            if CACurrentMediaTime() - lastFrameWallTime > 0.65 && actualVisualSpeed > 0.5 {
                actualVisualSpeed *= 0.88
            }
        }

        targetTime = desired
        let ahead = (targetTime - displayedFrameTime) * dirSign
        if !hasRenderedFrameInSession || ahead >= -0.02 || pendingPreviewTarget == nil {
            pendingPreviewTarget = targetTime
        }
    }

    private func recordRenderedFrame(actualTime: TimeInterval) {
        let now = CACurrentMediaTime()
        lastFrameWallTime = now
        speedSamples.append((wall: now, media: actualTime))
        let cutoff = now - 0.65
        while speedSamples.count > 2, let first = speedSamples.first, first.wall < cutoff {
            speedSamples.removeFirst()
        }
        guard let oldest = speedSamples.first, speedSamples.count >= 2 else { return }
        let dtWall = now - oldest.wall
        guard dtWall >= 0.08 else { return }
        let instantSpeed = abs(actualTime - oldest.media) / dtWall
        guard instantSpeed.isFinite else { return }
        let bounded = min(max(0, instantSpeed), max(4.0, requestedSpeed * 2.2))
        if actualVisualSpeed < 0.5 {
            actualVisualSpeed = bounded
        } else {
            actualVisualSpeed = actualVisualSpeed * 0.65 + bounded * 0.35
        }
    }

    private func startDecodeLoopIfNeeded(onPreviewFrame: @escaping PreviewSeekHandler) {
        if decodeLoopTask != nil { return }
        decodeLoopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let math = ScrubMath(profile: self.activeProfile, duration: max(1, self.currentDuration))

            while !Task.isCancelled && self.isScrubbing {
                if let nextTarget = self.pendingPreviewTarget {
                    if self.hasRenderedFrameInSession && self.activeMode != .touchpad {
                        let isShort: Bool
                        if case .shortStep = self.activeMode { isShort = true } else { isShort = false }
                        if !isShort {
                            let overshoot = (self.displayedFrameTime - nextTarget) * self.currentDirectionSign
                            let maxHoldMedia = max(0.35, self.requestedSpeed * 0.25)
                            if overshoot > maxHoldMedia {
                                self.targetTime = self.clampTime(self.displayedFrameTime, duration: self.currentDuration)
                            } else if overshoot > 0.08 {
                                try? await Task.sleep(nanoseconds: 16_000_000)
                                continue
                            }
                        }
                    }

                    var requestTarget = self.pendingPreviewTarget ?? nextTarget
                    self.pendingPreviewTarget = nil

                    if self.currentDirectionSign < 0,
                       let gopJump = math.backwardGOPJump(displayedTime: self.displayedFrameTime, targetTime: requestTarget) {
                        requestTarget = gopJump
                    }

                    if abs(requestTarget - self.lastDecodedRequestTarget) < 0.04 && self.hasRenderedFrameInSession {
                        try? await Task.sleep(nanoseconds: 6_000_000)
                        continue
                    }

                    self.lastDecodedRequestTarget = requestTarget
                    let actualTime = await onPreviewFrame(requestTarget)
                    guard !Task.isCancelled && self.isScrubbing else { break }

                    let sanitizedTime: TimeInterval
                    if self.hasRenderedFrameInSession {
                        if self.currentDirectionSign > 0 && actualTime < self.displayedFrameTime - 0.05 {
                            sanitizedTime = self.displayedFrameTime
                        } else if self.currentDirectionSign < 0 && actualTime > self.displayedFrameTime + 0.05 {
                            sanitizedTime = self.displayedFrameTime
                        } else {
                            sanitizedTime = self.clampTime(actualTime, duration: self.currentDuration)
                        }
                    } else {
                        sanitizedTime = self.clampTime(actualTime, duration: self.currentDuration)
                    }

                    self.displayedFrameTime = sanitizedTime
                    self.hasRenderedFrameInSession = true
                    self.recordRenderedFrame(actualTime: sanitizedTime)
                } else {
                    try? await Task.sleep(nanoseconds: 6_000_000)
                }
            }
            self.decodeLoopTask = nil
        }
    }

    private func stopLoopsOnly() {
        tickTask?.cancel()
        tickTask = nil
        decodeLoopTask?.cancel()
        decodeLoopTask = nil
        shortCommitTask?.cancel()
        shortCommitTask = nil
        pendingPreviewTarget = nil
    }

    private func clampTime(_ time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return max(0, time) }
        return min(max(0, time), duration)
    }
}
