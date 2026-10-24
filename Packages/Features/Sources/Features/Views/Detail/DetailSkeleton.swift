#if canImport(UIKit)
import SwiftUI
import UIKit

/// Static, layout-sized placeholders: no per-card animation or loading tasks while scrolling.
struct DetailSkeletonLine: View {
    var font: Font = .body
    var width: CGFloat? = nil

    var body: some View {
        Text(" ")
            .font(font)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.48)).padding(.vertical, 3)
            }
            .accessibilityHidden(true)
            .modifier(DetailSkeletonPulse())
    }
}

/// Uses the same UIKit font metrics and rounded height as JustifiedText.
struct DetailSkeletonParagraph: View {
    var style: UIFont.TextStyle = .body
    var lines = 3
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let lineHeight = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).lineHeight
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<lines, id: \.self) { index in
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.48))
                        .frame(width: geometry.size.width * (index == lines - 1 ? 0.72 : 1), height: lineHeight * 0.55)
                        .frame(height: lineHeight)
                }
                .frame(height: lineHeight)
            }
        }
        .frame(height: ceil(lineHeight * CGFloat(lines)), alignment: .top)
        .accessibilityHidden(true)
        .modifier(DetailSkeletonPulse())
    }
}

/// Text-only loading bars pulse between clearly visible light and dark greys.
/// PhaseAnimator keeps cycling while the skeleton is on screen, with no onAppear state race.
/// Artwork placeholders keep their existing spinners.
private struct DetailSkeletonPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content.opacity(0.8)
        } else {
            content.phaseAnimator([false, true]) { view, highlighted in
                view.opacity(highlighted ? 1 : 0.38)
            } animation: { _ in
                .easeInOut(duration: 0.9)
            }
        }
    }
}

extension View {
    /// Draw over the reserved card without changing its size or intercepting taps.
    func loadingCardSpinner(_ active: Bool = true) -> some View {
        overlay {
            if active {
                Spinner().controlSize(.large)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    func detailLoadingTransition(_ loading: Bool) -> some View {
        modifier(DetailLoadingTransition(loading: loading))
    }
}

private struct DetailLoadingTransition: ViewModifier {
    let loading: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: loading)
    }
}
#endif
