import Foundation

/// The Trakt feeds a row can show. Each is public: it needs the client ID and no account.
public enum TraktFeed: String, Sendable, Codable, CaseIterable, Hashable {
    case moviesTrending, moviesPopular, showsTrending, showsPopular

    /// The name shown on a row and in its source summary.
    public var title: String {
        switch self {
        case .moviesTrending: return "Trending Movies"
        case .moviesPopular: return "Popular Movies"
        case .showsTrending: return "Trending Shows"
        case .showsPopular: return "Popular Shows"
        }
    }

    /// The API path, e.g. `movies/trending`.
    var path: String {
        switch self {
        case .moviesTrending: return "movies/trending"
        case .moviesPopular: return "movies/popular"
        case .showsTrending: return "shows/trending"
        case .showsPopular: return "shows/popular"
        }
    }

    /// The type the items carry: `movie`, or `series` for shows (as Stremio names them).
    var mediaType: String {
        switch self {
        case .moviesTrending, .moviesPopular: return "movie"
        case .showsTrending, .showsPopular: return "series"
        }
    }
}

/// Reads Trakt lists and feeds as catalog items, and browses lists and users. The API key is a public client ID, not a secret: the one the
/// user configured in Settings. Calls that need the user's account go through `TraktAccount`.
public struct TraktClient: Sendable {
    /// `https://api.trakt.tv`. Built from components, so there is no force unwrap; the fallback is never used in practice.
    public static let defaultBaseURL: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.trakt.tv"
        return components.url ?? URL(fileURLWithPath: "/")
    }()

    private static let pathCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    let client: AddonClient
    let baseURL: URL
    private let account: TraktAccount?
    private let cache: TraktBrowseCache?

    /// `account` serves the calls that need a signed-in user (private lists, My Lists, Liked Lists, user search). `cache` keeps
    /// browse pages for a few minutes so searching and paging do not repeat requests.
    public init(client: AddonClient, baseURL: URL = TraktClient.defaultBaseURL, account: TraktAccount? = nil, cache: TraktBrowseCache? = nil) {
        self.client = client
        self.baseURL = baseURL
        self.account = account
        self.cache = cache
    }

    /// The user-configured Trakt API client ID, or empty if none was supplied.
    public static func clientID(in settings: any SettingsStore) async -> String {
        let stored = await settings.load().traktClientID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored ?? ""
    }

    /// One page of a list. Movies map to type `movie`, shows to `series`; other entries, and entries without an IMDb id, are dropped.
    /// Without a sort the list keeps its own order. A private list is read with the user's sign-in.
    public func listItems(_ list: TraktListReference, clientID: String, page: Int = 1, limit: Int = 50) async throws -> [MetaPreview] {
        guard let user = Self.segment(list.username), let slug = Self.segment(list.listSlug) else { throw AddonError.invalidURL }
        var path = "users/\(user)/lists/\(slug)/items"
        if let sort = list.sort { path += "/movie,show/\(sort.apiValue.by)/\(sort.apiValue.how)" }
        let query = "page=\(max(page, 1))&limit=\(min(max(limit, 1), 100))&extended=full"
        let result = try await send(path, query: query, clientID: clientID, authorised: list.needsAccount)
        return try Self.previews(from: result.data)
    }

    /// One page of a Trakt feed. Trending entries are wrapped with a watcher count; popular entries are the media themselves.
    public func feedItems(_ feed: TraktFeed, clientID: String, page: Int = 1, limit: Int = 50) async throws -> [MetaPreview] {
        guard let url = apiURL(feed.path, page: page, limit: limit) else { throw AddonError.invalidURL }
        let result = try await client.get(url, headers: TraktHeaders.common(clientID: clientID))
        return try Self.feedPreviews(from: result.data, feed: feed)
    }

    /// The name and Trakt id of a public list, for a list added by link. The name falls back to the slug when Trakt omits it.
    public func listInfo(username: String, listSlug: String, clientID: String) async throws -> (name: String, traktID: Int?) {
        guard let user = Self.segment(username), let slug = Self.segment(listSlug),
              let url = apiURL("users/\(user)/lists/\(slug)", page: 1, limit: 1, paged: false) else { throw AddonError.invalidURL }
        let result = try await client.get(url, headers: TraktHeaders.common(clientID: clientID))
        do {
            let info = try JSONDecoder().decode(TraktListInfo.self, from: result.data)
            return (info.name ?? listSlug, info.ids?.trakt)
        } catch {
            throw AddonError.invalidJSON
        }
    }

    // MARK: Browsing lists and users

    /// Popular or trending public lists. No sign-in needed.
    public func lists(_ feed: TraktListFeed, clientID: String, page: Int = 1, limit: Int = 20, refresh: Bool = false) async throws -> TraktPage<TraktListSummary> {
        let result = try await send(feed.path, query: Self.pageQuery(page, limit), clientID: clientID, authorised: false, refresh: refresh)
        return try Self.listPage(from: result, page: page)
    }

    /// Public lists matching a text search. No sign-in needed.
    public func searchLists(query: String, clientID: String, page: Int = 1, limit: Int = 20, refresh: Bool = false) async throws -> TraktPage<TraktListSummary> {
        let text = "query=\(Self.encode(query))&\(Self.pageQuery(page, limit))"
        let result = try await send("search/list", query: text, clientID: clientID, authorised: false, refresh: refresh)
        return try Self.listPage(from: result, page: page)
    }

    /// The public lists of one user. Trakt returns them all at once.
    public func userLists(username: String, clientID: String, refresh: Bool = false) async throws -> TraktPage<TraktListSummary> {
        guard let user = Self.segment(username) else { throw AddonError.invalidURL }
        let result = try await send("users/\(user)/lists", query: "", clientID: clientID, authorised: false, refresh: refresh)
        return try Self.listPage(from: result, page: 1)
    }

    /// The signed-in user's own lists, private ones included. Needs the Trakt sign-in.
    public func myLists(clientID: String, refresh: Bool = false) async throws -> TraktPage<TraktListSummary> {
        let result = try await send("users/me/lists", query: "", clientID: clientID, authorised: true, refresh: refresh)
        return try Self.listPage(from: result, page: 1)
    }

    /// Lists the signed-in user liked. Needs the Trakt sign-in.
    public func likedLists(clientID: String, page: Int = 1, limit: Int = 20, refresh: Bool = false) async throws -> TraktPage<TraktListSummary> {
        let result = try await send("users/likes/lists", query: Self.pageQuery(page, limit), clientID: clientID, authorised: true, refresh: refresh)
        return try Self.listPage(from: result, page: page)
    }

    /// Users matching a text search. Trakt answers this only for a signed-in user.
    public func searchUsers(query: String, clientID: String, page: Int = 1, limit: Int = 20, refresh: Bool = false) async throws -> TraktPage<TraktUserSummary> {
        let text = "query=\(Self.encode(query))&\(Self.pageQuery(page, limit))"
        let result = try await send("search/user", query: text, clientID: clientID, authorised: true, refresh: refresh)
        do {
            let entries = try JSONDecoder().decode([LossyUserEntry].self, from: result.data)
            return TraktPage(items: entries.compactMap(\.user), page: max(page, 1), pageCount: Self.pageCount(result))
        } catch {
            throw AddonError.invalidJSON
        }
    }

    /// The owner and slug of a `trakt.tv/users/<user>/lists/<slug>` link. A link without a scheme is accepted. nil when the text is not a list link.
    public static func listReference(fromLink text: String) -> (username: String, listSlug: String)? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), let host = url.host?.lowercased(), host == "trakt.tv" || host.hasSuffix(".trakt.tv") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[0] == "users", parts[2] == "lists", !parts[1].isEmpty, !parts[3].isEmpty else { return nil }
        return (parts[1], parts[3])
    }

    /// One GET with the API headers. `authorised` goes through the signed-in account (which refreshes its token); anything else is a
    /// public read. Browse results are kept for a few minutes unless `refresh` asks again.
    private func send(_ path: String, query: String, clientID: String, authorised: Bool, refresh: Bool = false) async throws -> HTTPResult {
        let relative = query.isEmpty ? path : "\(path)?\(query)"
        let key = "\(authorised ? "account" : "public")|\(clientID)|\(relative)"
        if !refresh, let cached = await cache?.value(for: key) { return cached }
        let result: HTTPResult
        if authorised {
            guard let account else { throw TraktAccountError.needsSignIn }
            result = try await account.get(relative)
        } else {
            var base = baseURL.absoluteString
            while base.hasSuffix("/") { base.removeLast() }
            guard let url = URL(string: "\(base)/\(relative)") else { throw AddonError.invalidURL }
            result = try await client.get(url, headers: TraktHeaders.common(clientID: clientID))
        }
        await cache?.store(result, for: key)
        return result
    }

    /// `base/<path>?page=…&limit=…&extended=full`. Lists keep their page and limit; a feed's `paged` is false only for a single object.
    private func apiURL(_ path: String, page: Int, limit: Int, paged: Bool = true) -> URL? {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let query = paged ? "?page=\(max(page, 1))&limit=\(min(max(limit, 1), 100))&extended=full" : "?extended=full"
        return URL(string: "\(base)/\(path)\(query)")
    }

    private static func pageQuery(_ page: Int, _ limit: Int) -> String {
        "page=\(max(page, 1))&limit=\(min(max(limit, 1), 100))"
    }

    private static func segment(_ text: String) -> String? {
        text.addingPercentEncoding(withAllowedCharacters: pathCharacters)
    }

    private static func encode(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: pathCharacters) ?? ""
    }

    private static func pageCount(_ result: HTTPResult) -> Int {
        max(result.response.headers["x-pagination-page-count"].flatMap(Int.init) ?? 1, 1)
    }

    private static func listPage(from result: HTTPResult, page: Int) throws -> TraktPage<TraktListSummary> {
        do {
            let entries = try JSONDecoder().decode([LossyListEntry].self, from: result.data)
            return TraktPage(items: entries.compactMap(\.list), page: max(page, 1), pageCount: pageCount(result))
        } catch {
            throw AddonError.invalidJSON
        }
    }

    /// The response must be an array; a bad element is dropped rather than failing the page.
    private static func previews(from data: Data) throws -> [MetaPreview] {
        do {
            return try JSONDecoder().decode([LossyEntry].self, from: data).compactMap(\.preview)
        } catch {
            throw AddonError.invalidJSON
        }
    }

    private static func feedPreviews(from data: Data, feed: TraktFeed) throws -> [MetaPreview] {
        do {
            return try JSONDecoder().decode([LossyFeedEntry].self, from: data).compactMap { $0.preview(for: feed) }
        } catch {
            throw AddonError.invalidJSON
        }
    }
}

/// The public list endpoint: a name and the list's ids. Only the trakt id is kept.
private struct TraktListInfo: Decodable {
    let name: String?
    let ids: Ids?

    struct Ids: Decodable { let trakt: Int? }
}

/// A feed entry, either wrapped (`{"watchers": 3, "movie": {…}}`) or the media itself. One that fails to decode becomes nil.
private struct LossyFeedEntry: Decodable {
    let wrapped: TraktMedia?
    let bare: TraktMedia?

    private enum Keys: String, CodingKey { case movie, show }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        wrapped = container.object(.movie) ?? container.object(.show)
        bare = try? TraktMedia(from: decoder)
    }

    func preview(for feed: TraktFeed) -> MetaPreview? {
        let media = wrapped ?? bare
        return media?.preview(type: feed.mediaType)
    }
}

/// Wraps an entry so that one that fails to decode becomes nil instead of failing the whole array.
private struct LossyEntry: Decodable {
    let preview: MetaPreview?

    init(from decoder: Decoder) throws {
        preview = try? TraktEntry(from: decoder).preview
    }
}

private struct TraktEntry: Decodable {
    let type: String?
    let movie: TraktMedia?
    let show: TraktMedia?

    private enum Keys: String, CodingKey { case type, movie, show }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        type = container.string(.type)
        movie = container.object(.movie)
        show = container.object(.show)
    }

    var preview: MetaPreview? {
        switch type {
        case "movie": return movie?.preview(type: "movie")
        case "show": return show?.preview(type: "series")
        default: return nil
        }
    }
}

private struct TraktMedia: Decodable {
    let title: String?
    let year: String?
    let imdbID: String?
    let overview: String?
    let rating: Double?
    let runtime: Int?
    let genres: [String]

    private enum Keys: String, CodingKey { case title, year, ids, overview, rating, runtime, genres }
    private enum IDKeys: String, CodingKey { case imdb }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        title = container.string(.title)
        year = container.string(.year)
        if container.contains(.ids), let ids = try? container.nestedContainer(keyedBy: IDKeys.self, forKey: .ids) {
            imdbID = ids.string(.imdb)
        } else {
            imdbID = nil
        }
        overview = container.string(.overview)
        rating = container.double(.rating)
        runtime = container.int(.runtime)
        genres = container.stringArray(.genres)
    }

    func preview(type: String) -> MetaPreview? {
        guard let imdbID else { return nil }
        return MetaPreview(id: imdbID, type: type, name: title,
                           poster: MetahubArtwork.poster(imdbID: imdbID),
                           background: MetahubArtwork.background(imdbID: imdbID),
                           logo: MetahubArtwork.logo(imdbID: imdbID),
                           description: overview,
                           releaseInfo: year,
                           imdbRating: rating.map { ($0 * 10).rounded() / 10 },
                           genres: genres.map(Self.genreLabel),
                           runtime: runtime.flatMap { $0 > 0 ? "\($0) min" : nil })
    }

    /// Trakt slugs read `science-fiction`; catalogs read `Science fiction`.
    private static func genreLabel(_ slug: String) -> String {
        let spaced = slug.replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

/// Artwork Stremio's metadata service publishes for an IMDb id.
public enum MetahubArtwork {
    private static let idCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    public static func poster(imdbID: String) -> URL? { artwork("poster", imdbID: imdbID) }

    public static func background(imdbID: String) -> URL? { artwork("background", imdbID: imdbID) }

    public static func logo(imdbID: String) -> URL? { artwork("logo", imdbID: imdbID) }

    private static func artwork(_ kind: String, imdbID: String) -> URL? {
        guard !imdbID.isEmpty, imdbID.unicodeScalars.allSatisfy({ idCharacters.contains($0) }) else { return nil }
        return URL(string: "https://images.metahub.space/\(kind)/medium/\(imdbID)/img")
    }
}
