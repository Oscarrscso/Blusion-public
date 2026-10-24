import CoreGraphics
import Testing
@testable import Features

@Suite struct BackSwipeRuleTests {
    /// An iPhone held upright: a sixth-and-a-bit of it (15%) is about 60 points.
    private let width: CGFloat = 402

    @Test func aNudgeOnThePageKeepsIt() {
        #expect(BackSwipeRule.mayBegin(forward: 12, vertical: 2, fromEdge: false), "a sideways start may track")
        #expect(!BackSwipeRule.goesBack(forward: 12, vertical: 2, fromEdge: false, width: width), "but a few points do not go back")
        #expect(!BackSwipeRule.goesBack(forward: 25, vertical: 2, fromEdge: false, width: width, speed: 900), "nor a short quick nudge")
        #expect(!BackSwipeRule.goesBack(forward: 50, vertical: 5, fromEdge: false, width: width, speed: 200), "nor a slow short drag")
    }

    @Test func anOrdinarySwipeOnThePageGoesBack() {
        #expect(BackSwipeRule.goesBack(forward: 61, vertical: 20, fromEdge: false, width: width), "a sixth of the screen, mostly across")
        #expect(BackSwipeRule.goesBack(forward: 35, vertical: 10, fromEdge: false, width: width, speed: 800), "a quick flick, sooner")
        #expect(BackSwipeRule.mayBegin(forward: 12, vertical: 9, fromEdge: false), "a swipe that starts a little diagonal still tracks")
    }

    @Test func aScrollThatDriftsSidewaysNeverGoesBack() {
        #expect(!BackSwipeRule.mayBegin(forward: 8, vertical: 12, fromEdge: false), "more down than across: the page scrolls")
        #expect(!BackSwipeRule.goesBack(forward: 150, vertical: 120, fromEdge: false, width: width, speed: 900), "far, but not mostly across")
        #expect(!BackSwipeRule.mayBegin(forward: -20, vertical: 0, fromEdge: false), "towards the leading edge")
        #expect(!BackSwipeRule.goesBack(forward: -150, vertical: 0, fromEdge: true, width: width))
    }

    @Test func anEdgeSwipeGoesBackAtOnce() {
        #expect(BackSwipeRule.edgeWidth == 30)
        #expect(BackSwipeRule.mayBegin(forward: 10, vertical: 8, fromEdge: true), "from the edge, more across than down is enough")
        #expect(BackSwipeRule.goesBack(forward: 10, vertical: 8, fromEdge: true, width: width))
        #expect(!BackSwipeRule.goesBack(forward: 8, vertical: 10, fromEdge: true, width: width), "a mostly vertical drag from the edge")
    }
}
