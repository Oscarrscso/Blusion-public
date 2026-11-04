import Foundation

/// Parses protocol ids. Movies are normally IMDb ids (`tt1234567`); episodes are `<imdbId>:<season>:<episode>`.
/// Other addons use their own prefixes (`kitsu:1234`, `mock:movie1`); those stay opaque.
public struct ContentID: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: Sendable, Hashable {
        case imdb
        case imdbEpisode(season: Int, episode: Int)
        case other
    }

    public let raw: String
    public let kind: Kind
    /// For episodes, the series id (`tt1234567`); otherwise `raw`.
    public let baseID: String

    public init(_ raw: String) {
        self.raw = raw
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if let first = parts.first, Self.isIMDb(first) {
            if parts.count == 3, let season = Int(parts[1]), let episode = Int(parts[2]), season >= 0, episode >= 0 {
                kind = .imdbEpisode(season: season, episode: episode)
                baseID = first
                return
            }
            if parts.count == 1 {
                kind = .imdb
                baseID = raw
                return
            }
        }
        kind = .other
        baseID = raw
    }

    public var description: String { raw }

    /// The series an episode id belongs to: `tt1` for `tt1:1:2`, and for another catalog's id, which ends in the episode's numbers,
    /// `kitsu:1` for `kitsu:1:5` (episode 5) or `tmdb:1399` for `tmdb:1399:1:2`. An id that doesn't end in them is returned as it is.
    public static func seriesID(of id: String, season: Int?, episode: Int?) -> String {
        let content = ContentID(id)
        guard case .other = content.kind else { return content.baseID }
        var parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard let episode, parts.count > 2, parts.last == Substring(String(episode)) else { return id }
        parts.removeLast()
        if let season, parts.count > 2, parts.last == Substring(String(season)) { parts.removeLast() }
        return parts.joined(separator: ":")
    }

    public var isEpisode: Bool {
        if case .imdbEpisode = kind { return true }
        return false
    }

    public var season: Int? {
        if case .imdbEpisode(let season, _) = kind { return season }
        return nil
    }

    public var episode: Int? {
        if case .imdbEpisode(_, let episode) = kind { return episode }
        return nil
    }

    /// The id prefix before the first colon, if any (`mock` in `mock:movie1`).
    public var prefix: String? {
        guard let index = raw.firstIndex(of: ":") else { return nil }
        return String(raw[..<index])
    }

    public static func episodeID(series: String, season: Int, episode: Int) -> String {
        "\(series):\(season):\(episode)"
    }

    private static func isIMDb(_ text: String) -> Bool {
        guard text.hasPrefix("tt"), text.count > 2 else { return false }
        return text.dropFirst(2).allSatisfy(\.isASCIIDigit)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
