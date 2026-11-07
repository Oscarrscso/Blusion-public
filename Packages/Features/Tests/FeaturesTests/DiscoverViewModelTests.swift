import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

@MainActor
@Suite struct DiscoverViewModelTests {
    private func services(_ server: MockServer) -> AppServices {
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: server.slowDelay + 4, maxRetries: 0, retryBackoff: 0.01))
        return AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client), client: client)
    }

    @Test func combinesEveryCatalogAndRemovesDuplicates() async throws {
        let server = try MockServer.shared()
        let services = services(server)
        _ = try await services.registry.install(from: server.catalogManifestURL(token: "one").absoluteString)
        _ = try await services.registry.install(from: server.catalogManifestURL(token: "two").absoluteString)
        let model = DiscoverViewModel(services: services)
        await model.loadSources()
        var expected = Set<String>()
        for source in model.sources {
            let page = try await services.browse.page(source)
            expected.formUnion(page.map(\.identity))
        }
        #expect(model.showsAllTypes)
        #expect(model.visibleSources == model.sources)
        #expect(Set(model.items.map(\.identity)) == expected)
        #expect(model.items.count == expected.count)
        #expect(model.state == .loaded)
    }

    @Test func nothingInstalledMeansNoSources() async throws {
        let model = DiscoverViewModel(services: services(try MockServer.shared()))
        await model.loadSources()
        #expect(!model.hasSources)
        #expect(model.items.isEmpty)
        await model.reload()
        await model.loadMore()
        #expect(model.state == .idle)
        #expect(!model.canLoadMore)
    }

    @Test func eachCatalogPaginatesWithoutRepeatingTitles() async throws {
        let server = try MockServer.shared()
        let services = services(server)
        _ = try await services.registry.install(from: server.catalogManifestURL().absoluteString)
        let model = DiscoverViewModel(services: services)
        await model.loadSources()
        var expected = Set(model.items.map(\.identity))
        for skip in [20, 40, 60] {
            for source in model.sources where source.catalog.supportsSkip {
                let page = try await services.browse.page(source, skip: skip)
                expected.formUnion(page.map(\.identity))
            }
            await model.loadMore()
        }
        #expect(Set(model.items.map(\.identity)) == expected)
        #expect(model.items.count == expected.count)
        #expect(!model.canLoadMore)
    }

    @Test func genreFilterAppliesAcrossCatalogs() async throws {
        let server = try MockServer.shared()
        let services = services(server)
        _ = try await services.registry.install(from: server.catalogManifestURL().absoluteString)
        let model = DiscoverViewModel(services: services)
        await model.loadSources()
        await model.select(genre: "Drama")
        #expect(model.selectedGenre == "Drama")
        #expect(!model.items.isEmpty)
        #expect(model.items.allSatisfy { $0.genres.contains("Drama") })
        await model.select(genre: nil)
        #expect(model.selectedGenre == nil)
    }

    @Test func anEmptyLocalGenrePageContinuesToTheNextRawPage() async throws {
        let manifest = Manifest(id: "genres", name: "Genres", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
                                catalogs: [CatalogDescriptor(type: "movie", id: "genres", extra: [ExtraDescriptor(name: "genre", options: ["Drama"])]),
                                           CatalogDescriptor(type: "movie", id: "paged", extra: [ExtraDescriptor(name: "skip")])])
        let transport = StubTransport { request, _ in
            let parsed = request.url.flatMap(AddonRequestBuilder.parse)
            let body: String
            if parsed?.id == "paged" {
                body = parsed?.extras.contains(ExtraParam("skip", "1")) == true
                    ? #"{"metas":[{"id":"tt2","type":"movie","name":"Drama","genres":["Drama"]}]}"#
                    : #"{"metas":[{"id":"tt1","type":"movie","name":"Action","genres":["Action"]}]}"#
            } else { body = #"{"metas":[]}"# }
            return StubTransport.response(Data(body.utf8), for: request)
        }
        let (registry, client) = try await makeStubbedRegistry(manifests: [manifest], transport: transport)
        let model = DiscoverViewModel(services: AppServices(registry: registry, client: client))
        await model.loadSources()
        await model.select(genre: "Drama")
        #expect(model.items.map(\.id) == ["tt2"])
        #expect(model.state == .loaded)
    }

    @Test func typesNarrowEveryCatalogAndAllRestoresThem() async throws {
        let server = try MockServer.shared()
        let services = services(server)
        _ = try await services.registry.install(from: server.catalogManifestURL().absoluteString)
        let model = DiscoverViewModel(services: services)
        await model.loadSources()
        await model.select(type: "movie")
        #expect(model.visibleSources.map(\.catalog.id) == ["mock-movies", "mock-top"])
        #expect(model.items.allSatisfy { $0.type == "movie" })
        await model.select(type: "series")
        #expect(model.visibleSources.map(\.catalog.id) == ["mock-series"])
        #expect(model.items.map(\.id) == ["mock:series1"])
        await model.select(type: "unknown")
        #expect(model.selectedType == "series")
        await model.selectAllTypes()
        #expect(model.visibleSources == model.sources)
        #expect(model.items.contains { $0.type == "movie" })
        #expect(model.items.contains { $0.type == "series" })
    }

    @Test func aStaleResponseCannotOverwriteANewerTypeChoice() async throws {
        let server = try MockServer.shared()
        let services = services(server)
        _ = try await services.registry.install(from: server.catalogManifestURL(flags: ["slow"]).absoluteString)
        let model = DiscoverViewModel(services: services)
        await model.loadSources()
        let pending = Task { await model.select(type: "movie") }
        try await Task.sleep(for: .milliseconds(150))
        await model.select(type: "series")
        await pending.value
        #expect(model.selectedType == "series")
        #expect(model.items.map(\.id) == ["mock:series1"])
    }

    @Test func refreshRemovesDisabledSourcesAndKeepsTheTypeChoice() async throws {
        let server = try MockServer.shared()
        let services = services(server)
        _ = try await services.registry.install(from: server.catalogManifestURL(token: "one").absoluteString)
        let second = try await services.registry.install(from: server.catalogManifestURL(token: "two").absoluteString)
        let model = DiscoverViewModel(services: services)
        await model.loadSources()
        await model.select(type: "series")
        try await services.registry.setEnabled(false, id: second.id)
        await model.loadSources()
        #expect(model.selectedType == "series")
        #expect(model.sources.allSatisfy { $0.addon.id != second.id })
        #expect(model.items.map(\.id) == ["mock:series1"])
    }

    @Test func failuresAreReported() async throws {
        let server = try MockServer.shared()
        let services = services(server)
        _ = try await services.registry.install(from: server.catalogManifestURL(flags: ["badjson"]).absoluteString)
        let model = DiscoverViewModel(services: services)
        await model.loadSources()
        #expect(model.state == .failed(.invalidJSON))
        #expect(model.items.isEmpty)
    }

    @Test func genresLeaveOutOrdersAndYearsAndRepeats() {
        func catalog(_ id: String, _ options: [String]) -> CatalogDescriptor {
            CatalogDescriptor(type: "movie", id: id, extra: [ExtraDescriptor(name: "genre", options: options)])
        }
        let genres = DiscoverViewModel.genres(of: [
            catalog("sorts", ["Date Added ↓", "Date Added ↑", "Title A-Z", "Title Z-A", "Actions"]),
            catalog("library", ["Recently Added", "Oldest Added", "Film Name", "Release Date (Newest)", "Release Date (Oldest)"]),
            catalog("years", ["2024", "2023", "1990s"]),
            catalog("genres", ["Thriller", "Action", "Top Rated", "Sci-Fi", "Comedy"]),
            catalog("more", ["action", "Drama", "Film-Noir"]),
        ])
        #expect(genres == ["Action", "Comedy", "Drama", "Film-Noir", "Sci-Fi", "Thriller"])
    }

    @Test func yearSpanLabelWordsTheSpanLikeTheLibraryChips() throws {
        let model = DiscoverViewModel(services: services(try MockServer.shared()))
        #expect(model.yearSpanLabel == nil)
        model.minimumYear = 1990
        model.maximumYear = 1999
        #expect(model.yearSpanLabel == "1990–1999")
        model.minimumYear = 2005
        model.maximumYear = 2005
        #expect(model.yearSpanLabel == "2005")
        model.minimumYear = 2000
        model.maximumYear = nil
        #expect(model.yearSpanLabel == "From 2000")
        model.minimumYear = nil
        model.maximumYear = 1979
        #expect(model.yearSpanLabel == "Until 1979")
    }
}
