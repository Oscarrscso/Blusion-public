import Foundation
import Testing
@testable import Features

@Suite struct SpeedHoldRulesTests {
    /// Each full 40 points up adds 1×; dragging back down steps back, never below 2×, and the ceiling holds beyond 4×.
    @Test func eachFortyPointsStepsTheSpeed() {
        let cases: [(Double, Float)] = [(0, 2), (-39.9, 2), (-40, 3), (-79.9, 3), (-80, 4), (-400, 4), (40, 2), (-1, 2)]
        for (displacement, expected) in cases {
            #expect(SpeedHoldRules.rate(displacement: displacement, maximum: 4) == expected, "\(displacement) points")
        }
    }

    @Test func smallMovementsAroundAStepDoNotToggleTheSpeed() {
        var rate: Float = 2
        let cases: [(Double, Float)] = [(-40, 3), (-39, 3), (-41, 3), (-35, 3), (-34, 2),
                                       (-39, 2), (-40, 3), (-80, 4), (-79, 4), (-74, 3), (-34, 2)]
        for (displacement, expected) in cases {
            rate = SpeedHoldRules.rate(displacement: displacement, maximum: 4, current: rate)
            #expect(rate == expected, "\(displacement) points")
        }
    }

    /// The engine's own ceiling caps the hold, including items that do not support fast-forward above 2×.
    @Test func theEnginesCeilingCapsTheHold() {
        #expect(SpeedHoldRules.rate(displacement: -400, maximum: 2) == 2)
        #expect(SpeedHoldRules.rate(displacement: -400, maximum: 3) == 3)
        #expect(SpeedHoldRules.rate(displacement: -400, maximum: 4) == 4)
        #expect(SpeedHoldRules.rate(displacement: -400, maximum: 9) == 4)
    }

    /// A position that is not a number keeps the start speed, and a finger below where the hold began never drops under it.
    @Test func badPositionsKeepTheStartSpeed() {
        #expect(SpeedHoldRules.rate(displacement: .nan, maximum: 4) == 2)
        #expect(SpeedHoldRules.rate(displacement: 500, maximum: 4) == 2)
    }

    /// A hold begins at 2×, after a 0.4 s rest, and a press may drift 10 points before it stops being one.
    @Test func aHoldBeginsAtTwoAfterAFourHundredMillisecondRest() {
        #expect(SpeedHoldRules.startRate == 2)
        #expect(SpeedHoldRules.holdDelay == 0.4)
        #expect(SpeedHoldRules.holdTolerance == 10)
    }
}
