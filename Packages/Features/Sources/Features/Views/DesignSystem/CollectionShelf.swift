#if canImport(UIKit) && targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// The Mac's horizontal shelf: a `UICollectionView` whose cells host SwiftUI cards.
///
/// A SwiftUI lazy row keeps every card it builds in the page's view graph, measures cards to learn its own height and re-lays them out on
/// each update of the page, all on the main thread, which made Mac scrolling stutter. Here UIKit scrolls the row, only the cells on screen
/// exist, and they are reused as they scroll off. The row's height is measured once, from its first card, so the page lays the row out
/// without looking inside it. Each cell is given the page's environment, so cards behave as they do in a SwiftUI row.
struct CollectionShelf<Item, Cell: View>: UIViewRepresentable {
    let items: [Item]
    let id: (Item) -> String
    /// Every card in the row is this wide.
    let itemWidth: CGFloat
    let spacing: CGFloat
    let margin: CGFloat
    /// Whatever the cards' height depends on besides their width (shape, size, text size): a change measures the row again.
    let heightKey: String
    /// Changing it scrolls the row back to its first card.
    var scrollToStart: Int = 0
    var onVisibleRange: ((ClosedRange<Int>?) -> Void)? = nil
    @ViewBuilder let cell: (Int, Item) -> Cell

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = SnappingShelfLayout()
        layout.scrollDirection = .horizontal
        let view = ShelfCollectionView(frame: .zero, collectionViewLayout: layout)
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.reportVisibleRange() }
        view.backgroundColor = .clear
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.alwaysBounceVertical = false
        view.alwaysBounceHorizontal = true
        view.decelerationRate = .fast
        // A lifted card under the pointer may grow past the row's edges, as in the SwiftUI row.
        view.clipsToBounds = false
        view.contentInsetAdjustmentBehavior = .never
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: Coordinator.reuseID)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        context.coordinator.collectionView = view
        context.coordinator.pointerPause = ScrollPointerPause(view)
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.shelf = self
        coordinator.environment = context.environment
        // Home scrolling moves this row under the pointer too: its cards ignore the pointer until Home settles.
        coordinator.pointerPause?.setExternallyPaused(context.environment.homeScroll?.isScrolling ?? false)
        if let layout = view.collectionViewLayout as? SnappingShelfLayout {
            let height = coordinator.height(for: self, environment: context.environment)
            let size = CGSize(width: itemWidth, height: height)
            if layout.itemSize != size { layout.itemSize = size }
            if layout.minimumLineSpacing != spacing { layout.minimumLineSpacing = spacing }
            let inset = UIEdgeInsets(top: 0, left: margin, bottom: 0, right: margin)
            if layout.sectionInset != inset { layout.sectionInset = inset }
        }
        let ids = items.map(id)
        if ids != coordinator.ids {
            coordinator.ids = ids
            view.reloadData()
        } else {
            // Same titles: refresh the cells on screen, so a new setting or environment reaches them. Off-screen cells are built fresh.
            for path in view.indexPathsForVisibleItems {
                if let cell = view.cellForItem(at: path) { coordinator.configure(cell, at: path.item) }
            }
        }
        coordinator.reportVisibleRange()
        if scrollToStart != coordinator.scrollToStart {
            let first = coordinator.scrollToStart == nil
            coordinator.scrollToStart = scrollToStart
            if !first { view.setContentOffset(.zero, animated: true) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICollectionView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? itemWidth, height: context.coordinator.height(for: self, environment: context.environment))
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        static var reuseID: String { "CollectionShelf.cell" }
        var shelf: CollectionShelf?
        var environment = EnvironmentValues()
        var ids: [String] = []
        weak var collectionView: UICollectionView?
        var pointerPause: ScrollPointerPause?
        var scrollToStart: Int?
        private var measured: (key: String, height: CGFloat)?
        private var lastRange: ClosedRange<Int>?

        /// The first card's height at the row's width, measured once per key in a throwaway hosting controller.
        func height(for shelf: CollectionShelf, environment: EnvironmentValues) -> CGFloat {
            let key = "\(shelf.heightKey)|\(shelf.itemWidth)"
            if let measured, measured.key == key { return measured.height }
            guard let first = shelf.items.first else { return 0 }
            let host = UIHostingController(rootView: shelf.cell(0, first).environment(\.self, environment))
            host.sizingOptions = []
            let size = host.sizeThatFits(in: CGSize(width: shelf.itemWidth, height: .greatestFiniteMagnitude))
            let height = max(1, size.height.rounded(.up))
            measured = (key, height)
            return height
        }

        func configure(_ cell: UICollectionViewCell, at index: Int) {
            guard let shelf, shelf.items.indices.contains(index) else { return }
            let item = shelf.items[index]
            let environment = environment
            cell.contentConfiguration = UIHostingConfiguration {
                // Identified by its title, so a reused cell starts the new card afresh.
                shelf.cell(index, item).id(shelf.id(item)).environment(\.self, environment)
                    .environment(\.isInCollectionCell, true).ignoresSafeArea()
            }
            .margins(.all, 0)
            cell.clipsToBounds = false
            cell.contentView.clipsToBounds = false
            cell.backgroundConfiguration = .clear()
            pointerPause?.prepare(cell)
        }

        func reportVisibleRange() {
            guard let shelf, let onVisibleRange = shelf.onVisibleRange, let view = collectionView else { return }
            let indices = view.indexPathsForVisibleItems.map(\.item)
            let range = indices.min().flatMap { low in indices.max().map { low...$0 } }
            guard range != lastRange else { return }
            lastRange = range
            // Reported after this update, so the row's state is never changed while SwiftUI is updating it.
            DispatchQueue.main.async { onVisibleRange(range) }
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            shelf?.items.count ?? 0
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Self.reuseID, for: indexPath)
            configure(cell, at: indexPath.item)
            return cell
        }

        /// The cards on screen are reported after the layout that follows (`ShelfCollectionView.onLayout`): until then the view still
        /// lists the cells of the last position.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            pointerPause?.scrolled()
        }

        func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool { false }
        func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool { false }
    }
}

/// A shelf's collection view, which says when it has laid out its cells.
final class ShelfCollectionView: UICollectionView {
    /// Told after each layout. The cells on screen change only here, as the row scrolls or its items change.
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// A row that comes to rest with a card's leading edge at the page margin, as the SwiftUI shelves do (`scrollTargetBehavior(.viewAligned)`).
final class SnappingShelfLayout: UICollectionViewFlowLayout {
    override func targetContentOffset(forProposedContentOffset proposed: CGPoint, withScrollingVelocity velocity: CGPoint) -> CGPoint {
        guard let view = collectionView else { return proposed }
        let pitch = itemSize.width + minimumLineSpacing
        guard pitch > 0 else { return proposed }
        let maxX = max(0, collectionViewContentSize.width - view.bounds.width)
        let index = (proposed.x / pitch).rounded()
        return CGPoint(x: min(max(0, index * pitch), maxX), y: proposed.y)
    }
}
#endif
