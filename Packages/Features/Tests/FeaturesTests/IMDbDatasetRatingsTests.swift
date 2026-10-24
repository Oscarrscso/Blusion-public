import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

/// The local IMDb dataset behind the rating badges: what it fills in, when it is read, and what it never overrides.
@MainActor
@Suite struct IMDbDatasetRatingsTests {
    private let movie = MetaPreview(id: "tt0468569", type: "movie", name: "Film", imdbRating: 9)
    private let bare = MetaPreview(id: "tt0468569", type: "movie", name: "Film")

    actor FakeDataset: IMDbDataset {
        var ratings: [String: IMDbRating]
        var outcomes: [IMDbDatasetRefresh]
        var episodeMappings: [Int: String] = [:]
        private(set) var lookups: [String] = []
        private(set) var refreshes = 0

        init(ratings: [String: IMDbRating] = [:], outcomes: [IMDbDatasetRefresh] = []) {
            self.ratings = ratings
            self.outcomes = outcomes
        }

        func episodeIDs(for seriesID: String, season: Int) -> [Int: String] { episodeMappings }
        func setEpisodeMappings(_ value: [Int: String]) { episodeMappings = value }

        func rating(for imdbID: String) -> IMDbRating? {
            lookups.append(imdbID)
            return ratings[imdbID]
        }

        func status() -> IMDbDatasetStatus? { IMDbDatasetStatus(titleCount: ratings.count, updatedAt: nil, checkedAt: nil) }

        func refreshIfNeeded() -> IMDbDatasetRefresh {
            refreshes += 1
            return outcomes.isEmpty ? .skipped : outcomes.removeFirst()
        }

        func set(_ rating: IMDbRating) { ratings[rating.imdbID] = rating }
        var lookupCount: Int { lookups.count }
    }

    private func entry(_ id: String, _ rating: Double, votes: Int = 1_000) -> IMDbRating { IMDbRating(imdbID: id, rating: rating, votes: votes) }

    @Test func theDatasetScoreFillsATitleTheCatalogHasNoScoreFor() async throws {
        let dataset = FakeDataset(ratings: ["tt0468569": entry("tt0468569", 8.1, votes: 2_900_000)])
        let store = PosterRatingsStore(dataset: dataset)
        let ratings = store.ratings(for: bare)
        #expect(ratings.imdb == nil, "asking from a view body must not synchronously change an observed rating")
        try await waitUntil { ratings.imdb == 8.1 }
        #expect(ratings.imdbVotes == 2_900_000 && ratings.imdbText == "81")
    }

    @Test func theDatasetIsIMDbsOwnNumberSoItWinsOverTheCatalogs() async throws {
        let dataset = FakeDataset(ratings: ["tt0468569": entry("tt0468569", 8.1)])
        let store = PosterRatingsStore(dataset: dataset)
        let ratings = store.ratings(for: movie)
        try await waitUntil { ratings.imdb == 8.1 }
        // The catalog's number arrives again with every list that shows the title: it must not win it back.
        for _ in 0..<5 { _ = store.ratings(for: movie) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(ratings.imdb == 8.1)
    }

    @Test func aTitleTheDatasetLacksKeepsTheCatalogScore() async throws {
        let store = PosterRatingsStore(dataset: FakeDataset())
        let ratings = store.ratings(for: movie)
        try await Task.sleep(for: .milliseconds(50))
        #expect(ratings.imdb == 9 && ratings.imdbVotes == nil)
    }

    @Test func aTitleIsReadOnceHoweverOftenItIsAskedFor() async throws {
        let dataset = FakeDataset(ratings: ["tt0468569": entry("tt0468569", 8.1)])
        let store = PosterRatingsStore(dataset: dataset)
        let ratings = store.ratings(for: bare)
        for _ in 0..<50 { _ = store.ratings(for: bare) }
        try await waitUntil { ratings.imdb == 8.1 }
        _ = store.ratings(for: bare)
        #expect(await dataset.lookupCount == 1)
    }

    @Test func otherSitesFiltersAndSwitchedOffPostersDoNotReadIt() async throws {
        let dataset = FakeDataset(ratings: ["tt0468569": entry("tt0468569", 8.1)])
        let store = PosterRatingsStore(isEnabled: false, dataset: dataset)
        _ = store.ratings(for: bare)
        _ = store.ratings(for: MetaPreview(id: "kitsu:1", type: "movie"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await dataset.lookupCount == 0)
        let reviews = store.ratings(for: bare, includeReviews: true)
        try await waitUntil { reviews.imdb == 8.1 }

        let letterboxdOnly = PosterRatingsStore(dataset: dataset)
        _ = letterboxdOnly.ratings(for: MetaPreview(id: "tt0111161", type: "movie"), source: .letterboxd)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await dataset.lookupCount == 1)
    }

    @Test func aFreshDownloadIsReadAgainAndRedrawsVisibleTitles() async throws {
        let dataset = FakeDataset(ratings: ["tt0468569": entry("tt0468569", 8.1)], outcomes: [.updated(titles: 5)])
        let store = PosterRatingsStore(dataset: dataset)
        let ratings = store.ratings(for: bare)
        try await waitUntil { ratings.imdb == 8.1 }
        await dataset.set(entry("tt0468569", 8.2))

        let before = store.reviewServicesRevision
        await store.refreshIMDbDataset()
        #expect(store.reviewServicesRevision == before + 1, "views ask again")
        _ = store.ratings(for: bare)
        try await waitUntil { ratings.imdb == 8.2 }
        #expect(await dataset.lookupCount == 2)
    }

    @Test func aCheckThatChangesNothingDisturbsNothing() async throws {
        let dataset = FakeDataset(ratings: ["tt0468569": entry("tt0468569", 8.1)],
                                  outcomes: [.skipped, .notModified, .failed("offline")])
        let store = PosterRatingsStore(dataset: dataset)
        let ratings = store.ratings(for: bare)
        try await waitUntil { ratings.imdb == 8.1 }
        let before = store.reviewServicesRevision
        for _ in 0..<3 { await store.refreshIMDbDataset() }
        _ = store.ratings(for: bare)
        #expect(store.reviewServicesRevision == before && ratings.imdb == 8.1)
        let refreshes = await dataset.refreshes
        let lookups = await dataset.lookupCount
        #expect(refreshes == 3 && lookups == 1)
    }

    @Test func withoutADatasetNothingChanges() async throws {
        let store = PosterRatingsStore()
        await store.refreshIMDbDataset()
        #expect(await store.imdbDatasetStatus() == nil)
        let ratings = store.ratings(for: movie)
        try await waitUntil { ratings.imdb == 9 }
    }

    @Test func settingsShowsWhatTheDeviceHolds() {
        #expect(IMDbDatasetSummary.text(nil) == "Downloading soon")
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(IMDbDatasetSummary.text(IMDbDatasetStatus(titleCount: 1_719_427, updatedAt: day, checkedAt: nil)).hasPrefix("1,719,427 titles"))
        #expect(IMDbDatasetSummary.text(IMDbDatasetStatus(titleCount: 12, updatedAt: nil, checkedAt: nil)) == "12 titles")
        let sized = IMDbDatasetStatus(titleCount: 1_234_567, updatedAt: day, checkedAt: nil, fileSize: 48_000_000)
        #expect(IMDbDatasetSummary.text(sized).hasPrefix("1,234,567 titles · "))
        #expect(IMDbDatasetSummary.text(sized).hasSuffix(" · " + Int64(48_000_000).formatted(.byteCount(style: .file))))
        #expect(IMDbDatasetSummary.text(IMDbDatasetStatus(titleCount: 12, updatedAt: nil, checkedAt: nil, fileSize: 2_000_000))
                == "12 titles · " + Int64(2_000_000).formatted(.byteCount(style: .file)))
    }
}
