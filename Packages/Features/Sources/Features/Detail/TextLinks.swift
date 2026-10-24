import Foundation

/// A link in a text: where it sits, in UTF-16 units of that text, and where it goes.
struct TextLink: Equatable {
    let range: NSRange
    let url: URL
}

/// The links in a text shown by `JustifiedText`: markdown links and bare URLs. Only http and https links are ever made, so a `javascript:`,
/// `mailto:`, `tel:`, `file:` or app link stays plain text. Nothing here touches UIKit, so the host tests cover it.
enum TextLinks {
    /// Whether `url` may be opened as a link: its scheme is http or https.
    static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The links of `text`, in order: the markdown links that are web links, and each bare URL that does not lie within one of them.
    /// `markdown` ranges are in the same UTF-16 units as `text`, which is the text as shown with its markdown removed.
    static func all(in text: String, markdown: [TextLink] = []) -> [TextLink] {
        let markdownLinks = markdown.filter { isWebLink($0.url) }
        let bare = bareLinks(in: text).filter { link in
            !markdownLinks.contains { NSIntersectionRange($0.range, link.range).length > 0 }
        }
        return (markdownLinks + bare).sorted { $0.range.location < $1.range.location }
    }

    /// The bare URLs of `text` that are written with an http or https scheme, found by NSDataDetector. Sentence punctuation after a URL is
    /// left out of it, and a name written without a scheme (such as `www.example.com`) stays plain.
    private static func bareLinks(in text: String) -> [TextLink] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let whole = text as NSString
        return detector.matches(in: text, options: [], range: NSRange(location: 0, length: whole.length)).compactMap { match in
            let written = whole.substring(with: match.range)
            let trimmed = written.trimmingCharacters(in: sentenceEnds)
            let lowercased = trimmed.lowercased()
            guard lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://"),
                  let url = URL(string: trimmed), isWebLink(url) else { return nil }
            return TextLink(range: NSRange(location: match.range.location, length: (trimmed as NSString).length), url: url)
        }
    }

    /// The characters that end a sentence rather than a URL when they follow one. NSDataDetector keeps a trailing `?` in a URL, so they are cut
    /// here. A closing bracket is left to NSDataDetector, which keeps one that closes a bracket inside the URL.
    private static let sentenceEnds = CharacterSet(charactersIn: ".,;:!?'\"")
}
