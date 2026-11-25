import Testing
import Foundation
@testable import PlaybackKit

@Suite("ScrubMath")
struct ScrubMathTests {
    @Test("起手阈值前为 0，之后指数增长")
    func rateCurve() {
        let math = ScrubMath(profile: .standard, duration: 7200)
        #expect(math.rate(after: 0.1) == 0)
        let early = math.rate(after: 0.68)
        #expect(early > 6)
        #expect(math.rate(after: 60) == 120)
    }

    @Test("三档封顶分别为 60 / 120 / 240")
    func ceilings() {
        #expect(ScrubMath(profile: .fine, duration: 7200).rate(after: 600) == 60)
        #expect(ScrubMath(profile: .standard, duration: 7200).rate(after: 600) == 120)
        #expect(ScrubMath(profile: .turbo, duration: 7200).rate(after: 600) == 240)
    }

    @Test("快进单调递增，绝不回退 PTS")
    func forwardMonotonic() {
        let math = ScrubMath(profile: .standard, duration: 7200)
        var displayed = 100.0
        for step in 0..<120 {
            let tick = math.tick(elapsed: 0.2 + Double(step) * 0.033, displayedTime: displayed, forward: true)
            #expect(tick.targetTime >= displayed - 0.05)
            displayed = tick.targetTime
        }
        #expect(displayed > 100)
    }

    @Test("快退不产生比已显示帧更晚的时间")
    func backwardMonotonic() {
        let math = ScrubMath(profile: .fine, duration: 7200)
        var displayed = 1000.0
        for step in 0..<60 {
            let tick = math.tick(elapsed: 0.2 + Double(step) * 0.033, displayedTime: displayed, forward: false)
            #expect(tick.targetTime <= displayed + 0.05)
            displayed = tick.targetTime
        }
        #expect(displayed < 1000)
    }

    @Test("长 GOP 阶梯：落后 1–8.36s 时强跨一个关键帧间隔")
    func backwardGOPJump() {
        let math = ScrubMath(profile: .fine, duration: 7200)
        #expect(math.backwardGOPJump(displayedTime: 1000, targetTime: 998.5) != nil)
        #expect(math.backwardGOPJump(displayedTime: 1000, targetTime: 999.5) == nil)
        #expect(math.backwardGOPJump(displayedTime: 1000, targetTime: 985) == nil)
    }

    @Test("松手落点不早于屏幕所见帧，且夹在片长内")
    func releaseTarget() {
        let math = ScrubMath(profile: .turbo, duration: 7200)
        #expect(math.releaseTarget(displayedTime: 321.5, forward: true) == 321.5)
        #expect(math.releaseTarget(displayedTime: -5, forward: false) == 0)
        #expect(math.releaseTarget(displayedTime: 99999, forward: true) == 7200)
    }

    @Test("短按跳秒合并上限 15s")
    func mergedJumps() {
        #expect(ScrubMath.mergedJump(shortPressCount: 1) == 5)
        #expect(ScrubMath.mergedJump(shortPressCount: 2) == 10)
        #expect(ScrubMath.mergedJump(shortPressCount: 9) == 15)
    }
}
