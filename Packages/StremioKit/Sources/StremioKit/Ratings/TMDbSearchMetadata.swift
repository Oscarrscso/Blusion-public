import Foundation

/// Search-only facts. TMDb's audience score must never be stored in MetaPreview.imdbRating.
public struct TMDbSearchMetadata: Sendable {
    public let item: MetaPreview
    public let language: String?
    public let score: Double?
    public let companies: [String]

    public static func parse(_ data: Data, mediaType: String) throws -> TMDbSearchMetadata? {
        let raw: Raw
        do { raw = try JSONDecoder().decode(Raw.self, from: data) } catch { throw AddonError.invalidJSON }
        guard let imdb = raw.imdb_id ?? raw.external_ids?.imdb_id, LetterboxdRatings.isIMDbID(imdb),
              let name = raw.title ?? raw.name else { return nil }
        let runtime = raw.runtime ?? raw.episode_run_time?.first
        let year = (raw.release_date ?? raw.first_air_date).map { String($0.prefix(4)) }
        let item = MetaPreview(id: imdb, type: mediaType == "tv" ? "series" : "movie", name: name,
                               poster: TMDbImage.url(raw.poster_path, size: "w500"),
                               background: TMDbImage.url(raw.backdrop_path, size: "w1280"), description: raw.overview,
                               releaseInfo: year, genres: raw.genres?.map(\.name) ?? [],
                               runtime: runtime.flatMap { $0 > 0 ? "\($0) min" : nil })
        return TMDbSearchMetadata(item: item, language: raw.original_language,
                                  score: (raw.vote_count ?? 0) > 0 ? raw.vote_average : nil,
                                  companies: raw.production_companies?.map(\.name) ?? [])
    }

    private struct Raw: Decodable {
        let title: String?, name: String?, imdb_id: String?, overview: String?
        let external_ids: ExternalIDs?
        let release_date: String?, first_air_date: String?, original_language: String?
        let runtime: Int?, episode_run_time: [Int]?
        let genres: [Named]?, production_companies: [Named]?
        let vote_average: Double?, vote_count: Int?
        let poster_path: String?, backdrop_path: String?
    }
    private struct Named: Decodable { let name: String }
    private struct ExternalIDs: Decodable { let imdb_id: String? }
}

extension TMDbRatings {
    /// One bounded request supplies the IMDb identity and full metadata for a filmography candidate.
    public func searchMetadata(tmdbID: Int, mediaType: String) async throws -> TMDbSearchMetadata? {
        guard tmdbID > 0, ["movie", "tv"].contains(mediaType), credential != nil else { return nil }
        let (url, headers) = try request(path: [mediaType, String(tmdbID)],
                                        query: [URLQueryItem(name: "append_to_response", value: "external_ids")])
        let result = try await client.get(url, headers: headers, limits: FetchLimits(maxBytes: 512 * 1024), timeout: 8)
        return try TMDbSearchMetadata.parse(result.data, mediaType: mediaType)
    }
}
