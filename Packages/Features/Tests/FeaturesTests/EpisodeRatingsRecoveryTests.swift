import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

@MainActor
@Suite struct EpisodeRatingsRecoveryTests {
    private let seriesID = "tt0944947"
    private let key = "omdb:tt0944947:s1"
    private let when = Date(timeIntervalSince1970: 1_800_000_000)
    private let season = Data(#"""
    {"Response":"True","Episodes":[
      {"Episode":"1","imdbRating":"N/A","imdbID":"tt1480055"},
      {"Episode":"2","imdbRating":"8.0","imdbID":"tt1668746"},
      {"Episode":"3","imdbRating":"7.5","imdbID":"tt1668747"},
      {"Episode":"4","imdbRating":"N/A","imdbID":"tt1668748"}]}
    """#.utf8)

    private func omdb(_ transport: StubTransport) -> OMDbRatings {
        // Independent daily allowance; other test suites must not spend this one's quota.
        let defaults = UserDefaults(suiteName: "EpisodeRatingsRecoveryTests.\(UUID().uuidString)") ?? .standard
        return OMDbRatings(client: makeClient(transport, retries: 0), apiKey: "test-key", usage: OMDbUsage(defaults: defaults))
    }

    @Test func completelyOfflineEpisodeScoresNeedNoOMDbKey() async {
        let dataset = IMDbDatasetRatingsTests.FakeDataset(ratings: [
            "tt1480055": IMDbRating(imdbID: "tt1480055", rating: 9.1, votes: 100),
            "tt1668746": IMDbRating(imdbID: "tt1668746", rating: 8.8, votes: 100)
        ])
        await dataset.setEpisodeMappings([1: "tt1480055", 2: "tt1668746"])
        let store = PosterRatingsStore(cache: InMemoryRatingsCache(), now: { when }, dataset: dataset)
        #expect(await store.episodeRatings(for: seriesID, season: 1, expectedEpisodes: [1, 2]) == [1: 9.1, 2: 8.8])
        #expect(await dataset.lookupCount == 2)
    }

    @Test func aCompleteOfflineSeasonNeverRequestsOMDb() async {
        let dataset = IMDbDatasetRatingsTests.FakeDataset(ratings: [
            "tt1480055": IMDbRating(imdbID: "tt1480055", rating: 9.1, votes: 100)
        ])
        await dataset.setEpisodeMappings([1: "tt1480055"])
        let transport = StubTransport(data: season)
        let store = PosterRatingsStore(cache: InMemoryRatingsCache(), now: { when }, omdb: omdb(transport), dataset: dataset)
        #expect(await store.episodeRatings(for: seriesID, season: 1, expectedEpisodes: [1]) == [1: 9.1])
        #expect(transport.callCount == 0)
    }

    @Test func aNewOfflineIdentityRepairsStaleCachedScore() async {
        let cache = InMemoryRatingsCache()
        await cache.store(CachedRating(rating: nil, fetchedAt: when, episodes: [1: 2.0],
                                       episodeIDs: [1: "tt0000001"], episodeNumbers: [1]), for: key)
        let dataset = IMDbDatasetRatingsTests.FakeDataset(ratings: [
            "tt1480055": IMDbRating(imdbID: "tt1480055", rating: 9.1, votes: 100)
        ])
        await dataset.setEpisodeMappings([1: "tt1480055"])
        let store = PosterRatingsStore(cache: cache, now: { when }, dataset: dataset)
        #expect(await store.episodeRatings(for: seriesID, season: 1, expectedEpisodes: [1]) == [1: 9.1])
        #expect(await cache.value(for: key)?.episodeIDs?[1] == "tt1480055")
    }

    @Test(arguments: [nil, Set([3])] as [Set<Int>?])
    func enrichingCachedEpisodesRetainsKnownNumbers(_ knownNumbers: Set<Int>?) async throws {
        let cache = InMemoryRatingsCache()
        let fetchedAt = when.addingTimeInterval(-600)
        await cache.store(CachedRating(rating: nil, fetchedAt: fetchedAt, episodes: [3: 7.5],
                                       episodeNumbers: knownNumbers), for: key)
        let dataset = IMDbDatasetRatingsTests.FakeDataset(ratings: [
            "tt1480055": IMDbRating(imdbID: "tt1480055", rating: 9.1, votes: 100)
        ])
        await dataset.setEpisodeMappings([1: "tt1480055"])
        let store = PosterRatingsStore(cache: cache, now: { when }, dataset: dataset)

        #expect(await store.episodeRatings(for: seriesID, season: 1) == [1: 9.1, 3: 7.5])
        let stored = try #require(await cache.value(for: key))
        #expect(stored.episodeNumbers == (knownNumbers ?? []).union([1]))
        #expect(stored.episodeIDs == [1: "tt1480055"])
        #expect(stored.fetchedAt == fetchedAt)
    }

    @Test func incompleteOfflineIndexCanStillUseOMDbFallback() async {
        let dataset = IMDbDatasetRatingsTests.FakeDataset(ratings: [
            "tt1480055": IMDbRating(imdbID: "tt1480055", rating: 9.1, votes: 100)
        ])
        await dataset.setEpisodeMappings([1: "tt1480055"])
        let transport = StubTransport(data: season)
        let store = PosterRatingsStore(cache: InMemoryRatingsCache(), now: { when }, omdb: omdb(transport), dataset: dataset)
        let scores = await store.episodeRatings(for: seriesID, season: 1, expectedEpisodes: [1, 2, 3])
        #expect(scores[1] == 9.1 && scores[2] == 8.0 && scores[3] == 7.5)
        #expect(transport.callCount == 1)
    }

    @Test func datasetFillsNAsAndOverridesStaleOMDbScoresWithOneSeasonRequest() async throws {
        let dataset = IMDbDatasetRatingsTests.FakeDataset(ratings: [
            "tt1480055": IMDbRating(imdbID: "tt1480055", rating: 9.1, votes: 100),
            "tt1668746": IMDbRating(imdbID: "tt1668746", rating: 8.8, votes: 100)
        ])
        let cache = InMemoryRatingsCache()
        let transport = StubTransport(data: season)
        let store = PosterRatingsStore(cache: cache, now: { when }, omdb: omdb(transport), dataset: dataset)
        async let a = store.episodeRatings(for: seriesID, season: 1)
        async let b = store.episodeRatings(for: seriesID, season: 1)
        let (first, second) = await (a, b)
        #expect(first == [1: 9.1, 2: 8.8, 3: 7.5] && first == second)
        #expect(await store.episodeRatings(for: seriesID, season: 1) == first)
        #expect(transport.callCount == 1)
        #expect(await dataset.lookupCount == 4, "one indexed local read per known episode, shared across cards")
        let stored = try #require(await cache.value(for: key))
        #expect(stored.episodeIDs?[4] == "tt1668748", "unrated identities survive in the cache")
        #expect(stored.episodes == first)
    }

    @Test func cachedIdentitiesWorkWithoutAKeyAndRecheckAfterTheDatasetArrives() async throws {
        let cache = InMemoryRatingsCache()
        await cache.store(CachedRating(rating: nil, fetchedAt: when, episodes: [:],
                                       episodeIDs: [1: "tt1480055"], episodeNumbers: [1]), for: key)
        let dataset = IMDbDatasetRatingsTests.FakeDataset(outcomes: [.updated(titles: 1)])
        let store = PosterRatingsStore(cache: cache, now: { when }, dataset: dataset)
        #expect(await store.episodeRatings(for: seriesID, season: 1).isEmpty)
        await dataset.set(IMDbRating(imdbID: "tt1480055", rating: 9.1, votes: 100))
        await store.refreshIMDbDataset()
        #expect(await store.episodeRatings(for: seriesID, season: 1) == [1: 9.1])
        #expect(await dataset.lookupCount == 2)
        let stored = try #require(await cache.value(for: key))
        #expect(stored.episodes == [1: 9.1] && stored.fetchedAt == when)
        let offline = PosterRatingsStore(cache: cache, now: { when.addingTimeInterval(90_000) })
        #expect(await offline.episodeRatings(for: seriesID, season: 1) == [1: 9.1])
    }

    @Test func oldScoreOnlyCachesUpgradeOnceWithoutWaitingADay() async throws {
        let cache = InMemoryRatingsCache()
        await cache.store(CachedRating(rating: nil, fetchedAt: when, episodes: [3: 7.4]), for: key)
        let dataset = IMDbDatasetRatingsTests.FakeDataset(ratings: [
            "tt1480055": IMDbRating(imdbID: "tt1480055", rating: 9.1, votes: 100)
        ])
        let transport = StubTransport(data: season)
        let store = PosterRatingsStore(cache: cache, now: { when }, omdb: omdb(transport), dataset: dataset)
        #expect(await store.episodeRatings(for: seriesID, season: 1) == [1: 9.1, 2: 8.0, 3: 7.5])
        _ = await store.episodeRatings(for: seriesID, season: 1)
        #expect(transport.callCount == 1)
    }

    @Test func partialSeasonsRetryHourlyAndRetainScoresMissingFromTheNewAnswer() async throws {
        let clock = EpisodeRatingsClock(when)
        let cache = InMemoryRatingsCache()
        await cache.store(CachedRating(rating: nil, fetchedAt: when, episodes: [1: 9.1],
                                       episodeIDs: [1: "tt1480055", 2: "tt1668746"], episodeNumbers: [1, 2]), for: key)
        let data = Data((#"{"Response":"True","Episodes":[{"Episode":"1","imdbRating":"N/A","imdbID":"tt1480055"},"#
                         + #"{"Episode":"2","imdbRating":"8.8","imdbID":"tt1668746"}]}"#).utf8)
        let transport = StubTransport(data: data)
        let store = PosterRatingsStore(cache: cache, now: { clock.date }, omdb: omdb(transport))
        clock.advance(3_599)
        #expect(await store.episodeRatings(for: seriesID, season: 1) == [1: 9.1])
        #expect(transport.callCount == 0)
        clock.advance(1)
        #expect(await store.episodeRatings(for: seriesID, season: 1) == [1: 9.1, 2: 8.8])
        #expect(transport.callCount == 1)
    }

    @Test func episodesOmittedEntirelyByOMDbStillMakeTheSeasonIncomplete() async throws {
        let clock = EpisodeRatingsClock(when)
        let transport = StubTransport(data: Data(#"{"Response":"True","Episodes":[{"Episode":"1","imdbRating":"9.1"}]}"#.utf8))
        let store = PosterRatingsStore(now: { clock.date }, omdb: omdb(transport))
        _ = await store.episodeRatings(for: seriesID, season: 1, expectedEpisodes: [1, 2])
        clock.advance(3_600)
        _ = await store.episodeRatings(for: seriesID, season: 1, expectedEpisodes: [1, 2])
        #expect(transport.callCount == 2)
    }

    @Test func completeSeasonsDoNotRequestAgainBeforeADay() async throws {
        let clock = EpisodeRatingsClock(when)
        let transport = StubTransport(data: Data(#"{"Response":"True","Episodes":[{"Episode":"1","imdbRating":"9.1"}]}"#.utf8))
        let store = PosterRatingsStore(now: { clock.date }, omdb: omdb(transport))
        _ = await store.episodeRatings(for: seriesID, season: 1)
        clock.advance(86_399)
        _ = await store.episodeRatings(for: seriesID, season: 1)
        #expect(transport.callCount == 1)
        clock.advance(1)
        _ = await store.episodeRatings(for: seriesID, season: 1)
        #expect(transport.callCount == 2)
    }

    @Test func anEpisodeIdentityCorrectionDoesNotCarryOverTheWrongRating() async throws {
        let cache = InMemoryRatingsCache()
        await cache.store(CachedRating(rating: nil, fetchedAt: when.addingTimeInterval(-90_000), episodes: [1: 9.1],
                                       episodeIDs: [1: "tt1480055"], episodeNumbers: [1]), for: key)
        let transport = StubTransport(data: Data(#"{"Response":"True","Episodes":[{"Episode":"1","imdbRating":"N/A","imdbID":"tt1668746"}]}"#.utf8))
        let store = PosterRatingsStore(cache: cache, now: { when }, omdb: omdb(transport))
        #expect(await store.episodeRatings(for: seriesID, season: 1).isEmpty)
    }

    @Test func aFailedLookupCanRecoverOnTheSameDetailPageAfterBackoff() async throws {
        let clock = EpisodeRatingsClock(when)
        let transport = StubTransport { request, call in
            if call == 1 { throw AddonError.offline }
            return StubTransport.response(Data(#"{"Response":"True","Episodes":[{"Episode":"1","imdbRating":"9.1"}]}"#.utf8), for: request)
        }
        let client = makeClient(transport, retries: 0)
        let ratings = PosterRatingsStore(now: { clock.date }, omdb: omdb(transport))
        let services = AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client),
                                   client: client, posterRatings: ratings)
        let model = DetailViewModel(preview: MetaPreview(id: seriesID, type: "series"), services: services)
        let video = Video(id: "tt0944947:1:1", season: 1, episode: 1)
        await model.loadEpisodeScores(season: 1)
        #expect(model.score(for: video) == nil)
        clock.advance(59)
        await model.loadEpisodeScores(season: 1)
        #expect(transport.callCount == 1)
        clock.advance(1)
        await model.loadEpisodeScores(season: 1)
        #expect(model.score(for: video) == .init(value: 9.1, isIMDb: true))
        #expect(transport.callCount == 2)
    }
}

private final class EpisodeRatingsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var date: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
