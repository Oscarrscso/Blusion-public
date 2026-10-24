#if canImport(UIKit)
import Foundation
import UIKit

public extension Notification.Name {
    /// Posted when the synchronized secrets (iCloud Keychain) changed on another device, so screens reread them.
    static let cloudSecretsDidChange = Notification.Name("app.blusion.cloudSecretsDidChange")
}

/// Notices when the secrets that iCloud Keychain carries between the user's devices change, and tells the screens to reread them.
/// The secrets themselves are never read out of this type: it only compares a digest of them, kept in memory, with the last one seen.
@MainActor
public final class SecretsSyncObserver {
    public static let shared = SecretsSyncObserver()

    private var isStarted = false
    /// A digest of the synchronized secrets as last seen here. Kept in memory only: never persisted, never sent anywhere.
    private var lastSecretsFingerprint: String?
    private var secretsFingerprint: (@Sendable () async -> String)?
    private var observers: [Task<Void, Never>] = []
    /// Re-checks every 30 seconds while the app is active. Cancelled when the app resigns active.
    private var pollTask: Task<Void, Never>?

    private init() {}

    /// Starts the observers and records the first digest. `secretsFingerprint` digests the synchronized secrets.
    public func start(secretsFingerprint: @escaping @Sendable () async -> String) {
        guard !isStarted else { return }
        isStarted = true
        self.secretsFingerprint = secretsFingerprint
        observe(UIApplication.willEnterForegroundNotification) { [weak self] _ in self?.checkNow() }
        observe(UIApplication.didBecomeActiveNotification) { [weak self] _ in
            self?.checkNow()
            self?.startPolling()
        }
        observe(UIApplication.willResignActiveNotification) { [weak self] _ in self?.stopPolling() }
        checkNow()
    }

    /// Called after a synchronized secret changed on this device. Records the new digest without posting, so this device
    /// does not react to its own change. Safe from any thread.
    public nonisolated func secretsDidChangeLocally() {
        Task { @MainActor in
            await SecretsSyncObserver.shared.recordSecretsFingerprint()
        }
    }

    // MARK: Triggers

    private func observe(_ name: Notification.Name, _ handle: @escaping @MainActor (Notification) -> Void) {
        observers.append(Task { @MainActor in
            for await notification in NotificationCenter.default.notifications(named: name) {
                handle(notification)
            }
        })
    }

    /// Checks now, and again after 5 and 20 seconds: iCloud Keychain can arrive a little after the app becomes active.
    private func checkNow() {
        Task { await checkSecrets() }
        for delay in [5, 20] {
            Task {
                try? await Task.sleep(for: .seconds(delay))
                await checkSecrets()
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await checkSecrets()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Digest

    /// Digests the synchronized secrets and posts `.cloudSecretsDidChange` only when the digest differs from the last one seen.
    /// The first digest, at start, only records what is there.
    private func checkSecrets() async {
        guard let secretsFingerprint else { return }
        let fingerprint = await secretsFingerprint()
        let previous = lastSecretsFingerprint
        lastSecretsFingerprint = fingerprint
        if let previous, previous != fingerprint {
            NotificationCenter.default.post(name: .cloudSecretsDidChange, object: nil)
        }
    }

    /// Records the digest after this device wrote a secret, without posting.
    private func recordSecretsFingerprint() async {
        guard let secretsFingerprint else { return }
        lastSecretsFingerprint = await secretsFingerprint()
    }
}
#endif
