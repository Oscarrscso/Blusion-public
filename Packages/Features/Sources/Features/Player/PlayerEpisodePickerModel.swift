import Foundation
import Observation
import StremioKit

/// The player's episode picker: a series' seasons and episodes, read from its metadata addon, and the request each episode plays.
@MainActor
@Observable
public final class PlayerEpisodePickerModel {
    public private(set) var isLoading = true
    /// Why the episodes are not there, when the addon could not say.
    public private(set) var failure: String?
    public private(set) var seasons: [Int] = []
    public private(set) var selectedSeason: Int?
    public private(set) var episodes: [Video] = []
    /// The episode whose streams are being readied. While one is, the others take no taps.
    public private(set) var preparingID: Video.ID?

    private let services: AppServices
    private let series: MetaPreview
    private let currentID: String
    private let currentSeason: Int?
    private let currentEpisode: Int?
    private var detail: MetaDetail?

    public init(request: StreamRequest, services: AppServices) {
        self.services = services
        self.currentID = request.id
        self.currentSeason = request.season
        self.currentEpisode = request.episode
        let name = request.seriesName ?? request.title.components(separatedBy: " · ").first ?? request.title
        self.series = MetaPreview(id: Self.seriesID(for: request), type: request.type, name: name, poster: request.poster)
    }

    /// The series' id behind an episode's. An IMDb episode id keeps its head (`tt1234567` from `tt1234567:1:2`); another addon's id
    /// ends with the episode's season and number, which are dropped (`mock:series1` from `mock:series1:1:2`). An id that does not end
    /// that way is taken as the series' own, as when the addon gives its episodes no season.
    static func seriesID(for request: StreamRequest) -> String {
        let content = ContentID(request.id)
        if case .imdbEpisode = content.kind { return content.baseID }
        guard let season = request.season, let episode = request.episode else { return request.id }
        let parts = request.id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count > 2,
              let last = Int(parts[parts.count - 1]), let beforeLast = Int(parts[parts.count - 2]),
              beforeLast == season, last == episode else { return request.id }
        return parts.dropLast(2).joined(separator: ":")
    }

    /// Reads the series' episodes, opening on the season playing. A picker opened again keeps what it read.
    public func load() async {
        guard detail == nil else { return }
        isLoading = true
        failure = nil
        let (detail, isFallback) = await services.browse.detail(for: series)
        guard !Task.isCancelled else { return }
        self.detail = detail
        seasons = detail.seasons
        if seasons.isEmpty {
            // An addon that gives its episodes no season has one list.
            episodes = detail.videos
        } else {
            let playing = currentSeason.flatMap { seasons.contains($0) ? $0 : nil }
            selectedSeason = playing ?? seasons.first
            episodes = selectedSeason.map(detail.episodes(inSeason:)) ?? []
        }
        isLoading = false
        if episodes.isEmpty {
            // A fallback is the preview alone: the addon that knows the series did not answer.
            failure = isFallback ? "The episodes couldn't be loaded." : "This series has no episodes."
        }
    }

    public func selectSeason(_ season: Int) {
        guard season != selectedSeason, let detail else { return }
        selectedSeason = season
        episodes = detail.episodes(inSeason: season)
    }

    /// The season's name as the picker shows it.
    public static func seasonName(_ season: Int) -> String {
        season == 0 ? "Specials" : "Season \(season)"
    }

    /// The episode playing now, marked in the list.
    public func isCurrent(_ video: Video) -> Bool {
        if video.id == currentID { return true }
        guard let currentEpisode else { return false }
        return video.season == currentSeason && video.episode == currentEpisode
    }

    /// The request that plays `video`, as its card on the series' page would.
    public func request(for video: Video) -> StreamRequest? {
        detail.map { StreamRequest(episode: video, of: $0) }
    }

    public func beginPreparing(_ video: Video) {
        preparingID = video.id
    }

    public func endPreparing() {
        preparingID = nil
    }
}
