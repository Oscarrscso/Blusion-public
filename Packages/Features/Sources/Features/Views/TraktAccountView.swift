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
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
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
