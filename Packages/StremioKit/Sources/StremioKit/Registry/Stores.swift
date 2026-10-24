import Foundation

/// What is persisted about an installed addon. Deliberately has no URL: the manifest URL is a secret and lives in a `SecretStore`.
public struct AddonRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    /// JSON-encoded `Manifest`.
    public var manifestData: Data
    public var isEnabled: Bool
    public var order: Int
    public var installedAt: Date
    /// The user's own name for the addon. Optional, so records saved before renaming decode as nil.
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

/// Persists addon metadata (SwiftData in the app). `save` replaces the whole set; the list is small.
public protocol AddonStore: Sendable {
    func loadAll() async throws -> [AddonRecord]
    func save(_ records: [AddonRecord]) async throws
}

/// Persists secrets (Keychain in the app).
public protocol SecretStore: Sendable {
    func get(_ key: String) async throws -> String?
    func set(_ value: String, for key: String) async throws
    func remove(_ key: String) async throws
}

public actor InMemoryAddonStore: AddonStore {
    private var records: [AddonRecord]
    public private(set) var saveCount = 0

    public init(records: [AddonRecord] = []) {
        self.records = records
    }

    public func loadAll() async throws -> [AddonRecord] { records }

    public func save(_ records: [AddonRecord]) async throws {
        self.records = records
        saveCount += 1
    }
}

public actor InMemorySecretStore: SecretStore {
    private var values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public func get(_ key: String) async throws -> String? { values[key] }

    public func set(_ value: String, for key: String) async throws { values[key] = value }

    public func remove(_ key: String) async throws { values[key] = nil }

    /// For tests: every stored key and value.
    public var snapshot: [String: String] { values }
}
