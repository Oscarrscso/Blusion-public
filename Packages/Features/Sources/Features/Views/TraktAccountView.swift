#if canImport(UIKit)
import SwiftUI
import AuthenticationServices
import StremioKit

struct TraktAccountView: View {
    @State private var model: TraktAccountViewModel
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    init(services: AppServices) { _model = State(initialValue: TraktAccountViewModel(services: services)) }

    var body: some View {
        Form {
            if model.isAvailable {
                clientIDSection
                accountSection
                if model.isSignedIn { syncSection }
            } else {
                Section {
                    Text("Trakt unavailable").foregroundStyle(.secondary).accessibilityIdentifier("trakt.unavailable")
                }
            }
            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(.secondary).accessibilityIdentifier("trakt.error") }
            }
            if let message = model.message {
                Section { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("trakt.message") }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Trakt")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .onDisappear { model.cancelSignIn() }
        .disabled(model.isWorking)
        .overlay { if model.isWorking { Spinner().padding().glassEffect() } }
        .accessibilityIdentifier("trakt.form")
    }

    private var clientIDSection: some View {
        Section {
            TextField("Trakt API Client ID", text: $model.clientIDText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("trakt.clientID")
            Button("Save Client ID") { Task { await model.saveClientID() } }
                .accessibilityIdentifier("trakt.saveClientID")
        } header: {
            Text("API configuration")
        } footer: {
            Text("Use your own Trakt API application. Register blusion://trakt/callback as its redirect URI. This app does not include an API client ID.")
        }
    }

    private var accountSection: some View {
        Section {
            if model.isSignedIn {
                Label("Connected", systemImage: "checkmark.circle")
                    .accessibilityIdentifier("trakt.signedIn")
                Button("Disconnect", role: .destructive) { Task { await model.signOut() } }
                    .accessibilityIdentifier("trakt.signOut")
            } else {
                Button("Connect") { Task { await signIn() } }
                    .disabled(!model.canSignIn)
                    .accessibilityIdentifier("trakt.signIn")
            }
        } header: {
            Text("Account")
        } footer: {
            if !model.isSignedIn {
                Text("Connect to sync your saved titles, watched marks and paused positions with Trakt.")
            }
        }
    }

    private var syncSection: some View {
        Section {
            Button("Sync") { Task { await model.sync() } }
                .accessibilityIdentifier("trakt.sync")
            Button("Import collection") { Task { await model.importFromTrakt() } }
                .accessibilityIdentifier("trakt.import")
            if model.pendingCount > 0 {
                Text(pendingText).foregroundStyle(.secondary).accessibilityIdentifier("trakt.pending")
            }
        } header: {
            Text("Your Trakt library")
        } footer: {
            Text("""
                Saved titles, watched marks and paused positions sync both ways automatically. Removing a saved title or clearing a watched \
                mark here does the same on Trakt, and what is removed on Trakt is removed here. Saved titles use your Trakt watchlist; \
                your collection is only read. Sync reads everything from Trakt again.
                """)
        }
    }

    private var pendingText: String {
        model.pendingCount == 1 ? "1 change waiting to reach Trakt." : "\(model.pendingCount) changes waiting to reach Trakt."
    }

    private func signIn() async {
        await model.startPKCESignIn()
        guard let url = model.authorizationURL else { return }
        do {
            let callback = try await TraktWebAuthentication.authenticate(using: webAuthenticationSession, url: url,
                                                                        redirectURI: TraktAccountViewModel.redirectURI)
            await model.finishPKCESignIn(callbackURL: callback)
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin || Task.isCancelled {
                model.cancelSignIn()
            } else {
                model.authenticationFailed(error)
            }
        }
    }
}
#endif
