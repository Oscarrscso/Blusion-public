import Foundation

/// Answers kept for the session by key. Callers that ask at the same time share one lookup, and a failed lookup is not kept, so it is asked
/// again. A `nil` answer is kept like any other.
actor KeptAnswers<Value: Sendable> {
    private var answers: [String: Value] = [:]
    private var lookups: [String: Task<Value, Error>] = [:]

    func value(for key: String, lookup: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let answer = answers[key] { return answer }
        if let pending = lookups[key] { return try await pending.value }
        let task = Task { try await lookup() }
        lookups[key] = task
        defer { lookups[key] = nil }
        let answer = try await task.value
        answers[key] = answer
        return answer
    }
}

/// The session's iTunes search answers by title, including the titles the store has no preview for, so reopening a title does not search
/// again. Callers that ask at the same time share one search. A failed search is not kept, so it is asked again.
public actor ITunesTrailerCache {
    public static let shared = ITunesTrailerCache()

    private let kept = KeptAnswers<Trailer?>()

    public init() {}

    func trailer(for key: String, lookup: @escaping @Sendable () async throws -> Trailer?) async throws -> Trailer? {
        try await kept.value(for: key, lookup: lookup)
    }
}

/// One store entry that can be a trailer: its name, release year, the https preview file, and for a series its season.
struct PreviewCandidate: Sendable, Equatable {
    let name: String
    let year: Int?
    let url: URL
    let season: Int?
}

/// The session's iTunes charts, one per type and country, so a title the search does not find is looked up in one download, not one per title.
/// A chart that fails to download is not kept, so it is asked again.
public actor ITunesChartCache {
    public static let shared = ITunesChartCache()

    private let kept = KeptAnswers<[PreviewCandidate]>()

    public init() {}

    func candidates(for key: String, lookup: @escaping @Sendable () async throws -> [PreviewCandidate]) async throws -> [PreviewCandidate] {
        try await kept.value(for: key, lookup: lookup)
    }
}

/// A movie's or series' preview from Apple's iTunes store: the short clip the store publishes for a film, or for a season of a show. The
/// clip is a direct file, so it plays in the app.
///
/// The store's search finds little for studio films, so when it has no match the chart of what is currently popular in the store is
/// searched instead. The chart holds the films and seasons people are watching now, which is where most of the titles on a page are. It
/// does not hold older or quieter titles, which is why the search still comes first. Both answer for Ireland (`country`).
public struct ITunesTrailers: Sendable {
    /// The store country both the search and the charts answer for.
    static let country = "ie"

    let client: AddonClient
    let cache: ITunesTrailerCache
    let chartCache: ITunesChartCache

    public init(client: AddonClient, cache: ITunesTrailerCache = .shared, chartCache: ITunesChartCache = .shared) {
        self.client = client
        self.cache = cache
        self.chartCache = chartCache
    }

    /// The preview of a movie (`type` "movie") or series (`type` "series") titled `title`, released in `year` when that is known. The
    /// store's search is tried first; when it has no match, the current chart is. Nil when neither has one, or for another type. Throws
    /// `AddonError` when the search fails.
    public func preview(title: String, year: Int?, type: String) async throws -> Trailer? {
        guard !Self.normalized(title).isEmpty, let url = Self.searchURL(title: title, type: type) else { return nil }
        let key = "\(type)|\(Self.normalized(title))|\(year.map(String.init) ?? "")"
        let client = client
        return try await cache.trailer(for: key) {
            let result = try await client.get(url, limits: FetchLimits(maxBytes: 256 * 1024), timeout: 6)
            if let trailer = try Self.parse(result.data, title: title, year: year, type: type) { return trailer }
            return try await chartTrailer(title: title, year: year, type: type)
        }
    }

    /// The store search for a movie or a series' seasons. Built with `URLComponents`, so the title is encoded as a query value.
    static func searchURL(title: String, type: String) -> URL? {
        let media: (media: String, entity: String)
        switch type {
        case "movie": media = ("movie", "movie")
        case "series": media = ("tvShow", "tvSeason")
        default: return nil
        }
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: title.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "media", value: media.media),
            URLQueryItem(name: "entity", value: media.entity),
            URLQueryItem(name: "country", value: country),
        ]
        return components?.url
    }

    /// The store's chart of current films (`type` "movie") or series' seasons (`type` "series"), 200 entries.
    static func chartURL(type: String) -> URL? {
        let feed: String
        switch type {
        case "movie": feed = "topmovies"
        case "series": feed = "toptvseasons"
        default: return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/\(country)/rss/\(feed)/limit=200/json"
        return components.url
    }

    /// The preview in a search answer. Throws `invalidJSON` when the answer has no `results` list.
    public static func parse(_ data: Data, title: String, year: Int?, type: String) throws -> Trailer? {
        let response: SearchResponse
        do { response = try JSONDecoder().decode(SearchResponse.self, from: data) } catch { throw AddonError.invalidJSON }
        guard ["movie", "series"].contains(type) else { return nil }
        let candidates = response.results.compactMap { result in
            candidate(rawName: type == "series" ? result.collectionName : result.trackName, releaseDate: result.releaseDate,
                      previewURL: result.previewUrl, type: type)
        }
        return match(candidates, title: title, year: year, type: type)
    }

    /// The preview in a chart answer (`topmovies` for a movie, `toptvseasons` for a series). Throws `invalidJSON` when the answer is not a
    /// chart feed.
    public static func parseChart(_ data: Data, title: String, year: Int?, type: String) throws -> Trailer? {
        let candidates = try candidates(fromChart: data, type: type)
        guard ["movie", "series"].contains(type) else { return nil }
        return match(candidates, title: title, year: year, type: type)
    }

    /// The chart's entries that carry an https preview file. Entries without one are left out; a single entry may come as an object rather
    /// than a list.
    static func candidates(fromChart data: Data, type: String) throws -> [PreviewCandidate] {
        let chart: ChartFeed
        do { chart = try JSONDecoder().decode(ChartFeed.self, from: data) } catch { throw AddonError.invalidJSON }
        return (chart.feed.entry?.values ?? []).compactMap { entry in
            let enclosure = entry.link?.values.first(where: { $0.attributes?.rel == "enclosure" })?.attributes?.href
            return candidate(rawName: entry.name?.label, releaseDate: entry.releaseDate?.label, previewURL: enclosure, type: type)
        }
    }

    private func chartTrailer(title: String, year: Int?, type: String) async throws -> Trailer? {
        guard let url = Self.chartURL(type: type) else { return nil }
        let client = client
        let candidates = try await chartCache.candidates(for: "\(type)|\(Self.country)") {
            let result = try await client.get(url, limits: FetchLimits(maxBytes: 2 * 1024 * 1024), timeout: 8)
            return try Self.candidates(fromChart: result.data, type: type)
        }
        return Self.match(candidates, title: title, year: year, type: type)
    }

    /// A store entry as a candidate: its name, release year and https preview file. A series' name loses its season suffix, and the season
    /// is kept. Nil without a usable preview.
    private static func candidate(rawName: String?, releaseDate: String?, previewURL: String?, type: String) -> PreviewCandidate? {
        guard let rawName, let text = previewURL, let url = URL(string: text), url.scheme?.lowercased() == "https" else { return nil }
        let year = releaseDate.flatMap { Int($0.prefix(4)) }
        guard type == "series" else { return PreviewCandidate(name: rawName, year: year, url: url, season: nil) }
        let parts = seasonParts(rawName)
        return PreviewCandidate(name: parts.name, year: year, url: url, season: parts.number)
    }

    /// The candidate for `title`: its name matches once normalised, and a known `year` is within one year of its release. A movie takes the
    /// first match; a series takes the match for its lowest season.
    private static func match(_ candidates: [PreviewCandidate], title: String, year: Int?, type: String) -> Trailer? {
        let wanted = normalized(title)
        guard !wanted.isEmpty else { return nil }
        let matches = candidates.filter { candidate in
            guard normalized(candidate.name) == wanted else { return false }
            guard let year else { return true }
            guard let released = candidate.year else { return false }
            return abs(released - year) <= 1
        }
        let chosen = type == "series" ? matches.min { ($0.season ?? .max) < ($1.season ?? .max) } : matches.first
        return chosen.map { Trailer(source: .direct($0.url), title: "Trailer", kind: .trailer, isOfficial: true, language: nil) }
    }

    /// A season's collection name without its season suffix ("Show, Season 2" gives "Show" and 2).
    private static func seasonParts(_ collection: String) -> (name: String, number: Int?) {
        guard let suffix = collection.range(of: #"\s*[,\-–:]?\s*Season\s+\d+\s*$"#, options: [.regularExpression, .caseInsensitive]) else {
            return (collection, nil)
        }
        let number = collection[suffix].range(of: #"\d+$"#, options: .regularExpression).flatMap { Int(collection[suffix][$0]) }
        return (String(collection[..<suffix.lowerBound]), number)
    }

    /// Case, accents and punctuation (and spaces) removed, so "Amélie" and "AMELIE!" are the same name.
    static func normalized(_ text: String) -> String {
        var out = ""
        for scalar in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).unicodeScalars
        where CharacterSet.alphanumerics.contains(scalar) {
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    private struct SearchResponse: Decodable { let results: [Result] }
    private struct Result: Decodable {
        let trackName: String?
        let collectionName: String?
        let previewUrl: String?
        let releaseDate: String?
    }

    private struct ChartFeed: Decodable { let feed: Feed }
    private struct Feed: Decodable { let entry: OneOrMany<ChartEntry>? }
    private struct ChartEntry: Decodable {
        let name: Label?
        let releaseDate: Label?
        let link: OneOrMany<Link>?

        private enum CodingKeys: String, CodingKey {
            case name = "im:name"
            case releaseDate = "im:releaseDate"
            case link
        }
    }
    private struct Label: Decodable { let label: String? }
    private struct Link: Decodable { let attributes: LinkAttributes? }
    private struct LinkAttributes: Decodable {
        let rel: String?
        let href: String?
    }
}

/// A JSON list that the store writes as a bare object when it has one entry.
private struct OneOrMany<Element: Decodable>: Decodable {
    let values: [Element]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let many = try? container.decode([Element].self) {
            values = many
        } else {
            values = [try container.decode(Element.self)]
        }
    }
}
