import Testing
@testable import StremioKit

@Suite struct ContentIDTests {
    @Test func imdbMovie() {
        let id = ContentID("tt1234567")
        #expect(id.kind == .imdb)
        #expect(id.baseID == "tt1234567")
        #expect(!id.isEpisode)
        #expect(id.prefix == nil)
    }

    @Test func imdbEpisode() {
        let id = ContentID("tt1234567:2:5")
        #expect(id.kind == .imdbEpisode(season: 2, episode: 5))
        #expect(id.baseID == "tt1234567")
        #expect(id.season == 2)
        #expect(id.episode == 5)
        #expect(id.isEpisode)
        #expect(id.prefix == "tt1234567")
    }

    @Test func specialsAreSeasonZero() {
        #expect(ContentID("tt1:0:3").season == 0)
    }

    @Test func otherAddonsStayOpaque() {
        for raw in ["kitsu:123:4", "mock:movie1", "mock:series1:1:2", "tmdb:55", "tt12:a:b", "tt", "tt1:1", "tt1:1:2:3", "", "anything"] {
            let id = ContentID(raw)
            #expect(id.kind == .other, "\(raw)")
            #expect(id.baseID == raw)
            #expect(id.season == nil && id.episode == nil)
        }
        #expect(ContentID("mock:movie1").prefix == "mock")
        #expect(ContentID("anything").prefix == nil)
    }

    @Test func buildsEpisodeIDs() {
        #expect(ContentID.episodeID(series: "tt1", season: 3, episode: 4) == "tt1:3:4")
        #expect(ContentID(ContentID.episodeID(series: "tt1", season: 3, episode: 4)).kind == .imdbEpisode(season: 3, episode: 4))
    }
}
