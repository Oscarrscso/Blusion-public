import Foundation

/// A service a title can be watched on, as TMDb lists it: its name and logo.
public struct TMDbWatchService: Sendable, Equatable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let logo: URL?

    public init(id: Int, name: String, logo: URL?) {
        self.id = id
        self.name = name
        self.logo = logo
    }
}

/// Where a title can be watched in one region, as TMDb lists it (JustWatch's data): the services it streams on, and those it can be
/// rented or bought from. `link` is TMDb's page for the title in that region.
public struct TMDbTitleWatch: Sendable, Equatable {
    public var link: URL?
    public var streaming: [TMDbWatchService]
    public var rent: [TMDbWatchService]
    public var buy: [TMDbWatchService]

    public init(link: URL?, streaming: [TMDbWatchService], rent: [TMDbWatchService], buy: [TMDbWatchService]) {
        self.link = link
        self.streaming = streaming
        self.rent = rent
        self.buy = buy
    }

    public static let empty = TMDbTitleWatch(link: nil, streaming: [], rent: [], buy: [])

    /// True when TMDb lists no way to watch the title in the region.
    public var isEmpty: Bool { streaming.isEmpty && rent.isEmpty && buy.isEmpty }

    private struct RawResponse: Decodable {
        let results: [String: RawRegion]?
    }

    private struct RawRegion: Decodable {
        let link: String?
        let flatrate: [RawService]?
        let rent: [RawService]?
        let buy: [RawService]?
    }

    private struct RawService: Decodable {
        let providerID: Int
        let providerName: String
        let logoPath: String?
        let displayPriority: Int?

        enum CodingKeys: String, CodingKey {
            case providerID = "provider_id"
            case providerName = "provider_name"
            case logoPath = "logo_path"
            case displayPriority = "display_priority"
        }
    }

    /// The options in `region`, each list in TMDb's display order. A region TMDb does not list gives `empty`.
    public static func parse(_ data: Data, region: String) throws -> TMDbTitleWatch {
        let response: RawResponse
        do { response = try JSONDecoder().decode(RawResponse.self, from: data) } catch { throw AddonError.invalidJSON }
        guard let listed = response.results?[region] else { return .empty }
        return TMDbTitleWatch(link: listed.link.flatMap(URL.init(string:)), streaming: services(listed.flatrate),
                              rent: services(listed.rent), buy: services(listed.buy))
    }

    private static func services(_ raw: [RawService]?) -> [TMDbWatchService] {
        (raw ?? []).sorted { ($0.displayPriority ?? .max) < ($1.displayPriority ?? .max) }.map {
            TMDbWatchService(id: $0.providerID, name: $0.providerName, logo: TMDbImage.url($0.logoPath, size: "w92"))
        }
    }
}

// MARK: - Client

extension TMDbRatings {
    /// Where the IMDb title can be watched in `region`. Empty when TMDb does not know the title. Throws `AddonError` for refusals and
    /// failures.
    public func titleWatch(imdbID: String, type: String, region: String) async throws -> TMDbTitleWatch {
        guard let id = try await tmdbID(imdbID: imdbID, type: type) else { return .empty }
        let (url, headers) = try request(path: [type == "movie" ? "movie" : "tv", String(id), "watch", "providers"])
        let result = try await client.get(url, headers: headers, limits: FetchLimits(maxBytes: 1024 * 1024), timeout: 8)
        return try TMDbTitleWatch.parse(result.data, region: region)
    }
}
