#if canImport(UIKit)
import SwiftUI
import StremioKit

/// A shelf header the way the TV app draws it: the title in bold 22 pt white and, when `onSeeAll` is set, a small grey chevron
/// right after the last word. The whole header is then the "See All" button. An optional grey subtitle sits under the title.
/// It has no horizontal padding of its own: the screen, or `MediaRow`, pads it to the page margin.
struct SectionHeader: View {
    let title: String
    let subtitle: String?
    let onSeeAll: (() -> Void)?

    init(_ title: String, subtitle: String? = nil, onSeeAll: (() -> Void)? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.onSeeAll = onSeeAll
    }

    var body: some View {
        if let onSeeAll {
            Button(action: onSeeAll) { SectionHeaderLabel(title: title, subtitle: subtitle, withChevron: true) }
                .buttonStyle(ShelfHeaderButtonStyle())
                .seeAllAccessibility(title)
        } else {
            SectionHeaderLabel(title: title, subtitle: subtitle, withChevron: false)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// The drawing of a shelf header: the title, then an optional grey subtitle. `SectionHeader` draws through it with or without its chevron.
private struct SectionHeaderLabel: View {
    let title: String
    let subtitle: String?
    let withChevron: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleText
                .headingStyle()
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The chevron is part of the text, so it stays glued to the last word when a long title wraps.
    private var titleText: Text {
        guard withChevron else { return Text(title) }
        let chevron = Text(Image(systemName: "chevron.right"))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .baselineOffset(2)
        return Text("\(title) \(chevron)")
    }
}

/// Dims the header while it is pressed, like a system text button.
private struct ShelfHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
    /// The "See All" reading and identifier of a header that opens a screen.
    func seeAllAccessibility(_ title: String) -> some View {
        accessibilityLabel(title)
            .accessibilityHint("See All")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("section.seeAll.\(title)")
    }
}

/// A titled horizontal shelf of cards. The cards snap to the page margin and may bleed past the screen's edge, so the row never
/// looks cut off by the margin. Margins and gaps come from `LayoutMetrics`, so a shelf is right on a phone and in a Mac window.
///
/// The row's height comes from its first card: a lazy stack in a horizontal scroll cannot measure the others before they scroll
/// in. Put the tallest card first, or give the cards of one row the same size and title setting.
struct MediaRow<Content: View>: View {
    let title: String
    let subtitle: String?
    let hideTitle: Bool
    let onSeeAll: (() -> Void)?
    let content: () -> Content
    private let artworkItems: [MetaPreview]
    private let artworkAspect: CardAspect
    private let artworkSize: CardSize
    private let artworkWidth: CGFloat?
    private let usesBetterPosters: Bool
    @State private var visibleRange: ClosedRange<Int>?
    @AppStorage(LazyLoadLookahead.defaultsKey) private var lookaheadLevel = LazyLoadLookahead.defaultLevel
    @Environment(\.isLandscape) private var isLandscape
    @Environment(\.loadsVisibleArtwork) private var sectionIsVisible
    /// The row's own menu, on its title and the space between its cards. A card's hold is the card's own: on iPhone it plays it.
    private var shelfMenu: AnyView?
    @State private var zoomScope = UUID().uuidString
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appAppearance) private var appearance
    /// The tallest card built so far, for the shape and text size it was measured at. With it the row has a fixed height, so laying out
    /// the page does not measure the row's cards again on every update: a lazy row that does not know its height builds and sizes cards,
    /// off screen ones too, each time the page around it changes.
    @State private var measuredHeight: (key: String, height: CGFloat)?
    #if targetEnvironment(macCatalyst)
    /// The Mac's UIKit shelf for a row built from a list of items (see `CollectionShelf`). Nil for a row of arbitrary content.
    fileprivate var collectionShelf: ((MediaRowShelfContext) -> AnyView)?
    /// The cards the UIKit shelf has on screen. Only `ShelfLookahead` reads them: a card scrolling in or out updated the row when they
    /// were its own state, and every update of the row refreshes every card on screen.
    @State private var shelfVisible = CollectionVisibleRanges()
    #endif

    init(_ title: String, subtitle: String? = nil, hideTitle: Bool = false, onSeeAll: (() -> Void)? = nil,
         artworkItems: [MetaPreview] = [], aspect: CardAspect = .poster, size: CardSize = .medium,
         cardWidth: CGFloat? = nil, usesBetterPosters: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.hideTitle = hideTitle
        self.onSeeAll = onSeeAll
        self.content = content
        self.artworkItems = artworkItems
        self.artworkAspect = aspect
        self.artworkSize = size
        self.artworkWidth = cardWidth
        self.usesBetterPosters = usesBetterPosters
    }

    /// Gives the row a menu on its title and the space between its cards, but not on the cards (see `shelfMenu`).
    func shelfMenu<Items: View>(@ViewBuilder _ items: () -> Items) -> MediaRow {
        var copy = self
        copy.shelfMenu = AnyView(items())
        return copy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.headerSpacing) {
            if !hideTitle {
                SectionHeader(title, subtitle: subtitle, onSeeAll: onSeeAll)
                    .modifier(OptionalContextMenu(menu: shelfMenu))
                    .padding(.horizontal, metrics.pageMargin)
            }
            shelf
        }
        .environment(\.zoomScope, zoomScope)
    }

    @ViewBuilder
    private var shelf: some View {
        #if targetEnvironment(macCatalyst)
        if let collectionShelf {
            let visible = shelfVisible
            collectionShelf(MediaRowShelfContext(
                itemWidth: MediaCard.resolvedWidth(width: artworkWidth, aspect: artworkAspect, size: artworkSize, metrics: metrics,
                                                   isLandscape: isLandscape),
                spacing: metrics.cardSpacing, margin: metrics.pageMargin, heightKey: heightKey,
                onVisibleRange: { visible.set($0, for: ShelfLookahead.id) }))
                .background {
                    ShelfLookahead(visible: visible, items: artworkItems, aspect: artworkAspect, size: artworkSize, width: artworkWidth,
                                   usesBetterPosters: usesBetterPosters)
                }
        } else {
            swiftUIShelf
        }
        #else
        swiftUIShelf
        #endif
    }

    private var swiftUIShelf: some View {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: metrics.cardSpacing) {
                    ForEach(subviews: content()) { card in
                        #if targetEnvironment(macCatalyst)
                        // Only iPhone haptics consume card-edge preferences.
                        card.id(card.id).onGeometryChange(for: CGFloat.self) { $0.size.height } action: { recordHeight($0) }
                        #else
                        card.id(card.id).reportsShelfEdge(id: card.id)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { recordHeight($0) }
                        #endif
                    }
                }
                .scrollTargetLayout()
                // Behind the cards and out into the page margins: a press between or beside them opens the row's menu, and one on a card
                // is the card's.
                .background {
                    if let shelfMenu {
                        Color.clear
                            .contentShape(.rect)
                            .padding(.horizontal, -metrics.pageMargin)
                            .contextMenu { shelfMenu }
                    }
                }
            }
            .onScrollGeometryChange(for: ClosedRange<Int>?.self) { geometry in
                guard !artworkItems.isEmpty else { return nil }
                let width = MediaCard.resolvedWidth(width: artworkWidth, aspect: artworkAspect, size: artworkSize,
                                                    metrics: metrics, isLandscape: isLandscape)
                let pitch = width + metrics.cardSpacing
                let first = min(artworkItems.count - 1, max(0, Int(((geometry.visibleRect.minX - metrics.pageMargin) / pitch).rounded(.down))))
                let last = min(artworkItems.count - 1, max(first, Int(((geometry.visibleRect.maxX - metrics.pageMargin) / pitch).rounded(.down))))
                return first...last
            } action: { _, range in visibleRange = range }
            .modifier(BufferedArtwork(shelves: [ArtworkShelf(items: bufferedItems, aspect: artworkAspect, size: artworkSize,
                                                             width: artworkWidth, usesBetterPosters: usesBetterPosters)]))
            .scrollIndicators(.hidden, axes: .horizontal)
            .contentMargins(.horizontal, metrics.pageMargin, for: .scrollContent)
            .softSnappingScroll()
            .scrollClipDisabled()
            .frame(height: rowHeight)
    }

    /// What the cards' height depends on: their shape and size, the text size of their captions and Appearance (card size, poster
    /// titles, font). A change measures again.
    private var heightKey: String {
        "\(artworkAspect.rawValue)|\(artworkSize.rawValue)|\(artworkWidth ?? 0)|\(isLandscape)|\(dynamicTypeSize)|\(metrics.posterWidth)|"
            + appearance.layoutKey
    }

    private var rowHeight: CGFloat? {
        guard let measuredHeight, measuredHeight.key == heightKey else { return nil }
        return measuredHeight.height
    }

    /// Keeps the tallest card's height. It only grows for one key, so a card built later that is taller is never cut off.
    private func recordHeight(_ height: CGFloat) {
        guard height > 0 else { return }
        let key = heightKey
        if let measuredHeight, measuredHeight.key == key, measuredHeight.height >= height - 0.5 { return }
        measuredHeight = (key, height.rounded(.up))
    }

    private var bufferedItems: [MetaPreview] {
        guard sectionIsVisible, let visibleRange,
              let range = LazyLoadLookahead.bufferRange(visible: visibleRange, count: artworkItems.count,
                  titles: LazyLoadLookahead.titles(atLevel: lookaheadLevel)) else { return [] }
        return Array(artworkItems[range])
    }
}

/// One card's place in a row built from a list of items: its index and identity.
struct ShelfItem<Item>: Identifiable {
    let id: String
    let index: Int
    let item: Item
}

/// The cards of a row built from a list of items, for the SwiftUI shelf (iPhone, and anywhere the Mac does not use `CollectionShelf`).
struct ShelfCards<Item, Card: View>: View {
    let items: [Item]
    let id: (Item) -> String
    let card: (Int, Item) -> Card

    var body: some View {
        ForEach(items.enumerated().map { ShelfItem(id: id($0.element), index: $0.offset, item: $0.element) }) { entry in
            card(entry.index, entry.item)
        }
    }
}

#if targetEnvironment(macCatalyst)
/// What a row tells its `CollectionShelf`: the cards' width, the gaps and margins, and where to report the cards on screen.
struct MediaRowShelfContext {
    let itemWidth: CGFloat
    let spacing: CGFloat
    let margin: CGFloat
    let heightKey: String
    let onVisibleRange: (ClosedRange<Int>?) -> Void
}

/// The artwork a row's `CollectionShelf` keeps loaded around the cards on screen: as many titles on each side as the Lazy load setting
/// asks, while the row's section is visible (`MediaRow.bufferedItems` does the same for the SwiftUI shelf).
private struct ShelfLookahead: View {
    /// The shelf's key in its `CollectionVisibleRanges`, which holds this one shelf.
    static let id = "shelf"
    let visible: CollectionVisibleRanges
    let items: [MetaPreview]
    let aspect: CardAspect
    let size: CardSize
    let width: CGFloat?
    let usesBetterPosters: Bool
    @AppStorage(LazyLoadLookahead.defaultsKey) private var lookaheadLevel = LazyLoadLookahead.defaultLevel
    @Environment(\.loadsVisibleArtwork) private var sectionIsVisible

    var body: some View {
        Color.clear
            .modifier(BufferedArtwork(shelves: [ArtworkShelf(items: buffered, aspect: aspect, size: size, width: width,
                                                             usesBetterPosters: usesBetterPosters)]))
            .accessibilityHidden(true)
    }

    private var buffered: [MetaPreview] {
        guard sectionIsVisible, let shown = visible.ranges[Self.id],
              let range = LazyLoadLookahead.bufferRange(visible: shown, count: items.count,
                                                       titles: LazyLoadLookahead.titles(atLevel: lookaheadLevel)) else { return [] }
        return Array(items[range])
    }
}
#endif

extension MediaRow {
    /// A row of `items`, one card each, all as wide as a card of `aspect`, `size` and `cardWidth`. On Mac it scrolls in a `CollectionShelf`;
    /// on iPhone it is the SwiftUI shelf, as rows of arbitrary content are.
    init<Item, Card: View>(_ title: String, subtitle: String? = nil, hideTitle: Bool = false, onSeeAll: (() -> Void)? = nil,
                           items: [Item], id: @escaping (Item) -> String, artworkItems: [MetaPreview] = [], aspect: CardAspect = .poster,
                           size: CardSize = .medium, cardWidth: CGFloat? = nil, usesBetterPosters: Bool = false,
                           scrollToStart: Int = 0,
                           @ViewBuilder card: @escaping (Int, Item) -> Card) where Content == ShelfCards<Item, Card> {
        self.init(title, subtitle: subtitle, hideTitle: hideTitle, onSeeAll: onSeeAll, artworkItems: artworkItems, aspect: aspect, size: size,
                  cardWidth: cardWidth, usesBetterPosters: usesBetterPosters) {
            ShelfCards(items: items, id: id, card: card)
        }
        #if targetEnvironment(macCatalyst)
        collectionShelf = { context in
            AnyView(CollectionShelf(items: items, id: id, itemWidth: context.itemWidth, spacing: context.spacing, margin: context.margin,
                                    heightKey: context.heightKey, scrollToStart: scrollToStart, onVisibleRange: context.onVisibleRange,
                                    cell: card))
        }
        #endif
    }
}

/// A lazy grid that preloads the chosen number of titles around the visible cards and requests the next page within that buffer.
/// `fillsWidth` makes Mac columns span the available width.
struct MediaGrid: View {
    let items: [MetaPreview]
    let aspect: CardAspect
    let showsRating: Bool
    let onLastAppear: (() -> Void)?
    let usesBetterPosters: Bool
    let fillsWidth: Bool
    @State private var zoomScope = UUID().uuidString
    @State private var visibleIDs: Set<String> = []
    @AppStorage(LazyLoadLookahead.defaultsKey) private var lookaheadLevel = LazyLoadLookahead.defaultLevel
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.isLandscape) private var isLandscape

    init(items: [MetaPreview], aspect: CardAspect = .poster, showsRating: Bool = true, onLastAppear: (() -> Void)? = nil,
         usesBetterPosters: Bool = false, fillsWidth: Bool = false) {
        self.items = items
        self.aspect = aspect
        self.showsRating = showsRating
        self.onLastAppear = onLastAppear
        self.usesBetterPosters = usesBetterPosters
        self.fillsWidth = fillsWidth
    }

    var body: some View {
        LazyVGrid(columns: filled(metrics.gridColumns(for: aspect, inLandscape: isLandscape)),
                  alignment: .leading, spacing: metrics.cardSpacing) {
            ForEach(items, id: \.identity) { item in
                MediaCardLink(item: item, aspect: aspect, showsRating: showsRating, usesBetterPosters: usesBetterPosters)
                    .stretched()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: Bool.self) { proxy in
                        guard let viewport = proxy.bounds(of: .scrollView) else { return true }
                        return viewport.intersects(CGRect(origin: .zero, size: proxy.size))
                    } action: { visible in
                        if visible { visibleIDs.insert(item.identity) }
                        else { visibleIDs.remove(item.identity) }
                    }
                    .onDisappear { visibleIDs.remove(item.identity) }
            }
        }
        .padding(.horizontal, metrics.pageMargin)
        .environment(\.zoomScope, zoomScope)
        .modifier(BufferedArtwork(shelves: [ArtworkShelf(items: bufferedItems, aspect: aspect, usesBetterPosters: usesBetterPosters)]))
        .task(id: nextPageID) {
            if nextPageID != nil { onLastAppear?() }
        }
    }

    private var visibleRange: ClosedRange<Int>? {
        let indices = items.indices.filter { visibleIDs.contains(items[$0].identity) }
        guard let first = indices.first, let last = indices.last else { return nil }
        return first...last
    }

    private var bufferedItems: [MetaPreview] {
        guard let visibleRange,
              let range = LazyLoadLookahead.bufferRange(visible: visibleRange, count: items.count,
                                                       titles: LazyLoadLookahead.titles(atLevel: lookaheadLevel)) else { return [] }
        return Array(items[range])
    }

    private var nextPageID: String? {
        guard let visibleRange,
              visibleRange.upperBound >= LazyLoadLookahead.triggerIndex(count: items.count,
                  titles: LazyLoadLookahead.titles(atLevel: lookaheadLevel)) else { return nil }
        return items.last?.identity
    }

    /// Mac, for a grid that fills its width: an adaptive column stops at its maximum width and so can leave a gutter on the right, so its
    /// maximum is lifted and the columns share the whole width (see `GridFill`). The cards ask for their pictures at the size they did,
    /// whatever the column's width. iPhone and iPad keep their columns.
    private func filled(_ columns: [GridItem]) -> [GridItem] {
        #if targetEnvironment(macCatalyst)
        return fillsWidth ? GridFill.filling(columns) : columns
        #else
        return columns
        #endif
    }


}

/// What a `MediaGrid` shows before its first titles arrive: blank cards in the grid's own columns, card shape, spacing and margins, so each
/// poster takes a placeholder's place exactly and nothing changes size as they load.
struct MediaGridPlaceholder: View {
    let aspect: CardAspect
    /// As the grid's own `fillsWidth`.
    var fillsWidth = false
    /// Enough blank cards to fill a screen.
    var count = 18
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.isLandscape) private var isLandscape

    var body: some View {
        // The grid's columns, and its drawing of a poster in landscape as a wide card (see `MediaGrid`).
        let landscapePoster = isLandscape && aspect == .poster
        var columns = metrics.gridColumns(for: aspect, inLandscape: isLandscape)
        #if targetEnvironment(macCatalyst)
        if fillsWidth { columns = GridFill.filling(columns) }
        #endif
        return LazyVGrid(columns: columns, alignment: .leading, spacing: metrics.cardSpacing) {
            ForEach(0..<count, id: \.self) { _ in
                UnloadedCard(artwork: landscapePoster ? .wide : aspect, showsCaption: aspect.showsCaptionByDefault)
            }
        }
        .padding(.horizontal, metrics.pageMargin)
        .shimmering()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

/// The stand-in for a title whose artwork has been released: a blank box of its card's shape, with the two caption lines when the card
/// has them, so the grid keeps the same row heights and its scroll position.
private struct UnloadedCard: View {
    @Environment(\.layoutMetrics) private var metrics
    let artwork: CardAspect
    let showsCaption: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            RoundedRectangle(cornerRadius: artwork.cornerRadius * metrics.cornerScale(for: .artwork), style: .continuous)
                .fill(.quaternary)
                .aspectRatio(artwork.ratio, contentMode: .fit)
            if showsCaption {
                VStack(alignment: .leading, spacing: 2) {
                    Text(" ").font(Theme.Typography.cardTitle).lineLimit(1)
                    Text(" ").font(Theme.Typography.cardSubtitle).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
/// A context menu when there is one to show; the view as it is otherwise.
struct OptionalContextMenu: ViewModifier {
    let menu: AnyView?

    func body(content: Content) -> some View {
        if let menu {
            content.contextMenu { menu }
        } else {
            content
        }
    }
}
#endif
