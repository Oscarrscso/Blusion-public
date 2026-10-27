import Foundation
import Testing
import StremioKit
@testable import Features

private func preview(_ id: String, _ type: String = "series", name: String? = nil, year: String? = nil, rating: Double? = nil) -> MetaPreview {
    var item = MetaPreview(id: id, type: type, name: name ?? id)
    item.releaseInfo = year
    item.imdbRating = rating
    return item
}

struct CatalogListFilterTests {
    private let items = [
        preview("a", name: "Futurama", year: "1999-2013", rating: 8.5),
        preview("b", "movie", name: "Akira", year: "1988", rating: 8.0),
        preview("c", name: "Invincible", year: "2021-", rating: 8.7),
        preview("d", name: "Unrated"),
    ]

    @Test func defaultKeepsTheSourceOrder() {
        #expect(CatalogListFiltering.apply(CatalogListFilter(), to: items).map(\.id) == ["a", "b", "c", "d"])
    }

    @Test func topRatedPutsUnratedLast() {
        #expect(CatalogListFiltering.apply(CatalogListFilter(sort: .rating), to: items).map(\.id) == ["c", "a", "b", "d"])
    }

    @Test func newestAndOldestUseTheFirstReleaseYear() {
        #expect(CatalogListFiltering.apply(CatalogListFilter(sort: .newest), to: items).map(\.id) == ["c", "a", "b", "d"])
        #expect(CatalogListFiltering.apply(CatalogListFilter(sort: .oldest), to: items).map(\.id) == ["b", "a", "c", "d"])
    }

    @Test func titleSortsAlphabetically() {
        #expect(CatalogListFiltering.apply(CatalogListFilter(sort: .title), to: items).map(\.id) == ["b", "a", "c", "d"])
    }

    @Test func shuffleFollowsItsRanksAndUnrankedGoLast() {
        let ranks = ["series/c": 0, "series/a": 1, "movie/b": 2]
        #expect(CatalogListFiltering.apply(CatalogListFilter(sort: .shuffle), to: items, shuffleRank: ranks).map(\.id) == ["c", "a", "b", "d"])
    }

    @Test func shuffleRanksCoverEveryItemOnce() {
        var generator = SystemRandomNumberGenerator()
        let ranks = CatalogListFiltering.shuffleRanks(for: items, from: 10, using: &generator)
        #expect(Set(ranks.values) == Set(10..<14))
        #expect(Set(ranks.keys) == Set(items.map(\.identity)))
    }

    @Test func filtersByTypeYearAndRating() {
        #expect(CatalogListFiltering.apply(CatalogListFilter(type: "movie"), to: items).map(\.id) == ["b"])
        #expect(CatalogListFiltering.apply(CatalogListFilter(minimumYear: 1990, maximumYear: 1999), to: items).map(\.id) == ["a"])
        #expect(CatalogListFiltering.apply(CatalogListFilter(minimumRating: 8.5), to: items).map(\.id) == ["a", "c"])
    }

    @Test func yearLabelNamesRecentWindowsAndDecades() {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 26))!
        let recent = CatalogListRecent.lastFive.years(now: now)
        #expect(recent == 2022...2026)
        #expect(CatalogListFilter(minimumYear: 2022, maximumYear: 2026).yearLabel(now: now) == "Last 5 Years")
        #expect(CatalogListFilter(minimumYear: 1990, maximumYear: 1999).yearLabel(now: now) == "1990s")
        #expect(CatalogListFilter().yearLabel(now: now) == nil)
    }
}
