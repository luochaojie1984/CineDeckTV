import Foundation
import CoreMedia
import UIKit
import os
import SubtitleKit

#if canImport(KSPlayer) && !targetEnvironment(simulator)
@preconcurrency import KSPlayer

@MainActor
private final class CineDeckKSOptions: KSOptions {
    var onVideoMetadata: (@MainActor (Float, CMFormatDescription) -> Void)?

    override func updateVideo(refreshRate: Float, isDovi: Bool, formatDescription: CMFormatDescription) {
        super.updateVideo(refreshRate: refreshRate, isDovi: isDovi, formatDescription: formatDescription)
        onVideoMetadata?(refreshRate, formatDescription)
    }
}

private final class OneShotSeekContinuation: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)

    func store(_ continuation: CheckedContinuation<Void, Never>) {
        lock.withLock { $0 = continuation }
    }

    func resumeOnce() {
        let cont = lock.withLock { current -> CheckedContinuation<Void, Never>? in
            let saved = current
            current = nil
            return saved
        }
        cont?.resume()
    }
}

/// 主力播放内核：KSPlayer 5.6.2（FFmpeg + 异步 VideoToolbox + AVSampleBufferDisplayLayer + 真实 CMFormatDescription 刷新率/动态范围匹配）。
@MainActor
public final class KSEngineAdapter: NSObject, PlayerEngine, KSPlayerLayerDelegate {
    public static let isAvailable = true

    public private(set) var layerRevision = 0
    public private(set) var isPlaying = false
    public private(set) var isBuffering = false
    public private(set) var isHardwareDecodeEnabled = true
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var videoFormatDescription: CMFormatDescription?

    public var onStateChange: ((String) -> Void)?
    public var onTimeUpdate: ((_ position: TimeInterval, _ duration: TimeInterval) -> Void)?
    public var onTracksChanged: ((_ audio: [MediaTrackItem], _ subtitles: [MediaTrackItem]) -> Void)?
    public var onPrepared: (() -> Void)?
    public var onFirstFrameRendered: (() -> Void)?
    public var onFinish: (() -> Void)?
    public var onError: ((String) -> Void)?

    private var playerLayer: KSPlayerLayer?
    private var activeOptions: CineDeckKSOptions?
    private var mountedView: UIView?
    private var loadTimeoutTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var pendingResumeSeekTime: TimeInterval?
    private var currentURLString: String = ""
    private var currentLoadOptions = EngineLoadOptions()
    private var isMutedState = false
    private var userPaused = false
    private var isSeeking = false
    private var loadGeneration: UInt64 = 0
    private var didReportPrepared = false

    public override init() {
        super.init()
    }

    public func load(url: String, startAt: TimeInterval, options: EngineLoadOptions) throws {
        guard let mediaURL = URL(string: url) else {
            throw PlayerEngineError.loadFailed("无效的播放地址：\(url)")
        }

        shutdown()
        loadGeneration &+= 1
        let gen = loadGeneration
        currentURLString = url
        currentLoadOptions = options
        isHardwareDecodeEnabled = options.hardwareDecode
        userPaused = false
        isSeeking = false
        isPlaying = true
        isBuffering = true
        didReportPrepared = false
        pendingResumeSeekTime = startAt > 0.5 ? startAt : nil

        let opts = makeOptions(options)
        self.activeOptions = opts

        let layer = KSPlayerLayer(url: mediaURL, options: opts, delegate: self)
        self.playerLayer = layer
        layerRevision &+= 1
        onStateChange?("缓冲中…")

        loadTimeoutTask?.cancel()
        loadTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled, self.loadGeneration == gen, !self.didReportPrepared, self.playerLayer === layer else { return }
            self.isBuffering = false
            self.onError?("KSPlayer 初始化超时，请重试或切换播放内核")
        }

        // 让出 1 帧给 SwiftUI 完成 layerView 挂载，再启动异步加载与首帧出画，避免挂载前帧阻塞
        prepareTask?.cancel()
        prepareTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.loadGeneration == gen, self.playerLayer === layer else { return }
            layer.prepareToPlay()
        }
    }

    private func makeOptions(_ options: EngineLoadOptions) -> CineDeckKSOptions {
        let opts = CineDeckKSOptions()
        opts.playerTypes = [KSMEPlayer.self, KSAVPlayer.self]
        opts.videoDecodeType = options.hardwareDecode ? .asynchronousHardware : .software
        opts.isAutoPlay = true
        opts.isSecondOpen = false
        opts.startPlayTime = 0
        opts.isAccurateSeek = false
        opts.isSeekedAutoPlay = true
        opts.seekUsePacketCache = true
        opts.seekInterruptIO = true
        opts.seekFlags = 1
        opts.changeDV7ToDV81 = true
        opts.autoSelectEmbedSubtitle = false
        opts.videoSoftDecodeThreadCount = 4
        opts.preferredForwardBufferDuration = 3.0
        opts.maxBufferDuration = 20
        opts.formatContextOptions["probesize"] = 2 * 1024 * 1024
        opts.formatContextOptions["analyzeduration"] = 2_000_000
        opts.onVideoMetadata = { [weak self] refreshRate, formatDesc in
            guard let self else { return }
            self.videoFormatDescription = formatDesc
            DisplayModeCoordinator.shared.apply(refreshRate: refreshRate, formatDescription: formatDesc)
        }
        return opts
    }

    public func play() {
        userPaused = false
        isPlaying = true
        playerLayer?.play()
        onStateChange?("正在播放")
    }

    public func pause() {
        userPaused = true
        isPlaying = false
        playerLayer?.pause()
        onStateChange?("已暂停")
    }

    public func seek(to time: TimeInterval, accurate: Bool) {
        guard let layer = playerLayer else { return }
        let clamped = duration > 0 ? min(max(0, time), max(0, duration - 0.5)) : max(0, time)
        let autoPlay = !userPaused
        activeOptions?.isAccurateSeek = accurate
        activeOptions?.isSeekedAutoPlay = autoPlay
        layer.seek(time: clamped, autoPlay: autoPlay) { _ in }
        currentTime = clamped
    }

    public func seekAsync(to time: TimeInterval, accurate: Bool, autoPlay: Bool) async {
        guard let layer = playerLayer else { return }
        let clamped = duration > 0 ? min(max(0, time), max(0, duration - 0.5)) : max(0, time)
        isSeeking = true
        defer { isSeeking = false }
        userPaused = !autoPlay
        activeOptions?.isAccurateSeek = accurate
        activeOptions?.isSeekedAutoPlay = autoPlay
        await performGuardedSeek(layer: layer, time: clamped, autoPlay: autoPlay, timeoutNs: 2_000_000_000)
        guard self.playerLayer === layer else { return }
        if autoPlay {
            layer.play()
            isPlaying = true
            onStateChange?("正在播放")
        } else {
            layer.pause()
            isPlaying = false
            onStateChange?("已暂停")
        }
        currentTime = clamped
    }

    public func seekToKeyframePreview(at time: TimeInterval) async -> TimeInterval {
        guard let layer = playerLayer else { return time }
        isSeeking = true
        defer { isSeeking = false }
        let clamped = duration > 0 ? min(max(0, time), max(0, duration - 0.5)) : max(0, time)
        activeOptions?.isAccurateSeek = false
        activeOptions?.isSeekedAutoPlay = false
        await performGuardedSeek(layer: layer, time: clamped, autoPlay: false, timeoutNs: 450_000_000)
        let actual = currentTime
        return (actual.isFinite && actual >= 0) ? actual : clamped
    }

    private func performGuardedSeek(
        layer: KSPlayerLayer,
        time: TimeInterval,
        autoPlay: Bool,
        timeoutNs: UInt64
    ) async {
        let guardBox = OneShotSeekContinuation()
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: timeoutNs)
            guardBox.resumeOnce()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guardBox.store(continuation)
            layer.seek(time: time, autoPlay: autoPlay) { _ in
                guardBox.resumeOnce()
            }
        }
        timeoutTask.cancel()
    }

    public func setPlaybackRate(_ rate: Double) {
        let clamped = Float(min(4.0, max(0.25, rate)))
        currentLoadOptions.playbackRate = Double(clamped)
        playerLayer?.player.playbackRate = clamped
    }

    public func setScalingMode(_ scaling: ScalingMode) {
        currentLoadOptions.scaling = scaling
        applyScalingMode(scaling)
    }

    private func applyScalingMode(_ scaling: ScalingMode) {
        guard let player = playerLayer?.player else { return }
        switch scaling {
        case .aspectFit: player.contentMode = .scaleAspectFit
        case .aspectFill: player.contentMode = .scaleAspectFill
        case .fill: player.contentMode = .scaleToFill
        }
    }

    public func setMuted(_ muted: Bool) {
        isMutedState = muted
        playerLayer?.player.isMuted = muted
    }

    /// KSPlayer 软/硬解码实时切换：保留当前时间点、倍速与画幅无感重建 KSPlayerLayer。
    @discardableResult
    public func switchDecoder(hardware: Bool) -> Bool {
        guard !currentURLString.isEmpty else { return false }
        let resumeAt = max(0, currentTime)
        var nextOptions = currentLoadOptions
        nextOptions.hardwareDecode = hardware
        do {
            try load(url: currentURLString, startAt: resumeAt, options: nextOptions)
            return true
        } catch {
            onError?(error.localizedDescription)
            return false
        }
    }

    public func selectAudioTrack(id: Int32) {
        guard let player = playerLayer?.player else { return }
        if let match = player.tracks(mediaType: .audio).first(where: { $0.trackID == id }) {
            player.select(track: match)
            refreshTracks()
        }
    }

    public func selectSubtitleTrack(id: Int32) {
        guard let player = playerLayer?.player else { return }
        if let match = player.tracks(mediaType: .subtitle).first(where: { $0.trackID == id }) {
            player.select(track: match)
            refreshTracks()
        }
    }

    public func disableEmbeddedSubtitle() {
        guard let player = playerLayer?.player else { return }
        for track in player.tracks(mediaType: .subtitle) {
            track.isEnabled = false
        }
        refreshTracks()
    }

    public func captureTechStats() -> PlaybackTechStats {
        var stats = PlaybackTechStats()
        stats.engineName = "KSPlayer 5.6 (Metal)"
        stats.isHardwareDecode = isHardwareDecodeEnabled
        guard let player = playerLayer?.player else { return stats }
        let info = player.dynamicInfo
        info.update()
        let size = player.naturalSize
        if size.width > 0 && size.height > 0 {
            stats.resolution = "\(Int(size.width))×\(Int(size.height))"
        }
        let rangeTag: String
        switch player.dynamicRange {
        case .dolbyVision: rangeTag = " DV"
        case .hdr10: rangeTag = " HDR10"
        case .hlg: rangeTag = " HLG"
        default: rangeTag = ""
        }
        stats.videoCodec = (player.videoFormat ?? "HEVC") + rangeTag
        if let audio = player.tracks(mediaType: .audio).first(where: { $0.isEnabled }) {
            stats.audioCodec = audio.name
        }
        let fps = Double(player.nominalFrameRate)
        stats.fps = fps > 0 ? fps : 0
        stats.outputFPS = stats.fps
        stats.droppedFrames = Int32(info.droppedVideoFrameCount)
        let bytesPerSec = Double(info.networkSpeed)
        stats.downloadSpeedMBps = bytesPerSec / (1024.0 * 1024.0)
        stats.bitrateMbps = (bytesPerSec * 8.0) / 1_000_000.0
        return stats
    }

    public func mount(into container: UIView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        mountedView = nil
        guard let layerView = playerLayer?.makeUIView() else { return }
        layerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(layerView)
        NSLayoutConstraint.activate([
            layerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            layerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            layerView.topAnchor.constraint(equalTo: container.topAnchor),
            layerView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        mountedView = layerView
        playerLayer?.updateUIView(layerView)
    }

    public func updateMountedView() {
        if let mountedView {
            playerLayer?.updateUIView(mountedView)
        }
    }

    public func shutdown() {
        loadGeneration &+= 1
        prepareTask?.cancel()
        prepareTask = nil
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        pendingResumeSeekTime = nil
        userPaused = false
        isSeeking = false
        isPlaying = false
        isBuffering = false
        didReportPrepared = false
        playerLayer?.delegate = nil
        playerLayer?.stop()
        playerLayer?.reset()
        playerLayer = nil
        activeOptions = nil
        mountedView?.removeFromSuperview()
        mountedView = nil
        videoFormatDescription = nil
    }

    private func refreshTracks() {
        guard let player = playerLayer?.player else { return }
        let audio = player.tracks(mediaType: .audio).map { track in
            MediaTrackItem(
                id: track.trackID,
                title: track.name,
                language: track.languageCode ?? "",
                codecName: "",
                isSelected: track.isEnabled
            )
        }
        let subs = player.tracks(mediaType: .subtitle).map { track in
            MediaTrackItem(
                id: track.trackID,
                title: track.name,
                language: track.languageCode ?? "",
                codecName: track.isImageSubtitle ? "图形字幕" : "内嵌文本",
                isSelected: track.isEnabled
            )
        }
        onTracksChanged?(audio, subs)
    }

    // MARK: - KSPlayerLayerDelegate

    public func playerDidReplace(layer: KSPlayerLayer) {
        guard layer === self.playerLayer else { return }
        updateMountedView()
    }

    public func player(layer: KSPlayerLayer, state: KSPlayerState) {
        guard layer === self.playerLayer else { return }
        switch state {
        case .buffering:
            isBuffering = true
            isPlaying = !userPaused
            onStateChange?("缓冲中…")
        case .readyToPlay:
            loadTimeoutTask?.cancel()
            loadTimeoutTask = nil
            isBuffering = false
            duration = max(0, layer.player.duration)
            applyScalingMode(currentLoadOptions.scaling)
            layer.player.playbackRate = Float(currentLoadOptions.playbackRate)
            layer.player.isMuted = isMutedState
            refreshTracks()
            updateMountedView()
            if let videoTrack = layer.player.tracks(mediaType: .video).first,
               let desc = videoTrack.formatDescription {
                videoFormatDescription = desc
                DisplayModeCoordinator.shared.apply(
                    refreshRate: videoTrack.nominalFrameRate,
                    formatDescription: desc
                )
            }
            if let resumeAt = pendingResumeSeekTime {
                pendingResumeSeekTime = nil
                let gen = loadGeneration
                let target = duration > 0 ? min(max(0, resumeAt), max(0, duration - 0.5)) : max(0, resumeAt)
                Task { @MainActor [weak self] in
                    guard let self, self.loadGeneration == gen, self.playerLayer === layer else { return }
                    self.isSeeking = true
                    defer { self.isSeeking = false }
                    let wantPlay = !self.userPaused
                    self.activeOptions?.isAccurateSeek = false
                    self.activeOptions?.isSeekedAutoPlay = wantPlay
                    await self.performGuardedSeek(layer: layer, time: target, autoPlay: wantPlay, timeoutNs: 2_500_000_000)
                    guard self.loadGeneration == gen, self.playerLayer === layer else { return }
                    self.updateMountedView()
                    if !self.userPaused {
                        layer.play()
                        self.isPlaying = true
                        self.onStateChange?("正在播放")
                    } else {
                        layer.pause()
                        self.isPlaying = false
                        self.onStateChange?("已暂停")
                    }
                    if !self.didReportPrepared {
                        self.didReportPrepared = true
                        self.onPrepared?()
                        self.onFirstFrameRendered?()
                    }
                }
            } else {
                if userPaused {
                    layer.pause()
                    isPlaying = false
                    onStateChange?("已暂停")
                } else {
                    if !layer.player.isPlaying { layer.play() }
                    isPlaying = true
                    onStateChange?("正在播放")
                }
                if !didReportPrepared {
                    didReportPrepared = true
                    onPrepared?()
                    onFirstFrameRendered?()
                }
            }
        case .bufferFinished:
            isBuffering = false
            if userPaused {
                if layer.player.isPlaying { layer.pause() }
                isPlaying = false
                onStateChange?("已暂停")
            } else {
                isPlaying = true
                onStateChange?("正在播放")
            }
        case .paused:
            isBuffering = false
            if userPaused {
                isPlaying = false
                onStateChange?("已暂停")
            } else if didReportPrepared && !isSeeking && pendingResumeSeekTime == nil {
                userPaused = true
                isPlaying = false
                onStateChange?("已暂停")
            }
        case .playedToTheEnd:
            isBuffering = false
            userPaused = false
            isPlaying = false
            onStateChange?("播放完成")
        case .error:
            isBuffering = false
            isPlaying = false
            onStateChange?("播放异常")
        default:
            break
        }
    }

    public func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        guard layer === self.playerLayer else { return }
        self.currentTime = max(0, currentTime)
        if totalTime > 0 {
            self.duration = totalTime
        }
        onTimeUpdate?(self.currentTime, self.duration)
    }

    public func player(layer: KSPlayerLayer, finish error: (any Error)?) {
        guard layer === self.playerLayer else { return }
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        userPaused = false
        isSeeking = false
        isPlaying = false
        isBuffering = false
        if let error {
            onError?(error.localizedDescription)
        } else {
            onFinish?()
        }
    }

    public func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}
}

#else
/// Simulator 占位实现：tvOS 模拟器下自动回退至 FSPlayer / AVPlayer，不影响真机 KSPlayer 5.6.2 完整能力。
@MainActor
public final class KSEngineAdapter: PlayerEngine {
    public static let isAvailable = false

    public private(set) var layerRevision = 0
    public private(set) var isPlaying = false
    public private(set) var isBuffering = false
    public private(set) var isHardwareDecodeEnabled = true
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0

    public var onStateChange: ((String) -> Void)?
    public var onTimeUpdate: ((_ position: TimeInterval, _ duration: TimeInterval) -> Void)?
    public var onTracksChanged: ((_ audio: [MediaTrackItem], _ subtitles: [MediaTrackItem]) -> Void)?
    public var onPrepared: (() -> Void)?
    public var onFirstFrameRendered: (() -> Void)?
    public var onFinish: (() -> Void)?
    public var onError: ((String) -> Void)?

    public init() {}

    public func load(url: String, startAt: TimeInterval, options: EngineLoadOptions) throws {
        throw PlayerEngineError.engineUnavailable("KSPlayer 仅在 Apple TV 真机上可用")
    }
    public func play() {}
    public func pause() {}
    public func seek(to time: TimeInterval, accurate: Bool) {}
    public func seekAsync(to time: TimeInterval, accurate: Bool, autoPlay: Bool) async {}
    public func seekToKeyframePreview(at time: TimeInterval) async -> TimeInterval { time }
    public func setPlaybackRate(_ rate: Double) {}
    public func setScalingMode(_ scaling: ScalingMode) {}
    public func setMuted(_ muted: Bool) {}
    @discardableResult public func switchDecoder(hardware: Bool) -> Bool { false }
    public func selectAudioTrack(id: Int32) {}
    public func selectSubtitleTrack(id: Int32) {}
    public func disableEmbeddedSubtitle() {}
    public func captureTechStats() -> PlaybackTechStats {
        var s = PlaybackTechStats()
        s.engineName = "KSPlayer (真机)"
        return s
    }
    public func mount(into container: UIView) {}
    public func updateMountedView() {}
    public func shutdown() {}
}
#endif
