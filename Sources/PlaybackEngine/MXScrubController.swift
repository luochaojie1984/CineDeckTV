import Foundation
import UIKit
import PlaybackKit

/// MX 手感快进控制器：0.18s 起手、30Hz 连续指数加速、单飞合并、长 GOP 单调防乒乓。
@MainActor
public final class MXScrubController {
    public enum Direction: Sendable { case forward, backward }

    public var onTick: ((Double, Double) -> Void)?
    public var onRelease: ((Double) -> Void)?
    public var onRateChange: ((Double) -> Void)?

    public private(set) var isScrubbing = false

    private var profile: ScrubProfile = .standard
    private var math: ScrubMath?
    private var timer: Timer?
    private var startTimestamp: CFTimeInterval = 0
    private var direction: Direction = .forward
    private var displayedTime: Double = 0
    private var lastEmittedTarget: Double = -1

    public init() {}

    public func begin(direction: Direction, displayedTime: Double, duration: Double, profile: ScrubProfile) {
        self.direction = direction
        self.displayedTime = displayedTime
        self.profile = profile
        self.math = ScrubMath(profile: profile, duration: duration)
        self.startTimestamp = CACurrentMediaTime()
        self.lastEmittedTarget = -1
        isScrubbing = true
        startTimer()
    }

    public func update(displayedTime: Double) {
        self.displayedTime = displayedTime
    }

    public func end() {
        guard isScrubbing else { return }
        stopTimer()
        isScrubbing = false
        onRelease?(displayedTime)
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let math else { return }
        let elapsed = CACurrentMediaTime() - startTimestamp
        let result = math.tick(elapsed: elapsed, displayedTime: displayedTime, forward: direction == .forward)
        guard result.rate > 0 else { return }
        onRateChange?(result.rate)
        guard abs(result.targetTime - lastEmittedTarget) > 0.01 else { return }
        lastEmittedTarget = result.targetTime
        onTick?(result.targetTime, result.rate)
    }
}
