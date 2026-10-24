import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct TraktDeviceCode: Sendable, Decodable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let expiresIn: Int
    public let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code", userCode = "user_code", verificationURL = "verification_url", expiresIn = "expires_in", interval
    }
}

public enum TraktAuthorizationResult: Sendable, Equatable {
    case pending, slowDown, signedIn
}

public enum TraktAccountError: Error, Sendable, Equatable {
    case needsCredentials, needsSignIn, expiredCode, denied, invalidCode, credentialsChanged, invalidResponse
    case needsRedirectURI, invalidCallback, needsClientSecret
    case network(AddonError)

    public var message: String {
        switch self {
        case .needsCredentials: return "Enter your Trakt API Client ID first."
        case .needsRedirectURI: return "Enter the exact Redirect URI registered for your Trakt API app."
        case .invalidCallback: return "The Trakt sign-in callback did not match this sign-in. Start again."
        case .needsClientSecret: return "Device-code sign-in needs a Client Secret. Use PKCE sign-in instead."
        case .needsSignIn: return "Sign in to Trakt before syncing."
        case .expiredCode: return "The sign-in code expired. Start again for a new code."
        case .denied: return "Trakt sign-in was declined."
        case .invalidCode: return "This sign-in code is no longer valid. Start again."
        case .credentialsChanged: return "Your Trakt API credentials changed. Sign in again."
        case .invalidResponse: return "Trakt returned an unreadable response. Try again."
        case .network(.http(status: 401)): return "Trakt rejected the credentials. Check them and sign in again."
        case .network(.http(status: 420)): return "Your Trakt watchlist is full. Check your account limits on Trakt."
        case .network(.http(status: 429)): return "Trakt is busy. Wait a little before trying again."
        case .network: return "Couldn’t reach Trakt. Check your connection and try again."
        }
    }

    /// Worth sending again later, unchanged: the request never reached Trakt, or Trakt was busy or failing. A refused request (most 4xx),
    /// a sign-in problem or an unreadable answer is not.
    public var isTransient: Bool {
        guard case .network(let error) = self else { return false }
        switch error {
        case .timeout, .offline, .network, .cancelled: return true
        case .http(let status): return status == 408 || status == 429 || (500...599).contains(status)
        default: return false
        }
    }
}

/// A watched movie or episode. IMDb identities match the addon metadata and local progress stores.
public struct TraktWatchedItem: Sendable, Equatable {
    public let preview: MetaPreview
    public let watchedAt: Date
    public let season: Int?
    public let episode: Int?

    public init(preview: MetaPreview, watchedAt: Date, season: Int? = nil, episode: Int? = nil) {
        self.preview = preview
        self.watchedAt = watchedAt
        self.season = season
        self.episode = episode
    }

    public var contentID: String {
        if let season, let episode { return "\(preview.id):\(season):\(episode)" }
        return preview.id
    }

    public var identity: String { LibraryItem.identity(type: preview.type, contentID: contentID) }
}

/// A title on the Trakt watchlist or in the collection, with the date Trakt gives for it.
public struct TraktSavedItem: Sendable, Equatable {
    public let preview: MetaPreview
    /// When it was put on the watchlist, or collected. Nil when Trakt sent no date.
    public let addedAt: Date?

    public init(preview: MetaPreview, addedAt: Date?) {
        self.preview = preview
        self.addedAt = addedAt
    }

    /// The saved title's identity in the local library, e.g. `movie/tt1`.
    public var identity: String { LibraryItem.identity(type: preview.type, contentID: preview.id) }
}

/// When each kind of Trakt data last changed, from `sync/last_activities`. Comparing two of these says what to fetch again.
public struct TraktLastActivities: Sendable, Codable, Equatable {
    public var watchlist: Date?
    public var collection: Date?
    public var watched: Date?
    public var playback: Date?

    public init(watchlist: Date? = nil, collection: Date? = nil, watched: Date? = nil, playback: Date? = nil) {
        self.watchlist = watchlist
        self.collection = collection
        self.watched = watched
        self.playback = playback
    }
}

/// OAuth credentials live only in the supplied SecretStore. Sync adds items; removals happen only through the explicit remove calls.
public actor TraktAccount {
    public enum Keys {
        public static let clientSecret = "trakt.account.clientSecret"
        public static let token = "trakt.account.token"
        public static let redirectURI = "trakt.account.redirectURI"
    }

    private struct Token: Codable, Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let createdAt: Int
        var clientID: String?
        var redirectURI: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", createdAt = "created_at", clientID, redirectURI
        }

        var expiresAt: Date { Date(timeIntervalSince1970: Double(createdAt) + Double(expiresIn)) }
    }

    private let settings: any SettingsStore
    private let secrets: any SecretStore
    private let transport: any HTTPTransport
    private let baseURL: URL
    private let now: @Sendable () -> Date
    private var credentialsRevision = 0
    private var pendingPKCE: (clientID: String, redirectURI: String, verifier: String, state: String, revision: Int)?

    public init(settings: any SettingsStore, secrets: any SecretStore, transport: (any HTTPTransport)? = nil,
                baseURL: URL = TraktClient.defaultBaseURL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.settings = settings
        self.secrets = secrets
        self.transport = transport ?? URLSessionTransport()
        self.baseURL = baseURL
        self.now = now
    }

    public func clientSecret() async -> String { (try? await secrets.get(Keys.clientSecret)) ?? "" }

    public func redirectURI() async -> String { (try? await secrets.get(Keys.redirectURI)) ?? "" }

    /// The verifier stays in memory for one browser sign-in; only tokens are saved.
    public func beginPKCESignIn(redirectURI: String, codeVerifier: String, codeChallenge: String) async throws -> URL {
        let (clientID, _) = try await credentials()
        guard let redirect = URL(string: redirectURI), let scheme = redirect.scheme,
              (scheme == "https" && redirect.host != nil) || scheme == "blusion" || redirectURI == "urn:ietf:wg:oauth:2.0:oob",
              redirect.fragment == nil, redirect.query == nil, redirect.user == nil, redirect.password == nil else {
            throw TraktAccountError.needsRedirectURI
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard (43...128).contains(codeVerifier.count), codeVerifier.unicodeScalars.allSatisfy(allowed.contains),
              codeChallenge.count == 43 else { throw TraktAccountError.invalidCode }
        let state = UUID().uuidString
        pendingPKCE = (clientID, redirectURI, codeVerifier, state, credentialsRevision)
        var url = URLComponents(string: "https://auth.trakt.tv/oauth/authorize")!
        url.queryItems = [URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "redirect_uri", value: redirectURI),
                         URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "state", value: state),
                         URLQueryItem(name: "code_challenge", value: codeChallenge), URLQueryItem(name: "code_challenge_method", value: "S256")]
        return url.url!
    }

    public func finishPKCESignIn(callbackURL: URL) async throws {
        guard let pending = pendingPKCE, let redirect = URL(string: pending.redirectURI),
              callbackURL.scheme == redirect.scheme, callbackURL.host == redirect.host, callbackURL.port == redirect.port,
              callbackURL.path == redirect.path, callbackURL.fragment == nil,
              let query = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
              query.filter({ $0.name == "state" }).count == 1,
              query.first(where: { $0.name == "state" })?.value == pending.state else { throw TraktAccountError.invalidCallback }
        if query.contains(where: { $0.name == "error" }) { throw TraktAccountError.denied }
        guard query.filter({ $0.name == "code" }).count == 1,
              let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw TraktAccountError.invalidCode }
        try await exchangePKCECode(code, pending: pending)
    }

    /// For Trakt apps already registered with the legacy out-of-band callback.
    public func finishPKCESignIn(code: String) async throws {
        guard let pending = pendingPKCE, pending.redirectURI == "urn:ietf:wg:oauth:2.0:oob" else { throw TraktAccountError.invalidCallback }
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw TraktAccountError.invalidCode }
        try await exchangePKCECode(code, pending: pending)
    }

    public func cancelPKCESignIn() { pendingPKCE = nil }

    private func exchangePKCECode(_ code: String, pending: (clientID: String, redirectURI: String, verifier: String, state: String, revision: Int)) async throws {
        let currentClientID = await settings.load().traktClientID
        guard pendingPKCE?.state == pending.state, pending.revision == credentialsRevision,
              currentClientID == pending.clientID else { throw TraktAccountError.credentialsChanged }
        let result = try await request(path: "oauth/token", clientID: pending.clientID,
                                      body: ["code": code, "client_id": pending.clientID, "redirect_uri": pending.redirectURI,
                                             "code_verifier": pending.verifier, "grant_type": "authorization_code"])
        try checkStatus(result)
        var token = try token(from: result.data)
        token.clientID = pending.clientID
        token.redirectURI = pending.redirectURI
        try Task.checkCancellation()
        let savedClientID = await settings.load().traktClientID
        guard pendingPKCE?.state == pending.state, pending.revision == credentialsRevision,
              savedClientID == pending.clientID else { throw TraktAccountError.credentialsChanged }
        pendingPKCE = nil
        try await save(token)
    }

    public func saveClientSecret(_ value: String) async throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != (try await secrets.get(Keys.clientSecret) ?? "") else { return }
        credentialsRevision += 1
        try await secrets.remove(Keys.token)
        if value.isEmpty { try await secrets.remove(Keys.clientSecret) } else { try await secrets.set(value, for: Keys.clientSecret) }
    }

    public func isSignedIn() async -> Bool {
        guard let token = try? await loadToken(), let clientID = await settings.load().traktClientID else { return false }
        return token.clientID == clientID
    }

    public func beginSignIn() async throws -> TraktDeviceCode {
        let (clientID, clientSecret) = try await credentials()
        guard !clientSecret.isEmpty else { throw TraktAccountError.needsClientSecret }
        return try await decode(TraktDeviceCode.self, path: "oauth/device/code", body: ["client_id": clientID])
    }

    public func checkAuthorization(_ code: TraktDeviceCode) async throws -> TraktAuthorizationResult {
        let revision = credentialsRevision
        let (clientID, clientSecret) = try await credentials()
        guard !clientSecret.isEmpty else { throw TraktAccountError.needsClientSecret }
        let result = try await request(path: "oauth/device/token", clientID: clientID,
                                       body: ["code": code.deviceCode, "client_id": clientID, "client_secret": clientSecret])
        switch result.response.statusCode {
        case 400: return .pending
        case 429: return .slowDown
        case 404, 409: throw TraktAccountError.invalidCode
        case 410: throw TraktAccountError.expiredCode
        case 418: throw TraktAccountError.denied
        case 200:
            var token = try token(from: result.data)
            token.clientID = clientID
            try Task.checkCancellation()
            guard revision == credentialsRevision else { throw TraktAccountError.credentialsChanged }
            try await save(token)
            return .signedIn
        default: throw TraktAccountError.network(.http(status: result.response.statusCode))
        }
    }

    /// Removes the local token immediately, then best-effort revokes the remote token.
    public func signOut() async {
        let token = try? await loadToken()
        let credentials = try? await credentials()
        credentialsRevision += 1
        pendingPKCE = nil
        try? await secrets.remove(Keys.token)
        if let token, let (clientID, clientSecret) = credentials {
            var body = ["token": token.accessToken, "client_id": clientID]
            if token.redirectURI == nil { body["client_secret"] = clientSecret }
            _ = try? await request(path: "oauth/revoke", clientID: clientID,
                                   body: body)
        }
    }

    public func clearCredentials() async {
        credentialsRevision += 1
        pendingPKCE = nil
        try? await secrets.remove(Keys.token)
        try? await secrets.remove(Keys.clientSecret)
        try? await secrets.remove(Keys.redirectURI)
    }

    /// A signed-in GET of an API path with its query, such as `users/me/lists`, for the Trakt list browser. The token is refreshed like
    /// every call here. Throws `needsSignIn` when nobody is signed in.
    public func get(_ path: String) async throws -> HTTPResult {
        try await authorizedRequest(path: path)
    }

    public func watchlist() async throws -> [MetaPreview] {
        try await watchlistEntries().map(\.preview)
    }

    /// Watchlist titles with the date each was listed.
    public func watchlistEntries() async throws -> [TraktSavedItem] {
        var items: [TraktSavedItem] = []
        var page = 1
        while true {
            let result = try await authorizedRequest(path: "sync/watchlist?page=\(page)&limit=100&extended=full")
            let entries = try decodeEntries(result.data)
            items += entries.compactMap(\.watchlistItem)
            let pageCount = result.response.headers["x-pagination-page-count"].flatMap(Int.init) ?? 1
            guard page < pageCount else { return items }
            page += 1
        }
    }

    /// Collected movies and shows map to saved titles; collection membership does not mark them watched.
    public func collection() async throws -> [MetaPreview] {
        try await collectionEntries().map(\.preview)
    }

    /// Collected titles with the date each was collected: movies by `collected_at`, shows by `last_collected_at`.
    public func collectionEntries() async throws -> [TraktSavedItem] {
        var items: [TraktSavedItem] = []
        var page = 1
        while true {
            let result = try await authorizedRequest(path: "sync/collection/movies?page=\(page)&limit=100&extended=full")
            items += try decodeEntries(result.data).compactMap(\.collectionItem)
            let pageCount = result.response.headers["x-pagination-page-count"].flatMap(Int.init) ?? 1
            guard page < pageCount else { break }
            page += 1
        }
        let shows = try await authorizedRequest(path: "sync/collection/shows?extended=full")
        return items + (try decodeEntries(shows.data).compactMap(\.collectionItem))
    }

    public func watched() async throws -> [TraktWatchedItem] {
        let movies = try await authorizedRequest(path: "sync/watched/movies?extended=full")
        let shows = try await authorizedRequest(path: "sync/watched/shows?extended=full")
        return try (decodeEntries(movies.data) + decodeEntries(shows.data)).flatMap(\.watchedItems)
    }

    /// Paused movies and episodes, authenticated with the same persisted/refreshable token as library sync.
    public func playback() async throws -> [TraktPlaybackItem] {
        var items: [TraktPlaybackItem] = []
        var page = 1
        while true {
            let result = try await authorizedRequest(path: "sync/playback?page=\(page)&limit=100&extended=full")
            items += try TraktPlaybackItem.decode(result.data)
            let pages = result.response.headers["x-pagination-page-count"].flatMap(Int.init) ?? 1
            guard page < pages else { return items.sorted { $0.pausedAt > $1.pausedAt } }
            page += 1
        }
    }

    /// Removes one paused record, so Trakt stops offering it under Continue Watching.
    public func removePlayback(id: Int) async throws {
        _ = try await authorizedRequest(path: "sync/playback/\(id)", method: "DELETE")
    }

    public func addToWatchlist(_ items: [MetaPreview]) async throws -> Int {
        let payload = Self.watchlistPayload(items)
        guard !payload.isEmpty else { return 0 }
        let result = try await authorizedRequest(path: "sync/watchlist", body: payload)
        return try addedCount(result.data)
    }

    /// Call with records missing on Trakt to avoid sending duplicate watches.
    public func addToHistory(_ items: [TraktWatchedItem]) async throws -> Int {
        let payload = Self.historyPayload(items)
        guard !payload.isEmpty else { return 0 }
        let result = try await authorizedRequest(path: "sync/history", body: payload)
        return try addedCount(result.data)
    }

    /// Only this explicit call removes watchlist items; sync never does.
    public func removeFromWatchlist(_ items: [MetaPreview]) async throws -> Int {
        let payload = Self.watchlistPayload(items)
        guard !payload.isEmpty else { return 0 }
        let result = try await authorizedRequest(path: "sync/watchlist/remove", body: payload)
        return try deletedCount(result.data)
    }

    /// Only this explicit call removes history records; sync never does. Trakt matches by title and episode, so no dates are sent.
    public func removeFromHistory(_ items: [TraktWatchedItem]) async throws -> Int {
        let payload = Self.historyPayload(items, dated: false)
        guard !payload.isEmpty else { return 0 }
        let result = try await authorizedRequest(path: "sync/history/remove", body: payload)
        return try deletedCount(result.data)
    }

    /// Sends the paused position so Trakt can offer the title under Continue Watching. Progress is a percentage, clamped to 0...100.
    /// A 409 means Trakt just recorded the same item, which counts as saved.
    public func savePlayback(_ item: TraktWatchedItem, progress: Double) async throws {
        let percent = progress.isNaN ? 0 : min(max(progress, 0), 100)
        guard let payload = Self.playbackPayload(item, progress: percent) else { return }
        _ = try await authorizedRequest(path: "scrobble/pause", body: payload, accepting: [409])
    }

    /// Latest change date per kind of Trakt data. Throws `invalidResponse` when the answer is unreadable.
    public func lastActivities() async throws -> TraktLastActivities {
        let result = try await authorizedRequest(path: "sync/last_activities")
        guard let activities = try? JSONDecoder().decode(TraktActivitiesResponse.self, from: result.data) else {
            throw TraktAccountError.invalidResponse
        }
        return activities.activities
    }

    private func credentials() async throws -> (String, String) {
        let clientID = (await settings.load().traktClientID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = try await secrets.get(Keys.clientSecret) ?? ""
        guard !clientID.isEmpty else { throw TraktAccountError.needsCredentials }
        return (clientID, clientSecret)
    }

    private func loadToken() async throws -> Token? {
        guard let text = try await secrets.get(Keys.token) else { return nil }
        return try? JSONDecoder().decode(Token.self, from: Data(text.utf8))
    }

    private func save(_ token: Token) async throws {
        let data = try JSONEncoder().encode(token)
        try await secrets.set(String(decoding: data, as: UTF8.self), for: Keys.token)
    }

    private func token(from data: Data) throws -> Token {
        guard let token = try? JSONDecoder().decode(Token.self, from: data), !token.accessToken.isEmpty,
              !token.refreshToken.isEmpty, token.expiresIn > 0 else { throw TraktAccountError.invalidResponse }
        return token
    }

    private func refreshed(_ old: Token, clientID: String, clientSecret: String) async throws -> Token {
        let revision = credentialsRevision
        var body = ["refresh_token": old.refreshToken, "client_id": clientID,
                    "redirect_uri": old.redirectURI ?? "urn:ietf:wg:oauth:2.0:oob", "grant_type": "refresh_token"]
        if old.redirectURI == nil { body["client_secret"] = clientSecret }
        let result = try await request(path: "oauth/token", clientID: clientID, body: body)
        try checkStatus(result)
        var token = try token(from: result.data)
        token.clientID = clientID
        token.redirectURI = old.redirectURI
        try Task.checkCancellation()
        guard revision == credentialsRevision else { throw TraktAccountError.credentialsChanged }
        try await save(token)
        return token
    }

    private func authorizedRequest(path: String, body: [String: Any]? = nil, method: String? = nil, accepting: Set<Int> = []) async throws -> HTTPResult {
        let (clientID, clientSecret) = try await credentials()
        guard var token = try await loadToken() else { throw TraktAccountError.needsSignIn }
        guard token.clientID == clientID else { throw TraktAccountError.credentialsChanged }
        if token.expiresAt <= now().addingTimeInterval(60) {
            token = try await refreshed(token, clientID: clientID, clientSecret: clientSecret)
        }
        var result = try await request(path: path, clientID: clientID, accessToken: token.accessToken, body: body, method: method)
        if result.response.statusCode == 401 {
            token = try await refreshed(token, clientID: clientID, clientSecret: clientSecret)
            result = try await request(path: path, clientID: clientID, accessToken: token.accessToken, body: body, method: method)
        }
        try checkStatus(result, accepting: accepting)
        return result
    }

    private func decode<T: Decodable>(_ type: T.Type, path: String, body: [String: Any]) async throws -> T {
        let result = try await request(path: path, body: body)
        try checkStatus(result)
        guard let value = try? JSONDecoder().decode(type, from: result.data) else { throw TraktAccountError.invalidResponse }
        return value
    }

    private func request(path: String, clientID: String? = nil, accessToken: String? = nil, body: [String: Any]? = nil,
                         method: String? = nil) async throws -> HTTPResult {
        guard let url = URL(string: path, relativeTo: baseURL.appendingPathComponent("/"))?.absoluteURL,
              url.scheme == "https" || url.scheme == "http" else { throw TraktAccountError.network(.invalidURL) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method ?? (body == nil ? "GET" : "POST")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (field, value) in TraktHeaders.common(clientID: clientID) { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("Blusion/1.0", forHTTPHeaderField: "User-Agent")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        do {
            return try await withDeadline(seconds: 20) { [request, transport] in
                try await transport.send(request, limits: FetchLimits(maxRedirects: 0))
            }
        } catch {
            throw TraktAccountError.network(AddonError.from(error))
        }
    }

    private func checkStatus(_ result: HTTPResult, accepting: Set<Int> = []) throws {
        guard (200...299).contains(result.response.statusCode) || accepting.contains(result.response.statusCode) else {
            throw TraktAccountError.network(.http(status: result.response.statusCode))
        }
    }

    private func decodeEntries(_ data: Data) throws -> [TraktSyncEntry] {
        guard let entries = try? JSONDecoder().decode([TraktSyncEntry].self, from: data) else { throw TraktAccountError.invalidResponse }
        return entries
    }

    private func addedCount(_ data: Data) throws -> Int {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let added = body["added"] as? [String: Int] else {
            throw TraktAccountError.invalidResponse
        }
        return added.values.reduce(0, +)
    }

    private func deletedCount(_ data: Data) throws -> Int {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let deleted = body["deleted"] as? [String: Int] else {
            throw TraktAccountError.invalidResponse
        }
        return deleted.values.reduce(0, +)
    }

    private static func watchlistPayload(_ items: [MetaPreview]) -> [String: Any] {
        let movies = items.filter { $0.type == "movie" && isIMDb($0.id) }.map { ["ids": ["imdb": $0.id]] }
        let shows = items.filter { $0.type == "series" && isIMDb($0.id) }.map { ["ids": ["imdb": $0.id]] }
        var payload: [String: Any] = [:]
        if !movies.isEmpty { payload["movies"] = movies }
        if !shows.isEmpty { payload["shows"] = shows }
        return payload
    }

    /// Additions carry `watched_at`; removals pass `dated: false` and send the same titles and episodes without dates.
    private static func historyPayload(_ items: [TraktWatchedItem], dated: Bool = true) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        func stamped(_ item: TraktWatchedItem, _ fields: [String: Any]) -> [String: Any] {
            guard dated else { return fields }
            return fields.merging(["watched_at": formatter.string(from: item.watchedAt)]) { $1 }
        }
        let movies: [[String: Any]] = items.filter { $0.preview.type == "movie" && isIMDb($0.preview.id) }.map {
            stamped($0, ["ids": ["imdb": $0.preview.id]])
        }
        let episodes = items.filter { $0.preview.type == "series" && isIMDb($0.preview.id) && $0.season != nil && $0.episode != nil }
        let shows: [[String: Any]] = Dictionary(grouping: episodes, by: { $0.preview.id }).sorted { $0.key < $1.key }.map { id, records in
            let seasons: [[String: Any]] = Dictionary(grouping: records, by: { $0.season ?? 0 }).sorted { $0.key < $1.key }.map { season, records in
                let episodes: [[String: Any]] = records.map { stamped($0, ["number": $0.episode ?? 0]) }
                return ["number": season, "episodes": episodes]
            }
            return ["ids": ["imdb": id], "seasons": seasons]
        }
        var payload: [String: Any] = [:]
        if !movies.isEmpty { payload["movies"] = movies }
        if !shows.isEmpty { payload["shows"] = shows }
        return payload
    }

    /// A movie, or an episode with its season and number. Nil for anything Trakt cannot match by IMDb id.
    private static func playbackPayload(_ item: TraktWatchedItem, progress: Double) -> [String: Any]? {
        if item.preview.type == "movie", isIMDb(item.preview.id) {
            return ["movie": ["ids": ["imdb": item.preview.id]], "progress": progress]
        }
        guard item.preview.type == "series", isIMDb(item.preview.id), let season = item.season, let episode = item.episode else { return nil }
        return ["show": ["ids": ["imdb": item.preview.id]], "episode": ["season": season, "number": episode], "progress": progress]
    }

    public static func isIMDb(_ id: String) -> Bool {
        id.hasPrefix("tt") && id.count > 2 && id.dropFirst(2).allSatisfy(\.isNumber)
    }
}

private struct TraktSyncEntry: Decodable {
    struct Media: Decodable {
        struct IDs: Decodable { let imdb: String? }
        let title: String?
        let year: Int?
        let ids: IDs?

        func preview(type: String) -> MetaPreview? {
            guard let id = ids?.imdb, TraktAccount.isIMDb(id) else { return nil }
            return MetaPreview(id: id, type: type, name: title, poster: MetahubArtwork.poster(imdbID: id),
                               releaseInfo: year.map(String.init))
        }
    }

    struct Season: Decodable {
        struct Episode: Decodable {
            let number: Int
            let lastWatchedAt: String?
            enum CodingKeys: String, CodingKey { case number, lastWatchedAt = "last_watched_at" }
        }
        let number: Int
        let episodes: [Episode]
    }

    let movie: Media?
    let show: Media?
    let lastWatchedAt: String?
    let seasons: [Season]?
    let listedAt: String?
    let collectedAt: String?
    let lastCollectedAt: String?
    enum CodingKeys: String, CodingKey {
        case movie, show, seasons, lastWatchedAt = "last_watched_at", listedAt = "listed_at", collectedAt = "collected_at", lastCollectedAt = "last_collected_at"
    }

    var watchlistPreview: MetaPreview? { movie?.preview(type: "movie") ?? show?.preview(type: "series") }

    var watchlistItem: TraktSavedItem? {
        guard let preview = watchlistPreview else { return nil }
        return TraktSavedItem(preview: preview, addedAt: Self.date(listedAt))
    }

    var collectionItem: TraktSavedItem? {
        if let preview = movie?.preview(type: "movie") { return TraktSavedItem(preview: preview, addedAt: Self.date(collectedAt)) }
        guard let preview = show?.preview(type: "series") else { return nil }
        return TraktSavedItem(preview: preview, addedAt: Self.date(lastCollectedAt))
    }

    var watchedItems: [TraktWatchedItem] {
        if let preview = movie?.preview(type: "movie"), let date = Self.date(lastWatchedAt) {
            return [TraktWatchedItem(preview: preview, watchedAt: date)]
        }
        guard let preview = show?.preview(type: "series") else { return [] }
        return (seasons ?? []).flatMap { season in
            season.episodes.compactMap { episode in
                guard let date = Self.date(episode.lastWatchedAt) else { return nil }
                return TraktWatchedItem(preview: preview, watchedAt: date, season: season.number, episode: episode.number)
            }
        }
    }

    fileprivate static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// The `sync/last_activities` answer. Every key is optional, so a partial or newer answer still decodes.
private struct TraktActivitiesResponse: Decodable {
    struct Section: Decodable {
        let watchlistedAt: String?
        let collectedAt: String?
        let watchedAt: String?
        let pausedAt: String?
        enum CodingKeys: String, CodingKey {
            case watchlistedAt = "watchlisted_at", collectedAt = "collected_at", watchedAt = "watched_at", pausedAt = "paused_at"
        }
    }

    struct Watchlist: Decodable {
        let updatedAt: String?
        enum CodingKeys: String, CodingKey { case updatedAt = "updated_at" }
    }

    let movies: Section?
    let episodes: Section?
    let shows: Section?
    let seasons: Section?
    let watchlist: Watchlist?

    /// The latest date in each group; a group with no dates stays nil.
    var activities: TraktLastActivities {
        func latest(_ texts: [String?]) -> Date? { texts.compactMap { TraktSyncEntry.date($0) }.max() }
        return TraktLastActivities(
            watchlist: latest([movies?.watchlistedAt, shows?.watchlistedAt, seasons?.watchlistedAt, episodes?.watchlistedAt, watchlist?.updatedAt]),
            collection: latest([movies?.collectedAt, episodes?.collectedAt]),
            watched: latest([movies?.watchedAt, episodes?.watchedAt]),
            playback: latest([movies?.pausedAt, episodes?.pausedAt]))
    }
}
