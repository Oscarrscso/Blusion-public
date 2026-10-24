import Foundation

/// A streaming service a web release came from, read from the tag its name or file name carries ("NF", "AMZN") or from the service's own
/// name. Heuristic, like the rest of `StreamQuality`: addons put it in free text.
public enum StreamProvider: String, Sendable, Equatable, Hashable, CaseIterable {
    case netflix, primeVideo, appleTV, disneyPlus, hboMax, hulu, paramountPlus, peacock, crunchyroll

    /// The service's name as a viewer reads it.
    public var name: String {
        switch self {
        case .netflix: "Netflix"
        case .primeVideo: "Prime Video"
        case .appleTV: "Apple TV+"
        case .disneyPlus: "Disney+"
        case .hboMax: "HBO Max"
        case .hulu: "Hulu"
        case .paramountPlus: "Paramount+"
        case .peacock: "Peacock"
        case .crunchyroll: "Crunchyroll"
        }
    }

    /// The words that name each service, its release tag or its own name, tested against lowercased text. The first rule that matches wins.
    /// A bare "Amazon" or "Peacock" is left out: both are ordinary words in film titles, so they name a service only with its brand.
    private static let rules: [(pattern: String, value: StreamProvider)] = [
        (#"\bnf\b|\bnetflix\b"#, .netflix),
        (#"\bamzn\b|\bamazon[ .]?prime\b|\bprime[ .\-]?video\b"#, .primeVideo),
        (#"\batvp\b|\bapple[ .]?tv(?![a-z0-9])"#, .appleTV),
        (#"\bdsnp\b|\bdisney(?:\+|[ .]?plus)"#, .disneyPlus),
        (#"\bhmax\b|\bhbo[ .]?max\b"#, .hboMax),
        (#"\bhulu\b"#, .hulu),
        (#"\bpmtp\b|\bparamount(?:\+|[ .]?plus)"#, .paramountPlus),
        (#"\bpcok\b|\bpeacock[ .]?tv\b"#, .peacock),
        // "CR" is Crunchyroll's tag only when a web release follows it ("CR WEB-DL").
        (#"\bcrunchyroll\b|\bcr(?=[ .\-]+web)"#, .crunchyroll),
    ]

    /// The rules compiled once, in order.
    private static let expressions: [(expression: NSRegularExpression, value: StreamProvider)] = rules.compactMap { rule in
        (try? NSRegularExpression(pattern: rule.pattern)).map { (expression: $0, value: rule.value) }
    }

    /// The service the texts name, or nil when none does. The texts are read in the order given, and an earlier text decides over a later
    /// one: a name or file name that names a service wins over a description that may name another.
    public static func detect(in texts: [String?]) -> StreamProvider? {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let lowered = text.lowercased()
            let range = NSRange(lowered.startIndex..., in: lowered)
            if let rule = expressions.first(where: { $0.expression.firstMatch(in: lowered, range: range) != nil }) {
                return rule.value
            }
        }
        return nil
    }
}
