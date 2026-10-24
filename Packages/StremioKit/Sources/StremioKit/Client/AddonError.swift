import Foundation

/// Failure of one addon request. Never carries a URL, so it is always safe to log or show.
public enum AddonError: Error, Sendable, Equatable {
    case invalidURL
    case timeout
    case offline
    /// Transport failure with a short machine code such as `urlerror.-1004`.
    case network(String)
    case http(status: Int)
    case notFound
    case invalidJSON
    case responseTooLarge(limit: Int)
    case tooManyRedirects
    case invalidManifest([String])
    case cancelled

    /// Short text for per-addon error chips.
    public var shortDescription: String {
        switch self {
        case .invalidURL: return "Invalid address"
        case .timeout: return "Timed out"
        case .offline: return "Offline"
        case .network: return "Can't connect"
        case .http(let status): return "Server error (\(status))"
        case .notFound: return "Not found"
        case .invalidJSON: return "Invalid response"
        case .responseTooLarge: return "Response too large"
        case .tooManyRedirects: return "Too many redirects"
        case .invalidManifest: return "Invalid addon"
        case .cancelled: return "Cancelled"
        }
    }

    /// Worth another attempt on an idempotent GET.
    public var isRetryable: Bool {
        switch self {
        case .timeout, .network: return true
        case .http(let status): return status == 408 || status == 429 || (500...599).contains(status)
        default: return false
        }
    }
}

extension AddonError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let reasons): return reasons.isEmpty ? shortDescription : reasons.joined(separator: " ")
        default: return shortDescription
        }
    }
}
