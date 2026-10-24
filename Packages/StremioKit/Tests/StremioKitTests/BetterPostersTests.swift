import Foundation
import Testing
@testable import StremioKit

@Suite struct BetterPostersTests {
    @Test func anIMDbIDAddressesThePosterByIt() {
        #expect(BetterPosters.posterURL(id: "tt1375666", type: "movie")?.absoluteString
                == "https://btttr.cc/poster/imdb/poster-default/tt1375666.jpg?rs=IM")
        #expect(BetterPosters.posterURL(id: "tt1375666", type: "series")?.absoluteString
                == "https://btttr.cc/poster/imdb/poster-default/tt1375666.jpg?rs=IM", "an IMDb id does not depend on the type")
    }

    @Test func aSeriesEpisodeIDDropsItsSeasonAndEpisode() {
        #expect(BetterPosters.posterURL(id: "tt0903747:1:2", type: "series")?.absoluteString
                == "https://btttr.cc/poster/imdb/poster-default/tt0903747.jpg?rs=IM")
    }

    @Test func aTMDbIDAddressesAMovieOrASeries() {
        #expect(BetterPosters.posterURL(id: "tmdb:27205", type: "movie")?.absoluteString
                == "https://btttr.cc/poster/tmdb/poster-default/movie-27205.jpg?rs=IM")
        #expect(BetterPosters.posterURL(id: "tmdb:1399", type: "series")?.absoluteString
                == "https://btttr.cc/poster/tmdb/poster-default/series-1399.jpg?rs=IM")
        #expect(BetterPosters.posterURL(id: "tmdb:27205", type: "anime") == nil, "any other type has no poster address")
    }

    @Test func anythingElseHasNoAddress() {
        for id in ["", "kitsu:1", "tt12x", "tt", "tt:1:2", "tt1375666:1", "tt1375666:x:2", "tt1375666/../x", "tt1375666?x=1",
                   "tmdb:", "tmdb:abc", "tmdb:27205/x", "tmdb:-1", " tt1375666"] {
            #expect(BetterPosters.posterURL(id: id, type: "movie") == nil, "\(id) has no address")
        }
    }
}
