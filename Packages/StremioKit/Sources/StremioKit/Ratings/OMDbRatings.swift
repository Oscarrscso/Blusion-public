import Foundation

/// IMDb, Rotten Tomatoes and Metacritic scores supplied by OMDb, when the user has provided an API key.
public struct OMDbRatings: Sendable {
    public static let defaultBaseURL = URL(string: "https://www.omdbapi.com/") ?? URL(fileURLWithPath: "/")
    private let client: AddonClient
    private let apiKey: String
    private let baseURL: URL
    /// What this key has been used for today; the daily allowance is `OMDbUsage.dailyLimit`.
    public let usage: OMDbUsage

    public init(client: AddonClient, apiKey: String, baseURL: URL = OMDbRatings.defaultBaseURL, usage: OMDbUsage = .shared) {
        self.client = client
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL
        self.usage = usage
    }

    public func ratings(imdbID: String) async throws -> ReviewRatings {
        guard LetterboxdRatings.isIMDbID(imdbID), !apiKey.isEmpty else { return ReviewRatings() }
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "apikey", value: apiKey), URLQueryItem(name: "i", value: imdbID)]
        guard let url = parts?.url else { throw AddonError.invalidURL }
        usage.record()
        let result = try await client.get(url, limits: FetchLimits(maxBytes: 64 * 1024), timeout: 6)
        return try Self.parse(result.data)
    }

    /// A season's IMDb scores and identities. Keep IDs even for `N/A` scores: the local IMDb dataset may have their ratings.
    public struct SeasonRatings: Sendable, Equatable {
        public var scores: [Int: Double] = [:]
        public var episodeIDs: [Int: String] = [:]
        public var episodeNumbers: Set<Int> = []

        public init() {}
    }

    /// IMDb scores of one season's episodes, by episode number.
    public func episodeRatings(imdbID: String, season: Int) async throws -> [Int: Double] {
        try await seasonRatings(imdbID: imdbID, season: season).scores
    }

    /// One request for the whole season, including identities for episodes OMDb has no rating for.
    public func seasonRatings(imdbID: String, season: Int) async throws -> SeasonRatings {
        guard LetterboxdRatings.isIMDbID(imdbID), season >= 0, !apiKey.isEmpty else { return SeasonRatings() }
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "apikey", value: apiKey), URLQueryItem(name: "i", value: imdbID),
                             URLQueryItem(name: "Season", value: String(season))]
        guard let url = parts?.url else { throw AddonError.invalidURL }
        usage.record()
        let result = try await client.get(url, limits: FetchLimits(maxBytes: 256 * 1024), timeout: 8)
        var answer = try Self.parseSeasonRatings(result.data)
        // A series ID is not an episode ID; never use the show's rating for an episode.
        answer.episodeIDs = answer.episodeIDs.filter { $0.value != imdbID }
        return answer
    }

    /// `Episodes` of a season answer, as episode number to score. Episodes without a score (`"N/A"`) are left out.
    public static func parseSeason(_ data: Data) throws -> [Int: Double] {
        try parseSeasonRatings(data).scores
    }

    public static func parseSeasonRatings(_ data: Data) throws -> SeasonRatings {
        let response: SeasonResponse
        do { response = try JSONDecoder().decode(SeasonResponse.self, from: data) } catch { throw AddonError.invalidJSON }
        if response.Response == "False" {
            if isMissingTitle(response.Error) { return SeasonRatings() }
            throw failure(for: response.Error)
        }
        guard response.Response == "True" else { throw AddonError.invalidJSON }
        var answer = SeasonRatings()
        for episode in response.Episodes ?? [] {
            guard let number = episode.Episode.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), number >= 0 else { continue }
            answer.episodeNumbers.insert(number)
            if let id = episode.imdbID?.trimmingCharacters(in: .whitespacesAndNewlines), LetterboxdRatings.isIMDbID(id) {
                answer.episodeIDs[number] = id
            }
            if let value = score(episode.imdbRating, scale: 10), value > 0 { answer.scores[number] = value }
        }
        return answer
    }

    public static func parse(_ data: Data) throws -> ReviewRatings {
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) } catch { throw AddonError.invalidJSON }
        if response.Response == "False" {
            if isMissingTitle(response.Error) { return ReviewRatings() }
            throw failure(for: response.Error)
        }
        guard response.Response == "True" else { throw AddonError.invalidJSON }
        let ratings = response.Ratings ?? []
        let imdb = score(response.imdbRating, scale: 10)
            ?? score(ratings.first { $0.Source == "Internet Movie Database" }?.Value, scale: 10, suffix: "/10")
        let tomatoes = score(ratings.first { $0.Source == "Rotten Tomatoes" }?.Value, scale: 100, suffix: "%")
        let metascore = score(response.Metascore, scale: 100)
            ?? score(ratings.first { $0.Source == "Metacritic" }?.Value, scale: 100, suffix: "/100")
        return ReviewRatings(imdb: imdb, rottenTomatoes: tomatoes, metacritic: metascore)
    }

    /// "Movie not found!", "Series or season not found!" and "Incorrect IMDb ID." mean OMDb has no such title: a real answer.
    private static func isMissingTitle(_ error: String?) -> Bool {
        guard let error = error?.lowercased() else { return false }
        return error.contains("not found") || error.contains("incorrect imdb id")
    }

    /// Invalid keys and exhausted quotas are failures, so they do not become cached "no rating" answers.
    private static func failure(for error: String?) -> AddonError {
        .http(status: error?.lowercased().contains("limit") == true ? 429 : 401)
    }

    private static func score(_ raw: String?, scale: Double, suffix: String = "") -> Double? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if !suffix.isEmpty {
            guard text.hasSuffix(suffix) else { return nil }
            text.removeLast(suffix.count)
        }
        guard let value = Double(text), value.isFinite, (0...scale).contains(value) else { return nil }
        return value
    }

    private struct Response: Decodable {
        let Response: String?
        let Error: String?
        let imdbRating: String?
        let Metascore: String?
        let Ratings: [Rating]?
    }
    private struct Rating: Decodable { let Source: String; let Value: String }

    private struct SeasonResponse: Decodable {
        let Response: String?
        let Error: String?
        let Episodes: [SeasonEpisode]?
    }
    private struct SeasonEpisode: Decodable {
        let Episode: String?
        let imdbRating: String?
        let imdbID: String?
    }
}
