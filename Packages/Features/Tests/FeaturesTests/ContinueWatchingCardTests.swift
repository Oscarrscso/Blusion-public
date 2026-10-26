import Foundation
import PlayerKit
import StremioKit
import Testing
@testable import Features

@Suite struct ContinueWatchingCardTests {
    private func progress(_ id: String, minutesAgo: Double, series: String? = nil, episode: Int? = nil) -> WatchProgress {
        let poster = URL(string: "https://img.example.com/\(series ?? id).jpg")
        if let series {
            return WatchProgress(id: "series/\(series):1:\(episode ?? 1)", type: "series", contentID: "\(series):1:\(episode ?? 1)",
                                 title: "Show · Episode \(episode ?? 1)", poster: poster, position: 300, duration: 1200, isWatched: false,
                                 updatedAt: Date(timeIntervalSinceNow: -minutesAgo * 60), season: 1, episode: episode ?? 1)
        }
        return WatchProgress(id: "movie/\(id)", type: "movie", contentID: id, title: id, poster: poster, position: 600, duration: 6000,
                             isWatched: false, updatedAt: Date(timeIntervalSinceNow: -minutesAgo * 60))
    }

    /// The widgets page showed Continue Watching's card with no pictures. It now shows the newest four titles, as Home's row lists them.
    @Test func theCardShowsTheNewestFourTitlesNewestFirst() {
        let local = [progress("tt1", minutesAgo: 50), progress("tt2", minutesAgo: 10), progress("tt3", minutesAgo: 30),
                     progress("tt4", minutesAgo: 5), progress("tt5", minutesAgo: 70), progress("tt6", minutesAgo: 1)]
        let items = ContinueWatchingEntry.cardItems(from: ContinueWatchingEntry.merge(local: local, remote: []))
        #expect(items.map(\.id) == ["tt6", "tt4", "tt2", "tt3"])
        #expect(items.allSatisfy { $0.poster?.absoluteString == "https://img.example.com/\($0.id).jpg" })
        #expect(items.allSatisfy { $0.background == MetahubArtwork.background(imdbID: $0.id) }, "each has its backdrop for the top row")
    }

    @Test func aSeriesIsOneTitleUnderItsShowsID() {
        let local = [progress("", minutesAgo: 2, series: "tt9", episode: 3), progress("", minutesAgo: 9, series: "tt9", episode: 2),
                     progress("tt1", minutesAgo: 5)]
        let items = ContinueWatchingEntry.cardItems(from: ContinueWatchingEntry.merge(local: local, remote: []))
        #expect(items.map(\.id) == ["tt9", "tt1"], "the show once, by its own id, for its pictures")
    }

    @Test func nothingInProgressLeavesTheCardEmpty() {
        #expect(ContinueWatchingEntry.cardItems(from: []).isEmpty)
    }

    /// The next episode, queued at 0% after "Mark as Watched", showed no caption at all. Its caption names it under the season and number.
    @Test func anEpisodeCardKnowsTheEpisodesOwnName() {
        func entry(_ title: String, series: String? = nil, episode: Int? = 2) -> ContinueWatchingEntry {
            ContinueWatchingEntry(request: StreamRequest(type: episode == nil ? "movie" : "series", id: "tt1:1:2", title: title,
                                                         season: episode == nil ? nil : 1, episode: episode, seriesName: series),
                                  fraction: 0, updatedAt: Date())
        }
        // The queued episode is saved from its title alone ("Series · Episode"), without the series name.
        let queued = ContinueWatchingEntry.merge(local: [progress("", minutesAgo: 1, series: "tt9", episode: 4)], remote: [])
        #expect(queued.first?.episodeName == "Episode 4")
        #expect(entry("JoJo's Bizarre Adventure · Sunlight Yellow Overdrive", series: "JoJo's Bizarre Adventure").episodeName
                == "Sunlight Yellow Overdrive")
        #expect(entry("Show · Part One · Part Two", series: "Show").episodeName == "Part One · Part Two", "a dot in the episode's name stays")
        #expect(entry("Show").episodeName == nil)
        #expect(entry("Inception · Director's Cut", episode: nil).episodeName == nil, "a film has no episode name")
        #expect(entry("Show · Episode 2").subtitle == "S1 E2")
    }
}
