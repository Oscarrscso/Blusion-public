import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

private struct StoreFailure: Error {}

/// Store that can be told to fail, to prove rollback.
private actor FlakyStore: AddonStore {
    var records: [AddonRecord] = []
    var failSaves = false

    func setFailSaves(_ value: Bool) { failSaves = value }
    func loadAll() async throws -> [AddonRecord] { records }
    func save(_ records: [AddonRecord]) async throws {
        if failSaves { throw StoreFailure() }
        self.records = records
    }
}

private actor FlakySecrets: SecretStore {
    var values: [String: String] = [:]
    var failSets = false

    func setFailSets(_ value: Bool) { failSets = value }
    func get(_ key: String) async throws -> String? { values[key] }
    func set(_ value: String, for key: String) async throws {
        if failSets { throw StoreFailure() }
        values[key] = value
    }
    func remove(_ key: String) async throws { values[key] = nil }
}

@Suite struct RegistryTests {
    let token = "tok_SECRET_42"

    private struct Rig {
        let registry: AddonRegistry
        let store: InMemoryAddonStore
        let secrets: InMemorySecretStore
        let sink: MemoryLogSink
        let server: MockServer
    }

    private func rig(store: InMemoryAddonStore = InMemoryAddonStore(), secrets: InMemorySecretStore = InMemorySecretStore()) throws -> Rig {
        let server = try MockServer.shared()
        let sink = MemoryLogSink()
        let logger = AddonLogger(sink: sink)
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: 5, maxRetries: 0, retryBackoff: 0.01), logger: logger)
        return Rig(registry: AddonRegistry(store: store, secrets: secrets, client: client, logger: logger), store: store, secrets: secrets, sink: sink, server: server)
    }

    /// `stremio://` form of a mock URL, the way users paste addon links.
    private func stremioLink(_ url: URL) -> String { url.absoluteString.replacingOccurrences(of: "http://", with: "stremio://") }

    // MARK: install

    @Test func installingNormalisesFetchesAndStores() async throws {
        let rig = try rig()
        let url = rig.server.catalogManifestURL(token: token)
        let addon = try await rig.registry.install(from: stremioLink(url))
        #expect(addon.name == "Mock Catalog")
        #expect(addon.manifestURL == url, "stremio:// to a LAN host becomes http://")
        #expect(addon.baseURL == rig.server.catalogBase(token: token))
        #expect(addon.isEnabled)
        #expect(await rig.registry.addons.map(\.id) == [addon.id])
        let secrets = await rig.secrets.snapshot
        #expect(secrets.values.contains(url.absoluteString), "the URL lives in the secret store")
    }

    @Test func storedMetadataNeverContainsTheURL() async throws {
        let rig = try rig()
        let url = rig.server.catalogManifestURL(token: token)
        _ = try await rig.registry.install(from: url.absoluteString)
        let records = try await rig.store.loadAll()
        #expect(records.count == 1)
        let json = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        #expect(!json.contains(token))
        #expect(!json.contains("127.0.0.1"))
        #expect(!json.contains("localhost"))
        #expect(!json.contains("http://"))
    }

    @Test func installingTheSameAddonTwiceIsRejected() async throws {
        let rig = try rig()
        let url = rig.server.catalogManifestURL(token: token)
        _ = try await rig.registry.install(from: url.absoluteString)
        await #expect(throws: RegistryError.alreadyInstalled) { try await rig.registry.install(from: url.absoluteString) }
        await #expect(throws: RegistryError.alreadyInstalled) { try await rig.registry.install(from: stremioLink(url)) }
        await #expect(throws: RegistryError.alreadyInstalled) { try await rig.registry.install(from: rig.server.catalogBase(token: token).absoluteString) }
        #expect(await rig.registry.addons.count == 1)
    }

    @Test func addonsWithTheSameManifestIdButDifferentURLsCoexist() async throws {
        let rig = try rig()
        _ = try await rig.registry.install(from: rig.server.catalogManifestURL(token: "one").absoluteString)
        _ = try await rig.registry.install(from: rig.server.catalogManifestURL(token: "two").absoluteString)
        #expect(await rig.registry.addons.count == 2)
    }

    @Test func badAddonsAreRejectedAndNothingIsStored() async throws {
        let rig = try rig()
        let cases: [(String, RegistryError)] = [
            (rig.server.catalogManifestURL(flags: ["badmanifest"]).absoluteString, .manifest(.invalidJSON)),
            (rig.server.catalogManifestURL(flags: ["manifest500"]).absoluteString, .manifest(.http(status: 500))),
            ("", .invalidURL(.empty)),
            ("ftp://example.com/manifest.json", .invalidURL(.unsupportedScheme("ftp"))),
            ("http://127.0.0.1:1/manifest.json", .manifest(.network("urlerror.\(URLError.Code.cannotConnectToHost.rawValue)"))),
        ]
        for (input, expected) in cases {
            do {
                _ = try await rig.registry.install(from: input)
                Issue.record("expected failure for \(input)")
            } catch let error as RegistryError {
                #expect(error == expected, "input: \(input)")
                #expect(!error.message.isEmpty)
            }
        }
        #expect(await rig.registry.addons.isEmpty)
        #expect(await rig.store.saveCount == 0)
        #expect(await rig.secrets.snapshot.isEmpty)
    }

    @Test func manifestsWithoutTypesStillInstall() async throws {
        let rig = try rig()
        let addon = try await rig.registry.install(from: rig.server.catalogManifestURL(flags: ["missingtypes"]).absoluteString)
        #expect(addon.manifest.types == ["movie", "series"], "derived from the catalogs")
    }

    @Test func storageFailuresRollBackCleanly() async throws {
        let server = try MockServer.shared()
        let store = FlakyStore()
        let secrets = FlakySecrets()
        let registry = AddonRegistry(store: store, secrets: secrets, client: AddonClient(configuration: AddonClientConfiguration(timeout: 5, maxRetries: 0)))
        await store.setFailSaves(true)
        await #expect(throws: RegistryError.storage("save")) { try await registry.install(from: server.catalogManifestURL().absoluteString) }
        #expect(await registry.addons.isEmpty)
        #expect(await secrets.values.isEmpty, "the secret written first is removed again")
        await secrets.setFailSets(true)
        await store.setFailSaves(false)
        await #expect(throws: RegistryError.storage("secret")) { try await registry.install(from: server.catalogManifestURL().absoluteString) }
        #expect(await registry.addons.isEmpty)
        // And a later success works.
        await secrets.setFailSets(false)
        _ = try await registry.install(from: server.catalogManifestURL().absoluteString)
        #expect(await registry.addons.count == 1)
        // A failed remove keeps the addon.
        await store.setFailSaves(true)
        let id = try #require(await registry.addons.first?.id)
        await #expect(throws: RegistryError.storage("save")) { try await registry.remove(id: id) }
        #expect(await registry.addons.count == 1)
        await #expect(throws: RegistryError.storage("save")) { try await registry.setEnabled(false, id: id) }
        #expect(await registry.addons.first?.isEnabled == true)
        await #expect(throws: RegistryError.storage("save")) { try await registry.move(id: id, to: 0) }
    }

    // MARK: persistence round trip

    @Test func aNewRegistryRestoresEverythingFromTheStores() async throws {
        let first = try rig()
        let a = try await first.registry.install(from: first.server.catalogManifestURL(token: "a").absoluteString)
        let b = try await first.registry.install(from: first.server.streamManifestURL(token: "b").absoluteString)
        try await first.registry.setEnabled(false, id: a.id)
        try await first.registry.move(id: b.id, to: 0)

        let second = try rig(store: first.store, secrets: first.secrets)
        try await second.registry.load()
        let restored = await second.registry.addons
        #expect(restored.map(\.id) == [b.id, a.id])
        #expect(restored.map(\.isEnabled) == [true, false])
        #expect(restored[1].manifestURL == a.manifestURL, "the URL comes back from the secret store")
        #expect(restored[1].baseURL == a.baseURL)
        #expect(restored[0].manifest == b.manifest)
    }

    @Test func recordsWithoutASecretAreSkippedNotFatal() async throws {
        let first = try rig()
        let a = try await first.registry.install(from: first.server.catalogManifestURL(token: "a").absoluteString)
        _ = try await first.registry.install(from: first.server.streamManifestURL(token: "b").absoluteString)
        try await first.secrets.remove("addon.\(a.id.uuidString).manifestURL")
        let second = try rig(store: first.store, secrets: first.secrets)
        try await second.registry.load()
        #expect(await second.registry.addons.count == 1)
        #expect(second.sink.lines.contains { $0.contains("skipping stored addon") })
    }

    // MARK: remove / enable / reorder

    @Test func removingDeletesRecordAndSecret() async throws {
        let rig = try rig()
        let addon = try await rig.registry.install(from: rig.server.catalogManifestURL(token: token).absoluteString)
        try await rig.registry.remove(id: addon.id)
        #expect(await rig.registry.addons.isEmpty)
        #expect(try await rig.store.loadAll().isEmpty)
        #expect(await rig.secrets.snapshot.isEmpty)
        await #expect(throws: RegistryError.notFound) { try await rig.registry.remove(id: addon.id) }
        await #expect(throws: RegistryError.notFound) { try await rig.registry.setEnabled(true, id: UUID()) }
        await #expect(throws: RegistryError.notFound) { try await rig.registry.move(id: UUID(), to: 0) }
        await #expect(throws: RegistryError.notFound) { try await rig.registry.refreshManifest(id: UUID()) }
    }

    @Test func reorderingByIndexAndByOffsets() async throws {
        let rig = try rig()
        var ids: [UUID] = []
        for name in ["a", "b", "c"] { ids.append(try await rig.registry.install(from: rig.server.catalogManifestURL(token: name).absoluteString).id) }
        let (a, b, c) = (ids[0], ids[1], ids[2])
        try await rig.registry.move(id: c, to: 0)
        #expect(await rig.registry.addons.map(\.id) == [c, a, b])
        try await rig.registry.move(id: c, to: 99)
        #expect(await rig.registry.addons.map(\.id) == [a, b, c], "indexes are clamped")
        try await rig.registry.move(id: c, to: -5)
        #expect(await rig.registry.addons.map(\.id) == [c, a, b])
        // SwiftUI onMove semantics: items end up before `toOffset`.
        try await rig.registry.move(fromOffsets: [0], toOffset: 3)
        #expect(await rig.registry.addons.map(\.id) == [a, b, c])
        try await rig.registry.move(fromOffsets: [2], toOffset: 0)
        #expect(await rig.registry.addons.map(\.id) == [c, a, b])
        try await rig.registry.move(fromOffsets: [0, 1], toOffset: 3)
        #expect(await rig.registry.addons.map(\.id) == [b, c, a])
        // Order is persisted.
        let records = try await rig.store.loadAll()
        #expect(records.sorted { $0.order < $1.order }.map(\.id) == [b, c, a])
    }

    @Test func refreshingAManifestKeepsTheInstall() async throws {
        let rig = try rig()
        let addon = try await rig.registry.install(from: rig.server.catalogManifestURL(token: token).absoluteString)
        try await rig.registry.refreshManifest(id: addon.id)
        #expect(await rig.registry.addon(id: addon.id)?.manifest == addon.manifest)
    }

    // MARK: routing

    @Test func routingBySupportedResourceTypeAndPrefix() async throws {
        let rig = try rig()
        let catalog = try await rig.registry.install(from: rig.server.catalogManifestURL().absoluteString)
        let streams = try await rig.registry.install(from: rig.server.streamManifestURL().absoluteString)
        #expect(await rig.registry.addons(for: .stream, type: "movie", id: "mock:movie1").map(\.id) == [streams.id])
        #expect(await rig.registry.addons(for: .meta, type: "movie", id: "mock:movie1").map(\.id) == [catalog.id])
        #expect(await rig.registry.addons(for: .subtitles, type: "movie", id: "mock:movie1").map(\.id) == [streams.id])
        #expect(await rig.registry.addons(for: .subtitles, type: "series", id: "mock:series1:1:1").isEmpty, "subtitles are movie-only in the mock")
        #expect(await rig.registry.addons(for: .stream, type: "movie", id: "tt1234567").isEmpty, "idPrefixes mock: excludes IMDb ids")
        #expect(await rig.registry.addons(providing: .catalog).map(\.id) == [catalog.id])
        try await rig.registry.setEnabled(false, id: streams.id)
        #expect(await rig.registry.addons(for: .stream, type: "movie", id: "mock:movie1").isEmpty, "disabled addons are never routed")
        #expect(await rig.registry.addons(providing: .stream).isEmpty)
    }

    // MARK: updates stream

    @Test func updatesEmitTheCurrentListThenEveryChange() async throws {
        let rig = try rig()
        var iterator = await rig.registry.updates().makeAsyncIterator()
        #expect(await iterator.next()?.isEmpty == true)
        let addon = try await rig.registry.install(from: rig.server.catalogManifestURL().absoluteString)
        #expect(await iterator.next()?.map(\.id) == [addon.id])
        try await rig.registry.setEnabled(false, id: addon.id)
        #expect(await iterator.next()?.first?.isEnabled == false)
        try await rig.registry.remove(id: addon.id)
        #expect(await iterator.next()?.isEmpty == true)
    }

    // MARK: secrets

    @Test func logsAndDescriptionsNeverContainTheToken() async throws {
        let rig = try rig()
        let addon = try await rig.registry.install(from: rig.server.catalogManifestURL(token: token).absoluteString)
        _ = try? await rig.registry.install(from: rig.server.catalogManifestURL(flags: ["badmanifest"], token: token).absoluteString)
        try await rig.registry.setEnabled(false, id: addon.id)
        try await rig.registry.remove(id: addon.id)
        #expect(!rig.sink.lines.isEmpty)
        for line in rig.sink.lines { #expect(!line.contains(token), "leaked in: \(line)") }
        #expect(!addon.description.contains(token))
        #expect(!addon.debugDescription.contains(token))
        #expect(!"\(addon)".contains(token))
        #expect(!String(reflecting: addon.summary).contains(token))
        #expect(addon.displayHost.hasPrefix("127.0.0.1") || addon.displayHost.hasPrefix("localhost"))
    }
}
