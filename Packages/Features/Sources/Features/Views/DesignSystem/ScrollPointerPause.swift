#if canImport(UIKit) && targetEnvironment(macCatalyst)
import UIKit

/// Switches the pointer off for a UIKit page's or shelf's cells while it scrolls, and back on a moment after it stops.
///
/// A page moving under a still pointer sends every card that passes beneath it a hover: each one hit-tests, lifts and casts its shadow,
/// only to drop again a frame later. That is work the scroll pays for on the main thread, and nothing the viewer asked for.
@MainActor
final class ScrollPointerPause {
    private(set) var isPaused = false
    private var resume: DispatchWorkItem?
    private weak var collectionView: UICollectionView?
    /// Told when the scroll starts and when it has settled.
    var onChange: ((Bool) -> Void)?

    init(_ collectionView: UICollectionView) {
        self.collectionView = collectionView
    }

    /// Call on every scroll movement.
    func scrolled() {
        setPaused(true)
        resume?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setPaused(false) }
        resume = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Pauses for as long as `paused` is true, from outside the view (Home's own scroll moving a row).
    func setExternallyPaused(_ paused: Bool) {
        resume?.cancel()
        setPaused(paused)
    }

    /// New and reused cells take the current state.
    func prepare(_ cell: UICollectionViewCell) {
        cell.isUserInteractionEnabled = !isPaused
    }

    private func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        onChange?(paused)
        for cell in collectionView?.visibleCells ?? [] { cell.isUserInteractionEnabled = !paused }
    }
}
#endif
