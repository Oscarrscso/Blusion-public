import Foundation
import Testing
@testable import Features

@Suite struct TrailerPanelLayoutTests {
    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

    @Test func anUnknownOrOddShapeIsSixteenByNine() {
        for given in [nil, 0, -1, 0.1, 10, Double.nan] as [Double?] {
            #expect(TrailerPanelLayout.aspectRatio(given) == 16.0 / 9.0, "\(String(describing: given)) is not a usable shape")
        }
    }

    @Test func aShapeWithinTwoPercentOfACommonOneIsThatOneExactly() {
        #expect(TrailerPanelLayout.aspectRatio(1.7699) == 16.0 / 9.0, "a rounded 16:9 size")
        #expect(TrailerPanelLayout.aspectRatio(1.3333) == 4.0 / 3.0, "a rounded 4:3 size")
        #expect(TrailerPanelLayout.aspectRatio(2.0) == 2.0, "no common shape is near, so the shape stays")
    }

    @Test func aWideTrailerIsFullWidthAndSixteenByNineHigh() {
        let size = TrailerPanelLayout.size(aspectRatio: 16.0 / 9.0, width: 360, maxHeight: 360)
        #expect(near(size.width, 360) && near(size.height, 202.5))
    }

    @Test func aStandardTrailerIsFullWidthAndFourByThreeHigh() {
        let size = TrailerPanelLayout.size(aspectRatio: 4.0 / 3.0, width: 360, maxHeight: 360)
        #expect(near(size.width, 360) && near(size.height, 270))
    }

    @Test func aTallTrailerIsCappedByTheHeightAndNarrower() {
        let size = TrailerPanelLayout.size(aspectRatio: 9.0 / 16.0, width: 360, maxHeight: 360)
        #expect(near(size.width, 202.5) && near(size.height, 360), "a tall picture never grows taller than the space")
    }

    @Test func inLandscapeAStandardTrailerIsCappedByTheSixteenByNineHeight() {
        let maxHeight = 360.0 * 9 / 16
        let size = TrailerPanelLayout.size(aspectRatio: 4.0 / 3.0, width: 360, maxHeight: maxHeight)
        #expect(near(size.width, maxHeight * 4 / 3) && near(size.height, maxHeight))
    }

    @Test func anUnknownShapeGivesTheSixteenByNinePanel() {
        let size = TrailerPanelLayout.size(aspectRatio: nil, width: 360, maxHeight: 360)
        #expect(near(size.width, 360) && near(size.height, 202.5))
    }

    @Test func aZeroWidthGivesNothing() {
        let size = TrailerPanelLayout.size(aspectRatio: 4.0 / 3.0, width: 0, maxHeight: 360)
        #expect(size.width == 0 && size.height == 0)
    }
}
