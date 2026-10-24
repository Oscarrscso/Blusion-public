import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

/// A custom addon name, and the configuration page link the addon's long-press menu opens.
@Suite struct AddonRenameTests {
    private let manifest = Manifest(id: "test.named", name: "Original", version: "1", resources: [ResourceDescriptor(name: "catalog")],
                                    types: ["movie"], catalogs: [])

    @Test func aCustomNameReplacesTheManifestNameUntilClearedAndSurvivesARestart() async throws {
        let store = InMemoryAddonStore()
        let secrets = InMemorySecretStore()
        let id = UUID()
        try await store.save([AddonRecord(id: id, manifestData: try JSONEncoder().encode(manifest), isEnabled: true, order: 0, installedAt: Date())])
        try await secrets.set("https://stub.example.com/TOKEN/manifest.json", for: "addon.\(id.uuidString).manifestURL")
        let client = makeClient(StubTransport(data: Data()), retries: 0)
        let registry = AddonRegistry(store: store, secrets: secrets, client: client, logger: .silent)
        try await registry.load()

        #expect(await registry.addons.first?.name == "Original")
        try await registry.rename("  My Addon  ", id: id)
        #expect(await registry.addons.first?.name == "My Addon")
        #expect(await registry.addons.first?.manifest.name == "Original", "the manifest itself is untouched")

        let reopened = AddonRegistry(store: store, secrets: secrets, client: client, logger: .silent)
        try await reopened.load()
        #expect(await reopened.addons.first?.name == "My Addon")

        try await registry.rename("   ", id: id)
        #expect(await registry.addons.first?.name == "Original", "a blank name clears the custom one")
        await #expect(throws: RegistryError.notFound) { try await registry.rename("x", id: UUID()) }
    }

    @Test func recordsSavedBeforeRenamingStillDecode() throws {
        let id = UUID()
        let old = #"{"id":"\#(id.uuidString)","manifestData":"AA==","isEnabled":true,"order":2,"installedAt":0}"#
        let record = try JSONDecoder().decode(AddonRecord.self, from: Data(old.utf8))
        #expect(record.customName == nil && record.order == 2)
    }

    @Test func theConfigurePageIsTheManifestLinkWithConfigureInItsPlace() {
        func addon(_ link: String) -> InstalledAddon {
            InstalledAddon(manifestURL: URL(string: link)!, baseURL: URL(string: link)!.deletingLastPathComponent(), manifest: manifest)
        }
        #expect(addon("https://a.example.com/abc123/manifest.json").configureURL?.absoluteString == "https://a.example.com/abc123/configure")
        #expect(addon("https://a.example.com/manifest.json").configureURL?.absoluteString == "https://a.example.com/configure")
        #expect(addon("https://a.example.com/addon.json").configureURL == nil)
        #expect(addon("stremio://a.example.com/manifest.json").configureURL == nil)
    }
}
