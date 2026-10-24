import Foundation
import Testing
import PlayerKit
import StremioKit
import StremioKitTestSupport
@testable import Features

/// The Library's filter and sort, as pure functions and through the view model.
@MainActor
@Suite struct LibraryFilterTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 86_400

    private func entry(_ id: String, type: String = "movie", name: String? = nil, year: String? = nil, rating: Double? = nil,
                       genres: [String] = [], added: TimeInterval? = nil, watchedAt: TimeInterval? = nil,
                       records: [WatchProgress] = []) -> LibraryEntry {
        let item = LibraryItem(id: "\(type)/\(id)", type: type, contentID: id, name: name ?? "Title \(id)", releaseInfo: year,
                               addedAt: now.addingTimeInterval(added ?? -100 * day), genres: genres, imdbRating: rating)
        return LibraryEntry(item: item, records: records + (watchedAt.map { [record(id, type: type, age: $0, watched: true)] } ?? []))
    }

    /// A record a little way into a 100-second title, so it is in progress unless `watched` is set.
    private func record(_ id: String, type: String = "movie", age: TimeInterval = 0, watched: Bool = false, position: Double = 40) -> WatchProgress {
        WatchProgress(id: "\(type)/\(id)", type: type, contentID: id, title: "T \(id)", position: position, duration: 100, isWatched: watched,
                      updatedAt: now.addingTimeInterval(age))
    }

    private func ids(_ entries: [LibraryEntry]) -> [String] { entries.map(\.id) }

    // MARK: Pure helpers

    @Test func theYearIsTheFirstFourDigitsOfTheReleaseInfo() {
        #expect(LibraryFiltering.year(from: "1999") == 1999)
        #expect(LibraryFiltering.year(from: "2019-2023") == 2019)
        #expect(LibraryFiltering.year(from: "2020-") == 2020)
        #expect(LibraryFiltering.year(from: "Released 2008") == 2008)
        #expect(LibraryFiltering.year(from: "TBA") == nil)
        #expect(LibraryFiltering.year(from: nil) == nil)
    }

    @Test func typesMapToTheFourKinds() {
        #expect(LibraryKind(type: "movie") == .movie)
        #expect(LibraryKind(type: "Series") == .series)
        #expect(LibraryKind(type: "anime") == .anime)
        #expect(LibraryKind(type: "tv") == .other)
        #expect(LibraryKind(type: "channel") == .other)
    }

    @Test func aSeriesIsInProgressWhileAnyEpisodeIsPartWay() {
        let partWay = record("tt1:1:1", type: "series", age: 0, watched: true)
        let started = record("tt1:1:2", type: "series", age: 0)
        #expect(LibraryFiltering.status(of: [partWay, started]) == .inProgress)
        #expect(LibraryFiltering.status(of: [partWay]) == .watched)
        #expect(LibraryFiltering.status(of: []) == .unwatched)
        #expect(LibraryFiltering.status(of: [record("x", position: 1)]) == .unwatched, "barely started counts as unwatched")
    }

    // MARK: Filters

    @Test func typeAndStatusFiltersAreAny() {
        let movie = entry("m", type: "movie")
        let show = entry("s", type: "series", records: [record("s", type: "series", watched: true)])
        let anime = entry("a", type: "anime")
        var filter = LibraryFilter()
        filter.kinds = [.series, .anime]
        #expect(ids(LibraryFiltering.apply(filter, to: [movie, show, anime], now: now)) == ["anime/a", "series/s"], "ties fall back to title")

        filter = LibraryFilter()
        filter.statuses = [.watched]
        #expect(ids(LibraryFiltering.apply(filter, to: [movie, show, anime], now: now)) == ["series/s"])
    }

    @Test func aYearRangeExcludesTitlesWithoutAYear() {
        let old = entry("1", year: "1985")
        let mid = entry("2", year: "2005-2010")
        let new = entry("3", year: "2021")
        let unknown = entry("4")
        var filter = LibraryFilter()
        filter.minimumYear = 2000
        filter.maximumYear = 2010
        #expect(ids(LibraryFiltering.apply(filter, to: [old, mid, new, unknown], now: now)) == ["movie/2"])

        filter = LibraryFilter()
        filter.minimumYear = 2020
        #expect(ids(LibraryFiltering.apply(filter, to: [old, mid, new, unknown], now: now)) == ["movie/3"], "an open upper bound")
    }

    @Test func genresMatchAnyChosenGenre() {
        let drama = entry("1", genres: ["Drama", "Crime"])
        let comedy = entry("2", genres: ["Comedy"])
        let bare = entry("3")
        var filter = LibraryFilter()
        filter.genres = ["Crime", "Horror"]
        #expect(ids(LibraryFiltering.apply(filter, to: [drama, comedy, bare], now: now)) == ["movie/1"])
    }

    @Test func aRatingThresholdExcludesUnratedTitles() {
        let high = entry("1", rating: 8.2)
        let low = entry("2", rating: 5.0)
        let unrated = entry("3")
        var filter = LibraryFilter()
        filter.minimumRating = 7
        #expect(ids(LibraryFiltering.apply(filter, to: [high, low, unrated], now: now)) == ["movie/1"])
    }

    @Test func theAddedWindowIsMeasuredFromNow() {
        let fresh = entry("1", added: -2 * day)
        let month = entry("2", added: -20 * day)
        let old = entry("3", added: -400 * day)
        var filter = LibraryFilter()
        filter.addedWithin = .lastWeek
        #expect(ids(LibraryFiltering.apply(filter, to: [fresh, month, old], now: now)) == ["movie/1"])
        filter.addedWithin = .lastMonth
        #expect(ids(LibraryFiltering.apply(filter, to: [fresh, month, old], now: now)) == ["movie/1", "movie/2"])
        filter.addedWithin = .anyTime
        #expect(LibraryFiltering.apply(filter, to: [fresh, month, old], now: now).count == 3)
    }

    @Test func filtersCombine() {
        let match = entry("1", type: "series", year: "2015", rating: 8, genres: ["Drama"])
        let wrongGenre = entry("2", type: "series", year: "2015", rating: 8, genres: ["Comedy"])
        let wrongKind = entry("3", type: "movie", year: "2015", rating: 8, genres: ["Drama"])
        var filter = LibraryFilter()
        filter.kinds = [.series]
        filter.genres = ["Drama"]
        filter.minimumYear = 2010
        filter.minimumRating = 7.5
        #expect(ids(LibraryFiltering.apply(filter, to: [match, wrongGenre, wrongKind], now: now)) == ["series/1"])
    }

    // MARK: Sort

    @Test func sortsByEachKeyWithMissingValuesLast() {
        let a = entry("a", year: "2001", rating: 6, added: -3 * day, watchedAt: -1 * day)
        let b = entry("b", year: "2010", rating: 9, added: -1 * day, watchedAt: -3 * day)
        let c = entry("c", name: "Alpha", added: -2 * day)
        let all = [a, b, c]
        #expect(ids(LibraryFiltering.sorted(all, by: .title)) == ["movie/c", "movie/a", "movie/b"], "by title: Alpha, then Title a, Title b")
        #expect(ids(LibraryFiltering.sorted(all, by: .year)) == ["movie/b", "movie/a", "movie/c"], "newest first, the unknown year last")
        #expect(ids(LibraryFiltering.sorted(all, by: .rating)) == ["movie/b", "movie/a", "movie/c"], "highest first, the unrated last")
        #expect(ids(LibraryFiltering.sorted(all, by: .recentlyAdded)) == ["movie/b", "movie/c", "movie/a"])
        #expect(ids(LibraryFiltering.sorted(all, by: .recentlyWatched)) == ["movie/a", "movie/c", "movie/b"], "a title never watched falls back to when it was added")
    }

    // MARK: Chips and clearing

    @Test func eachActiveFilterHasOneChipAndRemovingItClearsIt() {
        var filter = LibraryFilter()
        filter.kinds = [.movie]
        filter.statuses = [.watched]
        filter.minimumYear = 2000
        filter.maximumYear = 2010
        filter.genres = ["Drama"]
        filter.minimumRating = 7.5
        filter.addedWithin = .lastMonth
        filter.sort = .rating
        #expect(filter.chips.map(\.label) == ["Movies", "Watched", "2000–2010", "Drama", "Rating 75+", "Last 30 days"])
        #expect(Set(filter.chips.map(\.id)).count == filter.chips.count, "chip ids are unique")

        for chip in filter.chips { filter.remove(chip.target) }
        #expect(!filter.isNarrowing && filter.chips.isEmpty)
        #expect(filter.sort == .rating, "removing chips leaves the sort alone")
    }

    @Test func aOneSidedYearRangeHasItsOwnChip() {
        var filter = LibraryFilter()
        filter.minimumYear = 1990
        #expect(filter.chips.map(\.label) == ["From 1990"])
        filter = LibraryFilter()
        filter.maximumYear = 1990
        #expect(filter.chips.map(\.label) == ["Until 1990"])
    }

    // MARK: View model

    private func services(progress: [WatchProgress] = [], library: [LibraryItem] = []) -> AppServices {
        let client = makeClient(StubTransport(data: Data()))
        let registry = AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client)
        return AppServices(registry: registry, client: client, settings: InMemorySettingsStore(PlaybackSettings()),
                           progress: InMemoryProgressStore(progress), library: InMemoryLibraryStore(library))
    }

    private func saved(_ id: String, type: String = "movie", year: String? = nil, genres: [String] = [], rating: Double? = nil,
                       added: TimeInterval) -> LibraryItem {
        LibraryItem(id: "\(type)/\(id)", type: type, contentID: id, name: "Name \(id)", releaseInfo: year,
                    addedAt: now.addingTimeInterval(added), genres: genres, imdbRating: rating)
    }

    @Test func aFilterNarrowsEverySectionAndClearingRestoresThem() async {
        let library = [saved("a", year: "2001", genres: ["Drama"], rating: 8, added: -10),
                       saved("b", type: "series", year: "2015", genres: ["Comedy"], rating: 6, added: -20)]
        let progress = [record("a", age: -5), record("c", age: -4), record("d", age: -3, watched: true)]
        let model = LibraryViewModel(services: services(progress: progress, library: library))
        await model.load()
        #expect(model.saved.map(\.contentID) == ["a", "b"])
        #expect(model.watched.map(\.latest.contentID) == ["d"])
        #expect(model.availableGenres == ["Comedy", "Drama"])

        model.filter.kinds = [.series]
        #expect(model.saved.map(\.contentID) == ["b"])
        #expect(model.watched.isEmpty)
        #expect(model.hasMatches && !model.isEmpty)

        model.filter.kinds = []
        model.filter.statuses = [.inProgress]
        #expect(model.saved.map(\.contentID) == ["a"], "a saved title in progress keeps its place")
        #expect(model.watched.isEmpty)

        model.filter.statuses = []
        model.filter.genres = ["Comedy"]
        #expect(model.filter.chips.map(\.label) == ["Comedy"])
        model.removeFilter(model.filter.chips[0])
        #expect(model.saved.count == 2)

        model.filter.minimumRating = 7
        model.filter.minimumYear = 2000
        model.clearFilters()
        #expect(!model.filter.isNarrowing && model.saved.count == 2)
    }

    @Test func aFilterThatMatchesNothingIsNotAnEmptyLibrary() async {
        let model = LibraryViewModel(services: services(library: [saved("a", added: -10)]))
        await model.load()
        model.filter.kinds = [.anime]
        #expect(!model.hasMatches)
        #expect(!model.isEmpty, "the Library still holds a title, so the screen says nothing matches rather than that it is empty")
    }
}
