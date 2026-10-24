import CoreGraphics

/// Where `FlowLayout` puts its subviews: left to right, a new row when the next one would not fit. Pure arithmetic over their sizes.
enum FlowArrangement {
    /// The frames of subviews of `sizes` in `width`, and the size they take. A subview wider than `width` on its own is given
    /// `width` and measured again with `fitted`, so it shortens (a one-line label cuts its text short) instead of making the whole
    /// layout wider than its container: a long setting in the widget builder's sentence did that, and the screen went off its edges.
    static func arrange(sizes: [CGSize], in width: CGFloat, spacing: CGFloat,
                        fitted: (_ index: Int, _ width: CGFloat) -> CGSize) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for (index, measured) in sizes.enumerated() {
            var size = measured
            if width.isFinite, size.width > width {
                let refitted = fitted(index, width)
                size = CGSize(width: min(refitted.width, width), height: refitted.height)
            }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: frames.isEmpty ? 0 : y + rowHeight), frames)
    }
}
