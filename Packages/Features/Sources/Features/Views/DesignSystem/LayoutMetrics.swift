#if canImport(UIKit)
import SwiftUI
import UIKit

/// Every size that differs between a phone and a Mac window, in one place. Screens read these instead of hard-coding numbers, so
/// the same code is right on both:
///
///     @Environment(\.layoutMetrics) private var metrics
///     ... .padding(.horizontal, metrics.pageMargin)
///
/// The compact set is the iPhone layout (just under three posters across, 260 pt Up Next cards); the regular set is the
/// Mac window and the iPad (posters about 180 pt, as many across as fit). The environment picks one from the horizontal size
/// class; `.environment(\.layoutMetrics, .regular)` forces a set (the gallery and previews do).
struct LayoutMetrics: Equatable, Sendable {
    /// True for the wide layout (Mac window, iPad): sidebar navigation, left-aligned hero, readable-width text columns.
    var isRegular: Bool
    /// Horizontal inset of page content, the same on every page (Home, Discover, Library, Search, title pages): headings, filters and
    /// grids sit inside it, and shelves scroll edge to edge with their first and last cards inset by it.
    var pageMargin: CGFloat
    /// Vertical gap between two shelves (or sections) on a page.
    var shelfSpacing: CGFloat
    /// Gap between a shelf's header and its cards.
    var headerSpacing: CGFloat
    /// Gap between cards in a shelf, and between the columns and the rows of a grid. Every grid uses this one value.
    var cardSpacing: CGFloat
    /// Width of a 2:3 poster in a shelf (`CardSize.medium`).
    var posterWidth: CGFloat
    /// Width of a 16:9 card with a caption: Up Next, landscape shelves (`CardSize.medium`).
    var wideCardWidth: CGFloat
    /// Width of a square card in a shelf (`CardSize.medium`).
    var squareWidth: CGFloat
    /// Width of a 16:9 category tile in a shelf.
    var tileWidth: CGFloat
    /// Width of an episode lockup (16:9 still with its texts underneath).
    var episodeWidth: CGFloat
    /// Diameter of a cast and crew avatar.
    var avatarSize: CGFloat
    /// The widest a block of reading text (a synopsis) grows. Wider windows put the information block beside it.
    var readableWidth: CGFloat
    /// Share of the container's height that the featured carousel takes.
    var heroHeightFraction: CGFloat
    /// The tallest the featured carousel is allowed to be (a tall window should not make it a tower).
    var heroMaxHeight: CGFloat

    static let compact = LayoutMetrics(
        isRegular: false, pageMargin: Theme.Spacing.l, shelfSpacing: 28, headerSpacing: 10, cardSpacing: 12,
        posterWidth: 128, wideCardWidth: 260, squareWidth: 124, tileWidth: 200, episodeWidth: 250, avatarSize: 72,
        readableWidth: .infinity, heroHeightFraction: 0.66, heroMaxHeight: 640
    )

    static let regular = LayoutMetrics(
        isRegular: true, pageMargin: Theme.Spacing.l, shelfSpacing: 36, headerSpacing: 12, cardSpacing: 16,
        posterWidth: 180, wideCardWidth: 300, squareWidth: 176, tileWidth: 260, episodeWidth: 280, avatarSize: 88,
        readableWidth: 640, heroHeightFraction: 0.58, heroMaxHeight: 620
    )

    var continueCardWidth: CGFloat { isRegular ? 256 : 210 }

    /// The horizontal inset of a title page's content: the page margin, but never less than `Theme.Spacing.l`. Home uses it too, so its
    /// headings, selector and shelves line up with the title page.
    var contentMargin: CGFloat { max(pageMargin, Theme.Spacing.l) }

    /// The folded width of a TMDb review card on a title page.
    var reviewCardWidth: CGFloat { isRegular ? 340 : 280 }

    /// The gap between a title page's sections.
    var titleSectionSpacing: CGFloat { Theme.Spacing.xl + Theme.Spacing.l }

    /// Half of the gap between the ratings row and the section after it: the faint line sits in the middle, this far from each side.
    /// The whole gap is `titleSectionSpacing` plus `Theme.Spacing.s`.
    var titleRatingsGap: CGFloat { (Theme.Spacing.xl + Theme.Spacing.l + Theme.Spacing.s) / 2 }

    /// Other landscape rows keep their own base, so a larger Continue card does not resize them.
    var landscapePosterWidth: CGFloat { (isRegular ? 180 : 148) * 1.2 }

    func heroHeight(forContainerHeight height: CGFloat) -> CGFloat {
        min(max(height * heroHeightFraction, 380), heroMaxHeight)
    }

    /// The columns of a poster grid: three on a phone, as many as fit on a wide screen.
    var posterGridColumns: [GridItem] {
        isRegular
            ? [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: cardSpacing, alignment: .top)]
            : Array(repeating: GridItem(.flexible(), spacing: cardSpacing, alignment: .top), count: 3)
    }

    /// The columns of a grid of 16:9 cards or category tiles: two on a phone, as many as fit on a wide screen.
    var wideGridColumns: [GridItem] {
        isRegular
            ? [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: cardSpacing, alignment: .top)]
            : Array(repeating: GridItem(.flexible(), spacing: cardSpacing, alignment: .top), count: 2)
    }

    /// The columns of a grid of square cards.
    var squareGridColumns: [GridItem] {
        isRegular
            ? [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: cardSpacing, alignment: .top)]
            : Array(repeating: GridItem(.flexible(), spacing: cardSpacing, alignment: .top), count: 3)
    }

    func gridColumns(for aspect: CardAspect, inLandscape: Bool = false) -> [GridItem] {
        if inLandscape && aspect == .poster {
            // On a phone or iPad turned sideways the columns share the whole width: a capped column stopped short of it and left a
            // wider gap on the right than the page margin on the left (Library, Discover, See All). The Mac keeps its cap; its Discover
            // fills through `GridFill` instead.
            #if targetEnvironment(macCatalyst)
            let maximum = landscapePosterWidth * 1.25
            #else
            let maximum = CGFloat.infinity
            #endif
            return [GridItem(.adaptive(minimum: landscapePosterWidth, maximum: maximum), spacing: cardSpacing, alignment: .top)]
        }
        return switch aspect {
        case .poster: posterGridColumns
        case .wide: wideGridColumns
        case .square: squareGridColumns
        }
    }
}

/// Lists and forms keep to a readable column on a wide window, centred as before. On Mac the column starts at the leading edge instead, beside
/// the sidebar: a centred column left a wide gap there. A phone keeps the full width, including a large one turned sideways, whose size
/// class is regular.
struct ReadableColumn: ViewModifier {
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape

    /// `isPhoneLandscape` is also true on an iPad turned sideways, so the device is checked as well.
    private var isPhoneInLandscape: Bool { isPhoneLandscape && UIDevice.current.userInterfaceIdiom == .phone }

    private var alignment: Alignment {
        #if targetEnvironment(macCatalyst)
        return .leading
        #else
        return .center
        #endif
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: (metrics.isRegular && !isPhoneInLandscape) ? 680 : CGFloat.infinity, alignment: alignment)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

extension View {
    /// Keeps a list or form to the readable column (see `ReadableColumn`). Apply it to the list or form itself, before its background.
    func readableColumn() -> some View { modifier(ReadableColumn()) }
}

extension EnvironmentValues {
    @Entry var isLandscape = false
    /// True only for a phone turned sideways. A Mac window is never a phone, so its bar and spotlight keep the portrait rules there.
    @Entry var isPhoneLandscape = false
    /// Home supplies the full viewport height, including insets, so scrolling bars cannot resize the hero.
    @Entry var heroContainerHeight: CGFloat = 800
    /// Home supplies its width too, so the portrait spotlight is the same height as the title page's picture.
    @Entry var heroContainerWidth: CGFloat = 390
    @Entry var isHomeScrolling = false
    /// The safe-area insets of the window this view is in, as its root measured them. A screen that runs under the bars or the notch reads
    /// these when its own geometry cannot report them.
    @Entry var windowSafeArea = EdgeInsets()
    /// Set only to force a layout; `layoutMetrics` falls back to the one the size class asks for.
    @Entry var layoutMetricsOverride: LayoutMetrics?

    /// The metrics of the current layout: compact in a compact-width window (an iPhone, a narrow split view), regular otherwise
    /// (a Mac window, an iPad). Reading it makes the view depend on the size class, so it follows window resizes.
    var layoutMetrics: LayoutMetrics {
        get { layoutMetricsOverride ?? (horizontalSizeClass == .compact ? .compact : .regular) }
        set { layoutMetricsOverride = newValue }
    }
}
#endif
