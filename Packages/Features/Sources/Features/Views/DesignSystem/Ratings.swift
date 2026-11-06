#if canImport(UIKit)
import SwiftUI
import StremioKit

/// Letterboxd's mark: three small overlapping dots. Drawn, not an image, so it needs no brand assets and stays crisp at any size.
struct LetterboxdMark: View {
    var dot: CGFloat = 8
    /// Draws the three dots in Letterboxd's colours whatever the setting says (posters always do).
    var keepsColour = false
    @Environment(PosterRatingsStore.self) private var store: PosterRatingsStore?

    var body: some View {
        HStack(spacing: -dot * 0.34) {
            mark(Color(red: 1.0, green: 0.50, blue: 0.0))
            mark(Color(red: 0.0, green: 0.88, blue: 0.33))
            mark(Color(red: 0.25, green: 0.74, blue: 0.96))
        }
        .frame(width: dot * 2.32, height: dot)
        .accessibilityHidden(true)
    }

    /// Its own colour when coloured logos are on; otherwise the surrounding text colour, with a thin edge so the overlapping dots stay apart.
    @ViewBuilder private func mark(_ colour: Color) -> some View {
        if keepsColour || store?.showsColouredLogos ?? false {
            Circle().fill(colour)
        } else {
            Circle().overlay(Circle().stroke(.black.opacity(0.35), lineWidth: dot * 0.08))
        }
    }
}

/// The first two available scores, with their site's mark. Meant to sit on artwork over a dark backdrop.
struct RatingsLine: View {
    let ratings: TitleRatings
    var font: Font = .caption.weight(.semibold)
    var sites: [ReviewSite]?

    var body: some View {
        if !ratings.isEmpty {
            HStack(spacing: 7) {
                ForEach(sites ?? ratings.posterSites) { site in
                    if let score = ratings.shortText(for: site) {
                        HStack(spacing: 3) {
                            if site == .letterboxd {
                                LetterboxdMark(dot: 7)
                            } else {
                                ReviewSiteIcon(site: site, size: 12)
                            }
                            Text(score)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(site.name) rating \(score)")
                    }
                }
            }
            .font(font)
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
    }
}

/// The ratings of one title as a small floating pill over the bottom-left of a poster: dark, very translucent, inset from the
/// edges, sized to its contents, so the artwork stays unobstructed. Each score is led by its provider's own colours. Landscape artwork
/// (the hero and the title page) keeps its pill in the bottom-right corner. With marks on, the pill ends with the 4K or Blu-ray mark of
/// a film's best release, or else the logo of the service the title streams on. The mark can instead sit on its own in another corner
/// (`PosterMarkPlacement`, top right by default), and does when ratings are off. On its own it is sized to the card (see `markHeight`).
/// Reads the environment's `PosterRatingsStore`; draws
/// nothing without one, when both are switched off, or while nothing is known. Only this view observes the title's entry, so a rating
/// that arrives late redraws one poster.
struct PosterRatingsOverlay: View {
    let item: MetaPreview
    var isLandscape = false
    /// False holds the lookup back until the screen allows it (the title page waits for its hero).
    var startsLoading = true
    /// False leaves the mark to the metadata line beside the artwork (the landscape spotlight's), so it is not drawn twice.
    var showsMark = true
    @Environment(PosterRatingsStore.self) private var store: PosterRatingsStore?
    @Environment(\.layoutMetrics) private var metrics
    /// The card's shorter side, which sizes a mark on its own.
    @State private var cardSide: CGFloat = 0

    var body: some View {
        if let store, store.isEnabled || store.showsBestDisc && showsMark {
            let ratings = store.ratings(for: item)
            let sites: [ReviewSite] = !store.isEnabled ? []
                : isLandscape ? [ReviewSite.imdb, .letterboxd].filter { ratings.shortText(for: $0) != nil } : ratings.posterSites
            let mark = store.showsBestDisc && showsMark ? ratings.mark : nil
            let ratingsCorner: Alignment = isLandscape ? .bottomTrailing : .bottomLeading
            let markCorner = Self.corner(of: store.markPlacement) ?? ratingsCorner
            let joinsRatings = markCorner == ratingsCorner
            ZStack {
                if !sites.isEmpty {
                    placed(RatingPill(ratings: ratings, sites: sites, mark: joinsRatings ? mark : nil), in: ratingsCorner)
                }
                if let mark, !joinsRatings || sites.isEmpty {
                    placed(markOnItsOwn(mark), in: markCorner)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { min($0.size.width, $0.size.height) } action: { cardSide = $0 }
            .task(id: "\(item.identity):\(store.reviewServicesRevision):\(startsLoading)") {
                guard startsLoading else { return }
                _ = store.ratings(for: item)
            }
        }
    }

    /// The mark's height on its own: a twelfth of the card's shorter side, so it grows and shrinks with Card size, but never under
    /// 10 points, where a disc logo's lettering stops reading, nor over 18.
    private var markHeight: CGFloat { min(max((cardSide / 12).rounded(), 10), 18) }

    /// A disc logo on the pill's dark glass, so its white lettering reads on any artwork; a streamer's logo, already its own coloured
    /// tile, bare.
    @ViewBuilder
    private func markOnItsOwn(_ mark: TitleMark) -> some View {
        let height = markHeight
        switch mark {
        case .disc:
            TitleMarkView(mark: mark, height: height)
                .padding(.horizontal, height * 0.5)
                .padding(.vertical, height * 0.2)
                .background(.black.opacity(0.28),
                            in: RoundedRectangle(cornerRadius: height * 0.6 * metrics.cornerScale(for: .filters), style: .continuous))
        case .streamer:
            TitleMarkView(mark: mark, height: height)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
    }

    private func placed(_ badge: some View, in corner: Alignment) -> some View {
        badge
            .padding(Theme.Spacing.s - 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private static func corner(of placement: PosterMarkPlacement) -> Alignment? {
        switch placement {
        case .withRatings: nil
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }
}

/// The floating rating pill: each site's coloured mark, then its score in bold white, then the title's disc or streamer mark, on a dark, very
/// transparent rounded rectangle with no edge. Small, so it reads as a tag on the artwork; it is only as wide as its contents.
private struct RatingPill: View {
    @Environment(\.layoutMetrics) private var metrics
    let ratings: TitleRatings
    let sites: [ReviewSite]
    var mark: TitleMark?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(sites) { site in
                if let score = ratings.shortText(for: site) {
                    HStack(spacing: 3) {
                        if site == .letterboxd {
                            LetterboxdMark(dot: 5, keepsColour: true)
                        } else {
                            ReviewSiteIcon(site: site, size: 8, keepsColour: true)
                        }
                        Text(score)
                            .font(.system(size: 10, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)
                }
            }
            if let mark { TitleMarkView(mark: mark, height: 10) }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 6 * metrics.cornerScale(for: .filters), style: .continuous))
    }
}

/// The one mark a title shows: its film's best disc, else the service it streams on.
enum TitleMark: Equatable {
    case disc(BestDiscFormat)
    case streamer(TMDbWatchService)

    /// What VoiceOver reads for it.
    var spokenName: String {
        switch self {
        case .disc(let format): format == .uhdBluRay ? "4K Blu-ray" : "Blu-ray"
        case .streamer(let service): "On \(service.name)"
        }
    }
}

extension TitleRatings {
    var mark: TitleMark? { bestDisc.map(TitleMark.disc) ?? streamer.map(TitleMark.streamer) }
}

/// A disc mark, or a streamer's logo as a small rounded square a little taller than the disc marks, so the two read alike in a line.
struct TitleMarkView: View {
    let mark: TitleMark
    var height: CGFloat = 10

    var body: some View {
        switch mark {
        case .disc(let format):
            BestDiscMark(format: format, height: height)
        case .streamer(let service):
            let side = (height * 1.3).rounded()
            if let logo = service.logo {
                ArtworkImage(url: logo, title: service.name, maxPixelSize: side * 4, contentMode: .fit)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Text(service.name)
                    .font(.system(size: height, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The title's mark as the store knows it, for a line that shows it beside text (the title page's metadata line). Only this view
/// observes the title's entry, so a mark that arrives late redraws the line alone. Nil while marks are off or nothing is known.
struct TitleMarkReader<Content: View>: View {
    let item: MetaPreview
    @ViewBuilder let content: (TitleMark?) -> Content
    @Environment(PosterRatingsStore.self) private var store: PosterRatingsStore?

    var body: some View {
        if let store, store.showsBestDisc {
            content(store.ratings(for: item).mark)
        } else {
            content(nil)
        }
    }
}

/// The Ultra HD Blu-ray or Blu-ray Disc mark of a film's best release, in white, the logos the stream rows use.
struct BestDiscMark: View {
    let format: BestDiscFormat
    var height: CGFloat = 10

    var body: some View {
        Image(format == .uhdBluRay ? "StreamLogoUHDBluRay" : "StreamLogoBluRay")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(.white)
            .accessibilityHidden(true)
    }
}

/// Local official marks, so opening a screen does not make five extra image requests.
struct ReviewSiteIcon: View {
    let site: ReviewSite
    var size: CGFloat = 24
    /// Draws the official colours whatever the setting says (posters always do).
    var keepsColour = false
    @Environment(PosterRatingsStore.self) private var store: PosterRatingsStore?

    /// The official colours only when the user asks for them; otherwise the mark takes the surrounding text colour.
    var body: some View {
        Image(assetName)
            .resizable()
            .renderingMode(keepsColour || store?.showsColouredLogos ?? false ? .original : .template)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var assetName: String {
        switch site {
        case .imdb: "ReviewIMDb"
        case .letterboxd: "ReviewLetterboxd"
        case .rottenTomatoes: "ReviewRottenTomatoes"
        case .metacritic: "ReviewMetacritic"
        case .tmdb: "ReviewTMDB"
        }
    }
}

/// The title's scores as small buttons, for the line under its name on the detail page: a site's icon, then its score, in a small
/// flat panel-grey capsule, as the review panels are. A tap calls `onOpen`, which shows that site's reviews on the page, under the ratings.
/// IMDb is always there (its icon alone until a score arrives, so the link is never lost); every other site appears only once it
/// has a genuine score, so an unrated title shows one button, not five.
/// Meant to sit over artwork, so the text is white.
struct RatingButtonsRow: View {
    let item: MetaPreview
    /// False holds the lookup back until the screen allows it (the title page waits for its hero).
    var startsLoading = true
    /// The site whose reviews are open under the ratings, so its button can show it is open.
    var openSite: ReviewSite?
    /// True while the open site's reviews page loads, so its rating shows a spinner.
    var isLoading = false
    /// Shows the site's reviews for this title, or its search: the site, its link, and whether the link is a search.
    let onOpen: (ReviewSite, URL, Bool) -> Void
    @Environment(PosterRatingsStore.self) private var store: PosterRatingsStore?

    /// On a Mac the row keeps a button's natural width however wide the window is (120 pt a site, left-aligned); a phone fills its row.
    private static func maxRowWidth(forSites count: Int) -> CGFloat {
        #if targetEnvironment(macCatalyst)
        CGFloat(count) * 120
        #else
        .infinity
        #endif
    }

    var body: some View {
        if let store {
            let ratings = store.ratings(for: item)
            VStack(spacing: 8) {
                buttons(ratings: ratings)
                if let issue = store.reviewServiceIssue {
                    Text(issue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("detail.reviews.issue")
                }
            }
            .task(id: "\(item.identity):\(store.reviewServicesRevision):\(startsLoading)") {
                guard startsLoading else { return }
                _ = store.ratings(for: item, includeReviews: true)
            }
        } else {
            buttons(ratings: nil)
        }
    }

    private func buttons(ratings: TitleRatings?) -> some View {
        // Rotten Tomatoes and Metacritic always have a button: their reviews are read from the site itself, so a score is not needed. They sit
        // at the far right, after the other sites.
        // Rotten Tomatoes and Metacritic are for films only: a show has no button for either.
        let shown = ReviewSite.allCases.filter { site in
            if ReviewPageReader.supports(site) { return item.type == "movie" }
            return site == .imdb || ratings?.shortText(for: site) != nil
        }
        let sites = shown.filter { !ReviewPageReader.supports($0) } + shown.filter { ReviewPageReader.supports($0) }
        let showsLinkIcon = sites.count <= 4
        return GeometryReader { geometry in
            // A divider stands between each two buttons, with the same gap on either side of it as between the buttons themselves.
            let dividers = CGFloat(max(0, sites.count - 1))
            let gap = min(6, max(4, (geometry.size.width - CGFloat(sites.count) * 64 - dividers) / max(1, dividers * 2)))
            let pillWidth = (geometry.size.width - dividers * (gap * 2 + 1)) / CGFloat(sites.count)
            let inset = min(10, max(2, (pillWidth - 54) / 2))
            HStack(spacing: gap) {
                ForEach(sites) { site in
                    if let url = site.url(for: item, tmdbURL: ratings?.tmdbURL) {
                        if site != sites.first {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.4))
                                .frame(width: 1, height: 20)
                                .accessibilityHidden(true)
                        }
                        let isSearch = site.isSearch(for: item, tmdbURL: ratings?.tmdbURL)
                        RatingButton(site: site, score: ratings?.shortText(for: site), isSearch: isSearch, title: item.name,
                                     isOpen: site == openSite, isLoading: isLoading && site == openSite,
                                     horizontalInset: inset, showsLinkIcon: showsLinkIcon) {
                            onOpen(site, site.reviewsURL(for: item, tmdbURL: ratings?.tmdbURL) ?? url, isSearch)
                        }
                    }
                }
            }
        }
        .frame(height: 28)
        .frame(maxWidth: Self.maxRowWidth(forSites: sites.count), alignment: .leading)
        .accessibilityIdentifier("detail.reviews")
    }
}

/// One small rating button: the site's icon, then the score. Without a score it is the icon alone. A tap opens the site's reviews on the
/// page, under the buttons, so its chevron points down, or up while those reviews are open; an open site's button is lit.
struct RatingButton: View {
    @Environment(\.layoutMetrics) private var metrics
    let site: ReviewSite
    let score: String?
    /// True when the link is a search on the site, not the title's own page.
    let isSearch: Bool
    let title: String
    var isOpen = false
    /// True while this rating's reviews page loads.
    var isLoading = false
    var horizontalInset: CGFloat = 10
    var showsLinkIcon = false
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 5) {
                ReviewSiteIcon(site: site, size: 15)
                    .foregroundStyle(.white)
                if let score {
                    Text(score)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                // While the page loads, the rating shows a spinner in place of its chevron.
                if isLoading {
                    Spinner().controlSize(.mini)
                } else if showsLinkIcon || ((site == .imdb || ReviewPageReader.supports(site)) && score == nil) {
                    // After the score, a little greyed, so it reads as a control rather than as part of the rating.
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, horizontalInset)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(isOpen ? Theme.surfaceStrong : Theme.surface, in: ScaledCapsule(scale: metrics.cornerScale(for: .actionButtons)))
            .contentShape(ScaledCapsule(scale: metrics.cornerScale(for: .actionButtons)))
            .pointerInteraction(cornerRadius: 999 * metrics.cornerScale(for: .actionButtons))
            .pointerFeedback()
        }
        .buttonStyle(.plain)
        .titleTapHaptic(.buttons)
        .help(isSearch ? "Search \(site.name) for \(title) below" : "Show \(title) on \(site.name) below")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(score.map { "\(site.name) \($0)" } ?? site.name)
        .accessibilityHint(isSearch ? "Shows a \(site.name) search for this title below" : "Shows this title's reviews on \(site.name) below")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .accessibilityIdentifier("detail.reviews.\(site.rawValue)")
    }
}
#endif
