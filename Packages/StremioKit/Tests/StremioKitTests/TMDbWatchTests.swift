import Foundation
import Testing
@testable import StremioKit

@Suite struct TMDbWatchTests {
    private let json = Data(#"""
    {"id": 550, "results": {
      "GB": {"link": "https://www.themoviedb.org/movie/550/watch?locale=GB",
             "flatrate": [{"logo_path": "/n.jpg", "provider_id": 8, "provider_name": "Netflix", "display_priority": 2},
                          {"logo_path": "/p.jpg", "provider_id": 9, "provider_name": "Prime Video", "display_priority": 1}],
             "rent": [{"logo_path": "/a.jpg", "provider_id": 2, "provider_name": "Apple TV", "display_priority": 0}],
             "buy": []},
      "US": {"flatrate": [{"logo_path": "/h.jpg", "provider_id": 384, "provider_name": "HBO Max", "display_priority": 0}]}
    }}
    """#.utf8)

    @Test func theRegionsOptionsComeInTMDbsOrder() throws {
        let watch = try TMDbTitleWatch.parse(json, region: "GB")
        #expect(watch.streaming.map(\.name) == ["Prime Video", "Netflix"])
        #expect(watch.rent.map(\.name) == ["Apple TV"])
        #expect(watch.buy.isEmpty && !watch.isEmpty)
        #expect(watch.link == URL(string: "https://www.themoviedb.org/movie/550/watch?locale=GB"))
        #expect(watch.streaming.first?.logo == URL(string: "https://image.tmdb.org/t/p/w92/p.jpg"))
    }

    @Test func aRegionTMDbDoesNotListIsEmpty() throws {
        #expect(try TMDbTitleWatch.parse(json, region: "FR").isEmpty)
    }
}
