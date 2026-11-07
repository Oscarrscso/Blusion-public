#if canImport(UIKit)
import SwiftUI

/// Appearance's shelf divider: a line centred in the gap under a shelf, without changing the gap itself.
struct ShelfDivider: ViewModifier {
    let metrics: LayoutMetrics
    let isShown: Bool

    func body(content: Content) -> some View {
        if isShown && metrics.showsShelfDividers {
            let thickness = metrics.shelfDividerThickness
            let half = max(0, (metrics.shelfSpacing - thickness) / 2)
            VStack(alignment: .leading, spacing: 0) {
                content
                Rectangle()
                    .fill(Color.white.opacity(metrics.shelfDividerOpacity))
                    .frame(height: thickness)
                    .padding(.horizontal, metrics.shelfDividerFullWidth ? 0 : metrics.pageMargin)
                    .padding(.top, half)
                    .accessibilityHidden(true)
            }
            .padding(.bottom, -(half + thickness))
        } else {
            content
        }
    }
}
#endif
