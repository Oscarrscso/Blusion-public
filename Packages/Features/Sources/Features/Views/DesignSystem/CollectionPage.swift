#if canImport(UIKit) && targetEnvironment(macCatalyst)
import SwiftUI
import StremioKit
import UIKit

/// One part of a `CollectionPage`, top to bottom: a full-width piece of SwiftUI (filters, a heading, a message) or a grid of cards.
struct CollectionBlock {
    enum Kind {
        case full(AnyView)
        /// `ids` names each card; `cell` builds the card at an index. Columns follow `LayoutMetrics.gridColumns(for:)`.
        case grid(ids: [String], aspect: CardAspect, fillsWidth: Bool, cell: (Int) -> AnyView)
    }

    let id: String
    let kind: Kind
    /// Space under this block, before the next one.
    var spacingAfter: CGFloat = 0
    /// Grids only: the indices of the cards on screen, whenever they change.
    var onVisibleRange: ((ClosedRange<Int>?) -> Void)? = nil
}

/// The Mac's scrolling page for grids of titles (Discover, Library, See All): a `UICollectionView` whose cells host SwiftUI.
///
/// A SwiftUI `LazyVGrid` keeps every card it has built in the page's view graph and updates them on the main thread as the page scrolls,
/// which made long grids stutter on the Mac. Here UIKit scrolls the page, only the cells on screen exist, and they are reused. Each cell
/// is given the page's environment, so cards behave as in a SwiftUI grid.
struct CollectionPage: UIViewRepresentable {
    let blocks: [CollectionBlock]
    /// Space above the first block: the Mac's navigation bar floats over the page there.
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    /// Changing it scrolls the page back to the top.
    var scrollToTop: Int = 0
    /// Changing it puts the page at the top at once, with no animation.
    var jumpToTop: Int = 0
    /// True while the page scrolls, false once it has settled.
    var onScrollingChange: ((Bool) -> Void)? = nil
    /// The page's scroll position below its top inset, for the navigation bar's fade.
    var onScrollOffset: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView {
        let coordinator = context.coordinator
        // Insets are the page's own: none come from the window's safe area (the title bar), as in the SwiftUI pages, which run under it.
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.contentInsetsReference = .none
        let layout = UICollectionViewCompositionalLayout(sectionProvider: { [weak coordinator] section, environment in
            coordinator?.section(at: section, environment: environment)
        }, configuration: configuration)
        let view = InsetFreeCollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.contentInsetAdjustmentBehavior = .never
        view.insetsLayoutMarginsFromSafeArea = false
        view.clipsToBounds = true
        view.delegate = coordinator
        let registration = UICollectionView.CellRegistration<InsetFreeCell, String> { [weak coordinator] cell, path, _ in
            coordinator?.configure(cell, at: path)
        }
        coordinator.dataSource = UICollectionViewDiffableDataSource<String, String>(collectionView: view) { view, path, id in
            view.dequeueConfiguredReusableCell(using: registration, for: path, item: id)
        }
        coordinator.collectionView = view
        view.onLayout = { [weak coordinator] in coordinator?.reportVisibleRanges() }
        let pause = ScrollPointerPause(view)
        pause.onChange = { [weak coordinator] scrolling in coordinator?.page?.onScrollingChange?(scrolling) }
        coordinator.pointerPause = pause
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.page = self
        coordinator.environment = context.environment
        let insets = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        if view.contentInset != insets { view.contentInset = insets }
        coordinator.apply()
        // A change of card size, spacing or columns in Appearance lays the grids out again; a window resize already does.
        let appearanceKey = context.environment.appAppearance.layoutKey
        if appearanceKey != coordinator.appearanceKey {
            let first = coordinator.appearanceKey == nil
            coordinator.appearanceKey = appearanceKey
            if !first { view.collectionViewLayout.invalidateLayout() }
        }
        if scrollToTop != coordinator.scrollToTop {
            let first = coordinator.scrollToTop == nil
            coordinator.scrollToTop = scrollToTop
            if !first { view.setContentOffset(CGPoint(x: 0, y: -topInset), animated: true) }
        }
        if jumpToTop != coordinator.jumpToTop {
            let first = coordinator.jumpToTop == nil
            coordinator.jumpToTop = jumpToTop
            if !first { view.setContentOffset(CGPoint(x: 0, y: -topInset), animated: false) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate {
        var page: CollectionPage?
        /// The Appearance the grids were last laid out for (`AppearancePreferences.layoutKey`).
        var appearanceKey: String?
        var environment = EnvironmentValues()
        var dataSource: UICollectionViewDiffableDataSource<String, String>?
        weak var collectionView: UICollectionView?
        var pointerPause: ScrollPointerPause?
        var scrollToTop: Int?
        var jumpToTop: Int?
        private var blockIndex: [String: Int] = [:]
        private var lastRanges: [String: ClosedRange<Int>?] = [:]
        private var lastOffset: CGFloat?

        /// Item ids are the block's id and the card's id, so two grids can show one title.
        private func itemID(_ block: CollectionBlock, _ id: String) -> String { "\(block.id)\u{1F}\(id)" }

        func apply() {
            guard let page, let dataSource else { return }
            blockIndex = Dictionary(page.blocks.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            var fullIDs: [String] = []
            for block in page.blocks {
                snapshot.appendSections([block.id])
                switch block.kind {
                case .full:
                    let id = itemID(block, "full")
                    snapshot.appendItems([id], toSection: block.id)
                    fullIDs.append(id)
                case .grid(let ids, _, _, _):
                    // Every card keeps its place, so the cell at an index is that index's title; a repeated title gets a numbered id.
                    var counts: [String: Int] = [:]
                    let unique = ids.map { id -> String in
                        let seen = counts[id, default: 0]
                        counts[id] = seen + 1
                        return seen == 0 ? id : "\(id)#\(seen)"
                    }
                    snapshot.appendItems(unique.map { itemID(block, $0) }, toSection: block.id)
                }
            }
            let current = dataSource.snapshot()
            // A diffable data source leaves the cells of items it keeps as they were, so the full-width blocks (sections, filters,
            // messages) and the cards on screen are refreshed too, whether or not the list changed: new state must reach them.
            let visible = collectionView?.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) } ?? []
            let kept = Set(current.itemIdentifiers)
            let refresh = Array(Set(fullIDs + visible).filter { kept.contains($0) && snapshot.indexOfItem($0) != nil })
            if current.sectionIdentifiers != snapshot.sectionIdentifiers || current.itemIdentifiers != snapshot.itemIdentifiers {
                dataSource.apply(snapshot, animatingDifferences: false)
            }
            if !refresh.isEmpty {
                var refreshed = dataSource.snapshot()
                refreshed.reconfigureItems(refresh)
                dataSource.apply(refreshed, animatingDifferences: false)
            }
            reportVisibleRanges()
        }

        func configure(_ cell: UICollectionViewCell, at path: IndexPath) {
            guard let page, page.blocks.indices.contains(path.section) else { return }
            let block = page.blocks[path.section]
            // Each cell's content is identified by what it shows. A reused cell then starts the new section or title afresh, instead of
            // carrying the last one's state (a shelf's scroll position, a loaded flag) over to it.
            let content: AnyView
            switch block.kind {
            case .full(let view):
                // At its natural height: a horizontal scroll inside (a shelf) would otherwise stretch to whatever height the cell offers.
                content = AnyView(view.fixedSize(horizontal: false, vertical: true).id(block.id))
            case .grid(let ids, _, _, let cell):
                guard ids.indices.contains(path.item) else { return }
                content = AnyView(cell(path.item).id(ids[path.item]))
            }
            let environment = environment
            // The page places its cells itself: a cell under the window's title bar must not add the bar's inset to its own content.
            cell.contentConfiguration = UIHostingConfiguration { content.environment(\.self, environment).environment(\.isInCollectionCell, true).ignoresSafeArea() }
                .margins(.all, 0)
            cell.backgroundConfiguration = .clear()
            cell.clipsToBounds = false
            pointerPause?.prepare(cell)
        }

        func section(at index: Int, environment layoutEnvironment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? {
            guard let page, page.blocks.indices.contains(index) else { return nil }
            let block = page.blocks[index]
            let width = layoutEnvironment.container.effectiveContentSize.width
            let section: NSCollectionLayoutSection
            switch block.kind {
            case .full:
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(80))
                section = NSCollectionLayoutSection(group: .vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]))
            case .grid(_, let aspect, let fillsWidth, _):
                let metrics = environment.layoutMetrics
                let margin = metrics.pageMargin
                let spacing = metrics.cardSpacing
                let available = max(0, width - margin * 2)
                // A poster in a landscape layout (any Mac window) is drawn as a wide card, in the wide card's columns.
                let landscape = environment.isLandscape
                let (count, columnWidth) = Self.columns(for: aspect, fillsWidth: fillsWidth, available: available, metrics: metrics,
                                                        inLandscape: landscape)
                // Every card of a grid is as tall as its first: measured once, so no cell sizes itself as it scrolls in. A cell that
                // sizes itself lays its card out again in SwiftUI, which cost about a quarter of the scroll's time.
                let height = cardHeight(for: block, width: columnWidth)
                let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(columnWidth), heightDimension: .absolute(height))
                let rowWidth = columnWidth * CGFloat(count) + spacing * CGFloat(count - 1)
                let rowSize = NSCollectionLayoutSize(widthDimension: .absolute(rowWidth), heightDimension: .absolute(height))
                let row = NSCollectionLayoutGroup.horizontal(layoutSize: rowSize, repeatingSubitem: NSCollectionLayoutItem(layoutSize: itemSize),
                                                             count: count)
                row.interItemSpacing = .fixed(spacing)
                section = NSCollectionLayoutSection(group: row)
                section.interGroupSpacing = spacing
                section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: margin, bottom: 0, trailing: margin)
            }
            section.contentInsets.bottom = block.spacingAfter
            section.contentInsetsReference = .none
            return section
        }

        private var cardHeights: [String: CGFloat] = [:]

        /// The height of a grid's first card at `width`, measured in a throwaway hosting controller and kept per grid, width and text size.
        func cardHeight(for block: CollectionBlock, width: CGFloat) -> CGFloat {
            guard case .grid(let ids, let aspect, _, let cell) = block.kind else { return 0 }
            let key = "\(block.id)|\(width)|\(environment.dynamicTypeSize)|\(environment.isLandscape)|\(environment.appAppearance.layoutKey)"
            if let known = cardHeights[key] { return known }
            let landscape = environment.isLandscape && aspect == .poster
            guard !ids.isEmpty else { return width / (landscape ? CardAspect.wide : aspect).ratio }
            let host = UIHostingController(rootView: cell(0).environment(\.self, environment))
            host.sizingOptions = []
            let height = max(1, host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height.rounded(.up))
            cardHeights[key] = height
            return height
        }

        /// The SwiftUI grid's columns (`LayoutMetrics.gridColumns(for:)`): as many adaptive columns as fit, each between the minimum and
        /// maximum width, or sharing the whole width when the grid fills it (`GridFill`). A fixed column count shares the width.
        static func columns(for aspect: CardAspect, fillsWidth: Bool, available: CGFloat, metrics: LayoutMetrics,
                            inLandscape: Bool) -> (count: Int, width: CGFloat) {
            let spacing = metrics.cardSpacing
            let columns = metrics.gridColumns(for: aspect, inLandscape: inLandscape)
            if columns.count == 1, case .adaptive(let minimum, let maximum) = columns[0].size {
                let count = GridFill.columnCount(width: available, minimum: minimum, spacing: spacing)
                let shared = GridFill.columnWidth(width: available, count: count, spacing: spacing)
                return (count, fillsWidth ? shared : min(shared, maximum))
            }
            let count = max(1, columns.count)
            return (count, GridFill.columnWidth(width: available, count: count, spacing: spacing))
        }

        func reportVisibleRanges() {
            guard let page, let view = collectionView else { return }
            var visible: [Int: [Int]] = [:]
            for path in view.indexPathsForVisibleItems { visible[path.section, default: []].append(path.item) }
            for (index, block) in page.blocks.enumerated() {
                guard let report = block.onVisibleRange else { continue }
                let items = visible[index] ?? []
                let range = items.min().flatMap { low in items.max().map { low...$0 } }
                if let last = lastRanges[block.id], last == range { continue }
                lastRanges[block.id] = range
                // After this update, so no SwiftUI state changes while SwiftUI is updating the page.
                DispatchQueue.main.async { report(range) }
            }
        }

        /// The cards on screen are reported after the layout that follows (`InsetFreeCollectionView.onLayout`): until then the view still
        /// lists the cells of the last position.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            pointerPause?.scrolled()
            guard let report = page?.onScrollOffset else { return }
            let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            guard offset != lastOffset else { return }
            lastOffset = offset
            report(offset)
        }

        func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool { false }
        func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool { false }
    }
}

/// A grid of titles for a `CollectionPage`, with what `MediaGrid` adds to a grid: the posters around the visible cards are loaded ahead
/// (the Lazy load setting), and the next page is requested when the viewer comes within that many titles of the end.
struct MacTitleGrid {
    let id: String
    let items: [MetaPreview]
    var aspect: CardAspect = .poster
    var fillsWidth = false
    var usesBetterPosters = false
    var onLastAppear: (() -> Void)? = nil
    var spacingAfter: CGFloat = 0
    let card: (Int, MetaPreview) -> AnyView
}

/// The Mac's grid page: full-width SwiftUI pieces and grids of titles in one UIKit scroll (`CollectionPage`), with each grid's artwork
/// loaded ahead and its next page requested as `MediaGrid` does.
struct MacGridPage: View {
    enum Part {
        case full(id: String, view: AnyView, spacingAfter: CGFloat = 0)
        case grid(MacTitleGrid)
    }

    let parts: [Part]
    var scrollToTop: Int = 0
    /// The cards each grid has on screen. Only `MacGridLookahead` reads them: a row scrolling in or out updated this page when they
    /// were its own state, and every page update refreshes every card on screen.
    @State private var visible = CollectionVisibleRanges()
    @State private var zoomScope = UUID().uuidString
    @Environment(MacNavigationScrollState.self) private var navigation: MacNavigationScrollState?

    var body: some View {
        CollectionPage(blocks: blocks, topInset: MacPageNavigation.height, bottomInset: Theme.Spacing.l, scrollToTop: scrollToTop,
                       onScrollOffset: { [navigation] offset in
                           let value = min(MacPageNavigation.height, max(0, offset))
                           if navigation?.offset != value { navigation?.offset = value }
                       })
            .environment(\.zoomScope, zoomScope)
            .background { MacGridLookahead(grids: grids, visible: visible) }
            .onAppear { navigation?.offset = 0 }
    }

    private var grids: [MacTitleGrid] {
        parts.compactMap { if case .grid(let grid) = $0 { grid } else { nil } }
    }

    private var blocks: [CollectionBlock] {
        let visible = visible
        return parts.map { part in
            switch part {
            case .full(let id, let view, let spacingAfter):
                return CollectionBlock(id: id, kind: .full(view), spacingAfter: spacingAfter)
            case .grid(let grid):
                let items = grid.items
                return CollectionBlock(id: grid.id, kind: .grid(ids: items.map(\.identity), aspect: grid.aspect, fillsWidth: grid.fillsWidth,
                                                                cell: { index in grid.card(index, items[index]) }),
                                       spacingAfter: grid.spacingAfter,
                                       onVisibleRange: { visible.set($0, for: grid.id) })
            }
        }
    }
}

/// The cards each grid or shelf of a Mac UIKit page has on screen, by its id. Kept in an object so that a row or card scrolling in or out
/// updates only the views that read it (the artwork buffer, the next-page check), as `HomeScrollState` does for Home's scroll.
@MainActor @Observable
final class CollectionVisibleRanges {
    private(set) var ranges: [String: ClosedRange<Int>] = [:]

    func set(_ range: ClosedRange<Int>?, for id: String) {
        if ranges[id] != range { ranges[id] = range }
    }
}

/// What `MacGridPage` does with the cards on screen: loads the artwork around them, and asks a grid for its next page when the viewer
/// comes within the Lazy load setting's titles of its end, as `MediaGrid` does.
private struct MacGridLookahead: View {
    let grids: [MacTitleGrid]
    let visible: CollectionVisibleRanges
    @AppStorage(LazyLoadLookahead.defaultsKey) private var lookaheadLevel = LazyLoadLookahead.defaultLevel

    var body: some View {
        Color.clear
            .modifier(BufferedArtwork(shelves: bufferedShelves))
            .task(id: nextPageKey) { trigger(nextPageKey) }
            .accessibilityHidden(true)
    }

    private var titles: Int { LazyLoadLookahead.titles(atLevel: lookaheadLevel) }

    private var bufferedShelves: [ArtworkShelf] {
        grids.compactMap { grid in
            guard let visible = visible.ranges[grid.id],
                  let range = LazyLoadLookahead.bufferRange(visible: visible, count: grid.items.count, titles: titles) else { return nil }
            return ArtworkShelf(items: Array(grid.items[range]), aspect: grid.aspect, usesBetterPosters: grid.usesBetterPosters)
        }
    }

    /// The grids within `titles` of their end, named with their last title, so each asks for its next page once per page loaded.
    private var nextPageKey: [String] {
        grids.compactMap { grid in
            guard grid.onLastAppear != nil, let visible = visible.ranges[grid.id],
                  visible.upperBound >= LazyLoadLookahead.triggerIndex(count: grid.items.count, titles: titles),
                  let last = grid.items.last else { return nil }
            return "\(grid.id)|\(last.identity)"
        }
    }

    private func trigger(_ keys: [String]) {
        for grid in grids where keys.contains(where: { $0.hasPrefix("\(grid.id)|") }) { grid.onLastAppear?() }
    }
}
/// A collection view, and cells, that pass no safe area to their content. A page runs under the window's title bar, as the SwiftUI pages
/// do; a cell under the bar would otherwise inset its SwiftUI content by the bar's height and be measured that much taller.
final class InsetFreeCollectionView: UICollectionView {
    /// Told after each layout. The cells on screen change only here, as the view scrolls or its items change.
    var onLayout: (() -> Void)?

    override var safeAreaInsets: UIEdgeInsets { .zero }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

final class InsetFreeCell: UICollectionViewCell {
    override var safeAreaInsets: UIEdgeInsets { .zero }
}
#endif

