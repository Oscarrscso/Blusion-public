import Foundation

/// What one TMDb season answer gives the episode cards, keyed by episode number.
public struct TMDbSeasonEpisodes: Sendable, Equatable {
    /// Minutes each episode runs.
    public var runtimes: [Int: Int] = [:]
    /// Each episode's synopsis, for addons that send none.
    public var overviews: [Int: String] = [:]

    public init(runtimes: [Int: Int] = [:], overviews: [Int: String] = [:]) {
        self.runtimes = runtimes
        self.overviews = overviews
    }
}

extension TMDbRatings {
    /// How long each episode of one season runs, and its synopsis, keyed by episode number. Empty when the series or the season is
    /// unknown to TMDb. Throws `AddonError` for refusals and transport failures.
    public func seasonEpisodes(seriesIMDbID: String, season: Int) async throws -> TMDbSeasonEpisodes {
        guard LetterboxdRatings.isIMDbID(seriesIMDbID), season >= 0, credential != nil,
              let show = try await tmdbID(imdbID: seriesIMDbID, type: "series") else { return TMDbSeasonEpisodes() }
        let (url, headers) = try request(path: ["tv", String(show), "season", String(season)])
        do {
            let result = try await client.get(url, headers: headers, limits: FetchLimits(maxBytes: 512 * 1024), timeout: 6)
            return try Self.parseSeasonEpisodes(result.data)
        } catch AddonError.notFound {
            return TMDbSeasonEpisodes()
        }
    }

    /// The runtimes and synopses in a `tv/{id}/season/{n}` answer. An episode without a number is left out, as is a runtime of 0 or
    /// an empty synopsis. Throws `invalidJSON` when the answer has no `episodes` list.
    public static func parseSeasonEpisodes(_ data: Data) throws -> TMDbSeasonEpisodes {
        let response: Season
        do { response = try JSONDecoder().decode(Season.self, from: data) } catch { throw AddonError.invalidJSON }
        guard let episodes = response.episodes else { throw AddonError.invalidJSON }
        var parsed = TMDbSeasonEpisodes()
        for episode in episodes {
            guard let number = episode.episode_number else { continue }
            if let minutes = episode.runtime, minutes > 0 { parsed.runtimes[number] = minutes }
            if let text = episode.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                parsed.overviews[number] = text
            }
        }
        return parsed
    }

    /// The runtimes alone, as `parseSeasonEpisodes` reads them.
    public static func parseSeasonRuntimes(_ data: Data) throws -> [Int: Int] {
        try parseSeasonEpisodes(data).runtimes
    }

    private struct Season: Decodable {
        let episodes: [Episode]?
    }

    private struct Episode: Decodable {
        let episode_number: Int?
        let runtime: Int?
        let overview: String?
    }
}
