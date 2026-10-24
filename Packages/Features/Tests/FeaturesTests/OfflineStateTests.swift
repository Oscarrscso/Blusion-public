import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

/// M8: "you're offline" is told apart from "one addon is down", and every screen has a state for it.
@MainActor
@Suite struct OfflineStateTests {
    @Test func onlyAnUnanimousOfflineCountsAsOffline() {
        #expect(!Connectivity.isOffline([]), "no failures is not offline")
        #expect(Connectivity.isOffline([.offline]) && Connectivity.isOffline([.offline, .offline]))
        #expect(!Connectivity.isOffline([.offline, .http(status: 500)]), "one reachable-but-broken addon means the network is up")
        #expect(!Connectivity.isOffline([.timeout]))
    }

    /// Installs real mock addons, then answers every later request as if the network were down.
    private func offlineServices(catalog: Bool = true, streams: Bool = true) async throws -> AppServices {
        let server = try MockServer.shared()
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: 5, maxRetries: 0, retryBackoff: 0.01))
        let registry = AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client)
        if catalog { _ = try await registry.install(from: server.catalogManifestURL(token: "off").absoluteString) }
        if streams { _ = try await registry.install(from: server.streamManifestURL(token: "off").absoluteString) }
        let down = makeClient(StubTransport { _, _ in throw URLError(.notConnectedToInternet) }, retries: 0)
        return AppServices(registry: registry, client: client, browse: BrowseService(registry: registry, client: down),
                           streams: StreamService(registry: registry, client: down),
                           widgetContent: WidgetContentService(registry: registry, client: down, settings: InMemorySettingsStore()))
    }

    @Test func homeShowsOneBannerWhenEveryRowIsOffline() async throws {
        let model = HomeViewModel(services: try await offlineServices())
        #expect(!model.isOffline, "not before anything has been tried")
        await model.load()
        #expect(model.phase == .ready && !model.sections.isEmpty)
        #expect(model.sections.contains { $0.state.error == .offline })
        #expect(model.sections.filter { $0.state.error != nil }.allSatisfy { $0.state.error == .offline }, "a row failed for another reason")
        #expect(model.isOffline)
    }

    @Test func homeDoesNotCallItOfflineWhenOneRowWorks() async throws {
        let server = try MockServer.shared()
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: 5, maxRetries: 0))
        let registry = AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client)
        _ = try await registry.install(from: server.catalogManifestURL(token: "ok").absoluteString)
        let model = HomeViewModel(services: AppServices(registry: registry, client: client))
        await model.load()
        #expect(model.sections.allSatisfy { $0.state.error == nil } && !model.isOffline)
    }

    @Test func searchSaysOfflineInsteadOfNoResults() async throws {
        let model = SearchViewModel(services: try await offlineServices(), debounce: .milliseconds(1))
        model.query = "anything"
        await model.submit()
        #expect(model.isOffline)
        #expect(!model.showsNoResults, "failures are shown, not an empty result")
        #expect(model.failures.allSatisfy { $0.error == .offline })
    }

    @Test func discoverFailsAsOfflineAndRecoversOnReload() async throws {
        let model = DiscoverViewModel(services: try await offlineServices())
        await model.loadSources()
        #expect(model.state == .failed(.offline) && model.isOffline)
    }

    @Test func streamsAreNotReportedAsMissingWhenOffline() async throws {
        let services = try await offlineServices(catalog: false)
        let model = StreamPickerViewModel(request: StreamRequest(type: "movie", id: "mock:movie1", title: "Mock Movie 1"), services: services)
        await model.load()
        #expect(model.isOffline)
        #expect(!model.showsNothingFound, "the offline banner replaces \"No streams found\"")
        #expect(model.listing.failures.count == 1)
    }

    @Test func aBrokenAddonStillReadsAsNothingFoundNotOffline() async throws {
        let server = try MockServer.shared()
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: 5, maxRetries: 0))
        let registry = AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client)
        _ = try await registry.install(from: server.streamManifestURL(token: "ok").absoluteString)
        let broken = makeClient(StubTransport { request, _ in StubTransport.response(Data(), status: 500, for: request) }, retries: 0)
        let services = AppServices(registry: registry, client: client, streams: StreamService(registry: registry, client: broken))
        let model = StreamPickerViewModel(request: StreamRequest(type: "movie", id: "mock:movie1", title: "Mock Movie 1"), services: services)
        await model.load()
        #expect(!model.isOffline && model.showsNothingFound)
    }
}
