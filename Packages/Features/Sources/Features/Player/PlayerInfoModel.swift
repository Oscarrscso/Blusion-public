import Foundation
import Observation
import StremioKit

/// Media information belongs to the playback plan, not the statistics timer or an open menu.
@MainActor
@Observable
final class PlayerInfoModel {
    private let request: StreamRequest
    private let services: AppServices
    private(set) var detail: MetaDetail?
    private(set) var isLoading = true
    private(set) var isLoadingEpisode = false
    private(set) var episodeItem: MetaPreview?
    let episodeRatings: TitleRatings
    var isSynopsisExpanded = false
    var isSynopsisTruncated = false
    private(set) var openedReviews: DetailViewModel.OpenedReviews?
    private(set) var shownReviews: DetailViewModel.OpenedReviews?
    private(set) var reviewsLoading = false

    init(request: StreamRequest, services: AppServices) {
        self.request = request
        self.services = services
        episodeRatings = TitleRatings(id: request.identity)
    }

    var isEpisode: Bool {
        request.type == "series" || request.seriesName != nil || request.season != nil || request.episode != nil
            || ContentID(request.id).isEpisode
    }

    var item: MetaPreview {
        detail?.preview ?? MetaPreview(
            id: isEpisode ? PlayerEpisodePickerModel.seriesID(for: request) : request.id,
            type: request.type,
            name: isEpisode ? request.seriesName ?? request.title.components(separatedBy: " · ").first ?? request.title : request.title,
            poster: request.poster
        )
    }

    private var currentVideo: Video? {
        if let video = detail?.videos.first(where: { $0.id == request.id }) { return video }
        let content = ContentID(request.id)
        guard let season = request.season ?? content.season,
              let episode = request.episode ?? content.episode else { return nil }
        return detail?.videos.first { $0.season == season && $0.episode == episode }
    }

    var title: String {
        isEpisode ? currentVideo?.title ?? request.title : item.name
    }

    var synopsis: String? {
        // A missing episode overview must never fall back to the show's description.
        isEpisode ? currentVideo?.overview : detail?.preview.description
    }

    var ratingsRevision: Int { services.posterRatings.reviewServicesRevision }

    var reviewItem: MetaPreview? { isEpisode ? episodeItem : item }

    var imdbReviewsURL: URL? {
        guard let item = reviewItem, LetterboxdRatings.isIMDbID(item.id) else { return nil }
        return ReviewSite.imdb.reviewsURL(for: item)
    }

    func load() async {
        if detail == nil {
            isLoading = true
            let (loaded, _) = await services.browse.detail(for: item)
            guard !Task.isCancelled else { return }
            detail = loaded
            isLoading = false
        }
        guard isEpisode, let detail else { return }
        isLoadingEpisode = true
        defer { isLoadingEpisode = false }

        let video = currentVideo
        let content = ContentID(request.id)
        guard let season = video?.season ?? request.season ?? content.season,
              let episode = video?.episode ?? request.episode ?? content.episode else { return }
        let seriesID = LetterboxdRatings.isIMDbID(detail.preview.id) ? detail.preview.id
            : Video.seriesIMDbID(fromVideoID: request.id)
                ?? video.flatMap { Video.seriesIMDbID(fromVideoID: $0.id) }
                ?? detail.videos.lazy.compactMap { Video.seriesIMDbID(fromVideoID: $0.id) }.first
        guard let seriesID else { return }

        let expected = Set(detail.episodes(inSeason: season).filter { $0.hasAired() }.compactMap(\.episode))
        let ratings = services.posterRatings
        let scores = await ratings.episodeRatings(for: seriesID, season: season, expectedEpisodes: expected)
        guard !Task.isCancelled else { return }
        episodeRatings.imdb = scores[episode]
        let id = await ratings.imdbEpisodeID(seriesIMDbID: seriesID, season: season, episode: episode)
        guard !Task.isCancelled else { return }
        // No provider is offered without its own episode page. Never send an episode to the series' reviews.
        episodeItem = id.flatMap { id in
            guard id != seriesID else { return nil }
            return MetaPreview(id: id, type: "series", name: request.title)
        }
        if episodeItem == nil { closeReviews() }
    }

    func toggleReviews(_ site: ReviewSite, url: URL, isSearch: Bool) {
        if openedReviews?.site == site {
            closeReviews()
            return
        }
        if let shown = shownReviews, shown.site == site {
            openedReviews = shown
            shownReviews = nil
            reviewsLoading = false
            return
        }
        if let open = openedReviews, !reviewsLoading { shownReviews = open }
        openedReviews = .init(site: site, url: url, isSearch: isSearch)
        reviewsLoading = true
    }

    func closeReviews() {
        openedReviews = nil
        shownReviews = nil
        reviewsLoading = false
    }

    func reviewsDidLoad(_ reviews: DetailViewModel.OpenedReviews) {
        guard openedReviews == reviews else { return }
        reviewsLoading = false
        shownReviews = nil
    }
}
