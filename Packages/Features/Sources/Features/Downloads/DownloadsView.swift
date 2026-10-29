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

struct DownloadSettingsPage: View {
    let services: AppServices
    @State private var cellular = false
    @State private var deleteWatched = false
    @State private var confirmsDelete = false
    var body: some View {
        Form {
            Section {
                Toggle("Cellular Downloads", isOn: Binding(get: { cellular }, set: { value in
                    cellular = value
                    Task {
                        var settings = await services.settings.load()
                        settings.downloadsAllowCellular = value
                        await services.settings.save(settings)
                        await services.downloads?.preferencesChanged()
                    }
                }))
                Toggle("Delete When Watched", isOn: Binding(get: { deleteWatched }, set: { value in
                    deleteWatched = value
                    Task {
                        var settings = await services.settings.load()
                        settings.downloadsDeleteWhenWatched = value
                        await services.settings.save(settings)
                    }
                }))
                LabeledContent("Storage Used", value: ByteCountFormatter.string(fromByteCount: services.downloads?.storageBytes ?? 0, countStyle: .file))
                Button("Delete All", role: .destructive) { confirmsDelete = true }
            }
        }
        .navigationTitle("Downloads")
        .task {
            let settings = await services.settings.load()
            cellular = settings.downloadsAllowCellular; deleteWatched = settings.downloadsDeleteWhenWatched
            await services.downloads?.start()
        }
        .confirmationDialog("Delete All Downloads?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { Task { await services.downloads?.deleteAll() } }
        }
        .downloadErrors(services.downloads)
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
