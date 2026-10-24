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
/// (the hero and the title page) keeps its pill in the bottom-right corner. Reads the environment's `PosterRatingsStore`; draws nothing
/// without one, when ratings are switched off, or while no scores are known. Only this view observes the title's entry, so a rating
/// that arrives late redraws one poster.
struct PosterRatingsOverlay: View {
    let item: MetaPreview
    var isLandscape = false
    /// False holds the lookup back until the screen allows it (the title page waits for its hero).
    var startsLoading = true
    @Environment(PosterRatingsStore.self) private var store: PosterRatingsStore?

    var body: some View {
        if let store, store.isEnabled {
            let ratings = store.ratings(for: item)
            let sites = isLandscape ? [ReviewSite.imdb, .letterboxd].filter { ratings.shortText(for: $0) != nil } : ratings.posterSites
            ZStack {
                if !sites.isEmpty {
                    RatingPill(ratings: ratings, sites: sites)
                        .padding(Theme.Spacing.s - 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isLandscape ? .bottomTrailing : .bottomLeading)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .task(id: "\(item.identity):\(store.reviewServicesRevision):\(startsLoading)") {
                guard startsLoading else { return }
                _ = store.ratings(for: item)
            }
        }
    }
}

/// The floating rating pill: each site's coloured mark, then its score in bold white, on a dark, very transparent rounded
/// rectangle with no edge. Small, so it reads as a tag on the artwork; it is only as wide as its contents.
private struct RatingPill: View {
    let ratings: TitleRatings
    let sites: [ReviewSite]

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
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
            .background(isOpen ? Theme.surfaceStrong : Theme.surface, in: Capsule())
            .contentShape(Capsule())
            .pointerInteraction(cornerRadius: 999)
        }
        .buttonStyle(.plain)
        .titleTapHaptic()
        .help(isSearch ? "Search \(site.name) for \(title) below" : "Show \(title) on \(site.name) below")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(score.map { "\(site.name) \($0)" } ?? site.name)
        .accessibilityHint(isSearch ? "Shows a \(site.name) search for this title below" : "Shows this title's reviews on \(site.name) below")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .accessibilityIdentifier("detail.reviews.\(site.rawValue)")
    }
}
#endif
