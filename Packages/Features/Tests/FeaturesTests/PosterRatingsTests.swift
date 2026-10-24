import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

@MainActor
@Suite struct PosterRatingsTests {
    private let movie = MetaPreview(id: "tt0468569", type: "movie", name: "Film", imdbRating: 9)
    private let page = Data(#"<meta name="twitter:data2" content="4.5 out of 5">"#.utf8)
    private let when = Date(timeIntervalSince1970: 1_800_000_000)
    private let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ0ZXN0In0.signature"
    private let tmdbFindMovie = Data(#"{"movie_results":[{"id":155,"vote_average":9.1,"vote_count":20}],"tv_results":[]}"#.utf8)
    private let tmdbFindTV = Data(#"{"movie_results":[],"tv_results":[{"id":1399,"vote_average":8.4,"vote_count":50}]}"#.utf8)

    private func store(_ transport: StubTransport, cache: any RatingsCache = InMemoryRatingsCache(), enabled: Bool = true,
                       now: @escaping @Sendable () -> Date = { Date() }) -> PosterRatingsStore {
        PosterRatingsStore(isEnabled: enabled, letterboxd: LetterboxdRatings(client: makeClient(transport, retries: 0)), cache: cache, now: now)
    }

    @Test func entriesAreStablePerTypeAndIDAndFillIMDbAsynchronously() async throws {
        let store = PosterRatingsStore()
        let missing = MetaPreview(id: movie.id, type: "movie")
        let first = store.ratings(for: missing)
        let second = store.ratings(for: movie)
        let same = first === second
        #expect(same)
        #expect(first.imdb == nil, "asking from a view body must not synchronously change an observed rating")
        try await waitUntil { first.imdb == 9 }
        let series = store.ratings(for: MetaPreview(id: movie.id, type: "series"))
        let different = first !== series
        #expect(different)
    }

    @Test func aMovieIsLookedUpOnlyOnceAndFormatsBothRatings() async throws {
        let transport = StubTransport(data: page, status: 206)
        let store = store(transport)
        let entry = store.ratings(for: movie)
        for _ in 0..<50 { _ = store.ratings(for: movie) }
        try await waitUntil { entry.letterboxd == 4.5 }
        _ = store.ratings(for: movie)
        #expect(transport.callCount == 1)
        #expect(entry.imdbText == "90" && entry.letterboxdText == "90", "whole numbers out of 100, never a decimal")
        #expect(entry.text(for: .letterboxd) == "90/100")
        #expect(!entry.isEmpty)
    }

    @Test func aSpecificFilterScoreDoesNotQueueUnrelatedProviders() async throws {
        let transport = StubTransport(data: page)
        let store = store(transport)
        let entry = store.ratings(for: movie, source: .imdb)
        try await Task.sleep(for: .milliseconds(30))
        #expect(entry.imdb == 9 && transport.callCount == 0)
        _ = store.ratings(for: movie, source: .letterboxd)
        try await waitUntil { entry.letterboxd == 4.5 }
        #expect(transport.callCount == 1)
    }

    @Test func seriesInvalidIDsAndDisabledRatingsNeverRequest() async throws {
        let transport = StubTransport(data: page)
        let store = store(transport)
        _ = store.ratings(for: MetaPreview(id: movie.id, type: "series"))
        _ = store.ratings(for: MetaPreview(id: "kitsu:1", type: "movie"))
        store.isEnabled = false
        let entry = store.ratings(for: movie)
        try await Task.sleep(for: .milliseconds(50))
        #expect(entry.imdb == 9 && entry.letterboxd == nil)
        #expect(transport.callCount == 0)
        store.isEnabled = true
        _ = store.ratings(for: movie)
        try await waitUntil { entry.letterboxd == 4.5 }
        #expect(transport.callCount == 1)
    }

    @Test func aFreshCachedRatingSkipsTheRequest() async throws {
        let cache = InMemoryRatingsCache()
        await cache.store(CachedRating(rating: 4, fetchedAt: when.addingTimeInterval(-6 * 86_400)), for: movie.id)
        let transport = StubTransport(data: page)
        let store = store(transport, cache: cache, now: { when })
        let entry = store.ratings(for: movie)
        try await waitUntil { entry.letterboxd == 4 }
        #expect(transport.callCount == 0)
    }

    @Test func cachedDetailScoresDoNotWaitForBusyNetworkWorkers() async throws {
        let cache = InMemoryRatingsCache()
        await cache.store(CachedRating(rating: 4, fetchedAt: when), for: movie.id)
        let transport = StubTransport { request, _ in
            try await Task.sleep(for: .seconds(2))
            return StubTransport.response(Data(#"<meta name="twitter:data2" content="4.5">"#.utf8), for: request)
        }
        let store = store(transport, cache: cache, now: { self.when })
        for n in 0..<10 { _ = store.ratings(for: MetaPreview(id: "tt10000\(n)", type: "movie")) }
        try await waitUntil { transport.callCount == 3 }
        let cached = store.ratings(for: movie, includeReviews: true)
        try await waitUntil(timeout: 0.5) { cached.letterboxd == 4 }
        #expect(transport.callCount == 3)
        await store.refresh()
    }

    @Test func sevenDayOldRatingsAreRefetched() async throws {
        let cache = InMemoryRatingsCache()
        await cache.store(CachedRating(rating: 4, fetchedAt: when.addingTimeInterval(-7 * 86_400)), for: movie.id)
        let transport = StubTransport(data: page)
        let store = store(transport, cache: cache, now: { when })
        let entry = store.ratings(for: movie)
        try await waitUntil { entry.letterboxd == 4.5 }
        let saved = await cache.value(for: movie.id)
        #expect(transport.callCount == 1)
        #expect(saved == CachedRating(rating: 4.5, fetchedAt: when))
    }

    @Test func noRatingAnswersExpireAfterAnHourInTheSameSession() async throws {
        let clock = RatingsTestState(now: when)
        let cache = InMemoryRatingsCache()
        await cache.store(CachedRating(rating: nil, fetchedAt: when.addingTimeInterval(-1_800)), for: movie.id)
        let transport = StubTransport(data: page)
        let store = store(transport, cache: cache, now: { clock.date })
        let entry = store.ratings(for: movie)
        try await Task.sleep(for: .milliseconds(50))
        #expect(entry.letterboxd == nil && transport.callCount == 0)
        clock.advance(1_800)
        _ = store.ratings(for: movie)
        try await waitUntil { entry.letterboxd == 4.5 }
        #expect(transport.callCount == 1)
    }

    @Test func successfulEmptyAnswersAreCached() async throws {
        let cache = InMemoryRatingsCache()
        let transport = StubTransport(data: Data("<head></head>".utf8))
        let store = store(transport, cache: cache, now: { when })
        _ = store.ratings(for: movie)
        try await waitUntil { transport.callCount == 1 }
        try await Task.sleep(for: .milliseconds(20))
        let stored = await cache.value(for: movie.id)
        #expect(stored == CachedRating(rating: nil, fetchedAt: when))
    }

    @Test func failuresAreNotCachedAndCanRetryAfterAMinute() async throws {
        let clock = RatingsTestState(now: when)
        let cache = InMemoryRatingsCache()
        let transport = StubTransport { request, call in
            if call == 1 { throw AddonError.offline }
            return StubTransport.response(Data(#"<meta name="twitter:data2" content="4.5">"#.utf8), for: request)
        }
        let store = store(transport, cache: cache, now: { clock.date })
        let entry = store.ratings(for: movie)
        try await waitUntil { transport.callCount == 1 }
        try await Task.sleep(for: .milliseconds(20))
        let stored = await cache.value(for: movie.id)
        #expect(stored == nil)
        clock.advance(59)
        _ = store.ratings(for: movie)
        try await Task.sleep(for: .milliseconds(20))
        #expect(transport.callCount == 1 && entry.letterboxd == nil)
        clock.advance(1)
        _ = store.ratings(for: movie)
        try await waitUntil { entry.letterboxd == 4.5 }
        #expect(transport.callCount == 2)
    }

    @Test func tenMoviesUseAtMostThreeLookupsAndKeepQueueOrder() async throws {
        let state = RatingsTestState(now: when)
        let transport = StubTransport { request, _ in
            state.started()
            defer { state.finished() }
            try await Task.sleep(for: .milliseconds(40))
            return StubTransport.response(Data(#"<meta name="twitter:data2" content="4.5">"#.utf8), for: request)
        }
        let store = store(transport)
        let items = (0..<10).map { MetaPreview(id: "tt\(1_000_000 + $0)", type: "movie") }
        let entries = items.map { store.ratings(for: $0) }
        try await waitUntil { entries.allSatisfy { $0.letterboxd == 4.5 } }
        #expect(state.maximum == 3)
        #expect(transport.callCount == 10)
        #expect(Set(transport.requests.prefix(3).compactMap { $0.url?.lastPathComponent }) == Set(items.prefix(3).map(\.id)))
    }

    @Test func serialLookupsRunInTheOrderAsked() async throws {
        let transport = StubTransport(data: page)
        let store = PosterRatingsStore(letterboxd: LetterboxdRatings(client: makeClient(transport)), maxConcurrentLookups: 1)
        let items = (0..<5).map { MetaPreview(id: "tt\(1_000_000 + $0)", type: "movie") }
        let entries = items.map { store.ratings(for: $0) }
        try await waitUntil { entries.allSatisfy { $0.letterboxd == 4.5 } }
        #expect(transport.requests.compactMap { $0.url?.lastPathComponent } == items.map(\.id))
    }

    @Test func forgetAllCancelsAnOldAnswerAndKeepsIMDb() async throws {
        let cache = InMemoryRatingsCache()
        let transport = StubTransport { request, _ in
            try? await Task.sleep(for: .milliseconds(100))
            return StubTransport.response(Data(#"<meta name="twitter:data2" content="4.5">"#.utf8), for: request)
        }
        let store = store(transport, cache: cache)
        let entry = store.ratings(for: movie)
        try await waitUntil { transport.callCount == 1 }
        await store.forgetAll()
        let stored = await cache.value(for: movie.id)
        #expect(stored == nil && entry.letterboxd == nil && entry.imdb == 9)
        _ = store.ratings(for: movie)
        try await waitUntil { entry.letterboxd == 4.5 }
        #expect(transport.callCount == 2)
        await store.forgetAll()
        #expect(entry.letterboxd == nil && entry.imdb == 9)
    }

    @Test func tmdbScoresFillPostersAndTheDetailReviewRow() async throws {
        let transport = StubTransport(data: tmdbFindMovie)
        let store = PosterRatingsStore(tmdb: TMDbRatings(client: makeClient(transport), readAccessToken: jwt))
        let entry = store.ratings(for: movie)
        try await waitUntil { entry.tmdb == 9.1 }
        #expect(transport.callCount == 1)
        _ = store.ratings(for: movie, includeReviews: true)
        try await waitUntil { entry.tmdb == 9.1 }
        #expect(entry.imdb == 9 && entry.text(for: .tmdb) == "91/100")
        #expect(entry.tmdbURL?.absoluteString == "https://www.themoviedb.org/movie/155")
        for _ in 0..<10 { _ = store.ratings(for: movie, includeReviews: true) }
        #expect(transport.callCount == 1 && store.reviewServiceIssue == nil)
    }

    @Test func homeHeroLoadsDistinctOriginalArtworkEvenWhenPosterRatingsAreDisabled() async throws {
        let transport = StubTransport { request, _ in
            let json = request.url?.lastPathComponent == "images"
                ? #"{"backdrops":[{"file_path":"/landscape.jpg"}],"posters":[{"file_path":"/portrait.jpg"}]}"#
                : #"{"movie_results":[{"id":155}]}"#
            return StubTransport.response(Data(json.utf8), for: request)
        }
        let store = PosterRatingsStore(isEnabled: false, tmdb: TMDbRatings(client: makeClient(transport), readAccessToken: jwt))
        let artwork = try #require(await store.heroArtwork(for: movie))
        #expect(artwork.portrait == URL(string: "https://image.tmdb.org/t/p/original/portrait.jpg"))
        #expect(artwork.backdrop == URL(string: "https://image.tmdb.org/t/p/original/landscape.jpg"))
        #expect(artwork.portrait != artwork.backdrop)
        #expect(await PosterRatingsStore().heroArtwork(for: movie) == nil)
    }

    @Test func aRefusedTokenIsLoggedWithItsReasonAndSaidInTheReviewRow() async throws {
        let sink = MemoryLogSink()
        let transport = StubTransport(data: Data(#"{"success":false,"status_code":7}"#.utf8), status: 401)
        let store = PosterRatingsStore(tmdb: TMDbRatings(client: makeClient(transport), readAccessToken: jwt), logger: AddonLogger(sink: sink))
        let entry = store.ratings(for: movie, includeReviews: true)
        try await waitUntil { store.reviewServiceIssue != nil }
        #expect(store.reviewServiceIssue == "TMDb refused the Read Access Token. Check it in Settings.")
        #expect(entry.tmdb == nil)
        #expect(sink.lines.contains { $0.contains("tmdb lookup failed") && $0.contains("Server error (401)") })
        #expect(!sink.lines.joined().contains(jwt), "the token never reaches the log")
    }

    @Test func episodeScoresComeFromTMDbOnlyWithACredentialAndFailuresAreExplained() async throws {
        let season = Data(#"{"episodes":[{"episode_number":2,"vote_average":7.6,"vote_count":30}]}"#.utf8)
        let transport = StubTransport { request, call in
            StubTransport.response(call == 1 ? tmdbFindTV : season, for: request)
        }
        let store = PosterRatingsStore(tmdb: TMDbRatings(client: makeClient(transport), readAccessToken: jwt))
        #expect(await store.episodeRatings(seriesIMDbID: "tt0944947", season: 1) == [2: 7.6])
        #expect(await PosterRatingsStore().episodeRatings(seriesIMDbID: "tt0944947", season: 1).isEmpty)

        let sink = MemoryLogSink()
        let limited = StubTransport(data: Data("{}".utf8), status: 429)
        let failing = PosterRatingsStore(tmdb: TMDbRatings(client: makeClient(limited, retries: 0), readAccessToken: jwt), logger: AddonLogger(sink: sink))
        #expect(await failing.episodeRatings(seriesIMDbID: "tt0944947", season: 1).isEmpty)
        #expect(failing.reviewServiceIssue == "TMDb rate limit reached. Scores will return later.")
        #expect(sink.lines.contains { $0.contains("episode lookup for season 1 failed") })
    }

    private let omdbSeason = Data(#"{"Response":"True","Season":"2","Episodes":[{"Episode":"1","imdbRating":"8.9"},{"Episode":"2","imdbRating":"N/A"}]}"#.utf8)

    private let omdbTitle = Data(#"""
    {"Response":"True","Title":"Hail Mary","imdbRating":"7.5","Metascore":"64",
     "Ratings":[{"Source":"Internet Movie Database","Value":"7.5/10"},
                {"Source":"Rotten Tomatoes","Value":"81%"},{"Source":"Metacritic","Value":"64/100"}]}
    """#.utf8)

    @Test @MainActor func rottenTomatoesAndMetacriticComeFromOMDbForATitleWithAKey() async throws {
        let transport = StubTransport(data: omdbTitle)
        // Its own usage counter, so it does not share the app's OMDb count with the other tests.
        let usage = OMDbUsage(defaults: UserDefaults(suiteName: "tests.omdb.title") ?? .standard)
        let omdb = OMDbRatings(client: makeClient(transport), apiKey: "test-key", usage: usage)
        let store = PosterRatingsStore(cache: InMemoryRatingsCache(), now: { when }, omdb: omdb)
        let item = MetaPreview(id: "tt0944947", type: "movie", name: "Hail Mary")
        _ = store.ratings(for: item, includeReviews: true)
        try await waitUntil { store.ratings(for: item).rottenTomatoes != nil }
        #expect(store.ratings(for: item).rottenTomatoes == 81)
        #expect(store.ratings(for: item).metacritic == 64)
        #expect(transport.callCount == 1, "one OMDb request for the title")
    }

    @Test func episodeScoresComeFromOMDbOncePerSeasonAndAreCached() async throws {
        let cache = InMemoryRatingsCache()
        let transport = StubTransport(data: omdbSeason)
        let store = PosterRatingsStore(cache: cache, now: { when }, omdb: OMDbRatings(client: makeClient(transport), apiKey: "test-key"))
        async let first = store.episodeRatings(for: "tt0944947", season: 2)
        async let second = store.episodeRatings(for: "tt0944947", season: 2)
        let (a, b) = await (first, second)
        #expect(a == [1: 8.9] && b == a)
        let again = await store.episodeRatings(for: "tt0944947", season: 2)
        #expect(again == a && transport.callCount == 1)
        let stored = await cache.value(for: "omdb:tt0944947:s2")
        #expect(stored == CachedRating(rating: nil, fetchedAt: when, episodes: [1: 8.9], episodeIDs: [:], episodeNumbers: [1, 2]))
        _ = await store.episodeRatings(for: "tt0944947", season: 3)
        #expect(transport.callCount == 2)
    }

    @Test func episodeScoresNeedAnOMDbKeyAndAnIMDbID() async throws {
        let transport = StubTransport(data: omdbSeason)
        let without = PosterRatingsStore()
        let withKey = PosterRatingsStore(omdb: OMDbRatings(client: makeClient(transport), apiKey: "test-key"))
        let noKey = await without.episodeRatings(for: "tt0944947", season: 1)
        let notIMDb = await withKey.episodeRatings(for: "kitsu:1", season: 1)
        #expect(noKey.isEmpty && notIMDb.isEmpty && transport.callCount == 0)
    }

    @Test func refreshingEpisodesBypassesCachedMissesAndDeduplicatesTheNewAnswer() async throws {
        let cache = InMemoryRatingsCache()
        await cache.store(CachedRating(rating: nil, fetchedAt: when, episodes: [:]), for: "omdb:tt0944947:s2")
        let transport = StubTransport(data: omdbSeason)
        let store = PosterRatingsStore(cache: cache, now: { when }, omdb: OMDbRatings(client: makeClient(transport), apiKey: "test-key"))
        let before = await store.episodeRatings(for: "tt0944947", season: 2)
        #expect(before.isEmpty && transport.callCount == 0)
        await store.refresh()
        let after = await store.episodeRatings(for: "tt0944947", season: 2)
        let again = await store.episodeRatings(for: "tt0944947", season: 2)
        #expect(after == [1: 8.9] && again == after && transport.callCount == 1)
    }

    @Test func episodeScoresRemainAvailableOfflineAfterTheirDailyExpiry() async throws {
        let cache = InMemoryRatingsCache()
        let cached = CachedRating(rating: nil, fetchedAt: when.addingTimeInterval(-86_400), episodes: [1: 8.9])
        await cache.store(cached, for: "omdb:tt0944947:s2")
        let transport = StubTransport { _, _ in throw AddonError.offline }
        let store = PosterRatingsStore(cache: cache, now: { when }, omdb: OMDbRatings(client: makeClient(transport, retries: 0), apiKey: "test-key"))
        let scores = await store.episodeRatings(for: "tt0944947", season: 2)
        #expect(scores == [1: 8.9] && transport.callCount == 1)
        #expect(store.omdbError?.contains("connection") == true)
        let again = await store.episodeRatings(for: "tt0944947", season: 2)
        #expect(again == scores && transport.callCount == 1)
        let retained = await cache.value(for: "omdb:tt0944947:s2")
        #expect(retained == cached)
    }

    @Test func omdbEpisodeRequestsNeedAKeyAnAllowanceAndNoPause() async throws {
        let name = "PosterRatingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let usage = OMDbUsage(defaults: defaults)
        let transport = StubTransport(data: omdbSeason)
        let client = makeClient(transport, retries: 0)
        #expect(!PosterRatingsStore().omdbAllowsEpisodeRequests, "no key")
        let store = PosterRatingsStore(omdb: OMDbRatings(client: client, apiKey: "k", usage: usage))
        #expect(store.omdbAllowsEpisodeRequests)
        for _ in 0..<OMDbUsage.dailyLimit { usage.record() }
        #expect(!store.omdbAllowsEpisodeRequests, "the day's allowance is spent")
        #expect(await store.episodeRatings(for: "tt0944947", season: 1).isEmpty)
        #expect(transport.callCount == 0, "the fetch itself must enforce the allowance")
    }

    @Test func aRateLimitedOMDbIsNotAvailableForEpisodesAndAsksTheCardsAgain() async throws {
        // Its own count of today's requests: the test runner's shared one passes the daily allowance after enough runs in a day.
        let name = "PosterRatingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = StubTransport(data: omdbSeason, status: 429)
        let store = PosterRatingsStore(omdb: OMDbRatings(client: makeClient(transport, retries: 0), apiKey: "k",
                                                         usage: OMDbUsage(defaults: defaults)))
        let before = store.reviewServicesRevision
        #expect(store.omdbAllowsEpisodeRequests)
        _ = await store.episodeRatings(for: "tt0944947", season: 2)
        #expect(!store.omdbAllowsEpisodeRequests)
        #expect(store.reviewServicesRevision > before)
    }

    @Test func aRefusedOMDbKeyStopsSeasonLookupsUntilCredentialsChange() async throws {
        let transport = StubTransport(data: Data(#"{"Response":"False","Error":"Invalid API key!"}"#.utf8))
        let store = PosterRatingsStore(omdb: OMDbRatings(client: makeClient(transport, retries: 0), apiKey: "bad"))
        for season in 1...4 { _ = await store.episodeRatings(for: "tt0944947", season: season) }
        #expect(transport.callCount == 1, "the first refusal pauses the rest")
        #expect(store.omdbError?.contains("rejected") == true)
        await store.setReviewServices(omdb: OMDbRatings(client: makeClient(transport, retries: 0), apiKey: "good"), tmdb: nil)
        _ = await store.episodeRatings(for: "tt0944947", season: 5)
        #expect(transport.callCount == 2)
    }

    @Test func postersAndTitlePagesNeverAskOMDb() async throws {
        let transport = StubTransport(data: Data(#"{"Response":"True","imdbRating":"7.4","Metascore":"82"}"#.utf8))
        let store = PosterRatingsStore(omdb: OMDbRatings(client: makeClient(transport), apiKey: "test-key"))
        let unrated = MetaPreview(id: "tt1234567", type: "movie", name: "New")
        let entry = store.ratings(for: unrated, includeReviews: true)
        _ = store.ratings(for: MetaPreview(id: "tt7654321", type: "series"))
        try await Task.sleep(for: .milliseconds(60))
        #expect(transport.callCount == 0 && entry.imdb == nil && entry.metacritic == nil)
    }

    @Test func postersPreferTwoSourcesAndFillEitherMissingPreferredScore() {
        let entry = TitleRatings(id: "test", imdb: 8, letterboxd: 4)
        entry.rottenTomatoes = 91
        entry.metacritic = 82
        entry.tmdb = 8.4
        #expect(entry.posterSites == [.imdb, .letterboxd])
        entry.imdb = nil
        #expect(entry.posterSites == [.letterboxd, .rottenTomatoes])
        entry.letterboxd = nil
        #expect(entry.posterSites == [.rottenTomatoes, .metacritic])
        #expect(!entry.isEmpty && entry.shortText(for: .rottenTomatoes) == "91", "Rotten Tomatoes is a whole percentage")
        #expect(entry.shortText(for: .metacritic) == "82")
        entry.rottenTomatoes = nil
        #expect(entry.posterSites == [.metacritic, .tmdb])
        entry.metacritic = nil
        #expect(entry.posterSites == [.tmdb], "do not invent a second score for an unrated source")
        entry.tmdb = nil
        #expect(entry.posterSites.isEmpty && entry.isEmpty)
    }

    @Test func theAverageTakesEveryScoreOutOf100First() {
        let entry = TitleRatings(id: "test", imdb: 7.8, letterboxd: 4)
        entry.rottenTomatoes = 90
        entry.metacritic = 70
        entry.tmdb = 7.5
        #expect(entry.scoreOutOf100(for: .imdb) == 78 && entry.scoreOutOf100(for: .letterboxd) == 80)
        #expect(entry.scoreOutOf100(for: .tmdb) == 75 && entry.scoreOutOf100(for: .rottenTomatoes) == 90)
        // (78 + 80 + 90 + 70 + 75) / 5 = 78.6
        #expect(entry.averageScore == 79)
    }

    @Test func theAverageNeedsTwoScores() {
        let entry = TitleRatings(id: "test")
        #expect(entry.averageScore == nil)
        entry.metacritic = 64
        #expect(entry.averageScore == nil, "one score is not an average")
        entry.imdb = 7.1
        #expect(entry.averageScore == 68, "(64 + 71) / 2 = 67.5 rounds up")
        #expect(TitleRatings.average(of: [nil, 50, nil]) == nil)
    }

    @Test func expiredScoresSurviveOfflineFailuresAndManualRetryWorks() async throws {
        let cache = InMemoryRatingsCache()
        let cached = CachedRating(rating: 4, fetchedAt: when.addingTimeInterval(-8 * 86_400))
        await cache.store(cached, for: movie.id)
        let transport = StubTransport { request, call in
            if call == 1 { throw AddonError.offline }
            return StubTransport.response(Data(#"<meta name="twitter:data2" content="4.5">"#.utf8), for: request)
        }
        let store = store(transport, cache: cache, now: { when })
        let entry = store.ratings(for: movie)
        try await waitUntil { transport.callCount == 1 && entry.letterboxd == 4 }
        try await Task.sleep(for: .milliseconds(20))
        let retained = await cache.value(for: movie.id)
        #expect(retained == cached)
        await store.refresh()
        #expect(entry.letterboxd == 4)
        _ = store.ratings(for: movie)
        try await waitUntil { entry.letterboxd == 4.5 }
        #expect(transport.callCount == 2)
    }

    @Test func reviewScoresUseTheCacheAndRemainAvailableWithPosterBadgesDisabled() async throws {
        let cache = InMemoryRatingsCache()
        await cache.store(CachedRating(rating: nil, fetchedAt: when, reviews: ReviewRatings(tmdb: 8.4,
                          tmdbURL: URL(string: "https://www.themoviedb.org/movie/155"))), for: "tmdb:\(movie.identity)")
        let transport = StubTransport(data: Data())
        let store = PosterRatingsStore(isEnabled: false, cache: cache, now: { when },
                                       tmdb: TMDbRatings(client: makeClient(transport), readAccessToken: "test-token"))
        let entry = store.ratings(for: movie, includeReviews: true)
        try await waitUntil { entry.tmdb == 8.4 }
        #expect(transport.callCount == 0 && entry.text(for: .tmdb) == "84/100")
        await store.forgetAll()
        #expect(entry.tmdb == nil && entry.tmdbURL == nil)
    }

    @Test func addingAndRemovingTheTokenStartsFreshLookupsAndClearsTheirVisibleScores() async throws {
        let transport = StubTransport(data: tmdbFindMovie)
        let store = PosterRatingsStore()
        let entry = store.ratings(for: movie, includeReviews: true)
        #expect(entry.tmdb == nil && transport.callCount == 0)
        await store.setReviewServices(tmdb: TMDbRatings(client: makeClient(transport), readAccessToken: jwt))
        #expect(store.reviewServicesRevision == 1)
        _ = store.ratings(for: movie, includeReviews: true)
        try await waitUntil { entry.tmdb == 9.1 }
        await store.setReviewServices(tmdb: nil)
        _ = store.ratings(for: movie, includeReviews: true)
        #expect(entry.tmdb == nil && store.reviewServicesRevision == 2 && transport.callCount == 1)
    }

    @Test func openingReviewsResumesALetterboxdLookupPausedByThePosterSwitch() async throws {
        let transport = StubTransport(data: page)
        let store = store(transport)
        let entry = store.ratings(for: movie)
        store.isEnabled = false
        try await Task.sleep(for: .milliseconds(20))
        #expect(transport.callCount == 0)
        _ = store.ratings(for: movie, includeReviews: true)
        try await waitUntil { entry.letterboxd == 4.5 }
        #expect(transport.callCount == 1)
    }

    /// TMDb's answers for the hero tests: the id lookup finds the movie, and the images are one poster. `delay` slows the id lookup.
    private func tmdbHeroTransport(delay: Duration = .zero, state: RatingsTestState? = nil) -> StubTransport {
        StubTransport { request, _ in
            guard request.url?.path.contains("/find/") == true else {
                return StubTransport.response(Data(#"{"posters":[{"file_path":"/p.jpg"}]}"#.utf8), for: request)
            }
            state?.started()
            defer { state?.finished() }
            try await Task.sleep(for: delay)
            return StubTransport.response(Data(#"{"movie_results":[{"id":155}],"tv_results":[]}"#.utf8), for: request)
        }
    }

    private func heroStore(_ transport: StubTransport) -> PosterRatingsStore {
        PosterRatingsStore(isEnabled: false, tmdb: TMDbRatings(client: makeClient(transport, retries: 0), readAccessToken: jwt,
                                                               titleIDs: TMDbTitleIDCache()))
    }

    @Test func twoAsksForOneTitleAtOnceShareOneLookup() async throws {
        let transport = tmdbHeroTransport(delay: .milliseconds(30))
        let store = heroStore(transport)
        async let first = store.heroArtwork(for: movie)
        async let second = store.heroArtwork(for: movie)
        let answers = await (first, second)
        #expect(answers.0 != nil && answers.0 == answers.1)
        #expect(transport.requests.filter { $0.url?.path.contains("/find/") == true }.count == 1, "one lookup, not one per caller")
    }

    @Test func aTitleWhoseScoreIsKnownAsksTMDbOnlyForItsArtwork() async throws {
        let transport = tmdbHeroTransport()
        let tmdb = TMDbRatings(client: makeClient(transport, retries: 0), readAccessToken: jwt, titleIDs: TMDbTitleIDCache())
        _ = try await tmdb.ratings(imdbID: movie.id, type: movie.type)
        let artwork = try await tmdb.artwork(imdbID: movie.id, type: movie.type)
        #expect(artwork?.portrait == URL(string: "https://image.tmdb.org/t/p/original/p.jpg"))
        #expect(transport.requests.filter { $0.url?.path.contains("/find/") == true }.count == 1, "the score's answer named the id")
    }

    @Test func aScoreReadFromTheCacheNamesTheTitleToo() async throws {
        let transport = tmdbHeroTransport()
        let tmdb = TMDbRatings(client: makeClient(transport, retries: 0), readAccessToken: jwt, titleIDs: TMDbTitleIDCache())
        let cached = ReviewRatings(tmdb: 7.1, tmdbURL: URL(string: "https://www.themoviedb.org/movie/155"))
        await tmdb.rememberID(from: cached, imdbID: movie.id, type: movie.type)
        _ = try await tmdb.artwork(imdbID: movie.id, type: movie.type)
        #expect(!transport.requests.contains { $0.url?.path.contains("/find/") == true }, "no id lookup")
        #expect(transport.requests.contains { $0.url?.path.hasSuffix("/movie/155/images") == true })
    }

    @Test func theSpotlightsAgeRatingIsAskedOnceAndKeptForTheSession() async throws {
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/release_dates") == true {
                return StubTransport.response(Data(#"{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"PG-13"}]}]}"#.utf8), for: request)
            }
            return StubTransport.response(Data(#"{"movie_results":[{"id":155}],"tv_results":[]}"#.utf8), for: request)
        }
        let store = heroStore(transport)
        #expect(store.cachedCertification(for: movie) == nil, "nothing is known before the first lookup")
        #expect(await store.certification(for: movie) == "PG-13")
        #expect(store.cachedCertification(for: movie) == "PG-13")
        let asked = transport.callCount
        #expect(await store.certification(for: movie) == "PG-13")
        #expect(transport.callCount == asked, "a known age rating is not asked for again")
        #expect(await PosterRatingsStore().certification(for: movie) == nil, "without TMDb there is none")
    }

    @Test func aPrewarmAsksTMDbOnceForTheArtworkAndNeverForAPicture() async throws {
        let transport = tmdbHeroTransport()
        let store = heroStore(transport)
        await store.prewarmHeroArtwork(for: movie)
        #expect(store.cachedHeroArtwork(for: movie)?.portrait == URL(string: "https://image.tmdb.org/t/p/original/p.jpg"))
        #expect(transport.requests.allSatisfy { $0.url?.host == "api.themoviedb.org" }, "JSON only: no picture is downloaded")
        let asked = transport.callCount
        await store.prewarmHeroArtwork(for: movie)
        #expect(transport.callCount == asked, "a title whose artwork is known is not asked for again")
    }

    @Test func aPrewarmDoesNothingWithoutTMDb() async {
        let store = PosterRatingsStore()
        await store.prewarmHeroArtwork(for: movie)
        #expect(store.cachedHeroArtwork(for: movie) == nil)
    }

    @Test func prewarmsRunFourAtATimeAndOneWaitingForATurnDropsWhenItsCardScrollsAway() async throws {
        let state = RatingsTestState(now: when)
        let transport = tmdbHeroTransport(delay: .milliseconds(60), state: state)
        let store = heroStore(transport)
        let items = (0..<5).map { MetaPreview(id: "tt\(1_000_000 + $0)", type: "movie", name: "T") }
        var tasks: [Task<Void, Never>] = []
        for item in items { tasks.append(Task { await store.prewarmHeroArtwork(for: item) }) }
        try await waitUntil { state.maximum == 4 }
        // The fifth card scrolls away while it waits for one of the four running lookups.
        tasks[4].cancel()
        for task in tasks { await task.value }
        #expect(state.maximum == 4, "four lookups at once, no more")
        #expect(!transport.requests.contains { $0.url?.path.contains("tt1000004") == true }, "the card that scrolled away never asked")
        #expect(transport.requests.filter { $0.url?.path.contains("/find/") == true }.count == 4)
    }
}

private final class RatingsTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date
    private var active = 0
    private var peak = 0

    init(now: Date) { self.now = now }
    var date: Date { lock.withLock { now } }
    var maximum: Int { lock.withLock { peak } }
    func advance(_ seconds: TimeInterval) { lock.withLock { now.addTimeInterval(seconds) } }
    func started() { lock.withLock { active += 1; peak = max(peak, active) } }
    func finished() { lock.withLock { active -= 1 } }
}
