#if canImport(UIKit)
import SwiftUI
import StremioKit
import PlayerKit

struct DownloadsView: View {
    let services: AppServices
    @State private var plan: PlaybackPlan?
    @State private var progress: [String: WatchProgress] = [:]
    @State private var addonNames: [UUID: String] = [:]
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let manager = services.downloads {
                List {
                    ForEach(manager.items) { item in
                        DownloadRow(item: item, manager: manager, progress: progress[item.request.identity],
                                    addonName: addonNames[item.addonID]) {
                            Task { plan = await manager.plan(for: item.id) }
                        }
                    }
                }
                .overlay {
                    if manager.items.isEmpty { ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle") }
                }
            }
        }
        .navigationTitle("Downloads")
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
    private func loadDetails() async {
        let records = await services.progress.all()
        progress = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { $0.updatedAt > $1.updatedAt ? $0 : $1 })
        addonNames = Dictionary(await services.registry.addons.map { ($0.id, Redactor.redact(text: $0.name)) },
                               uniquingKeysWith: { first, _ in first })
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let manager: DownloadManager
    let progress: WatchProgress?
    let addonName: String?
    let play: () -> Void

    private var format: String {
        MediaContainer(rawValue: item.container).map { DownloadEligibility.fileExtension($0).uppercased() } ?? item.container.uppercased()
    }
    private var summary: String {
        [item.mediaDetails?["Resolution"], format, item.mediaDetails?["Video"], item.mediaDetails?["Dynamic Range"]]
            .compactMap { $0 }.joined(separator: " · ")
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: play) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.request.title).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        if let season = item.request.season, let episode = item.request.episode {
                            Text("Season \(season) · Episode \(episode)").font(.subheadline).foregroundStyle(.secondary)
                        } else if let year = item.request.year {
                            Text(year).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.state != .complete || item.pendingDeletion == true)
                controls
            }
            HStack {
                Label(item.pendingDeletion == true ? "Deleting" : item.state == .complete ? "Downloaded" : item.state.rawValue.capitalized,
                      systemImage: item.state == .complete ? "checkmark.circle.fill" : "arrow.down.circle")
                Spacer()
                if item.expected > 0 { Text("\(Int(item.fraction * 100))%").monospacedDigit() }
            }
            .font(.subheadline)
            if item.state != .complete { ProgressView(value: item.fraction) }
            Text(item.expected > 0 ? "\(bytes(item.received)) / \(bytes(item.expected))" : bytes(item.received))
                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            if item.state == .downloading {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let speed = manager.speed(for: item.id, at: context.date)
                    HStack {
                        LabeledContent("Speed", value: speed.map { bytes(Int64($0)) + "/s" } ?? "—")
                        if let speed, speed > 0, item.expected > item.received {
                            LabeledContent("Remaining", value: PlayerTime.format(Double(item.expected - item.received) / speed))
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            if let failure = item.failure { Text(failure).font(.subheadline).foregroundStyle(.orange) }
            DisclosureGroup("Details") {
                VStack(spacing: 8) {
                    LabeledContent("Type", value: item.request.episode != nil ? "Episode" : item.request.type.capitalized)
                    LabeledContent("Format", value: format)
                    ForEach(["Resolution", "Source", "Release", "Video", "Dynamic Range", "Audio"], id: \.self) { key in
                        if let value = item.mediaDetails?[key] { LabeledContent(key, value: value) }
                    }
                    if let duration = item.request.expectedDuration, duration > 0 {
                        LabeledContent("Runtime", value: PlayerTime.format(duration))
                    }
                    LabeledContent("Addon", value: addonName ?? "Removed addon")
                    LabeledContent("Added", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let completed = item.completedAt {
                        LabeledContent("Downloaded", value: completed.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Playback", value: item.usesFallback ? "Advanced player" : "Native player")
                    LabeledContent("Watch Status", value: progress?.isWatched == true ? "Watched" : "Not watched")
                    if let progress, progress.position > 0 {
                        LabeledContent("Watched", value: "\(PlayerTime.format(progress.position)) / \(PlayerTime.format(progress.duration))")
                    }
                    LabeledContent("Subtitles", value: item.subtitles.isEmpty ? "None" :
                        Array(Set(item.subtitles.map(\.language))).sorted().map { LanguageCodes.displayName($0) }.joined(separator: ", "))
                    if item.retries > 0 { LabeledContent("Retries", value: String(item.retries)) }
                }
                .font(.subheadline)
                .padding(.top, 8)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("download.\(item.id.uuidString)")
    }
    private var controls: some View {
        HStack(spacing: 12) {
            if item.state == .downloading || item.state == .queued {
                Button { Haptics.tap(); Task { await manager.pause(item.id) } } label: {
                    DownloadProgressGlyph(item: item).padding(5)
                }.accessibilityLabel("Pause Download").buttonStyle(.borderless)
            } else if item.state != .complete {
                Button("Resume", systemImage: "arrow.down.circle") { Haptics.tap(); Task { await manager.resume(item.id) } }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            } else {
                Button("Play", systemImage: "play.fill", action: play).labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            Button("Delete", systemImage: "trash", role: .destructive) { Haptics.tap(); Task { await manager.delete(item.id) } }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
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
