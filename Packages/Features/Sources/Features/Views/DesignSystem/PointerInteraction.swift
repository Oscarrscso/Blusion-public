#if canImport(UIKit)
import SwiftUI

/// Keep plain buttons' native press behaviour and give their labels visible Mac hover feedback.
struct HoverPlainButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.pointerFeedback()
        }
        .buttonStyle(.plain)
    }
}

extension PrimitiveButtonStyle where Self == HoverPlainButtonStyle {
    static var hoverPlain: HoverPlainButtonStyle { HoverPlainButtonStyle() }
}

extension EnvironmentValues {
    /// Draws hover feedback as if the pointer were over the control: Settings → Appearance → Hover's preview, which shows each value as
    /// it is set, a slider's while it is dragged and the pointer is on the slider.
    @Entry var showsHover = false
}

#if targetEnvironment(macCatalyst)
private struct ButtonHoverModifier: ViewModifier {
    let isActive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAppearance.hover) private var hover
    @Environment(\.showsHover) private var showsHover
    @State private var isHovering = false

    func body(content: Content) -> some View {
        let lit = isActive && isEnabled && (isHovering || showsHover)
        return content
            .brightness(lit ? hover.buttonBrightness : 0)
            .scaleEffect(lit && !reduceMotion ? hover.buttonScale : 1)
            .animation(hover.animation(0.12, reduceMotion: reduceMotion), value: isHovering)
            .hoverEffect(.highlight, isEnabled: isActive && isEnabled && hover.usesSystemHighlight)
            .onHover { isHovering = $0 }
    }
}

/// Lights a glass control under the pointer with a fill and rim in its own shape, as the navigation control's segments light. Glass in a
/// container is drawn by the container, so brightness and scale on the control alone barely show.
private struct GlassHoverModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAppearance.hover) private var hover
    @Environment(\.showsHover) private var showsHover
    @State private var isHovering = false

    func body(content: Content) -> some View {
        let lit = isEnabled && (isHovering || showsHover)
        return content
            .overlay {
                shape.fill(.white.opacity(lit ? hover.glassFillOpacity : 0))
                    .overlay { shape.strokeBorder(.white.opacity(lit ? hover.glassRimOpacity : 0), lineWidth: 1) }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .brightness(lit ? hover.buttonBrightness : 0)
            .scaleEffect(lit && !reduceMotion ? hover.buttonScale : 1)
            .animation(hover.animation(0.12, reduceMotion: reduceMotion), value: lit)
            .onHover { isHovering = $0 }
    }
}
#endif

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
    @Environment(\.appAppearance.hover) private var hover
    @Environment(\.showsHover) private var showsHover
    @State private var isHovering = false
    @State private var pointer = PointerLocation()

    func body(content: Content) -> some View {
        let hovering = isEnabled && (isHovering || showsHover)
        let casts = tracksPointer && lifts && hovering && hover.castsShadow
        let glows = tracksPointer && hovering && hover.glowOpacity > 0
        return content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(highlightColor.opacity(hovering ? (tracksPointer ? hover.trackedCardFillOpacity : hover.cardFillOpacity) : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(highlightColor.opacity(isEnabled && isFocused && showsFocus ? 0.8 : 0), lineWidth: 2)
                    }
                    .allowsHitTesting(false)
            }
            .overlay {
                if glows {
                    PointerGlow(pointer: pointer, centre: isHovering ? nil : Self.shownGlowCentre, cornerRadius: cornerRadius,
                                opacity: hover.glowOpacity)
                        .transition(.opacity)
                }
            }
            .shadow(color: .black.opacity(casts ? 0.25 : 0), radius: casts ? 12 : 0, y: casts ? 6 : 0)
            .scaleEffect(liftScale(hovering: hovering))
            .animation(hover.animation(0.15, reduceMotion: reduceMotion), value: isHovering)
            .hoverEffect(.highlight, isEnabled: isEnabled && systemHighlight && hover.usesSystemHighlight)
            .onHover { isHovering = isEnabled && $0 }
            .onContinuousHover { phase in
                guard tracksPointer, case .active(let location) = phase else { return }
                pointer.location = location
            }
    }

    /// Where the glow sits on a card drawn lit without the pointer (`showsHover`): up and to the left, where a pointer comes in.
    private static let shownGlowCentre = UnitPoint(x: 0.35, y: 0.3)

    /// Under the pointer, Settings → Appearance → Hover's lift; a focused card keeps the lift it always had, hover feedback on or off.
    private func liftScale(hovering: Bool) -> CGFloat {
        guard isEnabled && lifts && !reduceMotion else { return 1 }
        if hovering { return tracksPointer ? hover.cardScale : hover.buttonScale }
        return isFocused ? (tracksPointer ? 1.04 : 1.025) : 1
    }
}

extension AppearancePreferences.Hover {
    /// The hover's ease-out over `duration` seconds at its speed; none for Instant or with Reduce Motion.
    func animation(_ duration: Double, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion, let scaled = self.duration(duration) else { return nil }
        return .easeOut(duration: scaled)
    }
}

/// Where the pointer is over a card. Only `PointerGlow` reads it, so a pointer move redraws the glow and nothing else.
@Observable
private final class PointerLocation {
    var location: CGPoint = .zero
}

private struct PointerGlow: View {
    let pointer: PointerLocation
    /// A fixed centre, for a card drawn lit without the pointer; nil follows the pointer.
    var centre: UnitPoint?
    let cornerRadius: CGFloat
    let opacity: Double

    var body: some View {
        GeometryReader { geometry in
            RadialGradient(colors: [.white.opacity(opacity), .clear],
                           center: centre ?? UnitPoint(x: pointer.location.x / max(1, geometry.size.width),
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

    /// A visible highlight and lift alongside the native pointer highlight. Apply inside button labels on Catalyst.
    @ViewBuilder
    func pointerFeedback(_ isActive: Bool = true) -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(ButtonHoverModifier(isActive: isActive))
        #else
        self
        #endif
    }

    /// Hover feedback for a glass button drawn in `shape`: a lit fill and rim under the pointer. Apply inside the label, after its glass.
    @ViewBuilder
    func glassHover<S: InsettableShape>(_ shape: S) -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(GlassHoverModifier(shape: shape))
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
