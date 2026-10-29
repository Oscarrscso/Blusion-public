import Foundation

/// How a stream reaches the player: from Usenet (an NZB a service such as TorBox or Easynews fetched), or through a debrid service's
/// copy of a torrent (Real-Debrid, TorBox, AllDebrid, Premiumize). Read from the marks addons put in a stream's name and description,
/// since no addon says it in a field of its own: AIOStreams' "📰" (Usenet) or "☁️" (debrid) before its service tag
/// ("📡 Source: 📰 TB · Library"), and Torrentio's or Comet's service tags ("[RD+]", "[TORBOX⚡]").
public enum StreamDelivery: String, Sendable, Equatable, Hashable, CaseIterable {
    case usenet, debrid

    public var title: String {
        switch self {
        case .usenet: "Usenet"
        case .debrid: "Debrid"
        }
    }

    /// The stream's delivery, or nil when its text says neither (a plain link, a torrent on a streaming server, a web page).
    public static func detect(in stream: AddonStream) -> StreamDelivery? {
        switch stream.source {
        case .direct, .torrent: detect(in: [stream.name, stream.description])
        case .youtube, .external, .archive: nil
        }
    }

    public static func detect(in texts: [String?]) -> StreamDelivery? {
        let text = texts.compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        // Usenet first: TorBox fetches both, so a TorBox Usenet stream also carries the debrid service's tag.
        let scalars = text.unicodeScalars
        if scalars.contains("\u{1F4F0}") || scalars.contains("\u{1F5DE}") || matches(usenetWords, in: text) { return .usenet }
        if scalars.contains("\u{2601}") || matches(debridWords, in: text) || hasServiceTag(text) { return .debrid }
        return nil
    }

    /// A debrid service's tag in capitals: "RD", "AD", "PM", "TB", "TRB", alone or as "[RD+]". A "TB" after a number is a size ("1.2 TB").
    private static func hasServiceTag(_ text: String) -> Bool {
        guard let serviceTag else { return false }
        return serviceTag.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains { match in
            guard let found = Range(match.range, in: text) else { return false }
            let before = text[..<found.lowerBound].reversed().first { !$0.isWhitespace }
            return !(before.map { $0.isNumber || $0 == "." || $0 == "," } ?? false)
        }
    }

    private static let usenetWords = try? NSRegularExpression(pattern: #"\b(usenet|nzb|easynews|newsgroups?)\b"#, options: .caseInsensitive)
    private static let debridWords = try? NSRegularExpression(
        pattern: #"\b(debrid|real-?debrid|all-?debrid|premiumize|tor ?box|debrid-?link)\b"#, options: .caseInsensitive)
    private static let serviceTag = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])(RD|AD|PM|TB|TRB)(?![A-Za-z0-9])"#)

    private static func matches(_ expression: NSRegularExpression?, in text: String) -> Bool {
        expression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// Which kind of stream Auto Pick prefers (Settings › Playback). It is a preference, not a filter: a release of the preferred kind gains
/// `AutoStreamRanking.preferenceBonus`, which only decides between releases of near-equal quality. A clearly better release of the other
/// kind still wins. Balanced gives no preference, so every release is compared on quality alone.
public enum StreamSourcePreference: String, Sendable, Equatable, Hashable, CaseIterable, Identifiable, Codable {
    case usenet, balanced, debrid

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .usenet: "Usenet"
        case .balanced: "Balanced"
        case .debrid: "Debrid"
        }
    }

    /// The kind of stream preferred, nil for Balanced.
    public var delivery: StreamDelivery? {
        switch self {
        case .usenet: .usenet
        case .balanced: nil
        case .debrid: .debrid
        }
    }

    /// True when the stream is of the preferred kind. Balanced prefers nothing.
    public func prefers(_ stream: AddonStream) -> Bool {
        guard let delivery else { return false }
        return StreamDelivery.detect(in: stream) == delivery
    }
}
