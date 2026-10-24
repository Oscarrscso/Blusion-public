import Foundation

/// Display names and tab order for content types (`movie`, `series`, `tv`...). Matching ignores case and surrounding spaces.
public enum ContentTypeName {
    /// "Movies", "Series", "Live TV", "Channels", "Anime", "Other"; unknown types are capitalised with "." "_" "-" turned into spaces
    /// ("anime.series" -> "Anime Series").
    public static func plural(_ type: String) -> String {
        switch key(type) {
        case "movie": return "Movies"
        case "series": return "Series"
        case "anime": return "Anime"
        case "tv": return "Live TV"
        case "channel": return "Channels"
        default: return capitalised(type) ?? "Other"
        }
    }

    /// "Movie", "Series", "Channel" (for both tv and channel), "Anime", "Title" for an empty type; unknown types as in `plural`.
    public static func singular(_ type: String) -> String {
        switch key(type) {
        case "movie": return "Movie"
        case "series": return "Series"
        case "anime": return "Anime"
        case "tv", "channel": return "Channel"
        default: return capitalised(type) ?? "Title"
        }
    }

    /// movie 0, series 1, anime 2, tv 3, channel 4, everything else 5: the order tabs and sections appear in.
    public static func sortRank(_ type: String) -> Int {
        switch key(type) {
        case "movie": return 0
        case "series": return 1
        case "anime": return 2
        case "tv": return 3
        case "channel": return 4
        default: return 5
        }
    }

    private static func key(_ type: String) -> String {
        type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// nil when nothing is left once the separators are gone (an empty or all-punctuation type).
    private static func capitalised(_ type: String) -> String? {
        let spaced = type.trimmingCharacters(in: .whitespacesAndNewlines).map { ".-_".contains($0) ? " " : String($0) }.joined()
        let words = spaced.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let result = words.joined(separator: " ")
        return result.isEmpty ? nil : result
    }
}
