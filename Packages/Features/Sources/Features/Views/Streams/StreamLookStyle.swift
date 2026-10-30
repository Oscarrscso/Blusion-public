#if canImport(UIKit)
import StremioKit
import SwiftUI

extension StreamProvider {
    /// The service's own colour, for its card's edge and its badge.
    var tint: Color {
        switch self {
        case .netflix: Color(red: 0.90, green: 0.04, blue: 0.08)
        case .primeVideo: Color(red: 0.00, green: 0.66, blue: 0.88)
        case .appleTV: Color(white: 0.92)
        case .disneyPlus: Color(red: 0.18, green: 0.42, blue: 1.00)
        case .hboMax: Color(red: 0.45, green: 0.24, blue: 0.92)
        case .hulu: Color(red: 0.11, green: 0.91, blue: 0.51)
        case .paramountPlus: Color(red: 0.00, green: 0.39, blue: 1.00)
        case .peacock: Color(red: 0.96, green: 0.78, blue: 0.10)
        case .crunchyroll: Color(red: 0.96, green: 0.46, blue: 0.13)
        }
    }
}

/// How a card's look is drawn: the edge a service or a disc gives it, and the soft 4K glow of a 4K REMUX. Both are modifiers on the card
/// itself, not on its content, so a card keeps its place in the list and its open details when its look does not change.
extension View {
    /// The card's edge: a streaming service's colour, or a disc's silver sheen. The plain card keeps its own edge. The overlay is always
    /// there, and only what it draws changes.
    /// `isEmphasised` draws the edge bolder: on a Mac, the edge of the card the arrow keys are on, in place of a second outline.
    func streamLookEdge(_ look: StreamLook, isEmphasised: Bool = false) -> some View {
        overlay {
            switch look {
            case .plain:
                EmptyView()
            case .disc, .fourKDisc:
                StreamLookEdgeLine(style: AngularGradient(colors: StreamLookPalette.discSheen, center: .center), isEmphasised: isEmphasised)
            case .streaming(let provider):
                StreamLookEdgeLine(style: provider.tint.opacity(isEmphasised ? 1 : 0.9), isEmphasised: isEmphasised)
            }
        }
    }

    private static var streamGlowOpacity: Double {
        #if targetEnvironment(macCatalyst)
        0.12
        #else
        0.34
        #endif
    }

    /// A 4K REMUX's blurred 4K treatment: a soft champagne glow inside the card, under its content. It is a gradient rather than a blur
    /// filter, so the list scrolls as smoothly as the plain cards do.
    func streamLookGlow(_ look: StreamLook) -> some View {
        background {
            if look == .fourKDisc {
                Rectangle()
                    .fill(RadialGradient(colors: [QualityBadge.premium.opacity(Self.streamGlowOpacity), QualityBadge.premium.opacity(0)],
                                         center: .topTrailing, startRadius: 0, endRadius: 280))
            }
        }
    }
}

/// The hairline that frames a card for its look, drawn inside the card's edge and never hit by a tap.
private struct StreamLookEdgeLine<Style: ShapeStyle>: View {
    let style: Style
    var isEmphasised = false
    /// How wide an edge is drawn for the card the arrow keys are on, brighter too: plainly more than a thicker hairline.
    static var emphasisedWidth: CGFloat { 3 }

    var body: some View {
        RoundedRectangle(cornerRadius: StreamCardMetrics.cornerRadius, style: .continuous)
            .strokeBorder(style, lineWidth: isEmphasised ? Self.emphasisedWidth : 1.5)
            #if targetEnvironment(macCatalyst)
            .opacity(isEmphasised ? 1 : 0.3)
            #endif
            .brightness(isEmphasised ? 0.3 : 0)
            .allowsHitTesting(false)
    }
}

private enum StreamLookPalette {
    /// The silver of a disc's sheen, round the edge: bright where the light catches it, dimmer between. The first and last stops match, so
    /// the ring closes without a seam.
    static let discSheen: [Color] = [.white.opacity(0.9), Color(white: 0.45), .white.opacity(0.7), Color(white: 0.35), .white.opacity(0.9)]
}
#endif
