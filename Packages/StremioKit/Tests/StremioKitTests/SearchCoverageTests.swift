import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

/// The "search finds nothing" bug end to end: which installed addons search asks, and what it gets back. Where the addon can
/// be installed (validation and all), the test goes through `AddonRegistry.install`, as the app does.
@Suite struct SearchCoverageTests {
    /// A registry that installs from any manifest URL, and a browse service on it. Every request goes to `transport`.
    private func installing(_ transport: StubTransport) -> (registry: AddonRegistry, browse: BrowseService) {
        let client = makeClient(transport, retries: 0)
        let registry = AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client)
        return (registry, BrowseService(registry: registry, client: client))
    }

    @Test func aCatalogOnlyManifestInstallsAndIsSearched() async throws {
        let manifest = #"""
        {"id":"org.example.catalogs","name":"Catalogs","version":"1.0.0",
         "catalogs":[{"type":"movie","id":"top","name":"Top","extra":[{"name":"search"}]}]}
        """#
        let transport = StubTransport { request, _ in
            let isSearch = request.url?.path.contains("/catalog/movie/top/") == true
            return StubTransport.response(Data((isSearch ? #"{"metas":[{"id":"tt1","name":"Found"}]}"# : manifest).utf8), for: request)
        }
        let (registry, browse) = installing(transport)
        let addon = try await registry.install(from: "https://catalogs.example.com/manifest.json")
        #expect(addon.manifest.resources.isEmpty, "no resources list at all")
        let response = try #require(await browse.search("found").collect().first)
        #expect(response.value?.map(\.id) == ["tt1"])
    }

    @Test func aCinemetaShapedManifestSearchesMoviesAndSeries() async throws {
        // Legacy `extraSupported` lists, a resource with its own types, and a series catalog: the shape real catalog addons send.
        let manifest = #"""
        {"id":"com.linvo.cinemeta","name":"Cinemeta","version":"3.0.13",
         "resources":["catalog",{"name":"meta","types":["movie","series"],"idPrefixes":["tt"]}],
         "types":["movie","series"],
         "catalogs":[
           {"type":"movie","id":"top","name":"Popular","extraSupported":["search","genre","skip"]},
           {"type":"series","id":"top","name":"Popular","extraSupported":["search","genre","skip"]}]}
        """#
        let transport = StubTransport { request, _ in
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("manifest.json") {
                body = manifest
            } else if path.contains("/catalog/series/top/") {
                body = #"{"metas":[{"id":"tt0903747","name":"Breaking Bad"}]}"#
            } else {
                body = #"{"metas":[{"id":"tt1375666","name":"Inception"}]}"#
            }
            return StubTransport.response(Data(body.utf8), for: request)
        }
        let (registry, browse) = installing(transport)
        _ = try await registry.install(from: "https://v3-cinemeta.example.com/manifest.json")
        let listed = await browse.catalogSources()
        #expect(listed.map(\.catalog.key) == ["movie/top", "series/top"])
        let responses = await browse.search("breaking").collect()
        let items = responses.flatMap { $0.value ?? [] }
        #expect(items.map(\.type) == ["movie", "series"], "both types come back, typed by their catalog")
        #expect(items.map(\.name) == ["Inception", "Breaking Bad"])
    }

    @Test func customTypesAreSearchedToo() async throws {
        let manifest = Manifest(id: "org.example.all", name: "Everything", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["all"],
                                catalogs: [CatalogDescriptor(type: "all", id: "everything", extra: [ExtraDescriptor(name: "search")])])
        let transport = StubTransport(data: Data(#"{"metas":[{"id":"x:1","name":"Odd One"}]}"#.utf8))
        let (registry, client) = try await makeStubbedRegistry(manifests: [manifest], transport: transport)
        let browse = BrowseService(registry: registry, client: client)
        let response = try #require(await browse.search("odd").collect().first)
        #expect(response.value?.map(\.type) == ["all"])
    }

    @Test func searchAsksExactlyTheAddonsThatSearchableAddonsNames() async throws {
        let cinemeta = Manifest(id: "meta", name: "Meta", version: "1",
                                resources: [ResourceDescriptor(name: "catalog"), ResourceDescriptor(name: "meta")], types: ["movie", "series"],
                                catalogs: [CatalogDescriptor(type: "movie", id: "top", extra: [ExtraDescriptor(name: "search")]),
                                           CatalogDescriptor(type: "series", id: "top", extra: [ExtraDescriptor(name: "search")])])
        let bare = Manifest(id: "bare", name: "Bare", version: "1", resources: [ResourceDescriptor(name: "meta")], types: ["movie"],
                            catalogs: [CatalogDescriptor(type: "movie", id: "bare", extra: [ExtraDescriptor(name: "search")])])
        let streams = Manifest(id: "streams", name: "Streams", version: "1", resources: [ResourceDescriptor(name: "stream")], types: ["movie"])
        let needsGenre = Manifest(id: "genre", name: "Genre", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
                                  catalogs: [CatalogDescriptor(type: "movie", id: "by-genre",
                                                               extra: [ExtraDescriptor(name: "search"), ExtraDescriptor(name: "genre", isRequired: true)])])
        let off = Manifest(id: "off", name: "Off", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
                           catalogs: [CatalogDescriptor(type: "movie", id: "off", extra: [ExtraDescriptor(name: "search")])])
        let transport = StubTransport(data: Data(#"{"metas":[{"id":"x1"}]}"#.utf8))
        let (registry, client) = try await makeStubbedRegistry(manifests: [cinemeta, streams, bare, needsGenre, off], transport: transport)
        let installed = await registry.addons
        let disabled = try #require(installed.first { $0.name == "Off" })
        try await registry.setEnabled(false, id: disabled.id)
        let browse = BrowseService(registry: registry, client: client)

        let searchable = await browse.searchableAddons()
        #expect(searchable.map(\.name) == ["Meta", "Bare"], "in the user's order; stream-only, genre-only and disabled addons are left out")
        let responses = await browse.search("x").collect()
        #expect(Set(responses.map(\.addon.id)) == Set(searchable.map(\.id)), "search asks exactly the addons searchableAddons() names")
        #expect(transport.callCount == 3, "Meta's two catalogs and Bare's one; nothing else")
        let hosts = transport.requests.compactMap { $0.url?.host }
        #expect(!hosts.contains("stub1.example.com"), "the stream-only addon is never asked")
        #expect(!transport.requests.contains { $0.url?.path.contains("/by-genre/") == true }, "a catalog that needs a genre is never searched")
    }
}
