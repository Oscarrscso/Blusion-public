#if canImport(UIKit)
import SwiftUI

/// Moves a scrolling page so a section that has just been opened is in view, as the reviews opened from a rating are. The page's scroll
/// view supplies it (`ScrollViewProxy.pageReveal`); a section's own tap calls it, so a section that starts open moves nothing.
struct PageReveal {
    let action: (AnyHashable) -> Void

    /// Brings the view with this id into view once it has laid out at its open size, with the same short wait as the reviews.
    @MainActor func show(_ id: AnyHashable) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            action(id)
        }
    }
}

extension EnvironmentValues {
    /// Set by a page that scrolls: the title page, the stream picker and the player's Info panel. Nil elsewhere, where an opening section
    /// stays where it is.
    @Entry var pageReveal: PageReveal? = nil
}

/// Hands its content the page's reveal, for a section drawn inside the view that sets it.
struct PageRevealReader<Content: View>: View {
    @Environment(\.pageReveal) private var reveal
    @ViewBuilder let content: (PageReveal?) -> Content

    var body: some View { content(reveal) }
}

extension ScrollViewProxy {
    /// The opened section moves only as far as it needs to be wholly in view, with the motion of the ratings' reviews.
    @MainActor var pageReveal: PageReveal {
        let proxy = self
        return PageReveal { id in
            withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo(id) }
        }
    }
}
#endif
