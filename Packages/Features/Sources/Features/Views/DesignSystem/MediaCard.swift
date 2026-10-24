#if canImport(UIKit)
import SwiftUI
import StremioKit

/// The shape of a card's artwork. `ratio` is width / height.
enum CardAspect: String, CaseIterable, Sendable {
    case poster, wide, square

    var ratio: CGFloat {
        switch self {
        case .poster: 2.0 / 3.0
        case .wide: 16.0 / 9.0
        case .square: 1
        }
    }

    /// Posters and square artwork use the poster radius, wide artwork the card radius.
    var cornerRadius: CGFloat {
        self == .wide ? Theme.Radius.card : Theme.Radius.poster
    }

    /// Whether a card of this shape carries its name underneath by default. Posters do not: the art carries the title, as in the
    /// TV app's poster shelves. Landscape and square cards do.
    var showsCaptionByDefault: Bool {
        self != .poster
    }
}

/// How big a card is within its aspect: a scale of the layout's base width (`LayoutMetrics.posterWidth` and friends), so
/// `.medium` is the TV app's own size on every platform.
enum CardSize: String, CaseIterable, Sendable {
    case small, medium, large

    var scale: CGFloat {
        switch self {
        case .small: 0.82
        case .medium: 1
        case .large: 1.22
        }
    }

    /// The card's width in points. Without `metrics` the phone layout's numbers.
    func width(for aspect: CardAspect, metrics: LayoutMetrics = .compact) -> CGFloat {
        let base: CGFloat = switch aspect {
        case .poster: metrics.posterWidth
        case .wide: metrics.wideCardWidth
        case .square: metrics.squareWidth
        }
        return (base * scale).rounded()
    }
}

/// One title: artwork with continuous rounded corners and, for landscape and square cards, its name and a grey line underneath.
/// Poster and square cards show `item.poster`; wide cards show `item.background`, falling back to the poster.
///
/// The card is `width` wide, or `size`'s width when `width` is nil. `stretched()` lets a grid give it a column's width instead.
/// `showsTitle` nil means the aspect's default (no caption under a poster, a caption under wide and square cards); pass a Bool to
/// force either. With `showsRating`, posters carry the IMDb and Letterboxd ratings from the environment's `PosterRatingsStore`.
/// With `usesBetterPosters`, a poster takes its picture from the BetterPosters addon, which carries the IMDb rating itself; the app's own
/// rating is drawn only when the usual poster stands in, and while a BetterPosters picture loads over it.
struct MediaCard: View {
    let item: MetaPreview
    let aspect: CardAspect
    let size: CardSize
    let showsTitle: Bool?
    let showsRating: Bool
    let width: CGFloat?
    let subtitle: String?
    let usesBetterPosters: Bool
    private var stretches = false
    private var zoomID: String?
    /// True while a held poster's streams load: a spinner over the artwork, as on an episode's card.
    private var isLoadingStreams = false
    /// True while the picture on show is the usual poster, which stands in for a BetterPosters picture that has not loaded (or did not).
    @State private var posterFellBack = false
    /// Mac: TMDb's backdrop with no words on it for this title, once it has been looked up. A landscape poster shows it in place of the
    /// addon's own, which often carries the title in some language under the logo the card draws.
    @State private var textlessBackdrop: URL?
    /// Optional, as the rating badges read it: a screen without the store keeps the addon's picture.
    @Environment(PosterRatingsStore.self) private var ratingsStore: PosterRatingsStore?
    @Environment(\.zoomNamespace) private var zoomNamespace
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.displayScale) private var displayScale
    @Environment(\.isLandscape) private var isLandscape

    init(item: MetaPreview, aspect: CardAspect = .poster, size: CardSize = .medium, showsTitle: Bool? = nil, showsRating: Bool = true,
         width: CGFloat? = nil, subtitle: String? = nil, usesBetterPosters: Bool = false) {
        self.item = item
        self.aspect = aspect
        self.size = size
        self.showsTitle = showsTitle
        self.showsRating = showsRating
        self.width = width
        self.subtitle = subtitle
        self.usesBetterPosters = usesBetterPosters
    }

    var body: some View {
        let fixed = resolvedWidth
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            artwork
            if showsCaption { captions }
        }
        // The caption is laid out inside the artwork's width and never widens the card: it is cut off instead.
        .frame(minWidth: stretches ? 0 : fixed, idealWidth: fixed, maxWidth: stretches ? .infinity : fixed, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenName)
        .accessibilityIdentifier("poster.\(item.id)")
    }

    /// The card takes whatever width it is offered rather than its fixed width. Only a grid column offers a real width; a row does not.
    func stretched() -> MediaCard {
        var copy = self
        copy.stretches = true
        return copy
    }

    /// Spins over the artwork while the card's streams load (see `PosterPlayLauncher`).
    func loadingStreams(_ loading: Bool) -> MediaCard {
        var copy = self
        copy.isLoadingStreams = loading
        return copy
    }

    /// Makes the artwork the place a pushed screen zooms out of (see `TitleDestination`).
    func zoomSource(_ id: String) -> MediaCard {
        var copy = self
        copy.zoomID = id
        return copy
    }

    private var resolvedWidth: CGFloat {
        Self.resolvedWidth(width: width, aspect: aspect, size: size, metrics: metrics, isLandscape: isLandscape)
    }

    private static func resolvedWidth(width: CGFloat?, aspect: CardAspect, size: CardSize, metrics: LayoutMetrics, isLandscape: Bool) -> CGFloat {
        width ?? (isLandscape && aspect == .poster
            ? (metrics.landscapePosterWidth * size.scale).rounded()
            : size.width(for: aspect, metrics: metrics))
    }

    /// The pictures a card for `item` asks `ImagePipeline` for, with the URLs and pixel sizes it uses. The card draws from this, and so does
    /// the grid's artwork buffer, so what the buffer loads is exactly what the card finds in the cache. A landscape poster also shows the
    /// title's logo. A poster that uses Better Posters asks for its BetterPosters picture, which the card shows first.
    static func artworkRequests(for item: MetaPreview, aspect: CardAspect, size: CardSize = .medium, width: CGFloat? = nil,
                                metrics: LayoutMetrics, isLandscape: Bool, displayScale: CGFloat,
                                usesBetterPosters: Bool = false) -> [ArtworkPrefetcher.Request] {
        let landscape = isLandscape && aspect == .poster
        let fixed = resolvedWidth(width: width, aspect: aspect, size: size, metrics: metrics, isLandscape: isLandscape)
        let pixels = pixelSize(width: fixed, artwork: landscape ? .wide : aspect, displayScale: displayScale)
        var requests: [ArtworkPrefetcher.Request] = []
        if landscape {
            if let url = landscapeArtworkURL(for: item) { requests.append(.init(url: url, maxPixelSize: pixels)) }
            if let logo = landscapeLogoURL(for: item) { requests.append(.init(url: logo, maxPixelSize: logoPixelSize)) }
        } else if let url = betterPosterURL(for: item, aspect: aspect, usesBetterPosters: usesBetterPosters)
                    ?? artworkURL(for: item, aspect: aspect) {
            requests.append(.init(url: url, maxPixelSize: pixels))
        }
        return requests
    }

    /// The BetterPosters picture a card of this shape shows first: only for a poster that uses the addon, and only for a title the addon
    /// has an id for (see `BetterPosters.posterURL`). Nil otherwise.
    private static func betterPosterURL(for item: MetaPreview, aspect: CardAspect, usesBetterPosters: Bool) -> URL? {
        guard usesBetterPosters, aspect == .poster else { return nil }
        return BetterPosters.posterURL(id: item.id, type: item.type)
    }

    /// Decoded no larger than the card is drawn, so a long shelf stays light in memory.
    private static func pixelSize(width: CGFloat, artwork: CardAspect, displayScale: CGFloat) -> CGFloat {
        min((max(width, width / artwork.ratio) * displayScale).rounded(.up), 1200)
    }

    /// The size `LandscapeArtwork` decodes its logo at.
    private static let logoPixelSize: CGFloat = 400

    private static func landscapeArtworkURL(for item: MetaPreview) -> URL? {
        PosterQuality.landscape(item.background) ?? MetahubArtwork.background(imdbID: item.id) ?? PosterQuality.poster(for: item)
    }

    private static func landscapeLogoURL(for item: MetaPreview) -> URL? { item.logo ?? MetahubArtwork.logo(imdbID: item.id) }

    private static func artworkURL(for item: MetaPreview, aspect: CardAspect) -> URL? {
        switch aspect {
        case .wide: PosterQuality.landscape(item.background) ?? PosterQuality.poster(for: item)
        case .poster, .square: PosterQuality.poster(for: item)
        }
    }

    private var usesLandscapeArtwork: Bool { isLandscape && aspect == .poster }

    private var artworkAspect: CardAspect { usesLandscapeArtwork ? .wide : aspect }

    private var showsCaption: Bool {
        !usesLandscapeArtwork && (showsTitle ?? aspect.showsCaptionByDefault)
    }

    /// The BetterPosters picture this card shows first, or nil when it shows the usual artwork.
    private var betterPosterURL: URL? {
        Self.betterPosterURL(for: item, aspect: artworkAspect, usesBetterPosters: usesBetterPosters)
    }

    private var artwork: some View {
        artworkSpace
            .overlay {
                if usesLandscapeArtwork {
                    LandscapeArtwork(title: item.name, artwork: textlessBackdrop ?? Self.landscapeArtworkURL(for: item),
                                     logo: Self.landscapeLogoURL(for: item), maxPixelSize: pixelSize)
                } else {
                    // One picture view whether or not the card uses BetterPosters, so turning the setting on or off keeps the picture on show
                    // until the other one has loaded: the usual poster stays while the BetterPosters picture loads, and no placeholder shows.
                    ArtworkImage(url: betterPosterURL ?? artworkURL, title: item.name, maxPixelSize: pixelSize,
                                 fallbackURL: betterPosterURL == nil ? nil : artworkURL, usesFallback: $posterFellBack,
                                 keepsPictureOnShow: aspect == .poster)
                }
            }
            .overlay(alignment: .bottom) {
                if showsRating && (aspect != .wide || isLandscape) && (betterPosterURL == nil || posterFellBack) {
                    PosterRatingsOverlay(item: item, isLandscape: isLandscape)
                }
            }
            .overlay {
                if isLoadingStreams {
                    ZStack {
                        Color.black.opacity(0.35)
                        Spinner()
                            .controlSize(.large)
                    }
                    .transition(.opacity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Loading streams")
                    .accessibilityIdentifier("poster.loadingStreams")
                }
            }
            .animation(.smooth(duration: 0.25), value: isLoadingStreams)
            .mediaArtwork(cornerRadius: artworkAspect.cornerRadius)
            .zoomSource(id: zoomID ?? "", in: zoomID == nil ? nil : zoomNamespace)
            #if targetEnvironment(macCatalyst)
            .task(id: "\(item.identity)|\(usesLandscapeArtwork)") { await findTextlessBackdrop() }
            #endif
            // The title's Play colour is read from its poster while the card is on show, so its page has the colour on the first frame.
            .task(id: item.identity) {
                await PlayColourStore.shared.read(identity: item.identity, pictures: PlayColourStore.pictures(for: item),
                                                  logos: PlayColourStore.logos(for: item))
            }
    }

    #if targetEnvironment(macCatalyst)
    /// Mac: looks up the title's wordless backdrop for a landscape poster. A title already looked up this session answers at once; any other
    /// waits until the card has been on screen for a moment and takes its turn among the lookups, as a hero prewarm does.
    private func findTextlessBackdrop() async {
        guard usesLandscapeArtwork, let ratingsStore, ratingsStore.canLookUpHeroArtwork else {
            textlessBackdrop = nil
            return
        }
        if let known = ratingsStore.cachedHeroArtwork(for: item) {
            textlessBackdrop = Self.cardSized(known.textlessBackdrop)
            return
        }
        textlessBackdrop = nil
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        await ratingsStore.prewarmHeroArtwork(for: item)
        guard !Task.isCancelled else { return }
        textlessBackdrop = Self.cardSized(ratingsStore.cachedHeroArtwork(for: item)?.textlessBackdrop)
    }

    /// TMDb's original-size picture at the size a card needs.
    private static func cardSized(_ url: URL?) -> URL? {
        guard let url, url.host == "image.tmdb.org" else { return url }
        return URL(string: url.absoluteString.replacingOccurrences(of: "/t/p/original/", with: "/t/p/w780/")) ?? url
    }
    #endif

    /// The artwork's box. A fixed card already knows its width, so its height is set outright: an aspect-ratio box would take
    /// its height from whatever the enclosing row proposes, and cards after the first in a row came out squeezed. Only a grid
    /// column stretches, and it offers a real width, so the ratio can work there.
    @ViewBuilder
    private var artworkSpace: some View {
        if stretches {
            Color.clear.aspectRatio(artworkAspect.ratio, contentMode: .fit)
        } else {
            let fixed = resolvedWidth
            Color.clear.frame(width: fixed, height: fixed / artworkAspect.ratio)
        }
    }

    private var pixelSize: CGFloat {
        Self.pixelSize(width: resolvedWidth, artwork: artworkAspect, displayScale: displayScale)
    }

    /// One title line and one grey line, always: cards of one kind share a height (a row takes its height from its first card, see
    /// `MediaRow`), and the grey line sits right under the name. A long name is cut off rather than wrapped, as in the TV app.
    private var captions: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(subtitleLine)
                .font(Theme.Typography.cardSubtitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Drama · 2008": a blank line when there is nothing to say, so the grey lines of a row still line up.
    private var subtitleLine: String {
        if let subtitle, !subtitle.isEmpty { return subtitle }
        let line = [item.genres.first, item.releaseInfo].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return line.isEmpty ? " " : line
    }

    private var artworkURL: URL? { Self.artworkURL(for: item, aspect: aspect) }

    private var spokenName: String {
        [item.name, item.releaseInfo].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// `MediaCard` that opens the title: `NavigationLink(value: item)` with `PressableCardStyle`.
struct MediaCardLink: View {
    let item: MetaPreview
    let aspect: CardAspect
    let size: CardSize
    let showsTitle: Bool?
    let showsRating: Bool
    let width: CGFloat?
    let subtitle: String?
    let usesBetterPosters: Bool
    private var stretches = false
    @Environment(\.zoomScope) private var zoomScope
    @Environment(TitleActions.self) private var actions: TitleActions?
    @Environment(PosterPlayLauncher.self) private var posterPlay: PosterPlayLauncher?

    init(item: MetaPreview, aspect: CardAspect = .poster, size: CardSize = .medium, showsTitle: Bool? = nil, showsRating: Bool = true,
         width: CGFloat? = nil, subtitle: String? = nil, usesBetterPosters: Bool = false) {
        self.item = item
        self.aspect = aspect
        self.size = size
        self.showsTitle = showsTitle
        self.showsRating = showsRating
        self.width = width
        self.subtitle = subtitle
        self.usesBetterPosters = usesBetterPosters
    }

    var body: some View {
        // The row's scope makes the id unique on screen, so the title's screen zooms out of this card and not a twin in another row.
        let sourceID = "\(zoomScope)/\(item.identity)"
        let card = MediaCard(item: item, aspect: aspect, size: size, showsTitle: showsTitle, showsRating: showsRating, width: width,
                             subtitle: subtitle, usesBetterPosters: usesBetterPosters)
            .zoomSource(sourceID)
            .loadingStreams(posterPlay?.isLoading(item) == true)
        NavigationLink(value: TitleDestination(preview: item, sourceID: sourceID)) {
            stretches ? card.stretched() : card
        }
        .buttonStyle(PressableCardStyle())
        .pointerFeedback()
        // The light tap of opening a title, but not for the lift that ends a hold, which has given its own.
        .simultaneousGesture(TapGesture().onEnded {
            if posterPlay?.isHeldPress(item) != true { Haptics.tap() }
        })
        .prewarmsHeroArtwork(item)
        .help(item.name)
        // Holding a poster for a second plays it, on iPhone and Mac. On iPhone that takes the hold its menu had; the menu's actions are on
        // the title's page. The Mac keeps the menu, which a right click opens.
        .holdsToPlay(item)
        #if targetEnvironment(macCatalyst)
        .contextMenu {
            if let actions {
                Button(actions.isSaved(item) ? "Remove from Library" : "Add to Library", systemImage: "bookmark") {
                    Task { await actions.toggleSaved(item) }
                }
                if item.type == "movie" {
                    Button(actions.isWatched(item) ? "Mark as Unwatched" : "Mark as Watched", systemImage: "checkmark.circle") {
                        Task { await actions.setWatched(!actions.isWatched(item), for: item) }
                    }
                } else if item.type == "series" {
                    Button("Mark All Episodes as Watched", systemImage: "checkmark.circle") {
                        Task { await actions.setSeriesWatched(true, for: item) }
                    }
                    if actions.hasWatchedEpisodes(item) {
                        Button("Mark All Episodes as Unwatched", systemImage: "xmark.circle") {
                            Task { await actions.setSeriesWatched(false, for: item) }
                        }
                    }
                }
                if item.id.hasPrefix("tt"), item.id.dropFirst(2).allSatisfy(\.isNumber),
                   let url = URL(string: "https://www.imdb.com/title/\(item.id)/") {
                    ShareLink(item: url)
                }
            }
        }
        #endif
    }

    /// The link takes the width it is offered, as a grid column does. See `MediaCard.stretched()`.
    func stretched() -> MediaCardLink {
        var copy = self
        copy.stretches = true
        return copy
    }
}

extension View {
    /// Looks up a card's title in TMDb once the card has been on screen for a moment, so its page opens with the picture and logo already known.
    /// Only the lookup runs (no picture), and a card that scrolls away before the moment is up asks nothing. Does nothing without TMDb.
    func prewarmsHeroArtwork(_ item: MetaPreview) -> some View {
        modifier(PrewarmHeroArtworkModifier(item: item))
    }
}

private struct PrewarmHeroArtworkModifier: ViewModifier {
    let item: MetaPreview
    /// Optional, as the rating badges read it: a screen without the store simply does not prewarm.
    @Environment(PosterRatingsStore.self) private var ratings: PosterRatingsStore?

    func body(content: Content) -> some View {
        let item = self.item
        let ratings = self.ratings
        return content.task(id: item.identity, priority: .low) {
            // Without TMDb there is nothing to look up, so the card starts no wait at all.
            guard let ratings, ratings.canLookUpHeroArtwork else { return }
            // `.task` is cancelled when the card scrolls away, which ends the wait before any lookup starts.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await ratings.prewarmHeroArtwork(for: item)
        }
    }
}

/// How cards answer a touch or a pointer: pressed, they dim and shrink a little with a quick spring; under a pointer (Mac, iPad
/// trackpad) they lift slightly and highlight. Reduce Motion keeps the card still.
struct PressableCardStyle: ButtonStyle {
    /// False keeps the card its own size under a pointer and only highlights it: a card as wide as its column (a stream) would grow past
    /// the column's edges.
    var lifts = true
    /// False leaves out the system's hover highlight, so the card's own highlight is its one hover effect (a stream's card on a Mac).
    var addsSystemHighlight = true

    func makeBody(configuration: Configuration) -> some View {
        PressableCardLabel(configuration: configuration, lifts: lifts, addsSystemHighlight: addsSystemHighlight)
            .pointerFeedback(addsSystemHighlight)
    }
}

/// A view of its own because the hover state needs somewhere to live.
private struct PressableCardLabel: View {
    let configuration: ButtonStyleConfiguration
    let lifts: Bool
    let addsSystemHighlight: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.75), value: configuration.isPressed)
            .pointerInteraction(lifts: lifts && !configuration.isPressed, systemHighlight: addsSystemHighlight)
    }
}
#endif
