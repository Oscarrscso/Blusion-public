import Foundation

/// Addons report cache readiness in their display metadata. Unmarked HTTP streams
/// remain usable; an explicit download/waiting mark always blocks automatic starts.
public enum StreamAvailability {
    public static func canStartAutomatically(_ item: RankedStream) -> Bool {
        !isUncached(item.stream)
    }

    public static func automaticCandidates(from items: [RankedStream]) -> [RankedStream] {
        let ready = items.filter(canStartAutomatically)
        let cached = ready.filter { isCached($0.stream) }
        return cached.isEmpty ? ready : cached
    }

    private static func isUncached(_ stream: AddonStream) -> Bool {
        let text = [stream.name, stream.description].compactMap { $0 }.joined(separator: "\n")
        return TorBoxCache.detect(in: stream) == .notCached
            || text.unicodeScalars.contains("\u{23F3}") || text.unicodeScalars.contains("\u{231B}")
            || matches(#"\b(?:uncached|not[ _-]?cached)\b|\bcached\s*[:=]\s*(?:no|false|0)\b|\[(?:TB|RD|AD|PM|TRB|TORBOX)\s+download\]"#, text)
    }

    private static func isCached(_ stream: AddonStream) -> Bool {
        let text = [stream.name, stream.description].compactMap { $0 }.joined(separator: "\n")
        return TorBoxCache.detect(in: stream) == .cached || text.unicodeScalars.contains("\u{26A1}")
            || matches(#"\bcached\b|\[(?:TB|RD|AD|PM|TRB|TORBOX)\+\]"#, text)
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
