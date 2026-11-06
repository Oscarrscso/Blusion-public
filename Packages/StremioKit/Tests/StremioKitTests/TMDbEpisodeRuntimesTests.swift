import Foundation
import Testing
@testable import StremioKit

/// Episode lengths from TMDb's season data, for the episode cards.
@Suite struct TMDbEpisodeRuntimesTests {
    @Test func eachEpisodeWithARuntimeIsKeptByItsNumber() throws {
        let json = #"""
            {"episodes":[{"episode_number":1,"runtime":58},{"episode_number":2,"runtime":0},{"episode_number":3},
                         {"runtime":40},{"episode_number":4,"runtime":47,"vote_average":8.1}]}
            """#
        #expect(try TMDbRatings.parseSeasonRuntimes(Data(json.utf8)) == [1: 58, 4: 47], "no runtime, 0 or no number is left out")
    }

    @Test func eachEpisodeWithASynopsisIsKeptByItsNumber() throws {
        let json = #"""
            {"episodes":[{"episode_number":1,"overview":" Ross moves in. "},{"episode_number":2,"overview":""},
                         {"overview":"No number"},{"episode_number":3}]}
            """#
        #expect(try TMDbRatings.parseSeasonEpisodes(Data(json.utf8)).overviews == [1: "Ross moves in."])
    }

    @Test func tmdbSynopsesFillOnlyTheEpisodesOfThatSeasonWithoutOne() throws {
        let json = #"""
        {"id":"tt0108778","type":"series","name":"Show","videos":[
          {"id":"tt0108778:1:1","season":1,"episode":1},
          {"id":"tt0108778:1:2","season":1,"episode":2,"overview":"The addon's own."},
          {"id":"tt0108778:1:3","season":1,"episode":3,"overview":""},
          {"id":"tt0108778:2:1","season":2,"episode":1}
        ]}
        """#
        var detail = try JSONDecoder().decode(MetaDetail.self, from: Data(json.utf8))
        detail.fillEpisodeOverviews(season: 1, overviews: [1: "One", 2: "Two", 3: "Three"])
        #expect(detail.episodes(inSeason: 1).map(\.overview) == ["One", "The addon's own.", "Three"])
        #expect(detail.episodes(inSeason: 2).first?.overview == nil, "other seasons are untouched")
    }

    @Test func anAnswerWithoutEpisodesThrows() {
        #expect(throws: AddonError.invalidJSON) { try TMDbRatings.parseSeasonRuntimes(Data(#"{"id":1}"#.utf8)) }
    }
}
