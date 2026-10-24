import CoreGraphics
import StremioKit
import Testing
@testable import Features

@Suite struct WidgetSlotLayoutTests {
    /// Two columns across 340 points: each card is 162 wide and 243 tall, with a 16-point gutter.
    private let layout = WidgetSlotLayout.fitting(width: 340, columns: 2, count: 5)

    @Test func theCardSizeFillsTheWidthBetweenTheGutters() {
        #expect(layout.cardWidth == 162)
        #expect(layout.cardHeight == 243)
        #expect(layout.rows == 3)
        #expect(layout.contentSize == CGSize(width: 340, height: 3 * 243 + 2 * 16))
    }

    @Test func aCardsCentreIsItsOwnSlot() {
        for index in 0..<5 {
            #expect(layout.index(at: layout.center(for: index)) == index, "the centre of slot \(index)")
        }
    }

    @Test func aGutterIsNoSlot() {
        #expect(layout.index(at: CGPoint(x: 170, y: 50)) == nil, "between the two columns")
        #expect(layout.index(at: CGPoint(x: 50, y: 250)) == nil, "between two rows")
    }

    @Test func pastTheLastCardIsTheLastSlot() {
        #expect(layout.index(at: CGPoint(x: 300, y: 600)) == 4, "an empty slot of the short last row")
        #expect(layout.index(at: CGPoint(x: 50, y: 2000)) == 4, "below the grid")
    }

    @Test func outsideTheGridIsNoSlot() {
        #expect(layout.index(at: CGPoint(x: -4, y: 50)) == nil)
        #expect(layout.index(at: CGPoint(x: 50, y: -4)) == nil)
        #expect(layout.index(at: CGPoint(x: 400, y: 50)) == nil, "beyond the right edge")
    }

    @Test func moreColumnsMakeNarrowerCards() {
        let three = WidgetSlotLayout.fitting(width: 340, columns: 3, count: 7)
        let expectedWidth: CGFloat = (340 - 2 * 16) / 3
        #expect(abs(three.cardWidth - expectedWidth) < 0.001)
        #expect(three.rows == 3)
        #expect(three.index(at: three.center(for: 6)) == 6, "the last card of a short row")
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6])
    func everyColumnCountFindsItsCardsAndGutters(columns: Int) {
        let count = columns * 2 + 1
        let grid = WidgetSlotLayout.fitting(width: 600, columns: columns, count: count)
        for index in 0..<count {
            let frame = grid.frame(for: index)
            #expect(grid.index(at: grid.center(for: index)) == index, "the centre of slot \(index) of \(columns) columns")
            #expect(grid.index(at: CGPoint(x: frame.minX + 1, y: frame.minY + 1)) == index, "just inside the top-left corner")
            #expect(grid.index(at: CGPoint(x: frame.maxX - 1, y: frame.maxY - 1)) == index, "just inside the bottom-right corner")
            if index / columns < grid.rows - 1 {
                #expect(grid.index(at: CGPoint(x: frame.midX, y: frame.maxY + WidgetSlotLayout.gutter / 2)) == nil, "the gutter below")
            }
            if index % columns < columns - 1 {
                #expect(grid.index(at: CGPoint(x: frame.maxX + WidgetSlotLayout.gutter / 2, y: frame.midY)) == nil, "the gutter beside")
            }
        }
        if columns > 1 {
            let empty = grid.frame(for: count)
            #expect(grid.index(at: CGPoint(x: empty.midX, y: empty.midY)) == count - 1, "the short last row's empty slot is the last card's")
        }
        #expect(grid.index(at: CGPoint(x: grid.contentSize.width + 1, y: 10)) == nil, "beyond the right edge")
    }

    @Test func anEmptyOrUnmeasuredGridHasNoSlots() {
        #expect(WidgetSlotLayout.fitting(width: 340, columns: 2, count: 0).index(at: CGPoint(x: 10, y: 10)) == nil)
        #expect(WidgetSlotLayout.fitting(width: 0, columns: 2, count: 4).index(at: CGPoint(x: 0, y: 0)) == nil)
    }

    @Test func theTargetIsTheSlotUnderThePointerButNeverAboveTheShowcase() {
        #expect(layout.target(at: layout.center(for: 3), from: 1, pinned: 1) == 3)
        #expect(layout.target(at: layout.center(for: 0), from: 2, pinned: 1) == 1, "the showcase's slot puts the card right after it")
        #expect(layout.target(at: layout.center(for: 0), from: 2, pinned: 0) == 0, "without a showcase the first slot is open")
        #expect(layout.target(at: CGPoint(x: 170, y: 50), from: 2, pinned: 1) == 2, "a gutter keeps the card where it is")
        #expect(layout.target(at: CGPoint(x: -20, y: 50), from: 3, pinned: 1) == 3, "beside the grid keeps it too")
        #expect(layout.target(at: CGPoint(x: 50, y: 5000), from: 1, pinned: 1) == 4, "below the grid is the last slot")
    }

    @Test func aMoveForwardAndBackKeepsTheOtherCardsInOrder() {
        #expect(WidgetSlotLayout.moved(["a", "b", "c", "d"], from: 0, to: 2) == ["b", "c", "a", "d"])
        #expect(WidgetSlotLayout.moved(["a", "b", "c", "d"], from: 3, to: 0) == ["d", "a", "b", "c"])
        #expect(WidgetSlotLayout.moved(["a", "b", "c", "d"], from: 1, to: 1) == ["a", "b", "c", "d"])
        #expect(WidgetSlotLayout.moved(["a", "b"], from: 5, to: 0) == ["a", "b"], "an index outside the list changes nothing")
    }
}

@Suite struct WidgetShowcaseTests {
    private func row(_ id: String) -> HomeWidget {
        HomeWidget(id: id, title: id, content: .row(RowConfiguration(source: .tmdbDiscover(TMDbDiscoverQuery()))))
    }

    private func showcase(_ id: String) -> HomeWidget {
        HomeWidget(id: id, title: id, content: .hero(RowConfiguration(source: .tmdbDiscover(TMDbDiscoverQuery()))))
    }

    @Test func theShowcaseIsTheOnlyHeroAndIsRecognised() {
        #expect(WidgetsManagerViewModel.isShowcase(showcase("s")))
        #expect(!WidgetsManagerViewModel.isShowcase(row("r")))
    }

    private func continueWatching() -> HomeWidget {
        HomeWidget(id: "cw", title: "Continue", content: .continueWatching)
    }

    @Test func theShowcaseComesFirst() {
        let list = [row("a"), continueWatching(), showcase("s"), row("b")]
        #expect(HomeLayout.normalised(list).map(\.id) == ["s", "a", "cw", "b"])
    }

    @Test func anImportsOtherShowcaseIsKeptAsABanner() {
        let list = [row("a"), showcase("s1"), continueWatching(), row("b"), showcase("s2")]
        let normal = HomeLayout.normalised(list)
        #expect(normal.map(\.id) == ["s1", "a", "cw", "b", "s2"], "no widget is dropped")
        #expect(normal.filter(WidgetsManagerViewModel.isShowcase).map(\.id) == ["s1"])
    }

    @Test func aListWithoutAShowcaseKeepsItsOrder() {
        let list = [row("a"), continueWatching(), row("b")]
        #expect(HomeLayout.normalised(list).map(\.id) == ["a", "cw", "b"])
    }

    @Test func continueWatchingIsNotRemovable() {
        #expect(!WidgetsManagerViewModel.isRemovable(continueWatching()))
        #expect(WidgetsManagerViewModel.isRemovable(row("r")))
        #expect(WidgetsManagerViewModel.isRemovable(showcase("s")))
    }
}
