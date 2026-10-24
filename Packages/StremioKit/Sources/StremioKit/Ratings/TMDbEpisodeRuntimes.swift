import Foundation

extension TMDbRatings {
    /// How long each episode of one season runs, in minutes, keyed by episode number. Empty when the series or the season is unknown to
    /// TMDb, or no episode has a runtime. Throws `AddonError` for refusals and transport failures.
    public func seasonEpisodeRuntimes(seriesIMDbID: String, season: Int) async throws -> [Int: Int] {
        guard LetterboxdRatings.isIMDbID(seriesIMDbID), season >= 0, credential != nil,
              let show = try await tmdbID(imdbID: seriesIMDbID, type: "series") else { return [:] }
        let (url, headers) = try request(path: ["tv", String(show), "season", String(season)])
        do {
            let result = try await client.get(url, headers: headers, limits: FetchLimits(maxBytes: 512 * 1024), timeout: 6)
            return try Self.parseSeasonRuntimes(result.data)
        } catch AddonError.notFound {
            return [:]
        }
    }

    /// The runtimes in a `tv/{id}/season/{n}` answer. An episode without a number or with no runtime (0 or missing) is left out. Throws
    /// `invalidJSON` when the answer has no `episodes` list.
    public static func parseSeasonRuntimes(_ data: Data) throws -> [Int: Int] {
        let response: RuntimeSeason
        do { response = try JSONDecoder().decode(RuntimeSeason.self, from: data) } catch { throw AddonError.invalidJSON }
        guard let episodes = response.episodes else { throw AddonError.invalidJSON }
        var runtimes: [Int: Int] = [:]
        for episode in episodes {
            guard let number = episode.episode_number, let minutes = episode.runtime, minutes > 0 else { continue }
            runtimes[number] = minutes
        }
        return runtimes
    }

    private struct RuntimeSeason: Decodable {
        let episodes: [RuntimeEpisode]?
    }

    private struct RuntimeEpisode: Decodable {
        let episode_number: Int?
        let runtime: Int?
    }
}
