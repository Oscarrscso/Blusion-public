#if canImport(SwiftData)
import Foundation
import SwiftData

/// Persisted addon metadata. Deliberately has no URL field: the manifest URL may embed a token and lives in the Keychain.
@Model
public final class AddonEntity {
    @Attribute(.unique) public var id: UUID
    public var manifestData: Data
    public var isEnabled: Bool
    public var order: Int
    public var installedAt: Date
    /// Added in schema V4. Optional, so rows from earlier versions migrate with it nil.
    public var customName: String?

    public init(id: UUID, manifestData: Data, isEnabled: Bool, order: Int, installedAt: Date, customName: String? = nil) {
        self.id = id
        self.manifestData = manifestData
        self.isEnabled = isEnabled
        self.order = order
        self.installedAt = installedAt
        self.customName = customName
    }
}

/// Watch progress, one row per `StreamRequest.identity`. Added in schema V2.
@Model
public final class WatchProgressEntity {
    @Attribute(.unique) public var id: String
    public var type: String
    public var contentID: String
    public var title: String
    public var posterURLString: String?
    public var position: Double
    public var duration: Double
    public var isWatched: Bool
    public var updatedAt: Date
    public var season: Int?
    public var episode: Int?

    public init(id: String, type: String, contentID: String, title: String, posterURLString: String?, position: Double, duration: Double,
                isWatched: Bool, updatedAt: Date, season: Int?, episode: Int?) {
        self.id = id
        self.type = type
        self.contentID = contentID
        self.title = title
        self.posterURLString = posterURLString
        self.position = position
        self.duration = duration
        self.isWatched = isWatched
        self.updatedAt = updatedAt
        self.season = season
        self.episode = episode
    }
}

/// A saved title. Added in schema V2; genres and rating added in V3.
@Model
public final class LibraryEntity {
    @Attribute(.unique) public var id: String
    public var type: String
    public var contentID: String
    public var name: String
    public var posterURLString: String?
    public var releaseInfo: String?
    public var addedAt: Date
    public var genres: [String] = []
    public var imdbRating: Double?

    public init(id: String, type: String, contentID: String, name: String, posterURLString: String?, releaseInfo: String?, addedAt: Date,
                genres: [String] = [], imdbRating: Double? = nil) {
        self.id = id
        self.type = type
        self.contentID = contentID
        self.name = name
        self.posterURLString = posterURLString
        self.releaseInfo = releaseInfo
        self.addedAt = addedAt
        self.genres = genres
        self.imdbRating = imdbRating
    }
}

/// V1 (M2): addons only.
public enum BlusionSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] { [AddonEntity.self] }

    /// Addon rows as V1 to V3 stored them, before `customName`. V2 and V3 use this copy too, so those stores still match their schema.
    @Model
    public final class AddonEntity {
        @Attribute(.unique) public var id: UUID
        public var manifestData: Data
        public var isEnabled: Bool
        public var order: Int
        public var installedAt: Date

        public init(id: UUID, manifestData: Data, isEnabled: Bool, order: Int, installedAt: Date) {
            self.id = id
            self.manifestData = manifestData
            self.isEnabled = isEnabled
            self.order = order
            self.installedAt = installedAt
        }
    }
}

/// V2 (M7): adds watch progress and the library. Existing addon rows are untouched, so the migration is lightweight.
/// The library entity is frozen here as it was in V2, so the V2 store matches this definition during migration.
public enum BlusionSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)
    public static var models: [any PersistentModel.Type] { [BlusionSchemaV1.AddonEntity.self, WatchProgressEntity.self, LibraryEntity.self] }

    @Model
    public final class LibraryEntity {
        @Attribute(.unique) public var id: String
        public var type: String
        public var contentID: String
        public var name: String
        public var posterURLString: String?
        public var releaseInfo: String?
        public var addedAt: Date

        public init(id: String, type: String, contentID: String, name: String, posterURLString: String?, releaseInfo: String?, addedAt: Date) {
            self.id = id
            self.type = type
            self.contentID = contentID
            self.name = name
            self.posterURLString = posterURLString
            self.releaseInfo = releaseInfo
            self.addedAt = addedAt
        }
    }
}

/// V3: saved titles keep their genres and IMDb rating, so the Library can filter by them. A lightweight step from V2: both new
/// attributes have defaults.
public enum BlusionSchemaV3: VersionedSchema {
    public static let versionIdentifier = Schema.Version(3, 0, 0)
    public static var models: [any PersistentModel.Type] { [BlusionSchemaV1.AddonEntity.self, WatchProgressEntity.self, LibraryEntity.self] }
}

/// V4: addons can be renamed, so `AddonEntity` gains an optional `customName`. A lightweight step from V3, as the new attribute is optional.
public enum BlusionSchemaV4: VersionedSchema {
    public static let versionIdentifier = Schema.Version(4, 0, 0)
    public static var models: [any PersistentModel.Type] { [AddonEntity.self, WatchProgressEntity.self, LibraryEntity.self] }
}

public enum BlusionMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [BlusionSchemaV1.self, BlusionSchemaV2.self, BlusionSchemaV3.self, BlusionSchemaV4.self]
    }
    public static var stages: [MigrationStage] {
        [.lightweight(fromVersion: BlusionSchemaV1.self, toVersion: BlusionSchemaV2.self),
         .lightweight(fromVersion: BlusionSchemaV2.self, toVersion: BlusionSchemaV3.self),
         .lightweight(fromVersion: BlusionSchemaV3.self, toVersion: BlusionSchemaV4.self)]
    }
}
#endif
