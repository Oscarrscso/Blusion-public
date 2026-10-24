import Foundation

public enum AddonURLError: Error, Equatable, Sendable {
    case empty
    case invalid
    case unsupportedScheme(String)
    case missingHost
    case unsupportedQuery

    public var message: String {
        switch self {
        case .empty: return "Enter an addon URL."
        case .invalid: return "That doesn't look like a valid URL."
        case .unsupportedScheme(let scheme): return "“\(scheme)” links are not supported. Use an https:// or stremio:// link."
        case .missingHost: return "The URL has no host."
        case .unsupportedQuery: return "Addon URLs with a ?query part aren't supported. Use the addon's manifest link."
        }
    }
}

/// A normalised install target: the manifest URL (a secret, may embed a token) and its base (manifest URL minus `/manifest.json`).
public struct AddonLocation: Sendable, Hashable {
    public let manifestURL: URL
    public let baseURL: URL

    public init(manifestURL: URL, baseURL: URL) {
        self.manifestURL = manifestURL
        self.baseURL = baseURL
    }

    /// Derives the location from a manifest URL that already ends in `manifest.json`.
    public init?(manifestURL: URL) {
        guard let components = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.lowercased().hasSuffix("/manifest.json") else { return nil }
        var base = components
        base.percentEncodedPath = String(components.percentEncodedPath.dropLast("/manifest.json".count))
        base.percentEncodedQuery = nil
        base.fragment = nil
        guard let baseURL = base.url else { return nil }
        self.init(manifestURL: manifestURL, baseURL: baseURL)
    }
}

public enum AddonURLNormaliser {
    /// Accepts `stremio://host/path/manifest.json`, `https://…`, `http://…`, or a bare `host/path` and returns the install target.
    ///
    /// - `stremio://` becomes `https://`, or `http://` when the host is a LAN address (PLAN §4).
    /// - A bare host gets `https://`, or `http://` for LAN hosts.
    /// - `/manifest.json` is appended when missing; fragments are dropped.
    public static func normalise(_ input: String) throws -> AddonLocation {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'`"))
        guard !text.isEmpty else { throw AddonURLError.empty }

        var explicitScheme: String?
        if let range = text.range(of: "://") {
            let scheme = String(text[..<range.lowerBound]).lowercased()
            guard scheme.range(of: #"^[a-z][a-z0-9+.\-]*$"#, options: .regularExpression) != nil else { throw AddonURLError.invalid }
            explicitScheme = scheme
            text = String(text[range.upperBound...])
        }
        // Treat `stremio:///host/...` (three slashes) like two.
        while text.hasPrefix("/") { text.removeFirst() }

        if let scheme = explicitScheme, !["stremio", "http", "https"].contains(scheme) {
            throw AddonURLError.unsupportedScheme(scheme)
        }

        guard var components = URLComponents(string: "https://" + text) else { throw AddonURLError.invalid }
        guard let host = components.host?.lowercased(), !host.isEmpty else { throw AddonURLError.missingHost }
        components.host = host
        components.fragment = nil
        // Resource URLs are built from the path only (PLAN §4); a query would be dropped and the addon would silently misbehave.
        if components.percentEncodedQuery?.isEmpty == false { throw AddonURLError.unsupportedQuery }

        switch explicitScheme {
        case "http": components.scheme = "http"
        case "https": components.scheme = "https"
        default: components.scheme = HostClassifier.isLAN(host) ? "http" : "https"
        }

        var path = components.percentEncodedPath
        if !path.lowercased().hasSuffix("/manifest.json") {
            while path.hasSuffix("/") { path.removeLast() }
            path += "/manifest.json"
        }
        components.percentEncodedPath = path

        guard let manifestURL = components.url, let location = AddonLocation(manifestURL: manifestURL) else { throw AddonURLError.invalid }
        return location
    }
}

/// Decides whether a host is a local-network address (where plain http is expected and ATS's local-networking exception applies).
public enum HostClassifier {
    public static func isLAN(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return true }
        if let octets = ipv4Octets(host) { return isPrivateIPv4(octets) }
        if host.contains(":") { return isLocalIPv6(host) }
        // Unqualified single-label names (`nas`, `raspberrypi`) only resolve on a local network.
        return !host.contains(".")
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    private static func isPrivateIPv4(_ o: [Int]) -> Bool {
        switch (o[0], o[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true // CGNAT / Tailscale
        default: return false
        }
    }

    private static func isLocalIPv6(_ host: String) -> Bool {
        host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
    }
}
