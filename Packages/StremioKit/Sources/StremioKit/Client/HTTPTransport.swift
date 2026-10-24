import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct FetchLimits: Sendable, Equatable {
    /// Largest body accepted. Beyond it the fetch fails with `responseTooLarge`, or is cut short when `truncateAtLimit` is set.
    public var maxBytes: Int
    /// Return the first `maxBytes` instead of failing (used for container sniffing, where only the first bytes matter).
    public var truncateAtLimit: Bool
    public var maxRedirects: Int

    public init(maxBytes: Int = 5 * 1024 * 1024, truncateAtLimit: Bool = false, maxRedirects: Int = 5) {
        self.maxBytes = maxBytes
        self.truncateAtLimit = truncateAtLimit
        self.maxRedirects = maxRedirects
    }
}

/// The parts of an HTTP response the client needs. A plain value, so it is trivially `Sendable`.
public struct HTTPResponseInfo: Sendable, Equatable {
    public var statusCode: Int
    /// Lower-cased header names.
    public var headers: [String: String]
    public var url: URL?

    public init(statusCode: Int, headers: [String: String] = [:], url: URL? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.url = url
    }

    public var contentType: String? { headers["content-type"] }
}

public struct HTTPResult: Sendable, Equatable {
    public var data: Data
    public var response: HTTPResponseInfo
    public var truncated: Bool

    public init(data: Data, response: HTTPResponseInfo, truncated: Bool = false) {
        self.data = data
        self.response = response
        self.truncated = truncated
    }
}

/// Seam between `AddonClient` and the network, so retry and error logic can be tested with a stub.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, limits: FetchLimits) async throws -> HTTPResult
}

extension AddonError {
    /// Maps any thrown error to an `AddonError` without ever carrying a URL.
    public static func from(_ error: Error) -> AddonError {
        if let addon = error as? AddonError { return addon }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timeout
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .offline
            case .badURL, .unsupportedURL: return .invalidURL
            case .httpTooManyRedirects: return .tooManyRedirects
            default: return .network("urlerror.\(urlError.code.rawValue)")
            }
        }
        return .network("error")
    }
}

/// Redirect decisions, kept pure so they are unit-testable.
public enum RedirectPolicy {
    /// http(s) only, and never https -> http for a non-LAN host (addon URLs can carry a token).
    public static func allows(from: URL?, to: URL) -> Bool {
        guard let scheme = to.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        if from?.scheme?.lowercased() == "https", scheme == "http", !HostClassifier.isLAN(to.host ?? "") { return false }
        return true
    }
}

// MARK: - URLSession implementation

/// Streams the body so the size cap is enforced before a huge response is buffered, follows a bounded number of redirects,
/// and cancels the underlying task when the calling task is cancelled.
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let delegate: FetchDelegate

    public init(configuration: URLSessionConfiguration = URLSessionTransport.defaultConfiguration()) {
        let delegate = FetchDelegate()
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Protocol caching on (URLCache), no cookies, no credentials storage: addons are anonymous GETs.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpMaximumConnectionsPerHost = 6
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation: memory cache only, and `waitsForConnectivity` is read-only.
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 0, diskPath: nil)
        #else
        configuration.waitsForConnectivity = false
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024, directory: nil)
        #endif
        return configuration
    }

    public func send(_ request: URLRequest, limits: FetchLimits) async throws -> HTTPResult {
        let handle = CancelHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResult, Error>) in
                let task = session.dataTask(with: request)
                delegate.register(taskID: task.taskIdentifier, limits: limits, continuation: continuation)
                task.resume()
                handle.attach(task)
            }
        } onCancel: {
            handle.cancel()
        }
    }
}

/// Lets `onCancel` reach a task that may not exist yet.
private final class CancelHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func attach(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

private final class FetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// A class on purpose: mutated in place under the lock. As a struct, every appended chunk copied the whole buffer
    /// (quadratic for a multi-megabyte body), stalling every other task's delegate callbacks behind the lock.
    private final class Pending {
        let limits: FetchLimits
        let continuation: CheckedContinuation<HTTPResult, Error>
        var buffer = Data()
        var info: HTTPResponseInfo?
        var redirects = 0
        var failure: AddonError?
        var truncated = false

        init(limits: FetchLimits, continuation: CheckedContinuation<HTTPResult, Error>) {
            self.limits = limits
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]

    func register(taskID: Int, limits: FetchLimits, continuation: CheckedContinuation<HTTPResult, Error>) {
        lock.withLock { pending[taskID] = Pending(limits: limits, continuation: continuation) }
    }

    /// Looks the entry up under the lock, then runs `body` on it outside the lock (each entry is only touched from the
    /// session's serial delegate queue, so no two callbacks for one task overlap).
    private func withPending<T>(_ id: Int, _ body: (Pending) -> T) -> T? {
        guard let entry = lock.withLock({ pending[id] }) else { return nil }
        return body(entry)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let info = Self.info(from: response)
        let allow = withPending(dataTask.taskIdentifier) { entry -> Bool in
            entry.info = info
            if let length = info.headers["content-length"].flatMap({ Int($0) }), length > entry.limits.maxBytes, !entry.limits.truncateAtLimit {
                entry.failure = .responseTooLarge(limit: entry.limits.maxBytes)
                return false
            }
            return true
        } ?? false
        completionHandler(allow ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = withPending(dataTask.taskIdentifier) { entry -> Bool in
            entry.buffer.append(data)
            guard entry.buffer.count > entry.limits.maxBytes else { return false }
            if entry.limits.truncateAtLimit {
                entry.buffer = entry.buffer.prefix(entry.limits.maxBytes)
                entry.truncated = true
            } else {
                entry.failure = .responseTooLarge(limit: entry.limits.maxBytes)
                entry.buffer = Data()
            }
            return true
        } ?? false
        if overflow { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let follow = withPending(task.taskIdentifier) { entry -> Bool in
            entry.redirects += 1
            if entry.redirects > entry.limits.maxRedirects {
                entry.failure = .tooManyRedirects
                return false
            }
            guard let target = request.url, RedirectPolicy.allows(from: task.originalRequest?.url, to: target) else {
                entry.failure = .invalidURL
                return false
            }
            return true
        } ?? false
        completionHandler(follow ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = entry.failure {
            entry.continuation.resume(throwing: failure)
        } else if entry.truncated, let info = entry.info {
            entry.continuation.resume(returning: HTTPResult(data: entry.buffer, response: info, truncated: true))
        } else if let error {
            entry.continuation.resume(throwing: AddonError.from(error))
        } else if let info = entry.info {
            entry.continuation.resume(returning: HTTPResult(data: entry.buffer, response: info))
        } else {
            entry.continuation.resume(throwing: AddonError.network("noresponse"))
        }
    }

    private static func info(from response: URLResponse) -> HTTPResponseInfo {
        guard let http = response as? HTTPURLResponse else { return HTTPResponseInfo(statusCode: 0, url: response.url) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return HTTPResponseInfo(statusCode: http.statusCode, headers: headers, url: http.url)
    }
}
