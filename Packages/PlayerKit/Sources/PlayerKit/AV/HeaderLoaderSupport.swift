import Foundation

// Portable helpers behind the documented way to send request headers with AVPlayer (ADR-005, option B):
// an AVAssetResourceLoaderDelegate on a custom URL scheme. The delegate itself is Apple-only (HeaderResourceLoader);
// everything it decides lives here so it can be tested on any host.

public enum CustomScheme {
    public static let prefix = "blusion-"

    /// `https://h/x` -> `blusion-https://h/x`. Only http(s) URLs map.
    public static func encode(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = prefix + scheme
        return components.url
    }

    /// `blusion-https://h/x` -> `https://h/x`. Anything else is nil.
    public static func decode(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme.hasPrefix(prefix),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let real = String(scheme.dropFirst(prefix.count))
        guard real == "http" || real == "https" else { return nil }
        components.scheme = real
        return components.url
    }
}

public enum ByteRange {
    /// The `Range` header for an AVAssetResourceLoadingDataRequest.
    public static func header(offset: Int64, length: Int?, toEnd: Bool) -> String {
        if toEnd || length == nil { return "bytes=\(offset)-" }
        return "bytes=\(offset)-\(offset + Int64(max(length ?? 1, 1)) - 1)"
    }

    /// Total resource length from `Content-Range: bytes 0-1/12345` (nil for `*` or garbage).
    public static func totalLength(fromContentRange value: String?) -> Int64? {
        guard let value, let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}

/// Rewrites an HLS playlist so every segment, key, map and sub-playlist URI goes back through the custom scheme.
/// Without this AVPlayer would fetch absolute URIs directly, without the headers.
public enum HLSPlaylistRewriter {
    public static func looksLikePlaylist(_ data: Data) -> Bool {
        ContainerSniffingBridge.isHLS(data)
    }

    public static func rewrite(_ playlist: String, baseURL: URL, map: (URL) -> URL?) -> String {
        // "\r\n" is ONE Character in Swift, so splitting on "\n" would not split a CRLF playlist at all: normalise first.
        let normalised = playlist.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalised.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return line }
            if trimmed.hasPrefix("#") { return rewriteAttributeURIs(in: line, baseURL: baseURL, map: map) }
            guard let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL, let mapped = map(resolved) else { return line }
            return mapped.absoluteString
        }.joined(separator: "\n")
    }

    /// `#EXT-X-KEY:METHOD=AES-128,URI="key.bin"` -> URI replaced; other tags untouched.
    private static func rewriteAttributeURIs(in line: String, baseURL: URL, map: (URL) -> URL?) -> String {
        guard line.contains("URI=\"") else { return line }
        var result = ""
        var rest = Substring(line)
        while let start = rest.range(of: "URI=\"") {
            result += rest[..<start.upperBound]
            rest = rest[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            let uri = String(rest[..<end])
            if let resolved = URL(string: uri, relativeTo: baseURL)?.absoluteURL, let mapped = map(resolved) {
                result += mapped.absoluteString
            } else {
                result += uri
            }
            rest = rest[end...]
        }
        return result + rest
    }
}

/// Tiny shim so HLSPlaylistRewriter doesn't need the whole sniffer: a playlist starts with #EXTM3U.
enum ContainerSniffingBridge {
    static func isHLS(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(16), as: UTF8.self).drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        return head.hasPrefix("#EXTM3U")
    }
}
