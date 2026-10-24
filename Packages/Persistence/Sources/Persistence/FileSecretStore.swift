#if canImport(Darwin)
import Foundation
import StremioKit

/// `SecretStore` in a file only the user's account can read (mode 0600). For a Mac build signed without a provisioning
/// profile, which the system keeps away from the Keychain altogether (`KeychainSecretStore.isUsable`). Weaker than the
/// Keychain: any program running as the user can read the file.
public actor FileSecretStore: SecretStore {
    private let fileURL: URL
    private var cached: [String: String]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func get(_ key: String) async throws -> String? {
        try load()[key]
    }

    public func set(_ value: String, for key: String) async throws {
        var values = try load()
        values[key] = value
        try write(values)
    }

    public func remove(_ key: String) async throws {
        var values = try load()
        guard values.removeValue(forKey: key) != nil else { return }
        try write(values)
    }

    private func load() throws -> [String: String] {
        if let cached { return cached }
        var values: [String: String] = [:]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fileURL))
        }
        cached = values
        return values
    }

    private func write(_ values: [String: String]) throws {
        let files = FileManager.default
        let folder = fileURL.deletingLastPathComponent()
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        // Written under its final permissions, then moved into place: the secrets are never readable by another account.
        let fresh = folder.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString)")
        guard files.createFile(atPath: fresh.path, contents: try JSONEncoder().encode(values), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if files.fileExists(atPath: fileURL.path) {
            _ = try files.replaceItemAt(fileURL, withItemAt: fresh)
        } else {
            try files.moveItem(at: fresh, to: fileURL)
        }
        cached = values
    }
}
#endif
