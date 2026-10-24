import Foundation

/// An actual paused playback record. Percentage stays usable even when Trakt has no runtime.
public struct TraktPlaybackItem: Sendable, Equatable, Identifiable {
    public let preview: MetaPreview
    public let progress: Double
    public let pausedAt: Date
    public let season: Int?
    public let episode: Int?
    public let episodeTitle: String?
    public let duration: TimeInterval?
    /// Trakt's id for this paused record, needed to remove it (`DELETE sync/playback/{id}`).
    public var playbackID: Int?

    public var contentID: String {
        if let season, let episode { return "\(preview.id):\(season):\(episode)" }
        return preview.id
    }
    public var id: String { "\(preview.type)/\(contentID)" }
    public var request: StreamRequest {
        StreamRequest(type: preview.type, id: contentID,
                      title: episodeTitle.map { "\(preview.name) · \($0)" } ?? preview.name,
                      poster: preview.poster, season: season, episode: episode,
                      seriesName: season == nil ? nil : preview.name, year: preview.releaseInfo, expectedDuration: duration)
    }

    static func decode(_ data: Data) throws -> [TraktPlaybackItem] {
        guard let rows = try? JSONDecoder().decode([PlaybackRow].self, from: data) else { throw TraktAccountError.invalidResponse }
        return rows.compactMap(\.item)
    }
}

private struct PlaybackRow: Decodable {
    struct Media: Decodable {
        struct IDs: Decodable { let imdb: String? }
        let title: String?
        let year: Int?
        let ids: IDs?
        let runtime: Double?
    }
    struct Episode: Decodable {
        let season: Int?
        let number: Int?
        let title: String?
        let runtime: Double?
    }
    let id: Int?
    let type: String?
    let progress: Double?
    let paused_at: String?
    let movie: Media?
    let show: Media?
    let episode: Episode?

    var item: TraktPlaybackItem? {
        guard let progress, progress.isFinite, progress > 0, progress < 100,
              let paused_at, let date = Self.date(paused_at) else { return nil }
        let isEpisode = type == "episode"
        guard type == "movie" || isEpisode, let media = isEpisode ? show : movie,
              let imdb = media.ids?.imdb, imdb.wholeMatch(of: /tt[0-9]+/) != nil,
              let title = media.title, !title.isEmpty else { return nil }
        if isEpisode {
            guard let season = episode?.season, season >= 0, let number = episode?.number, number > 0 else { return nil }
        }
        let minutes = isEpisode ? episode?.runtime : media.runtime
        let duration = minutes.flatMap { $0 > 0 && $0.isFinite ? $0 * 60 : nil }
        let preview = MetaPreview(id: imdb, type: isEpisode ? "series" : "movie", name: title,
                                  poster: URL(string: "https://images.metahub.space/poster/medium/\(imdb)/img"),
                                  releaseInfo: media.year.map(String.init))
        return TraktPlaybackItem(preview: preview, progress: progress, pausedAt: date,
                                 season: isEpisode ? episode?.season : nil, episode: isEpisode ? episode?.number : nil,
                                 episodeTitle: isEpisode ? episode?.title : nil, duration: duration, playbackID: id)
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
