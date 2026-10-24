#if canImport(Security)
import Foundation
import Security
import StremioKit

public enum KeychainError: Error, Equatable, Sendable {
    case status(Int32)
}

/// `SecretStore` backed by the Keychain (generic passwords). Items are readable after the first unlock and never leave the device,
/// except the keys in `synchronizedKeys`, which are synchronizable items that iCloud Keychain carries to the user's other devices.
public final class KeychainSecretStore: SecretStore, Sendable {
    /// The secrets that travel between the user's devices through iCloud Keychain. Every other key stays on this device.
    public static let synchronizedKeys: Set<String> = [
        DefaultsSettingsStore.Keys.serverSecret,
        DefaultsSettingsStore.Keys.traktClientSecret,
        DefaultsSettingsStore.Keys.tmdbReadToken,
        DefaultsSettingsStore.Keys.omdbAPIKey,
        DefaultsSettingsStore.Keys.openSubtitlesAPIKey,
        DefaultsSettingsStore.Keys.openSubtitlesUsername,
        DefaultsSettingsStore.Keys.openSubtitlesPassword,
        // A legacy key of the removed trailer service. It stays listed so the one-time cleanup also deletes a copy iCloud Keychain carries.
        "settings.originSubscriptionKey",
        TraktAccount.Keys.clientSecret,
        TraktAccount.Keys.token,
        TraktAccount.Keys.redirectURI,
    ]

    public static func isSynchronized(_ key: String) -> Bool {
        synchronizedKeys.contains(key)
    }

    private let service: String
    private let synchronizes: @Sendable (String) -> Bool
    /// Called after a synchronized key is set or removed, so the app can tell the other device that something changed.
    private let onSynchronizedChange: (@Sendable () -> Void)?

    public init(service: String = "app.blusion.player.secrets", synchronizes: @escaping @Sendable (String) -> Bool = { _ in false },
                onSynchronizedChange: (@Sendable () -> Void)? = nil) {
        self.service = service
        self.synchronizes = synchronizes
        self.onSynchronizedChange = onSynchronizedChange
    }

    /// False where the system keeps this app away from the Keychain altogether. A Mac Catalyst build signed without a
    /// provisioning profile has no application identifier, and every call fails with `errSecMissingEntitlement`.
    public static var isUsable: Bool {
        // A read finds nothing and says so; only a write is refused. Deleting an item that does not exist changes nothing.
        let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "app.blusion.player.probe",
                                    kSecAttrAccount as String: "probe"]
        return SecItemDelete(probe as CFDictionary) != errSecMissingEntitlement
    }

    /// The secret store for this device: the Keychain, except in a Mac build that may not use it. There the secrets go into a
    /// file only the user's account can read, next to the app's store. `usesKeychain` says which one it is.
    public static func forThisDevice(onSynchronizedChange: (@Sendable () -> Void)? = nil) -> (store: any SecretStore, usesKeychain: Bool) {
        #if canImport(SwiftData) && (targetEnvironment(macCatalyst) || os(macOS))
        if !isUsable, let folder = PersistenceContainer.defaultStoreURL()?.deletingLastPathComponent() {
            return (FileSecretStore(fileURL: folder.appendingPathComponent("Secrets.json")), false)
        }
        #endif
        return (KeychainSecretStore(synchronizes: KeychainSecretStore.isSynchronized, onSynchronizedChange: onSynchronizedChange), true)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    /// The query for the synchronizable item, the one iCloud Keychain carries.
    private func synchronizableQuery(_ key: String) -> [String: Any] {
        var query = baseQuery(key)
        query[kSecAttrSynchronizable as String] = true
        return query
    }

    /// The query for this device's own item from before the key was synchronized.
    private func deviceOnlyQuery(_ key: String) -> [String: Any] {
        var query = baseQuery(key)
        query[kSecAttrSynchronizable as String] = false
        return query
    }

    private func copyValue(_ query: [String: Any]) throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    public func get(_ key: String) async throws -> String? {
        guard synchronizes(key) else { return try copyValue(baseQuery(key)) }
        if let value = try copyValue(synchronizableQuery(key)) { return value }
        guard let legacy = try copyValue(deviceOnlyQuery(key)) else { return nil }
        // An install from before synchronization keeps its device-only item until now: move it into iCloud Keychain without signing out.
        _ = try? writeSynchronized(legacy, for: key)
        return legacy
    }

    public func set(_ value: String, for key: String) async throws {
        guard synchronizes(key) else {
            let base = baseQuery(key)
            let deleteStatus = SecItemDelete(base as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else { throw KeychainError.status(deleteStatus) }
            var add = base
            add[kSecValueData as String] = Data(value.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.status(status) }
            return
        }
        try writeSynchronized(value, for: key)
        onSynchronizedChange?()
    }

    public func remove(_ key: String) async throws {
        guard synchronizes(key) else {
            let status = SecItemDelete(baseQuery(key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
            return
        }
        var query = baseQuery(key)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
        onSynchronizedChange?()
    }

    /// Replaces the synchronizable item and retires this device's older device-only item for the same key.
    private func writeSynchronized(_ value: String, for key: String) throws {
        let base = synchronizableQuery(key)
        let deleteStatus = SecItemDelete(base as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else { throw KeychainError.status(deleteStatus) }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // A synchronizable item cannot be ThisDeviceOnly.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        // The status is ignored: the synchronizable item is saved either way, and a leftover legacy item is only ever read as a fallback.
        _ = SecItemDelete(deviceOnlyQuery(key) as CFDictionary)
    }
}
#endif
