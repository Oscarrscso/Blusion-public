#if canImport(UIKit)
import SwiftUI

/// Shared pointer feedback for custom controls; it never changes their layout or adds a separate focus target.
private struct PointerInteractionModifier: ViewModifier {
    let cornerRadius: CGFloat
    let lifts: Bool
    let highlightColor: Color
    let showsFocus: Bool
    let systemHighlight: Bool
    let tracksPointer: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var pointerLocation: CGPoint = .zero

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(highlightColor.opacity(isEnabled && isHovering ? (tracksPointer ? 0.012 : 0.08) : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(highlightColor.opacity(isEnabled && isFocused && showsFocus ? 0.8 : 0), lineWidth: 2)
                    }
                    .allowsHitTesting(false)
            }
            .overlay {
                if tracksPointer {
                    GeometryReader { geometry in
                        RadialGradient(colors: [.white.opacity(0.04), .clear],
                                       center: UnitPoint(x: pointerLocation.x / max(1, geometry.size.width),
                                                         y: pointerLocation.y / max(1, geometry.size.height)),
                                       startRadius: 0, endRadius: 150)
                            .opacity(isEnabled && isHovering ? 1 : 0)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .shadow(color: .black.opacity(tracksPointer && lifts && isEnabled && isHovering ? 0.10 : 0), radius: 8, y: 3)
            .scaleEffect(isEnabled && lifts && !reduceMotion && (isHovering || isFocused) ? (tracksPointer ? 1.008 : 1.025) : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
            .hoverEffect(.highlight, isEnabled: isEnabled && systemHighlight)
            .onHover { isHovering = isEnabled && $0 }
            .onContinuousHover { phase in
                guard tracksPointer else { return }
                if case .active(let location) = phase { pointerLocation = location }
            }
    }
}

extension View {
    /// Hero artwork gets the same quiet Mac highlight, without lifting or casting a shadow.
    @ViewBuilder
    func heroPointerHighlight(cornerRadius: CGFloat = 0) -> some View {
        #if targetEnvironment(macCatalyst)
        pointerInteraction(cornerRadius: cornerRadius, systemHighlight: false, tracksPointer: true)
        #else
        self
        #endif
    }

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
                            showsFocus: Bool = true, systemHighlight: Bool = true, tracksPointer: Bool = false) -> some View {
        modifier(PointerInteractionModifier(cornerRadius: cornerRadius, lifts: lifts, highlightColor: highlightColor, showsFocus: showsFocus,
                                            systemHighlight: systemHighlight, tracksPointer: tracksPointer))
    }
}
#endif
