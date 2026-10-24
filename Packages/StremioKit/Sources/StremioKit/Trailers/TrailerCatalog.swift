import Foundation

/// Joins a title's trailers from iTunes, TMDb and its addons into one list to offer.
public enum TrailerCatalog {
    /// How many YouTube trailers are offered when no direct file is. TMDb exposes no view counts, so the three that rank best stand in for
    /// the most watched. A third is there in case YouTube refuses to embed one of the first two.
    private static let youTubeLimit = 3

    /// The trailers to offer for a title, best first. A direct file is the first choice: the iTunes preview, then the addon's own direct
    /// links, each listed once. YouTube is only a fallback: when there is no direct file at all, the best `youTubeLimit` YouTube trailers
    /// are offered, and when there is one, no YouTube entry is returned.
    ///
    /// YouTube candidates come from TMDb's videos and the addon's YouTube ids. TMDb's entry wins over an addon id they share, since it
    /// carries a title, kind and language. Addon-only YouTube entries are official trailers with no language, and count as English.
    /// Ranking: English, then no language, then other languages; official before unofficial; trailers before teasers; newer before
    /// older, undated last. Entries that still tie keep the order they were listed in.
    public static func merge(previews: [Trailer], addonYouTubeIDs: [String], addonURLs: [URL], tmdb: [TMDbVideo]) -> [Trailer] {
        let direct = directTrailers(previews: previews, addonURLs: addonURLs)
        guard direct.isEmpty else { return direct }
        return youTubeTrailers(addonYouTubeIDs: addonYouTubeIDs, tmdb: tmdb)
    }

    /// The order a player tries the trailers of a title in: every direct file in the order `merge` lists them, then the best
    /// `youTubeLimit` YouTube trailers, so YouTube is the fallback when no direct file plays. With no direct file it is the same list
    /// `merge` returns.
    public static func playbackOrder(previews: [Trailer], addonYouTubeIDs: [String], addonURLs: [URL], tmdb: [TMDbVideo]) -> [Trailer] {
        directTrailers(previews: previews, addonURLs: addonURLs)
            + youTubeTrailers(addonYouTubeIDs: addonYouTubeIDs, tmdb: tmdb)
    }

    /// The direct files, each listed once, in this order: the iTunes previews, then the addon's direct links. Any direct file that is not
    /// http(s) is left out.
    private static func directTrailers(previews: [Trailer], addonURLs: [URL]) -> [Trailer] {
        var seen = Set<String>()
        var direct: [Trailer] = []
        for preview in previews {
            guard let url = preview.directURL, isWebURL(url), seen.insert(preview.id).inserted else { continue }
            direct.append(preview)
        }
        for url in addonURLs where isWebURL(url) {
            let trailer = Trailer(source: .direct(url), isOfficial: true)
            if seen.insert(trailer.id).inserted { direct.append(trailer) }
        }
        return direct
    }

    /// The best `youTubeLimit` YouTube trailers from TMDb's videos and the addon's YouTube ids, best first.
    private static func youTubeTrailers(addonYouTubeIDs: [String], tmdb: [TMDbVideo]) -> [Trailer] {
        var seen = Set<String>()
        var candidates: [Candidate] = []
        func add(_ trailer: Trailer, languageRank: Int) {
            guard seen.insert(trailer.id).inserted else { return }
            candidates.append(Candidate(trailer: trailer, languageRank: languageRank))
        }
        for video in tmdb where video.isYouTubeTrailerOrTeaser {
            let kind: Trailer.Kind = video.type.lowercased() == "teaser" ? .teaser : .trailer
            let language = trimmed(video.iso_639_1)?.lowercased()
            add(Trailer(source: .youtube(video.key), title: trimmed(video.name) ?? (kind == .teaser ? "Teaser" : "Trailer"), kind: kind,
                        isOfficial: video.official ?? false, language: language, publishedAt: trimmed(video.published_at)),
                languageRank: languageRank(language))
        }
        for id in addonYouTubeIDs where Trailer.isYouTubeID(id) {
            add(Trailer(source: .youtube(id), isOfficial: true), languageRank: 0)
        }
        return candidates.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element), right = rank(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left.lexicographicallyPrecedes(right)
        }
        .prefix(youTubeLimit)
        .map { $0.element.trailer }
    }

    private struct Candidate {
        let trailer: Trailer
        let languageRank: Int
    }

    private static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// The sort key: smaller comes first. A newer date has the smaller key, and an undated trailer the largest.
    private static func rank(_ candidate: Candidate) -> [Double] {
        let trailer = candidate.trailer
        return [
            Double(candidate.languageRank),
            trailer.isOfficial ? 0 : 1,
            trailer.kind == .trailer ? 0 : 1,
            publishedDate(trailer.publishedAt).map { -$0.timeIntervalSince1970 } ?? .infinity,
        ]
    }

    /// English first, then no language, then any other language.
    private static func languageRank(_ language: String?) -> Int {
        if language == "en" { return 0 }
        return language == nil ? 1 : 2
    }

    private static func publishedDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return (try? fractional.parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    /// The text without surrounding whitespace, or nil when nothing is left.
    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
