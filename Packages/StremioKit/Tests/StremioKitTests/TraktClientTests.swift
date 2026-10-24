import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import StremioKit
import StremioKitTestSupport

@Suite struct TraktClientTests {
    private let list = TraktListReference(username: "tvgeniekodi", listSlug: "daily-picks", listName: "Daily Picks", traktID: 31897770)

    /// The list endpoint's shape: a movie, a show, a person (dropped) and a movie without an IMDb id (dropped).
    private let sample = #"""
    [
      { "rank": 1, "type": "movie", "movie": { "title": "Inception", "year": 2010, "ids": { "trakt": 1, "slug": "inception-2010", "imdb": "tt1375666",
          "tmdb": 27205 }, "overview": "A thief...", "rating": 8.67, "runtime": 148, "genres": ["action","science-fiction"] } },
      { "rank": 2, "type": "show", "show": { "title": "Breaking Bad", "year": 2008, "ids": { "imdb": "tt0903747" }, "overview": "A chemistry teacher.",
          "rating": 9.3, "runtime": 47, "genres": ["drama"] } },
      { "rank": 3, "type": "person", "person": { "name": "Someone" } },
      { "rank": 4, "type": "movie", "movie": { "title": "No ids", "year": 2001, "ids": { "trakt": 9 } } }
    ]
    """#

    @Test func theRequestHasThePathQueryAndHeaders() async throws {
        let transport = StubTransport(data: Data("[]".utf8))
        _ = try await TraktClient(client: makeClient(transport)).listItems(list, clientID: "client-123", page: 2, limit: 25)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.trakt.tv/users/tvgeniekodi/lists/daily-picks/items?page=2&limit=25&extended=full")
        #expect(request.value(forHTTPHeaderField: "trakt-api-version") == "2")
        #expect(request.value(forHTTPHeaderField: "trakt-api-key") == "client-123")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func pathPartsArePercentEncodedAndTheDefaultsAreFirstPageOfFifty() async throws {
        let transport = StubTransport(data: Data("[]".utf8))
        let odd = TraktListReference(username: "a/b c", listSlug: "x?y", listName: "Odd")
        _ = try await TraktClient(client: makeClient(transport)).listItems(odd, clientID: "key")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.trakt.tv/users/a%2Fb%20c/lists/x%3Fy/items?page=1&limit=50&extended=full")
    }

    @Test func pagesStartAtOneAndTheLimitStopsAtTraktsMaximum() async throws {
        let transport = StubTransport(data: Data("[]".utf8))
        _ = try await TraktClient(client: makeClient(transport)).listItems(list, clientID: "key", page: 0, limit: 500)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString.hasSuffix("/items?page=1&limit=100&extended=full") == true)
    }

    @Test func aCustomBaseURLKeepsItsPath() async throws {
        let transport = StubTransport(data: Data("[]".utf8))
        let base = try #require(URL(string: "https://trakt.example.com/api/"))
        _ = try await TraktClient(client: makeClient(transport), baseURL: base).listItems(list, clientID: "key")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString.hasPrefix("https://trakt.example.com/api/users/tvgeniekodi/lists/daily-picks/items") == true)
    }

    @Test func theSampleMapsMoviesAndShowsInOrder() async throws {
        let transport = StubTransport(data: Data(sample.utf8))
        let items = try await TraktClient(client: makeClient(transport)).listItems(list, clientID: "key")
        #expect(items.map(\.id) == ["tt1375666", "tt0903747"], "the person and the id-less movie are dropped")

        let movie = items[0]
        #expect(movie.type == "movie" && movie.name == "Inception")
        #expect(movie.poster == URL(string: "https://images.metahub.space/poster/medium/tt1375666/img"))
        #expect(movie.background == URL(string: "https://images.metahub.space/background/medium/tt1375666/img"))
        #expect(movie.logo == URL(string: "https://images.metahub.space/logo/medium/tt1375666/img"))
        #expect(movie.description == "A thief...")
        #expect(movie.releaseInfo == "2010")
        #expect(movie.imdbRating == 8.7)
        #expect(movie.genres == ["Action", "Science fiction"])
        #expect(movie.runtime == "148 min")

        let show = items[1]
        #expect(show.type == "series" && show.name == "Breaking Bad")
        #expect(show.releaseInfo == "2008" && show.imdbRating == 9.3)
        #expect(show.genres == ["Drama"] && show.runtime == "47 min")
        #expect(show.description == "A chemistry teacher.")
    }

    @Test func missingRatingsAndZeroRuntimesAreOmittedAndRatingsRoundToOneDecimal() async throws {
        let transport = StubTransport(data: Data(#"""
        [{"type":"movie","movie":{"title":"Zero","ids":{"imdb":"tt9"},"rating":6.04,"runtime":0,"genres":["science-fiction","news"]}},
         {"type":"show","show":{"title":"Bare","ids":{"imdb":"tt8"}}}]
        """#.utf8))
        let items = try await TraktClient(client: makeClient(transport)).listItems(list, clientID: "key")
        #expect(items[0].imdbRating == 6.0 && items[0].runtime == nil)
        #expect(items[0].genres == ["Science fiction", "News"])
        #expect(items[1].imdbRating == nil && items[1].genres.isEmpty && items[1].runtime == nil && items[1].releaseInfo == nil)
    }

    @Test func anEmptyArrayIsAnEmptyPage() async throws {
        let transport = StubTransport(data: Data("[]".utf8))
        #expect(try await TraktClient(client: makeClient(transport)).listItems(list, clientID: "key").isEmpty)
    }

    @Test func badElementsAreDroppedNotFatal() async throws {
        let transport = StubTransport(data: Data(#"[{"type":"movie"}, 5, {"type":"movie","movie":{"title":"X","ids":{"imdb":"tt7"}}}]"#.utf8))
        let items = try await TraktClient(client: makeClient(transport)).listItems(list, clientID: "key")
        #expect(items.map(\.id) == ["tt7"] && items.first?.name == "X")
    }

    @Test func unauthorizedIsAnHTTPError() async {
        let transport = StubTransport(data: Data(#"{"error":"Invalid API key"}"#.utf8), status: 401)
        await #expect(throws: AddonError.http(status: 401)) { try await TraktClient(client: makeClient(transport)).listItems(list, clientID: "bad") }
        #expect(transport.callCount == 1, "a 401 is not retried")
    }

    @Test func aNonArrayBodyIsInvalidJSON() async {
        let transport = StubTransport(data: Data(#"{"error":"nope"}"#.utf8))
        await #expect(throws: AddonError.invalidJSON) { try await TraktClient(client: makeClient(transport)).listItems(list, clientID: "key") }
    }

    @Test func artworkNeedsASafeIMDbID() {
        #expect(MetahubArtwork.poster(imdbID: "tt1")?.absoluteString == "https://images.metahub.space/poster/medium/tt1/img")
        #expect(MetahubArtwork.background(imdbID: "tt1")?.absoluteString == "https://images.metahub.space/background/medium/tt1/img")
        #expect(MetahubArtwork.logo(imdbID: "tt1")?.absoluteString == "https://images.metahub.space/logo/medium/tt1/img")
        #expect(MetahubArtwork.poster(imdbID: "") == nil)
        #expect(MetahubArtwork.poster(imdbID: "../etc") == nil)
        #expect(MetahubArtwork.logo(imdbID: "tt 1") == nil)
    }

    @Test func theDefaultBaseURLIsTraktsAPI() {
        #expect(TraktClient.defaultBaseURL.absoluteString == "https://api.trakt.tv")
    }
}
