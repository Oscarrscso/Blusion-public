#if canImport(UIKit)
import SwiftUI

/// Shared pointer feedback for custom controls; it never changes their layout or adds a separate focus target.
private struct PointerInteractionModifier: ViewModifier {
    let cornerRadius: CGFloat
    let lifts: Bool
    let highlightColor: Color
    let showsFocus: Bool
    let systemHighlight: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(highlightColor.opacity(isEnabled && isHovering ? 0.08 : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(highlightColor.opacity(isEnabled && isFocused && showsFocus ? 0.8 : 0), lineWidth: 2)
                    }
                    .allowsHitTesting(false)
            }
            .scaleEffect(isEnabled && lifts && !reduceMotion && (isHovering || isFocused) ? 1.025 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
            .hoverEffect(.highlight, isEnabled: isEnabled && systemHighlight)
            .onHover { isHovering = isEnabled && $0 }
    }
}

extension View {
    /// The system's hover highlight over something that can be clicked, so the pointer reacts to it. Mac only: a phone has no pointer.
    /// (Mac Catalyst has no SwiftUI cursor API, so this is the system's own pointer feedback rather than a hand cursor.)
    @ViewBuilder
    func pointerFeedback(_ isActive: Bool = true) -> some View {
        #if targetEnvironment(macCatalyst)
        hoverEffect(.highlight, isEnabled: isActive)
        #else
        self
        #endif
    }

    /// `showsFocus` false leaves out the ring a focused control gets, for a row inside a card whose own corners would cut the ring.
    /// `systemHighlight` false leaves out the system's hover highlight, so the fill drawn here is the only hover effect.
    func pointerInteraction(cornerRadius: CGFloat = Theme.Radius.card, lifts: Bool = false, highlightColor: Color = .white,
                            showsFocus: Bool = true, systemHighlight: Bool = true) -> some View {
        modifier(PointerInteractionModifier(cornerRadius: cornerRadius, lifts: lifts, highlightColor: highlightColor, showsFocus: showsFocus,
                                            systemHighlight: systemHighlight))
    }
}
#endif
