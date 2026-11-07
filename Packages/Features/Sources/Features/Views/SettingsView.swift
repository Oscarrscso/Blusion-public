#if canImport(UIKit)
import Network
import SwiftUI
import StremioKit
import UIKit
import UniformTypeIdentifiers

/// The Settings root: one row per area, each with a one-line summary of its current state. The areas are pages of their own below,
/// all reading and writing the one `SettingsViewModel` the root owns.
struct SettingsView: View {
    @Environment(\.layoutMetrics) private var metrics
    @State private var model: SettingsViewModel
    @State private var syncFolderName: String?
    @State private var traktConnected: Bool?
    @State private var downloadsBytes: Int64?
    @AppStorage(LazyLoadLookahead.defaultsKey) private var lookaheadLevel = LazyLoadLookahead.defaultLevel
    /// Performance's other choices, read so its row's summary follows them.
    @AppStorage(OptimisationSettings.homePreloadKey) private var optimisationHome = OptimisationSettings.homePreloadMatchesLazyLoad
    @AppStorage(OptimisationSettings.pictureMemoryKey) private var optimisationMemory = OptimisationSettings.defaultPictureMemory
    @AppStorage(OptimisationSettings.downloadSlotsKey) private var optimisationSlots = OptimisationSettings.defaultDownloadSlots
    @AppStorage(OptimisationSettings.prefetchesStreamsKey) private var optimisationPrefetch = true
    @AppStorage(OptimisationSettings.readiesFirstStreamKey) private var optimisationReadies = true
    @AppStorage(OptimisationSettings.savesPowerKey) private var optimisationSavesPower = true
    @AppStorage(ImageCachePolicy.diskMegabytesKey) private var imageCacheMegabytes = ImageCachePolicy.defaultDiskMegabytes
    @AppStorage(AppearancePreferences.defaultsKey) private var appearance = AppearancePreferences()
    private let services: AppServices
    let fallbackEngineLinked: Bool
    let aetherEngineLinked: Bool
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape
    @Environment(LandscapeTabBarState.self) private var landscapeTabs: LandscapeTabBarState?
    @Environment(AppRouter.self) private var router
    /// Ghost mode, kept between launches (see `GhostMode`). Pulling the page down and holding it for two seconds switches it.
    @AppStorage(GhostMode.defaultsKey) private var ghostIsOn = false
    /// How far the page is pulled down past its top, in points.
    @State private var pull: CGFloat = 0
    #if targetEnvironment(macCatalyst)
    /// The page opened from the chosen page, shown to its right (see `SettingsDetailColumns`).
    @State private var sidePage = SettingsSidePage()
    #endif
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
        #if targetEnvironment(macCatalyst)
        // As on iPad: the list beside the page chosen in it, and what that page pushes on a stack of its own.
        @Bindable var router = router
        NavigationSplitView(columnVisibility: .constant(.all)) {
            list
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 400)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetailColumns(sidePage: sidePage) {
                NavigationStack(path: $router.settingsPath) {
                    if let selection = router.settingsSelection {
                        page(selection)
                    } else {
                        Color.clear.screenBackground()
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: router.settingsSelection) {
            router.settingsPath = NavigationPath()
            sidePage.close()
            // The list stays on screen beside the page, so its summaries catch up when another page is chosen.
            Task { await refreshSummaries() }
        }
        #else
        list.navigationDestination(for: SettingsDestination.self) { page($0) }
        #endif
    }

    private var list: some View {
        @Bindable var router = router
        return SettingsList(selection: Self.selectsBesideList ? $router.settingsSelection : nil) {
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
                    .listRowBackground(SettingsRowBackground())
                }
            }
            Section("Sources") {
                link(.addons) {
                    SettingsRow(title: "Addons", summary: "\(model.installedAddonCount) installed", systemImage: "puzzlepiece.extension")
                }
                .accessibilityIdentifier("settings.addons")
                link(.server) {
                    SettingsRow(title: "Streaming Server", summary: model.settings.streamingServerURL ?? "Not set", systemImage: "server.rack")
                }
                .accessibilityIdentifier("settings.section.server")
            }
            Section("Playback") {
                link(.streams) {
                    SettingsRow(title: "Streams", summary: streamsSummary, systemImage: "play.square.stack")
                }
                .accessibilityIdentifier("settings.section.playback")
                link(.player) {
                    SettingsRow(title: "Player", summary: playerSummary, systemImage: "play.rectangle")
                }
                .accessibilityIdentifier("settings.section.player")
                link(.downloads) {
                    SettingsRow(title: "Downloads", summary: downloadsSummary, systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("settings.section.downloads")
            }
            Section("Customise") {
                link(.appearance) {
                    SettingsRow(title: "Appearance", summary: appearanceSummary, systemImage: "paintpalette")
                }
                .accessibilityIdentifier("settings.section.appearance")
                link(.widgets) {
                    SettingsRow(title: "Widgets", summary: "Home rows and layout", systemImage: "rectangle.3.group")
                }
                .accessibilityIdentifier("settings.widgets")
                // A Mac has no haptic hardware, so the page would be sliders it cannot demonstrate.
                #if !targetEnvironment(macCatalyst)
                link(.haptics) {
                    SettingsRow(title: "Haptics", summary: hapticsSummary, systemImage: "hand.tap")
                }
                .accessibilityIdentifier("settings.section.haptics")
                #endif
            }
            Section("Accounts & Sync") {
                link(.trakt) {
                    SettingsRow(title: "Trakt", summary: traktSummary, systemImage: "person.crop.circle")
                }
                .accessibilityIdentifier("settings.trakt")
                link(.ratings) {
                    SettingsRow(title: "Ratings", summary: ratingsSummary, systemImage: "star.bubble")
                }
                .accessibilityIdentifier("settings.section.reviews")
                if services.sharedFolder != nil {
                    link(.syncFolder) {
                        SettingsRow(title: "Widget Sync", summary: syncFolderName ?? "Off", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityIdentifier("settings.section.syncFolder")
                }
            }
            Section("Advanced") {
                link(.performance) {
                    SettingsRow(title: "Performance", summary: performanceSummary, systemImage: "gauge.with.dots.needle.67percent")
                }
                .accessibilityIdentifier("settings.section.optimisation")
                link(.data) {
                    SettingsRow(title: "Clear Data", summary: "History, library, settings", systemImage: "trash")
                }
                .accessibilityIdentifier("settings.section.data")
            }
            Section {
                link(.about) {
                    SettingsRow(title: "About", summary: "Version \(SettingsViewModel.appVersion)", systemImage: "info.circle")
                }
                .accessibilityIdentifier("settings.section.about")
            }
        }
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .readableColumn()
        .trackLandscapeTabScroll()
        .screenBackground()
        .navigationTitle("Settings")
        .macRootNavigation()
        .pageTabBar(hidden: isPhoneInLandscape)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        // On iPhone, each return to the list: a page pushed from it may have changed what a summary reads.
        .onAppear { Task { await refreshSummaries() } }
        // The review services changed while Settings was open.
        .onChange(of: services.posterRatings.reviewServicesRevision) { model.refreshOMDbUsage() }
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
    }

    /// Mac shows the chosen page beside the list; iPhone pushes it.
    private static var selectsBesideList: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    /// A row that opens `destination`. Beside the list, the chosen row is lit.
    private func link<Label: View>(_ destination: SettingsDestination, @ViewBuilder label: () -> Label) -> some View {
        NavigationLink(value: destination, label: label)
            .listRowBackground(SettingsRowBackground(isSelected: Self.selectsBesideList && router.settingsSelection == destination))
    }

    @ViewBuilder
    private func page(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .addons: AddonsView(services: services)
        case .server: ServerSettingsPage(model: model)
        case .streams: StreamsSettingsPage(model: model, services: services)
        case .player: PlayerSettingsPage(model: model, aetherEngineLinked: aetherEngineLinked)
        case .downloads: DownloadSettingsPage(services: services)
        case .appearance: AppearanceSettingsPage(model: model)
        case .widgets: WidgetsManagerView(services: services, startsHidden: true)
        case .haptics:
            #if targetEnvironment(macCatalyst)
            EmptyView()
            #else
            HapticsSettingsPage(model: model)
            #endif
        case .trakt: TraktAccountView(services: services, settings: model)
        case .ratings: RatingsSettingsPage(model: model, services: services)
        case .syncFolder:
            if let folder = services.sharedFolder { SyncFolderSettingsPage(folder: folder, services: services) }
        case .performance: PerformanceSettingsPage()
        case .data: DataSettingsPage(model: model)
        case .about: AboutSettingsPage(fallbackEngineLinked: fallbackEngineLinked, aetherEngineLinked: aetherEngineLinked)
        }
    }

    private var isPhoneInLandscape: Bool { isPhoneLandscape && UIDevice.current.userInterfaceIdiom == .phone }

    /// The summaries that read state other than the settings model's: Trakt's sign-in, the downloads on disk and the sync folder.
    private func refreshSummaries() async {
        syncFolderName = services.sharedFolder?.folderName
        downloadsBytes = services.downloads?.storageBytes
        traktConnected = await services.traktAccount.isSignedIn()
    }

    private func setGhost(_ isOn: Bool) {
        // A button's tap, not a switch's: Ghost mode changes what every screen shows, so it lands like a change of screen.
        Haptics.play(.buttons)
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
            .glassEffect(.regular, in: ScaledCapsule(scale: metrics.cornerScale(for: .settingsRows)))
            .opacity(min(1, (pull - 24) / 30))
            .padding(.top, Theme.Spacing.s)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Whether Auto Pick starts on its own, the quality asked for, and the source Auto Pick prefers when it is not balanced.
    private var streamsSummary: String {
        let settings = model.settings
        let quality = settings.dataSaverLevel == .ultra ? "Ultra Saver" : settings.dataSaver ? "Data Saver"
            : SettingsViewModel.resolutionOptions.first { $0.value == settings.preferredResolution }?.label ?? "Best available"
        var parts = [settings.autoPlayBestStream ? "Auto Pick" : "Manual", quality]
        if settings.autoPlayBestStream, settings.autoPickSource != .balanced { parts.append(settings.autoPickSource.title) }
        return parts.joined(separator: " · ")
    }

    /// Which player plays, and the subtitles it starts with.
    private var playerSummary: String {
        let player = switch model.settings.playerPreference {
        case .builtIn: "Blusion"
        case .infuse: "Infuse"
        case .infuseWhenNeeded: "Blusion, then Infuse"
        }
        let subtitles = model.settings.subtitleLanguage.flatMap { code in
            SettingsViewModel.languageOptions.first { $0.value == code }?.label
        }
        return "\(player) · " + (subtitles.map { "\($0) subtitles" } ?? "Subtitles off")
    }

    private var downloadsSummary: String {
        guard let downloadsBytes else { return "" }
        return downloadsBytes > 0 ? ByteCountFormatter.string(fromByteCount: downloadsBytes, countStyle: .file) : "None"
    }

    private var traktSummary: String {
        traktConnected.map { $0 ? "Connected" : "Not connected" } ?? ""
    }

    /// The preset in use, or what differs from the app's own look (accent, background, cards, text), then the poster switches that are on.
    private var appearanceSummary: String {
        var on: [String] = []
        if let preset = appearance.preset, preset != .original { return preset.label }
        if appearance.accent != .blusion { on.append(appearance.accent.label) }
        if appearance.background != .black { on.append(appearance.background.label) }
        if appearance.cardScale != 1 { on.append("\(Int((appearance.cardScale * 100).rounded()))% cards") }
        if appearance.textSize != .system { on.append("\(appearance.textSize.label) text") }
        if appearance.font != .standard { on.append(appearance.font.label) }
        if !on.isEmpty || !appearance.isDefault {
            return on.isEmpty ? "Custom" : on.joined(separator: ", ")
        }
        if model.settings.usesHeroPosters { on.append("Hero artwork on posters") }
        if model.settings.showsPosterRatings { on.append("Ratings on posters") }
        if model.settings.showsColouredRatingLogos { on.append("Coloured logos") }
        if model.settings.showsBestDiscOnPosters { on.append("Disc and streamer marks") }
        return on.isEmpty ? "Default" : on.joined(separator: ", ")
    }

    /// The Haptics row shows whether anything has been tuned: the overall strength when it is not 100%, and how many places are off.
    private var hapticsSummary: String {
        let haptics = model.settings.haptics
        guard haptics.isOn else { return "Off" }
        let places = HapticPreferences.Place.allCases
        var parts: [String] = []
        if haptics.overall != HapticPreferences.Default.overallStrength {
            parts.append("\(Int((haptics.overall * 100).rounded()))% overall")
        }
        let off = places.filter { !haptics.plays($0) }.count
        if off > 0 { parts.append("\(off) of \(places.count) off") }
        guard parts.isEmpty else { return parts.joined(separator: " · ") }
        return places.allSatisfy(haptics.isDefault) ? "Default" : "Custom"
    }

    private var ratingsSummary: String {
        var saved: [String] = []
        if model.settings.omdbAPIKey != nil { saved.append("OMDb") }
        if model.settings.tmdbReadToken != nil { saved.append("TMDB") }
        var text = saved.isEmpty ? "IMDb only" : saved.joined(separator: ", ")
        if model.settings.omdbAPIKey != nil {
            text += " · \(model.omdbRequestsToday.formatted()) of \(SettingsViewModel.omdbDailyLimit.formatted()) today"
        }
        return text
    }
}

extension SettingsView {
    /// How far lists load ahead, then whether anything else on the page has been changed.
    private var performanceSummary: String {
        let level = "Load ahead: \(lazyLoadLabel(lookaheadLevel))"
        let isDefault = optimisationHome == OptimisationSettings.homePreloadMatchesLazyLoad
            && optimisationMemory == OptimisationSettings.defaultPictureMemory && optimisationSlots == OptimisationSettings.defaultDownloadSlots
            && optimisationPrefetch && optimisationReadies && optimisationSavesPower
            && imageCacheMegabytes == ImageCachePolicy.defaultDiskMegabytes
        return isDefault ? level : "\(level) · Custom"
    }
}

private func lazyLoadLabel(_ level: Int) -> String {
    LazyLoadLookahead.levels[min(max(level, 1), LazyLoadLookahead.levels.count) - 1].label
}

/// One row of the Settings root, in the format of the Widgets page: a symbol, a title and a one-line summary. Also the Haptics page's
/// rows, one per place.
struct SettingsRow: View {
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

/// A native list with app-owned row backgrounds, so its corners can be adjusted independently.
struct SettingsList<Content: View>: View {
    /// Mac Settings' choice of page. With one, each row draws its own background, so the chosen row can be lit (see `SettingsView`).
    var selection: Binding<SettingsDestination?>? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        List(selection: selection) {
            if selection == nil {
                content()
                    .listRowBackground(SettingsRowBackground())
                    .listRowSeparator(.hidden)
            } else {
                content()
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.grouped)
        .contentMargins(.horizontal, metrics.pageMargin, for: .scrollContent)
        .listRowSpacing(4)
    }
}

struct SettingsRowBackground: View {
    /// The page shown beside the list (Mac Settings).
    var isSelected = false
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.surface * metrics.cornerScale(for: .settingsRows), style: .continuous)
            .fill(isSelected ? AnyShapeStyle(TintShapeStyle().opacity(0.35)) : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)))
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
            .macBackNavigation()
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings → Streams: the quality asked of addons, and Auto Pick (whether it plays on its own, the source it prefers and which addons
/// it waits for).
private struct StreamsSettingsPage: View {
    let model: SettingsViewModel
    let services: AppServices

    var body: some View {
        SettingsList {
            Section {
                Picker("Quality",
                       selection: Binding(get: { model.settings.preferredResolution },
                                          set: { value in Haptics.play(.choices); Task { await model.setPreferredResolution(value) } })) {
                    ForEach(SettingsViewModel.resolutionOptions) { Text($0.label).tag($0.value) }
                }
                .accessibilityIdentifier("settings.resolution")
                // Ultra keeps to 720p and the leanest encodes.
                Picker("Data Saver",
                       selection: Binding(get: { model.settings.dataSaverLevel },
                                          set: { level in Haptics.play(.choices); Task { await model.setDataSaverLevel(level) } })) {
                    ForEach(DataSaverLevel.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.dataSaver")
            }
            Section("Auto Pick") {
                Toggle("Play best stream automatically", isOn: Binding(get: { model.settings.autoPlayBestStream }, set: { value in
                    Task { await model.setAutoPlayBestStream(value) }
                }))
                .accessibilityIdentifier("settings.autoPlay")
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text("Prefer")
                    Picker("Prefer", selection: Binding(get: { model.settings.autoPickSource }, set: { value in
                        Haptics.play(.choices)
                        Task { await model.setAutoPickSource(value) }
                    })) {
                        ForEach(StreamSourcePreference.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("settings.autoPickSource")
                }
                SettingsSubpageLink(id: "streams.addonSpeed") {
                    AddonSpeedSettingsPage(services: services, onChange: { Task { await model.load() } })
                } label: {
                    LabeledContent("Waits for", value: waitSummary)
                }
                .accessibilityIdentifier("settings.section.addonSpeed")
            }
        }
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
        .settingsPage("Streams")
    }

    private var waitSummary: String {
        switch model.settings.autoPickWait {
        case .allAddons: "All addons"
        case .fastest: "Fastest addon"
        case .addon: AddonSpeedViewModel.summary(for: model.settings.autoPickWait, names: model.addonNames)
        }
    }
}

/// Settings → Performance: how far ahead lists and Home load, what is readied before Play, how much artwork is held, downloaded at once
/// and kept on disk, and Low Power Mode (see `OptimisationSettings`, `ImageCachePolicy`). Every choice applies at once.
private struct PerformanceSettingsPage: View {
    @AppStorage(LazyLoadLookahead.defaultsKey) private var lookaheadLevel = LazyLoadLookahead.defaultLevel
    @AppStorage(OptimisationSettings.homePreloadKey) private var homePreload = OptimisationSettings.homePreloadMatchesLazyLoad
    @AppStorage(OptimisationSettings.prefetchesStreamsKey) private var prefetchesStreams = true
    @AppStorage(OptimisationSettings.readiesFirstStreamKey) private var readiesFirstStream = true
    @AppStorage(OptimisationSettings.pictureMemoryKey) private var pictureMemory = OptimisationSettings.defaultPictureMemory
    @AppStorage(OptimisationSettings.downloadSlotsKey) private var downloadSlots = OptimisationSettings.defaultDownloadSlots
    @AppStorage(OptimisationSettings.savesPowerKey) private var savesPower = true
    @AppStorage(ImageCachePolicy.diskMegabytesKey) private var diskMegabytes = ImageCachePolicy.defaultDiskMegabytes
    @State private var diskInUse: Int?
    @State private var confirmsClear = false

    private var isDefault: Bool {
        lookaheadLevel == LazyLoadLookahead.defaultLevel && homePreload == OptimisationSettings.homePreloadMatchesLazyLoad
            && prefetchesStreams && readiesFirstStream && pictureMemory == OptimisationSettings.defaultPictureMemory
            && downloadSlots == OptimisationSettings.defaultDownloadSlots && savesPower
            && diskMegabytes == ImageCachePolicy.defaultDiskMegabytes
    }

    var body: some View {
        SettingsList {
            Section("Load Ahead") {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    HStack {
                        Text("Lists")
                        Spacer()
                        Text("\(lazyLoadLabel(lookaheadLevel)) · \(LazyLoadLookahead.titles(atLevel: lookaheadLevel)) titles")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    GlassSlider(value: $lookaheadLevel, stops: LazyLoadLookahead.levels.count)
                        .accessibilityLabel("Lists")
                        .accessibilityValue(lazyLoadLabel(lookaheadLevel))
                        .accessibilityIdentifier("settings.lazyLoadLookahead")
                    HStack {
                        Text(LazyLoadLookahead.levels[0].label)
                        Spacer()
                        Text(LazyLoadLookahead.levels[LazyLoadLookahead.levels.count - 1].label)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }
                picker("Home", selection: $homePreload, options: OptimisationSettings.homePreloadOptions,
                       id: "settings.optimisation.homePreload")
            }
            Section("Streams") {
                Toggle("Look up streams when a title opens", isOn: choice($prefetchesStreams))
                    .accessibilityIdentifier("settings.optimisation.prefetchStreams")
                Toggle("Pre-buffer the top stream", isOn: choice($readiesFirstStream))
                    .accessibilityIdentifier("settings.optimisation.readyFirstStream")
            }
            Section("Artwork") {
                picker("Memory", selection: $pictureMemory, options: pictureMemoryOptions, id: "settings.optimisation.pictureMemory")
                picker("Downloads at once", selection: $downloadSlots, options: OptimisationSettings.downloadSlotOptions,
                       id: "settings.optimisation.downloadSlots")
                Picker("Disk cache", selection: Binding(get: { diskMegabytes }, set: { new in
                    Haptics.play(.choices)
                    diskMegabytes = new
                })) {
                    ForEach(ImageCachePolicy.diskSizeOptions, id: \.self) { Text(Self.sizeName($0)).tag($0) }
                }
                .accessibilityIdentifier("settings.imageCache.size")
                LabeledContent("Disk cache used") {
                    Text(diskInUse.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—")
                        .monospacedDigit()
                        .accessibilityLabel(diskInUse.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Measuring")
                }
                .accessibilityIdentifier("settings.imageCache.inUse")
                Button("Clear Artwork Cache", role: .destructive) { confirmsClear = true }
                    .accessibilityIdentifier("settings.imageCache.clear")
            }
            Section {
                Toggle("Save power in Low Power Mode", isOn: choice($savesPower))
                    .accessibilityIdentifier("settings.optimisation.savesPower")
            }
            Section {
                Button("Restore Defaults") {
                    Haptics.play(.buttons)
                    for key in OptimisationSettings.allKeys + [ImageCachePolicy.diskMegabytesKey] { UserDefaults.standard.removeObject(forKey: key) }
                    applyPictures()
                    applyDiskLimit()
                }
                .disabled(isDefault)
                .accessibilityIdentifier("settings.optimisation.restore")
            }
        }
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
        .settingsPage("Performance")
        .task { diskInUse = ImagePipeline.shared.diskUsage }
        .onChange(of: pictureMemory) { applyPictures() }
        .onChange(of: downloadSlots) { applyPictures() }
        .onChange(of: savesPower) { applyPictures() }
        .onChange(of: diskMegabytes) { applyDiskLimit() }
        .confirmationDialog("Clear the artwork cache?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear Artwork Cache", role: .destructive) {
                // Off the main thread: emptying a full cache takes a moment, and the page should not stall while it does.
                Task {
                    await Task.detached(priority: .userInitiated) { ImagePipeline.shared.clearDisk() }.value
                    diskInUse = ImagePipeline.shared.diskUsage
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Posters and backdrops download again as you browse.")
        }
    }

    /// Memory's choices with what each holds on this device: "Balanced · 1 GB".
    private var pictureMemoryOptions: [OptimisationSettings.Option] {
        OptimisationSettings.pictureMemoryOptions.map { option in
            let bytes = ImageCachePolicy.decodedBytes(physicalMemory: ProcessInfo.processInfo.physicalMemory, level: option.value)
            return OptimisationSettings.Option(label: "\(option.label) · \(Self.sizeName(bytes / 1024 / 1024))", value: option.value)
        }
    }

    static func sizeName(_ megabytes: Int) -> String {
        megabytes >= 1024 ? "\(megabytes / 1024) GB" : "\(megabytes) MB"
    }

    /// A switch that ticks as it is flipped, as Settings' other switches do.
    private func choice(_ value: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue }, set: { new in
            Haptics.play(.choices)
            value.wrappedValue = new
        })
    }

    private func picker(_ title: LocalizedStringKey, selection: Binding<Int>, options: [OptimisationSettings.Option], id: String) -> some View {
        Picker(title, selection: Binding(get: { selection.wrappedValue }, set: { new in
            Haptics.play(.choices)
            selection.wrappedValue = new
        })) {
            ForEach(options) { Text($0.label).tag($0.value) }
        }
        .accessibilityIdentifier(id)
    }

    /// The picture loader takes its new memory limit and number of downloads at once now, not at the next launch.
    private func applyPictures() {
        ImagePipeline.shared.setMemoryLevel(OptimisationSettings.pictureMemory())
        Task { await ImagePipeline.shared.downloadSlotsChanged() }
    }

    private func applyDiskLimit() {
        ImagePipeline.shared.setDiskLimit(megabytes: UserDefaults.standard.object(forKey: ImageCachePolicy.diskMegabytesKey) as? Int
                                          ?? ImageCachePolicy.defaultDiskMegabytes)
        diskInUse = ImagePipeline.shared.diskUsage
    }
}

/// Settings → Ratings: OMDb's requests today (the app's own OMDb and TMDB keys are built in), and the offline IMDb scores (when they
/// were last updated, and whose they are: IMDb asks for the credit and limits the data to personal, non-commercial use).
private struct RatingsSettingsPage: View {
    let model: SettingsViewModel
    let services: AppServices
    @State private var datasetStatus: IMDbDatasetStatus?

    private var used: Int { model.omdbRequestsToday }
    private var limit: Int { SettingsViewModel.omdbDailyLimit }

    var body: some View {
        SettingsList {
            Section("OMDb") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Requests today", value: "\(used.formatted()) of \(limit.formatted())")
                    ProgressView(value: Double(min(used, limit)), total: Double(limit))
                        .tint(Double(used) >= Double(limit) * 0.9 ? .orange : nil)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.omdbUsage")
            }
            Section {
                Button("Refresh Ratings") { Task { await model.refreshRatings() } }
                    .accessibilityIdentifier("settings.reviews.refresh")
                if let error = services.posterRatings.omdbError ?? services.posterRatings.reviewServiceIssue {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settings.reviews.error")
                } else if let message = model.lastMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.reviews.message")
                }
            }
            Section {
                LabeledContent("Titles", value: datasetStatus.map { $0.titleCount.formatted() } ?? IMDbDatasetSummary.text(nil))
                    .accessibilityIdentifier("settings.imdbDataset")
                if let status = datasetStatus {
                    LabeledContent("Updated", value: (status.updatedAt ?? status.checkedAt)
                        .map { $0.formatted(.dateTime.day().month(.abbreviated).year()) } ?? "Not yet")
                    LabeledContent("Size on disk", value: status.fileSize.map { $0.formatted(.byteCount(style: .file)) } ?? "Unknown")
                }
                if let url = IMDbAttribution.termsURL { Link("IMDb Data Terms", destination: url) }
            } header: {
                Text("IMDb")
            } footer: {
                // IMDb's credit and terms, which its non-commercial datasets require.
                Text("\(IMDbAttribution.notice) \(IMDbAttribution.terms)")
            }
        }
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
        .settingsPage("Ratings")
        .onAppear { model.clearMessage() }
        .task {
            model.refreshOMDbUsage()
            datasetStatus = await services.posterRatings.imdbDatasetStatus()
        }
        // A new copy of the IMDb data arrived while the page was open, or the review services changed.
        .onChange(of: services.posterRatings.reviewServicesRevision) {
            model.refreshOMDbUsage()
            Task { datasetStatus = await services.posterRatings.imdbDatasetStatus() }
        }
    }
}

private struct ServerSettingsPage: View {
    @Bindable var model: SettingsViewModel

    var body: some View {
        SettingsList {
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
                Button("Save Address") { Task { await model.commitServerURL() } }
                    .disabled(model.serverURLMessage != nil)
                    .accessibilityIdentifier("settings.serverURL.save")
            }
        }
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
        .settingsPage("Streaming Server")
    }
}

private struct DataSettingsPage: View {
    let model: SettingsViewModel
    @State private var pendingScope: DataResetService.Scope?

    var body: some View {
        SettingsList {
            Section {
                ForEach(DataResetService.Scope.allCases.filter { $0 != .everything }, id: \.self) { scope in clearButton(scope) }
            }
            Section {
                clearButton(.everything)
            }
            if let message = model.lastMessage {
                Section {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.clearMessage")
                }
            }
        }
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
        .settingsPage("Clear Data")
        .onAppear { model.clearMessage() }
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

    private func clearButton(_ scope: DataResetService.Scope) -> some View {
        Button(scope.title, role: .destructive) { pendingScope = scope }
            .accessibilityIdentifier("settings.clear.\(String(describing: scope))")
    }
}

/// The folder the Home layout is shared through with the user's other devices, such as one in iCloud Drive (see `SyncedWidgetStore`).
private struct SyncFolderSettingsPage: View {
    let folder: SharedFolder
    let services: AppServices
    @State private var folderName: String?
    @State private var isChoosing = false
    @State private var failed = false

    var body: some View {
        SettingsList {
            Section {
                LabeledContent("Folder", value: folderName ?? "None")
                Button(folderName == nil ? "Choose Folder" : "Change Folder") { isChoosing = true }
                    .accessibilityIdentifier("settings.syncFolder.choose")
                if folderName != nil {
                    Button("Stop Syncing", role: .destructive) {
                        folder.forget()
                        folderName = nil
                    }
                    .accessibilityIdentifier("settings.syncFolder.stop")
                }
                if failed {
                    Label("That folder can't be used.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
        .settingsPage("Widget Sync")
        .onAppear { folderName = folder.folderName }
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            do {
                try folder.choose(url)
                folderName = folder.folderName
                failed = false
                // The first look at the folder: its layout comes in, or this device's layout starts it.
                Task { _ = await services.widgets.takeInSharedLayout() }
            } catch {
                failed = true
            }
        }
    }
}

/// How fast each addon answers, and what Auto Pick waits for. The test runs only when asked: every request is a real lookup. The addons
/// stay in the user's own order, which also orders Home's rows.
private struct AddonSpeedSettingsPage: View {
    @Environment(\.layoutMetrics) private var metrics
    @State private var model: AddonSpeedViewModel
    /// Tells Settings the choice changed, so its row's summary follows.
    let onChange: () -> Void
    @State private var isOnline = true

    init(services: AppServices, onChange: @escaping () -> Void) {
        _model = State(initialValue: AddonSpeedViewModel(services: services))
        self.onChange = onChange
    }

    var body: some View {
        SettingsList {
            Section {
                Button {
                    Task { await model.test() }
                } label: {
                    HStack {
                        Text(model.isTesting ? "Testing…" : "Test Speed")
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
                                .background(.tint.opacity(0.25), in: ScaledCapsule(scale: metrics.cornerScale(for: .settingsRows)))
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
                waitChoice("Fastest addon", .fastest)
                ForEach(model.rows) { row in waitChoice(row.addon.name, .addon(row.id)) }
            } header: {
                Text("Auto Pick Waits For")
            }
        }
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
        .settingsPage("Addon Speed")
        .task { await model.load() }
        .task { for await path in NWPathMonitor() { isOnline = path.status == .satisfied } }
    }

    private func waitChoice(_ title: String, _ wait: AutoPickWait) -> some View {
        Button {
            Haptics.play(.choices)
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
        SettingsList {
            Section {
                LabeledContent("Version", value: SettingsViewModel.appVersion)
                SettingsSubpageLink(id: "about.acknowledgements") {
                    AcknowledgementsView(fallbackEngineLinked: fallbackEngineLinked, aetherEngineLinked: aetherEngineLinked)
                } label: {
                    Text("Acknowledgements")
                }
                    .accessibilityIdentifier("settings.acknowledgements")
            } footer: {
                Text("""
                    Blusion includes no content or stream sources. Cinemeta provides catalogs and search; you can remove it in Settings › \
                    Addons. Blusion isn’t affiliated with any addon or service.
                    """)
            }
        }
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
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
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
        .scrollContentBackground(.hidden)
        .readableColumn()
        .screenBackground()
        .navigationTitle("Acknowledgements")
        .macBackNavigation()
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("acknowledgements.list")
    }
}
#endif
