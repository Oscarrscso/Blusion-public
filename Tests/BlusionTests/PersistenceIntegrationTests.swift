import Foundation
import Testing
import StremioKit
import Persistence

/// Runs in the simulator (app host), where the Keychain is available without extra entitlements.
@Suite struct PersistenceIntegrationTests {
    @Test func keychainStoreBehavesLikeASecretStore() async throws {
        let store = KeychainSecretStore(service: "app.blusion.player.tests.\(UUID().uuidString)")
        let key = "addon.\(UUID().uuidString).manifestURL"
        #expect(try await store.get(key) == nil)
        try await store.set("https://example.com/TOKEN/manifest.json", for: key)
        #expect(try await store.get(key) == "https://example.com/TOKEN/manifest.json")
        try await store.set("https://example.com/OTHER/manifest.json", for: key)
        #expect(try await store.get(key) == "https://example.com/OTHER/manifest.json")
        try await store.remove(key)
        #expect(try await store.get(key) == nil)
        try await store.remove(key)
    }

    @Test func registryUsesSwiftDataAndKeychainTogether() async throws {
        let container = try PersistenceContainer.make(inMemory: true)
        let store = SwiftDataAddonStore(container: container)
        let secrets = KeychainSecretStore(service: "app.blusion.player.tests.\(UUID().uuidString)")
        let manifest = Manifest(id: "x", name: "X", version: "1", resources: [ResourceDescriptor(name: "stream")], types: ["movie"])
        let id = UUID()
        let key = "addon.\(id.uuidString).manifestURL"
        try await store.save([AddonRecord(id: id, manifestData: try JSONEncoder().encode(manifest), isEnabled: true, order: 0, installedAt: Date())])
        try await secrets.set("https://example.com/TOKEN/manifest.json", for: key)
        defer { Task { try? await secrets.remove(key) } }

        let registry = AddonRegistry(store: store, secrets: secrets, client: AddonClient())
        try await registry.load()
        let addons = await registry.addons
        #expect(addons.map(\.name) == ["X"])
        #expect(addons.first?.manifestURL.absoluteString == "https://example.com/TOKEN/manifest.json")
    }
}
