#if canImport(UIKit)
import StremioKit
import SwiftUI
import UIKit

/// A row drawn in one of Blusion's own layouts (`RowLayout`) once its items have loaded: the row's header, then the layout. The row's
/// menu is on the header and the space around the cards; on the Mac it covers the whole row, and a card's own menu wins over it.
struct LayoutRow: View {
    let layout: RowLayout
    let title: String
    let hideTitle: Bool
    let items: [MetaPreview]
    let presentation: WidgetPresentation
    let onSeeAll: () -> Void
    let menu: AnyView
    @Environment(\.layoutMetrics) private var metrics
    @State private var zoomScope = UUID().uuidString

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.headerSpacing) {
            if !hideTitle {
                SectionHeader(title, onSeeAll: onSeeAll)
                    .contextMenu { menu }
                    .padding(.horizontal, metrics.pageMargin)
            }
            layoutBody
                .environment(\.layoutMetrics, metrics.layoutCards(presentation.cardStyle.cardSize))
                .background {
                    Color.clear
                        .contentShape(.rect)
                        .contextMenu { menu }
                }
        }
        .environment(\.zoomScope, zoomScope)
        #if targetEnvironment(macCatalyst)
        .contextMenu { menu }
        #endif
    }

    @ViewBuilder
    private var layoutBody: some View {
        switch layout {
        case .mosaic: MosaicLayout(items: items, presentation: presentation)
        case .flow: FlowLayoutRow(items: items, showsRating: presentation.showsRatings)
        case .wall: WallLayout(items: items)
        case .parallax: ParallaxLayout(items: items, showsRating: presentation.showsRatings)
        case .spines: SpinesLayout(items: items, showsRating: presentation.showsRatings)
        case .slots: SlotsLayout(items: items)
        case .deck: DeckLayout(items: items, showsRating: presentation.showsRatings)
        case .snapshots: SnapshotsLayout(items: items)
        case .videoStore: VideoStoreLayout(items: items, showsRating: presentation.showsRatings)
        }
    }

    /// The height `layout` takes under its header, for the placeholder that stands in for it. Flow's is its posters' alone: its caption is
    /// text, whose room the placeholder keeps with the caption's own lines.
    static func height(of layout: RowLayout, metrics: LayoutMetrics, containerWidth: CGFloat) -> CGFloat {
        switch layout {
        case .mosaic: MosaicLayout.height(metrics)
        case .flow: FlowLayoutRow.height(metrics)
        case .wall: WallLayout.height(metrics)
        case .parallax: ParallaxLayout.height(metrics, containerWidth: containerWidth)
        case .spines: SpinesLayout.height(metrics)
        case .slots: SlotsLayout.height(metrics, containerWidth: containerWidth)
        case .deck: DeckLayout.height(metrics)
        case .snapshots: SnapshotsLayout.height(metrics)
        case .videoStore: VideoStoreLayout.height(metrics)
        }
    }
}

/// The stand-in for a layout row while its items load: its header over a shimmering panel of the layout's height.
struct LayoutRowPlaceholder: View {
    let layout: RowLayout
    /// Nil when the row hides its title.
    let title: String?
    /// The widget's card size, which the layout's height follows.
    var size: CardSize = .medium
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.heroContainerWidth) private var containerWidth

    var body: some View {
        let cards = metrics.layoutCards(size)
        VStack(alignment: .leading, spacing: metrics.headerSpacing) {
            if let title {
                SectionHeader(title).padding(.horizontal, metrics.pageMargin)
            }
            VStack(spacing: layout == .flow ? Theme.Spacing.s : Theme.Spacing.m) {
                Color.clear.frame(height: LayoutRow.height(of: layout, metrics: cards, containerWidth: containerWidth))
                if layout == .flow { FlowLayoutRow.captionLines(name: " ", details: " ").hidden() }
            }
            // The slot machine's cabinet stands in the middle of the row at its own width.
            .frame(width: layout == .slots ? SlotsLayout.width(cards, containerWidth: containerWidth) : nil)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.surface * metrics.cornerScale(for: .artwork), style: .continuous)
                    .fill(Theme.surfaceStrong)
            }
            .shimmering()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, metrics.pageMargin)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

// MARK: - Shared pieces

extension LayoutMetrics {
    /// These metrics for a layout row whose widget asks for `size` cards, as a shelf's cards follow it: the poster width the layouts are
    /// drawn from, and the card scale Parallax's cards follow, scaled by it.
    fileprivate func layoutCards(_ size: CardSize) -> LayoutMetrics {
        var metrics = self
        metrics.posterWidth = (posterWidth * size.scale).rounded()
        metrics.cardScale *= size.scale
        return metrics
    }
}

/// "Drama · 2008 · ★ 8": the first genre, the year and, when shown, the IMDb rating.
func layoutDetailLine(_ item: MetaPreview, showsRating: Bool) -> String {
    let rating = showsRating ? item.imdbRating.map { "★ \(ScoreText.wholeScore($0))" } : nil
    return [item.genres.first, item.releaseInfo, rating].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
}

/// A title's poster filling `width` by `height`, decoded at the size it is drawn. Only its own frame takes touches.
struct LayoutPoster: View {
    let item: MetaPreview
    let width: CGFloat
    let height: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Color.clear
            .frame(width: width, height: height)
            .overlay {
                ArtworkImage(url: PosterQuality.poster(for: item), title: item.name,
                             maxPixelSize: min((max(width, height) * displayScale).rounded(.up), 1200), keepsPictureOnShow: true)
            }
            .clipped()
            .contentShape(Rectangle())
    }
}

/// A picture that opens its title, for the layouts' own cards: the push, zoom, press, tap haptic, hover and Mac menu a shelf's card has.
/// `copy` tells apart the repeats of one title in a layout that shows it more than once, so each is its own zoom source. `prewarms` false
/// leaves out the title page's artwork lookup ahead of a tap, and with it the poster's watch on whether it is on screen, for a layout
/// that moves all its posters on every frame.
struct LayoutTitleLink<Label: View>: View {
    let item: MetaPreview
    var copy = ""
    var prewarms = true
    let cornerRadius: CGFloat
    @ViewBuilder let label: () -> Label
    @Environment(\.zoomScope) private var zoomScope
    @Environment(\.zoomNamespace) private var zoomNamespace
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        let sourceID = "\(zoomScope)/\(copy)\(item.identity)"
        let link = NavigationLink(value: TitleDestination(preview: item, sourceID: sourceID)) {
            label()
                .mediaArtwork(cornerRadius: cornerRadius)
                .zoomSource(id: sourceID, in: zoomNamespace, cornerRadius: cornerRadius * metrics.cornerScale(for: .artwork))
        }
        .buttonStyle(PressableCardStyle.poster)
        .titleTapHaptic()
        Group {
            if prewarms { link.prewarmsHeroArtwork(item) } else { link }
        }
        .help(item.name)
        .titleCardMenu(item)
        .accessibilityLabel(item.name)
    }
}

/// A title's logo in a `width` by `height` box, pinned to its bottom leading corner: the spotlight's logo (the catalog's, else TMDb's from
/// the spotlight's artwork lookup), loaded as the spotlight loads it, trimmed and made light when it is dark. Its name in bold when it has
/// none.
struct LayoutLogo: View {
    let item: MetaPreview
    let width: CGFloat
    let height: CGFloat
    @Environment(PosterRatingsStore.self) private var ratings: PosterRatingsStore?
    @State private var hero = HeroLoader()
    @State private var heroArtwork: TMDbArtwork?
    /// Set once the spotlight's artwork lookup has answered, so a title with no logo falls back to its name.
    @State private var artworkChecked = false

    private var logoURL: URL? { item.logo ?? heroArtwork?.logo }

    var body: some View {
        Group {
            switch hero.slot(url: logoURL, maxPixelSize: HeroLoader.logoPixelSize, lookupFinished: artworkChecked) {
            case .ready(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            case .pending:
                Color.clear
            case .none:
                Text(item.name)
                    .font(.title3.bold())
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(width: width, height: height, alignment: .bottomLeading)
        .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
        .task(id: item.identity) {
            // The catalog's own logo needs no lookup; otherwise the spotlight's artwork, known already when the title was prewarmed.
            guard item.logo == nil else { return }
            heroArtwork = ratings?.cachedHeroArtwork(for: item)
            if heroArtwork == nil { heroArtwork = await ratings?.heroArtwork(for: item) }
            guard !Task.isCancelled else { return }
            artworkChecked = true
        }
        .task(id: logoURL) {
            await hero.load(priority: .medium, picture: nil, pictureSize: 0, logo: logoURL, logoSize: HeroLoader.logoPixelSize)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Mosaic

/// `RowLayout.mosaic`: pages of five posters, one twice the size of the others, which sit in a square of four beside it. The large poster
/// changes sides from page to page, so the row reads as a mosaic rather than a grid.
private struct MosaicLayout: View {
    let items: [MetaPreview]
    let presentation: WidgetPresentation
    @Environment(\.layoutMetrics) private var metrics

    static func tileWidth(_ metrics: LayoutMetrics) -> CGFloat { (metrics.posterWidth * 0.72).rounded() }
    static func gap(_ metrics: LayoutMetrics) -> CGFloat { max(4, (metrics.cardSpacing * 0.67).rounded()) }
    /// Two small posters and the gap between them, which is also the large poster's height.
    static func height(_ metrics: LayoutMetrics) -> CGFloat { tileWidth(metrics) * 3 + gap(metrics) }

    var body: some View {
        let tile = Self.tileWidth(metrics)
        let gap = Self.gap(metrics)
        let pages = stride(from: 0, to: items.count, by: 5).map { Array(items[$0..<min($0 + 5, items.count)]) }
        ShelfScroll(margin: metrics.pageMargin, spacing: gap) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                MosaicPage(items: page, featureFirst: index.isMultiple(of: 2), tile: tile, feature: Self.height(metrics) / 1.5, gap: gap,
                           presentation: presentation)
                    .reportsShelfEdge(id: index)
            }
        }
        // A phone on its side draws posters as wide cards, which would break the mosaic's squares.
        .environment(\.isLandscape, false)
    }
}

private struct MosaicPage: View {
    let items: [MetaPreview]
    let featureFirst: Bool
    let tile: CGFloat
    let feature: CGFloat
    let gap: CGFloat
    let presentation: WidgetPresentation

    var body: some View {
        HStack(alignment: .top, spacing: gap) {
            if featureFirst { card(items[0], width: feature, isFeature: true) }
            if items.count > 1 { quartet }
            if !featureFirst { card(items[0], width: feature, isFeature: true) }
        }
    }

    private var quartet: some View {
        let rest = Array(items.dropFirst())
        return VStack(alignment: .leading, spacing: gap) {
            HStack(spacing: gap) {
                ForEach(rest.prefix(2), id: \.identity) { card($0, width: tile, isFeature: false) }
            }
            if rest.count > 2 {
                HStack(spacing: gap) {
                    ForEach(rest.dropFirst(2), id: \.identity) { card($0, width: tile, isFeature: false) }
                }
            }
        }
    }

    /// Ratings only on the large poster: the small ones are too narrow for the badges.
    private func card(_ item: MetaPreview, width: CGFloat, isFeature: Bool) -> some View {
        MediaCardLink(item: item, aspect: .poster, size: isFeature ? .large : .small, showsTitle: false,
                      showsRating: presentation.showsRatings && isFeature, width: width, usesBetterPosters: presentation.usesBetterPosters)
    }
}

// MARK: - Flow

/// `RowLayout.flow`: iPod: Cover Flow. The poster in the middle faces the viewer; the others stand turned towards it in two tight stacks, each
/// overlapping the next like records in a crate, every poster over its own reflection, with the middle one's name and details under them.
/// A poster to one side comes to the middle when tapped; the one in the middle opens its title.
private struct FlowLayoutRow: View {
    let items: [MetaPreview]
    let showsRating: Bool
    @State private var centredID: String?
    @State private var entryCache = EntryCache()
    @State private var motion = ScrollMotion()
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.heroContainerWidth) private var containerWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if targetEnvironment(macCatalyst)
    @State private var isHovering = false
    #endif

    /// Starts on the first title in the middle copy, so the last titles already stand in the stack to its left.
    init(items: [MetaPreview], showsRating: Bool) {
        self.items = items
        self.showsRating = showsRating
        _centredID = State(initialValue: items.first.map { Self.entryID(copy: Self.middleCopy(of: items.count), item: $0) })
    }

    /// The shelf repeated end to end so the row loops: the user scrolls through the copies, and each time the row comes to rest it is
    /// silently put back on the same poster in the middle copy. Each side of the middle copy holds at least `runway` posters, so even a
    /// run of hard flicks never reaches an end, however short the shelf. A single title is not repeated.
    private static let runway = 400
    private static func copies(of count: Int) -> Int { count > 1 ? 2 * ((runway + count - 1) / count) + 1 : 1 }
    private static func middleCopy(of count: Int) -> Int { copies(of: count) / 2 }
    private static func entryID(copy: Int, item: MetaPreview) -> String { "\(copy)/\(item.identity)" }
    private struct Entry: Identifiable {
        let id: String
        let item: MetaPreview
        let copy: Int
        let index: Int
    }
    private var entries: [Entry] { entryCache.entries(for: items, copies: Self.copies(of: items.count)) }

    /// The copies' entries, built again only when the titles change: the row redraws each time another poster comes to the middle.
    @MainActor
    private final class EntryCache {
        private var items: [MetaPreview]?
        private var entries: [Entry] = []

        func entries(for items: [MetaPreview], copies: Int) -> [Entry] {
            guard items != self.items else { return entries }
            self.items = items
            entries = (0..<copies).flatMap { copy in
                items.enumerated().map { Entry(id: FlowLayoutRow.entryID(copy: copy, item: $1), item: $1, copy: copy, index: $0) }
            }
            return entries
        }
    }
    private var middleCopy: Int { Self.middleCopy(of: items.count) }

    /// Whether the row is held or still moving, kept out of the view's state so a change of phase does not redraw the row.
    @MainActor
    private final class ScrollMotion {
        var isMoving = false
    }

    static func cardWidth(_ metrics: LayoutMetrics) -> CGFloat { (metrics.posterWidth * 1.2).rounded() }
    static func reflection(_ metrics: LayoutMetrics) -> CGFloat { (cardWidth(metrics) * 1.5 * 0.12).rounded() }
    /// The posters over their reflections, above the caption.
    static func height(_ metrics: LayoutMetrics) -> CGFloat {
        cardWidth(metrics) * 1.5 + FlowCard.reflectionGap + reflection(metrics)
    }

    private var current: String? { centredID ?? entries.first { $0.copy == middleCopy }?.id }
    /// The position of the middle poster among all the copies.
    private var currentPosition: Int { entries.firstIndex { $0.id == current } ?? 0 }
    /// The middle poster's place in the shelf.
    private var currentIndex: Int { entries.indices.contains(currentPosition) ? entries[currentPosition].index : 0 }

    var body: some View {
        let width = Self.cardWidth(metrics)
        let height = width * 1.5
        let reflection = Self.reflection(metrics)
        // Each poster takes only `step` of the scroll, the gap between two posters in a side stack, so a drag moves the stacks with the
        // finger. The first poster to each side stands `spread` from the middle, clear of the one facing the viewer.
        let step = (width * 0.2).rounded()
        let spread = width * 0.66
        // Turns and scales about the poster's own middle, not its reflection's.
        let anchor = UnitPoint(x: 0.5, y: height / 2 / (height + FlowCard.reflectionGap + reflection))
        // Worked out once for the whole row, not again for each poster.
        let current = self.current
        let currentPosition = self.currentPosition
        let reduceMotion = self.reduceMotion
        let count = items.count
        VStack(spacing: Theme.Spacing.s) {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(entries) { entry in
                        let position = entry.copy * count + entry.index
                        FlowCard(item: entry.item, width: width, height: height, reflection: reflection,
                                 isCentred: entry.id == current, showsRating: showsRating) {
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.38)) { centredID = entry.id }
                        }
                        // Another poster coming to the middle redraws only it and the one that leaves.
                        .equatable()
                        .visualEffect { content, proxy in
                            // How many steps the poster is from the middle, leftwards when negative; past one step it is in a stack.
                            let distance = proxy.bounds(of: .scrollView).map { proxy.size.width / 2 - $0.midX } ?? 0
                            let side = min(max(distance / step, -1), 1)
                            // Ease both ends of the turn so a cover joins and leaves its stack without a sudden change in speed.
                            let progress = abs(side)
                            let turn = side * progress * (3 - 2 * progress)
                            return content
                                .rotation3DEffect(.degrees(reduceMotion ? 0 : -Double(turn) * 68), axis: (x: 0, y: 1, z: 0), anchor: anchor, perspective: 0.35)
                                .scaleEffect(1 - abs(turn) * 0.16, anchor: anchor)
                                .offset(x: turn * (spread - step))
                                .brightness(-Double(abs(turn)) * 0.12)
                        }
                        .frame(width: step)
                        // The poster in the middle is drawn over its neighbours, and each one in a stack over the one behind it.
                        .zIndex(-Double(abs(position - currentPosition)))
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $centredID, anchor: .center)
            .scrollTargetBehavior(.viewAligned)
            .onScrollPhaseChange { _, phase in
                motion.isMoving = phase != .idle
                // Put back the moment the row is at rest, before a finger can take it again.
                if phase == .idle { recentre() }
            }
            .scrollIndicators(.hidden, axes: .horizontal)
            .contentMargins(.horizontal, max(metrics.pageMargin, (containerWidth - step) / 2), for: .scrollContent)
            .scrollClipDisabled()
            .frame(height: height + FlowCard.reflectionGap + reflection)
            #if targetEnvironment(macCatalyst)
            .overlay {
                if isHovering && items.count > 1 { arrows.frame(height: height).frame(maxHeight: .infinity, alignment: .top) }
            }
            #endif
            caption
        }
        .onChange(of: centredID) { old, new in
            guard old != nil, new != old else { return }
            let shelfIndex = { (id: String?) in entries.first { $0.id == id }?.index }
            if shelfIndex(old) != shelfIndex(new) { Haptics.play(.shelves) }
            // A tap or a chevron moves the row without a gesture: it is put back once that move has had time to finish.
            if !motion.isMoving { recentre(after: .milliseconds(600)) }
        }
        #if targetEnvironment(macCatalyst)
        .onHover { isHovering = $0 }
        #endif
    }

    /// When the row rests on a poster in another copy, puts it back on the same poster in the middle copy, without animation: every
    /// poster stands just where it was, so nothing on screen moves. Never while the row is held or still moving.
    private func recentre(after delay: Duration = .zero) {
        guard let id = centredID, let entry = entries.first(where: { $0.id == id }), entry.copy != middleCopy else { return }
        let target = Self.entryID(copy: middleCopy, item: entry.item)
        Task { @MainActor in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !motion.isMoving, centredID == id, entries.contains(where: { $0.id == target }) else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { centredID = target }
        }
    }

    /// Keep the selected title's information in a steady space while the covers move above it.
    private var caption: some View {
        let item = items.indices.contains(currentIndex) ? items[currentIndex] : nil
        let details = item.map {
            [layoutDetailLine($0, showsRating: showsRating), $0.runtime ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        } ?? " "
        return Self.captionLines(name: item?.name ?? " ", details: details,
                                 synopsis: item?.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, metrics.pageMargin)
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: item?.identity)
            .accessibilityElement(children: .combine)
            .accessibilityValue(items.isEmpty ? "" : "\(currentIndex + 1) of \(items.count)")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: move(by: 1)
                case .decrement: move(by: -1)
                @unknown default: break
                }
            }
    }

    /// The title and tagline share a row; the synopsis uses the full width beneath them.
    static func captionLines(name: String, details: String, synopsis: String = "") -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                Text(name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .layoutPriority(1)
                Text(details)
                    .font(Theme.Typography.metaLine)
                    .foregroundStyle(Theme.metaText)
                    .lineLimit(1, reservesSpace: true)
            }
            Text(synopsis)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .multilineTextAlignment(.leading)
    }

    private func move(by step: Int) {
        guard items.count > 1 else { return }
        let target = min(max(currentPosition + step, 0), entries.count - 1)
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.38)) { centredID = entries[target].id }
    }

    #if targetEnvironment(macCatalyst)
    /// Mac: a chevron at each side while the pointer is over the row, moving the next poster to the middle.
    private var arrows: some View {
        HStack {
            arrow(systemName: "chevron.left", label: "Previous title", step: -1, enabled: items.count > 1)
            Spacer()
            arrow(systemName: "chevron.right", label: "Next title", step: 1, enabled: items.count > 1)
        }
        .padding(.horizontal, Theme.Spacing.l)
    }

    private func arrow(systemName: String, label: String, step: Int, enabled: Bool) -> some View {
        Button {
            move(by: step)
        } label: {
            Image(systemName: systemName)
                .font(.headline.weight(.semibold))
                .frame(width: 40, height: 40)
                .buttonSurface(.regular, in: ScaledCapsule(scale: metrics.circularButtonScale(for: .actionButtons)))
                .contentShape(ScaledCapsule(scale: metrics.circularButtonScale(for: .actionButtons)))
        }
        .buttonStyle(.hoverPlain)
        .disabled(!enabled)
        // A hidden chevron must not take clicks meant for the posters beneath it.
        .allowsHitTesting(enabled)
        .opacity(enabled ? 1 : 0)
        .accessibilityLabel(label)
    }
    #endif
}

private struct FlowCard: View, Equatable {
    let item: MetaPreview
    let width: CGFloat
    let height: CGFloat
    let reflection: CGFloat
    let isCentred: Bool
    let showsRating: Bool
    let onCentre: () -> Void
    @Environment(AppRouter.self) private var router
    @Environment(\.zoomScope) private var zoomScope
    @Environment(\.zoomNamespace) private var zoomNamespace
    @Environment(\.layoutMetrics) private var metrics

    /// `onCentre` is left out: it only ever brings this poster to the middle.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.item == rhs.item && lhs.width == rhs.width && lhs.height == rhs.height && lhs.reflection == rhs.reflection
                && lhs.isCentred == rhs.isCentred && lhs.showsRating == rhs.showsRating
        }
    }

    /// The gap between a poster and its reflection.
    static let reflectionGap: CGFloat = 1

    private var sourceID: String { "\(zoomScope)/\(item.identity)" }

    var body: some View {
        let radius = Theme.Radius.poster
        let button = Button {
            if isCentred { openTitle() } else { onCentre() }
        } label: {
            LayoutPoster(item: item, width: width, height: height)
                .overlay(alignment: .bottom) {
                    if showsRating { PosterRatingsOverlay(item: item) }
                }
                .mediaArtwork(cornerRadius: radius)
                .zoomSource(id: sourceID, in: zoomNamespace, cornerRadius: radius * metrics.cornerScale(for: .artwork))
        }
        .buttonStyle(PressableCardStyle.poster)
        VStack(spacing: Self.reflectionGap) {
            // Only the selected cover needs a visibility observer and an advance lookup for its title page.
            Group {
                if isCentred { button.prewarmsHeroArtwork(item) } else { button }
            }
            .help(item.name)
            .titleCardMenu(item)
            .accessibilityLabel(item.name)
            // VoiceOver opens the title straight away, wherever the poster is.
            .accessibilityAction(.default) { openTitle() }
            // The reflection: the poster's foot upside down, fading into the page.
            LayoutPoster(item: item, width: width, height: height)
                .mediaArtwork(cornerRadius: radius)
                .scaleEffect(x: 1, y: -1)
                .frame(width: width, height: reflection, alignment: .top)
                .clipped()
                .mask {
                    LinearGradient(stops: [.init(color: .white.opacity(0.34), location: 0),
                                           .init(color: .white.opacity(0.08), location: 0.65),
                                           .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                }
                // Drawn once into a single picture, so the stacks' turning on every frame of a scroll does not mask it again.
                .drawingGroup()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func openTitle() {
        Haptics.play(.titles)
        router.homePath.append(TitleDestination(preview: item, sourceID: sourceID))
    }
}

// MARK: - Wall

/// `RowLayout.wall`: a tilted wall of small posters, three rows tall, in rows that drift past in opposite directions at different speeds,
/// in a rounded panel with a soft vignette. Each poster opens its title, and each row can be dragged along by itself; a flick glides on and
/// slows to a stop as a scrolled list does, a row caught while it glides stops under the finger, and the row drifts again from wherever it
/// is let go. The wall stands still with Reduce Motion, while its row is off screen or the app is in the background,
/// while a row is held and, on the Mac, while the pointer is over it, so a poster can be clicked.
private struct WallLayout: View {
    let items: [MetaPreview]
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.heroContainerWidth) private var containerWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.loadsVisibleArtwork) private var sectionIsVisible
    @Environment(\.scenePhase) private var scenePhase
    @State private var clock = DriftClock()
    @State private var stripCache = WallStripCache()
    @State private var isHovering = false
    /// How far each row has been moved by hand, by its id, on top of its drift.
    @State private var shifts: [Int: CGFloat] = [:]
    /// Each flicked row's glide, by its id, worked out from the wall's own time.
    @State private var glides: [Int: WallGlide] = [:]
    /// The row being dragged, and how far along it the finger has gone.
    @State private var drag: (row: Int, distance: CGFloat)?

    static let tilt: Double = -8
    static func posterWidth(_ metrics: LayoutMetrics) -> CGFloat { (metrics.posterWidth * 0.5).rounded() }
    static func gap(_ metrics: LayoutMetrics) -> CGFloat { max(4, (metrics.cardSpacing * 0.67).rounded()) }
    static func height(_ metrics: LayoutMetrics) -> CGFloat { (posterWidth(metrics) * 1.5 * 3).rounded() }

    var body: some View {
        let width = Self.posterWidth(metrics)
        let posterHeight = width * 1.5
        let gap = Self.gap(metrics)
        let panelHeight = Self.height(metrics)
        let panelWidth = max(1, containerWidth - metrics.pageMargin * 2)
        let angle = CGFloat(abs(Self.tilt) * .pi / 180)
        // Enough rows, and enough wall past each side, that the tilted wall still covers the panel's corners.
        let needed: CGFloat = (panelHeight * cos(angle) + panelWidth * sin(angle)) / (posterHeight + gap)
        let rows = max(3, Int(needed.rounded(.up)) + 1)
        let overhang: CGFloat = (panelHeight * sin(angle)).rounded(.up) + width
        let strips = stripCache.strips(for: items, rows: rows, width: width, gap: gap, span: panelWidth + overhang * 2)
        // On the Mac the wall stops drifting under the pointer, but a row flicked there still glides to a stop.
        let gliding = glides.values.contains { $0.isMoving(at: clock.glideTime) }
        let paused = reduceMotion || !sectionIsVisible || scenePhase != .active || (isHovering && !gliding) || drag != nil
        let radius = HeroBanner.cornerRadius * metrics.cornerScale(for: .artwork)
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: paused)) { context in
            let time = clock.advance(to: context.date, running: !paused, drifting: !isHovering)
            let glideTime = clock.glideTime
            VStack(alignment: .leading, spacing: gap) {
                ForEach(strips) { strip in
                    WallStripView(strip: strip, width: width, height: posterHeight, gap: gap)
                        .equatable()
                        .offset(x: strip.offset(at: time, shift: shift(of: strip.id, at: glideTime)) - overhang)
                        .gesture(WallRowPan { distance in
                            hold(strip.id, distance: distance)
                        } ended: { distance, velocity in
                            release(strip.id, distance: distance, velocity: velocity)
                        })
                }
            }
            .frame(width: panelWidth, alignment: .leading)
        }
        .rotationEffect(.degrees(Self.tilt))
        .frame(width: panelWidth, height: panelHeight)
        .overlay {
            RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: panelHeight * 0.3,
                           endRadius: max(panelWidth, panelHeight) * 0.75)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        // The rows run past the panel; only what shows inside it takes touches.
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.artworkBorder, lineWidth: 0.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, metrics.pageMargin)
        #if targetEnvironment(macCatalyst)
        .onHover { isHovering = $0 }
        #endif
    }

    /// How far `row` has been moved by hand at `time`: the drags before, the one under way and the glide of the last flick.
    private func shift(of row: Int, at time: TimeInterval) -> CGFloat {
        let held = drag?.row == row ? drag?.distance ?? 0 : 0
        return shifts[row, default: 0] + held + (glides[row]?.distance(at: time) ?? 0)
    }

    /// The finger on `row`. A row still gliding stops where it stands, so it stays under the finger instead of jumping to where its glide
    /// would have ended.
    private func hold(_ row: Int, distance: CGFloat) {
        if drag?.row != row, let glide = glides.removeValue(forKey: row) {
            shifts[row, default: 0] += glide.distance(at: clock.glideTime)
        }
        drag = (row, distance)
    }

    /// Leaves `row` where the finger let go. A flick carries it on and slows to a stop, as a scrolled list does; with Reduce Motion it stays put.
    private func release(_ row: Int, distance: CGFloat, velocity: CGFloat) {
        shifts[row, default: 0] += distance
        if !reduceMotion, abs(velocity) > 20 {
            glides[row] = WallGlide(velocity: min(max(velocity, -4000), 4000), start: clock.glideTime)
        }
        drag = nil
    }
}

/// A flicked row of the wall gliding on and slowing to a stop as a scrolled list does. It is worked out from the wall's own time rather
/// than animated, so where the row stands is known at every moment and a finger can catch it there.
private struct WallGlide {
    let velocity: CGFloat
    let start: TimeInterval

    /// UIScrollView's normal deceleration as a time constant: the speed falls by a factor of e every half second.
    static let decay: TimeInterval = 0.5

    /// How far the row has glided by `time`.
    func distance(at time: TimeInterval) -> CGFloat {
        let elapsed = max(0, time - start)
        return velocity * CGFloat(Self.decay * (1 - exp(-elapsed / Self.decay)))
    }

    /// Whether the row is still visibly moving at `time`.
    func isMoving(at time: TimeInterval) -> Bool {
        abs(velocity) * CGFloat(exp(-max(0, time - start) / Self.decay)) > 4
    }
}

/// A sideways drag on one of the wall's rows (or the Deck's top card): `moved` with how far the finger has gone along it, `ended` with that
/// distance and its speed in points a second. It starts only when the finger moves more sideways than up or down, and the page's scroll waits for it to give up,
/// so a vertical swipe over the wall still scrolls the page. A drag that starts on a poster does not open it. On the Mac a two-finger
/// trackpad swipe moves the row too.
struct WallRowPan: UIGestureRecognizerRepresentable {
    let moved: (CGFloat) -> Void
    let ended: (_ distance: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        #if targetEnvironment(macCatalyst)
        recognizer.allowedScrollTypesMask = .continuous
        #endif
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {}

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let distance = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began:
            // Measured from where the drag is recognised, not where the finger came down, so the row does not jump by the distance the
            // finger moved before it counted as a drag.
            recognizer.setTranslation(.zero, in: recognizer.view)
            moved(0)
        case .changed: moved(distance)
        case .ended: ended(distance, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed: ended(distance, 0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}

/// The wall's own time. It runs only while the wall moves, so after a pause the wall carries on from where it stood rather than jumping.
/// The rows' drift and their glides keep separate times, so a row can glide while the wall's drift stands still under the Mac's pointer.
@MainActor
private final class DriftClock {
    private var elapsed: TimeInterval = 0
    private var last: Date?
    /// The time the rows' glides were last drawn at.
    private(set) var glideTime: TimeInterval = 0

    /// The drift's time at `date`. `running` false keeps both times where they are, for a wall drawn again while it stands still (a row
    /// held); `drifting` false keeps only the drift's.
    func advance(to date: Date, running: Bool = true, drifting: Bool = true) -> TimeInterval {
        if running, let last {
            // The first frame after a pause moves the wall no further than a frame would.
            let step = min(max(date.timeIntervalSince(last), 0), 1.0 / 30)
            glideTime += step
            if drifting { elapsed += step }
        }
        last = date
        return elapsed
    }
}

/// The wall's rows, built again only when its titles or its size change: a drag or a flick redraws the wall on every move, and its rows
/// stay the same through it.
@MainActor
private final class WallStripCache {
    private var items: [MetaPreview] = []
    private var size: [CGFloat] = []
    private var strips: [WallStrip] = []

    func strips(for items: [MetaPreview], rows: Int, width: CGFloat, gap: CGFloat, span: CGFloat) -> [WallStrip] {
        let size = [CGFloat(rows), width, gap, span]
        if size != self.size || items != self.items {
            self.items = items
            self.size = size
            strips = WallStrip.strips(for: items, rows: rows, width: width, gap: gap, span: span)
        }
        return strips
    }
}

/// One row of the wall: its titles, repeated until the row is longer than the panel by a whole lap, so it loops without a seam.
private struct WallStrip: Identifiable {
    struct Entry: Identifiable {
        let id: String
        let item: MetaPreview
        /// The repeat of the title that VoiceOver reads; the others are hidden from it.
        let isOriginal: Bool
        /// Tells this repeat's zoom source apart from the others.
        let copy: String
    }

    let id: Int
    let entries: [Entry]
    /// Identifies the entries, so a frame of the wall can tell that the row itself has not changed.
    let key: String
    /// The width of one lap: the row's own titles, each with its gap.
    let lap: CGFloat
    /// Points a second; leftwards when negative.
    let speed: CGFloat

    /// How far the row has drifted at `time`, plus `shift` moved by hand, within one lap, so it always covers the panel.
    func offset(at time: TimeInterval, shift: CGFloat = 0) -> CGFloat {
        guard lap > 0 else { return 0 }
        let travelled = (CGFloat(time) * speed + shift).truncatingRemainder(dividingBy: lap)
        return (travelled < 0 ? travelled + lap : travelled) - lap
    }

    /// `rows` rows covering `span` points each. With enough titles each row takes its own share in turn; with fewer, each row takes just
    /// as many as it needs to cross the panel without a title showing twice, starting at its own place in the shelf, and with fewer still
    /// every row shows them all. A row never carries more posters than it needs, as every one of them moves on every frame.
    static func strips(for items: [MetaPreview], rows: Int, width: CGFloat, gap: CGFloat, span: CGFloat) -> [WallStrip] {
        guard !items.isEmpty else { return [] }
        let speeds: [CGFloat] = [-14, 11, -17, 9, -12, 15]
        // Each row takes its own share only when that share is long enough to cross the panel without a title showing twice in the row.
        let shared = CGFloat(items.count / rows) * (width + gap) >= span
        let crossing = min(items.count, Int((span / (width + gap)).rounded(.up)))
        // VoiceOver reads each title once, where it first appears.
        var read = Set<String>()
        return (0..<rows).map { row in
            let own: [MetaPreview]
            if shared {
                own = stride(from: row, to: items.count, by: rows).map { items[$0] }
            } else {
                let start = row * items.count / rows
                own = (0..<crossing).map { items[(start + $0) % items.count] }
            }
            let lap = CGFloat(own.count) * (width + gap)
            let laps = Int((span / lap).rounded(.up)) + 1
            var entries: [Entry] = []
            for copy in 0..<laps {
                for item in own {
                    let isOriginal = copy == 0 && read.insert(item.identity).inserted
                    entries.append(Entry(id: "\(copy)/\(item.identity)", item: item, isOriginal: isOriginal, copy: "\(row).\(copy)/"))
                }
            }
            return WallStrip(id: row, entries: entries, key: entries.map(\.id).joined(separator: "|"), lap: lap,
                             speed: speeds[row % speeds.count])
        }
    }
}

/// A row of the wall's posters. Equatable, so the wall's frames move the row without rebuilding its posters.
private struct WallStripView: View, Equatable {
    let strip: WallStrip
    let width: CGFloat
    let height: CGFloat
    let gap: CGFloat

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.strip.id == rhs.strip.id && lhs.strip.key == rhs.strip.key && lhs.width == rhs.width && lhs.height == rhs.height
                && lhs.gap == rhs.gap
        }
    }

    var body: some View {
        HStack(spacing: gap) {
            ForEach(strip.entries) { entry in
                LayoutTitleLink(item: entry.item, copy: entry.copy, prewarms: false, cornerRadius: Theme.Radius.small * 0.8) {
                    LayoutPoster(item: entry.item, width: width, height: height)
                }
                .accessibilityHidden(!entry.isOriginal)
            }
        }
        .fixedSize()
    }
}

// MARK: - Parallax

/// `RowLayout.parallax`: wide cards whose backdrops slide slower than the cards as the row scrolls, each carrying the title's logo (or
/// name), its details and the start of its synopsis over a fade.
private struct ParallaxLayout: View {
    let items: [MetaPreview]
    let showsRating: Bool
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.heroContainerWidth) private var containerWidth

    /// Most of a phone's width, so the next card peeks in; a fixed width in a wider window. Both scale with the card size, never wider
    /// than the page.
    static func cardWidth(_ metrics: LayoutMetrics, containerWidth: CGFloat) -> CGFloat {
        let available = containerWidth - metrics.pageMargin * 2
        let base = metrics.isRegular ? min(560, available * 0.62) : max(200, available - 28)
        return max(1, min(available, (base * metrics.cardScale).rounded()))
    }

    static func height(_ metrics: LayoutMetrics, containerWidth: CGFloat) -> CGFloat {
        (cardWidth(metrics, containerWidth: containerWidth) / 1.5).rounded()
    }

    var body: some View {
        let width = Self.cardWidth(metrics, containerWidth: containerWidth)
        let height = Self.height(metrics, containerWidth: containerWidth)
        // The cards' height follows the window's width, so the shelf measures again when it changes instead of keeping the tallest it
        // has seen, which left a narrowed window's cards in a row too tall for them.
        ShelfScroll(margin: metrics.pageMargin, spacing: metrics.cardSpacing, resetKey: "\(width)x\(height)") {
            ForEach(items, id: \.identity) { item in
                ParallaxCard(item: item, width: width, height: height, showsRating: showsRating)
                    .reportsShelfEdge(id: item.identity)
            }
        }
    }
}

private struct ParallaxCard: View {
    let item: MetaPreview
    let width: CGFloat
    let height: CGFloat
    let showsRating: Bool
    @Environment(\.displayScale) private var displayScale

    private var backdrop: URL? {
        PosterQuality.landscape(item.background) ?? MetahubArtwork.background(imdbID: item.id) ?? PosterQuality.poster(for: item)
    }

    private var synopsis: String? {
        let text = item.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    var body: some View {
        // The picture is wider than the card by `shift` each side, and slides by up to that much against the card's own movement.
        let shift = (width * 0.14).rounded()
        LayoutTitleLink(item: item, cornerRadius: Theme.Radius.surface) {
            Color.clear
                .frame(width: width, height: height)
                .overlay {
                    ArtworkImage(url: backdrop, title: item.name,
                                 maxPixelSize: min(((width + shift * 2) * displayScale).rounded(.up), 2048))
                        .frame(width: width + shift * 2, height: height)
                        .scrollTransition(.interactive.threshold(.centered), axis: .horizontal) { content, phase in
                            content.offset(x: -CGFloat(phase.value) * shift)
                        }
                }
                .clipped()
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .black.opacity(0.55), location: 0.65),
                                           .init(color: .black.opacity(0.88), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomLeading) { caption }
                .contentShape(Rectangle())
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 6) {
            LayoutLogo(item: item, width: width * 0.5, height: height * 0.24)
            let details = layoutDetailLine(item, showsRating: showsRating)
            if !details.isEmpty {
                Text(details)
                    .font(Theme.Typography.metaLine.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            }
            if let synopsis {
                Text(synopsis)
                    .font(Theme.Typography.metaLine)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .foregroundStyle(.white)
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Spines

/// `RowLayout.spines`: posters standing side by side like books on a shelf, each showing a slice of its cover as a spine with its name
/// running up it. A tap opens a spine out to its whole cover, and a tap on the open cover opens the title. The first starts open.
private struct SpinesLayout: View {
    let items: [MetaPreview]
    let showsRating: Bool
    @State private var openID: String?
    @Environment(\.layoutMetrics) private var metrics

    static func coverWidth(_ metrics: LayoutMetrics) -> CGFloat { (metrics.posterWidth * 1.15).rounded() }
    static func height(_ metrics: LayoutMetrics) -> CGFloat { (coverWidth(metrics) * 1.5).rounded() }
    static func spineWidth(_ metrics: LayoutMetrics) -> CGFloat { max(36, (metrics.posterWidth * 0.32).rounded()) }

    var body: some View {
        let open = openID ?? items.first?.identity
        let coverWidth = Self.coverWidth(metrics)
        let spineWidth = Self.spineWidth(metrics)
        let height = Self.height(metrics)
        ScrollViewReader { proxy in
            ShelfScroll(margin: metrics.pageMargin, spacing: max(3, (metrics.cardSpacing * 0.4).rounded())) {
                ForEach(items, id: \.identity) { item in
                    SpineCard(item: item, isOpen: item.identity == open, coverWidth: coverWidth, spineWidth: spineWidth, height: height,
                              showsRating: showsRating) {
                        Haptics.play(.choices)
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { openID = item.identity }
                    }
                    // Opening a spine redraws only it and the one that closes.
                    .equatable()
                    .reportsShelfEdge(id: item.identity)
                }
            }
            // Brings a cover that opened out past the screen's edge fully into view.
            .onChange(of: openID) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.4)) { proxy.scrollTo(id) }
            }
        }
    }
}

private struct SpineCard: View, Equatable {
    let item: MetaPreview
    let isOpen: Bool
    let coverWidth: CGFloat
    let spineWidth: CGFloat
    let height: CGFloat
    let showsRating: Bool
    let onOpenOut: () -> Void
    @Environment(AppRouter.self) private var router
    @Environment(\.zoomScope) private var zoomScope
    @Environment(\.zoomNamespace) private var zoomNamespace
    @Environment(\.layoutMetrics) private var metrics

    /// `onOpenOut` is left out: it only ever opens this card's own title.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.item == rhs.item && lhs.isOpen == rhs.isOpen && lhs.coverWidth == rhs.coverWidth && lhs.spineWidth == rhs.spineWidth
                && lhs.height == rhs.height && lhs.showsRating == rhs.showsRating
        }
    }

    private var sourceID: String { "\(zoomScope)/\(item.identity)" }

    var body: some View {
        let radius = isOpen ? Theme.Radius.poster : Theme.Radius.poster * 0.45
        Button {
            if isOpen { openTitle() } else { onOpenOut() }
        } label: {
            // The whole cover is always drawn; the spine is its middle, cut to the spine's width.
            LayoutPoster(item: item, width: coverWidth, height: height)
                .frame(width: isOpen ? coverWidth : spineWidth, height: height)
                .clipped()
                .overlay { spineFace.opacity(isOpen ? 0 : 1) }
                .overlay(alignment: .bottom) {
                    if isOpen && showsRating { PosterRatingsOverlay(item: item).transition(.opacity) }
                }
                .contentShape(Rectangle())
                .mediaArtwork(cornerRadius: radius)
                .zoomSource(id: sourceID, in: zoomNamespace, cornerRadius: radius * metrics.cornerScale(for: .artwork))
        }
        .buttonStyle(PressableCardStyle.poster)
        .prewarmsHeroArtwork(item)
        .help(item.name)
        .titleCardMenu(item)
        .accessibilityLabel(item.name)
        // VoiceOver opens the title straight away, open or not.
        .accessibilityAction(.default) { openTitle() }
    }

    /// The spine: shaded like a rounded back, with a pair of rules near each end and the name running up it, the year at its head.
    private var spineFace: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.7), location: 0),
                .init(color: .black.opacity(0.3), location: 0.28),
                .init(color: .white.opacity(0.06), location: 0.45),
                .init(color: .black.opacity(0.32), location: 0.72),
                .init(color: .black.opacity(0.74), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            VStack {
                rules
                Spacer()
                rules
            }
            .padding(.vertical, 12)
            HStack(spacing: Theme.Spacing.s) {
                Text(item.name)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                Spacer(minLength: Theme.Spacing.s)
                if let year = item.releaseInfo, !year.isEmpty {
                    Text(year)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            .frame(width: max(0, height - 52))
            .rotationEffect(.degrees(-90))
        }
        .frame(width: spineWidth, height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var rules: some View {
        VStack(spacing: 3) {
            Rectangle().frame(height: 1)
            Rectangle().frame(height: 1)
        }
        .foregroundStyle(.white.opacity(0.35))
        .padding(.horizontal, 6)
    }

    private func openTitle() {
        Haptics.play(.titles)
        router.homePath.append(TitleDestination(preview: item, sourceID: sourceID))
    }
}
#endif
