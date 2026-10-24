#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

#if targetEnvironment(macCatalyst)
/// The title page's hero on a Mac. The picture runs the full width of the window, darker on its left, and the title, the actions and the
/// ratings sit over its lower left edge. Beneath it the trailer's panel and the synopsis share a column, with the information beside them
/// when the window is wide enough for two. The page supplies the controls, the panel, the synopsis and the information, so the state they
/// keep stays on the page.
struct DesktopDetailHero<Controls: View, Trailer: View, Synopsis: View, Information: View>: View {
    let model: DetailViewModel
    /// The page's own size: the full width of the window's content, and its height.
    let size: CGSize
    let contentMargin: CGFloat
    let pictureSlot: HeroSlot
    let logoSlot: HeroSlot
    let isRevealed: Bool
    /// False hides the trailer's panel, the synopsis, the information and the ratings, leaving the picture, the title and the controls. The
    /// page then shows its streams under them.
    let showsDetails: Bool
    @ViewBuilder let controls: Controls
    /// The trailer's panel, at the width its column gives it.
    let trailer: (CGFloat) -> Trailer
    @ViewBuilder let synopsis: Synopsis
    @ViewBuilder let information: Information
    /// True when the overview over the picture is cut short at its three lines. Only then is the whole synopsis set under the hero: one
    /// that fits is already read in full above, and a second copy under it said the same thing twice.
    @State private var overviewIsCut = false

    /// The hero is extended below its former height so its bottom-aligned title, overview, ratings and actions sit noticeably lower.
    private var heroHeight: CGFloat { min(max(size.height * 0.62, 440), 620) + 80 }
    /// The widest the title, the actions and the ratings are, over the picture's lower left edge.
    private static var textWidth: CGFloat { 560 }
    /// The widest and tallest the title's logo is on this page.
    private static var logoBox: CGSize { CGSize(width: 420, height: 120) }
    /// The page's width from which the synopsis and the information sit side by side.
    private static var twoColumnWidth: CGFloat { 900 }
    /// The information's column beside the synopsis, and the gap between them.
    private static var informationWidth: CGFloat { 300 }
    private static var columnGap: CGFloat { 48 }
    /// The widest the synopsis and the trailer's panel run, so their lines stay readable on a wide window.
    private static var detailsMax: CGFloat { TitleHero.macDetailsWidth }

    /// The page's width less its margins.
    private var contentWidth: CGFloat { max(0, size.width - contentMargin * 2) }
    private var hasTwoColumns: Bool { contentWidth >= Self.twoColumnWidth }
    /// The synopsis and the trailer's panel share this width. The information follows the cast on the page, so it takes no column here.
    private var detailsWidth: CGFloat {
        min(Self.detailsMax, contentWidth)
    }

    /// The trailer's panel fades in and grows from its top edge, so the synopsis moves down with it rather than jumping.
    private static var trailerTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
    }

    @ViewBuilder
    var body: some View {
        hero
        if showsDetails {
            details
                .transition(.opacity)
        }
    }

    /// The picture across the window, with the title and the controls over its lower left edge. The title's scores are the linked buttons
    /// under the overview, and nowhere else on the page.
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            HeroPicture(slot: pictureSlot, isRevealed: isRevealed, contentMode: .fill, alignment: .center, preview: model.preview,
                        standInFromBackdrop: true, usesSystemSpinner: true)
            // Darker on the left, where the text sits, so the title and the buttons read over the picture.
            LinearGradient(stops: [
                .init(color: .black.opacity(0.85), location: 0),
                .init(color: .black.opacity(0.35), location: 0.5),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            .allowsHitTesting(false)
            // The fade starts lower than it did, so more of the picture shows above it before it fades into the page.
            BottomFade(length: 0.42)
            textColumn
        }
        // The full width of the page, from the sidebar's edge to the window's.
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
        .clipped()
    }

    /// The title, the metadata line and, once the details show, the overview and the ratings, then the actions: one column over the
    /// picture's lower left edge, in the order the Mac's title page sets them.
    private var textColumn: some View {
        VStack(alignment: .leading, spacing: TitleHero.logoTextGap) {
            titleArt
            metaLine
            if showsDetails {
                overview
                // The buttons stay over the picture. The reviews a tap opens sit under the hero, in the details, so the hero's clipping
                // cannot cut them off.
                RatingButtonsRow(item: model.detail.preview, startsLoading: model.hasSettledHero,
                                 openSite: model.openedReviews?.site, isLoading: model.reviewsLoading) { site, url, isSearch in
                    model.toggleReviews(site, url: url, isSearch: isSearch)
                }
                .padding(.bottom, Theme.Spacing.s)
            }
            controls
        }
        .frame(maxWidth: Self.textWidth, alignment: .leading)
        .padding(.leading, contentMargin)
        // Sit directly on the hero's lower edge so the logo, overview, ratings and actions move down together.
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
    }

    /// The metadata line, the same text as iPhone's, set over the picture's left edge. Like iPhone's, it drops genres before the rating.
    private var metaLine: some View {
        // Compact and left aligned, joined by dots: the spread line put its parts across the whole hero width.
        MetaLine(model.heroMetaLine, genres: model.heroMetaGenres, identifier: "detail.metaLine")
    }

    /// The overview, cut to three lines and not expandable: its full text, and More, are in the details below the hero.
    @ViewBuilder
    private var overview: some View {
        if let description = model.detail.preview.description, !description.isEmpty {
            JustifiedText(text: description, color: UIColor.white.withAlphaComponent(0.85), lineLimit: 3, isTruncated: $overviewIsCut)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("detail.overview")
        }
    }

    private var titleArt: some View {
        HeroTitleArt(name: model.detail.name, slot: logoSlot, alignment: .leading, compact: false, logoBox: Self.logoBox)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Hidden rather than removed, so the layout does not move when the title appears.
            .opacity(isRevealed ? 1 : 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.detail.name)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("detail.title")
    }

    /// Beneath the hero: the trailer's panel and the synopsis in one column, and the information beside them on a wide window or under
    /// them on a narrow one. One layout serves both widths, so the trailer's player keeps its place in the view tree when the window
    /// crosses the two-column width; a different container there would rebuild the player during playback.
    @ViewBuilder
    private var details: some View {
        layout {
            // With no trailer and an overview that fits above, the column would be empty, so the information leads instead.
            if model.trailer.showsPanel || overviewIsCut || model.openedReviews != nil { detailsColumn }
            information
                .frame(maxWidth: hasTwoColumns ? Self.informationWidth : Self.detailsMax, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, contentMargin)
        .padding(.top, Theme.Spacing.xxl)
    }

    /// Side by side on a wide page, stacked on a narrow one.
    private var layout: AnyLayout {
        hasTwoColumns
            ? AnyLayout(HStackLayout(alignment: .top, spacing: Self.columnGap))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.xl))
    }

    /// The trailer's panel, when it has one to show, above the synopsis. The panel is the same view the iPhone page places above the
    /// synopsis, so the two read in the same order.
    private var detailsColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if model.trailer.showsPanel {
                trailer(detailsWidth)
                    .transition(Self.trailerTransition)
            }
            // Placed after the trailer's panel, so that panel keeps its place in the view tree while reviews open.
            if let reviews = model.openedReviews {
                DetailReviewsPanel(reviews: reviews, shown: model.shownReviews, item: model.detail.preview, isLoading: model.reviewsLoading,
                                   onLoaded: model.reviewsDidLoad, onClose: model.closeReviews)
            }
            if overviewIsCut { synopsis }
        }
        .frame(width: detailsWidth, alignment: .leading)
    }
}
#endif
#endif
