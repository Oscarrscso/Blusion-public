import Foundation
import Testing
@testable import Features

@Suite struct LazyLoadLookaheadTests {
    private func defaults(saving level: Int? = nil) -> UserDefaults {
        let name = "LazyLoadLookaheadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        if let level { defaults.set(level, forKey: LazyLoadLookahead.defaultsKey) }
        return defaults
    }

    @Test func titlesPerLevel() {
        #expect(LazyLoadLookahead.levels.map(\.titles) == [12, 24, 48])
        #expect(LazyLoadLookahead.levels.map(\.label) == ["Near", "Balanced", "Far"])
        #expect([1, 2, 3].map { LazyLoadLookahead.titles(atLevel: $0) } == [12, 24, 48])
    }

    @Test func defaultsToBalancedWhenNothingIsSaved() {
        #expect(LazyLoadLookahead.level(in: defaults()) == 2)
        #expect(LazyLoadLookahead.titlesAhead(in: defaults()) == 24)
    }

    @Test func savedLevelIsClampedToTheRange() {
        #expect(LazyLoadLookahead.level(in: defaults(saving: 1)) == 1)
        #expect(LazyLoadLookahead.level(in: defaults(saving: 3)) == 3)
        #expect(LazyLoadLookahead.level(in: defaults(saving: 0)) == 1)
        #expect(LazyLoadLookahead.level(in: defaults(saving: -4)) == 1)
        #expect(LazyLoadLookahead.level(in: defaults(saving: 9)) == 3)
        #expect(LazyLoadLookahead.titles(atLevel: 0) == 12)
        #expect(LazyLoadLookahead.titles(atLevel: 7) == 48)
    }

    @Test func triggerIndexPerLevel() {
        #expect(LazyLoadLookahead.triggerIndex(count: 100, in: defaults(saving: 1)) == 87)
        #expect(LazyLoadLookahead.triggerIndex(count: 100, in: defaults(saving: 2)) == 75)
        #expect(LazyLoadLookahead.triggerIndex(count: 100, in: defaults(saving: 3)) == 51)
    }

    @Test func triggerIndexOfShortListsIsTheStart() {
        #expect(LazyLoadLookahead.triggerIndex(count: 0, in: defaults(saving: 3)) == 0)
        #expect(LazyLoadLookahead.triggerIndex(count: 5, in: defaults(saving: 3)) == 0)
        #expect(LazyLoadLookahead.triggerIndex(count: 49, in: defaults(saving: 3)) == 0)
        #expect(LazyLoadLookahead.triggerIndex(count: 50, in: defaults(saving: 3)) == 1)
    }

    @Test func bufferRangeSurroundsTheVisibleTitles() {
        #expect(LazyLoadLookahead.bufferRange(visible: 30...41, count: 100, titles: 9) == 21...50)
        #expect(LazyLoadLookahead.bufferRange(visible: 30...41, count: 100, titles: 18) == 12...59)
    }

    @Test func bufferRangeIsClampedToTheList() {
        #expect(LazyLoadLookahead.bufferRange(visible: 0...5, count: 100, titles: 9) == 0...14)
        #expect(LazyLoadLookahead.bufferRange(visible: 90...99, count: 100, titles: 18) == 72...99)
        #expect(LazyLoadLookahead.bufferRange(visible: 0...2, count: 4, titles: 3) == 0...3)
    }

    @Test func bufferRangeIsNilWithoutTitles() {
        #expect(LazyLoadLookahead.bufferRange(visible: 0...2, count: 0, titles: 3) == nil)
        #expect(LazyLoadLookahead.bufferRange(visible: 50...60, count: 10, titles: 3) == nil)
    }

    // A grid of 10 titles, 3 columns: 4 rows. Rows 100 pt high with 10 pt spacing: height 430, pitch 110.
    private func visible(_ minY: CGFloat, _ maxY: CGFloat, height: CGFloat = 430, columns: Int = 3, count: Int = 10) -> ClosedRange<Int>? {
        LazyLoadLookahead.visibleItems(viewportMinY: minY, viewportMaxY: maxY, gridHeight: height, rowSpacing: 10, columns: columns,
                                       count: count)
    }

    @Test func visibleItemsAtTheTop() {
        #expect(visible(0, 100) == 0...2)
        #expect(visible(-300, 150) == 0...5)
    }

    @Test func visibleItemsInTheMiddle() {
        #expect(visible(120, 200) == 3...5)
        #expect(visible(105, 230) == 3...8)
    }

    @Test func visibleItemsAtTheBottomStopAtTheLastTitle() {
        #expect(visible(330, 430) == 9...9)
        #expect(visible(215, 900) == 6...9)
    }

    @Test func visibleItemsPartialRowsCount() {
        #expect(visible(95, 115) == 0...5)
        // A viewport inside the gap below row 0 sees no row: it starts at row 1.
        #expect(visible(105, 109) == 3...5)
    }

    @Test func visibleItemsOutsideTheGridAreNil() {
        #expect(visible(-500, -1) == nil)
        #expect(visible(430, 900) == nil)
        #expect(visible(600, 900) == nil)
    }

    @Test func visibleItemsOneColumnAndUnevenCounts() {
        #expect(visible(0, 100, height: 430, columns: 1, count: 4) == 0...0)
        #expect(visible(0, 440, height: 430, columns: 1, count: 4) == 0...3)
        // 7 titles in 3 columns is 3 rows; the last row holds one title.
        #expect(visible(0, 330, height: 320, columns: 3, count: 7) == 0...6)
    }

    @Test func visibleItemsRejectNonPositiveSizes() {
        #expect(visible(0, 100, height: 0) == nil)
        #expect(visible(0, 100, height: -5) == nil)
        #expect(visible(0, 100, columns: 0) == nil)
        #expect(visible(0, 100, count: 0) == nil)
        #expect(visible(50, 50) == nil)
        #expect(visible(80, 20) == nil)
    }
}
