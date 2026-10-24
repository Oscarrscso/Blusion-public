import Foundation

/// An addon the user installed. `manifestURL` is a secret (it may embed a token): this type prints without it.
public struct InstalledAddon: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var manifestURL: URL
    public var baseURL: URL
    public var manifest: Manifest
    public var isEnabled: Bool
    public var installedAt: Date
    /// A name the user gave the addon. Nil or blank means the manifest's own name.
    public var customName: String?

    public init(id: UUID = UUID(), manifestURL: URL, baseURL: URL, manifest: Manifest, isEnabled: Bool = true, installedAt: Date = Date(),
                customName: String? = nil) {
        self.id = id
        self.manifestURL = manifestURL
        self.baseURL = baseURL
        self.manifest = manifest
        self.isEnabled = isEnabled
        self.installedAt = installedAt
        self.customName = customName
    }

    /// The name the UI shows: the trimmed custom name when there is one, else the manifest's.
    public var name: String {
        let trimmed = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? manifest.name : trimmed
    }

    /// Host (and port) only; safe to show.
    public var displayHost: String { Redactor.displayHost(manifestURL) }

    public var summary: AddonSummary { AddonSummary(id: id, name: name, host: displayHost) }
}

extension InstalledAddon: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "InstalledAddon(\(manifest.name) @ \(displayHost))" }
    public var debugDescription: String { description }
}

/// Identifies an addon in results and error chips without exposing its URL.
public struct AddonSummary: Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let host: String

    public init(id: UUID, name: String, host: String) {
        self.id = id
        self.name = name
        self.host = host
    }
}

public enum RegistryError: Error, Equatable, Sendable {
    case invalidURL(AddonURLError)
    case alreadyInstalled
    case notFound
    case manifest(AddonError)
    case storage(String)

    public var message: String {
        switch self {
        case .invalidURL(let error): return error.message
        case .alreadyInstalled: return "This addon is already installed."
        case .notFound: return "That addon is no longer installed."
        case .manifest(let error): return "Couldn't load the addon: \(error.errorDescription ?? error.shortDescription)"
        case .storage: return "Couldn't save your addons."
        }
    }
}
