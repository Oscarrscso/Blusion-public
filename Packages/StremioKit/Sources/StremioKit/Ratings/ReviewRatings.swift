import Foundation

/// Supplemental scores keep each site's native scale: IMDb/TMDB out of 10, critics out of 100.
public struct ReviewRatings: Sendable, Codable, Equatable {
    public var imdb: Double?
    public var rottenTomatoes: Double?
    public var metacritic: Double?
    public var tmdb: Double?
    public var tmdbURL: URL?

    public init(imdb: Double? = nil, rottenTomatoes: Double? = nil, metacritic: Double? = nil,
                tmdb: Double? = nil, tmdbURL: URL? = nil) {
        self.imdb = imdb
        self.rottenTomatoes = rottenTomatoes
        self.metacritic = metacritic
        self.tmdb = tmdb
        self.tmdbURL = tmdbURL
    }

    public var isEmpty: Bool { imdb == nil && rottenTomatoes == nil && metacritic == nil && tmdb == nil && tmdbURL == nil }
}

/// Links never guess a review-page slug from the title. A search link says so in the UI.
public enum ReviewSite: String, CaseIterable, Sendable, Identifiable {
    case imdb, letterboxd, rottenTomatoes, metacritic, tmdb
    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .imdb: "IMDb"
        case .letterboxd: "Letterboxd"
        case .rottenTomatoes: "Rotten Tomatoes"
        case .metacritic: "Metacritic"
        case .tmdb: "TMDB"
        }
    }

    public func isSearch(for item: MetaPreview, tmdbURL: URL? = nil) -> Bool {
        switch self {
        case .imdb: !LetterboxdRatings.isIMDbID(item.id)
        case .letterboxd: item.type != "movie" || !LetterboxdRatings.isIMDbID(item.id)
        case .tmdb: tmdbURL == nil
        case .rottenTomatoes, .metacritic: true
        }
    }

    /// The page that lists the title's user reviews, where the site has one this title can reach by address. Otherwise the same page as
    /// `url(for:)`: the title's page, or a search.
    public func reviewsURL(for item: MetaPreview, tmdbURL: URL? = nil) -> URL? {
        if self == .imdb, LetterboxdRatings.isIMDbID(item.id) { return URL(string: "https://www.imdb.com/title/\(item.id)/reviews/") }
        // TMDB's user reviews are a page below the title's own.
        if self == .tmdb, let tmdbURL { return tmdbURL.appendingPathComponent("reviews") }
        // Metacritic's user reviews sit at the title's own address. The address is a guess from the title; a page that is not there falls
        // back to the search (see the review web view).
        if self == .metacritic, let slug = Self.metacriticSlug(item.name) {
            return URL(string: "https://www.metacritic.com/\(item.type == "movie" ? "movie" : "tv")/\(slug)/user-reviews/")
        }
        return url(for: item, tmdbURL: tmdbURL)
    }

    /// Whether the reviews panel waits for a reviews heading on this address before it opens. IMDb's reviews page has one. Its search page,
    /// which a title with no IMDb id opens, has none, so waiting there would only run out the clock. The other sites keep the wait.
    public func waitsForReviewsHeading(at url: URL) -> Bool {
        switch self {
        case .letterboxd: false
        case .imdb: url.pathComponents.contains("reviews")
        case .rottenTomatoes, .metacritic, .tmdb: true
        }
    }

    /// The part of a Metacritic address that names a title: its words in lower case, joined by hyphens, with accents and apostrophes
    /// dropped ("The Dark Knight" is "the-dark-knight", "Schindler's List" is "schindlers-list").
    static func metacriticSlug(_ name: String) -> String? {
        let plain = name.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
            .folding(options: [.diacriticInsensitive], locale: nil)
        let cleaned = plain.map { character -> String in
            character.isASCII && (character.isLetter || character.isNumber) ? character.lowercased() : " "
        }.joined()
        let slug = cleaned.split(separator: " ").joined(separator: "-")
        return slug.isEmpty ? nil : slug
    }

    public func url(for item: MetaPreview, tmdbURL: URL? = nil) -> URL? {
        if self == .imdb, LetterboxdRatings.isIMDbID(item.id) { return URL(string: "https://www.imdb.com/title/\(item.id)/") }
        if self == .letterboxd, item.type == "movie", LetterboxdRatings.isIMDbID(item.id) {
            return URL(string: "https://letterboxd.com/imdb/\(item.id)/")
        }
        if self == .tmdb, let tmdbURL { return tmdbURL }
        let base: String
        let parameter: String
        switch self {
        case .imdb: base = "https://www.imdb.com/find/"; parameter = "q"
        case .letterboxd: base = "https://letterboxd.com/search/"; parameter = "q"
        case .rottenTomatoes: base = "https://www.rottentomatoes.com/search"; parameter = "search"
        case .metacritic:
            let title = item.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#")))
            return title.flatMap { URL(string: "https://www.metacritic.com/search/\($0)/") }
        case .tmdb: base = "https://www.themoviedb.org/search"; parameter = "query"
        }
        var parts = URLComponents(string: base)
        parts?.queryItems = [URLQueryItem(name: parameter, value: item.name)]
        return parts?.url
    }
}
