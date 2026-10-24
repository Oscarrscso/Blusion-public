import Foundation
import StremioKit
import StremioKitTestSupport
import Testing
@testable import Features

@MainActor
@Suite struct HeroMetaStoreTests {
    private static let movie = MetaPreview(id: "tt0468569", type: "movie", name: "The Dark Knight", releaseInfo: "2008")
    private static let metaJSON = #"{"meta":{"id":"tt0468569","type":"movie","name":"The Dark Knight","releaseInfo":"2008","#
        + #""genres":["Action","Crime"],"runtime":"152 min"}}"#

    /// Services whose only addon answers `meta` with `body` and `status`, with the transport that counts its requests.
    private func stubbed(status: Int = 200, body: String = Self.metaJSON) async throws -> (store: HeroMetaStore, transport: StubTransport) {
        let transport = StubTransport { request, _ in StubTransport.response(Data(body.utf8), status: status, for: request) }
        let resources = [ResourceDescriptor(name: "meta")]
        let manifest = Manifest(id: "test.meta", name: "Meta", version: "1", resources: resources, types: ["movie"])
        let (registry, client) = try await makeStubbedRegistry(manifests: [manifest], transport: transport)
        return (AppServices(registry: registry, client: client).heroMeta, transport)
    }

    /// Meta requests the stub has received.
    private func metaRequests(_ transport: StubTransport) -> Int {
        transport.requests.filter { $0.url?.path.contains("/meta/") == true }.count
    }

    /// A store whose addons are never reached: for the parts that only keep what they are given.
    private func offlineStore() -> HeroMetaStore {
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: 1, maxRetries: 0))
        return AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client),
                           client: client).heroMeta
    }

    @Test func beforeLoadingTheItemIsShownAsItIs() {
        let store = offlineStore()
        #expect(store.kept(for: Self.movie) == nil)
        #expect(store.preview(for: Self.movie) == Self.movie)
    }

    @Test func loadingKeepsTheAddonsDetails() async throws {
        let (store, transport) = try await stubbed()
        await store.load(for: Self.movie)
        let kept = try #require(store.kept(for: Self.movie))
        #expect(kept.genres == ["Action", "Crime"])
        #expect(kept.runtime == "152 min")
        #expect(store.preview(for: Self.movie) == kept)
        #expect(metaRequests(transport) == 1)
    }

    @Test func aTitleNoAddonAnswersForKeepsNothingAndIsAskedAgain() async throws {
        let (store, transport) = try await stubbed(status: 404, body: "{}")
        await store.load(for: Self.movie)
        #expect(store.kept(for: Self.movie) == nil)
        #expect(store.preview(for: Self.movie) == Self.movie)
        await store.load(for: Self.movie)
        #expect(metaRequests(transport) == 2, "an answer built from the item alone is not kept, so it is asked for again")
    }

    @Test func recordReplacesTheKeptDetails() async throws {
        let (store, _) = try await stubbed()
        await store.load(for: Self.movie)
        var details = Self.movie
        details.genres = ["Drama"]
        details.runtime = "90 min"
        store.record(details, for: Self.movie)
        #expect(store.kept(for: Self.movie) == details)
        #expect(store.preview(for: Self.movie) == details)
    }

    @Test func simultaneousLoadsAskTheAddonsOnce() async throws {
        let (store, transport) = try await stubbed()
        async let first: Void = store.load(for: Self.movie)
        async let second: Void = store.load(for: Self.movie)
        _ = await (first, second)
        #expect(metaRequests(transport) == 1, "the second caller waits for the first request")
        #expect(store.kept(for: Self.movie)?.genres == ["Action", "Crime"])
    }
}
