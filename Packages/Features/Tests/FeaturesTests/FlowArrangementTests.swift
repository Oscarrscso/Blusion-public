import CoreGraphics
import Testing
@testable import Features

@Suite struct FlowArrangementTests {
    /// A measure that gives a subview the width it is offered, as a one-line label that cuts its text short does.
    private func fitting(_ index: Int, _ width: CGFloat) -> CGSize { CGSize(width: width, height: 30) }

    @Test func subviewsWrapToANewRowWhenTheNextDoesNotFit() {
        let sizes = [CGSize(width: 100, height: 30), CGSize(width: 120, height: 30), CGSize(width: 150, height: 30)]
        let result = FlowArrangement.arrange(sizes: sizes, in: 300, spacing: 10, fitted: fitting)
        #expect(result.frames.map(\.origin) == [CGPoint(x: 0, y: 0), CGPoint(x: 110, y: 0), CGPoint(x: 0, y: 40)])
        #expect(result.size == CGSize(width: 230, height: 70))
    }

    /// A setting in the widget builder's sentence that was longer than the screen made the whole builder wider than the screen.
    @Test func aSubviewWiderThanTheWidthIsGivenTheWidthAndNothingGoesWider() {
        let sizes = [CGSize(width: 60, height: 30), CGSize(width: 900, height: 30), CGSize(width: 60, height: 30)]
        let result = FlowArrangement.arrange(sizes: sizes, in: 361, spacing: 6, fitted: fitting)
        #expect(result.frames[1] == CGRect(x: 0, y: 36, width: 361, height: 30), "on a row of its own, as wide as the container")
        #expect(result.frames[2].origin == CGPoint(x: 0, y: 72))
        #expect(result.size.width <= 361)
        #expect(result.frames.allSatisfy { $0.maxX <= 361 })
    }

    @Test func anUnboundedWidthKeepsEverySubviewAtItsOwnSize() {
        let sizes = [CGSize(width: 900, height: 30), CGSize(width: 50, height: 20)]
        let result = FlowArrangement.arrange(sizes: sizes, in: .infinity, spacing: 8, fitted: fitting)
        #expect(result.frames.map(\.size) == sizes)
        #expect(result.size == CGSize(width: 958, height: 30))
    }

    @Test func nothingToArrangeTakesNoRoom() {
        #expect(FlowArrangement.arrange(sizes: [], in: 300, spacing: 8, fitted: fitting).size == .zero)
    }
}
