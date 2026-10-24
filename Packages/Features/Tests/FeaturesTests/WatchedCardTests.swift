import Foundation
import Testing
import PlayerKit
import StremioKit
@testable import Features

/// The Library's Watched cards: one per movie and one per show, the show's named for it and showing its latest episode.
@Suite struct WatchedCardTests {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func episode(_ show: String, _ season: Int, _ number: Int, _ title: String, age: TimeInterval) -> WatchProgress {
        WatchProgress(id: "series/\(show):\(season):\(number)", type: "series", contentID: "\(show):\(season):\(number)",
                      title: "Show · \(title)", poster: URL(string: "https://example.com/show.jpg"), position: 0, duration: 0, isWatched: true,
                      updatedAt: when.addingTimeInterval(age), season: season, episode: number)
    }

    private func movie(_ id: String, age: TimeInterval) -> WatchProgress {
        WatchProgress(id: "movie/\(id)", type: "movie", contentID: id, title: "Movie \(id)", position: 0, duration: 0, isWatched: true,
                      updatedAt: when.addingTimeInterval(age))
    }

    @Test func aShowTakesOneCardNamedForItWithItsLatestEpisode() {
        let cards = WatchedCards.cards(from: [
            LibraryEntry(record: episode("tt1", 1, 2, "Second", age: 100), saved: nil),
            LibraryEntry(record: movie("tt9", age: 50), saved: nil),
            LibraryEntry(record: episode("tt1", 1, 1, "Pilot", age: 0), saved: nil),
        ])
        #expect(cards.map(\.id) == ["series/tt1", "movie/tt9"], "a card takes the place of its title's first entry")

        let show = cards[0]
        #expect(show.isShow && show.watchedCount == 2)
        #expect(show.latest.contentID == "tt1:1:2", "the newest episode is the one the card shows")
        #expect(show.preview.id == "tt1" && show.preview.type == "series" && show.preview.name == "Show")
        #expect(show.episodeLine == "S1E2 · Second")
    }

    @Test func aMovieKeepsItsOwnCard() {
        let cards = WatchedCards.cards(from: [LibraryEntry(record: movie("tt9", age: 0), saved: nil)])
        #expect(cards.count == 1)
        #expect(!cards[0].isShow && cards[0].watchedCount == 1)
        #expect(cards[0].episodeLine == nil)
        #expect(cards[0].preview.name == "Movie tt9" && cards[0].preview.id == "tt9")
    }

    @Test func aSavedShowIsNamedAsItIsSaved() {
        let saved = LibraryItem(preview: MetaPreview(id: "tt1", type: "series", name: "The Show"), addedAt: when)
        let cards = WatchedCards.cards(from: [LibraryEntry(record: episode("tt1", 1, 1, "Pilot", age: 0), saved: saved)])
        #expect(cards[0].preview.name == "The Show")
        #expect(cards[0].episodeLine == "S1E1 · Pilot", "the episode line still names the episode")
    }

    @Test func anEpisodeWithoutATitleShowsOnlyItsNumbers() {
        let record = WatchProgress(id: "series/tt1:3:4", type: "series", contentID: "tt1:3:4", title: "Show", position: 0, duration: 0,
                                   isWatched: true, updatedAt: when, season: 3, episode: 4)
        let cards = WatchedCards.cards(from: [LibraryEntry(record: record, saved: nil)])
        #expect(cards[0].episodeLine == "S3E4")
        #expect(cards[0].preview.name == "Show")
    }
}
