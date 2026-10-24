#if canImport(UIKit)
import SwiftUI
import StremioKit

/// Landscape artwork with a centered title logo and a compact playback row inside its bottom fade.
struct ProgressCard: View {
    let title: String
    let subtitle: String?
    let artwork: URL?
    let logo: URL?
    let fraction: Double
    let duration: TimeInterval?
    let width: CGFloat?
    @Environment(\.layoutMetrics) private var metrics

    init(title: String, subtitle: String? = nil, artwork: URL?, logo: URL? = nil, fraction: Double,
         duration: TimeInterval? = nil, width: CGFloat? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
        self.logo = logo
        self.fraction = fraction
        self.duration = duration
        self.width = width
    }

    var body: some View {
        let progress = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        let fixed = width ?? metrics.continueCardWidth
        let overlay = PlaybackProgressOverlay(fraction: progress, duration: duration, episode: subtitle, width: fixed)
        LandscapeCard(title: title, logo: logo, artwork: artwork, width: width) { overlay }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([title, subtitle, overlay.remainingTime, "\(Int((progress * 100).rounded())) percent watched"].compactMap { $0 }
                .filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

extension View {
    /// A Continue Watching card: a tap opens its title's page with the stream picker open on the item it resumes, or, with Auto Pick on,
    /// starts that item's stream from Home (see `ContinueWatchingLauncher`). Its context menu opens the title from that artwork.
    func continueWatchingHold(preview: MetaPreview, request: StreamRequest, itemID: String, launcher: ContinueWatchingLauncher?,
                              onMarkWatched: @escaping () -> Void, onRemove: @escaping () -> Void) -> some View {
        modifier(ContinueWatchingHoldModifier(preview: preview, request: request, itemID: itemID,
                                               launcher: launcher, onMarkWatched: onMarkWatched, onRemove: onRemove))
    }
}

private struct ContinueWatchingHoldModifier: ViewModifier {
    let preview: MetaPreview
    let request: StreamRequest
    let itemID: String
    let launcher: ContinueWatchingLauncher?
    let onMarkWatched: () -> Void
    let onRemove: () -> Void
    @Environment(AppRouter.self) private var router
    @Environment(\.zoomNamespace) private var zoomNamespace
    @Environment(\.zoomScope) private var zoomScope

    /// True while a card's streams load on Home: every card ignores taps meanwhile, and looks as it did.
    private var isBusy: Bool { launcher?.isResolving ?? false }

    func body(content: Content) -> some View {
        let sourceID = "continue/\(zoomScope)/\(preview.identity)"
        let isLoading = launcher?.isLoading(itemID) ?? false
        Button {
            guard !isBusy else { return }
            guard let launcher else {
                Haptics.tap()
                return openTitle(sourceID: sourceID)
            }
            // A swipe that ends on the card starts nothing, as on an episode's card.
            guard !SwipeRecord.latest.isSwipe(at: ContinuousClock.now) else { return }
            Haptics.tap()
            Task {
                if await launcher.open(itemID: itemID, request: request, preview: preview, sourceID: sourceID) == .openTitle {
                    openTitle(sourceID: sourceID)
                }
            }
        } label: {
            content
                // While this card's streams load, the ring an episode's card shows, over this card only.
                .overlay {
                    if isLoading {
                        ZStack {
                            Color.black.opacity(0.35)
                            Spinner()
                                .controlSize(.large)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: CardAspect.wide.cornerRadius, style: .continuous))
                        .transition(.opacity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Loading streams")
                    }
                }
                .animation(.smooth(duration: 0.25), value: isLoading)
                .zoomSource(id: sourceID, in: zoomNamespace, cornerRadius: CardAspect.wide.cornerRadius)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableCardStyle())
        .allowsHitTesting(!isBusy)
        // The hold is the system context menu: a custom long-press gesture here blocked the row's horizontal scroll.
        // No custom preview: the system snapshots the card itself (its artwork, bounds and clipping), and this shape gives the
        // menu the card's corner radius.
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .contextMenu {
            Button("Open title", systemImage: "info.circle") {
                Haptics.scrollSnap()
                router.open(.home)
                router.homePath.append(TitleDestination(preview: preview, sourceID: sourceID))
            }
            Button("Mark as Watched", systemImage: "checkmark.circle") {
                Haptics.tap()
                onMarkWatched()
            }
            Button("Remove from Continue Watching", systemImage: "minus.circle", role: .destructive) {
                Haptics.tap()
                onRemove()
            }
        }
        // The menu's "Open title" opens this title's page, so its artwork is looked up while the card is on screen.
        .prewarmsHeroArtwork(preview)
    }

    /// The title's page, with the streams of the item this card resumes.
    private func openTitle(sourceID: String) {
        router.open(.home)
        router.homePath.append(TitleDestination(preview: preview, sourceID: sourceID, streams: request))
    }
}

/// The text block at a landscape card's bottom: the shared fade, then `content` in white at the card's padding, `width` wide. It is
/// decoration: taps pass through and VoiceOver skips it.
struct CardCaption<Content: View>: View {
    let width: CGFloat
    /// Extra room between the content and the card's edges, for a card whose corners are rounder than usual.
    let inset: CGFloat
    let content: Content

    init(width: CGFloat, inset: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.width = width
        self.inset = inset
        self.content = content()
    }

    var body: some View {
        BottomFade(length: 0.70)
            .overlay(alignment: .bottomLeading) {
                content
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Spacing.s + inset)
                    .padding(.vertical, Theme.Spacing.s + inset)
                    .frame(width: width, alignment: .leading)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Shared playback styling. Unknown runtime leaves the time label out; unwatched and completed artwork has no playback overlay.
struct PlaybackProgressOverlay: View {
    let fraction: Double
    var duration: TimeInterval?
    var episode: String?
    let width: CGFloat
    /// Extra room between the line and the card's edges (see `CardCaption`).
    var inset: CGFloat = 0

    private var hasProgress: Bool { fraction.isFinite && fraction > 0 && fraction < 1 }

    var remainingTime: String? {
        guard hasProgress, let duration, duration.isFinite, duration > 0 else { return nil }
        let minutes = ((duration * (1 - fraction)).rounded() / 60).rounded(.up)
        return "\(minutes.formatted(.number.precision(.fractionLength(0))))m"
    }

    var body: some View {
        if hasProgress {
            CardCaption(width: width, inset: inset) {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Capsule()
                        .fill(.white.opacity(0.32))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white).scaleEffect(x: fraction, y: 1, anchor: .leading)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 3)
                    if let remainingTime {
                        Text(remainingTime)
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .fixedSize()
                    }
                    if let episode, !episode.isEmpty {
                        Text(episode)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.black)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.horizontal, Theme.Spacing.xs)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.92), in: Capsule())
                    }
                }
            }
        }
    }
}
#endif
