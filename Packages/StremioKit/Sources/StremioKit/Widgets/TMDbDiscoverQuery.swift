import Foundation

/// A list TMDb builds from filters, such as "series, trending this week, animation": the source of a discover widget.
public struct TMDbDiscoverQuery: Sendable, Codable, Equatable, Hashable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case movie, series

        /// The plural name shown for the kind, such as "Movies".
        public var title: String {
            switch self {
            case .movie: return "Movies"
            case .series: return "Series"
            }
        }

        /// The singular name used inside a title, such as "movie".
        public var noun: String {
            switch self {
            case .movie: return "movie"
            case .series: return "series"
            }
        }
    }

    public enum Ordering: String, Sendable, Codable, CaseIterable {
        case popular, trendingToday, trendingThisWeek, newest, oldest

        /// The name shown for the ordering, such as "Trending Today".
        public var title: String {
            switch self {
            case .popular: return "Popular"
            case .trendingToday: return "Trending Today"
            case .trendingThisWeek: return "Trending This Week"
            case .newest: return "Newest"
            case .oldest: return "Oldest"
            }
        }
    }

    /// A window of release dates that moves with today's date.
    public enum Period: String, Sendable, Codable, CaseIterable {
        case lastMonth, last3Months, thisYear, lastYear, last5Years, last10Years

        /// The name shown for the period, such as "Last 3 Months".
        public var title: String {
            switch self {
            case .lastMonth: return "Last Month"
            case .last3Months: return "Last 3 Months"
            case .thisYear: return "This Year"
            case .lastYear: return "Last Year"
            case .last5Years: return "Last 5 Years"
            case .last10Years: return "Last 10 Years"
            }
        }
    }

    /// Something TMDb names by a number: a genre, keyword, person, company or watch provider. The name is kept for display.
    public struct Named: Sendable, Codable, Equatable, Hashable, Identifiable {
        public var id: Int
        public var name: String

        public init(id: Int, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// One filter of a query, for asking whether the query can use it and whether it is set.
    public enum Filter: String, Sendable, CaseIterable {
        case period, genres, keywords, excludedKeywords, score, votes, language, runtime, release, providers, region, cast, crew, companies
    }

    public var kind: Kind
    public var ordering: Ordering
    public var period: Period?
    public var genres: [Named]
    public var keywords: [Named]
    public var excludedKeywords: [Named]
    /// The rating, 0 to 10: IMDb's for a widget once IMDb's dataset is on the device, else TMDb's community score (see `usesTMDbScores`).
    public var minimumScore: Double?
    public var maximumScore: Double?
    /// The number of votes behind the rating, IMDb's or TMDb's as for the score.
    public var minimumVotes: Int?
    /// The original language as an ISO 639-1 code, such as "ja".
    public var language: String?
    /// Minutes.
    public var minimumRuntime: Int?
    public var maximumRuntime: Int?
    /// Release dates as "yyyy-MM-dd". They take the place of `period` when either is set.
    public var releasedFrom: String?
    public var releasedTo: String?
    public var providers: [Named]
    /// The country the watch providers are looked up in, as an uppercase ISO 3166-1 code such as "IE". Nil uses the device's region.
    public var region: String?
    public var cast: [Named]
    public var crew: [Named]
    public var companies: [Named]
    /// Genres TMDb leaves out, sent as `without_genres`. Adult animation leaves out the family titles (see `inferred(fromTitle:)`).
    public var excludedGenres: [Named]
    /// True when the title names neither films nor shows: the list then holds both, interleaved, so a show such as The Simpsons is in an
    /// animation list as a film is. Written only when set, so a saved list keeps its encoding.
    public var spansBothKinds: Bool
    /// True for a search's list, whose score and vote bounds are always TMDb's own; a widget's are IMDb's. Written only when set, so a
    /// saved widget keeps its encoding.
    public var usesTMDbScores: Bool

    public init(kind: Kind = .movie, ordering: Ordering = .popular, period: Period? = nil, genres: [Named] = [], keywords: [Named] = [],
                excludedKeywords: [Named] = [], minimumScore: Double? = nil, maximumScore: Double? = nil, minimumVotes: Int? = nil,
                language: String? = nil, minimumRuntime: Int? = nil, maximumRuntime: Int? = nil, releasedFrom: String? = nil,
                releasedTo: String? = nil, providers: [Named] = [], region: String? = nil, cast: [Named] = [], crew: [Named] = [],
                companies: [Named] = [], excludedGenres: [Named] = [], spansBothKinds: Bool = false, usesTMDbScores: Bool = false) {
        self.spansBothKinds = spansBothKinds
        self.usesTMDbScores = usesTMDbScores
        self.kind = kind
        self.ordering = ordering
        self.period = period
        self.genres = genres
        self.keywords = keywords
        self.excludedKeywords = excludedKeywords
        self.minimumScore = minimumScore
        self.maximumScore = maximumScore
        self.minimumVotes = minimumVotes
        self.language = language
        self.minimumRuntime = minimumRuntime
        self.maximumRuntime = maximumRuntime
        self.releasedFrom = releasedFrom
        self.releasedTo = releasedTo
        self.providers = providers
        self.region = region
        self.cast = cast
        self.crew = crew
        self.companies = companies
        self.excludedGenres = excludedGenres
    }

    private enum CodingKeys: String, CodingKey {
        case kind, ordering, period, genres, keywords, excludedKeywords, minimumScore, maximumScore, minimumVotes, language
        case minimumRuntime, maximumRuntime, releasedFrom, releasedTo, providers, region, cast, crew, companies, excludedGenres
        case spansBothKinds, usesTMDbScores
    }

    /// Every key is optional. An unknown `kind`, `ordering` or `period` falls back to its default, so a file from another version still
    /// decodes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: (try? container.decodeIfPresent(String.self, forKey: .kind)).flatMap { Kind(rawValue: $0) } ?? .movie,
            ordering: (try? container.decodeIfPresent(String.self, forKey: .ordering)).flatMap { Ordering(rawValue: $0) } ?? .popular,
            period: (try? container.decodeIfPresent(String.self, forKey: .period)).flatMap { Period(rawValue: $0) },
            genres: try container.decodeIfPresent([Named].self, forKey: .genres) ?? [],
            keywords: try container.decodeIfPresent([Named].self, forKey: .keywords) ?? [],
            excludedKeywords: try container.decodeIfPresent([Named].self, forKey: .excludedKeywords) ?? [],
            minimumScore: try container.decodeIfPresent(Double.self, forKey: .minimumScore),
            maximumScore: try container.decodeIfPresent(Double.self, forKey: .maximumScore),
            minimumVotes: try container.decodeIfPresent(Int.self, forKey: .minimumVotes),
            language: try container.decodeIfPresent(String.self, forKey: .language),
            minimumRuntime: try container.decodeIfPresent(Int.self, forKey: .minimumRuntime),
            maximumRuntime: try container.decodeIfPresent(Int.self, forKey: .maximumRuntime),
            releasedFrom: try container.decodeIfPresent(String.self, forKey: .releasedFrom),
            releasedTo: try container.decodeIfPresent(String.self, forKey: .releasedTo),
            providers: try container.decodeIfPresent([Named].self, forKey: .providers) ?? [],
            region: try container.decodeIfPresent(String.self, forKey: .region),
            cast: try container.decodeIfPresent([Named].self, forKey: .cast) ?? [],
            crew: try container.decodeIfPresent([Named].self, forKey: .crew) ?? [],
            companies: try container.decodeIfPresent([Named].self, forKey: .companies) ?? [],
            excludedGenres: try container.decodeIfPresent([Named].self, forKey: .excludedGenres) ?? [],
            spansBothKinds: try container.decodeIfPresent(Bool.self, forKey: .spansBothKinds) ?? false,
            usesTMDbScores: try container.decodeIfPresent(Bool.self, forKey: .usesTMDbScores) ?? false)
    }

    /// Writes the keys the synthesized encoding wrote. `excludedGenres` is written only when it has genres, so a list that leaves none
    /// out encodes as it did before the field existed: its saved snapshot file name and its Fusion export stay the same.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(ordering, forKey: .ordering)
        try container.encodeIfPresent(period, forKey: .period)
        try container.encode(genres, forKey: .genres)
        try container.encode(keywords, forKey: .keywords)
        try container.encode(excludedKeywords, forKey: .excludedKeywords)
        try container.encodeIfPresent(minimumScore, forKey: .minimumScore)
        try container.encodeIfPresent(maximumScore, forKey: .maximumScore)
        try container.encodeIfPresent(minimumVotes, forKey: .minimumVotes)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(minimumRuntime, forKey: .minimumRuntime)
        try container.encodeIfPresent(maximumRuntime, forKey: .maximumRuntime)
        try container.encodeIfPresent(releasedFrom, forKey: .releasedFrom)
        try container.encodeIfPresent(releasedTo, forKey: .releasedTo)
        try container.encode(providers, forKey: .providers)
        try container.encodeIfPresent(region, forKey: .region)
        try container.encode(cast, forKey: .cast)
        try container.encode(crew, forKey: .crew)
        try container.encode(companies, forKey: .companies)
        if !excludedGenres.isEmpty { try container.encode(excludedGenres, forKey: .excludedGenres) }
        if spansBothKinds { try container.encode(true, forKey: .spansBothKinds) }
        if usesTMDbScores { try container.encode(true, forKey: .usesTMDbScores) }
    }

    /// The excluded genres the list does not name itself. A genre the list asks for is never left out, so the two cannot contradict.
    public var effectiveExcludedGenres: [Named] {
        excludedGenres.filter { excluded in !genres.contains { $0.id == excluded.id } }
    }

    /// True when the ordering is one of TMDb's trending lists, which take no filters of their own.
    public var isTrending: Bool {
        ordering == .trendingToday || ordering == .trendingThisWeek
    }

    /// Whether the query can use a filter. A trending list takes only a few filters, which the app applies to TMDb's answer itself.
    public func supports(_ filter: Filter) -> Bool {
        if isTrending {
            return [.period, .genres, .score, .votes, .language, .release].contains(filter)
        }
        switch filter {
        case .cast, .crew: return kind == .movie
        case .region: return supports(.providers)
        default: return true
        }
    }

    /// Whether a filter has a value: a period, a list with names, a score or vote bound, a language, a runtime or release bound, or a
    /// region.
    public func isSet(_ filter: Filter) -> Bool {
        switch filter {
        case .period: return period != nil
        case .genres: return !genres.isEmpty
        case .keywords: return !keywords.isEmpty
        case .excludedKeywords: return !excludedKeywords.isEmpty
        case .score: return minimumScore != nil || maximumScore != nil
        case .votes: return minimumVotes != nil
        case .language: return language != nil
        case .runtime: return minimumRuntime != nil || maximumRuntime != nil
        case .release: return releasedFrom != nil || releasedTo != nil
        case .providers: return !providers.isEmpty
        case .region: return region != nil
        case .cast: return !cast.isEmpty
        case .crew: return !crew.isEmpty
        case .companies: return !companies.isEmpty
        }
    }

    /// Sets a filter back to its default. The score, runtime and release filters each clear both of their bounds.
    public mutating func clear(_ filter: Filter) {
        switch filter {
        case .period: period = nil
        case .genres: genres = []
        case .keywords: keywords = []
        case .excludedKeywords: excludedKeywords = []
        case .score:
            minimumScore = nil
            maximumScore = nil
        case .votes: minimumVotes = nil
        case .language: language = nil
        case .runtime:
            minimumRuntime = nil
            maximumRuntime = nil
        case .release:
            releasedFrom = nil
            releasedTo = nil
        case .providers: providers = []
        case .region: region = nil
        case .cast: cast = []
        case .crew: crew = []
        case .companies: companies = []
        }
    }

    /// A copy with every filter the query does not support cleared.
    public func removingUnsupportedFilters() -> TMDbDiscoverQuery {
        var copy = self
        for filter in Filter.allCases where !supports(filter) {
            copy.clear(filter)
        }
        return copy
    }

    /// The name a widget gets unless the user types one: the ordering, then the first genre, then the kind, such as "Newest Animation
    /// Movies". A trending list reads the other way round: "Trending Animation Series This Week".
    public var title: String {
        let genre = genres.first?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = [genre?.isEmpty == false ? genre : nil, kind.title].compactMap { $0 }.joined(separator: " ")
        switch ordering {
        case .trendingToday: return "Trending \(subject) Today"
        case .trendingThisWeek: return "Trending \(subject) This Week"
        case .popular, .newest, .oldest: return "\(ordering.title) \(subject)"
        }
    }

    /// A line for lists of widgets: "TMDB · Popular Movies", with " · 2 filters" added when filters other than genres are set.
    public var summary: String {
        let others = Filter.allCases.filter { $0 != .genres && isSet($0) }.count
        let filters = others == 0 ? "" : " · \(others) filter\(others == 1 ? "" : "s")"
        return "TMDB · \(title)\(filters)"
    }

    /// The release dates as "yyyy-MM-dd" strings in the calendar's time zone, either bound nil when open. Explicit dates win over the
    /// period; with neither, the newest ordering stops at today so titles not yet out are left out.
    public func dateRange(today: Date, calendar: Calendar) -> (from: String?, to: String?) {
        if releasedFrom != nil || releasedTo != nil { return (releasedFrom, releasedTo) }
        let todayText = Self.isoDate(today, calendar: calendar)
        guard let period else { return ordering == .newest ? (nil, todayText) : (nil, nil) }
        let year = calendar.component(.year, from: today)
        switch period {
        case .lastMonth:
            return (Self.isoDate(calendar.date(byAdding: .day, value: -30, to: today) ?? today, calendar: calendar), todayText)
        case .last3Months:
            return (Self.isoDate(calendar.date(byAdding: .day, value: -90, to: today) ?? today, calendar: calendar), todayText)
        case .thisYear:
            return (Self.yearStart(year), todayText)
        case .lastYear:
            return (Self.yearStart(year - 1), "\(Self.padded(year - 1, 4))-12-31")
        case .last5Years:
            return (Self.isoDate(calendar.date(byAdding: .year, value: -5, to: today) ?? today, calendar: calendar), todayText)
        case .last10Years:
            return (Self.isoDate(calendar.date(byAdding: .year, value: -10, to: today) ?? today, calendar: calendar), todayText)
        }
    }

    /// The date as "yyyy-MM-dd", zero-padded, read from the calendar's components.
    private static func isoDate(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(padded(parts.year ?? 0, 4))-\(padded(parts.month ?? 0, 2))-\(padded(parts.day ?? 0, 2))"
    }

    private static func yearStart(_ year: Int) -> String {
        "\(padded(year, 4))-01-01"
    }

    private static func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(width - digits.count, 0)) + digits
    }
}
