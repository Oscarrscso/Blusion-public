import Foundation
import PlayerKit
import StremioKit
import Testing
@testable import Persistence

/// The behaviour every `AddonStore` must have. Runs against the in-memory store everywhere and SwiftData on Apple platforms.
func exerciseAddonStoreContract(_ store: any AddonStore) async throws {
    #expect(try await store.loadAll().isEmpty)
    let when = Date(timeIntervalSince1970: 1_700_000_000)
    let a = AddonRecord(id: UUID(), manifestData: Data("a".utf8), isEnabled: true, order: 0, installedAt: when)
    let b = AddonRecord(id: UUID(), manifestData: Data("b".utf8), isEnabled: false, order: 1, installedAt: when)
    let c = AddonRecord(id: UUID(), manifestData: Data("c".utf8), isEnabled: true, order: 2, installedAt: when)

    try await store.save([a, b])
    #expect(try await store.loadAll().sorted { $0.order < $1.order } == [a, b])

    // update one, add one, drop one
    var updated = b
    updated.isEnabled = true
    updated.order = 0
    var moved = a
    moved.order = 1
    try await store.save([updated, moved, c])
    #expect(try await store.loadAll().sorted { $0.order < $1.order } == [updated, moved, c])

    try await store.save([c])
    #expect(try await store.loadAll() == [c])

    try await store.save([])
    #expect(try await store.loadAll().isEmpty)
}

func exerciseSecretStoreContract(_ store: any SecretStore) async throws {
    let key = "addon.\(UUID().uuidString).manifestURL"
    #expect(try await store.get(key) == nil)
    try await store.set("https://example.com/TOKEN/manifest.json", for: key)
    #expect(try await store.get(key) == "https://example.com/TOKEN/manifest.json")
    try await store.set("https://example.com/OTHER/manifest.json", for: key)
    #expect(try await store.get(key) == "https://example.com/OTHER/manifest.json", "set replaces")
    try await store.remove(key)
    #expect(try await store.get(key) == nil)
    try await store.remove(key)   // removing twice is fine
}

func exerciseProgressStoreContract(_ store: any ProgressStore) async {
    let when = Date(timeIntervalSince1970: 1_700_000_000)
    func item(_ id: String, _ age: TimeInterval, position: Double = 10, watched: Bool = false) -> WatchProgress {
        WatchProgress(id: "movie/\(id)", type: "movie", contentID: id, title: "T \(id)", poster: URL(string: "https://e.example.com/\(id).jpg"),
                      position: position, duration: 100, isWatched: watched, updatedAt: when.addingTimeInterval(age), season: nil, episode: nil)
    }
    #expect(await store.all().isEmpty)
    #expect(await store.progress(for: "movie/x") == nil)
    await store.save(item("old", 0))
    await store.save(item("new", 100))
    await store.save(item("mid", 50))
    #expect(await store.all().map(\.contentID) == ["new", "mid", "old"], "most recent first")
    #expect(await store.progress(for: "movie/mid") == item("mid", 50))

    await store.save(item("mid", 200, position: 99, watched: true))   // upsert
    let updated = await store.progress(for: "movie/mid")
    #expect(updated?.position == 99 && updated?.isWatched == true)
    let afterUpsert = await store.all()
    #expect(afterUpsert.count == 3 && afterUpsert.first?.contentID == "mid")

    let episode = WatchProgress(id: "series/tt9:2:5", type: "series", contentID: "tt9:2:5", title: "Show", position: 5, duration: 50, isWatched: false,
                                updatedAt: when, season: 2, episode: 5)
    await store.save(episode)
    #expect(await store.progress(for: "series/tt9:2:5") == episode, "season and episode survive")

    await store.remove("movie/new")
    #expect(await store.progress(for: "movie/new") == nil)
    await store.remove("movie/new")   // twice is fine
    await store.clear()
    #expect(await store.all().isEmpty)
}

func exerciseLibraryStoreContract(_ store: any LibraryStore) async {
    let when = Date(timeIntervalSince1970: 1_700_000_000)
    func item(_ id: String, _ age: TimeInterval) -> LibraryItem {
        LibraryItem(id: "movie/\(id)", type: "movie", contentID: id, name: "N \(id)", poster: URL(string: "https://e.example.com/\(id).jpg"), releaseInfo: "1999",
                    addedAt: when.addingTimeInterval(age))
    }
    #expect(await store.all().isEmpty)
    await store.add(item("a", 0))
    await store.add(item("b", 100))
    await store.add(item("a", 0))   // adding again keeps one
    #expect(await store.all() == [item("b", 100), item("a", 0)])
    let hasA = await store.contains("movie/a")
    let hasZ = await store.contains("movie/z")
    #expect(hasA && !hasZ)
    await store.remove("movie/b")
    #expect(await store.all() == [item("a", 0)])
    await store.clear()
    #expect(await store.all().isEmpty)
}

@Suite struct StoreContractTests {
    @Test func inMemoryAddonStore() async throws {
        try await exerciseAddonStoreContract(InMemoryAddonStore())
    }

    @Test func inMemorySecretStore() async throws {
        try await exerciseSecretStoreContract(InMemorySecretStore())
    }

    #if canImport(Darwin)
    /// The store of a Mac build that may not use the Keychain: a second store on the same file sees what the first saved, and
    /// no other account can read the file.
    @Test func fileSecretStoreKeepsItsValuesInAPrivateFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blusion-secrets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Secrets.json")
        try await exerciseSecretStoreContract(FileSecretStore(fileURL: file))

        try await FileSecretStore(fileURL: file).set("https://example.com/TOKEN/manifest.json", for: "addon.a.manifestURL")
        try await FileSecretStore(fileURL: file).set("key", for: "ratings.tmdb")
        #expect(try await FileSecretStore(fileURL: file).get("addon.a.manifestURL") == "https://example.com/TOKEN/manifest.json")
        let mode = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Secrets.json"], "no temporary file is left behind")
    }
    #endif

    @Test func inMemoryProgressStore() async {
        await exerciseProgressStoreContract(InMemoryProgressStore())
    }

    @Test func inMemoryLibraryStore() async {
        await exerciseLibraryStoreContract(InMemoryLibraryStore())
    }

    @Test func bootstrap() {
        #expect(PersistenceInfo.name == "Persistence")
    }
}
