import Foundation
import PlayerKit
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

/// The live transport, except that the iTunes store is never reached: a test must not depend on the network.
private struct NoITunesTransport: HTTPTransport {
    private let live = URLSessionTransport()

    func send(_ request: URLRequest, limits: FetchLimits) async throws -> HTTPResult {
        if request.url?.host == "itunes.apple.com" { throw URLError(.notConnectedToInternet) }
        return try await live.send(request, limits: limits)
    }
}

@MainActor
@Suite struct DetailViewModelTests {
    private func services(_ server: MockServer) -> AppServices {
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: server.slowDelay + 4, maxRetries: 0),
                                 transport: NoITunesTransport())
        return AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client), client: client)
    }

    /// Services that never reach the network: for the parts of Detail that read the preview alone.
    private func offlineServices() -> AppServices {
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: 1, maxRetries: 0))
        return AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client), client: client)
    }

    /// Services with the mock catalog addon installed, so Detail can load the mock's movies and two-season series.
    private func installedServices() async throws -> AppServices {
        let server = try MockServer.shared()
        let services = services(server)
        _ = try await services.registry.install(from: server.catalogManifestURL().absoluteString)
        return services
    }

    /// The mock's series (two seasons of three episodes), loaded.
    private func loadedSeries(_ services: AppServices) async -> DetailViewModel {
        let model = DetailViewModel(preview: MetaPreview(id: "mock:series1", type: "series", name: "S"), services: services)
        await model.load()
        return model
    }

    /// Saves unwatched progress for a movie or episode, as the player does while it plays.
    private func saveProgress(_ services: AppServices, id: String, type: String, position: TimeInterval, duration: TimeInterval,
                              updatedAt: Date, season: Int? = nil, episode: Int? = nil) async {
        await services.progress.save(WatchProgress(id: "\(type)/\(id)", type: type, contentID: id, title: id, position: position,
                                                   duration: duration, isWatched: false, updatedAt: updatedAt, season: season, episode: episode))
    }

    @Test func startsFromThePreviewThenUpgradesToMeta() async throws {
        let server = try MockServer.shared()
        let services = services(server)
        _ = try await services.registry.install(from: server.catalogManifestURL().absoluteString)
        let preview = MetaPreview(id: "mock:movie3", type: "movie", name: "Preview Title", poster: URL(string: "https://example.com/p.jpg"))
        let model = DetailViewModel(preview: preview, services: services)
        #expect(model.isLoading)
        #expect(model.detail.name == "Preview Title", "something to show immediately")
        await model.load()
        #expect(!model.isLoading && !model.isFallback)
        #expect(model.detail.name == "Mock Movie 3")
        #expect(model.detail.cast.count == 2)
        #expect(model.detail.preview.poster != nil)
        #expect(model.subtitle.contains("min"))
        #expect(!model.isSeries)
    }

    @Test func fallsBackToCatalogDataWhenMetaIsUnavailable() async throws {
        let server = try MockServer.shared()
        let services = services(server)
        _ = try await services.registry.install(from: server.catalogManifestURL().absoluteString)
        let preview = MetaPreview(id: "mock:nometa1", type: "movie", name: "Preview Only Movie", releaseInfo: "2001")
        let model = DetailViewModel(preview: preview, services: services)
        await model.load()
        #expect(model.isFallback)
        #expect(model.detail.name == "Preview Only Movie")
        #expect(model.subtitle == "2001")
    }

    @Test func seriesExposeSeasonsAndEpisodes() async throws {
        let server = try MockServer.shared()
        let services = services(server)
        _ = try await services.registry.install(from: server.catalogManifestURL().absoluteString)
        let model = DetailViewModel(preview: MetaPreview(id: "mock:series1", type: "series", name: "S"), services: services)
        await model.load()
        #expect(model.isSeries)
        #expect(model.seasons == [1, 2])
        #expect(model.selectedSeason == 1, "the first season is selected")
        #expect(model.episodes.map(\.episode) == [1, 2, 3])
        model.selectedSeason = 2
        let episode = try #require(model.episodes.first)
        let request = model.request(for: episode)
        #expect(request.type == "series")
        #expect(request.id == "mock:series1:2:1")
        #expect(request.season == 2 && request.episode == 1)
        #expect(request.title == "Mock Series One · Episode 1")
    }

    @Test func movieRequestsCarryTitlePosterAndIdentity() async throws {
        let server = try MockServer.shared()
        let services = services(server)
        _ = try await services.registry.install(from: server.catalogManifestURL().absoluteString)
        let model = DetailViewModel(preview: MetaPreview(id: "mock:movie4", type: "movie", name: "P"), services: services)
        await model.load()
        let request = model.movieRequest
        #expect(request.id == "mock:movie4")
        #expect(request.type == "movie")
        #expect(request.title == "Mock Movie 4")
        #expect(request.poster != nil)
        #expect(request.identity == "movie/mock:movie4")
    }

    @Test func requestsFromPreviewsDefaultTheType() {
        #expect(StreamRequest(movie: MetaPreview(id: "tt1", name: "X")).type == "movie")
    }

    @Test func nextUpIsTheFirstEpisodeOfAFreshSeries() async throws {
        let services = try await installedServices()
        let model = await loadedSeries(services)
        #expect(model.nextUp?.id == "mock:series1:1:1")
        #expect(model.primaryActionTitle == "Play S1 · E1")
        #expect(model.selectedSeason == 1, "the season of the next episode is the one shown")
    }

    @Test func nextUpIsTheFirstUnwatchedEpisodeInWatchingOrder() async throws {
        let services = try await installedServices()
        let model = await loadedSeries(services)
        for video in model.episodes.prefix(2) {
            await model.setWatched(true, for: model.request(for: video))
        }
        #expect(model.nextUp?.id == "mock:series1:1:3")
        #expect(model.primaryActionTitle == "Resume S1 · E3")
    }

    @Test func markingAllEpisodesThroughOneResumesAtTheNextEpisodeEvenAfterReopening() async throws {
        let services = try await installedServices()
        let model = await loadedSeries(services)
        let selected = try #require(model.detail.videos.first(where: { $0.id == "mock:series1:1:3" }))
        await model.markEpisodesWatched(through: selected)
        #expect(model.nextUp?.id == "mock:series1:2:1")
        #expect(model.primaryActionTitle == "Resume S2 · E1")
        #expect(model.primaryRequest?.id == "mock:series1:2:1", "Resume launches the next episode, not the marked episode")
        let reopened = await loadedSeries(services)
        #expect(reopened.primaryActionTitle == "Resume S2 · E1", "watched history, not transient UI state, drives Resume")
        #expect(reopened.primaryRequest?.id == "mock:series1:2:1")
    }

    @Test func nextUpFallsBackToTheFirstEpisodeWhenEverythingIsWatched() async throws {
        let services = try await installedServices()
        let model = await loadedSeries(services)
        for video in model.detail.videos {
            await model.setWatched(true, for: model.request(for: video))
        }
        #expect(model.nextUp?.id == "mock:series1:1:1")
        #expect(model.primaryActionTitle == "Play S1 · E1")
    }

    @Test func nextUpIsTheMostRecentlyUpdatedUnfinishedEpisode() async throws {
        let services = try await installedServices()
        let model = await loadedSeries(services)
        await saveProgress(services, id: "mock:series1:2:2", type: "series", position: 300, duration: 1200,
                           updatedAt: Date().addingTimeInterval(-600), season: 2, episode: 2)
        await saveProgress(services, id: "mock:series1:1:3", type: "series", position: 60, duration: 1200,
                           updatedAt: Date().addingTimeInterval(-60), season: 1, episode: 3)
        await model.refreshUserState()
        #expect(model.nextUp?.id == "mock:series1:1:3", "the episode watched most recently wins, though S1 E1 is still unwatched")
        #expect(model.primaryActionTitle == "Resume S1 · E3")
        let video = try #require(model.detail.videos.first(where: { $0.id == "mock:series1:1:3" }))
        #expect(model.progressFraction(for: video) == 0.05)
        #expect(model.progressFraction(for: model.request(for: video)) == 0.05)
    }

    @Test func primaryActionResumesOnlyWhenThereIsResumableProgress() async throws {
        let services = try await installedServices()
        let model = DetailViewModel(preview: MetaPreview(id: "mock:movie3", type: "movie", name: "P"), services: services)
        await model.load()
        #expect(model.primaryActionTitle == "Play")
        #expect(model.progressFraction(for: model.movieRequest) == nil, "not started: no bar")
        await saveProgress(services, id: "mock:movie3", type: "movie", position: 600, duration: 6000, updatedAt: Date())
        await model.refreshUserState()
        #expect(model.primaryActionTitle == "Resume")
        #expect(model.progressFraction(for: model.movieRequest) == 0.1)
        await model.setWatched(true, for: model.movieRequest)
        #expect(model.primaryActionTitle == "Play")
        #expect(model.progressFraction(for: model.movieRequest) == nil, "watched: no bar")
    }

    @Test func withNoDirectFileTheAddonsYouTubeTrailersAreTheFallbackInItsOrder() async throws {
        let json = #"""
        {"meta":{"id":"tt0468569","type":"movie","name":"The Dark Knight",
         "trailerStreams":[{"title":"Bad","ytId":"not an id"},{"title":"Trailer","ytId":"EXeTwQWrcwY"},{"title":"Other","ytId":"zZZ999"},
                           {"title":"Third","ytId":"third1"}]}}
        """#
        let transport = StubTransport { request, _ in StubTransport.response(Data(json.utf8), for: request) }
        let manifest = Manifest(id: "test.stubmeta", name: "Stub", version: "1", resources: [ResourceDescriptor(name: "meta")], types: ["movie"])
        let (registry, client) = try await makeStubbedRegistry(manifests: [manifest], transport: transport)
        let model = DetailViewModel(preview: MetaPreview(id: "tt0468569", type: "movie", name: "The Dark Knight"),
                                    services: AppServices(registry: registry, client: client))
        await model.load()
        #expect(!model.isFallback)
        #expect(model.tmdbVideos.isEmpty, "no read token, so TMDb is not asked")
        #expect(model.itunesTrailer == nil, "the stub answers the store with the meta, which is no search result")
        #expect(model.trailers.map(\.id) == ["yt:EXeTwQWrcwY", "yt:zZZ999", "yt:third1"], "malformed ids dropped, three kept")
    }

    @Test func anITunesPreviewIsTheFirstTrailerAndYouTubeStepsAside() async throws {
        let meta = #"""
        {"meta":{"id":"tt9900001","type":"movie","name":"Preview Ledger Film","releaseInfo":"2019",
         "trailerStreams":[{"title":"Trailer","ytId":"EXeTwQWrcwY"},{"title":"Direct","url":"https://cdn.example.com/t.mp4"}]}}
        """#
        let itunes = #"""
        {"resultCount":1,"results":[{"trackName":"Preview Ledger Film","releaseDate":"2019-05-01T07:00:00Z",
         "previewUrl":"https://a.example.com/preview.m4v"}]}
        """#
        let transport = StubTransport { request, _ in
            StubTransport.response(Data((request.url?.host == "itunes.apple.com" ? itunes : meta).utf8), for: request)
        }
        let manifest = Manifest(id: "test.stubmeta", name: "Stub", version: "1", resources: [ResourceDescriptor(name: "meta")], types: ["movie"])
        let (registry, client) = try await makeStubbedRegistry(manifests: [manifest], transport: transport)
        let model = DetailViewModel(preview: MetaPreview(id: "tt9900001", type: "movie", name: "Preview Ledger Film"),
                                    services: AppServices(registry: registry, client: client))
        await model.load()
        #expect(model.itunesTrailer?.directURL == URL(string: "https://a.example.com/preview.m4v"))
        #expect(model.trailers.map(\.id) == ["url:https://a.example.com/preview.m4v", "url:https://cdn.example.com/t.mp4"],
                "the preview leads, the addon's direct link follows it, and no YouTube trailer is offered")
        #expect(model.trailers.first?.youtubeID == nil)
    }

    @Test func aWholeShowCanBeMarkedWatchedAndUnmarked() async throws {
        let services = try await installedServices()
        let model = await loadedSeries(services)
        #expect(!model.isSeriesWatched && !model.isSeasonWatched(1))
        await model.setSeriesWatched(true)
        #expect(model.isSeriesWatched && model.isSeasonWatched(1) && model.isSeasonWatched(2))
        #expect(model.watchedIdentities.count == 6, "every episode of both seasons")
        let saved = await services.progress.progress(for: "series/mock:series1:2:3")
        #expect(saved?.isWatched == true && saved?.season == 2 && saved?.episode == 3)
        await model.setSeriesWatched(false)
        #expect(!model.isSeriesWatched && model.watchedIdentities.isEmpty)
        let cleared = await services.progress.progress(for: "series/mock:series1:2:3")
        #expect(cleared == nil)
    }

    @Test func aSeasonIsMarkedOnItsOwn() async throws {
        let model = await loadedSeries(try await installedServices())
        await model.setSeasonWatched(true, season: 1)
        #expect(model.isSeasonWatched(1) && !model.isSeasonWatched(2) && !model.isSeriesWatched)
        #expect(model.watchedIdentities.count == 3)
        #expect(model.nextUp?.season == 2, "the next episode moves to the season after")
        await model.setSeasonWatched(false, season: 1)
        #expect(model.watchedIdentities.isEmpty)
    }

    @Test func markingAShowSkipsEpisodesThatHaveNotAiredYet() async throws {
        let json = #"""
        {"meta":{"id":"tt7000001","type":"series","name":"Ongoing","videos":[
          {"id":"tt7000001:1:1","title":"Out","season":1,"episode":1,"released":"2001-01-01T00:00:00.000Z"},
          {"id":"tt7000001:1:2","title":"Soon","season":1,"episode":2,"released":"2999-01-01T00:00:00.000Z"}]}}
        """#
        let transport = StubTransport { request, _ in StubTransport.response(Data(json.utf8), for: request) }
        let manifest = Manifest(id: "test.stubmeta", name: "Stub", version: "1", resources: [ResourceDescriptor(name: "meta")], types: ["series"])
        let (registry, client) = try await makeStubbedRegistry(manifests: [manifest], transport: transport)
        let model = DetailViewModel(preview: MetaPreview(id: "tt7000001", type: "series", name: "Ongoing"),
                                    services: AppServices(registry: registry, client: client))
        await model.load()
        await model.setSeriesWatched(true)
        #expect(model.watchedIdentities == ["series/tt7000001:1:1"])
        #expect(model.isSeriesWatched, "the show counts as watched once everything that has aired is")
    }

    /// A series from a stub addon, loaded as Detail loads it.
    private func stubbedSeries(_ json: String, id: String) async throws -> DetailViewModel {
        let transport = StubTransport { request, _ in StubTransport.response(Data(json.utf8), for: request) }
        let manifest = Manifest(id: "test.stubshuffle", name: "Stub", version: "1", resources: [ResourceDescriptor(name: "meta")], types: ["series"])
        let (registry, client) = try await makeStubbedRegistry(manifests: [manifest], transport: transport)
        let model = DetailViewModel(preview: MetaPreview(id: id, type: "series", name: "S"), services: AppServices(registry: registry, client: client))
        await model.load()
        return model
    }

    @Test func shuffleOnlyPicksAnEpisodeThatHasAiredAndNeverASpecial() async throws {
        let model = try await stubbedSeries(#"""
        {"meta":{"id":"tt7000002","type":"series","name":"Mixed","videos":[
          {"id":"tt7000002:1:1","title":"Out","season":1,"episode":1,"released":"2001-01-01T00:00:00.000Z"},
          {"id":"tt7000002:1:2","title":"Soon","season":1,"episode":2,"released":"2999-01-01T00:00:00.000Z"},
          {"id":"tt7000002:0:1","title":"Special","season":0,"episode":1,"released":"2001-01-01T00:00:00.000Z"}]}}
        """#, id: "tt7000002")
        #expect(model.canShuffle)
        for _ in 0..<20 {
            #expect(model.shuffledRequest()?.id == "tt7000002:1:1", "the only regular episode that has aired")
        }
    }

    @Test func shuffleHasNothingToPickBeforeAnEpisodeAirs() async throws {
        let model = try await stubbedSeries(#"""
        {"meta":{"id":"tt7000003","type":"series","name":"Upcoming","videos":[
          {"id":"tt7000003:1:1","title":"Soon","season":1,"episode":1,"released":"2999-01-01T00:00:00.000Z"}]}}
        """#, id: "tt7000003")
        #expect(!model.canShuffle)
        #expect(model.shuffledRequest() == nil)
    }

    @Test func shuffleDrawsFromEverySeasonOfTheSeriesButNotForAMovie() async throws {
        let services = try await installedServices()
        let series = await loadedSeries(services)
        #expect(series.canShuffle)
        let aired = Set(series.detail.episodesCountingAsWatched().map(\.id))
        let picks = Set((0..<200).compactMap { _ in series.shuffledRequest()?.id })
        #expect(picks.isSubset(of: aired), "only episodes that have aired")
        let pickedSeasons = Set(series.detail.videos.filter { picks.contains($0.id) }.compactMap(\.season))
        #expect(pickedSeasons == [1, 2], "the shuffle reaches both seasons, not only the one shown")
        let movie = DetailViewModel(preview: MetaPreview(id: "mock:movie4", type: "movie", name: "P"), services: services)
        await movie.load()
        #expect(!movie.canShuffle)
        #expect(movie.shuffledRequest() == nil)
    }

    @Test func aTappedRatingOpensItsSiteAndASecondTapOnTheSameSiteCloses() async throws {
        let services = try await installedServices()
        let movie = DetailViewModel(preview: MetaPreview(id: "mock:movie4", type: "movie", name: "P"), services: services)
        let imdb = URL(string: "https://www.imdb.com/title/mock:movie4/")!
        let search = URL(string: "https://letterboxd.com/search/P/")!
        #expect(movie.openedReviews == nil)
        movie.toggleReviews(.imdb, url: imdb, isSearch: false)
        #expect(movie.openedReviews == DetailViewModel.OpenedReviews(site: .imdb, url: imdb, isSearch: false))
        movie.toggleReviews(.letterboxd, url: search, isSearch: true)
        #expect(movie.openedReviews == DetailViewModel.OpenedReviews(site: .letterboxd, url: search, isSearch: true), "another site replaces")
        movie.toggleReviews(.letterboxd, url: search, isSearch: true)
        #expect(movie.openedReviews == nil, "the same site again closes them")
        movie.toggleReviews(.imdb, url: imdb, isSearch: false)
        movie.closeReviews()
        #expect(movie.openedReviews == nil)
    }

    @Test func theOpenSiteStaysOnScreenWhileAnotherLoads() async throws {
        let services = try await installedServices()
        let movie = DetailViewModel(preview: MetaPreview(id: "mock:movie4", type: "movie", name: "P"), services: services)
        let imdb = DetailViewModel.OpenedReviews(site: .imdb, url: URL(string: "https://www.imdb.com/title/mock:movie4/")!, isSearch: false)
        let letterboxd = DetailViewModel.OpenedReviews(site: .letterboxd, url: URL(string: "https://letterboxd.com/search/P/")!, isSearch: true)
        let rottenTomatoes = DetailViewModel.OpenedReviews(site: .rottenTomatoes, url: URL(string: "https://www.rottentomatoes.com/search?search=P")!,
                                                           isSearch: true)
        movie.toggleReviews(imdb.site, url: imdb.url, isSearch: imdb.isSearch)
        #expect(movie.shownReviews == nil, "nothing was open to keep")
        movie.reviewsDidLoad()
        movie.toggleReviews(letterboxd.site, url: letterboxd.url, isSearch: letterboxd.isSearch)
        #expect(movie.openedReviews == letterboxd && movie.shownReviews == imdb, "IMDb stays on screen while Letterboxd loads")
        movie.toggleReviews(rottenTomatoes.site, url: rottenTomatoes.url, isSearch: rottenTomatoes.isSearch)
        #expect(movie.openedReviews == rottenTomatoes && movie.shownReviews == imdb, "still the page on screen, not the one that never showed")
        movie.reviewsDidLoad()
        #expect(movie.openedReviews == rottenTomatoes && movie.shownReviews == nil, "the new site takes its place once loaded")
        movie.toggleReviews(imdb.site, url: imdb.url, isSearch: imdb.isSearch)
        movie.toggleReviews(rottenTomatoes.site, url: rottenTomatoes.url, isSearch: rottenTomatoes.isSearch)
        #expect(movie.openedReviews == nil && movie.shownReviews == nil, "a tap on the site on screen closes the reviews")
    }

    @Test func theTrailerAndTheReviewsOpenAndCloseEachOnTheirOwn() async throws {
        let services = try await installedServices()
        let movie = DetailViewModel(preview: MetaPreview(id: "mock:movie4", type: "movie", name: "P"), services: services)
        let imdb = URL(string: "https://www.imdb.com/title/mock:movie4/")!
        movie.toggleTrailer()
        #expect(movie.trailer.phase == .loading, "the trailer is loading when the rating is tapped")
        movie.toggleReviews(.imdb, url: imdb, isSearch: false)
        #expect(movie.trailer.phase == .loading, "opening reviews leaves the trailer as it was")
        #expect(movie.openedReviews != nil)
        movie.closeReviews()
        #expect(movie.trailer.phase == .loading, "closing them leaves it too")
        movie.toggleReviews(.imdb, url: imdb, isSearch: false)
        movie.toggleTrailer()
        #expect(movie.openedReviews != nil, "the trailer's button leaves the reviews open")
        movie.trailer.cancel()
        #expect(movie.openedReviews != nil, "and closing the trailer leaves them as they were")
    }

    /// The Trailer button ticks when its own tap starts or closes the trailer, but not after the full-screen trailer's X, which gave its own
    /// haptic: only that close moves `trailerQuietCloses`.
    @Test func onlyTheFullScreenTrailersCloseIsQuiet() {
        let movie = DetailViewModel(preview: MetaPreview(id: "tt1", type: "movie", name: "P"), services: offlineServices())
        movie.toggleTrailer()
        #expect(movie.trailer.phase == .loading)
        #expect(movie.trailerQuietCloses == 0, "the button's own tap ticks")
        movie.closeTrailerQuietly()
        #expect(movie.trailerQuietCloses == 1 && !movie.trailer.isPlaying)
    }

    @Test func anOMDbScoreBeatsTheAddonsOneAndTheAddonsFillsTheRest() async throws {
        let transport = StubTransport(data: Data(#"{"Response":"True","Episodes":[{"Episode":"1","imdbRating":"8.9"}]}"#.utf8))
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: 1, maxRetries: 0), transport: transport)
        let ratings = PosterRatingsStore(omdb: OMDbRatings(client: client, apiKey: "test-key"))
        let services = AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client),
                                   client: client, posterRatings: ratings)
        let model = DetailViewModel(preview: MetaPreview(id: "tt0944947", type: "series", name: "S"), services: services)
        let first = Video(id: "tt0944947:1:1", season: 1, episode: 1, rating: 6)
        let second = Video(id: "tt0944947:1:2", season: 1, episode: 2, rating: 7.5)
        #expect(model.score(for: first) == .init(value: 6, isIMDb: false))
        await model.loadEpisodeScores(season: 1)
        #expect(model.score(for: first) == .init(value: 8.9, isIMDb: true))
        #expect(model.score(for: second) == .init(value: 7.5, isIMDb: false))
        #expect(model.score(for: Video(id: "x")) == nil)
    }

    @Test func aSeasonIsAskedForOnceWhenItsCardsAppearAndNeverBefore() async throws {
        let transport = StubTransport(data: Data(#"{"Response":"True","Episodes":[{"Episode":"1","imdbRating":"8.9"}]}"#.utf8))
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: 1, maxRetries: 0), transport: transport)
        let services = AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client),
                                   client: client, posterRatings: PosterRatingsStore(omdb: OMDbRatings(client: client, apiKey: "k")))
        let model = DetailViewModel(preview: MetaPreview(id: "tt0944947", type: "series", name: "S"), services: services)
        await model.load()
        let omdbRequests = transport.requests.filter { $0.url?.host == "www.omdbapi.com" }
        #expect(omdbRequests.isEmpty, "opening the page asks for no episode scores")
        let videos = (1...3).map { (number: Int) in Video(id: "tt0944947:1:\(number)", season: 1, episode: number) }
        async let a: Void = model.loadEpisodeSeason(videos[0].season)
        async let b: Void = model.loadEpisodeSeason(videos[1].season)
        async let c: Void = model.loadEpisodeSeason(videos[2].season)
        _ = await (a, b, c)
        // Counted for OMDb only: the page's iTunes search goes through the same transport.
        #expect(transport.requests.filter { $0.url?.host == "www.omdbapi.com" }.count == 1, "three cards of one season share one request")
        #expect(model.score(for: videos[0]) == .init(value: 8.9, isIMDb: true))
        await model.loadEpisodeSeason(2)
        #expect(transport.requests.filter { $0.url?.host == "www.omdbapi.com" }.count == 2, "another season is its own request")
    }

    @Test(arguments: [false, true])
    func episodesLoadIMDbFirstEvenWhenTheAddonUsesItsOwnSeriesID(usesAddonID: Bool) async throws {
        let seriesID = usesAddonID ? "addon:show" : "tt0944947"
        let meta = #"{"meta":{"id":"\#(seriesID)","type":"series","name":"Show","videos":[{"id":"tt0944947:1:1","season":1,"episode":1}]}}"#
        let transport = StubTransport { request, _ in
            let json = request.url?.host == "www.omdbapi.com"
                ? #"{"Response":"True","Episodes":[{"Episode":"1","imdbRating":"8.9"}]}"# : meta
            return StubTransport.response(Data(json.utf8), for: request)
        }
        let manifest = Manifest(id: "test.meta", name: "Meta", version: "1", resources: [ResourceDescriptor(name: "meta")], types: ["series"])
        let (registry, client) = try await makeStubbedRegistry(manifests: [manifest], transport: transport)
        let ratings = PosterRatingsStore(omdb: OMDbRatings(client: client, apiKey: "test-key"),
                                         tmdb: TMDbRatings(client: client, readAccessToken: "test-token"))
        // The title's artwork is not under test here, so its lookup is skipped (`artworkChecked`).
        let model = DetailViewModel(preview: MetaPreview(id: seriesID, type: "series"),
                                    services: AppServices(registry: registry, client: client, posterRatings: ratings), artworkChecked: true)
        await model.load()
        let episode = try #require(model.episodes.first)
        await model.loadEpisodeSeason(episode.season)
        #expect(model.score(for: episode) == .init(value: 8.9, isIMDb: true))
        #expect(transport.requests.filter { $0.url?.host == "www.omdbapi.com" }.count == 1)
        #expect(!transport.requests.contains { $0.url?.host == "api.themoviedb.org" }, "IMDb already covered the season")
    }

    /// A series page whose meta has two unrated episodes, with OMDb answering `omdbStatus` with no scores and TMDb answering season scores.
    private func tmdbFallbackModel(omdbKey: Bool, requestsToday: Int = 0, omdbStatus: Int = 200) async throws
        -> (model: DetailViewModel, transport: StubTransport) {
        let meta = #"{"meta":{"id":"tt0944947","type":"series","name":"Show","videos":["#
            + #"{"id":"tt0944947:1:1","season":1,"episode":1},{"id":"tt0944947:1:2","season":1,"episode":2}]}}"#
        let transport = StubTransport { request, _ in
            switch request.url?.host {
            case "www.omdbapi.com":
                return StubTransport.response(Data(#"{"Response":"True","Episodes":[]}"#.utf8), status: omdbStatus, for: request)
            case "api.themoviedb.org":
                let json = request.url?.path.contains("/find/") == true
                    ? #"{"movie_results":[],"tv_results":[{"id":5}]}"#
                    : #"{"episodes":[{"episode_number":1,"vote_average":7.5,"vote_count":10}]}"#
                return StubTransport.response(Data(json.utf8), for: request)
            default:
                return StubTransport.response(Data(meta.utf8), for: request)
            }
        }
        let manifest = Manifest(id: "test.meta", name: "Meta", version: "1", resources: [ResourceDescriptor(name: "meta")], types: ["series"])
        let (registry, client) = try await makeStubbedRegistry(manifests: [manifest], transport: transport)
        let name = "DetailViewModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let usage = OMDbUsage(defaults: defaults)
        for _ in 0..<requestsToday { usage.record() }
        let ratings = PosterRatingsStore(omdb: omdbKey ? OMDbRatings(client: client, apiKey: "k", usage: usage) : nil,
                                         tmdb: TMDbRatings(client: client, readAccessToken: "t"))
        // The title's artwork is not under test here, so its lookup is skipped (`artworkChecked`) and TMDb is asked about episodes only.
        let model = DetailViewModel(preview: MetaPreview(id: "tt0944947", type: "series"),
                                    services: AppServices(registry: registry, client: client, posterRatings: ratings), artworkChecked: true)
        await model.load()
        return (model, transport)
    }

    private func tmdbRequests(_ transport: StubTransport) -> Int {
        transport.requests.filter { $0.url?.host == "api.themoviedb.org" }.count
    }

    @Test func tmdbFillsTheEpisodesOMDbHasNoScoreFor() async throws {
        let (model, transport) = try await tmdbFallbackModel(omdbKey: true)
        let episode = try #require(model.episodes.first)
        await model.loadEpisodeSeason(episode.season)
        #expect(transport.requests.contains { $0.url?.host == "www.omdbapi.com" })
        #expect(tmdbRequests(transport) >= 1, "an episode OMDb has no score for is filled from TMDb, OMDb being available or not")
    }

    @Test func tmdbEpisodeScoresAreUsedWithoutAnOMDbKey() async throws {
        let (model, transport) = try await tmdbFallbackModel(omdbKey: false)
        let episode = try #require(model.episodes.first)
        await model.loadEpisodeSeason(episode.season)
        #expect(tmdbRequests(transport) > 0)
        #expect(model.score(for: model.episodes[0]) == .init(value: 7.5, isIMDb: false))
    }

    @Test func tmdbEpisodeScoresAreUsedOnceTheDailyLimitIsReached() async throws {
        let (model, transport) = try await tmdbFallbackModel(omdbKey: true, requestsToday: OMDbUsage.dailyLimit)
        await model.loadEpisodeSeason(try #require(model.episodes.first).season)
        #expect(tmdbRequests(transport) > 0)
        #expect(model.score(for: model.episodes[0]) == .init(value: 7.5, isIMDb: false))
    }

    @Test func tmdbEpisodeScoresAreUsedOnceOMDbIsPausedByARateLimit() async throws {
        let (model, transport) = try await tmdbFallbackModel(omdbKey: true, omdbStatus: 429)
        await model.loadEpisodeSeason(try #require(model.episodes.first).season)
        #expect(tmdbRequests(transport) > 0)
        #expect(model.score(for: model.episodes[0]) == .init(value: 7.5, isIMDb: false))
    }

    @Test func aTMDbScoreFilledEarlierIsHiddenWhileOMDbIsAvailableButAnAddonScoreStays() async throws {
        let (model, _) = try await tmdbFallbackModel(omdbKey: true)
        let tmdb = Video(id: "tt0944947:1:1", season: 1, episode: 1, rating: 7.5, ratingSource: .tmdb)
        let addon = Video(id: "tt0944947:1:2", season: 1, episode: 2, rating: 6, ratingSource: .addon)
        #expect(model.score(for: tmdb) == nil)
        #expect(model.score(for: addon) == .init(value: 6, isIMDb: false))
        let (without, _) = try await tmdbFallbackModel(omdbKey: false)
        #expect(without.score(for: tmdb) == .init(value: 7.5, isIMDb: false))
    }

    @Test func episodeWidthToggleIsOffByDefaultSavedAndReadBackOnTheNextPage() async {
        let settings = InMemorySettingsStore()
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: 1, maxRetries: 0))
        let services = AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client),
                                   client: client, settings: settings)
        let preview = MetaPreview(id: "tt1", type: "series", name: "S")
        let model = DetailViewModel(preview: preview, services: services)
        #expect(!model.matchesEpisodeWidthToText)
        await model.setMatchesEpisodeWidthToText(true)
        #expect(model.matchesEpisodeWidthToText)
        #expect(await settings.load().matchesEpisodeWidthToText)
        let nextPage = DetailViewModel(preview: preview, services: services)
        await nextPage.load()
        #expect(nextPage.matchesEpisodeWidthToText)
        await nextPage.setMatchesEpisodeWidthToText(false)
        #expect(!(await settings.load().matchesEpisodeWidthToText))
    }

    @Test func trailersAreEmptyWithoutTrailers() {
        let model = DetailViewModel(preview: MetaPreview(id: "tt1", type: "movie", name: "X"), services: offlineServices())
        #expect(model.trailers.isEmpty)
    }

    @Test(arguments: [false, true])
    func detailUsesSeparateOriginalHeroesInsteadOfCatalogPosters(hasArtwork: Bool) async throws {
        let transport = StubTransport { request, _ in
            let json: String
            switch request.url?.lastPathComponent {
            case "tt0468569": json = #"{"movie_results":[{"id":155}]}"#
            case "images":
                json = #"""
                {"backdrops":[{"file_path":"/backdrop.jpg"}],
                 "posters":[{"file_path":"/poster.jpg"}],
                 "logos":[{"file_path":"/logo.png","iso_639_1":"en"}]}
                """#
            default: json = #"{"results":[]}"#
            }
            return StubTransport.response(Data(json.utf8), for: request)
        }
        let client = makeClient(transport)
        // The store holds the TMDb client, as it does in the app, and the title page reads its artwork through the store.
        let ratings = PosterRatingsStore(tmdb: TMDbRatings(client: client, readAccessToken: "test-key", titleIDs: TMDbTitleIDCache()))
        let services = AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client),
                                   client: client, settings: InMemorySettingsStore(PlaybackSettings(tmdbReadToken: "test-key")),
                                   posterRatings: ratings)
        let poster = URL(string: "https://example.com/poster.jpg")
        let backdrop = URL(string: "https://example.com/backdrop.jpg")
        let logo = URL(string: "https://example.com/logo.png")
        let preview = MetaPreview(id: "tt0468569", type: "movie", name: "Film", poster: hasArtwork ? poster : nil,
                                  background: hasArtwork ? backdrop : nil, logo: hasArtwork ? logo : nil)
        let model = DetailViewModel(preview: preview, services: services)
        await model.load()
        #expect(model.tmdbArtwork != nil)
        #expect(model.portraitArtworkURL == URL(string: "https://image.tmdb.org/t/p/original/poster.jpg"))
        #expect(model.backdropURL == URL(string: "https://image.tmdb.org/t/p/original/backdrop.jpg"))
        #expect(model.portraitArtworkURL != model.backdropURL)
        #expect(model.logoURL == (hasArtwork ? logo : URL(string: "https://image.tmdb.org/t/p/original/logo.png")))
        let openedFromHome = DetailViewModel(preview: preview, services: services, artwork: model.tmdbArtwork)
        #expect(!openedFromHome.isLoadingArtwork)
        #expect(openedFromHome.portraitArtworkURL == model.portraitArtworkURL)
        #expect(openedFromHome.backdropURL == model.backdropURL)
    }

    @Test func aTitleOpenedAgainThisSessionTakesItsArtworkWithoutAskingTMDbAgain() async throws {
        let transport = StubTransport { request, _ in
            let json = request.url?.lastPathComponent == "images"
                ? #"{"backdrops":[{"file_path":"/backdrop.jpg"}],"posters":[{"file_path":"/poster.jpg"}]}"#
                : #"{"movie_results":[{"id":155}]}"#
            return StubTransport.response(Data(json.utf8), for: request)
        }
        let client = makeClient(transport)
        let ratings = PosterRatingsStore(tmdb: TMDbRatings(client: client, readAccessToken: "test-key", titleIDs: TMDbTitleIDCache()))
        let services = AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client),
                                   client: client, posterRatings: ratings)
        let preview = MetaPreview(id: "tt0468569", type: "movie", name: "Film")
        let first = DetailViewModel(preview: preview, services: services)
        await first.load()
        let artworkRequests = { transport.requests.filter { $0.url?.lastPathComponent == "images" }.count }
        #expect(artworkRequests() == 1)
        let second = DetailViewModel(preview: preview, services: services)
        #expect(!second.isLoadingArtwork, "known at once, before the page loads")
        #expect(second.portraitArtworkURL == first.portraitArtworkURL)
        await second.load()
        #expect(artworkRequests() == 1, "the session keeps the answer")
    }

    @Test func heroLoadingWaitsForArtworkAndFallsBackWithoutUsingTheCatalogPoster() async {
        let background = URL(string: "https://example.com/hero.jpg")
        let preview = MetaPreview(id: "tt0468569", type: "movie", name: "Film", poster: URL(string: "https://example.com/poster.jpg"),
                                  background: background)
        let model = DetailViewModel(preview: preview, services: offlineServices())
        #expect(model.isLoadingArtwork)
        #expect(model.portraitArtworkURL == nil && model.backdropURL == nil)
        await model.load()
        #expect(!model.isLoadingArtwork)
        #expect(model.portraitArtworkURL == background && model.backdropURL == background)
    }

    @Test func heroMetaPartsAreTheSameForBothHeroes() {
        let preview = MetaPreview(id: "tt0468569", type: "movie", name: "The Dark Knight", releaseInfo: "2008", imdbRating: 9.0,
                                  genres: ["Action", "Crime", "Drama"], runtime: "152 min")
        #expect(DetailViewModel.heroMetaParts(for: preview, certification: "PG-13")
                == ["2008", "Action", "Crime", "PG-13", "152 min", "★ 90"], "year, two genres, certification, runtime, rating")
        #expect(DetailViewModel.heroMetaParts(for: preview, certification: nil)
                == ["2008", "Action", "Crime", nil, "152 min", "★ 90"], "the spotlight has no certification")
    }

    @Test func heroMetaPartsKeepMissingPartsAsNil() {
        let bare = MetaPreview(id: "tt1", type: "movie", name: "X")
        #expect(DetailViewModel.heroMetaParts(for: bare, certification: nil) == [nil, nil, nil, nil], "nothing known adds no text")
        let rated = MetaPreview(id: "tt2", type: "movie", name: "Y", imdbRating: 7)
        #expect(DetailViewModel.heroMetaParts(for: rated, certification: nil).last == "★ 70", "a whole rating is a whole score out of 100")
    }

    @Test func heroMetaGenresAreTheOnesTheLineShows() {
        let preview = MetaPreview(id: "tt0111161", type: "movie", name: "The Shawshank Redemption", releaseInfo: "1994", imdbRating: 9.3,
                                  genres: ["Drama", "Crime", "Thriller"], runtime: "142 min")
        #expect(DetailViewModel.heroMetaGenres(for: preview) == ["Drama", "Crime"], "the first two, which the line drops first")
        #expect(DetailViewModel.heroMetaParts(for: preview, certification: "R")
                == ["1994", "Drama", "Crime", "R", "142 min", "★ 93"], "the same genres sit in the line")
    }

    @Test func theMetaLineIsBuiltFromTheDetailsTheSpotlightKeeps() async throws {
        let services = try await installedServices()
        let preview = MetaPreview(id: "mock:movie3", type: "movie", name: "Preview Title")
        let model = DetailViewModel(preview: preview, services: services)
        await model.load()
        #expect(model.heroMetaLine == services.heroMeta.parts(for: preview, certification: nil, ratings: services.posterRatings))
        #expect(services.heroMeta.kept(for: preview) == model.detail.preview)
    }

    @Test func aPageOpenedAfterItsDetailsWereKeptStartsWithThem() async throws {
        let services = try await installedServices()
        let preview = MetaPreview(id: "mock:movie3", type: "movie", name: "Preview Title")
        let details = MetaPreview(id: "mock:movie3", type: "movie", name: "Mock Movie 3", genres: ["Drama"], runtime: "100 min")
        services.heroMeta.record(details, for: preview)
        let model = DetailViewModel(preview: preview, services: services)
        #expect(model.heroMetaLine == DetailViewModel.heroMetaParts(for: details, certification: nil),
                "the line is the kept one before the page loads")
    }

    @Test func heroMetaPartsShowIMDbsOwnScoreWhenTheCallerHasOne() {
        let preview = MetaPreview(id: "tt0468569", type: "movie", name: "The Dark Knight", releaseInfo: "2008", imdbRating: 9.0)
        #expect(DetailViewModel.heroMetaParts(for: preview, certification: nil, imdbRating: 8.4).last == "★ 84",
                "IMDb's own score replaces the catalog's")
        #expect(DetailViewModel.heroMetaParts(for: preview, certification: nil, imdbRating: nil).last == "★ 90",
                "without one, the catalog's score")
    }

    // MARK: trailers

    /// Services whose addon meta lists `trailers` as its trailer streams. The store has no preview, so the addon's trailers are the
    /// only ones.
    private func trailerServices(trailers: String) async throws -> AppServices {
        let meta = Data((#"{"meta":{"id":"tt7200001","type":"movie","name":"Trailer Movie","releaseInfo":"2010","#
            + #""trailerStreams":\#(trailers)}}"#).utf8)
        let transport = StubTransport { request, _ in StubTransport.response(meta, for: request) }
        let manifest = Manifest(id: "test.trailers", name: "Stub", version: "1", resources: [ResourceDescriptor(name: "meta")],
                                types: ["movie"])
        let (registry, client) = try await makeStubbedRegistry(manifests: [manifest], transport: transport)
        return AppServices(registry: registry, client: client)
    }

    @Test func aTitleWithNoTrailerCannotPlayOne() async throws {
        let services = try await trailerServices(trailers: "[]")
        let model = DetailViewModel(preview: MetaPreview(id: "tt7200001", type: "movie", name: "Trailer Movie", releaseInfo: "2010"),
                                    services: services)
        await model.load()
        #expect(model.trailers.isEmpty)
        #expect(!model.canPlayTrailer, "no trailer known: the button does nothing")
    }

    @Test func metadataIsReadyBeforeWaitingForTheHeroAndPlayUsesTheSavedEpisode() async throws {
        let services = try await installedServices()
        await saveProgress(services, id: "mock:series1:2:2", type: "series", position: 300, duration: 1200, updatedAt: Date(),
                           season: 2, episode: 2)
        let model = DetailViewModel(preview: MetaPreview(id: "mock:series1", type: "series", name: "S"), services: services)
        let whenLoaded = SeenRequest()
        await model.load(afterHero: { whenLoaded.id = !model.isLoading && model.detail.name != "S" ? "metadata-ready" : "still-loading" })
        #expect(whenLoaded.id == "metadata-ready")
        #expect(model.primaryRequest?.id == "mock:series1:2:2", "Play resumes the saved episode once metadata arrives")
        #expect(model.selectedSeason == 2)
    }

    @Test func theTrailerButtonWorksBeforeTheDetailsArrive() async throws {
        let trailers = #"[{"title":"Direct","url":"https://cdn.example.com/t.mp4"}]"#
        let services = try await trailerServices(trailers: trailers)
        let model = DetailViewModel(preview: MetaPreview(id: "tt7200001", type: "movie", name: "Trailer Movie", releaseInfo: "2010"),
                                    services: services)
        #expect(model.canPlayTrailer, "a tap is taken while the details load")
        async let plan = model.trailerPlan()
        await model.load()
        #expect(await plan.trailers.map(\.id) == ["url:https://cdn.example.com/t.mp4"], "the tap waited for the details' trailer")
    }

    @Test func theTrailerPlanListsTheAddonsDirectLinkBeforeItsYouTubeIDs() async throws {
        let trailers = #"[{"title":"Trailer","ytId":"EXeTwQWrcwY"},{"title":"Direct","url":"https://cdn.example.com/t.mp4"}]"#
        let services = try await trailerServices(trailers: trailers)
        let model = DetailViewModel(preview: MetaPreview(id: "tt7200001", type: "movie", name: "Trailer Movie", releaseInfo: "2010"),
                                    services: services)
        await model.load()
        #expect(model.canPlayTrailer)
        let plan = await model.trailerPlan()
        #expect(plan.trailers.map(\.id) == ["url:https://cdn.example.com/t.mp4", "yt:EXeTwQWrcwY"],
                "the direct file is tried first; the YouTube id is the fallback")
    }
}

/// What a test saw at one moment of a load.
@MainActor
private final class SeenRequest {
    var id: String?
}
