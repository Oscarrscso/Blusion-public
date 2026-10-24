#if canImport(SwiftData)
import Foundation
import PlayerKit
import StremioKit
import SwiftData

public enum PersistenceContainer {
    /// The app's container at the current schema (V4), migrating older stores forward. `inMemory` is for tests; otherwise the store lives
    /// at `url` (default: `defaultStoreURL()`, or SwiftData's default location where that is nil).
    public static func make(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: BlusionSchemaV4.self)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else if let url = url ?? defaultStoreURL() {
            configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: BlusionMigrationPlan.self, configurations: [configuration])
    }

    /// SwiftData's default location is `Application Support/default.store`. On iOS that is the app's own file. A Mac app that is
    /// not sandboxed shares the folder with every other such app and would open whichever one's store got there first, so on
    /// the Mac the store goes into a folder named after the bundle id. Nil means SwiftData's default.
    static func defaultStoreURL(
        bundleID: String? = Bundle.main.bundleIdentifier,
        support: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) -> URL? {
        #if targetEnvironment(macCatalyst) || os(macOS)
        guard let bundleID, let support else { return nil }
        let folder = support.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("Blusion.store")
        #else
        return nil
        #endif
    }
}

/// `AddonStore` backed by SwiftData. The context is confined to this actor.
public actor SwiftDataAddonStore: AddonStore {
    private let container: ModelContainer
    /// Created on first use, on this actor's executor, so the context is never bound to the main queue the store was built on.
    private lazy var context = ModelContext(container)

    public init(container: ModelContainer) {
        self.container = container
    }

    public func loadAll() async throws -> [AddonRecord] {
        let entities = try context.fetch(FetchDescriptor<AddonEntity>(sortBy: [SortDescriptor(\.order)]))
        return entities.map {
            AddonRecord(id: $0.id, manifestData: $0.manifestData, isEnabled: $0.isEnabled, order: $0.order, installedAt: $0.installedAt,
                        customName: $0.customName)
        }
    }

    public func save(_ records: [AddonRecord]) async throws {
        let existing = try context.fetch(FetchDescriptor<AddonEntity>())
        var byID: [UUID: AddonEntity] = [:]
        for entity in existing { byID[entity.id] = entity }
        let wanted = Set(records.map(\.id))
        for entity in existing where !wanted.contains(entity.id) { context.delete(entity) }
        for record in records {
            if let entity = byID[record.id] {
                entity.manifestData = record.manifestData
                entity.isEnabled = record.isEnabled
                entity.order = record.order
                entity.installedAt = record.installedAt
                entity.customName = record.customName
            } else {
                context.insert(AddonEntity(id: record.id, manifestData: record.manifestData, isEnabled: record.isEnabled,
                                           order: record.order, installedAt: record.installedAt, customName: record.customName))
            }
        }
        try context.save()
    }
}

/// `ProgressStore` backed by SwiftData.
public actor SwiftDataProgressStore: ProgressStore {
    private let container: ModelContainer
    /// Created on first use, on this actor's executor, so the context is never bound to the main queue the store was built on.
    private lazy var context = ModelContext(container)

    public init(container: ModelContainer) {
        self.container = container
    }

    private func fetch(_ identity: String) -> WatchProgressEntity? {
        var descriptor = FetchDescriptor<WatchProgressEntity>(predicate: #Predicate { $0.id == identity })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func progress(from entity: WatchProgressEntity) -> WatchProgress {
        WatchProgress(id: entity.id, type: entity.type, contentID: entity.contentID, title: entity.title,
                      poster: entity.posterURLString.flatMap(URL.init(string:)), position: entity.position, duration: entity.duration,
                      isWatched: entity.isWatched, updatedAt: entity.updatedAt, season: entity.season, episode: entity.episode)
    }

    public func progress(for identity: String) async -> WatchProgress? {
        fetch(identity).map(Self.progress(from:))
    }

    public func save(_ progress: WatchProgress) async {
        await save([progress])
    }

    public func progress(for identities: [String]) async -> [WatchProgress] {
        guard !identities.isEmpty else { return [] }
        let descriptor = FetchDescriptor<WatchProgressEntity>(predicate: #Predicate { identities.contains($0.id) })
        return ((try? context.fetch(descriptor)) ?? []).map(Self.progress(from:))
    }

    public func save(_ records: [WatchProgress]) async {
        guard !records.isEmpty else { return }
        let identities = records.map(\.id)
        let descriptor = FetchDescriptor<WatchProgressEntity>(predicate: #Predicate { identities.contains($0.id) })
        var existing = Dictionary(((try? context.fetch(descriptor)) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for progress in records {
            if let entity = existing[progress.id] {
                entity.type = progress.type
                entity.contentID = progress.contentID
                entity.title = progress.title
                entity.posterURLString = progress.poster?.absoluteString
                entity.position = progress.position
                entity.duration = progress.duration
                entity.isWatched = progress.isWatched
                entity.updatedAt = progress.updatedAt
                entity.season = progress.season
                entity.episode = progress.episode
            } else {
                let entity = WatchProgressEntity(id: progress.id, type: progress.type, contentID: progress.contentID, title: progress.title,
                                                   posterURLString: progress.poster?.absoluteString, position: progress.position, duration: progress.duration,
                                                   isWatched: progress.isWatched, updatedAt: progress.updatedAt, season: progress.season, episode: progress.episode)
                context.insert(entity)
                existing[progress.id] = entity
            }
        }
        try? context.save()
    }

    public func all() async -> [WatchProgress] {
        let entities = (try? context.fetch(FetchDescriptor<WatchProgressEntity>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        return entities.map(Self.progress(from:))
    }

    public func remove(_ identity: String) async {
        if let entity = fetch(identity) {
            context.delete(entity)
            try? context.save()
        }
    }

    public func remove(_ identities: [String]) async {
        guard !identities.isEmpty else { return }
        let descriptor = FetchDescriptor<WatchProgressEntity>(predicate: #Predicate { identities.contains($0.id) })
        for entity in (try? context.fetch(descriptor)) ?? [] { context.delete(entity) }
        try? context.save()
    }

    public func clear() async {
        try? context.delete(model: WatchProgressEntity.self)
        try? context.save()
    }
}

/// `LibraryStore` backed by SwiftData.
public actor SwiftDataLibraryStore: LibraryStore {
    private let container: ModelContainer
    /// Created on first use, on this actor's executor, so the context is never bound to the main queue the store was built on.
    private lazy var context = ModelContext(container)

    public init(container: ModelContainer) {
        self.container = container
    }

    private func fetch(_ id: String) -> LibraryEntity? {
        var descriptor = FetchDescriptor<LibraryEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    public func all() async -> [LibraryItem] {
        let entities = (try? context.fetch(FetchDescriptor<LibraryEntity>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)]))) ?? []
        return entities.map {
            LibraryItem(id: $0.id, type: $0.type, contentID: $0.contentID, name: $0.name, poster: $0.posterURLString.flatMap(URL.init(string:)),
                        releaseInfo: $0.releaseInfo, addedAt: $0.addedAt, genres: $0.genres, imdbRating: $0.imdbRating)
        }
    }

    public func contains(_ id: String) async -> Bool { fetch(id) != nil }

    public func add(_ item: LibraryItem) async {
        await add([item])
    }

    public func add(_ items: [LibraryItem]) async {
        guard !items.isEmpty else { return }
        let identities = items.map(\.id)
        let descriptor = FetchDescriptor<LibraryEntity>(predicate: #Predicate { identities.contains($0.id) })
        var existing = Set(((try? context.fetch(descriptor)) ?? []).map(\.id))
        for item in items where existing.insert(item.id).inserted {
            context.insert(LibraryEntity(id: item.id, type: item.type, contentID: item.contentID, name: item.name,
                                         posterURLString: item.poster?.absoluteString, releaseInfo: item.releaseInfo, addedAt: item.addedAt,
                                         genres: item.genres, imdbRating: item.imdbRating))
        }
        try? context.save()
    }

    public func remove(_ id: String) async {
        if let entity = fetch(id) {
            context.delete(entity)
            try? context.save()
        }
    }

    public func clear() async {
        try? context.delete(model: LibraryEntity.self)
        try? context.save()
    }
}
#endif
