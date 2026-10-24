import Foundation

/// A trailer or teaser for a title, from TMDb's videos, an addon's `trailerStreams` or iTunes' preview. A YouTube source plays in YouTube's
/// embedded player on the title page; a direct source is a file the app's own player plays.
public struct Trailer: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case trailer
        case teaser
    }

    public enum Source: Sendable, Hashable {
        case youtube(String)
        case direct(URL)
    }

    public let source: Source
    public let title: String
    public let kind: Kind
    public let isOfficial: Bool
    /// Lowercased ISO 639-1 code. Nil when unknown.
    public let language: String?
    /// TMDb's ISO 8601 date text, as sent. Nil when unknown.
    public let publishedAt: String?
    /// Nil when neither TMDb nor the addon gives it.
    public var duration: TimeInterval?

    public init(source: Source, title: String = "Trailer", kind: Kind = .trailer, isOfficial: Bool = false, language: String? = nil,
                publishedAt: String? = nil, duration: TimeInterval? = nil) {
        self.source = source
        self.title = title
        self.kind = kind
        self.isOfficial = isOfficial
        self.language = language
        self.publishedAt = publishedAt
        self.duration = duration
    }

    /// `yt:<id>` for a YouTube source, `url:<absolute string>` for a direct one. Two trailers with the same id are the same trailer.
    public var id: String {
        switch source {
        case .youtube(let key): return "yt:\(key)"
        case .direct(let url): return "url:\(url.absoluteString)"
        }
    }

    public var youtubeID: String? {
        if case .youtube(let key) = source { return key }
        return nil
    }

    public var directURL: URL? {
        if case .direct(let url) = source { return url }
        return nil
    }

    /// YouTube thumbnails, best first: `maxresdefault`, then `hq720`, then `mqdefault` (16:9, and always there). Empty for direct sources.
    public var thumbnailCandidates: [URL] {
        guard let youtubeID else { return [] }
        return ["maxresdefault", "hq720", "mqdefault"].compactMap { URL(string: "https://img.youtube.com/vi/\(youtubeID)/\($0).jpg") }
    }

    /// YouTube ids are short runs of letters, digits, `-` and `_`. Anything else an addon or TMDb sends is never put into a URL.
    public static func isYouTubeID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
