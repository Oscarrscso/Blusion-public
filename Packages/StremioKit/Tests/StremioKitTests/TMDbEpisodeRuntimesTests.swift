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

    @Test func anAnswerWithoutEpisodesThrows() {
        #expect(throws: AddonError.invalidJSON) { try TMDbRatings.parseSeasonRuntimes(Data(#"{"id":1}"#.utf8)) }
    }
}
