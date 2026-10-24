#if canImport(UIKit)
import SwiftUI

/// Places its subviews left to right at their intrinsic size, starting a new row when the next one would not fit. Rows are
/// left-aligned, and the gap between chips is `spacing` both across and down.
struct FlowLayout: Layout {
    var spacing: CGFloat

    init(spacing: CGFloat = Theme.Spacing.s) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(in: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, arrangement.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(in width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        FlowArrangement.arrange(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, in: width, spacing: spacing) { index, width in
            subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
    }
}
#endif
