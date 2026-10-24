import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

@MainActor
@Suite struct DefaultAddonSeederTests {
    private static let cinemeta = #"""
    {"id":"com.linvo.cinemeta","name":"Cinemeta","version":"1","resources":["catalog","meta"],"types":["movie","series"],
     "catalogs":[{"type":"movie","id":"top","name":"Popular","extra":[{"name":"search"}]}]}
    """#

    /// A registry whose every request goes to `transport`; nothing touches the network.
    private func makeRegistry(_ transport: StubTransport) -> AddonRegistry {
        AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: makeClient(transport, retries: 0))
    }

    private func cinemetaAnswers() -> StubTransport {
        StubTransport(data: Data(Self.cinemeta.utf8))
    }

    @Test func firstLaunchInstallsTheDefaultAddonAndRemembersIt() async {
        let transport = cinemetaAnswers()
        let registry = makeRegistry(transport)
        let flags = InMemoryFlagStore()
        let outcome = await DefaultAddonSeeder(registry: registry, flags: flags).seedIfNeeded()
        #expect(outcome == .installed)
        #expect(flags.bool(forKey: DefaultAddonSeeder.flagKey))
        let addons = await registry.addons
        #expect(addons.map(\.manifest.id) == ["com.linvo.cinemeta"])
        #expect(transport.requests.first?.url?.host == "v3-cinemeta.strem.io", "Cinemeta's manifest is the default")
    }

    @Test func aSecondLaunchDoesNothingAndAsksNobody() async {
        let transport = cinemetaAnswers()
        let registry = makeRegistry(transport)
        let flags = InMemoryFlagStore()
        _ = await DefaultAddonSeeder(registry: registry, flags: flags).seedIfNeeded()
        let again = await DefaultAddonSeeder(registry: registry, flags: flags).seedIfNeeded()
        #expect(again == .alreadyDone)
        #expect(transport.callCount == 1, "only the first launch asked the network")
    }

    @Test func aRemovedDefaultAddonIsNotInstalledAgain() async throws {
        let transport = cinemetaAnswers()
        let registry = makeRegistry(transport)
        let flags = InMemoryFlagStore()
        _ = await DefaultAddonSeeder(registry: registry, flags: flags).seedIfNeeded()
        let installed = await registry.addons
        let addon = try #require(installed.first)
        try await registry.remove(id: addon.id)
        let outcome = await DefaultAddonSeeder(registry: registry, flags: flags).seedIfNeeded()
        #expect(outcome == .alreadyDone)
        let remaining = await registry.addons
        #expect(remaining.isEmpty)
        #expect(transport.callCount == 1)
    }

    @Test func anAddonAlreadyInstalledByTheUserIsRecognisedWithoutAnotherInstall() async throws {
        let transport = cinemetaAnswers()
        let registry = makeRegistry(transport)
        _ = try await registry.install(from: "https://v3-cinemeta.strem.io/manifest.json")
        let flags = InMemoryFlagStore()
        let outcome = await DefaultAddonSeeder(registry: registry, flags: flags).seedIfNeeded()
        #expect(outcome == .alreadyInstalled)
        #expect(flags.bool(forKey: DefaultAddonSeeder.flagKey), "remembered, so it is not looked at again")
        #expect(transport.callCount == 1, "the manual install was the only request")
    }

    @Test func aFailedInstallLeavesTheFlagUnsetSoTheNextLaunchTriesAgain() async {
        let offline = StubTransport { _, _ in throw URLError(.notConnectedToInternet) }
        let flags = InMemoryFlagStore()
        let failed = await DefaultAddonSeeder(registry: makeRegistry(offline), flags: flags).seedIfNeeded()
        #expect(failed == .failed(.manifest(.offline)))
        #expect(!flags.bool(forKey: DefaultAddonSeeder.flagKey), "a failed attempt is not remembered")

        let registry = makeRegistry(cinemetaAnswers())
        let retried = await DefaultAddonSeeder(registry: registry, flags: flags).seedIfNeeded()
        #expect(retried == .installed)
        #expect(flags.bool(forKey: DefaultAddonSeeder.flagKey))
        let addons = await registry.addons
        #expect(addons.count == 1)
    }

    @Test func defaultsFlagStoreRemembersAcrossInstances() throws {
        let suite = "blusion.tests.flags.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!DefaultsFlagStore(defaults: defaults).bool(forKey: DefaultAddonSeeder.flagKey))
        DefaultsFlagStore(defaults: defaults).set(true, forKey: DefaultAddonSeeder.flagKey)
        #expect(DefaultsFlagStore(defaults: defaults).bool(forKey: DefaultAddonSeeder.flagKey))
    }
}
