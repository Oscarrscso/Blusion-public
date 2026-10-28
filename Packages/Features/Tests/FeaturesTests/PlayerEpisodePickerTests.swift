import Foundation
import PlayerKit
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

@MainActor
@Suite struct PlayerEpisodePickerTests {
    /// The mock catalog addon installed, whose series has two seasons of three episodes.
    private func installedServices() async throws -> AppServices {
        let server = try MockServer.shared()
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: server.slowDelay + 4, maxRetries: 0))
        let services = AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client), client: client)
        _ = try await services.registry.install(from: server.catalogManifestURL().absoluteString)
        return services
    }

    /// The mock's second season's first episode, as the player opens it.
    private func playingRequest() -> StreamRequest {
        StreamRequest(type: "series", id: "mock:series1:2:1", title: "Mock Series One · Episode 1",
                      season: 2, episode: 1, seriesName: "Mock Series One")
    }

    @Test func opensOnTheSeasonPlayingAndListsItsEpisodes() async throws {
        let model = PlayerEpisodePickerModel(request: playingRequest(), services: try await installedServices())
        await model.load()
        #expect(!model.isLoading)
        #expect(model.failure == nil)
        #expect(model.seasons == [1, 2])
        #expect(model.selectedSeason == 2, "the season playing, not the first")
        #expect(model.episodes.map(\.id) == ["mock:series1:2:1", "mock:series1:2:2", "mock:series1:2:3"])
        #expect(model.episodes.filter(model.isCurrent).map(\.id) == ["mock:series1:2:1"])
    }

    @Test func anotherSeasonListsItsOwnEpisodes() async throws {
        let model = PlayerEpisodePickerModel(request: playingRequest(), services: try await installedServices())
        await model.load()
        await model.selectSeason(1)
        #expect(model.selectedSeason == 1)
        #expect(model.episodes.map(\.id) == ["mock:series1:1:1", "mock:series1:1:2", "mock:series1:1:3"])
        #expect(model.episodes.filter(model.isCurrent).isEmpty, "the playing episode is in the other season")
    }

    @Test func anEpisodeRequestPlaysThatEpisodeOfTheSeries() async throws {
        let model = PlayerEpisodePickerModel(request: playingRequest(), services: try await installedServices())
        await model.load()
        let video = try #require(model.episodes.first)
        let request = try #require(model.request(for: video))
        #expect(request.type == "series")
        #expect(request.id == "mock:series1:2:1")
        #expect(request.season == 2 && request.episode == 1)
        #expect(request.title == "Mock Series One · Episode 1")
        #expect(request.seriesName == "Mock Series One")
        #expect(request.nextID == "mock:series1:2:2", "the next episode is carried as it is from a card")
    }

    @Test func theSeriesIDIsTheEpisodesWithoutItsSeasonAndNumber() {
        #expect(PlayerEpisodePickerModel.seriesID(for: playingRequest()) == "mock:series1")
        #expect(PlayerEpisodePickerModel.seriesID(for: StreamRequest(type: "series", id: "tt0944947:1:2", title: "Show · Two",
                                                                   season: 1, episode: 2)) == "tt0944947")
        #expect(PlayerEpisodePickerModel.seriesID(for: StreamRequest(type: "series", id: "kitsu:123:4", title: "Show · Four",
                                                                   episode: 4)) == "kitsu:123:4",
                "an episode id with no season is the series' own id")
    }

    @Test func aSeriesTheAddonsCannotAnswerShowsWhyThereAreNoEpisodes() async throws {
        let transport = StubTransport { request, _ in StubTransport.response(Data(), status: 500, for: request) }
        let (registry, client) = try await makeStubbedRegistry(manifests: [], transport: transport)
        let services = AppServices(registry: registry, client: client)
        let model = PlayerEpisodePickerModel(request: playingRequest(), services: services)
        await model.load()
        #expect(!model.isLoading)
        #expect(model.episodes.isEmpty)
        #expect(model.failure == "The episodes couldn't be loaded.")
    }

    @Test func aChosenEpisodeIsReadiedFromItsStreams() async throws {
        let transport = StubTransport { request, _ in
            StubTransport.response(Data(#"{"streams":[{"name":"Mock 1080","url":"https://e.example.com/episode.mp4"}]}"#.utf8), for: request)
        }
        let (registry, client) = try await makeStubbedRegistry(manifests: [streamManifest("addon")], transport: transport)
        let services = AppServices(registry: registry, client: client)
        let movie = StreamRequest(type: "movie", id: "tt1", title: "Movie")
        let player = PlayerViewModel(plan: PlaybackPlan(request: movie, candidates: []), services: services)
        let chosen = StreamRequest(type: "series", id: "tt2:1:2", title: "Show · Two", season: 1, episode: 2, seriesName: "Show")
        let plan = await player.prepareEpisode(chosen)
        #expect(plan?.request.id == "tt2:1:2")
        #expect(plan?.candidates.first?.title == "Mock 1080")
        #expect(plan?.request.season == 1 && plan?.request.episode == 2)
    }
}
