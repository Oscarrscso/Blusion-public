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
        }
    }

    /// The height `layout` takes under its header, for the placeholder that stands in for it.
    static func height(of layout: RowLayout, metrics: LayoutMetrics, containerWidth: CGFloat) -> CGFloat {
        switch layout {
        case .mosaic: MosaicLayout.height(metrics)
        case .flow: FlowLayoutRow.height(metrics)
        case .wall: WallLayout.height(metrics)
        case .parallax: ParallaxLayout.height(metrics, containerWidth: containerWidth)
        case .spines: SpinesLayout.height(metrics)
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
        VStack(alignment: .leading, spacing: metrics.headerSpacing) {
            if let title {
                SectionHeader(title).padding(.horizontal, metrics.pageMargin)
            }
            RoundedRectangle(cornerRadius: Theme.Radius.surface * metrics.cornerScale(for: .artwork), style: .continuous)
                .fill(Theme.surfaceStrong)
                .frame(height: LayoutRow.height(of: layout, metrics: metrics.layoutCards(size), containerWidth: containerWidth))
                .shimmering()
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
private func detailLine(_ item: MetaPreview, showsRating: Bool) -> String {
    let rating = showsRating ? item.imdbRating.map { "★ \(ScoreText.wholeScore($0))" } : nil
    return [item.genres.first, item.releaseInfo, rating].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
}

/// A title's poster filling `width` by `height`, decoded at the size it is drawn. Only its own frame takes touches.
private struct LayoutPoster: View {
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
/// `copy` tells apart the repeats of one title in a layout that shows it more than once, so each is its own zoom source.
private struct LayoutTitleLink<Label: View>: View {
    let item: MetaPreview
    var copy = ""
    let cornerRadius: CGFloat
    @ViewBuilder let label: () -> Label
    @Environment(\.zoomScope) private var zoomScope
    @Environment(\.zoomNamespace) private var zoomNamespace
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        let sourceID = "\(zoomScope)/\(copy)\(item.identity)"
        NavigationLink(value: TitleDestination(preview: item, sourceID: sourceID)) {
            label()
                .mediaArtwork(cornerRadius: cornerRadius)
                .zoomSource(id: sourceID, in: zoomNamespace, cornerRadius: cornerRadius * metrics.cornerScale(for: .artwork))
        }
        .buttonStyle(PressableCardStyle.poster)
        .titleTapHaptic()
        .prewarmsHeroArtwork(item)
        .help(item.name)
        .titleCardMenu(item)
        .accessibilityLabel(item.name)
    }
}

/// A title's logo in a `width` by `height` box, pinned to its bottom leading corner; its name in bold when it has none.
private struct LayoutLogo: View {
    let item: MetaPreview
    let width: CGFloat
    let height: CGFloat
    @State private var image: UIImage?
    @State private var settled = false

    private var url: URL? { item.logo ?? MetahubArtwork.logo(imdbID: item.id) }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if settled {
                Text(item.name)
                    .font(.title3.bold())
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(width: width, height: height, alignment: .bottomLeading)
        .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
        .task(id: url) {
            image = url.flatMap { ImagePipeline.shared.cachedImage(for: $0, maxPixelSize: 400) }
            guard image == nil, let url else {
                settled = true
                return
            }
            let loaded = try? await ImagePipeline.shared.image(for: url, maxPixelSize: 400)
            guard !Task.isCancelled else { return }
            image = loaded
            settled = true
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

/// `RowLayout.flow`: Cover Flow. The poster in the middle faces the viewer; the others stand turned towards it in two tight stacks, each
/// overlapping the next like records in a crate, every poster over its own reflection, with the middle one's name and details under them.
/// A poster to one side comes to the middle when tapped; the one in the middle opens its title.
private struct FlowLayoutRow: View {
    let items: [MetaPreview]
    let showsRating: Bool
    @State private var centredID: String?
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.heroContainerWidth) private var containerWidth
    #if targetEnvironment(macCatalyst)
    @State private var isHovering = false
    #endif

    static func cardWidth(_ metrics: LayoutMetrics) -> CGFloat { (metrics.posterWidth * 1.2).rounded() }
    static func reflection(_ metrics: LayoutMetrics) -> CGFloat { (cardWidth(metrics) * 1.5 * 0.3).rounded() }
    static func height(_ metrics: LayoutMetrics) -> CGFloat {
        cardWidth(metrics) * 1.5 + FlowCard.reflectionGap + reflection(metrics) + Theme.Spacing.m + 40
    }

    private var current: String? { centredID ?? items.first?.identity }
    private var currentIndex: Int { items.firstIndex { $0.identity == current } ?? 0 }

    var body: some View {
        let width = Self.cardWidth(metrics)
        let height = width * 1.5
        let reflection = Self.reflection(metrics)
        // Each poster takes only `step` of the scroll, the gap between two posters in a side stack, so a drag moves the stacks with the
        // finger. The first poster to each side stands `spread` from the middle, clear of the one facing the viewer.
        let step = (width * 0.18).rounded()
        let spread = width * 0.68
        // Turns and scales about the poster's own middle, not its reflection's.
        let anchor = UnitPoint(x: 0.5, y: height / 2 / (height + FlowCard.reflectionGap + reflection))
        VStack(spacing: Theme.Spacing.m) {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.identity) { index, item in
                        FlowCard(item: item, width: width, height: height, reflection: reflection, isCentred: item.identity == current) {
                            withAnimation(.snappy(duration: 0.4)) { centredID = item.identity }
                        }
                        .visualEffect { content, proxy in
                            // How many steps the poster is from the middle, leftwards when negative; past one step it is in a stack.
                            let distance = proxy.bounds(of: .scrollView).map { proxy.size.width / 2 - $0.midX } ?? 0
                            let side = min(max(distance / step, -1), 1)
                            return content
                                .rotation3DEffect(.degrees(-Double(side) * 65), axis: (x: 0, y: 1, z: 0), anchor: anchor, perspective: 0.6)
                                .scaleEffect(1 - abs(side) * 0.2, anchor: anchor)
                                .offset(x: side * (spread - step))
                                .brightness(-Double(abs(side)) * 0.08)
                        }
                        .frame(width: step)
                        // The poster in the middle is drawn over its neighbours, and each one in a stack over the one behind it.
                        .zIndex(-Double(abs(index - currentIndex)))
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $centredID, anchor: .center)
            .scrollTargetBehavior(.viewAligned)
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
            Haptics.play(.shelves)
        }
        #if targetEnvironment(macCatalyst)
        .onHover { isHovering = $0 }
        #endif
    }

    /// The middle poster's name, and its details under it, crossfading as another poster comes to the middle.
    private var caption: some View {
        let item = items.indices.contains(currentIndex) ? items[currentIndex] : nil
        return VStack(spacing: 2) {
            Text(item?.name ?? " ")
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(item.map { detailLine($0, showsRating: showsRating) } ?? " ")
                .font(Theme.Typography.metaLine)
                .foregroundStyle(Theme.metaText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, metrics.pageMargin)
        .contentTransition(.opacity)
        .animation(.easeOut(duration: 0.2), value: current)
        .accessibilityHidden(true)
    }

    #if targetEnvironment(macCatalyst)
    /// Mac: a chevron at each side while the pointer is over the row, moving the next poster to the middle.
    private var arrows: some View {
        HStack {
            arrow(systemName: "chevron.left", label: "Previous title", step: -1, enabled: currentIndex > 0)
            Spacer()
            arrow(systemName: "chevron.right", label: "Next title", step: 1, enabled: currentIndex < items.count - 1)
        }
        .padding(.horizontal, Theme.Spacing.l)
    }

    private func arrow(systemName: String, label: String, step: Int, enabled: Bool) -> some View {
        Button {
            let target = min(max(currentIndex + step, 0), items.count - 1)
            withAnimation(.snappy(duration: 0.4)) { centredID = items[target].identity }
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

private struct FlowCard: View {
    let item: MetaPreview
    let width: CGFloat
    let height: CGFloat
    let reflection: CGFloat
    let isCentred: Bool
    let onCentre: () -> Void
    @Environment(AppRouter.self) private var router
    @Environment(\.zoomScope) private var zoomScope
    @Environment(\.zoomNamespace) private var zoomNamespace
    @Environment(\.layoutMetrics) private var metrics

    /// The gap between a poster and its reflection.
    static let reflectionGap: CGFloat = 3

    private var sourceID: String { "\(zoomScope)/\(item.identity)" }

    var body: some View {
        let radius = Theme.Radius.poster
        VStack(spacing: Self.reflectionGap) {
            Button {
                if isCentred { openTitle() } else { onCentre() }
            } label: {
                LayoutPoster(item: item, width: width, height: height)
                    .mediaArtwork(cornerRadius: radius)
                    .zoomSource(id: sourceID, in: zoomNamespace, cornerRadius: radius * metrics.cornerScale(for: .artwork))
            }
            .buttonStyle(PressableCardStyle.poster)
            .prewarmsHeroArtwork(item)
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
                    LinearGradient(colors: [.white.opacity(0.42), .clear], startPoint: .top, endPoint: .bottom)
                }
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

/// `RowLayout.wall`: a tilted wall of small posters in rows that drift past in opposite directions at different speeds, in a rounded panel
/// with a soft vignette. Each poster opens its title, and each row can be dragged along by itself; a flick glides on, and the row drifts
/// again from wherever it is let go. The wall stands still with Reduce Motion, while its row is off screen or the app is in the background,
/// while a row is held and, on the Mac, while the pointer is over it, so a poster can be clicked.
private struct WallLayout: View {
    let items: [MetaPreview]
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.heroContainerWidth) private var containerWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.loadsVisibleArtwork) private var sectionIsVisible
    @Environment(\.scenePhase) private var scenePhase
    @State private var clock = DriftClock()
    @State private var isHovering = false
    /// How far each row has been moved by hand, by its id, on top of its drift.
    @State private var shifts: [Int: CGFloat] = [:]
    /// The row being dragged, and how far along it the finger has gone.
    @State private var drag: (row: Int, distance: CGFloat)?

    static let tilt: Double = -8
    static func posterWidth(_ metrics: LayoutMetrics) -> CGFloat { (metrics.posterWidth * 0.62).rounded() }
    static func gap(_ metrics: LayoutMetrics) -> CGFloat { max(4, (metrics.cardSpacing * 0.67).rounded()) }
    static func height(_ metrics: LayoutMetrics) -> CGFloat { (posterWidth(metrics) * 1.5 * 2.2).rounded() }

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
        let strips = WallStrip.strips(for: items, rows: rows, width: width, gap: gap, span: panelWidth + overhang * 2)
        let paused = reduceMotion || !sectionIsVisible || scenePhase != .active || isHovering || drag != nil
        let radius = HeroBanner.cornerRadius * metrics.cornerScale(for: .artwork)
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: paused)) { context in
            let time = clock.advance(to: context.date)
            VStack(alignment: .leading, spacing: gap) {
                ForEach(strips) { strip in
                    WallStripView(strip: strip, width: width, height: posterHeight, gap: gap)
                        .equatable()
                        .modifier(WallStripOffset(strip: strip, time: time, overhang: overhang, shift: shift(of: strip.id)))
                        .gesture(WallRowPan { distance in
                            drag = (strip.id, distance)
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

    /// How far `row` has been moved by hand, counting the drag under way.
    private func shift(of row: Int) -> CGFloat {
        shifts[row, default: 0] + (drag?.row == row ? drag?.distance ?? 0 : 0)
    }

    /// Leaves `row` where the finger let go. A flick carries it on and slows to a stop, as a scrolled list does; with Reduce Motion it stays put.
    private func release(_ row: Int, distance: CGFloat, velocity: CGFloat) {
        let landed = shifts[row, default: 0] + distance
        let glide = reduceMotion ? 0 : min(max(velocity, -4000), 4000) * 0.3
        withAnimation(glide == 0 ? nil : .easeOut(duration: 0.6)) {
            drag = nil
            shifts[row] = landed + glide
        }
    }
}

/// A row of the wall where its drift has taken it at `time`, plus `shift`, how far it has been moved by hand, always within one lap. The
/// shift animates, so a flicked row glides on and wraps round its lap as it goes instead of running back.
private struct WallStripOffset: ViewModifier, Animatable {
    let strip: WallStrip
    let time: TimeInterval
    let overhang: CGFloat
    private var shift: CGFloat

    init(strip: WallStrip, time: TimeInterval, overhang: CGFloat, shift: CGFloat) {
        self.strip = strip
        self.time = time
        self.overhang = overhang
        self.shift = shift
    }

    /// Not tied to the main actor, as `Animatable` asks: it only reads and writes the modifier's own number.
    nonisolated var animatableData: CGFloat {
        get { shift }
        set { shift = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(x: strip.offset(at: time, shift: shift) - overhang)
    }
}

/// A sideways drag on one of the wall's rows: `moved` with how far the finger has gone along it, `ended` with that distance and its speed
/// in points a second. It starts only when the finger moves more sideways than up or down, and the page's scroll waits for it to give up,
/// so a vertical swipe over the wall still scrolls the page. A drag that starts on a poster does not open it. On the Mac a two-finger
/// trackpad swipe moves the row too.
private struct WallRowPan: UIGestureRecognizerRepresentable {
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
        case .began, .changed: moved(distance)
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
@MainActor
private final class DriftClock {
    private var elapsed: TimeInterval = 0
    private var last: Date?

    func advance(to date: Date) -> TimeInterval {
        if let last {
            // The first frame after a pause moves the wall no further than a frame would.
            elapsed += min(max(date.timeIntervalSince(last), 0), 1.0 / 30)
        }
        last = date
        return elapsed
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

    /// `rows` rows covering `span` points each. With enough titles each row takes its own share in turn; with few, every row shows them
    /// all, each starting at a different title.
    static func strips(for items: [MetaPreview], rows: Int, width: CGFloat, gap: CGFloat, span: CGFloat) -> [WallStrip] {
        guard !items.isEmpty else { return [] }
        let speeds: [CGFloat] = [-14, 11, -17, 9, -12, 15]
        let shared = items.count >= rows * 4
        return (0..<rows).map { row in
            let own: [MetaPreview]
            if shared {
                own = stride(from: row, to: items.count, by: rows).map { items[$0] }
            } else {
                let start = row * items.count / rows
                own = Array(items[start...]) + Array(items[..<start])
            }
            let lap = CGFloat(own.count) * (width + gap)
            let laps = Int((span / lap).rounded(.up)) + 1
            var entries: [Entry] = []
            for copy in 0..<laps {
                for item in own {
                    entries.append(Entry(id: "\(copy)/\(item.identity)", item: item, isOriginal: copy == 0 && (shared || row == 0),
                                         copy: "\(row).\(copy)/"))
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
                LayoutTitleLink(item: entry.item, copy: entry.copy, cornerRadius: Theme.Radius.small * 0.8) {
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
        ShelfScroll(margin: metrics.pageMargin, spacing: metrics.cardSpacing) {
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
            let details = detailLine(item, showsRating: showsRating)
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
        ScrollViewReader { proxy in
            ShelfScroll(margin: metrics.pageMargin, spacing: max(3, (metrics.cardSpacing * 0.4).rounded())) {
                ForEach(items, id: \.identity) { item in
                    SpineCard(item: item, isOpen: item.identity == open, coverWidth: Self.coverWidth(metrics),
                              spineWidth: Self.spineWidth(metrics), height: Self.height(metrics), showsRating: showsRating) {
                        Haptics.play(.choices)
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { openID = item.identity }
                    }
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

private struct SpineCard: View {
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
