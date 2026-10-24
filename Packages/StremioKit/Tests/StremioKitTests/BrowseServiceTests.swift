import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

@Suite struct BrowseServiceTests {
    private struct Rig {
        let browse: BrowseService
        let registry: AddonRegistry
        let server: MockServer
    }

    private func makeRig(visibleTypes: Set<String>? = nil) throws -> Rig {
        let server = try MockServer.shared()
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: server.slowDelay + 4, maxRetries: 0, retryBackoff: 0.01))
        let registry = AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client)
        return Rig(browse: BrowseService(registry: registry, client: client, visibleTypes: visibleTypes), registry: registry, server: server)
    }

    @Test func catalogSourcesFollowAddonOrderAndHideUnsupportedTypes() async throws {
        let rig = try makeRig(visibleTypes: ["movie"])
        let first = try await rig.registry.install(from: rig.server.catalogManifestURL(token: "one").absoluteString)
        _ = try await rig.registry.install(from: rig.server.streamManifestURL().absoluteString)
        let second = try await rig.registry.install(from: rig.server.catalogManifestURL(token: "two").absoluteString)
        let sources = await rig.browse.catalogSources()
        #expect(sources.map(\.catalog.id) == ["mock-movies", "mock-top", "mock-movies", "mock-top"], "series hidden, stream-only addon contributes nothing")
        #expect(sources.map(\.addon.id) == [first.id, first.id, second.id, second.id])
        #expect(Set(sources.map(\.id)).count == 4, "ids are unique across addons")

        try await rig.registry.setEnabled(false, id: first.id)
        #expect(await rig.browse.catalogSources().map(\.addon.id) == [second.id, second.id])

        let all = try makeRig(visibleTypes: ["movie", "series"])
        _ = try await all.registry.install(from: all.server.catalogManifestURL(token: "x").absoluteString)
        #expect(await all.browse.catalogSources().map(\.catalog.id) == ["mock-movies", "mock-top", "mock-series"])
        #expect(await all.browse.catalogSources(type: "series").map(\.catalog.id) == ["mock-series"])
    }

    @Test func pagesGenresAndSkip() async throws {
        let rig = try makeRig()
        _ = try await rig.registry.install(from: rig.server.catalogManifestURL().absoluteString)
        let movies = try #require(await rig.browse.catalogSources().first { $0.catalog.id == "mock-movies" })
        let top = try #require(await rig.browse.catalogSources().first { $0.catalog.id == "mock-top" })

        let first = try await rig.browse.page(movies)
        let second = try await rig.browse.page(movies, skip: 20)
        #expect(first.count == 20 && second.count == 20)
        #expect(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
        #expect(try await rig.browse.page(movies, skip: 40).count == 5)
        #expect(try await rig.browse.page(movies, skip: 60).isEmpty)

        let drama = try await rig.browse.page(movies, genre: "Drama")
        #expect(!drama.isEmpty && drama.allSatisfy { $0.genres.contains("Drama") })
        #expect(try await rig.browse.page(movies, genre: "").count == 20, "an empty genre means no filter")

        // A catalog without genre/skip support ignores both instead of sending them.
        #expect(try await rig.browse.page(top, genre: "Drama", skip: 20).count == 4)
    }

    @Test func searchFansOutAndIsolatesFailures() async throws {
        let rig = try makeRig()
        let a = try await rig.registry.install(from: rig.server.catalogManifestURL(token: "a").absoluteString)
        let broken = try await rig.registry.install(from: rig.server.catalogManifestURL(token: "b").absoluteString)
        // A manifest installs fine, then its resources fail: swap the registry entry for an err500 base via a fresh addon.
        try await rig.registry.remove(id: broken.id)
        let bad = try await rig.registry.install(from: rig.server.catalogManifestURL(flags: ["err500"], token: "c").absoluteString)
        _ = try await rig.registry.install(from: rig.server.streamManifestURL().absoluteString)

        let responses = await rig.browse.search("movie 12").collect()
        #expect(responses.count == 2, "stream-only addons are not asked")
        #expect(responses.first { $0.addon.id == a.id }?.value?.map(\.id) == ["mock:movie12"])
        #expect(responses.first { $0.addon.id == bad.id }?.error == .http(status: 500))
    }

    @Test func emptyQueriesSearchNothing() async throws {
        let rig = try makeRig()
        _ = try await rig.registry.install(from: rig.server.catalogManifestURL().absoluteString)
        #expect(await rig.browse.search("").collect().isEmpty)
        #expect(await rig.browse.search("   \n").collect().isEmpty)
        #expect(await rig.browse.search("  movie 7  ").collect().first?.value?.map(\.id) == ["mock:movie7"], "the query is trimmed")
    }

    @Test func incrementalSearchPublishesFastCatalogBeforeItsSlowSibling() async throws {
        let manifest = Manifest(id: "partial", name: "Partial", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
                                catalogs: [CatalogDescriptor(type: "movie", id: "slow", extra: [ExtraDescriptor(name: "search")]),
                                           CatalogDescriptor(type: "movie", id: "fast", extra: [ExtraDescriptor(name: "search")])])
        let transport = StubTransport { request, _ in
            let slow = request.url?.path.contains("/slow/") == true
            if slow { try await Task.sleep(for: .milliseconds(200)) }
            let id = slow ? "tt1" : "tt2"
            return StubTransport.response(Data("{\"metas\":[{\"id\":\"\(id)\"}]}".utf8), for: request)
        }
        let browse = try await stubbedService(manifests: [manifest], transport: transport)
        var iterator = await browse.search("title", incremental: true).makeAsyncIterator()
        #expect(await iterator.next()?.value?.map(\.id) == ["tt2"])
        #expect(await iterator.next()?.value?.map(\.id) == ["tt1", "tt2"], "final order follows catalogs, not arrival order")
        #expect(await iterator.next() == nil)
    }

    @Test func searchMergesAnAddonsCatalogsAndDeduplicates() async throws {
        let manifest = Manifest(
            id: "multi", name: "Multi", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie", "series"],
            catalogs: [CatalogDescriptor(type: "movie", id: "a", extra: [ExtraDescriptor(name: "search")]),
                       CatalogDescriptor(type: "movie", id: "b", extra: [ExtraDescriptor(name: "search")]),
                       CatalogDescriptor(type: "movie", id: "needs-genre", extra: [ExtraDescriptor(name: "search"), ExtraDescriptor(name: "genre", isRequired: true)])])
        let transport = StubTransport { request, _ in
            let path = request.url?.path ?? ""
            let body: String
            if path.contains("/catalog/movie/a/") {
                body = #"{"metas":[{"id":"tt1","name":"One"},{"id":"tt2","name":"Two"}]}"#
            } else if path.contains("/catalog/movie/b/") {
                body = #"{"metas":[{"id":"tt2","name":"Two"},{"id":"tt3","name":"Three"}]}"#
            } else {
                body = #"{"metas":[{"id":"never"}]}"#
            }
            return StubTransport.response(Data(body.utf8), for: request)
        }
        let browse = try await stubbedService(manifests: [manifest], transport: transport, visibleTypes: ["movie", "series"])
        let response = try #require(await browse.search("x").collect().first)
        #expect(response.value?.map(\.id) == ["tt1", "tt2", "tt3"], "catalog order kept, tt2 only once, the genre-requiring catalog skipped")
        #expect(transport.callCount == 2)
    }

    @Test func anAddonOnlyFailsWhenAllItsCatalogsFail() async throws {
        let manifest = Manifest(
            id: "partial", name: "Partial", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
            catalogs: [CatalogDescriptor(type: "movie", id: "good", extra: [ExtraDescriptor(name: "search")]),
                       CatalogDescriptor(type: "movie", id: "bad", extra: [ExtraDescriptor(name: "search")])])
        let transport = StubTransport { request, _ in
            let isGood = request.url?.path.contains("/good/") == true
            return StubTransport.response(isGood ? Data(#"{"metas":[{"id":"tt1"}]}"#.utf8) : Data(), status: isGood ? 200 : 500, for: request)
        }
        let browse = try await stubbedService(manifests: [manifest], transport: transport, visibleTypes: ["movie", "series"])
        #expect(await browse.search("x").collect().first?.value?.map(\.id) == ["tt1"])

        let allBad = StubTransport(data: Data(), status: 500)
        let failing = try await stubbedService(manifests: [manifest], transport: allBad, visibleTypes: ["movie", "series"])
        #expect(await failing.search("x").collect().first?.error == .http(status: 500))
    }

    @Test func detailUsesTheAddonsMetaAndKeepsThePreviewPoster() async throws {
        let rig = try makeRig()
        _ = try await rig.registry.install(from: rig.server.catalogManifestURL().absoluteString)
        let preview = MetaPreview(id: "mock:movie3", type: "movie", name: "Preview Name", poster: URL(string: "https://example.com/p.jpg"))
        let result = await rig.browse.detail(for: preview)
        #expect(!result.isFallback)
        #expect(result.detail.name == "Mock Movie 3", "the addon's meta wins")
        #expect(result.detail.cast == ["Mock Actor A", "Mock Actor B"])
    }

    @Test func detailFallsBackToThePreviewWhenMetaFailsOrNobodyAnswers() async throws {
        let rig = try makeRig()
        _ = try await rig.registry.install(from: rig.server.catalogManifestURL().absoluteString)
        let preview = MetaPreview(id: "mock:nometa1", type: "movie", name: "Preview Only Movie", poster: URL(string: "https://example.com/p.jpg"), releaseInfo: "2001")
        let missing = await rig.browse.detail(for: preview)
        #expect(missing.isFallback)
        #expect(missing.detail.name == "Preview Only Movie")
        #expect(missing.detail.preview.releaseInfo == "2001")

        let nobody = try makeRig() // no addons at all
        let none = await nobody.browse.detail(for: preview)
        #expect(none.isFallback && none.detail.name == "Preview Only Movie")

        // An id nobody's idPrefixes accept is not even asked.
        let foreign = await rig.browse.detail(for: MetaPreview(id: "tt999", type: "movie", name: "Foreign"))
        #expect(foreign.isFallback)
    }

    /// Two addons that both give details for an IMDb id: Cinemeta first in the list, then one that answers for any id, sooner, with another
    /// title (a search result used to open as an episode of something else this way).
    private func metaRace(firstDelay: Duration, firstStatus: Int = 200) async throws -> BrowseService {
        let first = Manifest(id: "first", name: "First", version: "1", resources: [ResourceDescriptor(name: "meta", idPrefixes: ["tt"])],
                             types: ["movie"], catalogs: [])
        let catchAll = Manifest(id: "any", name: "Any", version: "1", resources: [ResourceDescriptor(name: "meta")], types: ["movie", "series"],
                                catalogs: [])
        let transport = StubTransport { request, _ in
            if request.url?.host == "stub0.example.com" {
                try await Task.sleep(for: firstDelay)
                return StubTransport.response(Data(#"{"meta":{"id":"tt4920274","type":"movie","name":"Regular Show: The Movie"}}"#.utf8),
                                              status: firstStatus, for: request)
            }
            return StubTransport.response(Data(#"{"meta":{"id":"tt4920274","type":"series","name":"A Time Loop Episode"}}"#.utf8), for: request)
        }
        return try await stubbedService(manifests: [first, catchAll], transport: transport, visibleTypes: ["movie", "series"])
    }

    @Test func detailTakesTheFirstAddonInOrderNotTheFastest() async throws {
        let browse = try await metaRace(firstDelay: .milliseconds(300))
        let result = await browse.detail(for: MetaPreview(id: "tt4920274", type: "movie", name: "Regular Show: The Movie"))
        #expect(!result.isFallback)
        #expect(result.detail.name == "Regular Show: The Movie", "the addon higher in the list wins, though the other answered first")
    }

    @Test func detailFallsToTheNextAddonWhenTheFirstFails() async throws {
        let browse = try await metaRace(firstDelay: .milliseconds(50), firstStatus: 500)
        let result = await browse.detail(for: MetaPreview(id: "tt4920274", type: "movie", name: "Regular Show: The Movie"))
        #expect(!result.isFallback)
        #expect(result.detail.name == "A Time Loop Episode", "with nothing from the first, the next one's details are used")
    }

    @Test func theFirstAnswerInOrderWaitsOnlyForTheAddonsAboveIt() {
        #expect(BrowseService.firstAnswerInOrder([1: "b"], settled: [1], count: 3) == nil, "the first addon has not answered yet")
        #expect(BrowseService.firstAnswerInOrder([1: "b"], settled: [0, 1], count: 3) == "b", "the first failed, the second has one")
        #expect(BrowseService.firstAnswerInOrder([0: "a"], settled: [0], count: 3) == "a", "the first answers: no waiting for the rest")
        #expect(BrowseService.firstAnswerInOrder([Int: String](), settled: [0, 1, 2], count: 3) == nil, "nobody has one")
    }

    @Test func detailSurvivesABrokenAddonWhenAnotherAnswers() async throws {
        let rig = try makeRig()
        _ = try await rig.registry.install(from: rig.server.catalogManifestURL(flags: ["err500"], token: "x").absoluteString)
        _ = try await rig.registry.install(from: rig.server.catalogManifestURL(token: "y").absoluteString)
        let result = await rig.browse.detail(for: MetaPreview(id: "mock:movie5", type: "movie", name: "P"))
        #expect(!result.isFallback)
        #expect(result.detail.name == "Mock Movie 5")
    }

    @Test func fillingKeepsAddonFieldsAndBackfillsMissingOnes() {
        let preview = MetaPreview(id: "x", type: "movie", name: "P", poster: URL(string: "https://e.com/p.jpg"), description: "from preview",
                                  releaseInfo: "1999", imdbRating: 7, genres: ["Action"])
        var detail = MetaDetail(preview: MetaPreview(id: "x", type: "", name: "D", description: "from meta"))
        detail = detail.filling(from: preview)
        #expect(detail.name == "D")
        #expect(detail.preview.description == "from meta")
        #expect(detail.preview.poster?.absoluteString == "https://e.com/p.jpg")
        #expect(detail.preview.releaseInfo == "1999")
        #expect(detail.preview.imdbRating == 7)
        #expect(detail.preview.genres == ["Action"])
        #expect(detail.type == "movie")
    }

    @Test func searchableCatalogsMustNotRequireAnythingElse() {
        #expect(CatalogDescriptor(type: "movie", id: "a", extra: [ExtraDescriptor(name: "search")]).isSearchable)
        #expect(CatalogDescriptor(type: "movie", id: "a", extra: [ExtraDescriptor(name: "search", isRequired: true)]).isSearchable)
        #expect(!CatalogDescriptor(type: "movie", id: "a", extra: [ExtraDescriptor(name: "search"), ExtraDescriptor(name: "genre", isRequired: true)]).isSearchable)
        #expect(!CatalogDescriptor(type: "movie", id: "a", extra: [ExtraDescriptor(name: "skip")]).isSearchable)
    }

    /// A browse service over hand-written manifests answered by `transport`. Every type is visible unless `visibleTypes` narrows it.
    private func stubbedService(manifests: [Manifest], transport: StubTransport, visibleTypes: Set<String>? = nil) async throws -> BrowseService {
        let store = InMemoryAddonStore()
        let secrets = InMemorySecretStore()
        var records: [AddonRecord] = []
        for (index, manifest) in manifests.enumerated() {
            let id = UUID()
            records.append(AddonRecord(id: id, manifestData: try JSONEncoder().encode(manifest), isEnabled: true, order: index, installedAt: Date()))
            try await secrets.set("https://stub\(index).example.com/TOKEN/manifest.json", for: "addon.\(id.uuidString).manifestURL")
        }
        try await store.save(records)
        let client = makeClient(transport, retries: 0)
        let registry = AddonRegistry(store: store, secrets: secrets, client: client)
        try await registry.load()
        return BrowseService(registry: registry, client: client, visibleTypes: visibleTypes)
    }

    @Test func everyContentTypeIsListedByDefault() async throws {
        let rig = try makeRig()
        _ = try await rig.registry.install(from: rig.server.catalogManifestURL().absoluteString)
        let sources = await rig.browse.catalogSources()
        #expect(sources.map(\.catalog.id) == ["mock-movies", "mock-top", "mock-series"], "the series catalog is listed by default")
        let series = await rig.browse.catalogSources(type: "series")
        #expect(series.map(\.catalog.id) == ["mock-series"])
    }

    @Test func seriesCatalogsAreSearchedByDefault() async throws {
        let manifest = Manifest(id: "shows", name: "Shows", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["series"],
                                catalogs: [CatalogDescriptor(type: "series", id: "top", name: "Top Shows", extra: [ExtraDescriptor(name: "search")])])
        let transport = StubTransport { request, _ in
            let isSeriesSearch = request.url?.path.contains("/catalog/series/top/") == true
            let body = isSeriesSearch ? #"{"metas":[{"id":"tt0903747","name":"Breaking Bad"}]}"# : #"{"metas":[]}"#
            return StubTransport.response(Data(body.utf8), for: request)
        }
        let browse = try await stubbedService(manifests: [manifest], transport: transport)
        let listed = await browse.catalogSources()
        #expect(listed.map(\.catalog.id) == ["top"])
        let response = try #require(await browse.search("breaking").collect().first)
        #expect(response.value?.map(\.name) == ["Breaking Bad"])
        #expect(response.value?.first?.type == "series", "items take the catalog's type when the addon omits it")
    }

    @Test func catalogsWithoutTheCatalogResourceAreListedAndSearched() async throws {
        let manifest = Manifest(id: "no-resource", name: "No Resource", version: "1", resources: [ResourceDescriptor(name: "meta")], types: ["movie"],
                                catalogs: [CatalogDescriptor(type: "movie", id: "found", name: "Found", extra: [ExtraDescriptor(name: "search")])])
        let transport = StubTransport(data: Data(#"{"metas":[{"id":"tt1","name":"Found It"}]}"#.utf8))
        let browse = try await stubbedService(manifests: [manifest], transport: transport)
        let listed = await browse.catalogSources()
        #expect(listed.map(\.catalog.id) == ["found"])
        let addons = await browse.searchableAddons()
        #expect(addons.map(\.name) == ["No Resource"])
        let response = try #require(await browse.search("found").collect().first)
        #expect(response.value?.map(\.id) == ["tt1"])
    }

    @Test func streamOnlyAddonsAreNeverSearchable() async throws {
        let rig = try makeRig()
        _ = try await rig.registry.install(from: rig.server.streamManifestURL().absoluteString)
        let none = await rig.browse.searchableAddons()
        #expect(none.isEmpty)
        #expect(await rig.browse.search("movie 12").collect().isEmpty, "no addon is asked")
        let catalog = try await rig.registry.install(from: rig.server.catalogManifestURL().absoluteString)
        let found = await rig.browse.searchableAddons()
        #expect(found == [catalog.summary])
    }

    @Test func visibleTypesNarrowListingAndSearching() async throws {
        let seriesOnly = try makeRig(visibleTypes: ["series"])
        _ = try await seriesOnly.registry.install(from: seriesOnly.server.catalogManifestURL().absoluteString)
        let searchable = await seriesOnly.browse.searchableAddons()
        #expect(searchable.isEmpty, "the mock's only searchable catalog is a movie catalog")
        let results = await seriesOnly.browse.search("movie 1").collect()
        #expect(results.isEmpty)
        let sources = await seriesOnly.browse.catalogSources()
        #expect(sources.map(\.catalog.id) == ["mock-series"])
    }
}
