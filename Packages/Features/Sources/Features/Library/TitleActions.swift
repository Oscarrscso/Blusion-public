import Foundation
import Observation
import PlayerKit
import StremioKit

/// Library membership and watched marks for any title, kept current so menus and badges can read them without waiting.
@MainActor
@Observable
public final class TitleActions {
    /// `type/id` of every saved title.
    public private(set) var savedIdentities: Set<String> = []
    /// `type/id` of every watched movie. A series is not in here: it is watched by its episodes (`seriesWithWatchedEpisodes`).
    public private(set) var watchedIdentities: Set<String> = []
    /// `type/id` of every series with at least one episode marked watched.
    public private(set) var seriesWithWatchedEpisodes: Set<String> = []

    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    /// Reads the library and the watch history again. Call when a screen appears, since other screens change them too.
    public func refresh(progress: [WatchProgress]? = nil) async {
        savedIdentities = Set(await services.library.all().map(\.id))
        let records: [WatchProgress]
        if let progress { records = progress } else { records = await services.progress.all() }
        let watched = records.filter(\.isWatched)
        watchedIdentities = Set(watched.filter { $0.type == "movie" }.map(\.id))
        seriesWithWatchedEpisodes = Set(watched.compactMap(Self.showID(of:)).map { LibraryItem.identity(type: "series", contentID: $0) })
    }

    /// The show an episode record belongs to. An episode's id is its show's id plus `:season:episode`, whatever the addon's id scheme
    /// (`ContentID` only understands IMDb ones), so the suffix comes off by what the record says it is.
    private static func showID(of record: WatchProgress) -> String? {
        guard record.type == "series" else { return nil }
        if let season = record.season, let episode = record.episode {
            let suffix = ":\(season):\(episode)"
            if record.contentID.hasSuffix(suffix), record.contentID.count > suffix.count { return String(record.contentID.dropLast(suffix.count)) }
        }
        return record.seriesID
    }

    /// True when some episode of the series is marked watched, which is when "mark as unwatched" has something to clear.
    public func hasWatchedEpisodes(_ item: MetaPreview) -> Bool {
        seriesWithWatchedEpisodes.contains(Self.identity(of: item))
    }

    /// Series: marks every aired episode watched, or clears the mark from every episode. The episode list comes from the addons, so
    /// this waits for them; a show they cannot describe is left alone.
    public func setSeriesWatched(_ watched: Bool, for item: MetaPreview) async {
        guard Self.itemType(of: item) == "series" else { return }
        let detail = await services.browse.detail(for: item).detail
        let videos = watched ? detail.episodesCountingAsWatched() : detail.videos
        let type = detail.type.isEmpty ? "series" : detail.type
        if watched {
            await services.progress.save(videos.map { video in
                WatchProgress(id: "\(type)/\(video.id)", type: type, contentID: video.id, title: "\(detail.name) · \(video.title)",
                              poster: detail.preview.poster, position: 0, duration: 0, isWatched: true, updatedAt: Date(),
                              season: video.season, episode: video.episode)
            })
        } else {
            await services.progress.remove(videos.map { "\(type)/\($0.id)" })
        }
        await refresh()
    }

    public func isSaved(_ item: MetaPreview) -> Bool {
        savedIdentities.contains(Self.identity(of: item))
    }

    public func isWatched(_ item: MetaPreview) -> Bool {
        watchedIdentities.contains(Self.identity(of: item))
    }

    /// Saves the title, or removes it. Decides from the store rather than the cached set, so a stale menu cannot save twice.
    public func toggleSaved(_ item: MetaPreview) async {
        let identity = Self.identity(of: item)
        if await services.library.contains(identity) {
            await services.library.remove(identity)
        } else {
            await services.library.add(LibraryItem(preview: item, addedAt: Date()))
        }
        await refresh()
    }

    /// Movies only: marks watched or removes the mark, as Detail does. Does nothing for other types.
    public func setWatched(_ watched: Bool, for item: MetaPreview) async {
        guard Self.itemType(of: item) == "movie" else { return }
        let identity = Self.identity(of: item)
        if watched {
            await services.progress.save(WatchProgress(id: identity, type: "movie", contentID: item.id, title: item.name, poster: item.poster,
                                                       position: 0, duration: 0, isWatched: true, updatedAt: Date()))
        } else {
            await services.progress.remove(identity)
        }
        await refresh()
    }

    /// A title with no type is a movie, as in `LibraryItem` and `StreamRequest`, so it is keyed the same way everywhere.
    private static func itemType(of item: MetaPreview) -> String {
        item.type.isEmpty ? "movie" : item.type
    }

    private static func identity(of item: MetaPreview) -> String {
        LibraryItem.identity(type: itemType(of: item), contentID: item.id)
    }
}
