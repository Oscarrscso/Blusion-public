import Foundation
import StremioKit

/// Remembers small yes/no facts across launches, such as "the default addon was already offered".
public protocol FlagStore: Sendable {
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
}

/// Flags kept in memory: for tests and for UI-test launches, which must start empty every time.
public final class InMemoryFlagStore: FlagStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool]

    public init(values: [String: Bool] = [:]) {
        self.values = values
    }

    public func bool(forKey key: String) -> Bool { lock.withLock { values[key] ?? false } }

    public func set(_ value: Bool, forKey key: String) { lock.withLock { values[key] = value } }
}

/// Flags kept in `UserDefaults`, so they survive launches.
public final class DefaultsFlagStore: FlagStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }

    public func set(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }
}

/// Installs Stremio's official metadata addon (Cinemeta: catalogs, search and metadata, no streams) once, so Home, Discover, Search and
/// Detail work out of the box. After that it is an ordinary addon: the user can disable or remove it, and it is never installed again.
public struct DefaultAddonSeeder: Sendable {
    public enum Outcome: Equatable, Sendable {
        case alreadyDone
        case alreadyInstalled
        case installed
        case failed(RegistryError)
    }

    public static let flagKey = "defaults.seededMetadataAddon.v1"

    private let registry: AddonRegistry
    private let flags: any FlagStore
    private let manifestURL: String
    private let manifestID: String

    public init(registry: AddonRegistry, flags: any FlagStore,
                manifestURL: String = SuggestedAddon.cinemeta.manifestURL, manifestID: String = SuggestedAddon.cinemeta.manifestID) {
        self.registry = registry
        self.flags = flags
        self.manifestURL = manifestURL
        self.manifestID = manifestID
    }

    /// Installs the default addon unless this already happened once. A failure (e.g. offline) leaves the flag unset,
    /// so the next launch tries again.
    @discardableResult
    public func seedIfNeeded() async -> Outcome {
        guard !flags.bool(forKey: Self.flagKey) else { return .alreadyDone }
        if await registry.addons.contains(where: { $0.manifest.id == manifestID }) {
            flags.set(true, forKey: Self.flagKey)
            return .alreadyInstalled
        }
        do {
            try await registry.install(from: manifestURL)
            flags.set(true, forKey: Self.flagKey)
            return .installed
        } catch RegistryError.alreadyInstalled {
            flags.set(true, forKey: Self.flagKey)
            return .alreadyInstalled
        } catch let error as RegistryError {
            return .failed(error)
        } catch {
            return .failed(.manifest(AddonError.from(error)))
        }
    }
}
