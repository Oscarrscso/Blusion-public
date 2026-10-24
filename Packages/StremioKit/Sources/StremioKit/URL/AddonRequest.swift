import Foundation

public struct ExtraParam: Sendable, Hashable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

public struct ParsedAddonRequest: Sendable, Equatable {
    public var resource: ResourceKind
    public var type: String
    public var id: String
    public var extras: [ExtraParam]
}

/// Builds and parses `<base>/<resource>/<type>/<id>[/<k>=<v>&<k>=<v>].json` (PLAN §4).
public enum AddonRequestBuilder {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static let idAllowed = unreserved.union(CharacterSet(charactersIn: ":"))

    public static func url(base: URL, resource: ResourceKind, type: String, id: String, extras: [ExtraParam] = []) -> URL? {
        var path = base.absoluteString
        while path.hasSuffix("/") { path.removeLast() }
        path += "/\(resource.rawValue)/\(encode(type, allowed: unreserved))/\(encode(id, allowed: idAllowed))"
        if !extras.isEmpty {
            let pairs = extras.map { "\(encode($0.name, allowed: unreserved))=\(encode($0.value, allowed: unreserved))" }
            path += "/" + pairs.joined(separator: "&")
        }
        return URL(string: path + ".json")
    }

    /// Inverse of `url(base:…)`; ignores whatever prefix (base path, token) precedes the resource segment.
    public static func parse(_ url: URL) -> ParsedAddonRequest? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard var last = segments.popLast(), last.hasSuffix(".json") else { return nil }
        last.removeLast(".json".count)
        segments.append(last)
        // Trailing shapes: [resource, type, id] or [resource, type, id, extras].
        for tail in [3, 4] where segments.count >= tail {
            let window = Array(segments.suffix(tail))
            guard let resource = ResourceKind(rawValue: window[0]),
                  let type = window[1].removingPercentEncoding,
                  let id = window[2].removingPercentEncoding else { continue }
            return ParsedAddonRequest(resource: resource, type: type, id: id,
                                      extras: tail == 4 ? parseExtras(window[3]) : [])
        }
        return nil
    }

    static func parseExtras(_ segment: String) -> [ExtraParam] {
        segment.split(separator: "&", omittingEmptySubsequences: true).compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first?.removingPercentEncoding, !name.isEmpty else { return nil }
            let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? "") : ""
            return ExtraParam(name, value)
        }
    }

    private static func encode(_ text: String, allowed: CharacterSet) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
