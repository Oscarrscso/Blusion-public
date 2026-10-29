#if canImport(UIKit)
import SwiftUI
import StremioKit
import PlayerKit

/// One download as a card: its portrait poster on the left, and beside it the title, episode, quality, status,
/// progress, speed and controls, with the details under them. The card's own background is a soft blur of the same artwork, tinted so the
/// text reads; the thumbnail is drawn as it is. Tapping the card opens its title, while the download controls act independently.
struct DownloadCard: View {
    let item: DownloadItem
    let manager: DownloadManager
    let progress: WatchProgress?
    let addonName: String?
    /// The thumbnail's width. A wide layout gives the card a wider one.
    let thumbnailWidth: CGFloat
    let play: () -> Void
    @Environment(\.displayScale) private var displayScale

    private var format: String {
        MediaContainer(rawValue: item.container).map { DownloadEligibility.fileExtension($0).uppercased() } ?? item.container.uppercased()
    }
    private var summary: String {
        [item.mediaDetails?["Resolution"], format, item.mediaDetails?["Video"], item.mediaDetails?["Dynamic Range"]]
            .compactMap { $0 }.joined(separator: " · ")
    }
    private var episodeLine: String? {
        if let season = item.request.season, let episode = item.request.episode { return "Season \(season) · Episode \(episode)" }
        return item.request.year
    }
    private var statusLine: String {
        if item.pendingDeletion == true { return "Deleting" }
        return item.state == .complete ? "Downloaded" : item.state.rawValue.capitalized
    }
    /// Episodes open their parent series, while movies open their own title page.
    private var titlePreview: MetaPreview {
        let request = item.request
        let name = request.seriesName ?? request.title.components(separatedBy: " · ").first ?? request.title
        return MetaPreview(id: ContentID(request.id).baseID, type: request.type, name: name,
                           poster: DownloadArtwork.poster(for: request), background: DownloadArtwork.backdrop(for: request),
                           releaseInfo: request.year)
    }
    /// The artwork's pixel size, shared by the poster and blurred backdrop.
    private var pixelSize: CGFloat { LandscapeArtwork.maxPixelSize(width: thumbnailWidth, scale: displayScale) }
    /// The cached picture when the download has one, else the title's backdrop or poster from Metahub.
    private var picture: (url: URL?, fallback: URL?) {
        DownloadArtwork.picture(for: item.request, cached: manager.artworkURL(for: item))
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                thumbnail
                info
            }
            DisclosureGroup("Details") { details }
                .font(.subheadline)
                .tint(.white)
        }
        .foregroundStyle(.white)
        .padding(Theme.Spacing.m)
        .background {
            NavigationLink(value: titlePreview) {
                backdrop.contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .glassHairline(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityIdentifier("download.\(item.id.uuidString)")
    }

    /// The standard 2:3 poster; tapping it opens the movie or series.
    private var thumbnail: some View {
        NavigationLink(value: titlePreview) {
            ArtworkImage(url: DownloadArtwork.poster(for: item.request), maxPixelSize: pixelSize, fallbackURL: picture.url)
                .frame(width: thumbnailWidth, height: thumbnailWidth / CardAspect.poster.ratio)
                .mediaArtwork(cornerRadius: Theme.Radius.small)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(titlePreview.name)")
    }

    /// The text beside the thumbnail. Its controls sit in the status row, so the card is as tall as its text and no taller.
    private var info: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(item.request.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
            if let episodeLine {
                Text(episodeLine).font(.subheadline).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            }
            if !summary.isEmpty {
                Text(summary).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.xs)
            if item.state != .complete { progressRow }
            if item.state == .downloading { speedRow }
            if let failure = item.failure {
                Text(failure).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
            statusRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progressRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Spacing.s) {
                ProgressView(value: item.fraction).tint(.white)
                if item.expected > 0 { Text("\(Int(item.fraction * 100))%").font(.caption).monospacedDigit() }
            }
            Text(item.expected > 0 ? "\(bytes(item.received)) / \(bytes(item.expected))" : bytes(item.received))
                .font(.caption).foregroundStyle(.white.opacity(0.7)).monospacedDigit().lineLimit(1)
        }
    }

    /// The speed and the time left, as the transfer is running. Refreshed each second, as the download list always was.
    private var speedRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(speedText(manager.speed(for: item.id, at: context.date)))
                .font(.caption).foregroundStyle(.white.opacity(0.7)).monospacedDigit().lineLimit(1)
        }
    }

    private func speedText(_ speed: Double?) -> String {
        let rate = speed.map { bytes(Int64($0)) + "/s" } ?? "—"
        guard let speed, speed > 0, item.expected > item.received else { return rate }
        return "\(rate) · \(PlayerTime.format(Double(item.expected - item.received) / speed)) left"
    }

    /// The status on the left, the controls on the right. The controls are the ones the download list always had.
    private var statusRow: some View {
        HStack(spacing: Theme.Spacing.s) {
            Label(statusLine, systemImage: item.state == .complete ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: Theme.Spacing.s)
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: Theme.Spacing.s) {
            if item.state == .downloading || item.state == .queued {
                Button { Haptics.tap(); Task { await manager.pause(item.id) } } label: {
                    DownloadProgressGlyph(item: item)
                }
                .accessibilityLabel("Pause Download")
                .glassCircleButton(.regular)
            } else if item.state != .complete {
                Button("Resume", systemImage: "arrow.down.circle") { Haptics.tap(); Task { await manager.resume(item.id) } }
                    .labelStyle(.iconOnly)
                    .glassCircleButton(.regular)
            } else {
                Button("Play", systemImage: "play.fill", action: play)
                    .labelStyle(.iconOnly)
                    .glassCircleButton(.regular)
            }
            Button("Delete", systemImage: "trash", role: .destructive) { Haptics.tap(); Task { await manager.delete(item.id) } }
                .labelStyle(.iconOnly)
                .glassCircleButton(.regular)
        }
    }

    private var details: some View {
        VStack(spacing: Theme.Spacing.s) {
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
        .padding(.top, Theme.Spacing.s)
    }

    /// The artwork, blurred and tinted: soft enough that the card reads as its title's colours, and dim enough that its text reads. It is
    /// scaled up a little so the blur's soft edge falls outside the card.
    private var backdrop: some View {
        ZStack {
            ArtworkImage(url: picture.url, maxPixelSize: pixelSize, fallbackURL: picture.fallback)
                .scaleEffect(1.35)
                .blur(radius: 44, opaque: true)
            Color.black.opacity(0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityHidden(true)
    }
}
#endif
