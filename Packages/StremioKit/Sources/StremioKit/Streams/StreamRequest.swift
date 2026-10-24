import Foundation

/// What the user wants to watch: enough to ask addons for streams and to label the player.
public struct StreamRequest: Sendable, Hashable, Codable {
    public var type: String
    /// Protocol id: `tt1234567`, or `tt1234567:1:2` for an episode.
    public var id: String
    public var title: String
    public var poster: URL?
    public var season: Int?
    public var episode: Int?
    /// For episodes: the next episode in watching order, so the player can offer it (and binge-continue) at the end.
    public var nextID: String?
    public var nextTitle: String?
    public var nextSeason: Int?
    public var nextEpisode: Int?
    /// For episodes: the series' name, which names the file an external player gets (the title is "Series · Episode").
    public var seriesName: String?
    /// The release year of the movie or series, when the addon gave one.
    public var year: String?
    /// How long the title runs, when the addon said so. Lets a position reported by another player mark the title as watched.
    public var expectedDuration: TimeInterval?

    public init(type: String, id: String, title: String, poster: URL? = nil, season: Int? = nil, episode: Int? = nil,
                nextID: String? = nil, nextTitle: String? = nil, nextSeason: Int? = nil, nextEpisode: Int? = nil,
                seriesName: String? = nil, year: String? = nil, expectedDuration: TimeInterval? = nil) {
        self.type = type
        self.id = id
        self.title = title
        self.poster = poster
        self.season = season
        self.episode = episode
        self.nextID = nextID
        self.nextTitle = nextTitle
        self.nextSeason = nextSeason
        self.nextEpisode = nextEpisode
        self.seriesName = seriesName
        self.year = year
        self.expectedDuration = expectedDuration
    }

    /// The request for the next episode, if the current one has a successor.
    public var nextRequest: StreamRequest? {
        guard let nextID, let nextTitle else { return nil }
        return StreamRequest(type: type, id: nextID, title: nextTitle, poster: poster, season: nextSeason, episode: nextEpisode,
                             seriesName: seriesName, year: year, expectedDuration: expectedDuration)
    }

    /// Unique per piece of content (an id alone can repeat across types).
    public var identity: String { "\(type)/\(id)" }

    public init(movie preview: MetaPreview) {
        self.init(type: preview.type.isEmpty ? "movie" : preview.type, id: preview.id, title: preview.name, poster: preview.poster,
                  year: Self.releaseYear(in: preview.releaseInfo), expectedDuration: Self.duration(fromRuntime: preview.runtime))
    }

    public init(episode video: Video, of series: MetaDetail) {
        // An episode that has not aired yet is never offered as the next one: the player would start it.
        let next = series.nextVideo(after: video).flatMap { $0.hasAired() ? $0 : nil }
        self.init(type: series.type.isEmpty ? "series" : series.type, id: video.id,
                  title: "\(series.name) · \(video.title)", poster: series.preview.poster, season: video.season, episode: video.episode,
                  nextID: next?.id, nextTitle: next.map { "\(series.name) · \($0.title)" }, nextSeason: next?.season, nextEpisode: next?.episode,
                  seriesName: series.name, year: Self.releaseYear(in: series.preview.releaseInfo),
                  expectedDuration: Self.duration(fromRuntime: series.preview.runtime))
    }

    /// The length of a runtime as addons write it, in seconds: "152 min", "49 min", "2h 32min", "1 h 5 m", or a bare "95" (minutes).
    /// nil for anything else, and for zero.
    public static func duration(fromRuntime text: String?) -> TimeInterval? {
        let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let match = value.wholeMatch(of: /(?:([0-9]+)\s*h(?:ours?|rs?)?\s*)?(?:([0-9]+)\s*(?:m(?:in(?:ute)?s?)?)?)?/) else { return nil }
        let hours = Double(match.1 ?? "") ?? 0
        let minutes = Double(match.2 ?? "") ?? 0
        let seconds = hours * 3600 + minutes * 60
        return seconds > 0 && seconds.isFinite ? seconds : nil
    }

    /// The first run of exactly four digits in `text`: "2010" in "2010–2015" or "Jan 5, 2010". nil when there is none.
    static func releaseYear(in text: String?) -> String? {
        var run = ""
        for character in (text ?? "") + " " {
            if character.isASCII && character.isNumber {
                run.append(character)
            } else {
                if run.count == 4 { return run }
                run = ""
            }
        }
        return nil
    }
}
