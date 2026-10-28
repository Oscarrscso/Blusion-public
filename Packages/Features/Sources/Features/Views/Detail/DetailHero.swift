#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit
import Observation

/// The title page's hero. In portrait the picture runs under the bar with the logo low on it, and the controls, the trailer's panel and the
/// synopsis sit beneath it. In landscape the backdrop fills the hero's trailing side and the title, controls, full overview and ratings sit
/// over its leading edge, with the trailer's panel and any open reviews under them. The trailer's panel is there only while it has one to
/// show. The page supplies the controls, the panel and the synopsis, so the state they keep stays on the page and survives a rotation.
struct DetailHero<Controls: View, TrailerPanel: View, Synopsis: View>: View {
    let model: DetailViewModel
    let scroll: DetailHeroScrollState
    let size: CGSize
    let contentMargin: CGFloat
    /// The least space kept clear above the logo.
    let topInset: CGFloat
    let pictureSlot: HeroSlot
    let logoSlot: HeroSlot
    let isRevealed: Bool
    let hidesLogo: Bool
    /// False hides the trailer's panel, the synopsis and the ratings row, leaving the picture, the logo and the controls. The page then
    /// shows its streams under them.
    let showsDetails: Bool
    @ViewBuilder let controls: Controls
    @ViewBuilder let trailer: TrailerPanel
    @ViewBuilder let synopsis: Synopsis
    @State private var renderedLogoHeight: CGFloat = TitleHero.logoMaxHeight
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.isLandscape) private var isLandscape

    /// Three parts in a row, so the trailer's panel is the same view in both orientations: turning the device while its player is full
    /// screen must not rebuild the player. Only the parts above and below it differ between portrait and landscape.
    @ViewBuilder
    var body: some View {
        if isLandscape {
            // Lift the complete landscape hero and its layout footprint together. Internal logo, metadata, action,
            // synopsis and ratings spacing stays unchanged, while the following sections rise with it.
            landscapeTop.padding(.top, -Self.landscapePageLift)
        } else {
            portraitTop
        }
        if showsDetails && model.trailer.showsPanel {
            trailer
                .padding(.horizontal, contentMargin)
                // The same gap as the synopsis keeps from what is above it, in each orientation.
                .padding(.top, isLandscape ? Theme.Spacing.s : TitleHero.playRowGap)
                .transition(Self.trailerTransition)
        }
        if showsDetails {
            if isLandscape {
                landscapeBottom.transition(.opacity)
            } else {
                portraitBottom.transition(.opacity)
            }
        }
    }

    private var landscapeHeroHeight: CGFloat { TitleHero.landscapeHeroHeight(pageHeight: size.height) }

    /// Landscape: the backdrop on the trailing side, fading into the page on its leading side, with the title, the actions, the overview and
    /// the ratings in a column over its lower leading edge. The scores are the rating buttons here and nowhere else in the hero.
    private var landscapeTop: some View {
        VStack(alignment: .leading, spacing: TitleHero.logoTextGap) {
            titleArt(alignment: .leading)
            controls
            if showsDetails {
                landscapeOverview
                RatingButtonsRow(item: model.detail.preview, startsLoading: model.hasSettledHero,
                                 openSite: model.openedReviews?.site, isLoading: model.reviewsLoading) { site, url, isSearch in
                    model.toggleReviews(site, url: url, isSearch: isSearch)
                }
                .padding(.top, Theme.Spacing.xs)
            }
        }
        .frame(width: TitleHero.landscapeTextWidth(pageWidth: size.width), alignment: .leading)
        .padding(.leading, contentMargin)
        .padding(.top, Self.landscapeTopClearance)
        .padding(.bottom, TitleHero.landscapeContentBottomInset)
        // A minimum, not a fixed height: large text grows the hero rather than clipping it.
        .frame(maxWidth: .infinity, minHeight: landscapeHeroHeight, alignment: .bottomLeading)
        .background { landscapeArt }
    }

    /// The least space kept above the text column, clear of the floating back button.
    private static var landscapeTopClearance: CGFloat { 60 }
    /// Moves the whole landscape page upward without changing spacing within the hero.
    private static var landscapePageLift: CGFloat { Theme.Spacing.xl }
    /// Bias the landscape backdrop toward the trailing edge so its focal area sits farther from the text.
    private static var landscapeBackdropShift: CGFloat { 24 }

    /// The ground, an optional wash of the title's colour on the text side, and the backdrop pinned to the trailing edge. It runs to the
    /// top of the screen and under the side safe areas, so no strip of ground shows above it or beside the notch. As in portrait, a pull
    /// past the top stretches it up so no gap opens over it, and scrolling the page zooms it.
    private var landscapeArt: some View {
        let artWidth = TitleHero.landscapeArtWidth(heroHeight: landscapeHeroHeight, pageWidth: size.width)
        let tint = PlayColourStore.colour(hex: model.playColourHex)
        return ZStack(alignment: .trailing) {
            if let tint {
                LinearGradient(stops: [
                    .init(color: tint.opacity(0.22), location: 0),
                    .init(color: tint.opacity(0.08), location: 0.45),
                    .init(color: .clear, location: 0.75),
                ], startPoint: .leading, endPoint: .trailing)
                .transition(.opacity)
            }
            HeroPicture(slot: pictureSlot, isRevealed: isRevealed, contentMode: .fill, alignment: .center, preview: model.preview,
                        standInFromBackdrop: true, usesSystemSpinner: true)
                .frame(width: artWidth)
                .frame(maxHeight: .infinity)
                .modifier(LandscapeHeroZoom(scroll: scroll))
                .clipped()
                .mask {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.55), location: 0.25),
                        .init(color: .black, location: 0.45),
                    ], startPoint: .leading, endPoint: .trailing)
                }
                .offset(x: Self.landscapeBackdropShift)
            BottomFade(length: 0.42)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .modifier(LandscapeHeroPull(scroll: scroll))
        .animation(.smooth(duration: 0.3), value: model.playColourHex)
        .allowsHitTesting(false)
        .ignoresSafeArea(.container, edges: [.top, .horizontal])
    }

    /// Share portrait's folded, tappable synopsis and page-owned expansion state in landscape.
    private var landscapeOverview: some View {
        synopsis.accessibilityIdentifier("detail.overview")
    }

    /// Landscape, under the trailer's panel: the reviews opened from a rating. The synopsis already appears in the hero overview.
    @ViewBuilder
    private var landscapeBottom: some View {
        if let reviews = model.openedReviews {
            DetailReviewsPanel(reviews: reviews, shown: model.shownReviews, item: model.detail.preview, isLoading: model.reviewsLoading,
                               onLoaded: model.reviewsDidLoad, onClose: model.closeReviews)
                .padding(.horizontal, contentMargin)
                .padding(.top, Theme.Spacing.s)
        }
    }

    /// Portrait: the picture under the bar, with the logo low on it and the controls beneath.
    private var portraitTop: some View {
        let height = TitleHero.height(width: size.width, metrics: metrics)
        let visible = TitleHero.visibleHeight(height,
                                              logoHeight: TitleHero.logoHeight(logoSlot, hidden: hidesLogo, width: size.width - contentMargin * 2))
        return VStack(spacing: 0) {
            // Reserve artwork above the measured logo; all text and controls participate in normal vertical layout.
            Color.clear
                // Never less than the top safe area, so a tall logo or title pushes the page down rather than up into the status bar. The drop
                // is added after that floor, so the logo moves by the same amount in every case, and the fade with it.
                .frame(height: max(topInset, height - renderedLogoHeight - TitleHero.logoTextGap) + TitleHero.portraitDrop)
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                titleArt(alignment: .center)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { renderedLogoHeight = $0 }
                // The block below the logo sits close to it. The stack's own spacing is part of that gap.
                controls
                    .padding(.top, TitleHero.logoTextGap - Theme.Spacing.m)
            }
            .padding(.horizontal, contentMargin)
        }
        .background(alignment: .top) {
            // Own scroll state belongs to the artwork, not the title page: long series' episode rows stay untouched.
            DetailHeroScrollArtwork(slot: pictureSlot, isRevealed: isRevealed, preview: model.preview,
                                    width: size.width, heroHeight: height, visibleHeight: visible, scroll: scroll)
        }
    }

    /// Portrait: the synopsis, then the ratings row. The stack's spacing, here the padding above the block, is part of the gap above the
    /// synopsis.
    private var portraitBottom: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            // The same gap as the Play row keeps from the line above it, so the row sits evenly between the two.
            synopsis
                .padding(.top, TitleHero.playRowGap - Theme.Spacing.m)
            DetailRatings(model: model, startsLoading: model.hasSettledHero)
        }
        .padding(.top, Theme.Spacing.m)
        .padding(.horizontal, contentMargin)
    }

    /// The panel fades in and grows from its top edge, so the content below it moves down with it rather than jumping.
    private static var trailerTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
    }

    private func titleArt(alignment: Alignment) -> some View {
        HeroTitleArt(name: model.detail.name, slot: logoSlot, alignment: alignment, compact: isLandscape, hidden: hidesLogo)
            .frame(maxWidth: .infinity, alignment: alignment)
            // Hidden rather than removed, so the layout does not move when the title appears.
            .opacity(isRevealed ? 1 : 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.detail.name)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("detail.title")
    }
}

/// Scroll-driven rendering is isolated here, so moving a large show's page never invalidates its episode list,
/// trailers or buttons. The existing overscroll stretch is unchanged; ordinary page scrolling zooms the picture.
@MainActor
@Observable
final class DetailHeroScrollState {
    var offset: CGFloat = 0
}

private struct DetailHeroScrollArtwork: View {
    let slot: HeroSlot
    let isRevealed: Bool
    let preview: MetaPreview
    let width: CGFloat
    let heroHeight: CGFloat
    let visibleHeight: CGFloat
    let scroll: DetailHeroScrollState

    var body: some View {
        HeroPicture(slot: slot, isRevealed: isRevealed, contentMode: .fill, preview: preview, usesSystemSpinner: true)
            .modifier(DetailHeroScrollTransform(width: width, heroHeight: heroHeight,
                                                visibleHeight: visibleHeight, scroll: scroll))
    }
}

/// Landscape: a pull past the top grows the art upward by the pull, so the picture fills it (it is drawn to fill) and stays against the
/// top of the screen. Only this and `LandscapeHeroZoom` read the offset, so the art's content does not rebuild per scroll tick.
private struct LandscapeHeroPull: ViewModifier {
    let scroll: DetailHeroScrollState

    func body(content: Content) -> some View {
        content.padding(.top, -max(0, -scroll.offset))
    }
}

/// Landscape: scrolling the page down zooms the picture from its top, on the same curve as portrait.
private struct LandscapeHeroZoom: ViewModifier {
    let scroll: DetailHeroScrollState

    func body(content: Content) -> some View {
        let down = max(0, scroll.offset)
        content.scaleEffect(1 + 0.28 * (down / (down + 180)), anchor: .top)
    }
}

/// Only this modifier reads the offset. Its image content and the rest of the page do not rebuild per scroll tick.
private struct DetailHeroScrollTransform: ViewModifier {
    let width: CGFloat
    let heroHeight: CGFloat
    let visibleHeight: CGFloat
    let scroll: DetailHeroScrollState

    private var scrollPull: CGFloat { max(0, -scroll.offset) }
    private var scrollDown: CGFloat { max(0, scroll.offset) }

    func body(content: Content) -> some View {
        content
            .frame(width: width, height: TitleHero.pictureHeight(heroHeight) + scrollPull)
            // More visible early in a swipe; the curve has no abrupt stop while the artwork is on screen.
            .scaleEffect(1 + 0.28 * (scrollDown / (scrollDown + 180)), anchor: .top)
            .frame(height: visibleHeight + scrollPull, alignment: .top)
            .clipped()
            .overlay(alignment: .bottom) {
                BottomFade(length: TitleHero.fadeLength(height: heroHeight, visible: visibleHeight + scrollPull),
                           strength: TitleHero.fadeStrength)
                    .padding(.bottom, -TitleHero.fadeOverscan)
            }
            .offset(y: -scrollPull)
    }
}
#endif
