#if canImport(UIKit)
import StremioKit
import SwiftUI

/// A `.banner` widget: a large featured landscape title over a row of smaller cards once its items arrive. Until then, and when it has
/// nothing to show, the same header sits over a placeholder, a message or a retry, so the layout does not move when the cards arrive.
struct HeroBannerSection: View {
    let section: HomeViewModel.Section
    let row: RowConfiguration
    let onRetry: () -> Void
    /// The widget's menu, on everything but the cards under the featured title, whose hold plays them. Nil when the page puts the menu
    /// around the whole banner itself.
    var menu: AnyView?
    @Environment(AppRouter.self) private var router
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.headerSpacing) {
            if !section.widget.hideTitle {
                header
                    .modifier(OptionalContextMenu(menu: menu))
                    .padding(.horizontal, metrics.pageMargin)
            }
            content
        }
        .accessibilityIdentifier("board.row.\(section.widget.id)")
    }

    /// The title, which opens the whole list once the banner has items, like the header of a row.
    @ViewBuilder
    private var header: some View {
        if case .loaded(let items) = section.state, !items.isEmpty {
            SectionHeader(section.widget.title, onSeeAll: {
                Haptics.play(.titles)
                router.homePath.append(CatalogListRequest(title: section.widget.title, sources: [row.source], presentation: row.presentation))
            })
        } else {
            SectionHeader(section.widget.title)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section.state {
        case .idle, .loading:
            HeroBannerPlaceholder(size: row.presentation.cardStyle.cardSize)
                .modifier(OptionalContextMenu(menu: menu))
        case .loaded(let items) where !items.isEmpty:
            // Keyed by the featured title, so a reload that features another title doesn't keep the last one's looked-up picture.
            HeroBanner(items: items, row: row, menu: menu)
                .id(items[0].identity)
        case .loaded:
            Group {
                if let issue = section.issue {
                    IssueMessage(issue: issue)
                } else {
                    Text("Nothing here yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, metrics.pageMargin)
                }
            }
            .modifier(OptionalContextMenu(menu: menu))
        case .failed(let error):
            InlineErrorView(error.shortDescription, retry: onRetry)
                .padding(.horizontal, metrics.pageMargin)
                .modifier(OptionalContextMenu(menu: menu))
        }
    }
}

/// One rounded card: the featured title's backdrop on top with its logo and year at the bottom left, and the rest of the list as a
/// row of small landscape cards on a tray tinted by the same picture, blurred.
struct HeroBanner: View {
    let items: [MetaPreview]
    let row: RowConfiguration
    /// The widget's menu, on the featured title and the space between the cards under it (see `HeroBannerSection.menu`).
    var menu: AnyView?
    @Environment(\.layoutMetrics) private var metrics
    @State private var heroArtwork: TMDbArtwork?
    @State private var artworkChecked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BannerFeature(item: items[0], showsRating: row.presentation.showsRatings, heroArtwork: $heroArtwork, artworkChecked: $artworkChecked)
                .modifier(OptionalContextMenu(menu: menu))
            if items.count > 1 {
                let tray = MediaRow("", hideTitle: true, artworkItems: Array(items.dropFirst()), aspect: .wide,
                                    size: row.presentation.cardStyle.cardSize, cardWidth: cardWidth,
                                    usesBetterPosters: row.presentation.usesBetterPosters) {
                    ForEach(Array(items.dropFirst()), id: \.identity) { item in
                        MediaCardLink(item: item, aspect: .wide, size: row.presentation.cardStyle.cardSize,
                                      showsRating: row.presentation.showsRatings, width: cardWidth, subtitle: item.releaseInfo ?? " ",
                                      usesBetterPosters: row.presentation.usesBetterPosters)
                    }
                }
                Group {
                    if let menu { tray.shelfMenu { menu } } else { tray }
                }
                .padding(.top, Theme.Spacing.m)
                .padding(.bottom, Theme.Spacing.m)
            }
        }
        .environment(\.colorScheme, .dark)
        .background { tray }
        .clipShape(RoundedRectangle(cornerRadius: HeroBanner.cornerRadius * metrics.cornerScale(for: .artwork), style: .continuous))
        .padding(.horizontal, metrics.pageMargin)
    }

    static let cornerRadius: CGFloat = 20

    static func featureHeight(width: CGFloat, margin: CGFloat, isPhoneLandscape: Bool) -> CGFloat {
        min((width - margin * 2) * 9 / 16, isPhoneLandscape ? 180 : 260)
    }

    private var cardWidth: CGFloat { Self.cardWidth(metrics, size: row.presentation.cardStyle.cardSize) }

    /// The small cards of the tray: about a third of the banner's width on a phone, a little under a shelf poster's width.
    static func cardWidth(_ metrics: LayoutMetrics, size: CardSize) -> CGFloat {
        (metrics.posterWidth * 0.96 * size.scale).rounded()
    }

    /// The featured picture, blurred and darkened, so the tray picks up the colours above it. It waits for the same lookup as the feature
    /// and decodes at the feature's size, so the one download and decode serve both and no poster loads beside it.
    private var tray: some View {
        ArtworkImage(url: artworkChecked ? (heroArtwork?.backdrop ?? items[0].background ?? MetahubArtwork.background(imdbID: items[0].id)) : nil,
                     maxPixelSize: 2048, contentMode: .fill, imageAlignment: .bottom)
            .blur(radius: 40)
            .overlay { Color.black.opacity(0.55) }
            .background(Theme.surface)
    }
}

/// The featured title of a banner: its backdrop, with its logo (or name) and year at the bottom left and a soft fade into the tray.
private struct BannerFeature: View {
    let item: MetaPreview
    let showsRating: Bool
    @Binding var heroArtwork: TMDbArtwork?
    @Binding var artworkChecked: Bool
    @Environment(AppRouter.self) private var router
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.heroContainerWidth) private var containerWidth
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape
    @Environment(\.zoomNamespace) private var zoomNamespace
    @Environment(PosterRatingsStore.self) private var ratings
    /// Loads the title's logo as the spotlight does: trimmed, made light when it is dark, and kept for the session.
    @State private var hero = HeroLoader()

    /// The spotlight's logo for the title: the catalog's, else TMDb's from the same lookup as the backdrop.
    private var logoURL: URL? { item.logo ?? heroArtwork?.logo }
    private var logoSlot: HeroSlot { hero.slot(url: logoURL, maxPixelSize: HeroLoader.logoPixelSize, lookupFinished: artworkChecked) }

    var body: some View {
        let sourceID = "banner/\(item.identity)"
        let openTitle = {
            Haptics.play(.titles)
            router.homePath.append(TitleDestination(preview: item, sourceID: sourceID, artwork: heroArtwork,
                                                    artworkChecked: heroArtwork != nil))
        }
        Color.clear
            .frame(height: HeroBanner.featureHeight(width: containerWidth, margin: metrics.pageMargin, isPhoneLandscape: isPhoneLandscape))
            .frame(maxWidth: .infinity)
            .overlay {
                ArtworkImage(url: artworkChecked ? (heroArtwork?.backdrop ?? item.background ?? MetahubArtwork.background(imdbID: item.id)) : nil,
                             title: item.name, maxPixelSize: 2048, contentMode: .fill, imageAlignment: .top)
            }
            .clipped()
            // Marked before the fade, so the zoom carries a solid picture. The fade is see-through at the bottom, and there the zoom
            // showed its own black instead of the tray behind the banner, until the zoom ended.
            .zoomSource(id: sourceID, in: zoomNamespace, cornerRadius: HeroBanner.cornerRadius * metrics.cornerScale(for: .artwork))
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0.8), .init(color: .black.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                caption
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            #if targetEnvironment(macCatalyst)
            .heroPointerHighlight(cornerRadius: HeroBanner.cornerRadius * metrics.cornerScale(for: .artwork))
            #else
            .pointerInteraction(cornerRadius: HeroBanner.cornerRadius * metrics.cornerScale(for: .artwork))
            #endif
            .onTapGesture(perform: openTitle)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.name)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openTitle() }
            .task(id: ratings.reviewServicesRevision) {
                let loaded = await ratings.heroArtwork(for: item)
                guard !Task.isCancelled else { return }
                heroArtwork = loaded
                artworkChecked = true
            }
            .task(id: logoURL) {
                await hero.load(picture: nil, pictureSize: 0, logo: logoURL, logoSize: HeroLoader.logoPixelSize)
            }
    }

    /// The logo's box: the spotlight's, kept to half the banner's width and a third of its picture's height.
    private var logoBox: CGSize {
        let width = containerWidth - metrics.pageMargin * 2
        let height = HeroBanner.featureHeight(width: containerWidth, margin: metrics.pageMargin, isPhoneLandscape: isPhoneLandscape)
        return CGSize(width: min(HeroLogo.box.width, (width * 0.5).rounded()), height: min(HeroLogo.box.height, (height / 3).rounded()))
    }

    /// The title's logo, or its name in bold when it has none, and the year (and the rating, when shown) in a lighter line under it.
    private var caption: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch logoSlot {
            case .ready(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: logoBox.width, height: logoBox.height, alignment: .bottomLeading)
            case .pending:
                // Holds the logo's place while it loads, so the year does not move when it arrives.
                Color.clear.frame(width: logoBox.width, height: logoBox.height)
            case .none:
                Text(item.name)
                    .font(.title2.bold())
                    .lineLimit(2)
            }
            Text([item.releaseInfo, rating].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rating: String? {
        showsRating ? item.imdbRating.map { "★ \(ScoreText.wholeScore($0))" } : nil
    }
}

/// The grey stand-in for a banner, the same shape as the loaded card, shimmering while the items load: the feature's height over the tray's
/// card placeholders, at the tray's card width, gaps and margins.
struct HeroBannerPlaceholder: View {
    /// The widget's card size, which the tray's cards follow.
    var size: CardSize = .medium
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.heroContainerWidth) private var containerWidth
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: HeroBanner.featureHeight(width: containerWidth, margin: metrics.pageMargin, isPhoneLandscape: isPhoneLandscape))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: metrics.cardSpacing) {
                    ForEach(0..<6, id: \.self) { _ in
                        CardPlaceholder(aspect: .wide, size: size, width: HeroBanner.cardWidth(metrics, size: size),
                                        fill: AnyShapeStyle(Theme.surfaceStrong))
                    }
                }
            }
            .scrollIndicators(.hidden, axes: .horizontal)
            .scrollDisabled(true)
            .contentMargins(.horizontal, metrics.pageMargin, for: .scrollContent)
            .padding(.vertical, Theme.Spacing.m)
        }
        .frame(maxWidth: .infinity)
        .background { Rectangle().fill(Theme.surface) }
        .shimmering()
        .clipShape(RoundedRectangle(cornerRadius: HeroBanner.cornerRadius * metrics.cornerScale(for: .artwork), style: .continuous))
        .padding(.horizontal, metrics.pageMargin)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}
#endif
