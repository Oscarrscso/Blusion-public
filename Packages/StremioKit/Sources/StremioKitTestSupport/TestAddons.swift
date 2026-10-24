import Foundation
import StremioKit

public enum TestAddons {
    /// An installed addon pointing at `base`; resources and catalogs mirror the mock's catalog addon.
    public static func catalogAddon(base: URL, name: String = "Mock Catalog", enabled: Bool = true) -> InstalledAddon {
        let manifest = Manifest(
            id: "test.\(name)", name: name, version: "1.0.0",
            resources: [ResourceDescriptor(name: "catalog"), ResourceDescriptor(name: "meta")],
            types: ["movie", "series"],
            catalogs: [CatalogDescriptor(type: "movie", id: "mock-top", name: "Top"),
                       CatalogDescriptor(type: "movie", id: "mock-movies", name: "Movies",
                                         extra: [ExtraDescriptor(name: "search"), ExtraDescriptor(name: "genre", options: ["Action", "Drama", "Comedy"]),
                                             ExtraDescriptor(name: "skip")])],
            idPrefixes: ["mock:"])
        return InstalledAddon(manifestURL: base.appendingPathComponent("manifest.json"), baseURL: base, manifest: manifest, isEnabled: enabled)
    }
}

/// Seconds since `start`, for ordering assertions.
public func elapsed(since start: Date) -> TimeInterval { Date().timeIntervalSince(start) }

/// A registry preloaded with hand-written manifests (no network needed to install), answered by `transport`.
public func makeStubbedRegistry(manifests: [Manifest], transport: StubTransport, logger: AddonLogger = .silent)
    async throws -> (registry: AddonRegistry, client: AddonClient) {
    let store = InMemoryAddonStore()
    let secrets = InMemorySecretStore()
    var records: [AddonRecord] = []
    for (index, manifest) in manifests.enumerated() {
        let id = UUID()
        records.append(AddonRecord(id: id, manifestData: try JSONEncoder().encode(manifest), isEnabled: true, order: index, installedAt: Date()))
        try await secrets.set("https://stub\(index).example.com/TOKEN/manifest.json", for: "addon.\(id.uuidString).manifestURL")
    }
    try await store.save(records)
    let client = makeClient(transport, retries: 0, logger: logger)
    let registry = AddonRegistry(store: store, secrets: secrets, client: client, logger: logger)
    try await registry.load()
    return (registry, client)
}

/// Sniffer that answers from a table keyed by the URL's last path component; anything else is "no verdict".
public struct StubSniffer: ContainerSniffing {
    private let table: [String: MediaContainer]

    public init(_ table: [String: MediaContainer] = [:]) {
        self.table = table
    }

    public func sniff(url: URL, headers: [String: String]) async -> MediaContainer? { table[url.lastPathComponent] }
}

/// A manifest for an addon that answers `stream` requests for every movie and series id.
public func streamManifest(_ name: String) -> Manifest {
    Manifest(id: "stream.\(name)", name: name, version: "1",
             resources: [ResourceDescriptor(name: "stream", types: ["movie", "series"])], types: ["movie", "series"])
}
