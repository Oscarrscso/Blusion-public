import Foundation

public struct MetaLink: Sendable, Equatable, Hashable, Codable {
    public var name: String
    public var category: String
    public var url: String

    public init(name: String, category: String, url: String) {
        self.name = name
        self.category = category
        self.url = url
    }

    private enum Keys: String, CodingKey { case name, category, url }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        guard let name = container.string(.name) else { throw DroppedItem(reason: "link without name") }
        self.init(name: name, category: container.string(.category) ?? "", url: container.string(.url) ?? "")
    }
}

/// Catalog item: enough to draw a poster and open Detail.
public struct MetaPreview: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var id: String
    /// Empty when the addon omitted it; `AddonClient.catalog` fills it from the request.
    public var type: String
    public var name: String
    public var poster: URL?
    public var posterShape: String
    public var background: URL?
    public var logo: URL?
    public var description: String?
    /// Year or range as text (`"1999"`, `"2020-"`). Addons also send it as a number.
    public var releaseInfo: String?
    public var imdbRating: Double?
    public var genres: [String]
    public var runtime: String?

    public init(id: String, type: String = "", name: String? = nil, poster: URL? = nil, posterShape: String = "poster",
                background: URL? = nil, logo: URL? = nil, description: String? = nil, releaseInfo: String? = nil,
                imdbRating: Double? = nil, genres: [String] = [], runtime: String? = nil) {
        self.id = id
        self.type = type
        self.name = name ?? id
        self.poster = poster
        self.posterShape = posterShape
        self.background = background
        self.logo = logo
        self.description = description
        self.releaseInfo = releaseInfo
        self.imdbRating = imdbRating
        self.genres = genres
        self.runtime = runtime
    }

    private enum Keys: String, CodingKey {
        case id, type, name, poster, posterShape, background, logo, description, releaseInfo, year, imdbRating, genres, genre, runtime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        guard let id = container.string(.id) else { throw DroppedItem(reason: "meta without id") }
        var genres = container.stringArray(.genres)
        if genres.isEmpty { genres = container.stringArray(.genre) }
        self.init(id: id,
                  type: container.string(.type) ?? "",
                  name: container.string(.name),
                  poster: container.url(.poster),
                  posterShape: container.string(.posterShape) ?? "poster",
                  background: container.url(.background),
                  logo: container.url(.logo),
                  description: container.string(.description),
                  releaseInfo: container.string(.releaseInfo) ?? container.string(.year),
                  imdbRating: container.double(.imdbRating),
                  genres: genres,
                  runtime: container.string(.runtime))
    }

    /// `type/id`: an id can repeat across types, so this is what tells two items apart.
    public var identity: String { "\(type)/\(id)" }
}

/// An episode (series) of a meta.
public struct Video: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var season: Int?
    public var episode: Int?
    /// Air date as the addon sent it: `released`, or `firstAired` when that is missing.
    public var released: String? {
        didSet { airDate = Self.parseAirDate(released) }
    }
    public var thumbnail: URL?
    public var overview: String?
    /// Episode rating on a 0 to 10 scale. The addon's `imdbRating` or `rating` when it sends one; otherwise filled in from TMDb's
    /// season data (see `ratingSource`).
    public var rating: Double?
    /// Where `rating` came from. Nil without a rating.
    public var ratingSource: RatingSource?

    /// The site an episode score came from, so the UI can name it.
    public enum RatingSource: String, Sendable, Codable, Equatable, Hashable {
        /// The addon's own metadata, usually IMDb's score.
        case addon
        /// TMDb's vote average for the episode. Not IMDb's score.
        case tmdb
    }

    public init(id: String, title: String? = nil, season: Int? = nil, episode: Int? = nil,
                released: String? = nil, thumbnail: URL? = nil, overview: String? = nil, rating: Double? = nil,
                ratingSource: RatingSource? = nil) {
        self.id = id
        self.title = title ?? id
        self.season = season
        self.episode = episode
        self.released = released
        self.airDate = Self.parseAirDate(released)
        self.thumbnail = thumbnail
        self.overview = overview
        let usable = rating.flatMap { (0...10).contains($0) && $0 > 0 ? $0 : nil }
        self.rating = usable
        self.ratingSource = usable == nil ? nil : (ratingSource ?? .addon)
    }

    /// `84`, or nil without a usable rating: the score out of 100, never a decimal.
    public var ratingText: String? { rating.map { String(Int(($0 * 10).rounded())) } }

    /// Parsed once with the metadata, so drawing a long-running show's cards never reparses every air date.
    public private(set) var airDate: Date?

    private static func parseAirDate(_ released: String?) -> Date? {
        guard let released, !released.isEmpty else { return nil }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return (try? fractional.parse(released)) ?? (try? Date.ISO8601FormatStyle().parse(released))
    }

    /// False only for an episode with a known air date after `now`. An episode with no date counts as aired, so a show whose addon
    /// sends no dates can still be marked watched.
    public func hasAired(by now: Date = Date()) -> Bool {
        airDate.map { $0 <= now } ?? true
    }

    /// The series' IMDb id from an episode id such as `tt0944947:1:2`, or nil when the id does not start with one.
    public static func seriesIMDbID(fromVideoID id: String) -> String? {
        guard let head = id.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init),
              LetterboxdRatings.isIMDbID(head), head != id else { return nil }
        return head
    }

    // The parsed date is derived from `released`, not an extra field in saved or addon metadata.
    private enum CodingKeys: String, CodingKey {
        case id, title, season, episode, released, thumbnail, overview, rating, ratingSource
    }

    private enum Keys: String, CodingKey {
        case id, title, name, season, episode, number, released, firstAired, thumbnail, overview, description, imdbRating, rating
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        guard let id = container.string(.id) else { throw DroppedItem(reason: "video without id") }
        self.init(id: id,
                  title: container.string(.title) ?? container.string(.name),
                  season: container.int(.season),
                  episode: container.int(.episode) ?? container.int(.number),
                  released: container.string(.released) ?? container.string(.firstAired),
                  thumbnail: container.url(.thumbnail),
                  overview: container.string(.overview) ?? container.string(.description),
                  rating: container.double(.imdbRating) ?? container.double(.rating))
    }
}

/// A trailer as addons send it: `trailerStreams` entries carry a YouTube id in `ytId` and sometimes a direct `url`, the older `trailers`
/// entries carry the id in `source`.
private struct TrailerEntry: Decodable {
    let ytId: String?
    let url: URL?
    let source: String?

    private enum Keys: String, CodingKey { case ytId, url, source }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        ytId = container.string(.ytId)
        url = container.url(.url)
        source = container.string(.source)
    }
}

/// Full metadata for Detail. Superset of `MetaPreview`.
public struct MetaDetail: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var preview: MetaPreview
    public var released: String?
    public var director: [String]
    public var cast: [String]
    public var writers: [String]
    public var links: [MetaLink]
    public var videos: [Video]
    public var defaultVideoID: String?
    /// YouTube ids of the trailers, in the addon's order.
    public var trailers: [String]
    /// Direct http(s) trailer URLs from `trailerStreams`, in the addon's order.
    public var trailerURLs: [URL]

    public var id: String { preview.id }
    public var type: String { preview.type }
    public var name: String { preview.name }

    public init(preview: MetaPreview, released: String? = nil, director: [String] = [], cast: [String] = [],
                writers: [String] = [], links: [MetaLink] = [], videos: [Video] = [], defaultVideoID: String? = nil,
                trailers: [String] = [], trailerURLs: [URL] = []) {
        self.preview = preview
        self.released = released
        self.director = director
        self.cast = cast
        self.writers = writers
        self.links = links
        self.videos = videos
        self.defaultVideoID = defaultVideoID
        self.trailers = trailers
        self.trailerURLs = trailerURLs
    }

    private enum Keys: String, CodingKey { case released, director, cast, writer, writers, links, videos, behaviorHints, trailerStreams, trailers }
    private enum HintKeys: String, CodingKey { case defaultVideoId }

    public init(from decoder: Decoder) throws {
        let preview = try MetaPreview(from: decoder)
        let container = try decoder.container(keyedBy: Keys.self)
        var hint: String?
        if container.contains(.behaviorHints), let hints = try? container.nestedContainer(keyedBy: HintKeys.self, forKey: .behaviorHints) {
            hint = hints.string(.defaultVideoId)
        }
        var writers = container.stringArray(.writers)
        if writers.isEmpty { writers = container.stringArray(.writer) }
        let streams: [TrailerEntry] = container.lossyArray(.trailerStreams)
        self.init(preview: preview,
                  released: container.string(.released),
                  director: container.stringArray(.director),
                  cast: container.stringArray(.cast),
                  writers: writers,
                  links: container.lossyArray(.links),
                  videos: container.lossyArray(.videos),
                  defaultVideoID: hint,
                  trailers: Self.trailerIDs(streams: streams, legacy: container.lossyArray(.trailers)),
                  trailerURLs: Self.unique(streams.map(\.url)))
    }

    /// `trailerStreams[].ytId`, or `trailers[].source` when that yields nothing. Empty and repeated ids are dropped.
    private static func trailerIDs(streams: [TrailerEntry], legacy: [TrailerEntry]) -> [String] {
        let fromStreams = unique(streams.map(\.ytId))
        return fromStreams.isEmpty ? unique(legacy.map(\.source)) : fromStreams
    }

    private static func unique<Value: Hashable>(_ values: [Value?]) -> [Value] {
        var seen = Set<Value>()
        return values.compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    /// Episodes grouped by season, ascending; specials (season 0) last, as most UIs show them.
    public var seasons: [Int] {
        let all = Set(videos.compactMap(\.season))
        return all.filter { $0 > 0 }.sorted() + (all.contains(0) ? [0] : [])
    }

    public func episodes(inSeason season: Int) -> [Video] {
        videos.filter { $0.season == season }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }

    /// The episodes that "watched" means for the whole show: everything that has aired in the regular seasons, plus episodes the addon
    /// gave no season. Specials (season 0) and episodes that are yet to air are left out, so a show counts as watched once its
    /// regular, aired episodes are, and marking it never claims an episode nobody could have seen.
    public func episodesCountingAsWatched(by now: Date = Date()) -> [Video] {
        let regular = seasons.filter { $0 != 0 }.flatMap { episodes(inSeason: $0) }
        return (regular + videos.filter { $0.season == nil }).filter { $0.hasAired(by: now) }
    }

    /// Gives the episodes of `season` that have no rating of their own the score for their number in `scores`. The addon's rating
    /// always wins; a score outside 0...10 is ignored.
    public mutating func fillEpisodeRatings(season: Int, scores: [Int: Double], source: Video.RatingSource) {
        for index in videos.indices where videos[index].season == season && videos[index].rating == nil {
            guard let number = videos[index].episode, let score = scores[number], (0...10).contains(score), score > 0 else { continue }
            videos[index].rating = score
            videos[index].ratingSource = source
        }
    }

    /// The episode after `video` in watching order: season by season, specials (season 0) only after the last regular season.
    public func nextVideo(after video: Video) -> Video? {
        let ordered = seasons.flatMap { episodes(inSeason: $0) }
        guard let index = ordered.firstIndex(where: { $0.id == video.id }), index + 1 < ordered.count else { return nil }
        let next = ordered[index + 1]
        // Don't roll from a regular season into specials automatically.
        if (video.season ?? 0) > 0, next.season == 0 { return nil }
        return next
    }

    /// The episode before `video` in watching order, back across a season's start. Specials (season 0) stay apart: the first special has
    /// none before it, and a regular season never steps back into them.
    public func previousVideo(before video: Video) -> Video? {
        let ordered = seasons.flatMap { episodes(inSeason: $0) }
        guard let index = ordered.firstIndex(where: { $0.id == video.id }), index > 0 else { return nil }
        let previous = ordered[index - 1]
        guard (previous.season == 0) == (video.season == 0) else { return nil }
        return previous
    }

    /// The episodes a switcher steps to from `video`: the one before it and the one after it, in watching order. Each is nil when there is
    /// none, and when it has not aired by `now`.
    public func neighbouringEpisodes(of video: Video, by now: Date = Date()) -> (previous: Video?, next: Video?) {
        (previousVideo(before: video).flatMap { $0.hasAired(by: now) ? $0 : nil },
         nextVideo(after: video).flatMap { $0.hasAired(by: now) ? $0 : nil })
    }

    /// Fills fields the addon's `meta` left out with what the catalog preview already showed (so Detail never loses its poster).
    public func filling(from preview: MetaPreview) -> MetaDetail {
        var copy = self
        copy.preview.poster = copy.preview.poster ?? preview.poster
        copy.preview.background = copy.preview.background ?? preview.background
        copy.preview.logo = copy.preview.logo ?? preview.logo
        copy.preview.description = copy.preview.description ?? preview.description
        copy.preview.releaseInfo = copy.preview.releaseInfo ?? preview.releaseInfo
        copy.preview.imdbRating = copy.preview.imdbRating ?? preview.imdbRating
        if copy.preview.genres.isEmpty { copy.preview.genres = preview.genres }
        if copy.preview.type.isEmpty { copy.preview.type = preview.type }
        return copy
    }

    /// Detail built from a catalog preview when the addon's `meta` request fails.
    public static func fallback(from preview: MetaPreview) -> MetaDetail { MetaDetail(preview: preview) }
}

// MARK: - Encodable (flat, so a round trip yields the same value)

extension MetaDetail {
    private enum EncodeKeys: String, CodingKey {
        case id, type, name, poster, posterShape, background, logo, description, releaseInfo, imdbRating, genres, runtime
        case released, director, cast, writers, links, videos, behaviorHints, trailerStreams
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: EncodeKeys.self)
        try container.encode(preview.id, forKey: .id)
        try container.encode(preview.type, forKey: .type)
        try container.encode(preview.name, forKey: .name)
        try container.encodeIfPresent(preview.poster, forKey: .poster)
        try container.encode(preview.posterShape, forKey: .posterShape)
        try container.encodeIfPresent(preview.background, forKey: .background)
        try container.encodeIfPresent(preview.logo, forKey: .logo)
        try container.encodeIfPresent(preview.description, forKey: .description)
        try container.encodeIfPresent(preview.releaseInfo, forKey: .releaseInfo)
        try container.encodeIfPresent(preview.imdbRating, forKey: .imdbRating)
        try container.encode(preview.genres, forKey: .genres)
        try container.encodeIfPresent(preview.runtime, forKey: .runtime)
        try container.encodeIfPresent(released, forKey: .released)
        try container.encode(director, forKey: .director)
        try container.encode(cast, forKey: .cast)
        try container.encode(writers, forKey: .writers)
        try container.encode(links, forKey: .links)
        try container.encode(videos, forKey: .videos)
        try container.encode(trailers.map { ["ytId": $0] } + trailerURLs.map { ["url": $0.absoluteString] }, forKey: .trailerStreams)
        if let defaultVideoID { try container.encode(["defaultVideoId": defaultVideoID], forKey: .behaviorHints) }
    }
}
