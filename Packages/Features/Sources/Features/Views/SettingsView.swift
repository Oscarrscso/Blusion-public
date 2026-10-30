#if canImport(UIKit)
import Network
import SwiftUI
import StremioKit
import UIKit

/// The Settings root: one row per area, each with a one-line summary of its current state. The areas are pages of their own below,
/// all reading and writing the one `SettingsViewModel` the root owns.
struct SettingsView: View {
    @State private var model: SettingsViewModel
    @State private var datasetStatus: IMDbDatasetStatus?
    @AppStorage(LazyLoadLookahead.defaultsKey) private var lookaheadLevel = LazyLoadLookahead.defaultLevel
    @AppStorage(ImageCachePolicy.diskMegabytesKey) private var imageCacheMegabytes = ImageCachePolicy.defaultDiskMegabytes
    private let services: AppServices
    let fallbackEngineLinked: Bool
    let aetherEngineLinked: Bool
    @Environment(AppRouter.self) private var router
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape
    @Environment(LandscapeTabBarState.self) private var landscapeTabs: LandscapeTabBarState?
    /// The id of the first section, which the list's scroll goes back to when the Settings tab's item is tapped.
    private static let topID = "settings.top"
    /// Ghost mode, kept between launches (see `GhostMode`). Pulling the page down and holding it for two seconds switches it.
    @AppStorage(GhostMode.defaultsKey) private var ghostIsOn = false
    /// How far the page is pulled down past its top, in points.
    @State private var pull: CGFloat = 0
    /// How much of the two-second hold has run, 0...1, which the ring round the ghost draws.
    @State private var holdProgress: CGFloat = 0
    /// The pull from which the hold counts, and how long it must last.
    private static let holdPull: CGFloat = 70
    private static let holdDuration: Double = 2

    init(services: AppServices) {
        _model = State(initialValue: SettingsViewModel(services: services))
        self.services = services
        fallbackEngineLinked = services.fallbackEngineLinked
        aetherEngineLinked = services.aetherEngineLinked
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if ghostIsOn {
                    Section {
                        HStack(spacing: Theme.Spacing.m) {
                            Text("👻").font(.title2).accessibilityHidden(true)
                            Text("Ghost mode is on").font(.subheadline.weight(.semibold))
                            Spacer(minLength: 0)
                            Button("Turn Off") { setGhost(false) }
                                .buttonStyle(.glassCapsule)
                                .accessibilityIdentifier("settings.ghost.off")
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("settings.ghost")
                    }
                }
                Section("Content") {
                    NavigationLink(value: SettingsDestination.addons) {
                        SettingsRow(title: "Addons", summary: "\(model.installedAddonCount) installed", systemImage: "puzzlepiece.extension")
                    }
                    .accessibilityIdentifier("settings.addons")
                    NavigationLink { AddonSpeedSettingsPage(services: services, onChange: { Task { await model.load() } }) } label: {
                        SettingsRow(title: "Addon Speed",
                                    summary: AddonSpeedViewModel.summary(for: model.settings.autoPickWait, names: model.addonNames),
                                    systemImage: "speedometer")
                    }
                    .accessibilityIdentifier("settings.section.addonSpeed")
                    NavigationLink(value: SettingsDestination.widgets) {
                        SettingsRow(title: "Widgets", summary: "Home rows and layout", systemImage: "rectangle.3.group")
                    }
                    .accessibilityIdentifier("settings.widgets")
                }
                .id(Self.topID)
                Section("Playback & appearance") {
                    NavigationLink { PlaybackSettingsPage(model: model) } label: {
                        SettingsRow(title: "Playback", summary: playbackSummary, systemImage: "play.rectangle")
                    }
                    .accessibilityIdentifier("settings.section.playback")
                    NavigationLink { PlayerSettingsPage(model: model) } label: {
                        SettingsRow(title: "Player", summary: "Subtitles, audio, picture, skip buttons", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("settings.section.player")
                    NavigationLink { AppearanceSettingsPage(model: model) } label: {
                        SettingsRow(title: "Appearance", summary: appearanceSummary, systemImage: "paintpalette")
                    }
                    .accessibilityIdentifier("settings.section.appearance")
                    NavigationLink { LazyLoadSettingsPage() } label: {
                        SettingsRow(title: "Lazy load", summary: lazyLoadLabel(lookaheadLevel), systemImage: "arrow.down.to.line")
                    }
                    .accessibilityIdentifier("settings.section.lazyLoad")
                    // A Mac has no haptic hardware, so the page would be sliders it cannot demonstrate.
                    #if !targetEnvironment(macCatalyst)
                    NavigationLink { HapticsSettingsPage(model: model) } label: {
                        SettingsRow(title: "Haptics", summary: hapticsSummary, systemImage: "hand.tap")
                    }
                    .accessibilityIdentifier("settings.section.haptics")
                    #endif
                }
                Section("Ratings") {
                    NavigationLink { ReviewServicesPage(model: model, services: services) } label: {
                        SettingsRow(title: "Review services", summary: reviewServicesSummary, systemImage: "star.bubble")
                    }
                    .accessibilityIdentifier("settings.section.reviews")
                    NavigationLink { IMDbRatingsPage(status: datasetStatus) } label: {
                        SettingsRow(title: "IMDb ratings", summary: IMDbDatasetSummary.text(datasetStatus), systemImage: "arrow.down.circle")
                    }
                    .accessibilityIdentifier("settings.section.imdb")
                }
                Section("Accounts & server") {
                    NavigationLink { TraktAccountView(services: services) } label: {
                        SettingsRow(title: "Trakt", summary: "Sync and lists", systemImage: "person.crop.circle")
                    }
                    .accessibilityIdentifier("settings.trakt")
                    NavigationLink { AccountsSettingsPage(model: model) } label: {
                        SettingsRow(title: "Continue refresh", summary: continueRefreshSummary, systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("settings.section.accounts")
                    NavigationLink { ServerSettingsPage(model: model) } label: {
                        SettingsRow(title: "Streaming server", summary: model.settings.streamingServerURL ?? "Not set", systemImage: "server.rack")
                    }
                    .accessibilityIdentifier("settings.section.server")
                    if fallbackEngineLinked {
                        NavigationLink { FallbackSettingsPage(model: model, aetherEngineLinked: aetherEngineLinked) } label: {
                            SettingsRow(title: "Fallback player", summary: FallbackSettingsPage.summary(model.settings, aetherEngineLinked: aetherEngineLinked),
                                        systemImage: "film")
                        }
                        .accessibilityIdentifier("settings.section.fallback")
                    }
                }
                Section("Data") {
                    NavigationLink { DownloadSettingsPage(services: services) } label: {
                        SettingsRow(title: "Downloads", summary: "", systemImage: "arrow.down.circle")
                    }
                    NavigationLink { ImageCacheSettingsPage() } label: {
                        SettingsRow(title: "Image cache", summary: ImageCacheSettingsPage.summary(imageCacheMegabytes), systemImage: "photo.stack")
                    }
                    .accessibilityIdentifier("settings.section.imageCache")
                    NavigationLink { DataSettingsPage(model: model) } label: {
                        SettingsRow(title: "Clear data", summary: "History, library, settings", systemImage: "trash")
                    }
                    .accessibilityIdentifier("settings.section.data")
                }
                Section("About") {
                    NavigationLink { AboutSettingsPage(fallbackEngineLinked: fallbackEngineLinked, aetherEngineLinked: aetherEngineLinked) } label: {
                        SettingsRow(title: "About", summary: "Version \(SettingsViewModel.appVersion)", systemImage: "info.circle")
                    }
                    .accessibilityIdentifier("settings.section.about")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .readableColumn()
            .trackLandscapeTabScroll()
            .screenBackground()
            .navigationTitle("Settings")
            .toolbar(isPhoneInLandscape ? .hidden : .automatic, for: .tabBar)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await model.load()
                datasetStatus = await services.posterRatings.imdbDatasetStatus()
            }
            // A new copy of the IMDb data arrived while Settings was open, or the review services changed.
            .onChange(of: services.posterRatings.reviewServicesRevision) {
                model.refreshOMDbUsage()
                Task { datasetStatus = await services.posterRatings.imdbDatasetStatus() }
            }
            .accessibilityIdentifier("settings.form")
            // The pull past the top, which the ghost's indicator follows.
            .onScrollGeometryChange(for: CGFloat.self) { max(0, -($0.contentOffset.y + $0.contentInsets.top)) } action: { _, value in
                pull = value
            }
            .overlay(alignment: .top) { ghostPullIndicator }
            // Held past the mark for two seconds, the pull switches ghost mode. Let go sooner and nothing happens.
            .task(id: pull >= Self.holdPull) {
                guard pull >= Self.holdPull else {
                    holdProgress = 0
                    return
                }
                withAnimation(.linear(duration: Self.holdDuration)) { holdProgress = 1 }
                do { try await Task.sleep(for: .seconds(Self.holdDuration)) } catch {
                    holdProgress = 0
                    return
                }
                setGhost(!ghostIsOn)
            }
            // A tap on Settings' tab item goes back to its first page, and scrolls it to the top.
            .onChange(of: router.tabTapRevisions[.settings, default: 0]) { _, _ in
                withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo(Self.topID, anchor: .top) }
            }
        }
    }

    private var isPhoneInLandscape: Bool { isPhoneLandscape && UIDevice.current.userInterfaceIdiom == .phone }

    private func setGhost(_ isOn: Bool) {
        // The tap, not a selection tick: Ghost mode changes what every screen shows, so it lands like a change of screen.
        Haptics.tap()
        withAnimation(.snappy(duration: 0.3)) { ghostIsOn = isOn }
    }

    /// Shown while the page is pulled down: a ghost in a ring that fills over the two seconds of the hold, and what letting it fill does.
    @ViewBuilder
    private var ghostPullIndicator: some View {
        if pull > 24 {
            let isHolding = pull >= Self.holdPull
            HStack(spacing: Theme.Spacing.s) {
                Text("👻")
                    .font(.title3)
                    .padding(8)
                    .background {
                        Circle().stroke(.white.opacity(0.2), lineWidth: 3)
                        Circle().trim(from: 0, to: holdProgress)
                            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                Text(holdProgress >= 1 ? (ghostIsOn ? "Ghost mode on" : "Ghost mode off")
                     : isHolding ? "Keep holding…" : (ghostIsOn ? "Pull and hold to leave ghost mode" : "Pull and hold for ghost mode"))
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .glassEffect(.regular, in: .capsule)
            .opacity(min(1, (pull - 24) / 30))
            .padding(.top, Theme.Spacing.s)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var playbackSummary: String {
        let quality = SettingsViewModel.resolutionOptions.first { $0.value == model.settings.preferredResolution }?.label ?? "Best available"
        return "\(model.settings.playerPreference.title) · \(quality) · \(model.settings.autoPickSource.title)"
    }

    private var appearanceSummary: String {
        var on: [String] = []
        if model.settings.showsPosterRatings { on.append("Ratings on posters") }
        if model.settings.showsColouredRatingLogos { on.append("Coloured logos") }
        return on.isEmpty ? "Rating options off" : on.joined(separator: ", ")
    }

    /// The Haptics row shows the tap strength.
    private var hapticsSummary: String {
        let haptics = model.settings.haptics
        guard haptics.isOn else { return "Off" }
        let tap = Int((haptics.tapStrength * 100).rounded())
        return "Tap \(tap)%"
    }

    private var reviewServicesSummary: String {
        var saved: [String] = []
        if model.settings.omdbAPIKey != nil { saved.append("OMDb") }
        if model.settings.tmdbReadToken != nil { saved.append("TMDB") }
        var text = saved.isEmpty ? "Not set up" : saved.joined(separator: ", ")
        if model.settings.omdbAPIKey != nil {
            text += " · \(model.omdbRequestsToday.formatted()) of \(SettingsViewModel.omdbDailyLimit.formatted()) today"
        }
        return text
    }

    private var continueRefreshSummary: String {
        let seconds = model.settings.continueWatchingRefreshSeconds ?? 300
        return SettingsViewModel.continueWatchingRefreshOptions.first { $0.value == seconds }?.label ?? "Every 5 minutes"
    }
}

private func lazyLoadLabel(_ level: Int) -> String {
    LazyLoadLookahead.levels[min(max(level, 1), LazyLoadLookahead.levels.count) - 1].label
}

/// One row of the Settings root, in the format of the Widgets page: a symbol, a title and a one-line summary.
private struct SettingsRow: View {
    let title: String
    let summary: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

/// The look every Settings page shares with the Widgets page.
extension View {
    func settingsPage(_ title: String) -> some View {
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .readableColumn()
            .screenBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlaybackSettingsPage: View {
    let model: SettingsViewModel
    @State private var infuseInstalled = true

    var body: some View {
        List {
            Section {
                Picker("Play with", selection: Binding(get: { model.settings.playerPreference }, set: { value in
                    Task { await model.setPlayerPreference(value) }
                })) {
                    ForEach(PlayerPreference.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.player")
                if model.settings.playerPreference.externalPlayer != nil && !infuseInstalled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Infuse isn’t installed on this device.").font(.footnote).foregroundStyle(.secondary)
                        if let url = ExternalPlayer.infuse.appStoreURL { Link("Get Infuse", destination: url) }
                    }
                    .accessibilityIdentifier("settings.player.missing")
                }
                Toggle("Play best stream automatically", isOn: Binding(get: { model.settings.autoPlayBestStream }, set: { value in
                    Task { await model.setAutoPlayBestStream(value) }
                }))
                .accessibilityIdentifier("settings.autoPlay")
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text("Auto Pick source")
                    Picker("Auto Pick source", selection: Binding(get: { model.settings.autoPickSource }, set: { value in
                        Haptics.selection()
                        Task { await model.setAutoPickSource(value) }
                    })) {
                        ForEach(StreamSourcePreference.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("settings.autoPickSource")
                }
                Picker("Preferred quality",
                       selection: Binding(get: { model.settings.preferredResolution },
                                          set: { value in Haptics.selection(); Task { await model.setPreferredResolution(value) } })) {
                    ForEach(SettingsViewModel.resolutionOptions) { Text($0.label).tag($0.value) }
                }
                .accessibilityIdentifier("settings.resolution")
                Picker("Subtitles", selection: Binding(get: { model.settings.subtitleLanguage }, set: { value in
                    Haptics.selection()
                    Task { await model.setSubtitleLanguage(value) }
                })) {
                    ForEach(SettingsViewModel.languageOptions) { Text($0.label).tag($0.value) }
                }
                .accessibilityIdentifier("settings.subtitleLanguage")
            }
        }
        .settingsPage("Playback")
        .task {
            if let url = URL(string: "infuse://") { infuseInstalled = UIApplication.shared.canOpenURL(url) }
        }
    }
}

private struct AppearanceSettingsPage: View {
    let model: SettingsViewModel

    var body: some View {
        List {
            Section {
                Toggle("Ratings on posters", isOn: Binding(get: { model.settings.showsPosterRatings }, set: { value in
                    Task { await model.setShowsPosterRatings(value) }
                }))
                .accessibilityIdentifier("settings.posterRatings")
                Toggle("Coloured rating logos", isOn: Binding(get: { model.settings.showsColouredRatingLogos }, set: { value in
                    Task { await model.setShowsColouredRatingLogos(value) }
                }))
                .accessibilityIdentifier("settings.colouredRatingLogos")
            }
        }
        .settingsPage("Appearance")
    }
}

private struct LazyLoadSettingsPage: View {
    @AppStorage(LazyLoadLookahead.defaultsKey) private var lookaheadLevel = LazyLoadLookahead.defaultLevel

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    HStack {
                        Text("Lazy load")
                        Spacer()
                        Text(lazyLoadLabel(lookaheadLevel)).foregroundStyle(.secondary)
                    }
                    GlassSlider(value: $lookaheadLevel, stops: LazyLoadLookahead.levels.count)
                        .accessibilityLabel("Lazy load")
                        .accessibilityIdentifier("settings.lazyLoadLookahead")
                    HStack {
                        Text(LazyLoadLookahead.levels[0].label)
                        Spacer()
                        Text(LazyLoadLookahead.levels[LazyLoadLookahead.levels.count - 1].label)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .settingsPage("Lazy load")
    }
}

private struct ReviewServicesPage: View {
    @Bindable var model: SettingsViewModel
    let services: AppServices

    private var used: Int { model.omdbRequestsToday }
    private var limit: Int { SettingsViewModel.omdbDailyLimit }

    var body: some View {
        List {
            Section {
                SecureField("OMDb API Key", text: $model.omdbAPIKeyText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("settings.omdbAPIKey")
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Requests today", value: "\(used.formatted()) of \(limit.formatted())")
                    ProgressView(value: Double(min(used, limit)), total: Double(limit))
                        .tint(Double(used) >= Double(limit) * 0.9 ? .orange : nil)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.omdbUsage")
                if let url = URL(string: "https://www.omdbapi.com/apikey.aspx") { Link("Get an OMDb key", destination: url) }
            } header: {
                Text("OMDb")
            }
            Section {
                SecureField("TMDB Read Access Token", text: $model.tmdbReadTokenText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("settings.tmdbReadToken")
                if let url = URL(string: "https://www.themoviedb.org/settings/api") { Link("TMDB API settings", destination: url) }
            } header: {
                Text("TMDB")
            }
            Section {
                Button("Save Review Services") { Task { await model.commitReviewCredentials() } }
                    .accessibilityIdentifier("settings.reviews.save")
                Button("Refresh Ratings") { Task { await model.refreshRatings() } }
                    .accessibilityIdentifier("settings.reviews.refresh")
                if let error = services.posterRatings.omdbError ?? services.posterRatings.reviewServiceIssue {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settings.reviews.error")
                }
            }
        }
        .settingsPage("Review services")
        .task { model.refreshOMDbUsage() }
        .onChange(of: services.posterRatings.reviewServicesRevision) { model.refreshOMDbUsage() }
    }
}

/// What the offline IMDb scores are, when they were last updated, and whose they are (IMDb asks for the credit and limits the data
/// to personal, non-commercial use).
private struct IMDbRatingsPage: View {
    let status: IMDbDatasetStatus?

    var body: some View {
        List {
            Section {
                if let status {
                    LabeledContent {
                        Text(status.titleCount.formatted())
                    } label: {
                        HStack(spacing: 6) {
                            ReviewSiteIcon(site: .imdb, size: 13)
                            Text("Titles")
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.imdbDataset")
                    LabeledContent("Updated", value: (status.updatedAt ?? status.checkedAt)
                        .map { $0.formatted(.dateTime.day().month(.abbreviated).year()) } ?? "Not yet")
                    LabeledContent("Size on disk", value: status.fileSize.map { $0.formatted(.byteCount(style: .file)) } ?? "Unknown")
                } else {
                    LabeledContent {
                        Text(IMDbDatasetSummary.text(nil))
                    } label: {
                        HStack(spacing: 6) {
                            ReviewSiteIcon(site: .imdb, size: 13)
                            Text("Titles")
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.imdbDataset")
                }
                if let url = IMDbAttribution.termsURL { Link("IMDb data terms", destination: url) }
            } footer: {
                // IMDb's credit and terms, which its non-commercial datasets require.
                Text("\(IMDbAttribution.notice) \(IMDbAttribution.terms)")
            }
        }
        .settingsPage("IMDb ratings")
    }
}

private struct AccountsSettingsPage: View {
    let model: SettingsViewModel

    var body: some View {
        List {
            Section {
                Picker("Continue refresh", selection: Binding(get: { model.settings.continueWatchingRefreshSeconds ?? 300 }, set: { value in
                    Task { await model.setContinueWatchingRefreshSeconds(value) }
                })) {
                    ForEach(SettingsViewModel.continueWatchingRefreshOptions) { Text($0.label).tag($0.value) }
                }
                .accessibilityIdentifier("settings.continueWatchingRefresh")
            }
        }
        .settingsPage("Continue refresh")
    }
}

private struct ServerSettingsPage: View {
    @Bindable var model: SettingsViewModel

    var body: some View {
        List {
            Section {
                TextField("http://192.168.1.10:11470", text: $model.serverURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .submitLabel(.done)
                    .onSubmit { Task { await model.commitServerURL() } }
                    .accessibilityLabel("Streaming server address")
                    .accessibilityIdentifier("settings.serverURL")
                if let message = model.serverURLMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settings.serverURL.message")
                }
                Button("Save address") { Task { await model.commitServerURL() } }
                    .disabled(model.serverURLMessage != nil)
                    .accessibilityIdentifier("settings.serverURL.save")
            }
        }
        .settingsPage("Streaming server")
    }
}

private struct FallbackSettingsPage: View {
    let model: SettingsViewModel
    var aetherEngineLinked = false

    /// The row's summary on the Settings list: off, or which engine plays.
    static func summary(_ settings: PlaybackSettings, aetherEngineLinked: Bool) -> String {
        guard settings.fallbackEngineEnabled else { return "Off" }
        guard aetherEngineLinked else { return "On" }
        return settings.player.advancedEngine == .aether ? "AetherEngine" : "mpv"
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PlayerPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.settings.player[keyPath: keyPath] }, set: { value in
            Haptics.selection()
            Task { await model.updatePlayer { $0[keyPath: keyPath] = value } }
        })
    }

    var body: some View {
        List {
            Section {
                Toggle("Use the fallback player", isOn: Binding(get: { model.settings.fallbackEngineEnabled },
                                        set: { value in Haptics.selection(); Task { await model.setFallbackEngineEnabled(value) } }))
                    .accessibilityIdentifier("settings.fallbackToggle")
            }
            if aetherEngineLinked, model.settings.fallbackEngineEnabled {
                Section {
                    Picker("Engine", selection: binding(\.advancedEngine)) {
                        Text("AetherEngine").tag(AdvancedEngine.aether)
                        Text("mpv").tag(AdvancedEngine.mpv)
                    }
                    .accessibilityIdentifier("settings.fallbackEngine")
                }
                if model.settings.player.advancedEngine == .aether {
                    Section {
                        Toggle("Compose Dolby Vision FEL", isOn: binding(\.composesDolbyVisionFEL))
                            .accessibilityIdentifier("settings.aether.fel")
                        Toggle("Spatial audio for TrueHD and DTS:X", isOn: binding(\.rendersObjectAudio))
                            .accessibilityIdentifier("settings.aether.objectAudio")
                    }
                }
            }
        }
        .settingsPage("Fallback player")
    }
}

private struct DataSettingsPage: View {
    let model: SettingsViewModel
    @State private var pendingScope: DataResetService.Scope?

    var body: some View {
        List {
            Section {
                ForEach(DataResetService.Scope.allCases, id: \.self) { scope in
                    Button(scope.title, role: .destructive) { pendingScope = scope }
                        .accessibilityIdentifier("settings.clear.\(String(describing: scope))")
                }
                if let message = model.lastMessage {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.clearMessage")
                }
            }
        }
        .settingsPage("Clear data")
        .confirmationDialog(pendingScope.map { "Clear \($0.title.lowercased())?" } ?? "",
                            isPresented: Binding(get: { pendingScope != nil }, set: { if !$0 { pendingScope = nil } }),
                            titleVisibility: .visible, presenting: pendingScope) { scope in
            Button("Clear \(scope.title.lowercased())", role: .destructive) { Task { await model.clear(scope) } }
                .accessibilityIdentifier("settings.confirmClear")
            Button("Cancel", role: .cancel) {}
        } message: { scope in
            Text(scope.warning)
        }
    }
}

/// How much room posters and backdrops may take on this device, how much they take now, and a way to clear them. There is no expiry and no
/// quality choice: pictures stay until the limit makes room (the least recently used go first), and one that has been kept a while is
/// checked quietly for a newer copy (see `ImageCachePolicy`).
private struct ImageCacheSettingsPage: View {
    @AppStorage(ImageCachePolicy.diskMegabytesKey) private var megabytes = ImageCachePolicy.defaultDiskMegabytes
    @State private var inUse: Int?
    @State private var confirmsClear = false

    /// The Settings row's summary: the chosen size.
    static func summary(_ megabytes: Int) -> String {
        "Up to \(sizeName(ImageCachePolicy.diskBytes(forSavedMegabytes: megabytes) / 1024 / 1024))"
    }

    static func sizeName(_ megabytes: Int) -> String {
        megabytes >= 1024 ? "\(megabytes / 1024) GB" : "\(megabytes) MB"
    }

    var body: some View {
        List {
            Section {
                Picker("Disk cache size", selection: $megabytes) {
                    ForEach(ImageCachePolicy.diskSizeOptions, id: \.self) { Text(Self.sizeName($0)).tag($0) }
                }
                .accessibilityIdentifier("settings.imageCache.size")
                LabeledContent("Cache in use") {
                    Text(inUse.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—")
                        .monospacedDigit()
                        .accessibilityLabel(inUse.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Measuring")
                }
                .accessibilityIdentifier("settings.imageCache.inUse")
            }
            Section {
                Button("Clear Image Cache", role: .destructive) { confirmsClear = true }
                    .accessibilityIdentifier("settings.imageCache.clear")
            }
        }
        .settingsPage("Image cache")
        .task { inUse = ImagePipeline.shared.diskUsage }
        .onChange(of: megabytes) { _, chosen in
            ImagePipeline.shared.setDiskLimit(megabytes: chosen)
            inUse = ImagePipeline.shared.diskUsage
        }
        .confirmationDialog("Clear the image cache?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear Image Cache", role: .destructive) {
                // Off the main thread: emptying a full cache takes a moment, and the page should not stall while it does.
                Task {
                    await Task.detached(priority: .userInitiated) { ImagePipeline.shared.clearDisk() }.value
                    inUse = ImagePipeline.shared.diskUsage
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Posters and backdrops download again as you browse.")
        }
    }
}

/// How fast each addon answers, and what Auto Pick waits for. The test runs only when asked: every request is a real lookup. The addons
/// stay in the user's own order, which also orders Home's rows.
private struct AddonSpeedSettingsPage: View {
    @State private var model: AddonSpeedViewModel
    /// Tells Settings the choice changed, so its row's summary follows.
    let onChange: () -> Void
    @State private var isOnline = true

    init(services: AppServices, onChange: @escaping () -> Void) {
        _model = State(initialValue: AddonSpeedViewModel(services: services))
        self.onChange = onChange
    }

    var body: some View {
        List {
            Section {
                Button {
                    Task { await model.test() }
                } label: {
                    HStack {
                        Text(model.isTesting ? "Testing…" : "Test Now")
                        Spacer(minLength: 0)
                        if model.isTesting { Spinner().controlSize(.small) }
                    }
                }
                .disabled(model.isTesting || !isOnline)
                .accessibilityIdentifier("settings.addonSpeed.test")
                ForEach(model.rows) { row in
                    HStack(spacing: Theme.Spacing.s) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.addon.name)
                            Text(AddonSpeedViewModel.detail(for: row.result))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer(minLength: 0)
                        if row.id == model.fastest {
                            Text("Fastest")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, Theme.Spacing.s)
                                .padding(.vertical, 3)
                                .background(.tint.opacity(0.25), in: Capsule())
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.addonSpeed.row.\(row.id.uuidString)")
                }
            } footer: {
                if !isOnline { Text("You're offline. Connect to test your addons.") }
            }
            Section {
                waitChoice("All addons", .allAddons)
                waitChoice("Auto (fastest)", .fastest)
                ForEach(model.rows) { row in waitChoice(row.addon.name, .addon(row.id)) }
            } header: {
                Text("Auto Pick waits for")
            }
        }
        .settingsPage("Addon Speed")
        .task { await model.load() }
        .task { for await path in NWPathMonitor() { isOnline = path.status == .satisfied } }
    }

    private func waitChoice(_ title: String, _ wait: AutoPickWait) -> some View {
        Button {
            Haptics.selection()
            Task { await model.choose(wait, saved: onChange) }
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 0)
                if model.shownWait == wait { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .accessibilityAddTraits(model.shownWait == wait ? .isSelected : [])
        .accessibilityIdentifier("settings.addonSpeed.wait.\(wait.storedValue)")
    }
}

private struct AboutSettingsPage: View {
    let fallbackEngineLinked: Bool
    var aetherEngineLinked = false

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: SettingsViewModel.appVersion)
                NavigationLink("Acknowledgements") { AcknowledgementsView(fallbackEngineLinked: fallbackEngineLinked, aetherEngineLinked: aetherEngineLinked) }
                    .accessibilityIdentifier("settings.acknowledgements")
            } footer: {
                Text("""
                    Blusion includes no content or stream sources. Cinemeta provides catalogs and search; you can remove it in Settings › \
                    Addons. Blusion isn’t affiliated with any addon or service.
                    """)
            }
        }
        .settingsPage("About")
    }
}

struct AcknowledgementsView: View {
    let fallbackEngineLinked: Bool
    var aetherEngineLinked = false

    var body: some View {
        List(Acknowledgement.all(fallbackEngineLinked: fallbackEngineLinked, aetherEngineLinked: aetherEngineLinked)) { item in
            VStack(alignment: .leading, spacing: 4) {
                if item.name == "TMDB" {
                    Image("ReviewTMDB").resizable().scaledToFit()
                        .frame(width: 80, height: 35)
                        .accessibilityLabel("TMDB")
                }
                Text(item.name).font(.headline)
                Text(item.license).font(.subheadline).foregroundStyle(.secondary)
                Text(item.detail).font(.footnote)
                if let url = item.sourceURL { Link("Source", destination: url).font(.footnote) }
            }
            .accessibilityElement(children: .contain)
        }
        .scrollContentBackground(.hidden)
        .readableColumn()
        .screenBackground()
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("acknowledgements.list")
    }
}
#endif
