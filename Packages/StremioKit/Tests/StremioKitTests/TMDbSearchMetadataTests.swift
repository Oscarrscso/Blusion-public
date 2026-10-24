import Foundation
import Testing
import StremioKitTestSupport
@testable import StremioKit

@Suite struct TMDbSearchMetadataTests {
    private let movie = Data(#"""
    {"title":"A Comedy","imdb_id":"tt1234567","overview":"Two friends go on a journey.",
     "release_date":"1995-06-01","original_language":"en","runtime":98,
     "genres":[{"name":"Comedy"}],"production_companies":[{"name":"A Studio"}],
     "vote_average":7.5,"vote_count":500}
    """#.utf8)

    @Test func metadataKeepsRuntimeGenresLanguageAndScoreOnTheirOwnScales() throws {
        let facts = try #require(try TMDbSearchMetadata.parse(movie, mediaType: "movie"))
        #expect(facts.item.releaseInfo == "1995" && facts.item.runtime == "98 min")
        #expect(facts.item.genres == ["Comedy"] && facts.language == "en")
        #expect(facts.companies == ["A Studio"] && facts.score == 7.5)
        #expect(facts.item.imdbRating == nil, "TMDb's score must not become an IMDb rating")
    }

    @Test func seriesUsesAppendedIMDbIdentityAndEpisodeRuntime() throws {
        let data = Data(#"{"name":"A Series","external_ids":{"imdb_id":"tt7654321"},"episode_run_time":[25],"first_air_date":"1997-01-01"}"#.utf8)
        let facts = try #require(try TMDbSearchMetadata.parse(data, mediaType: "tv"))
        #expect(facts.item.type == "series" && facts.item.id == "tt7654321")
        #expect(facts.item.runtime == "25 min" && facts.item.releaseInfo == "1997")
        #expect(facts.score == nil)
    }

    @Test func oneRequestSuppliesMetadataAndExternalIdentity() async throws {
        let transport = StubTransport(data: movie)
        let api = TMDbRatings(client: makeClient(transport, retries: 0), readAccessToken: "test-key")
        #expect(try await api.searchMetadata(tmdbID: 100, mediaType: "movie")?.item.name == "A Comedy")
        #expect(transport.callCount == 1)
        let url = try #require(transport.requests.first?.url)
        #expect(url.path.hasSuffix("/movie/100"))
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
            $0.name == "append_to_response" && $0.value == "external_ids"
        } == true)
    }
}
