import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The API key every request carries, and optionally an OpenSubtitles account. Anonymous downloads work with the key alone, at a lower
/// daily quota; a username and password lift it.
public struct OpenSubtitlesCredentials: Sendable, Equatable {
    public var apiKey: String
    public var username: String?
    public var password: String?

    public init(apiKey: String, username: String? = nil, password: String? = nil) {
        self.apiKey = apiKey
        self.username = username
        self.password = password
    }
}

/// One subtitle file that a search found. `id` is the file id, which is what a download asks for.
public struct OpenSubtitlesResult: Sendable, Equatable, Identifiable {
    public let id: String
    public let fileID: Int
    /// As OpenSubtitles writes it: `en`, `pt-BR`.
    public let language: String
    public let release: String
    public let fileName: String?
    public let downloadCount: Int
    public let isHearingImpaired: Bool
    /// "Forced" subtitles: only the lines spoken in another language.
    public let isForeignPartsOnly: Bool
    public let isMachineTranslated: Bool
    /// OpenSubtitles matched this file's hash, so the subtitle was made for this exact release.
    public let matchesHash: Bool
    public let format: String?

    /// nil for a result without a file: nothing can be downloaded from it.
    fileprivate init?(item: SearchItem) {
        guard let attributes = item.attributes, let file = attributes.files?.first, let fileID = file.file_id else { return nil }
        self.id = String(fileID)
        self.fileID = fileID
        self.language = attributes.language ?? ""
        self.release = attributes.release ?? ""
        self.fileName = file.file_name
        self.downloadCount = attributes.download_count ?? 0
        self.isHearingImpaired = attributes.hearing_impaired ?? false
        self.isForeignPartsOnly = attributes.foreign_parts_only ?? false
        self.isMachineTranslated = (attributes.machine_translated ?? false) || (attributes.ai_translated ?? false)
        self.matchesHash = attributes.moviehash_match ?? false
        self.format = attributes.format
    }
}

/// A temporary link to a subtitle file, and how many downloads the key or account has left today when the server says.
public struct OpenSubtitlesDownload: Sendable, Equatable {
    public let url: URL
    public let fileName: String?
    public let remaining: Int?
}

/// Why an OpenSubtitles call failed. Network failures (offline, timeout) come through as `AddonError` instead.
public enum OpenSubtitlesError: Error, Equatable, Sendable {
    /// No API key was given. Nothing is sent.
    case missingAPIKey
    /// The key, or the account's login, was refused.
    case unauthorized
    /// The download allowance is used up. `resetTime` is the server's text for when it refills, when it sends one.
    case quotaExceeded(resetTime: String?)
    case notFound
    /// Any other failure status, such as a 5xx.
    case server(Int)
    /// A response that is not the JSON the API documents.
    case decoding
}

/// OpenSubtitles.com REST API v1: subtitle search and download links.
///
/// Requests go through `transport`, not `AddonClient.get`: the answers depend on the status and the body (a quota refusal carries its reset
/// time), and `AddonClient` only returns 2xx responses. The `client` supplies the request timeout.
public actor OpenSubtitlesClient {
    public static let defaultBaseURL = URL(string: "https://api.opensubtitles.com/api/v1") ?? URL(fileURLWithPath: "/")
    /// Enough for a long search answer; a download link is far smaller.
    private static let limits = FetchLimits(maxBytes: 2 * 1024 * 1024)

    private let client: AddonClient
    private let credentials: OpenSubtitlesCredentials
    private let baseURL: URL
    private let transport: any HTTPTransport
    /// The login token, kept for the session: a login per download would add a round trip to each one.
    private var token: String?

    public init(client: AddonClient, credentials: OpenSubtitlesCredentials, baseURL: URL = OpenSubtitlesClient.defaultBaseURL,
                transport: (any HTTPTransport)? = nil) {
        self.client = client
        self.credentials = credentials
        self.baseURL = baseURL
        self.transport = transport ?? URLSessionTransport()
    }

    /// Subtitles for a movie, or for one episode when `season` and `episode` are both given (`imdbID` is then the series).
    /// Hash matches come first, then human translations, then the most downloaded. No request is sent for an id with no digits.
    public func search(imdbID: String, season: Int?, episode: Int?, languages: [String], movieHash: String?) async throws -> [OpenSubtitlesResult] {
        let key = try apiKey()
        guard let id = Self.imdbDigits(imdbID) else { return [] }
        var query: [URLQueryItem] = []
        if let season, let episode {
            query.append(URLQueryItem(name: "parent_imdb_id", value: id))
            query.append(URLQueryItem(name: "season_number", value: String(season)))
            query.append(URLQueryItem(name: "episode_number", value: String(episode)))
        } else {
            query.append(URLQueryItem(name: "imdb_id", value: id))
        }
        // The API wants the codes sorted, so the same request always reads the same.
        let codes = Set(languages.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }).sorted()
        if !codes.isEmpty { query.append(URLQueryItem(name: "languages", value: codes.joined(separator: ","))) }
        if let hash = movieHash?.trimmingCharacters(in: .whitespaces).lowercased(), !hash.isEmpty {
            query.append(URLQueryItem(name: "moviehash", value: hash))
        }
        query.append(URLQueryItem(name: "order_by", value: "download_count"))
        let data = try await perform(try request("GET", path: "subtitles", query: query, key: key))
        return Self.sorted(try Self.results(from: data))
    }

    /// A temporary link to the subtitle file. With a username and password the account's token is used (logged in once, then kept);
    /// without them the download is anonymous. A token the server refuses is replaced once, and the download retried once.
    public func download(_ result: OpenSubtitlesResult) async throws -> OpenSubtitlesDownload {
        let key = try apiKey()
        if token == nil, let login = loginPair {
            token = try await logIn(login, key: key)
        }
        do {
            return try await link(for: result, key: key)
        } catch OpenSubtitlesError.unauthorized where token != nil {
            token = nil
            if let login = loginPair { token = try await logIn(login, key: key) }
            return try await link(for: result, key: key)
        }
    }

    // MARK: - Requests

    private func link(for result: OpenSubtitlesResult, key: String) async throws -> OpenSubtitlesDownload {
        let body = try JSONEncoder().encode(["file_id": result.fileID])
        let data = try await perform(try request("POST", path: "download", body: body, key: key, token: token))
        let answer = try Self.decode(DownloadResponse.self, from: data)
        guard let url = answer.link.flatMap({ URL(string: $0) }), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw OpenSubtitlesError.decoding
        }
        return OpenSubtitlesDownload(url: url, fileName: answer.file_name, remaining: answer.remaining)
    }

    private func logIn(_ login: (username: String, password: String), key: String) async throws -> String {
        let body = try JSONEncoder().encode(["username": login.username, "password": login.password])
        let data = try await perform(try request("POST", path: "login", body: body, key: key))
        guard let value = try Self.decode(LoginResponse.self, from: data).token, !value.isEmpty else { throw OpenSubtitlesError.decoding }
        return value
    }

    /// The trimmed key. An empty key is refused before any request is made.
    private func apiKey() throws -> String {
        let key = credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenSubtitlesError.missingAPIKey }
        return key
    }

    /// Both a username and a password, or nil: a half-filled account means an anonymous download.
    private var loginPair: (username: String, password: String)? {
        let username = credentials.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = credentials.password ?? ""
        guard !username.isEmpty, !password.isEmpty else { return nil }
        return (username, password)
    }

    /// The key goes in a header, never the URL. Query names are sorted: the API redirects a request whose parameters are out of order.
    private func request(_ method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil, key: String,
                         token: String? = nil) throws -> URLRequest {
        var parts = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        parts?.queryItems = query.isEmpty ? nil : query.sorted { $0.name < $1.name }
        guard let url = parts?.url else { throw AddonError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: client.configuration.timeout)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "Api-Key")
        request.setValue("Blusion v1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let result: HTTPResult
        do {
            result = try await transport.send(request, limits: Self.limits)
        } catch {
            throw AddonError.from(error)
        }
        if let failure = Self.failure(status: result.response.statusCode, body: result.data) { throw failure }
        return result.data
    }

    // MARK: - Pure rules

    /// The error a status and body mean, or nil for 2xx. 429 is always the quota (the API's rate limit). 406 is the quota only when its body
    /// says so, because it also answers other refusals.
    static func failure(status: Int, body: Data) -> OpenSubtitlesError? {
        switch status {
        case 200...299: return nil
        case 401, 403: return .unauthorized
        case 404: return .notFound
        case 429: return .quotaExceeded(resetTime: resetTime(in: body))
        case 406 where mentionsQuota(body): return .quotaExceeded(resetTime: resetTime(in: body))
        default: return .server(status)
        }
    }

    /// The digits of an IMDb id, without `tt` and leading zeros: `tt0111161` is `111161`. nil when there are no digits.
    static func imdbDigits(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("tt") { text.removeFirst(2) }
        let digits = text.drop { $0 == "0" }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(digits)
    }

    /// Hash matches first (the same release), then human translations, then the most downloaded. Ties keep the server's order.
    static func sorted(_ results: [OpenSubtitlesResult]) -> [OpenSubtitlesResult] {
        results.enumerated().sorted { lhs, rhs in
            let a = lhs.element
            let b = rhs.element
            if a.matchesHash != b.matchesHash { return a.matchesHash }
            if a.isMachineTranslated != b.isMachineTranslated { return !a.isMachineTranslated }
            if a.downloadCount != b.downloadCount { return a.downloadCount > b.downloadCount }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func results(from data: Data) throws -> [OpenSubtitlesResult] {
        let response = try decode(SearchResponse.self, from: data)
        return (response.data ?? []).compactMap { OpenSubtitlesResult(item: $0) }
    }

    private static func mentionsQuota(_ body: Data) -> Bool {
        let text = String(decoding: body, as: UTF8.self)
        return text.contains("remaining") || text.contains("reset_time")
    }

    private static func resetTime(in body: Data) -> String? {
        (try? JSONDecoder().decode(QuotaBody.self, from: body))?.reset_time
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw OpenSubtitlesError.decoding
        }
    }
}

// MARK: - Wire format

/// Only the fields the app uses; all optional, so a missing one never fails the whole answer.
private struct SearchResponse: Decodable {
    let data: [SearchItem]?
}

private struct SearchItem: Decodable {
    let attributes: SearchAttributes?
}

private struct SearchAttributes: Decodable {
    let language: String?
    let release: String?
    let download_count: Int?
    let hearing_impaired: Bool?
    let foreign_parts_only: Bool?
    let machine_translated: Bool?
    let ai_translated: Bool?
    let moviehash_match: Bool?
    let format: String?
    let files: [SearchFile]?
}

private struct SearchFile: Decodable {
    let file_id: Int?
    let file_name: String?
}

private struct LoginResponse: Decodable {
    let token: String?
}

private struct DownloadResponse: Decodable {
    let link: String?
    let file_name: String?
    let remaining: Int?
}

private struct QuotaBody: Decodable {
    let reset_time: String?
}
