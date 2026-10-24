#if canImport(UIKit)
import StremioKit
import SwiftUI

/// Every shared component on one screen, for looking at the design system in one place.
/// Reached with the launch route `gallery` or `gallery:<section>` (`scripts/snapshot.sh gallery:cards out.png`); not linked from
/// the app's own UI. A section name shows only that section, so each one fits a picture. It lays out with the metrics of the
/// window it is in, so the phone picture shows the phone layout and `--mac` the Mac one.
struct DesignGalleryView: View {
    var section: String?
    @Environment(\.layoutMetrics) private var metrics
    @State private var ratings = PosterRatingsStore()

    private static let sectionNames = ["cards", "rows", "chips", "states"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.shelfSpacing) {
                layoutCaption
                if shows("cards") { cards }
                if shows("rows") { rows }
                if shows("chips") { chips }
                if shows("states") { states }
                if let section, !Self.sectionNames.contains(section.lowercased()) {
                    Text("No gallery section named \"\(section)\". Sections: \(Self.sectionNames.joined(separator: ", ")).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, metrics.pageMargin)
                }
            }
            .padding(.vertical, Theme.Spacing.l)
        }
        .screenBackground()
        .navigationTitle("Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .environment(ratings)
        .task { Sample.fillLetterboxd(in: ratings) }
    }

    private func shows(_ name: String) -> Bool {
        guard let section else { return true }
        return section.lowercased() == name
    }

    private var layoutCaption: some View {
        let layout = metrics.isRegular ? "regular" : "compact"
        return caption("Layout \(layout): poster \(Int(metrics.posterWidth)) pt, wide card \(Int(metrics.wideCardWidth)) pt, "
            + "margin \(Int(metrics.pageMargin)) pt, shelf gap \(Int(metrics.shelfSpacing)) pt")
    }

    // MARK: - Cards

    /// Each row is either all captioned or all uncaptioned, and lists its tallest card first: a row takes its height from its
    /// first card.
    private var cards: some View {
        VStack(alignment: .leading, spacing: metrics.shelfSpacing) {
            sectionTitle("Cards")
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                caption("Poster shelf: no caption, IMDb and Letterboxd ratings, See All header")
                MediaRow("Top Movies", onSeeAll: {}) {
                    ForEach(Sample.all) { MediaCard(item: $0) }
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                caption("Poster sizes: large, medium, small")
                MediaRow("Sizes", hideTitle: true) {
                    MediaCard(item: Sample.interstellar, size: .large)
                    MediaCard(item: Sample.inception, size: .medium)
                    MediaCard(item: Sample.oppenheimer, size: .small)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                caption("Poster with a forced caption, and without ratings")
                MediaRow("Captioned", hideTitle: true) {
                    MediaCard(item: Sample.darkKnight, showsTitle: true)
                    MediaCard(item: Sample.breakingBad, showsTitle: true, showsRating: false)
                    MediaCard(item: Sample.gameOfThrones, showsTitle: true)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                caption("Landscape cards: title and a grey line")
                MediaRow("Landscape", hideTitle: true) {
                    ForEach(Sample.all) { MediaCard(item: $0, aspect: .wide) }
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                caption("Square cards")
                MediaRow("Square", hideTitle: true) {
                    MediaCard(item: Sample.gameOfThrones, aspect: .square)
                    MediaCard(item: Sample.oppenheimer, aspect: .square)
                    MediaCard(item: Sample.interstellar, aspect: .square)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                caption("Up Next: progress inside the art, grey line under")
                MediaRow("Up Next", onSeeAll: {}) {
                    ProgressCard(title: "Breaking Bad", subtitle: "S2 E5", artwork: Sample.artwork("tt0903747", "background"),
                                 logo: MetahubArtwork.logo(imdbID: "tt0903747"), fraction: 0.82, duration: 2820)
                    ProgressCard(title: "Inception", artwork: Sample.artwork("tt1375666", "background"),
                                 logo: MetahubArtwork.logo(imdbID: "tt1375666"), fraction: 0.35, duration: 8880)
                    ProgressCard(title: "Oppenheimer", artwork: Sample.artwork("tt15398776", "background"),
                                 logo: MetahubArtwork.logo(imdbID: "tt15398776"), fraction: 0.04, duration: 10800)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                caption("Category tiles: gradient, with a picture, and without a title")
                MediaRow("Categories", hideTitle: true) {
                    CollectionTile(title: "Action")
                    CollectionTile(title: "Drama", imageURL: Sample.artwork("tt0944947", "background"))
                    CollectionTile(title: "Sci-Fi")
                    CollectionTile(title: "Documentary")
                    CollectionTile(title: "Thriller", imageURL: Sample.artwork("tt0468569", "background"), hideTitle: true)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                caption("Tiles in other shapes")
                MediaRow("Shapes", hideTitle: true) {
                    CollectionTile(title: "Crime", aspect: .poster)
                    CollectionTile(title: "2010s", imageURL: Sample.artwork("tt1375666", "poster"), aspect: .square)
                    CollectionTile(title: "Comedy", aspect: .square)
                }
            }
        }
    }

    // MARK: - Rows

    private var rows: some View {
        VStack(alignment: .leading, spacing: metrics.shelfSpacing) {
            sectionTitle("Rows")
            MediaRow("Popular", subtitle: "Most watched this week", onSeeAll: {}) {
                ForEach(Sample.all) { MediaCardLink(item: $0) }
            }
            MediaRow("Recently Added") {
                ForEach(Sample.all) { MediaCardLink(item: $0, aspect: .wide) }
            }
            MediaRow("A Header Without See All") {
                ForEach(Sample.all) { MediaCardLink(item: $0, size: .small) }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                caption("Skeleton shelves while rows load: poster, landscape")
                SkeletonShelf()
                SkeletonShelf(aspect: .wide)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                caption("MediaGrid of posters")
                MediaGrid(items: Sample.all)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                caption("Grid of category tiles")
                LazyVGrid(columns: metrics.wideGridColumns, spacing: metrics.cardSpacing) {
                    ForEach(["Action", "Comedy", "Drama", "Horror", "Romance", "Documentary"], id: \.self) {
                        CollectionTile(title: $0).stretched()
                    }
                }
                .padding(.horizontal, metrics.pageMargin)
            }
        }
    }

    // MARK: - Chips

    private var chips: some View {
        VStack(alignment: .leading, spacing: metrics.shelfSpacing) {
            sectionTitle("Chips, badges and buttons")
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                caption("Filter chips: the selected one is a white capsule")
                ChipRow {
                    GlassChip("All", isSelected: true) {}
                    GlassChip("Movies", systemImage: "film") {}
                    GlassChip("Series", systemImage: "tv") {}
                    GlassChip("Documentary") {}
                }
            }
            block("Capability badges, and other badges") {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    CapabilityBadges(["4K", "Dolby Vision", "HDR10"])
                    HStack(spacing: Theme.Spacing.s) {
                        Badge("Watched", systemImage: "checkmark")
                        Badge("New", style: .accent)
                        Badge("Slow addon", style: .warning)
                    }
                }
            }
            block("Ratings on artwork: both, IMDb only, and the one-number badge") {
                HStack(alignment: .bottom, spacing: Theme.Spacing.m) {
                    ratingSwatch(imdb: 9, letterboxd: 4.5)
                    ratingSwatch(imdb: 8.3, letterboxd: nil)
                    ratingSwatch(imdb: nil, letterboxd: 1.9)
                    ZStack(alignment: .bottomLeading) {
                        Theme.placeholder.frame(width: 80, height: 40)
                        RatingBadge(9.0).padding(Theme.Spacing.s)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                }
            }
            block("Metadata line: nil parts are skipped") {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    MetaLine(["Drama", "2023", "2 hr 49 min"])
                    MetaLine(["2008–2013", nil, "Crime"])
                }
            }
            block("Buttons: one white primary action per screen") {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Button {} label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(.primaryAction)
                        .frame(maxWidth: metrics.isRegular ? 320 : .infinity)
                    HStack(spacing: Theme.Spacing.m) {
                        Button {} label: { Label("Resume", systemImage: "play.fill") }
                            .buttonStyle(.primaryActionCompact)
                        Button("Trailer") {}
                            .buttonStyle(.glassCapsule)
                        Button("Customize") {}
                            .buttonStyle(.glass)
                    }
                    HStack(spacing: Theme.Spacing.m) {
                        Button("Small") {}
                            .buttonStyle(.primaryActionCompact)
                            .controlSize(.small)
                        Button("Large") {}
                            .buttonStyle(.primaryActionCompact)
                            .controlSize(.large)
                    }
                }
            }
            block("Round action buttons with captions: off and on") {
                CircleActionRow {
                    CircleActionButton(title: "Add", systemImage: "plus", isOn: false, onTitle: "Added", onSystemImage: "checkmark") {}
                    CircleActionButton(title: "Add", systemImage: "plus", isOn: true, onTitle: "Added", onSystemImage: "checkmark") {}
                    CircleActionButton(title: "Watched", systemImage: "checkmark.circle", isOn: true) {}
                    CircleActionButton(title: "Trailer", systemImage: "play.rectangle") {}
                }
            }
        }
    }

    private func ratingSwatch(imdb: Double?, letterboxd: Double?) -> some View {
        ZStack(alignment: .bottomLeading) {
            Theme.placeholder
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                .frame(height: 30)
            RatingsLine(ratings: TitleRatings(id: "preview", imdb: imdb, letterboxd: letterboxd))
                .padding(.horizontal, 8)
                .padding(.bottom, 7)
        }
        .frame(width: metrics.posterWidth, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
    }

    // MARK: - States

    private var states: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            sectionTitle("States")
            caption("Empty state with an action")
            EmptyStateView("Nothing saved yet", systemImage: "bookmark", message: "Titles you save appear here.",
                           actionTitle: "Browse", action: {})
            caption("Inline error with retry")
            InlineErrorView("Cinemeta did not answer in time.", retry: {})
                .padding(.horizontal, metrics.pageMargin)
            caption("Error chips")
            WrappingStack {
                ErrorChip(text: "Torrentio: 503 Service Unavailable")
                ErrorChip(text: "Cinemeta: timed out")
            }
            .padding(.horizontal, metrics.pageMargin)
            caption("Offline")
            OfflineBanner()
            caption("No addons yet")
            EmptyAddonsView(onOpenAddons: {})
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, metrics.pageMargin)
            .accessibilityAddTraits(.isHeader)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, metrics.pageMargin)
    }

    /// A caption over content that is inset to the page margin. The caption insets itself, so only the content is padded here.
    private func block<Content: View>(_ text: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            caption(text)
            content()
                .padding(.horizontal, metrics.pageMargin)
        }
    }
}

/// Real titles and artwork from Stremio's metadata host, so the gallery looks the way the app does with data.
private enum Sample {
    static let darkKnight = title("tt0468569", "movie", "The Dark Knight", "2008", 9.0, ["Action", "Crime"], "152 min")
    static let inception = title("tt1375666", "movie", "Inception", "2010", 8.8, ["Action", "Sci-Fi"], "148 min")
    static let interstellar = title("tt0816692", "movie", "Interstellar", "2014", 8.7, ["Sci-Fi", "Drama"], "169 min")
    static let breakingBad = title("tt0903747", "series", "Breaking Bad", "2008–2013", 9.5, ["Crime", "Drama"], nil)
    static let oppenheimer = title("tt15398776", "movie", "Oppenheimer", "2023", 8.3, ["Biography", "Drama"], "180 min")
    static let gameOfThrones = title("tt0944947", "series", "Game of Thrones", "2011–2019", 9.2, ["Fantasy", "Drama"], nil)

    static let all = [darkKnight, inception, interstellar, breakingBad, oppenheimer, gameOfThrones]

    /// Letterboxd for four of the six, so the gallery shows posters with both ratings and with IMDb alone.
    @MainActor
    static func fillLetterboxd(in store: PosterRatingsStore) {
        store.ratings(for: darkKnight).letterboxd = 4.4
        store.ratings(for: inception).letterboxd = 4.2
        store.ratings(for: interstellar).letterboxd = 4.3
        store.ratings(for: oppenheimer).letterboxd = 4.1
    }

    static func title(_ id: String, _ type: String, _ name: String, _ year: String, _ rating: Double, _ genres: [String],
                      _ runtime: String?) -> MetaPreview {
        MetaPreview(id: id, type: type, name: name, poster: artwork(id, "poster"), background: artwork(id, "background"),
                    releaseInfo: year, imdbRating: rating, genres: genres, runtime: runtime)
    }

    static func artwork(_ id: String, _ kind: String) -> URL? {
        URL(string: "https://images.metahub.space/\(kind)/medium/\(id)/img")
    }
}
#endif
