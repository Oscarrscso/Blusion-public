#if canImport(UIKit)
import SwiftUI
import StremioKit
import PlayerKit

/// The device's downloads, shown in place on Library's Downloads page: a card per download, filtered and sorted by the page's Downloads
/// filter. It is part of the page, not a screen of its own.
struct DownloadsView: View {
    let services: AppServices
    let filter: DownloadFilter
    /// Clears the Downloads filter, for when it hides every download.
    let clearFilters: () -> Void
    @State private var plan: PlaybackPlan?
    @State private var progress: [String: WatchProgress] = [:]
    @State private var addonNames: [UUID: String] = [:]
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.isLandscape) private var isLandscape

    var body: some View {
        content
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await services.downloads?.start()
                await loadDetails()
            }
            .fullScreenCover(item: $plan, onDismiss: { Task { await loadDetails() } }) {
                PlayerScreen(plan: $0, services: services)
            }
            .downloadErrors(services.downloads)
    }

    @ViewBuilder private var content: some View {
        if let manager = services.downloads {
            let shown = DownloadFiltering.apply(filter, to: manager.items)
            if manager.items.isEmpty {
                EmptyStateLayout(title: "No Downloads", systemImage: "arrow.down.circle", message: nil) { EmptyView() }
                    .accessibilityIdentifier("library.downloads.empty")
            } else if shown.isEmpty {
                EmptyStateLayout(title: "No downloads match", systemImage: "line.3.horizontal.decrease.circle", message: "Try removing a filter.") {
                    Button("Clear Filters", action: clearFilters)
                        .buttonStyle(.primaryActionCompact)
                        .accessibilityIdentifier("library.downloads.noMatches.clear")
                }
                .accessibilityIdentifier("library.downloads.noMatches")
            } else {
                LazyVGrid(columns: columns, spacing: metrics.cardSpacing) {
                    ForEach(shown) { item in
                        DownloadCard(item: item, manager: manager, progress: progress[item.request.identity],
                                     addonName: addonNames[item.addonID], thumbnailWidth: thumbnailWidth) {
                            Task { plan = await manager.plan(for: item.id) }
                        }
                    }
                }
                .padding(.horizontal, metrics.pageMargin)
            }
        }
    }

    /// A phone in portrait lists one card across. Turned sideways, or on a Mac or iPad, cards sit in as many columns as fit, so each is wide
    /// enough for its thumbnail and text, and the extra width is used rather than left empty.
    private var columns: [GridItem] {
        let wide = metrics.isRegular || isLandscape
        let size: GridItem.Size = wide ? .adaptive(minimum: metrics.isRegular ? 440 : 340) : .flexible()
        return [GridItem(size, spacing: metrics.cardSpacing, alignment: .top)]
    }

    /// The thumbnail is 16:9, and grows with the card: a row of two wide cards keeps its text beside a larger picture.
    private var thumbnailWidth: CGFloat {
        metrics.isRegular ? 200 : isLandscape ? 160 : 132
    }

    private func loadDetails() async {
        let records = await services.progress.all()
        progress = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { $0.updatedAt > $1.updatedAt ? $0 : $1 })
        addonNames = Dictionary(await services.registry.addons.map { ($0.id, Redactor.redact(text: $0.name)) },
                               uniquingKeysWith: { first, _ in first })
    }
}

/// Settings → Downloads: when downloads may run and be removed, and the space they take.
struct DownloadSettingsPage: View {
    let services: AppServices
    @State private var cellular = false
    @State private var deleteWatched = false
    @State private var confirmsDelete = false
    var body: some View {
        SettingsList {
            Section {
                // A Mac has no cellular connection to allow.
                #if !targetEnvironment(macCatalyst)
                Toggle("Use cellular data", isOn: Binding(get: { cellular }, set: { value in
                    Haptics.play(.choices)
                    cellular = value
                    Task {
                        _ = await services.settings.update { $0.downloadsAllowCellular = value }
                        await services.downloads?.preferencesChanged()
                    }
                }))
                .accessibilityIdentifier("settings.downloads.cellular")
                #endif
                Toggle("Delete after watching", isOn: Binding(get: { deleteWatched }, set: { value in
                    Haptics.play(.choices)
                    deleteWatched = value
                    Task {
                        _ = await services.settings.update { $0.downloadsDeleteWhenWatched = value }
                    }
                }))
                .accessibilityIdentifier("settings.downloads.deleteWatched")
            }
            Section {
                LabeledContent("Storage used", value: storageText)
                    .accessibilityIdentifier("settings.downloads.storage")
                Button("Delete All Downloads", role: .destructive) { confirmsDelete = true }
                    .accessibilityIdentifier("settings.downloads.deleteAll")
            }
        }
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
        .settingsPage("Downloads")
        .task {
            let settings = await services.settings.load()
            cellular = settings.downloadsAllowCellular; deleteWatched = settings.downloadsDeleteWhenWatched
            await services.downloads?.start()
        }
        .confirmationDialog("Delete all downloads?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete All Downloads", role: .destructive) { Task { await services.downloads?.deleteAll() } }
            Button("Cancel", role: .cancel) {}
        }
        .downloadErrors(services.downloads)
    }

    private var storageText: String {
        let bytes = services.downloads?.storageBytes ?? 0
        return bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "None"
    }
}

private struct DownloadErrors: ViewModifier {
    let manager: DownloadManager?
    func body(content: Content) -> some View {
        content.alert("Downloads", isPresented: Binding(get: { manager?.errorMessage != nil }, set: { if !$0 { manager?.clearError() } })) {
            Button("OK") { manager?.clearError() }
        } message: { Text(manager?.errorMessage ?? "") }
    }
}
extension View {
    func downloadErrors(_ manager: DownloadManager?) -> some View { modifier(DownloadErrors(manager: manager)) }
}
#endif
