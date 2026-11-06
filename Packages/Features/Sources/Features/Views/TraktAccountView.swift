#if canImport(UIKit)
import SwiftUI
import AuthenticationServices
import StremioKit

/// Settings → Trakt: the connection, syncing the library and how often Continue Watching asks Trakt for playback. The API client ID is
/// built in.
struct TraktAccountView: View {
    @State private var model: TraktAccountViewModel
    /// Settings' model, which holds the Continue Watching refresh.
    let settings: SettingsViewModel
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    init(services: AppServices, settings: SettingsViewModel) {
        _model = State(initialValue: TraktAccountViewModel(services: services))
        self.settings = settings
    }

    var body: some View {
        SettingsList {
            if model.isAvailable {
                accountSection
                if model.isSignedIn {
                    syncSection
                    continueWatchingSection
                }
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
        .settingsPage("Trakt")
        .task { await model.load() }
        .onDisappear { model.cancelSignIn() }
        .disabled(model.isWorking)
        .overlay { if model.isWorking { Spinner().padding().glassEffect() } }
        .accessibilityIdentifier("trakt.form")
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
            Button("Sync Now") { Task { await model.sync() } }
                .accessibilityIdentifier("trakt.sync")
            Button("Import Collection") { Task { await model.importFromTrakt() } }
                .accessibilityIdentifier("trakt.import")
            if model.pendingCount > 0 {
                Text(pendingText).foregroundStyle(.secondary).accessibilityIdentifier("trakt.pending")
            }
        } header: {
            Text("Library")
        }
    }

    /// How often Home's Continue Watching asks Trakt for playback from other devices.
    private var continueWatchingSection: some View {
        Section("Continue Watching") {
            Picker("Refresh", selection: Binding(get: { settings.settings.continueWatchingRefreshSeconds ?? 300 }, set: { value in
                Haptics.play(.choices)
                Task { await settings.setContinueWatchingRefreshSeconds(value) }
            })) {
                ForEach(SettingsViewModel.continueWatchingRefreshOptions) { Text($0.label).tag($0.value) }
            }
            .accessibilityIdentifier("settings.continueWatchingRefresh")
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
