import Foundation

/// 快进档位：起手倍速、指数增长率、封顶。
public struct ScrubProfile: Sendable, Equatable {
    public let initialRate: Double
    public let growth: Double
    public let ceiling: Double
    public let startDelay: Double

    public init(initialRate: Double, growth: Double, ceiling: Double, startDelay: Double = 0.18) {
        self.initialRate = initialRate
        self.growth = growth
        self.ceiling = ceiling
        self.startDelay = startDelay
    }

    public static let fine = ScrubProfile(initialRate: 4, growth: 2.15, ceiling: 60)
    public static let standard = ScrubProfile(initialRate: 6, growth: 2.25, ceiling: 120)
    public static let turbo = ScrubProfile(initialRate: 10, growth: 2.40, ceiling: 240)
}

/// 单拍解算结果：目标时间、当前倍速、是否被单调规则丢弃。
public struct ScrubTick: Sendable, Equatable {
    public let targetTime: Double
    public let rate: Double
    public let rejected: Bool
}

/// 快进/快退的纯数学部分（无 UIKit，可在 Linux 单测）。
///
/// 三条硬规则（设计规划 5.5 / 6.3 #13）：
/// 1. 曲线：min(ceiling, initial * growth^t)，t 为按住时长（秒，扣掉 0.18s 起手）。
/// 2. 单调：快进绝不渲染比已显示帧更早的 PTS（容差 0.05s）；快退同理不渲染更晚的帧。
/// 3. 长 GOP 跨越：快退卡在同一关键帧且落后 >= 1.0s 时，按 -1.0s -> -9.5s 阶梯强制跨 GOP。
public struct ScrubMath: Sendable {
    public let profile: ScrubProfile
    public let duration: Double
    public let frameDuration: Double

    public init(profile: ScrubProfile, duration: Double, frameDuration: Double = 1.0 / 24.0) {
        self.profile = profile
        self.duration = max(0, duration)
        self.frameDuration = frameDuration
    }

    /// 按住 elapsed 秒后的倍速。
    public func rate(after elapsed: Double) -> Double {
        guard elapsed > profile.startDelay else { return 0 }
        let t = elapsed - profile.startDelay
        return min(profile.ceiling, profile.initialRate * pow(profile.growth, t))
    }

    /// 单拍推进：forward = true 表示快进。
    public func tick(elapsed: Double, displayedTime: Double, forward: Bool, tickInterval: Double = 1.0 / 30.0) -> ScrubTick {
        let currentRate = rate(after: elapsed)
        guard currentRate > 0 else {
            return ScrubTick(targetTime: displayedTime, rate: 0, rejected: false)
        }
        let step = currentRate * tickInterval
        var target = forward ? displayedTime + step : displayedTime - step
        if forward {
            if target < displayedTime - 0.05 { target = displayedTime }
        } else {
            if target > displayedTime + 0.05 { target = displayedTime }
        }
        let clamped = min(max(0, target), max(0, duration))
        return ScrubTick(targetTime: clamped, rate: currentRate, rejected: clamped == displayedTime && step > 0)
    }

    /// 长 GOP 卡住判据：同一关键帧内多次推进仍落后 >= 1.0s 时，强制跨到前一个关键帧。
    /// 返回 nil 表示不触发阶梯。
    public func backwardGOPJump(displayedTime: Double, targetTime: Double, keyframeInterval: Double = 8.36) -> Double? {
        let lag = displayedTime - targetTime
        guard lag >= 1.0, lag < keyframeInterval else { return nil }
        let stepped = displayedTime - keyframeInterval - 1.0
        return max(0, min(stepped, displayedTime - 1.0))
    }

    /// 松手后的落点：以屏幕所见帧为准（关键帧 seek），不回退到更早位置。
    public func releaseTarget(displayedTime: Double, forward: Bool) -> Double {
        min(max(0, displayedTime), max(0, duration))
    }

    /// 短按跳秒的合并：连续点按按次数累加，单次上限 15s。
    public static func mergedJump(shortPressCount: Int, unit: Double = 5) -> Double {
        let capped = min(max(1, shortPressCount), 3)
        return min(15, unit * Double(capped))
    }
}
