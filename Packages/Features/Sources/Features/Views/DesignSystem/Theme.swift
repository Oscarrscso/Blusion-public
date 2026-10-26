#if canImport(UIKit)
import SwiftUI
import UIKit

/// Design tokens. Screens take their spacing, radii and colours from here so every screen lines up on the same grid.
/// Sizes that differ between a phone and a Mac window (page margin, poster width, shelf spacing) live in `LayoutMetrics`.
enum Theme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        /// Small containers: episode stills, progress tracks.
        static let small: CGFloat = 10
        /// Poster artwork.
        static let poster: CGFloat = 10
        /// Wide artwork: Up Next cards, landscape cards, category tiles.
        static let card: CGFloat = 12
        /// Grouped surfaces and panels (the system's inset-grouped corner).
        static let surface: CGFloat = 20
    }

    /// Horizontal inset of screen content on a phone. Zero: content runs edge to edge. Adaptive screens read `LayoutMetrics.pageMargin`.
    static let screenPadding: CGFloat = 0
    /// The height of the system navigation bar, and the diameter of the round glass button it holds (the title page's back button). A round
    /// button beside a screen's content is drawn at this size so it lines up with the bar's own.
    static let barButtonDiameter: CGFloat = 44
    /// Vertical gap between rows on a phone browse screen. Adaptive screens read `LayoutMetrics.shelfSpacing`.
    static let rowSpacing: CGFloat = 28
    /// Gap between cards in a row or a grid on a phone. Adaptive screens read `LayoutMetrics.cardSpacing`.
    static let cardSpacing: CGFloat = 12

    /// The TV app's page: pure black, edge to edge.
    static let background = Color.black
    /// A raised surface on the black page (grouped panels, placeholders): the system's dark secondary grouped grey.
    static let surface = Color.white.opacity(0.11)
    static let surfaceStrong = Color.white.opacity(0.18)
    static let separator = Color.white.opacity(0.12)
    static let artworkBorder = Color.white.opacity(0.22)
    /// The grey of the metadata line under a title's name, on Home's spotlight and on the title page alike. A fixed colour rather than a
    /// hierarchical style, so the line never takes a tint from the view around it.
    static let metaText = Color(white: 0.58)
    /// Flat grey shown where artwork is still loading. Opaque, so a card never shows what is behind it.
    static let placeholder = Color(white: 0.11)
    static let brandStart = Color(red: 0.12, green: 0.30, blue: 0.86)
    static let brandEnd = Color(red: 0.48, green: 0.17, blue: 1.0)
    static let brandGradient = LinearGradient(colors: [brandStart, brandEnd], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// The TV app's type styles. System text styles, so Dynamic Type works; weights are the app's.
    enum Typography {
        /// A shelf header: "Continue Watching", "Season 2".
        static let shelfTitle = Font.title2.bold()
        /// The title under a card, and a row title: bold footnote.
        static let cardTitle = Font.footnote.weight(.semibold)
        /// The grey line under a card title: "S2, E5 · 21 min left".
        static let cardSubtitle = Font.caption
        /// The small grey caps above an episode title: "EPISODE 5". Apply `.textCase(.uppercase)` too.
        static let eyebrow = Font.caption2.weight(.semibold)
        /// A screen's large title ("Search", "Library") when it draws its own.
        static let largeTitle = Font.largeTitle.bold()
        /// The name of a title on its own page when there is no logo artwork.
        static let heroTitle = Font.system(.largeTitle, design: .default, weight: .bold)
        /// The single grey line under a title's name: "Drama · 2008 · 2 hr 32 min".
        static let metaLine = Font.footnote
        /// Body copy such as a synopsis.
        static let body = Font.subheadline
        /// A label inside a button.
        static let button = Font.headline
    }
}

extension View {
    /// The app's screen background: pure black edge to edge, like the TV app. Artwork is the only colour on screen.
    func screenBackground() -> some View {
        modifier(ScreenBackgroundModifier())
    }

    /// A subtle translucent rounded surface for grouped content. Deliberately not glass: glass is for controls over media.
    func cardSurface(cornerRadius: CGFloat = Theme.Radius.surface) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Glass for a card of content (a stream, a panel) with its translucent hairline. Cards share `Theme.Radius.card`.
    func glassCardSurface(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return glassEffect(.regular, in: shape)
            .glassHairline(shape)
    }

    /// A translucent rounded surface for a panel that holds glass controls, with the same hairline as `glassCardSurface`. It is the
    /// system's material and not glass: glass chips and buttons inside a glass panel would be glass on glass.
    func translucentPanelSurface(cornerRadius: CGFloat = Theme.Radius.surface) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(.regularMaterial, in: shape)
            .glassHairline(shape)
    }

    /// The translucent hairline that edges a glass card or panel, drawn just inside `shape`.
    func glassHairline(_ shape: some InsettableShape) -> some View {
        overlay {
            shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.7)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The same inset, one-pixel hairline for posters, cards and tiles. Full-screen hero artwork does not use it.
    func mediaArtwork(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        modifier(MediaArtworkModifier(cornerRadius: cornerRadius))
    }

    /// Horizontal shelves hide their scroll indicators on a phone; a Mac window shows them so the pointer can scroll.
    @ViewBuilder
    func shelfIndicators() -> some View {
        #if targetEnvironment(macCatalyst)
        scrollIndicators(.visible, axes: .horizontal)
        #else
        scrollIndicators(.hidden, axes: .horizontal)
        #endif
    }
}

private struct MediaArtworkModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.pixelLength) private var pixelLength

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Theme.artworkBorder, lineWidth: pixelLength)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct ScreenBackgroundModifier: ViewModifier {
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape

    /// On iPhone every page's top edge gets the system's soft scroll-edge blur, and hero pages (Home's spotlight, Detail) hide it so it never
    /// shows over their artwork at rest. Mac has no soft edge: over black it reads as a black band, so its top bar is a material blur instead.
    @ViewBuilder
    func body(content: Content) -> some View {
        // Keep the same view hierarchy through rotation so scrolling and artwork tasks survive.
        content.background { Theme.background.ignoresSafeArea() }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectHidden(isPhoneLandscape || Self.isMacCatalyst, for: .top)
            .scrollEdgeEffectHidden(isPhoneLandscape && UIDevice.current.userInterfaceIdiom == .phone, for: .bottom)
            .pageTopBar(hidden: isPhoneLandscape)
    }

    /// Mac builds take the top bar's material blur (see `pageTopBar`), with no soft edge.
    private static var isMacCatalyst: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }
}

extension View {
    /// A page's navigation bar. On iPhone it is hidden when `hidden` (the page runs under it), and the system's own otherwise. On Mac it is
    /// always visible, with the system's regular material, so the page beneath blurs and the bar never reads as a black band. `hidden` does
    /// not apply on Mac.
    func pageTopBar(hidden: Bool) -> some View {
        modifier(PageTopBarModifier(hidden: hidden))
    }
}

private struct PageTopBarModifier: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .toolbarBackground(.regularMaterial, for: .navigationBar)
        #else
        content.toolbarBackgroundVisibility(hidden ? .hidden : .automatic, for: .navigationBar)
        #endif
    }
}

/// A fade from clear to black, eased so there is no visible edge where it starts. Hero artwork and the backdrops of title pages
/// end in one. `length` is the share of the height the fade covers, measured from the bottom.
struct BottomFade: View {
    var length: Double = 0.55
    var strength: Double = 1

    var body: some View {
        let start = max(0, 1 - length)
        LinearGradient(stops: [
            .init(color: .black.opacity(0), location: start),
            .init(color: .black.opacity(0.10 * strength), location: start + (1 - start) * 0.18),
            .init(color: .black.opacity(0.32 * strength), location: start + (1 - start) * 0.40),
            .init(color: .black.opacity(0.62 * strength), location: start + (1 - start) * 0.65),
            .init(color: .black.opacity(0.88 * strength), location: start + (1 - start) * 0.85),
            .init(color: .black.opacity(strength), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
