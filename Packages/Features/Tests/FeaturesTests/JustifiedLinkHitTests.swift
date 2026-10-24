import CoreGraphics
import Testing
@testable import Features

@Suite struct JustifiedLinkHitTests {
    /// A link one line tall (20 points) and 100 points wide, by default at (100, 100).
    private func link(x: CGFloat = 100, y: CGFloat = 100, width: CGFloat = 100, height: CGFloat = 20) -> CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    @Test func aTapInsideTheFrameHitsIt() {
        #expect(JustifiedLinkHit.index(at: CGPoint(x: 150, y: 110), frames: [link()]) == 0)
    }

    @Test func aTapAboveALineLinkHitsWithinItsGrownTarget() {
        #expect(JustifiedLinkHit.index(at: CGPoint(x: 150, y: 90), frames: [link()]) == 0, "10 points above: inside the 12-point growth")
        #expect(JustifiedLinkHit.index(at: CGPoint(x: 150, y: 87), frames: [link()]) == nil, "13 points above: outside it")
    }

    @Test func aTapBesideAWideLinkUsesTheSlop() {
        #expect(JustifiedLinkHit.index(at: CGPoint(x: 92, y: 110), frames: [link()]) == 0, "8 points left: the slop")
        #expect(JustifiedLinkHit.index(at: CGPoint(x: 91, y: 110), frames: [link()]) == nil, "9 points left: outside it")
    }

    @Test func aSmallLinkIsHitAnywhereWithinItsMinimumTarget() {
        // 10 points across grows by 17 each way, so the target runs from 83 to 127.
        let small = link(width: 10, height: 10)
        #expect(JustifiedLinkHit.index(at: CGPoint(x: 83, y: 110), frames: [small]) == 0)
        #expect(JustifiedLinkHit.index(at: CGPoint(x: 82, y: 110), frames: [small]) == nil)
        #expect(JustifiedLinkHit.index(at: CGPoint(x: 126, y: 110), frames: [small]) == 0)
        #expect(JustifiedLinkHit.index(at: CGPoint(x: 127, y: 110), frames: [small]) == nil)
    }

    @Test func theNearerLinkWins() {
        // The upper link ends at 120 and the lower starts at 130; both targets reach the gap between them.
        let upper = link(y: 100)
        let lower = link(y: 130)
        #expect(JustifiedLinkHit.index(at: CGPoint(x: 150, y: 124), frames: [upper, lower]) == 0, "4 below the upper, 6 above the lower")
        #expect(JustifiedLinkHit.index(at: CGPoint(x: 150, y: 127), frames: [upper, lower]) == 1, "7 below the upper, 3 above the lower")
        #expect(JustifiedLinkHit.index(at: CGPoint(x: 150, y: 125), frames: [upper, lower]) == 0, "equally near: the first")
    }

    @Test func aTapInsideALinkWinsOverAnotherLinksTarget() {
        // The first link's target holds the tap at 119, but the second link's own frame does.
        let beside = link(y: 130)
        let inside = link(y: 100)
        #expect(JustifiedLinkHit.index(at: CGPoint(x: 150, y: 119), frames: [beside, inside]) == 1)
    }

    @Test func noFramesOrEmptyFramesGiveNil() {
        #expect(JustifiedLinkHit.index(at: CGPoint(x: 1, y: 1), frames: []) == nil)
        #expect(JustifiedLinkHit.index(at: .zero, frames: [.zero]) == nil, "a zero-size frame is skipped")
    }
}
