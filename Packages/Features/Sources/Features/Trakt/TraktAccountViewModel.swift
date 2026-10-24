import Foundation
import Observation
import PlayerKit
import StremioKit

/// Two-way syncing that runs by itself. The buttons here force a full sync, which reads everything from Trakt and applies every removal.
/// Trakt uses a user-configured client ID and PKCE; no application credential is bundled.
@MainActor
@Observable
public final class TraktAccountViewModel {
    /// The redirect registered for the Trakt app. Blusion receives it natively through the web authentication session.
    public static let redirectURI = "blusion://trakt/callback"

    public private(set) var isSignedIn = false
    public private(set) var isWorking = false
    public private(set) var authorizationURL: URL?
    public private(set) var message: String?
    public private(set) var errorMessage: String?
    /// Changes still waiting to reach Trakt.
    public private(set) var pendingCount = 0
    public var clientIDText = ""
    public private(set) var clientIDConfigured = false

    private let services: AppServices

    public init(services: AppServices) { self.services = services }

    /// Account settings remain available even when no API client ID has been configured.
    public var isAvailable: Bool { true }

    public var canSignIn: Bool { clientIDConfigured }

    public func load() async {
        let stored = await services.settings.load()
        clientIDText = stored.traktClientID ?? ""
        clientIDConfigured = !clientIDText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        isSignedIn = await services.traktAccount.isSignedIn()
        pendingCount = await services.traktSync.pendingCount()
    }

    /// Save a user-provided API client ID. Changing it ends the old sign-in, not an unrelated load.
    public func saveClientID() async {
        let clientID = clientIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = await services.settings.load()
        guard (previous.traktClientID ?? "").trimmingCharacters(in: .whitespacesAndNewlines) != clientID else {
            clientIDConfigured = !clientID.isEmpty
            return
        }
        await perform {
            await self.services.traktAccount.signOut()
            await self.services.traktSync.signedOut()
            var settings = await self.services.settings.load()
            settings.traktClientID = clientID.isEmpty ? nil : clientID
            await self.services.settings.save(settings)
            await self.services.widgetContent.invalidate()
            self.clientIDConfigured = !clientID.isEmpty
            self.isSignedIn = false
            self.message = clientID.isEmpty ? "Trakt client ID removed." : "Trakt client ID saved."
        }
    }

    public func startPKCESignIn() async {
        guard canSignIn else {
            errorMessage = "Enter and save your Trakt API client ID first."
            return
        }
        #if canImport(CryptoKit)
        await perform {
            let proof = TraktWebAuthentication.proof()
            self.authorizationURL = try await self.services.traktAccount.beginPKCESignIn(
                redirectURI: Self.redirectURI, codeVerifier: proof.verifier, codeChallenge: proof.challenge)
            self.message = nil
        }
        #endif
    }

    public func finishPKCESignIn(callbackURL: URL) async {
        await perform {
            try await self.services.traktAccount.finishPKCESignIn(callbackURL: callbackURL)
            self.isSignedIn = true
            self.authorizationURL = nil
        }
        if isSignedIn, errorMessage == nil { await importFromTrakt() }
    }

    public func authenticationFailed(_ error: Error) {
        cancelSignIn()
        errorMessage = "Couldn’t open Trakt sign-in. Try again."
    }

    public func cancelSignIn() {
        authorizationURL = nil
        Task { await services.traktAccount.cancelPKCESignIn() }
    }

    public func signOut() async {
        authorizationURL = nil
        await perform {
            await self.services.traktAccount.signOut()
            await self.services.traktSync.signedOut()
            self.isSignedIn = false
            self.message = "Disconnected from Trakt. Your local library and history are kept."
        }
    }

    /// Forces a full sync: reads everything from Trakt and applies it here, removals included, so a title or mark that left Trakt leaves
    /// this device too.
    public func importFromTrakt() async {
        await perform {
            let summary = try await self.services.traktSync.sync(force: true)
            self.message = Self.importMessage(summary)
        }
    }

    /// Forces a full sync that also sends the saved titles and watched marks here that Trakt does not have yet. What Trakt removed is
    /// removed here too, as in an import.
    public func sendToTrakt() async {
        await perform {
            let summary = try await self.services.traktSync.sync(force: true, sendingLocalOnly: true)
            self.message = "Sent \(summary.savedSent) saved titles and \(summary.watchedSent) watched items to Trakt."
        }
    }

    /// Forces a full sync that sends local items to Trakt and reads Trakt back, in one pass.
    public func sync() async {
        await perform {
            let summary = try await self.services.traktSync.sync(force: true, sendingLocalOnly: true)
            self.message = Self.importMessage(summary)
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        message = nil
        defer { isWorking = false }
        do { try await operation() } catch { errorMessage = Self.message(for: error) }
        pendingCount = await services.traktSync.pendingCount()
    }

    /// The sentence after a sync: what came in, then what Trakt removed here, when it removed anything.
    private static func importMessage(_ summary: TraktSync.Summary) -> String {
        var text = "Imported \(summary.savedAdded) saved titles and \(summary.watchedAdded) watched items from Trakt."
        if summary.savedRemoved + summary.watchedRemoved > 0 {
            text += " Removed \(summary.savedRemoved) saved titles and \(summary.watchedRemoved) watched marks that were removed on Trakt."
        }
        return text
    }

    private static func message(for error: Error) -> String {
        (error as? TraktAccountError)?.message ?? "Couldn’t save or sync your Trakt account. Try again."
    }
}
