import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AddonClientConfiguration: Sendable, Equatable {
    /// Overall deadline for one request, retries included. Catalog, meta and subtitle requests use it.
    public var timeout: TimeInterval
    /// Overall deadline for stream requests, which aggregating stream addons often need longer for. `nil` means `timeout`.
    public var streamTimeout: TimeInterval?
    public var maxBytes: Int
    /// Retries after the first attempt, for idempotent GETs that failed transiently (timeouts, connection loss, 5xx, 429).
    public var maxRetries: Int
    /// First retry waits `retryBackoff`, the next `2 x retryBackoff`, and so on.
    public var retryBackoff: TimeInterval
    public var maxRedirects: Int
    public var userAgent: String

    public init(timeout: TimeInterval = 15, streamTimeout: TimeInterval? = nil, maxBytes: Int = 5 * 1024 * 1024, maxRetries: Int = 2,
                retryBackoff: TimeInterval = 0.25, maxRedirects: Int = 5, userAgent: String = StremioKitInfo.userAgent) {
        self.timeout = timeout
        self.streamTimeout = streamTimeout
        self.maxBytes = maxBytes
        self.maxRetries = maxRetries
        self.retryBackoff = retryBackoff
        self.maxRedirects = maxRedirects
        self.userAgent = userAgent
    }

    /// The deadline stream requests run under.
    public var effectiveStreamTimeout: TimeInterval { streamTimeout ?? timeout }

    public static let `default` = AddonClientConfiguration(timeout: 15, streamTimeout: 30)
}

/// Talks to addons. Every failure is an `AddonError`; no error or log line ever contains an addon URL.
public final class AddonClient: Sendable {
    public let configuration: AddonClientConfiguration
    private let transport: any HTTPTransport
    private let logger: AddonLogger

    public init(configuration: AddonClientConfiguration = .default,
                transport: (any HTTPTransport)? = nil,
                logger: AddonLogger = .silent) {
        self.configuration = configuration
        self.transport = transport ?? URLSessionTransport()
        self.logger = logger
    }

    /// GET with a deadline, bounded retries and status mapping. 2xx returns; 404 is `notFound`; other statuses are `http`.
    /// `timeout` (nil: `configuration.timeout`) bounds the whole call, retries included, and is each attempt's own timeout.
    public func get(_ url: URL, headers: [String: String] = [:], limits: FetchLimits? = nil, timeout: TimeInterval? = nil) async throws -> HTTPResult {
        let limits = limits ?? FetchLimits(maxBytes: configuration.maxBytes, maxRedirects: configuration.maxRedirects)
        let timeout = timeout ?? configuration.timeout
        let started = Date()
        do {
            let result = try await withDeadline(seconds: timeout) { [self] in
                try await getWithRetries(url, headers: headers, limits: limits, timeout: timeout)
            }
            logger.log(.debug, "GET \(Redactor.redact(url)) -> \(result.response.statusCode) (\(result.data.count) B, \(Self.millis(since: started)) ms)")
            return result
        } catch {
            let mapped = AddonError.from(error)
            logger.log(.warning, "GET \(Redactor.redact(url)) failed: \(mapped.shortDescription) after \(Self.millis(since: started)) ms")
            throw mapped
        }
    }

    /// First bytes of a resource, for container sniffing. Asks for a range, and cuts the body short if the server ignores it.
    public func prefix(of url: URL, bytes: Int = 4096, headers: [String: String] = [:]) async throws -> (data: Data, contentType: String?) {
        var headers = headers
        headers["Range"] = "bytes=0-\(max(bytes, 1) - 1)"
        let result = try await get(url, headers: headers, limits: FetchLimits(maxBytes: bytes, truncateAtLimit: true, maxRedirects: configuration.maxRedirects))
        return (result.data, result.response.contentType)
    }

    /// `length` bytes from `offset`, for reading the head and tail of a file (`MovieHash`). The total size comes from `Content-Range`, and is
    /// nil when the server does not know it. A server that ignores the range and sends the whole body is accepted only for offset 0, and cut
    /// to `length`; any other answer means the range cannot be served, and fails as `http(416)`.
    public func range(of url: URL, offset: Int64, length: Int, headers: [String: String] = [:]) async throws -> (data: Data, totalLength: Int64?) {
        guard offset >= 0, length > 0 else { throw AddonError.http(status: 416) }
        var headers = headers
        headers["Range"] = "bytes=\(offset)-\(offset + Int64(length) - 1)"
        let result = try await get(url, headers: headers, limits: FetchLimits(maxBytes: length, truncateAtLimit: true, maxRedirects: configuration.maxRedirects))
        switch result.response.statusCode {
        case 206:
            return (result.data.prefix(length), Self.totalLength(contentRange: result.response.headers["content-range"]))
        case 200 where offset == 0:
            return (result.data.prefix(length), nil)
        default:
            throw AddonError.http(status: 416)
        }
    }

    /// The `TOTAL` of `bytes a-b/TOTAL`. nil for `*` or anything unparsable.
    private static func totalLength(contentRange: String?) -> Int64? {
        guard let total = contentRange?.split(separator: "/").last else { return nil }
        return Int64(total.trimmingCharacters(in: .whitespaces))
    }

    private func getWithRetries(_ url: URL, headers: [String: String], limits: FetchLimits, timeout: TimeInterval) async throws -> HTTPResult {
        var attempt = 0
        while true {
            do {
                return try await attemptOnce(url, headers: headers, limits: limits, timeout: timeout)
            } catch let error as AddonError {
                guard error.isRetryable, attempt < configuration.maxRetries else { throw error }
                logger.log(.debug, "retry \(attempt + 1)/\(configuration.maxRetries) for \(Redactor.redact(url)) after \(error.shortDescription)")
                try await Task.sleep(for: .seconds(configuration.retryBackoff * pow(2, Double(attempt))))
                attempt += 1
            }
        }
    }

    private func attemptOnce(_ url: URL, headers: [String: String], limits: FetchLimits, timeout: TimeInterval) async throws -> HTTPResult {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { throw AddonError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, */*;q=0.5", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let result: HTTPResult
        do {
            result = try await transport.send(request, limits: limits)
        } catch {
            throw AddonError.from(error)   // whatever a transport throws, retry decisions see an AddonError
        }
        switch result.response.statusCode {
        case 200...299: return result
        case 404: throw AddonError.notFound
        default: throw AddonError.http(status: result.response.statusCode)
        }
    }

    private static func millis(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
}

// MARK: - Typed protocol requests

extension AddonClient {
    /// Fetches, decodes and validates a manifest. Uninstallable manifests throw `invalidManifest` with readable reasons.
    public func fetchManifest(at location: AddonLocation) async throws -> Manifest {
        let result = try await get(location.manifestURL)
        let manifest = try ResponseDecoder.manifest(from: result.data)
        let errors = manifest.validate().filter { $0.severity == .error }
        guard errors.isEmpty else { throw AddonError.invalidManifest(errors.map(\.message)) }
        return manifest
    }

    public func catalog(base: URL, type: String, id: String, extras: [ExtraParam] = []) async throws -> [MetaPreview] {
        let result = try await get(try url(base, .catalog, type, id, extras))
        return try ResponseDecoder.catalog(from: result.data, defaultType: type)
    }

    /// `notFound` when the addon answers without a usable `meta`.
    public func meta(base: URL, type: String, id: String) async throws -> MetaDetail {
        let result = try await get(try url(base, .meta, type, id))
        guard let detail = try ResponseDecoder.meta(from: result.data, defaultType: type) else { throw AddonError.notFound }
        return detail
    }

    public func streams(base: URL, type: String, id: String) async throws -> [AddonStream] {
        let result = try await get(try url(base, .stream, type, id), timeout: configuration.effectiveStreamTimeout)
        return try ResponseDecoder.streams(from: result.data)
    }

    public func subtitles(base: URL, type: String, id: String, extras: [ExtraParam] = []) async throws -> [SubtitleItem] {
        let result = try await get(try url(base, .subtitles, type, id, extras))
        return try ResponseDecoder.subtitles(from: result.data)
    }

    private func url(_ base: URL, _ resource: ResourceKind, _ type: String, _ id: String, _ extras: [ExtraParam] = []) throws -> URL {
        guard let url = AddonRequestBuilder.url(base: base, resource: resource, type: type, id: id, extras: extras) else { throw AddonError.invalidURL }
        return url
    }
}
