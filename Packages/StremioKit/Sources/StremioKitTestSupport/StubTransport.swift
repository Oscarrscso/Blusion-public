import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StremioKit

/// Scriptable transport: `handler` gets the request and the 1-based call number.
public final class StubTransport: HTTPTransport, @unchecked Sendable {
    public typealias Handler = @Sendable (URLRequest, Int) async throws -> HTTPResult

    private let handler: Handler
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var limitsSeen: [FetchLimits] = []

    public init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    /// Always answers with `data` and `status`.
    public convenience init(data: Data, status: Int = 200, headers: [String: String] = [:]) {
        self.init { request, _ in
            HTTPResult(data: data, response: HTTPResponseInfo(statusCode: status, headers: headers, url: request.url))
        }
    }

    public var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    public var limits: [FetchLimits] {
        lock.lock()
        defer { lock.unlock() }
        return limitsSeen
    }

    public var callCount: Int { requests.count }

    public func send(_ request: URLRequest, limits: FetchLimits) async throws -> HTTPResult {
        let call = lock.withLock { () -> Int in
            recorded.append(request)
            limitsSeen.append(limits)
            return recorded.count
        }
        return try await handler(request, call)
    }

    public static func response(_ data: Data, status: Int = 200, for request: URLRequest, headers: [String: String] = [:]) -> HTTPResult {
        HTTPResult(data: data, response: HTTPResponseInfo(statusCode: status, headers: headers, url: request.url))
    }
}

/// Client with fast retries for tests.
public func makeClient(_ transport: any HTTPTransport, timeout: TimeInterval = 5, retries: Int = 2, backoff: TimeInterval = 0.01,
                logger: AddonLogger = .silent) -> AddonClient {
    AddonClient(configuration: AddonClientConfiguration(timeout: timeout, maxRetries: retries, retryBackoff: backoff), transport: transport, logger: logger)
}
