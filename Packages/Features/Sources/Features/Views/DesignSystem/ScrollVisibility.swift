#if canImport(UIKit)
import SwiftUI

extension EnvironmentValues {
    /// True inside a cell of the Mac's UIKit pages and shelves (`CollectionPage`, `CollectionShelf`).
    @Entry var isInCollectionCell = false
}

extension View {
    /// Calls `action` with whether this view lies within its scroll view's visible bounds, as it scrolls.
    ///
    /// In a UIKit cell the view counts as visible once it appears and no geometry is tracked: UIKit keeps only the cells on and just beside
    /// the screen, and tracking a view's place in the UIKit scroll made every cell lay out and draw again on each frame of the page's scroll.
    func onScrollVisibility(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(ScrollVisibilityModifier(action: action))
    }
}

private struct ScrollVisibilityModifier: ViewModifier {
    let action: (Bool) -> Void
    @Environment(\.isInCollectionCell) private var isInCollectionCell

    @ViewBuilder
    func body(content: Content) -> some View {
        if isInCollectionCell {
            content.onAppear { action(true) }
        } else {
            content.onGeometryChange(for: Bool.self) { proxy in
                guard let viewport = proxy.bounds(of: .scrollView) else { return true }
                return viewport.intersects(CGRect(origin: .zero, size: proxy.size))
            } action: { action($0) }
        }
    }
}
#endif
