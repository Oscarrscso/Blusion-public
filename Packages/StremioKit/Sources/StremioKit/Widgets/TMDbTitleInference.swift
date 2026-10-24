import Foundation

extension TMDbDiscoverQuery {
    /// The query for a Fusion `tmdbDiscover` source. Fusion's exports carry no filters for these, so the filters are read from the
    /// widget's title (or the tile's, inside a collection): whether the list is of TV or films, the genres it names, a decade such as
    /// "1980s", and whether it asks for the newest, trending, classic, acclaimed or hidden-gem titles. Anything the title does not name is
    /// left open, so a title with no clues is the most popular films. Pure: nothing is requested.
    public static func inferred(fromTitle title: String) -> TMDbDiscoverQuery {
        // An apostrophe is dropped first, so "1980's" reads as "1980s".
        let words = titleWords(title)
        let text = " " + words.joined(separator: " ") + " "
        let has: (String) -> Bool = { word in words.contains(word) }

        // A title naming both films and TV reads as films: one query cannot hold both, and films are the widget's default.
        let namesTV = words.contains(where: { ["tv", "series", "show", "shows", "television"].contains($0) })
        let namesFilms = words.contains(where: { ["movie", "movies", "films"].contains($0) })
        let kind: Kind = namesTV && !namesFilms ? .series : .movie

        var genres: [Named] = []
        for clue in genreClues where clue.phrases.contains(where: { text.contains(" \($0) ") }) {
            guard let genre = kind == .movie ? clue.movie : clue.series, !genres.contains(where: { $0.id == genre.id }) else { continue }
            genres.append(genre)
        }

        var ordering: Ordering = .popular
        if has("trending") {
            ordering = has("today") ? .trendingToday : .trendingThisWeek
        } else if has("new") || has("newest") || has("latest") {
            ordering = .newest
        }

        // A decade in the title is the release window; "classic" alone reads as everything before 2000.
        var releasedFrom: String?
        var releasedTo: String?
        if let decade = words.lazy.compactMap(decadeStart).first {
            releasedFrom = "\(decade)-01-01"
            releasedTo = "\(decade + 9)-12-31"
        } else if has("classic") || has("classics") {
            releasedTo = "1999-12-31"
        }

        var minimumScore: Double?
        var minimumVotes: Int?
        if has("acclaimed") || has("critically") {
            minimumScore = 7.5
            minimumVotes = 1000
        } else if has("gem") || has("gems") {
            minimumScore = 7.0
            minimumVotes = 100
        }

        // Adult animation is animation TMDb tags "adult animation", as Fusion lists it: without the family titles (and for TV the kids'
        // shows), and without the anime and hentai the keyword also reaches. The genre alone leaves out shows such as The Simpsons.
        var excludedGenres: [Named] = []
        var keywords: [Named] = []
        var excludedKeywords: [Named] = []
        if namesAdultAnimation(title) {
            excludedGenres = adultAnimationExclusions(kind, namedGenres: genres)
            keywords = [TMDbDiscoverQuery.adultAnimationKeyword]
            excludedKeywords = TMDbDiscoverQuery.adultAnimationExcludedKeywords
        }

        return TMDbDiscoverQuery(kind: kind, ordering: ordering, genres: genres, keywords: keywords, excludedKeywords: excludedKeywords,
                                 minimumScore: minimumScore, minimumVotes: minimumVotes,
                                 releasedFrom: releasedFrom, releasedTo: releasedTo, excludedGenres: excludedGenres,
                                 spansBothKinds: !namesTV && !namesFilms && (has("animation") || has("animated")))
    }

    /// Whether a title names adult animation: "adult" then "animation" or "animated", in any case, and not negated. "Non-adult animation"
    /// and "no adult animation" name the other thing.
    static func namesAdultAnimation(_ title: String) -> Bool {
        let words = titleWords(title)
        return words.indices.contains { index in
            guard index + 1 < words.count, words[index] == "adult", ["animation", "animated"].contains(words[index + 1]) else { return false }
            return index == 0 || !["no", "not", "non", "without"].contains(words[index - 1])
        }
    }

    /// TMDb's "adult animation" keyword, which Fusion's adult animation list is built on, and the keywords it leaves out: anime and hentai.
    static let adultAnimationKeyword = Named(id: 161919, name: "adult animation")
    static let adultAnimationExcludedKeywords = [Named(id: 210024, name: "anime"), Named(id: 198385, name: "hentai")]
    /// TMDb's "kids" keyword. The Simpsons carries it, so an adult animation list must not leave it out.
    static let kidsKeyword = Named(id: 208349, name: "kids")

    /// The genres adult animation leaves out for a list of this kind: the family titles, and for TV the kids' shows as well. A genre the
    /// list already names is not left out.
    static func adultAnimationExclusions(_ kind: Kind, namedGenres: [Named]) -> [Named] {
        let family = Named(id: 10751, name: "Family")
        let all = kind == .movie ? [family] : [family, Named(id: 10762, name: "Kids")]
        return all.filter { excluded in !namedGenres.contains { $0.id == excluded.id } }
    }

    /// The title's words in lowercase, with apostrophes dropped first so "1980's" reads as "1980s", and punctuation splitting words.
    private static func titleWords(_ title: String) -> [String] {
        title.lowercased().filter { $0 != "'" && $0 != "\u{2019}" }
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// The first year of a decade written "1980s" or "80s", or nil for any other word. A two-digit decade from 30 on is the 1900s, and
    /// any other is the 2000s.
    private static func decadeStart(_ word: String) -> Int? {
        guard word.hasSuffix("s"), let value = Int(word.dropLast()), value % 10 == 0 else { return nil }
        switch word.count {
        case 3: return value >= 30 ? 1900 + value : 2000 + value
        case 5 where value >= 1900: return value
        default: return nil
        }
    }

    /// The genre a title's words name, as TMDb's movie and TV ids. A genre TV does not have is nil for TV.
    struct GenreClue: Sendable {
        let phrases: [String]
        let movie: Named?
        let series: Named?
    }

    /// Whole words or phrases (lowercased, punctuation dropped) and the genre each means. TMDb's TV genres group some films' genres, so
    /// "Sci-Fi" is Science Fiction for films and Sci-Fi & Fantasy for TV.
    static let genreClues: [GenreClue] = [
        GenreClue(phrases: ["action"], movie: Named(id: 28, name: "Action"), series: Named(id: 10759, name: "Action & Adventure")),
        GenreClue(phrases: ["adventure"], movie: Named(id: 12, name: "Adventure"), series: Named(id: 10759, name: "Action & Adventure")),
        GenreClue(phrases: ["animation", "animated"], movie: Named(id: 16, name: "Animation"), series: Named(id: 16, name: "Animation")),
        GenreClue(phrases: ["comedy", "comedies"], movie: Named(id: 35, name: "Comedy"), series: Named(id: 35, name: "Comedy")),
        GenreClue(phrases: ["crime"], movie: Named(id: 80, name: "Crime"), series: Named(id: 80, name: "Crime")),
        GenreClue(phrases: ["documentary", "documentaries"], movie: Named(id: 99, name: "Documentary"),
                  series: Named(id: 99, name: "Documentary")),
        GenreClue(phrases: ["drama", "dramas"], movie: Named(id: 18, name: "Drama"), series: Named(id: 18, name: "Drama")),
        GenreClue(phrases: ["family"], movie: Named(id: 10751, name: "Family"), series: Named(id: 10751, name: "Family")),
        GenreClue(phrases: ["fantasy"], movie: Named(id: 14, name: "Fantasy"), series: Named(id: 10765, name: "Sci-Fi & Fantasy")),
        GenreClue(phrases: ["history"], movie: Named(id: 36, name: "History"), series: nil),
        GenreClue(phrases: ["horror"], movie: Named(id: 27, name: "Horror"), series: nil),
        GenreClue(phrases: ["mystery", "mysteries"], movie: Named(id: 9648, name: "Mystery"), series: Named(id: 9648, name: "Mystery")),
        GenreClue(phrases: ["romance", "romantic"], movie: Named(id: 10749, name: "Romance"), series: nil),
        GenreClue(phrases: ["science fiction", "sci fi", "scifi"], movie: Named(id: 878, name: "Science Fiction"),
                  series: Named(id: 10765, name: "Sci-Fi & Fantasy")),
        GenreClue(phrases: ["thriller", "thrillers"], movie: Named(id: 53, name: "Thriller"), series: nil),
        GenreClue(phrases: ["war"], movie: Named(id: 10752, name: "War"), series: Named(id: 10768, name: "War & Politics")),
        GenreClue(phrases: ["western", "westerns"], movie: Named(id: 37, name: "Western"), series: Named(id: 37, name: "Western")),
    ]
}

extension HomeWidget {
    /// A saved widget whose source is a Fusion `tmdbDiscover` list, which was kept as unsupported before its filters were read from the
    /// title. It is read the way an import reads one now, so a saved layout shows what a fresh import would. Other sources are unchanged.
    func readingSavedTMDbFilters() -> HomeWidget {
        var widget = self
        switch content {
        case .row(var row):
            row.source = row.source.readingSavedTMDbFilters(title: title)
            widget.content = .row(row)
        case .hero(var row):
            row.source = row.source.readingSavedTMDbFilters(title: title)
            widget.content = .hero(row)
        case .banner(var row):
            row.source = row.source.readingSavedTMDbFilters(title: title)
            widget.content = .banner(row)
        case .collection(var tiles):
            for index in tiles.indices {
                let tileTitle = tiles[index].title
                tiles[index].sources = tiles[index].sources.map { $0.readingSavedTMDbFilters(title: tileTitle) }
            }
            widget.content = .collection(tiles)
        case .continueWatching, .unsupported:
            break
        }
        return widget
    }
}

extension WidgetSource {
    fileprivate func readingSavedTMDbFilters(title: String) -> WidgetSource {
        switch self {
        case .unsupported(let kind) where kind == "tmdbDiscover":
            return .tmdbDiscover(TMDbDiscoverQuery.inferred(fromTitle: title))
        case .tmdbDiscover(var query) where TMDbDiscoverQuery.namesAdultAnimation(title):
            // A list saved before its title's adult animation left out the family titles, or named no keyword, is given them, as a Fusion title
            // reads them. A list that leaves out TMDb's "kids" keyword drops The Simpsons, which carries it, so that keyword is let back in: a
            // show's kids' show is already left out by its genre. Each step does nothing to a list that already has it.
            if query.excludedGenres.isEmpty {
                query.excludedGenres = TMDbDiscoverQuery.adultAnimationExclusions(query.kind, namedGenres: query.genres)
            }
            if query.keywords.isEmpty {
                query.keywords = [TMDbDiscoverQuery.adultAnimationKeyword]
                query.excludedKeywords = TMDbDiscoverQuery.adultAnimationExcludedKeywords
            }
            query.excludedKeywords.removeAll { $0.id == TMDbDiscoverQuery.kidsKeyword.id }
            return .tmdbDiscover(query)
        default:
            return self
        }
    }
}
