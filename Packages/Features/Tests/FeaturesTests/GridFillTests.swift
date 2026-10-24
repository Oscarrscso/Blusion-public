import CoreGraphics
import SwiftUI
import Testing
@testable import Features

/// A grid that fills its width: the columns and their gaps add up to the width exactly, so the last column ends on the right margin.
@Suite struct GridFillTests {
    /// The Mac's landscape posters: at least 216 points wide, 16 apart.
    private let minimum: CGFloat = 216
    private let spacing: CGFloat = 16

    @Test(arguments: [200, 216, 448, 600, 908, 1000, 1143, 1144, 1400, 1920, 2560] as [CGFloat])
    func theColumnsAndGapsAddUpToTheWidth(width: CGFloat) {
        let count = GridFill.columnCount(width: width, minimum: minimum, spacing: spacing)
        let column = GridFill.columnWidth(width: width, count: count, spacing: spacing)
        #expect(abs(column * CGFloat(count) + spacing * CGFloat(count - 1) - width) < 0.001, "no gutter on the right")
        if count > 1 { #expect(column >= minimum, "never narrower than today's smallest card") }
        #expect(GridFill.columnWidth(width: width, count: count + 1, spacing: spacing) < minimum, "as many columns as fit")
    }

    @Test func aWiderWindowAddsColumnsRatherThanWiderCards() {
        #expect(GridFill.columnCount(width: 908, minimum: minimum, spacing: spacing) == 3)
        #expect(GridFill.columnCount(width: 1144, minimum: minimum, spacing: spacing) == 5)
        #expect(GridFill.columnCount(width: 1920, minimum: minimum, spacing: spacing) == 8)
        #expect(GridFill.columnWidth(width: 908, count: 3, spacing: spacing) == 292)
    }

    @Test func aNarrowGridHasOneColumn() {
        #expect(GridFill.columnCount(width: 100, minimum: minimum, spacing: spacing) == 1)
        #expect(GridFill.columnCount(width: 0, minimum: minimum, spacing: spacing) == 1)
        #expect(GridFill.columnWidth(width: 100, count: 1, spacing: spacing) == 100)
    }

    @Test func onlyAnAdaptiveGridLosesItsMaximum() throws {
        let filled = GridFill.filling([GridItem(.adaptive(minimum: 216, maximum: 270), spacing: 16, alignment: .top)])
        #expect(filled.count == 1)
        guard case .adaptive(let low, let high) = try #require(filled.first).size else { Issue.record("not adaptive"); return }
        #expect(low == 216, "the same smallest card as today")
        #expect(high == .infinity, "no cap, so no gutter")
        #expect(filled.first?.spacing == 16)
        let phone = Array(repeating: GridItem(.flexible()), count: 3)
        #expect(GridFill.filling(phone).count == 3, "the phone's three columns stay")
        guard case .flexible = GridFill.filling(phone)[0].size else { Issue.record("changed"); return }
    }
}
