import Foundation

/// What TMDb knows about a title beyond the addon's details, for the title page's Information: who made it, where and in what
/// language, what it cost and earned, and for a series its network, seasons and run. Empty lists and nil values are facts TMDb left out.
public struct TMDbTitleFacts: Sendable, Equatable {
    /// Production companies, in TMDb's order.
    public var studios: [String] = []
    /// A series' networks.
    public var networks: [String] = []
    /// A series' creators.
    public var creators: [String] = []
    /// Production countries, by name.
    public var countries: [String] = []
    /// The original language's English name ("Japanese").
    public var originalLanguage: String?
    /// The title it was released under, when it differs from the English one.
    public var originalTitle: String?
    /// "Released", "Returning Series", "Ended", "In Production" and so on.
    public var status: String?
    /// US dollars. Nil when TMDb has 0, which means unknown.
    public var budget: Int?
    public var revenue: Int?
    /// The release date of a movie, or a series' first and last air dates, as "yyyy-MM-dd".
    public var releaseDate: String?
    public var firstAired: String?
    public var lastAired: String?
    public var seasonCount: Int?
    public var episodeCount: Int?

    public init(studios: [String] = [], networks: [String] = [], creators: [String] = [], countries: [String] = [],
                originalLanguage: String? = nil, originalTitle: String? = nil, status: String? = nil, budget: Int? = nil,
                revenue: Int? = nil, releaseDate: String? = nil, firstAired: String? = nil, lastAired: String? = nil,
                seasonCount: Int? = nil, episodeCount: Int? = nil) {
        self.studios = studios
        self.networks = networks
        self.creators = creators
        self.countries = countries
        self.originalLanguage = originalLanguage
        self.originalTitle = originalTitle
        self.status = status
        self.budget = budget
        self.revenue = revenue
        self.releaseDate = releaseDate
        self.firstAired = firstAired
        self.lastAired = lastAired
        self.seasonCount = seasonCount
        self.episodeCount = episodeCount
    }

    /// Reads a `movie/{id}` or `tv/{id}` answer. Blank names are dropped, and a list keeps each name once. Throws `invalidJSON` for an
    /// answer that is not an object.
    public static func parse(_ data: Data) throws -> TMDbTitleFacts {
        let raw: Raw
        do { raw = try JSONDecoder().decode(Raw.self, from: data) } catch { throw AddonError.invalidJSON }
        let languageCode = text(raw.original_language)
        let language = raw.spoken_languages?.first { $0.iso_639_1 == languageCode }.flatMap { text($0.english_name) }
            ?? languageCode.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0) }
        let heading = text(raw.title) ?? text(raw.name)
        let original = text(raw.original_title) ?? text(raw.original_name)
        return TMDbTitleFacts(studios: names(raw.production_companies?.map(\.name)),
                              networks: names(raw.networks?.map(\.name)),
                              creators: names(raw.created_by?.map(\.name)),
                              countries: names(raw.production_countries?.map(\.name)),
                              originalLanguage: language,
                              originalTitle: original == heading ? nil : original,
                              status: text(raw.status),
                              budget: raw.budget.flatMap { $0 > 0 ? $0 : nil },
                              revenue: raw.revenue.flatMap { $0 > 0 ? $0 : nil },
                              releaseDate: text(raw.release_date),
                              firstAired: text(raw.first_air_date),
                              lastAired: text(raw.last_air_date),
                              seasonCount: raw.number_of_seasons.flatMap { $0 > 0 ? $0 : nil },
                              episodeCount: raw.number_of_episodes.flatMap { $0 > 0 ? $0 : nil })
    }

    private static func text(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func names(_ values: [String?]?) -> [String] {
        var seen = Set<String>()
        return (values ?? []).compactMap { text($0) }.filter { seen.insert($0).inserted }
    }

    private struct Raw: Decodable {
        let title: String?, name: String?, original_title: String?, original_name: String?
        let original_language: String?, status: String?
        let budget: Int?, revenue: Int?
        let release_date: String?, first_air_date: String?, last_air_date: String?
        let number_of_seasons: Int?, number_of_episodes: Int?
        let production_companies: [Named]?, production_countries: [Named]?, networks: [Named]?, created_by: [Named]?
        let spoken_languages: [Language]?
    }

    private struct Named: Decodable { let name: String? }
    private struct Language: Decodable { let iso_639_1: String?, english_name: String? }
}

extension TMDbRatings {
    /// The facts TMDb has about a title (see `TMDbTitleFacts`). Nil when TMDb does not know the title.
    public func titleFacts(imdbID: String, type: String) async throws -> TMDbTitleFacts? {
        guard let number = try await tmdbID(imdbID: imdbID, type: type) else { return nil }
        let (url, headers) = try request(path: [type == "movie" ? "movie" : "tv", String(number)],
                                         query: [URLQueryItem(name: "language", value: "en-US")])
        let result = try await client.get(url, headers: headers, limits: FetchLimits(maxBytes: 512 * 1024), timeout: 6)
        return try TMDbTitleFacts.parse(result.data)
    }
}
