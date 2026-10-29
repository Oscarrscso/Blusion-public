import Foundation
import StremioKit
import Testing
@testable import Features

/// The Downloads page's status and year filters, its sort, its chips, and the artwork addresses a download's card falls back through.
@Suite struct DownloadFilterTests {
    private func download(_ title: String, season: Int? = nil, episode: Int? = nil, year: String? = nil,
                          state: DownloadState = .complete, added: TimeInterval = 0) -> DownloadItem {
        var item = DownloadItem(request: StreamRequest(type: season == nil ? "movie" : "series", id: "tt1234567", title: title,
                                                       season: season, episode: episode, year: year),
                                addonID: UUID(), container: .matroska, usesFallback: false)
        item.state = state
        item.createdAt = Date(timeIntervalSince1970: added)
        return item
    }

    @Test func statusMatchesEachStateAndQueuedCountsAsDownloading() {
        let complete = download("A", state: .complete)
        let queued = download("B", state: .queued)
        let downloading = download("C", state: .downloading)
        let paused = download("D", state: .paused)
        let failed = download("E", state: .failed)
        #expect(DownloadStatusFilter.all.matches(paused))
        #expect(DownloadStatusFilter.downloaded.matches(complete) && !DownloadStatusFilter.downloaded.matches(queued))
        #expect(DownloadStatusFilter.downloading.matches(queued) && DownloadStatusFilter.downloading.matches(downloading))
        #expect(!DownloadStatusFilter.downloading.matches(paused))
        #expect(DownloadStatusFilter.paused.matches(paused))
        #expect(DownloadStatusFilter.failed.matches(failed) && !DownloadStatusFilter.failed.matches(complete))
    }

    @Test func yearSpanKeepsOnlyDownloadsInTheSpanAndExcludesUnknownYears() {
        let items = [download("Old", year: "1995"), download("New", year: "2011"), download("Unknown")]
        var filter = DownloadFilter()
        filter.minimumYear = 1990
        filter.maximumYear = 1999
        #expect(DownloadFiltering.apply(filter, to: items).map(\.request.title) == ["Old"])
        filter.maximumYear = nil
        filter.minimumYear = 2000
        #expect(DownloadFiltering.apply(filter, to: items).map(\.request.title) == ["New"])
    }

    @Test func recentlyAddedIsNewestFirst() {
        let items = [download("First", added: 100), download("Third", added: 300), download("Second", added: 200)]
        #expect(DownloadFiltering.apply(DownloadFilter(), to: items).map(\.request.title) == ["Third", "Second", "First"])
    }

    @Test func titleSortGroupsAShowsEpisodesInOrder() {
        let items = [download("Show", season: 1, episode: 2), download("Alpha"), download("Show", season: 1, episode: 1),
                     download("Show", season: 2, episode: 1)]
        var filter = DownloadFilter()
        filter.sort = .title
        let sorted = DownloadFiltering.apply(filter, to: items)
        #expect(sorted.map(\.request.title) == ["Alpha", "Show", "Show", "Show"])
        #expect(sorted.map { [$0.request.season ?? 0, $0.request.episode ?? 0] } == [[0, 0], [1, 1], [1, 2], [2, 1]])
    }

    @Test func yearSortPutsMissingYearsLast() {
        let items = [download("Unknown"), download("Old", year: "1990"), download("New", year: "2020")]
        var filter = DownloadFilter()
        filter.sort = .year
        #expect(DownloadFiltering.apply(filter, to: items).map(\.request.title) == ["New", "Old", "Unknown"])
    }

    @Test func chipsNameTheActiveFiltersAndRemoveThem() {
        var filter = DownloadFilter()
        filter.status = .paused
        filter.minimumYear = 1990
        filter.maximumYear = 1999
        #expect(filter.chips.map(\.label) == ["Paused", "1990–1999"])
        filter.remove(.status)
        #expect(filter.status == .all)
        #expect(filter.chips.map(\.label) == ["1990–1999"])
        filter.clearFilters()
        #expect(filter.chips.isEmpty)
    }

    @Test func clearingKeepsTheSort() {
        var filter = DownloadFilter()
        filter.sort = .title
        filter.status = .failed
        filter.clearFilters()
        #expect(filter.sort == .title)
    }

    @Test func anEpisodeTakesItsSeriesBackdrop() {
        let request = StreamRequest(type: "series", id: "tt1234567:1:2", title: "Show", season: 1, episode: 2)
        #expect(DownloadArtwork.titleID(request) == "tt1234567")
        #expect(DownloadArtwork.backdrop(for: request)?.absoluteString == "https://images.metahub.space/background/medium/tt1234567/img")
    }

    @Test func aCachedPictureIsUsedFirstThenTheBackdropThenThePoster() {
        let request = StreamRequest(type: "movie", id: "tt1234567", title: "Film")
        let cached = URL(fileURLWithPath: "/tmp/cached.artwork")
        let picture = DownloadArtwork.picture(for: request, cached: cached)
        #expect(picture.url == cached)
        #expect(picture.fallback == (DownloadArtwork.backdrop(for: request) ?? DownloadArtwork.poster(for: request)))
        let remote = DownloadArtwork.picture(for: request, cached: nil)
        #expect(remote.url == DownloadArtwork.backdrop(for: request))
        #expect(remote.fallback == DownloadArtwork.poster(for: request))
    }

    @Test func notAPictureIsNeverKeptAsArtwork() {
        #expect(!DownloadArtwork.isPicture(Data("<html>Error</html>".utf8)))
    }
}
