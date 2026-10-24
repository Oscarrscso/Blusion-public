import Foundation
import Testing
import PlayerKit
import StremioKit
import StremioKitTestSupport
@testable import Features

@MainActor
@Suite struct TitleActionsTests {
    private let movie = MetaPreview(id: "tt1", type: "movie", name: "Film")
    private let series = MetaPreview(id: "tt9", type: "series", name: "Show")

    private func services(library: [LibraryItem] = [], progress: [WatchProgress] = []) -> AppServices {
        let client = makeClient(StubTransport(data: Data()))
        return AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client), client: client,
                           progress: InMemoryProgressStore(progress), library: InMemoryLibraryStore(library))
    }

    private func watched(_ id: String, type: String = "movie", season: Int? = nil, episode: Int? = nil, isWatched: Bool = true) -> WatchProgress {
        WatchProgress(id: "\(type)/\(id)", type: type, contentID: id, title: id, position: 0, duration: 0, isWatched: isWatched,
                      updatedAt: Date(), season: season, episode: episode)
    }

    @Test func savingAndUnsavingAMovie() async {
        let services = services()
        let actions = TitleActions(services: services)
        await actions.refresh()
        #expect(!actions.isSaved(movie))
        await actions.toggleSaved(movie)
        #expect(actions.isSaved(movie) && actions.savedIdentities == ["movie/tt1"])
        let stored = await services.library.all()
        #expect(stored.map(\.id) == ["movie/tt1"] && stored.first?.name == "Film")
        await actions.toggleSaved(movie)
        #expect(!actions.isSaved(movie) && actions.savedIdentities.isEmpty)
        let remaining = await services.library.all()
        #expect(remaining.isEmpty)
    }

    @Test func aTitleWithNoTypeIsKeyedAsAMovie() async {
        let services = services()
        let actions = TitleActions(services: services)
        let untyped = MetaPreview(id: "tt2", name: "Untyped")
        await actions.toggleSaved(untyped)
        #expect(actions.isSaved(untyped))
        let stored = await services.library.all()
        #expect(stored.map(\.id) == ["movie/tt2"])
        await actions.setWatched(true, for: untyped)
        #expect(actions.isWatched(untyped) && actions.watchedIdentities == ["movie/tt2"])
    }

    @Test func toggleFollowsTheStoreNotAStaleCache() async {
        let services = services(library: [LibraryItem(preview: movie, addedAt: Date())])
        let actions = TitleActions(services: services)
        // Not refreshed: the cache does not know the title is saved, so the toggle must ask the store.
        #expect(!actions.isSaved(movie))
        await actions.toggleSaved(movie)
        let remaining = await services.library.all()
        #expect(remaining.isEmpty && !actions.isSaved(movie))
    }

    @Test func markingAMovieWatchedAndBackAgain() async {
        let services = services()
        let actions = TitleActions(services: services)
        await actions.setWatched(true, for: movie)
        #expect(actions.isWatched(movie) && actions.watchedIdentities == ["movie/tt1"])
        let record = await services.progress.progress(for: "movie/tt1")
        #expect(record?.isWatched == true && record?.title == "Film")
        await actions.setWatched(false, for: movie)
        #expect(!actions.isWatched(movie) && actions.watchedIdentities.isEmpty)
        let cleared = await services.progress.progress(for: "movie/tt1")
        #expect(cleared == nil)
    }

    @Test func aSeriesIsNeverMarkedWatched() async {
        let services = services()
        let actions = TitleActions(services: services)
        await actions.setWatched(true, for: series)
        #expect(!actions.isWatched(series) && actions.watchedIdentities.isEmpty)
        let record = await services.progress.progress(for: "series/tt9")
        #expect(record == nil)
    }

    @Test func aShowIsMarkedWatchedEpisodeByEpisodeAndClearedAgain() async throws {
        let server = try MockServer.shared()
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: server.slowDelay + 4, maxRetries: 0))
        let services = AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client), client: client)
        _ = try await services.registry.install(from: server.catalogManifestURL().absoluteString)
        let actions = TitleActions(services: services)
        let show = MetaPreview(id: "mock:series1", type: "series", name: "S")
        #expect(!actions.hasWatchedEpisodes(show))
        await actions.setSeriesWatched(true, for: show)
        let marked = await services.progress.all().filter(\.isWatched)
        #expect(marked.count == 6, "both seasons of three episodes")
        #expect(actions.hasWatchedEpisodes(show) && actions.watchedIdentities.isEmpty, "a show is not a watched movie")
        #expect(marked.allSatisfy { $0.type == "series" && $0.contentID.hasPrefix("mock:series1:") && $0.season != nil && $0.episode != nil })
        await actions.setSeriesWatched(false, for: show)
        let left = await services.progress.all()
        #expect(left.isEmpty && !actions.hasWatchedEpisodes(show))
    }

    @Test func markingAShowNeedsItsEpisodesAndIgnoresMovies() async {
        let services = services()
        let actions = TitleActions(services: services)
        await actions.setSeriesWatched(true, for: series)
        await actions.setSeriesWatched(true, for: movie)
        let records = await services.progress.all()
        #expect(records.isEmpty, "no addon described the show, and a movie is not a show")
    }

    @Test func refreshPicksUpChangesMadeElsewhere() async {
        let services = services()
        let actions = TitleActions(services: services)
        await actions.refresh()
        #expect(!actions.isSaved(movie) && !actions.isWatched(movie))
        await services.library.add(LibraryItem(preview: movie, addedAt: Date()))
        await services.progress.save(watched("tt1"))
        await services.progress.save(watched("tt3", isWatched: false))
        await services.progress.save(watched("tt9:1:1", type: "series", season: 1, episode: 1))
        #expect(!actions.isSaved(movie), "nothing changes until it is refreshed")
        await actions.refresh()
        #expect(actions.isSaved(movie) && actions.isWatched(movie))
        #expect(actions.watchedIdentities == ["movie/tt1"], "unfinished movies and watched episodes are not watched titles")
    }

    @Test func savedAndWatchedStartEmptyBeforeTheFirstRefresh() async {
        let services = services(library: [LibraryItem(preview: movie, addedAt: Date())], progress: [watched("tt1")])
        let actions = TitleActions(services: services)
        #expect(actions.savedIdentities.isEmpty && actions.watchedIdentities.isEmpty)
        await actions.refresh()
        #expect(actions.savedIdentities == ["movie/tt1"] && actions.watchedIdentities == ["movie/tt1"])
    }
}
