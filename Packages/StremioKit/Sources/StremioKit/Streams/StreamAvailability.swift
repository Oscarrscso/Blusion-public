import Foundation

/// Cache readiness reported by an addon's display metadata, or `.unknown` when the stream carries no cache marker.
public enum StreamCacheStatus: String, Sendable, Equatable, Hashable, Codable {
    case cached
    case uncached
    case unknown
}

/// Addons report cache readiness in their display metadata. Unmarked HTTP streams
/// remain usable; HTTP download placeholders block automatic starts. Torrents need a playable server route.
public enum StreamAvailability {
    public static func canStartAutomatically(_ item: RankedStream) -> Bool {
        item.route.isWatchable && (!isUncached(item.stream) || isTorrent(item.stream))
    }

    public static func automaticCandidates(from items: [RankedStream]) -> [RankedStream] {
        items.filter(canStartAutomatically)
    }

    public static func cacheStatus(for stream: AddonStream) -> StreamCacheStatus {
        switch stream.source {
        case .direct, .torrent:
            if isUncached(stream) { return .uncached }
            if isCached(stream) { return .cached }
            return .unknown
        case .youtube, .external, .archive:
            return .unknown
        }
    }

    /// An uncached torrent can play through the configured streaming server; an HTTP download placeholder cannot.
    private static func isTorrent(_ stream: AddonStream) -> Bool {
        if case .torrent = stream.source { return true }
        return false
    }

    private static func isUncached(_ stream: AddonStream) -> Bool {
        let text = [stream.name, stream.description].compactMap { $0 }.joined(separator: "\n")
        return TorBoxCache.detect(in: stream) == .notCached
            || text.unicodeScalars.contains("\u{23F3}") || text.unicodeScalars.contains("\u{231B}")
            || matches(#"\b(?:uncached|not[ _-]?cached)\b|\bcached\s*[:=]\s*(?:no|false|0)\b|\[(?:TB|RD|AD|PM|TRB|TORBOX)\s+download\]"#, text)
    }

    public static func isCached(_ stream: AddonStream) -> Bool {
        guard !isUncached(stream) else { return false }
        let text = [stream.name, stream.description].compactMap { $0 }.joined(separator: "\n")
        return TorBoxCache.detect(in: stream) == .cached || text.unicodeScalars.contains("\u{26A1}")
            || matches(#"\bcached\b|\[(?:TB|RD|AD|PM|TRB|TORBOX)\+\]"#, text)
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
