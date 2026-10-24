import Foundation

/// Addon URLs routinely embed user tokens (`https://host/<token>/manifest.json`). They are secrets:
/// never log, display or persist them outside the Keychain.
public enum Redactor {
    public static let placeholder = "…"

    /// `https://host:port/…` — scheme, host and port only.
    public static func redact(_ url: URL) -> String {
        let scheme = url.scheme ?? "?"
        let host = url.host ?? "?"
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)/\(placeholder)"
    }

    /// Redacts every URL embedded in free text (error descriptions, log lines).
    ///
    /// A URL runs up to whitespace, a quote or an angle bracket. `)`, `]` and `}` are legal inside paths and some token schemes use them,
    /// so they stay part of the match (cutting there would leak the rest of the token); only trailing sentence punctuation is kept.
    public static func redact(text: String) -> String {
        guard text.contains("://") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = ""
        var cursor = text.startIndex
        for match in urlPattern.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            result += text[cursor..<matchRange.lowerBound]
            var raw = String(text[matchRange])
            var suffix = ""
            while let last = raw.last, trailingPunctuation.contains(last) {
                suffix.insert(last, at: suffix.startIndex)
                raw.removeLast()
            }
            if let url = URL(string: raw), url.host != nil {
                result += redact(url)
            } else {
                result += placeholder
            }
            result += suffix
            cursor = matchRange.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// Host (and port) only, for showing which server an addon lives on.
    public static func displayHost(_ url: URL) -> String {
        let host = url.host ?? "unknown host"
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}"]

    // swiftlint:disable:next force_try
    private static let urlPattern = try! NSRegularExpression(pattern: #"(?i)\b(?:https?|stremio|ftp)://[^\s"'<>]+"#)
}
