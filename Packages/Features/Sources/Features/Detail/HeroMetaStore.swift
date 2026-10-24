import Foundation
import Observation
import StremioKit

/// The fuller details of a title (year, genres, runtime, score) as an addon's `meta` gives them, kept for the session by `type/id`.
/// Home's spotlight and the title page both build their metadata line from the entry kept here, so the two lines are the same text.
@MainActor
@Observable
public final class HeroMetaStore {
    private var previews: [String: MetaPreview] = [:]
    /// Lookups under way, by title, so a title asked for twice at once shares one request.
    @ObservationIgnored private var lookups: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let browse: BrowseService

    public nonisolated init(browse: BrowseService) {
        self.browse = browse
    }

    /// The details kept for the title, or nil when none have been loaded yet.
    public func kept(for item: MetaPreview) -> MetaPreview? {
        previews[item.identity]
    }

    /// What the metadata line is built from: the kept details, else the item as it is.
    public func preview(for item: MetaPreview) -> MetaPreview {
        kept(for: item) ?? item
    }

    /// Asks the addons for the title's details and keeps them. A title already kept, or being asked for, asks nothing more; callers
    /// that arrive while the request runs wait for it. An answer built from the item alone (no addon answered) is not kept, so it is
    /// asked again.
    public func load(for item: MetaPreview) async {
        let key = item.identity
        guard previews[key] == nil else { return }
        if let running = lookups[key] {
            await running.value
            return
        }
        let task = Task { [self] in
            let result = await browse.detail(for: item)
            if !result.isFallback { previews[key] = result.detail.preview }
            lookups[key] = nil
        }
        lookups[key] = task
        await task.value
    }

    /// Keeps the details the title page has just loaded itself, replacing any kept before.
    public func record(_ details: MetaPreview, for item: MetaPreview) {
        previews[item.identity] = details
    }

    /// The parts of the metadata line for a title, for `MetaLine`. Home's spotlight and the title page both call this with the same
    /// ratings store, so the two lines are built by the same code from the same details.
    public func parts(for item: MetaPreview, certification: String?, ratings: PosterRatingsStore) -> [String?] {
        let shown = preview(for: item)
        return DetailViewModel.heroMetaParts(for: shown, certification: certification,
                                             imdbRating: ratings.ratings(for: shown, includeReviews: true, source: .imdb).imdb)
    }

    /// The genres of the metadata line for a title, the same ones `parts` shows, for `MetaLine` to drop first when the line is too long.
    public func genres(for item: MetaPreview) -> [String] {
        DetailViewModel.heroMetaGenres(for: preview(for: item))
    }
}
