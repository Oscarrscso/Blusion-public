#if canImport(UIKit)
import SwiftUI

/// Shared pointer feedback for custom controls; it never changes their layout or adds a separate focus target.
///
/// Every poster card on a Mac carries this, so it stays cheap while the pointer is elsewhere: the glow is only built under the pointer,
/// the shadow has no radius when idle, and pointer moves redraw the glow alone, not the card.
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
    @State private var pointer = PointerLocation()

    func body(content: Content) -> some View {
        let hovering = isEnabled && isHovering
        let casts = tracksPointer && lifts && hovering
        return content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(highlightColor.opacity(hovering ? (tracksPointer ? 0.012 : 0.08) : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(highlightColor.opacity(isEnabled && isFocused && showsFocus ? 0.8 : 0), lineWidth: 2)
                    }
                    .allowsHitTesting(false)
            }
            .overlay {
                if tracksPointer && hovering {
                    PointerGlow(pointer: pointer, cornerRadius: cornerRadius)
                        .transition(.opacity)
                }
            }
            .shadow(color: .black.opacity(casts ? 0.25 : 0), radius: casts ? 12 : 0, y: casts ? 6 : 0)
            .scaleEffect(isEnabled && lifts && !reduceMotion && (isHovering || isFocused) ? (tracksPointer ? 1.04 : 1.025) : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
            .hoverEffect(.highlight, isEnabled: isEnabled && systemHighlight)
            .onHover { isHovering = isEnabled && $0 }
            .onContinuousHover { phase in
                guard tracksPointer, case .active(let location) = phase else { return }
                pointer.location = location
            }
    }
}

/// Where the pointer is over a card. Only `PointerGlow` reads it, so a pointer move redraws the glow and nothing else.
@Observable
private final class PointerLocation {
    var location: CGPoint = .zero
}

private struct PointerGlow: View {
    let pointer: PointerLocation
    let cornerRadius: CGFloat

    var body: some View {
        GeometryReader { geometry in
            RadialGradient(colors: [.white.opacity(0.04), .clear],
                           center: UnitPoint(x: pointer.location.x / max(1, geometry.size.width),
                                             y: pointer.location.y / max(1, geometry.size.height)),
                           startRadius: 0, endRadius: 150)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
