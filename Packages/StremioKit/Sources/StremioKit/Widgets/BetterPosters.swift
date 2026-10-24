import Foundation

/// Poster artwork from the BetterPosters addon (btttr.cc): a title's poster with a tag, its genre and its rating drawn on it. The addon
/// serves one by IMDb id or TMDb id and needs no key. It answers 404 for a title it has no poster for.
public enum BetterPosters {
    private static let base = "https://btttr.cc/poster"
    /// The addon draws an average of several sites' ratings unless asked for one. `IM` is IMDb's score out of 10 (its "IMDb (/10)"
    /// option, which its own configuration page sends as `rs=IM`).
    private static let imdbRating = "?rs=IM"

    /// The addon's poster for a title, or nil when `id` is neither an IMDb id ("tt" and digits, with or without a ":season:episode"
    /// ending, which is dropped) nor "tmdb:<number>". A TMDb id needs `type` "movie" or "series".
    public static func posterURL(id: String, type: String) -> URL? {
        if id.hasPrefix("tmdb:") {
            let number = String(id.dropFirst("tmdb:".count))
            guard isDigits(number) else { return nil }
            let kind: String
            switch type {
            case "movie": kind = "movie"
            case "series": kind = "series"
            default: return nil
            }
            return URL(string: "\(base)/tmdb/poster-default/\(kind)-\(number).jpg\(imdbRating)")
        }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        let imdb: Substring
        switch parts.count {
        case 1: imdb = parts[0]
        case 3 where isDigits(String(parts[1])) && isDigits(String(parts[2])): imdb = parts[0]
        default: return nil
        }
        guard imdb.hasPrefix("tt"), isDigits(String(imdb.dropFirst(2))) else { return nil }
        return URL(string: "\(base)/imdb/poster-default/\(imdb).jpg\(imdbRating)")
    }

    /// True for one or more ASCII digits and nothing else.
    private static func isDigits(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
