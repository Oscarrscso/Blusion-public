import Foundation

/// Whether TorBox already holds a stream's file, so it plays at once, or would first fetch it. Read from the marks addons put in a
/// stream's name and description, since no addon says it in a field of its own: AIOStreams' "⚡" (cached) or "⏳" (not yet) beside
/// its "TB" service tag ("📡 Source: ☁️ TB · Library"), Torrentio's "[TB+]" or "[TB download]", Comet's "[TORBOX⚡]" and
/// MediaFusion's "TRB".
public enum TorBoxCache: Sendable, Equatable {
    case cached, notCached

    /// The stream's state on TorBox, or nil when it is not a TorBox stream or its text does not say. Links to a web page (an
    /// aggregator's statistics and error notes) are never streams on TorBox, though their text can name it.
    public static func detect(in stream: AddonStream) -> TorBoxCache? {
        switch stream.source {
        case .direct, .torrent: detect(in: [stream.name, stream.description])
        case .youtube, .external, .archive: nil
        }
    }

    public static func detect(in texts: [String?]) -> TorBoxCache? {
        let text = texts.compactMap { $0 }.joined(separator: "\n")
        guard namesTorBox(text) else { return nil }
        // The marks are read as single scalars, so the emoji form ("⚡️", with its variation selector) counts too.
        let scalars = text.unicodeScalars
        if scalars.contains("\u{23F3}") || matches(notCachedMark, in: text) { return .notCached }
        if scalars.contains("\u{26A1}") || text.contains("TB+") || matches(cachedMark, in: text) { return .cached }
        return nil
    }

    /// The service tag "TB" or "TRB" in capitals. A "TB" after a number is a size ("1.2 TB"), not the service. Without a tag, the
    /// name "TorBox" counts unless another service's tag is there: "☁️ RD · TorBox Search" is a Real-Debrid stream an addon of that
    /// name found.
    private static func namesTorBox(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        let tagged = tag?.matches(in: text, range: range).contains { match in
            guard let found = Range(match.range, in: text) else { return false }
            let before = text[..<found.lowerBound].reversed().first { !$0.isWhitespace }
            return !(before.map { $0.isNumber || $0 == "." || $0 == "," } ?? false)
        } ?? false
        if tagged { return true }
        return matches(name, in: text) && !matches(otherService, in: text)
    }

    private static let tag = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])TR?B(?![A-Za-z0-9])"#)
    private static let name = try? NSRegularExpression(pattern: #"\btor ?box\b"#, options: .caseInsensitive)
    private static let otherService = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])(RD|AD|PM|ED|OC|EN)(?![A-Za-z0-9])"#)
    private static let notCachedMark = try? NSRegularExpression(
        pattern: #"\b(uncached|not cached|tb download)\b|\bcached\s*:\s*(no|false)\b"#, options: .caseInsensitive)
    private static let cachedMark = try? NSRegularExpression(pattern: #"\bcached\b"#, options: .caseInsensitive)

    private static func matches(_ expression: NSRegularExpression?, in text: String) -> Bool {
        expression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
