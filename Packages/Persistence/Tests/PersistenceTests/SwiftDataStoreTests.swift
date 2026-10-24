#if canImport(SwiftData)
import Foundation
import PlayerKit
import StremioKit
import SwiftData
import Testing
@testable import Persistence

@Suite struct SwiftDataStoreTests {
    @Test func bulkProgressUpdatesPersistDeduplicateAndRemoveOnlyRequestedRecords() async throws {
        let container = try PersistenceContainer.make(inMemory: true)
        let store: any ProgressStore = SwiftDataProgressStore(container: container)
        let first = WatchProgress(id: "series/tt1:1:1", type: "series", contentID: "tt1:1:1", title: "Episode",
                                  position: 10, duration: 100, isWatched: false, updatedAt: Date())
        var updated = first
        updated.isWatched = true
        let other = WatchProgress(id: "movie/tt2", type: "movie", contentID: "tt2", title: "Other", position: 20, duration: 100, isWatched: false, updatedAt: Date())
        await store.save([first, other, updated])
        let reopened = SwiftDataProgressStore(container: container)
        #expect(await reopened.all().count == 2)
        #expect(await reopened.progress(for: [first.id, "missing"]) == [updated])
        await store.remove([first.id, "missing"])
        #expect(await reopened.all() == [other])
    }

    @Test func bulkLibraryAdditionsPreserveExistingItemsAndDeduplicateNewOnes() async throws {
        let container = try PersistenceContainer.make(inMemory: true)
        let store: any LibraryStore = SwiftDataLibraryStore(container: container)
        let original = LibraryItem(preview: MetaPreview(id: "tt1", type: "movie", name: "Original"))
        var changed = original
        changed.name = "Changed"
        let other = LibraryItem(preview: MetaPreview(id: "tt2", type: "movie", name: "Other"))
        await store.add(original)
        await store.add([changed, other, other])
        let saved = await SwiftDataLibraryStore(container: container).all()
        #expect(saved.count == 2)
        #expect(saved.first { $0.id == original.id } == original)
    }
    @Test func satisfiesTheAddonStoreContract() async throws {
        let container = try PersistenceContainer.make(inMemory: true)
        try await exerciseAddonStoreContract(SwiftDataAddonStore(container: container))
    }

    @Test func satisfiesTheProgressStoreContract() async throws {
        let container = try PersistenceContainer.make(inMemory: true)
        await exerciseProgressStoreContract(SwiftDataProgressStore(container: container))
    }

    @Test func satisfiesTheLibraryStoreContract() async throws {
        let container = try PersistenceContainer.make(inMemory: true)
        await exerciseLibraryStoreContract(SwiftDataLibraryStore(container: container))
    }

    @Test func aSecondStoreOnTheSameContainerSeesSavedRecords() async throws {
        let container = try PersistenceContainer.make(inMemory: true)
        let record = AddonRecord(id: UUID(), manifestData: Data("m".utf8), isEnabled: true, order: 0, installedAt: Date(timeIntervalSince1970: 1))
        try await SwiftDataAddonStore(container: container).save([record])
        #expect(try await SwiftDataAddonStore(container: container).loadAll() == [record])
    }

    @Test func registryWorksOnTopOfSwiftData() async throws {
        let container = try PersistenceContainer.make(inMemory: true)
        let store = SwiftDataAddonStore(container: container)
        let secrets = InMemorySecretStore()
        let manifest = Manifest(id: "x", name: "X", version: "1", resources: [ResourceDescriptor(name: "stream")], types: ["movie"])
        let record = AddonRecord(id: UUID(), manifestData: try JSONEncoder().encode(manifest), isEnabled: true, order: 0, installedAt: Date())
        try await store.save([record])
        try await secrets.set("https://example.com/manifest.json", for: "addon.\(record.id.uuidString).manifestURL")
        let registry = AddonRegistry(store: store, secrets: secrets, client: AddonClient())
        try await registry.load()
        #expect(await registry.addons.map(\.name) == ["X"])
    }

    /// PLAN M7: persistence tests including a schema migration. A store written with schema V1 (addons only) is reopened with V2 + the
    /// migration plan: addons survive, and the new progress and library stores work on the same file.
    @Test func aVersionOneStoreMigratesToVersionTwoKeepingItsAddons() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("blusion-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("blusion.store")
        let record = AddonRecord(id: UUID(), manifestData: Data("manifest".utf8), isEnabled: false, order: 3, installedAt: Date(timeIntervalSince1970: 1_700_000_000))

        do {
            let v1 = Schema(versionedSchema: BlusionSchemaV1.self)
            let container = try ModelContainer(for: v1, configurations: [ModelConfiguration(schema: v1, url: url, cloudKitDatabase: .none)])
            let context = ModelContext(container)
            context.insert(BlusionSchemaV1.AddonEntity(id: record.id, manifestData: record.manifestData, isEnabled: record.isEnabled, order: record.order,
                                                       installedAt: record.installedAt))
            try context.save()
        }

        let migrated = try PersistenceContainer.make(url: url)
        #expect(try await SwiftDataAddonStore(container: migrated).loadAll() == [record], "the V1 addon row survived the migration")

        let progress = SwiftDataProgressStore(container: migrated)
        await progress.save(WatchProgress(id: "movie/tt1", type: "movie", contentID: "tt1", title: "T", position: 5, duration: 50, isWatched: false, updatedAt: Date()))
        #expect(await progress.progress(for: "movie/tt1")?.position == 5)
        let library = SwiftDataLibraryStore(container: migrated)
        await library.add(LibraryItem(preview: MetaPreview(id: "tt1", name: "T")))
        #expect(await library.contains("movie/tt1"))
    }

    /// A store written with schema V2 keeps its saved titles when reopened with V3, which adds genres and ratings to them.
    @Test func aVersionTwoStoreMigratesToVersionThreeKeepingItsLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("blusion-migration-v3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("blusion.store")
        let added = Date(timeIntervalSince1970: 1_700_000_000)

        do {
            let v2 = Schema(versionedSchema: BlusionSchemaV2.self)
            let container = try ModelContainer(for: v2, configurations: [ModelConfiguration(schema: v2, url: url, cloudKitDatabase: .none)])
            let context = ModelContext(container)
            context.insert(BlusionSchemaV2.LibraryEntity(id: "movie/tt1", type: "movie", contentID: "tt1", name: "Old", posterURLString: nil,
                                                         releaseInfo: "1999", addedAt: added))
            try context.save()
        }

        let migrated = try PersistenceContainer.make(url: url)
        let library = SwiftDataLibraryStore(container: migrated)
        let kept = try #require(await library.all().first)
        #expect(kept.name == "Old" && kept.releaseInfo == "1999" && kept.addedAt == added, "the V2 row survived the migration")
        #expect(kept.genres.isEmpty && kept.imdbRating == nil, "a row from before V3 has no genres or rating")

        await library.add(LibraryItem(id: "series/tt2", type: "series", contentID: "tt2", name: "New", addedAt: added, genres: ["Drama"], imdbRating: 8.1))
        let reopened = await SwiftDataLibraryStore(container: try PersistenceContainer.make(url: url)).all()
        #expect(reopened.first { $0.id == "series/tt2" }?.genres == ["Drama"])
        #expect(reopened.first { $0.id == "series/tt2" }?.imdbRating == 8.1)
    }

    #if targetEnvironment(macCatalyst) || os(macOS)
    /// `Application Support/default.store` belongs to whichever unsandboxed Mac app made it first. The Mac app once opened such
    /// a file, could not read it and ran from memory.
    @Test func onTheMacTheStoreLivesInAFolderOfItsOwn() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("blusion-support-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let url = try #require(PersistenceContainer.defaultStoreURL(bundleID: "example.blusion", support: support))
        #expect(url == support.appendingPathComponent("example.blusion/Blusion.store"))

        let record = AddonRecord(id: UUID(), manifestData: Data("m".utf8), isEnabled: true, order: 0, installedAt: Date(timeIntervalSince1970: 1))
        try await SwiftDataAddonStore(container: try PersistenceContainer.make(url: url)).save([record])
        #expect(try await SwiftDataAddonStore(container: try PersistenceContainer.make(url: url)).loadAll() == [record])
    }
    #endif

    @Test func theSchemaVersionsAreOrdered() {
        #expect(BlusionSchemaV1.versionIdentifier < BlusionSchemaV2.versionIdentifier)
        #expect(BlusionSchemaV2.versionIdentifier < BlusionSchemaV3.versionIdentifier)
        #expect(BlusionSchemaV3.versionIdentifier < BlusionSchemaV4.versionIdentifier)
        #expect(BlusionMigrationPlan.schemas.count == 4)
        #expect(BlusionMigrationPlan.stages.count == 3)
    }

    /// A store written before addons could be renamed keeps its addons, with no custom name, and can then save one.
    @Test func aVersionThreeStoreMigratesToVersionFourKeepingItsAddons() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("blusion-migration-v4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("blusion.store")
        let id = UUID()
        let installed = Date(timeIntervalSince1970: 1_700_000_000)

        do {
            let v3 = Schema(versionedSchema: BlusionSchemaV3.self)
            let container = try ModelContainer(for: v3, configurations: [ModelConfiguration(schema: v3, url: url, cloudKitDatabase: .none)])
            let context = ModelContext(container)
            context.insert(BlusionSchemaV1.AddonEntity(id: id, manifestData: Data("manifest".utf8), isEnabled: true, order: 1, installedAt: installed))
            try context.save()
        }

        let migrated = try PersistenceContainer.make(url: url)
        let store = SwiftDataAddonStore(container: migrated)
        let loaded = try await store.loadAll()
        #expect(loaded == [AddonRecord(id: id, manifestData: Data("manifest".utf8), isEnabled: true, order: 1, installedAt: installed)])
        #expect(loaded.first?.customName == nil)

        var renamed = try #require(loaded.first)
        renamed.customName = "My Cinemeta"
        try await store.save([renamed])
        #expect(try await store.loadAll().first?.customName == "My Cinemeta")
    }
}
#endif
