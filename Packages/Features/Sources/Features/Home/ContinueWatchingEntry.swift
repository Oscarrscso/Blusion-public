import Foundation
import PlayerKit
import StremioKit

public struct ContinueWatchingEntry: Identifiable, Equatable, Sendable {
    public let request: StreamRequest
    public let fraction: Double
    public let updatedAt: Date
    public var id: String { request.identity }

    public var subtitle: String {
        guard let season = request.season, let episode = request.episode else { return "" }
        return "S\(season) E\(episode)"
    }

    static func merge(local: [WatchProgress], remote: [TraktPlaybackItem]) -> [ContinueWatchingEntry] {
        var entries: [String: ContinueWatchingEntry] = [:]
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { $0.updatedAt > $1.updatedAt ? $0 : $1 })
        for item in remote {
            // A newer local completion or pause wins over an older Trakt pause.
            if let saved = localByID[item.id], saved.updatedAt >= item.pausedAt { continue }
            entries[item.id] = ContinueWatchingEntry(request: item.request, fraction: item.progress / 100, updatedAt: item.pausedAt)
        }
        for item in local where !item.isWatched && (item.isQueuedForContinue == true || ProgressRecorder.resumePosition(for: item) > 0) {
            if let remote = entries[item.id], remote.updatedAt > item.updatedAt { continue }
            var request = LibraryViewModel.request(for: item)
            request.expectedDuration = item.duration > 0 ? item.duration : nil
            entries[item.id] = ContinueWatchingEntry(request: request, fraction: item.fraction, updatedAt: item.updatedAt)
        }
        var series = Set<String>()
        let latestLocalEpisode = Dictionary(local.compactMap { item in item.seriesID.map { ($0, item) } },
                                           uniquingKeysWith: { $0.updatedAt > $1.updatedAt ? $0 : $1 })
        return entries.values.sorted { $0.updatedAt > $1.updatedAt }.filter { entry in
            guard entry.request.type == "series" else { return true }
            let seriesID = ContentID(entry.request.id).baseID
            // Completing a later episode must not bring an older, unfinished episode back to Continue Watching.
            if let latest = latestLocalEpisode[seriesID], latest.isWatched, latest.updatedAt >= entry.updatedAt { return false }
            return series.insert(seriesID).inserted
        }
    }
}

extension ContinueWatchingEntry {
    /// The pictures of Continue Watching's card on the widgets page: its newest four titles, newest first, as Home's row lists them. Each
    /// carries the title's backdrop and poster, so the card's top row shows the first two backdrops and its bottom row the next two posters.
    static func cardItems(from entries: [ContinueWatchingEntry]) -> [MetaPreview] {
        entries.prefix(4).map { entry in
            let id = ContentID(entry.request.id).baseID
            return MetaPreview(id: id, type: entry.request.type, name: entry.request.seriesName ?? entry.request.title,
                               poster: entry.request.poster, background: MetahubArtwork.background(imdbID: id))
        }
    }
}

extension AppServices {
    /// Adds the next available, unwatched episode to Continue Watching at 0% after a manual completion.
    /// Episode order and air dates come from the same metadata used by the detail page, not guessed numbers.
    func queueNextContinueEpisode(after request: StreamRequest) async {
        guard request.type == "series", request.season != nil, request.episode != nil else { return }
        let seriesID = ContentID(request.id).baseID
        let preview = MetaPreview(id: seriesID, type: "series",
                                  name: request.seriesName ?? request.title.components(separatedBy: " · ").first ?? request.title,
                                  poster: request.poster)
        let result = await browse.detail(for: preview)
        guard !result.isFallback, !Task.isCancelled else { return }
        let detail = result.detail
        guard let current = detail.videos.first(where: { $0.id == request.id })
                ?? detail.videos.first(where: { $0.season == request.season && $0.episode == request.episode }) else { return }
        var next = detail.nextVideo(after: current)
        while let video = next, video.hasAired(), !Task.isCancelled {
            let nextRequest = StreamRequest(episode: video, of: detail)
            let existing = await progress.progress(for: nextRequest.identity)
            if existing?.isWatched == true {
                next = detail.nextVideo(after: video)
                continue
            }
            var item = existing ?? WatchProgress(
                id: nextRequest.identity, type: nextRequest.type, contentID: nextRequest.id,
                title: nextRequest.title, poster: nextRequest.poster,
                position: 0, duration: 0, isWatched: false, updatedAt: Date(),
                season: nextRequest.season, episode: nextRequest.episode)
            // Started episodes retain their real position. An untouched episode gets the
            // persistent zero-progress marker, so SwiftData reloads do not drop its card.
            if ProgressRecorder.resumePosition(for: item) == 0 {
                item.isQueuedForContinue = true
            }
            item.updatedAt = Date()
            await progress.save(item)
            return
        }
    }

    /// Takes one title off Continue Watching everywhere it is kept. Trakt's paused record is removed by sync, now or when Trakt can next
    /// be reached, and stays hidden here until then.
    func removeContinueWatching(identity: String) async {
        await traktSync.playbackRemoved(identity)
        await progress.remove(identity)
    }
}
