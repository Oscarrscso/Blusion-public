import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import StremioKit
import StremioKitTestSupport

/// Trakt feeds (trending and popular), list-by-link, and the Blusion-only `blusion.traktFeed` kind in Fusion files.
@Suite struct TraktFeedTests {
    /// Trending entries are wrapped with a watcher count.
    private let trendingMovies = #"""
    [
      { "watchers": 12, "movie": { "title": "Inception", "year": 2010, "ids": { "trakt": 1, "imdb": "tt1375666" }, "rating": 8.67 } },
      { "watchers": 9, "movie": { "title": "No ids", "year": 2001, "ids": { "trakt": 9 } } }
    ]
    """#

    /// Popular entries are the media themselves.
    private let popularShows = #"""
    [
      { "title": "Breaking Bad", "year": 2008, "ids": { "imdb": "tt0903747" }, "genres": ["drama", "science-fiction"] },
      { "title": "No imdb", "ids": { "trakt": 7 } }
    ]
    """#

    @Test func aFeedRequestHasItsPathPagingAndHeaders() async throws {
        let transport = StubTransport(data: Data("[]".utf8))
        _ = try await TraktClient(client: makeClient(transport)).feedItems(.moviesTrending, clientID: "key-1", page: 3, limit: 20)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.trakt.tv/movies/trending?page=3&limit=20&extended=full")
        #expect(request.value(forHTTPHeaderField: "trakt-api-key") == "key-1")
        #expect(request.value(forHTTPHeaderField: "trakt-api-version") == "2")
    }

    @Test func everyFeedUsesItsOwnPath() {
        #expect(TraktFeed.allCases.map(\.path) == ["movies/trending", "movies/popular", "shows/trending", "shows/popular"])
        #expect(TraktFeed.showsPopular.mediaType == "series" && TraktFeed.moviesPopular.mediaType == "movie")
    }

    @Test func trendingEntriesAreUnwrapped() async throws {
        let transport = StubTransport(data: Data(trendingMovies.utf8))
        let items = try await TraktClient(client: makeClient(transport)).feedItems(.moviesTrending, clientID: "key")
        #expect(items.map(\.id) == ["tt1375666"])
        #expect(items.first?.type == "movie" && items.first?.name == "Inception")
    }

    @Test func popularEntriesAreTheMediaAndShowsMapToSeries() async throws {
        let transport = StubTransport(data: Data(popularShows.utf8))
        let items = try await TraktClient(client: makeClient(transport)).feedItems(.showsPopular, clientID: "key")
        #expect(items.map(\.id) == ["tt0903747"], "an entry without an IMDb id is dropped")
        #expect(items.first?.type == "series")
        #expect(items.first?.genres == ["Drama", "Science fiction"])
    }

    @Test func aFeedThatIsNotAnArrayFailsAsInvalidJSON() async throws {
        let transport = StubTransport(data: Data(#"{"error":"nope"}"#.utf8))
        await #expect(throws: AddonError.invalidJSON) { try await TraktClient(client: makeClient(transport)).feedItems(.moviesPopular, clientID: "key") }
    }

    @Test func aListLinkIsReadWithOrWithoutAScheme() {
        let expected = ("tvgeniekodi", "daily-picks")
        for link in ["https://trakt.tv/users/tvgeniekodi/lists/daily-picks", "trakt.tv/users/tvgeniekodi/lists/daily-picks/",
                     "  https://www.trakt.tv/users/tvgeniekodi/lists/daily-picks?sort=rank  "] {
            let parsed = TraktClient.listReference(fromLink: link)
            #expect(parsed?.username == expected.0 && parsed?.listSlug == expected.1, "\(link)")
        }
    }

    @Test func aNonListLinkIsRejected() {
        for link in ["", "https://example.com/users/a/lists/b", "https://trakt.tv/users/a/watchlist", "https://trakt.tv/movies/inception",
                     "https://nottrakt.tv/users/a/lists/b", "not a link"] {
            #expect(TraktClient.listReference(fromLink: link) == nil, "\(link)")
        }
    }

    @Test func listInfoReadsTheNameAndTraktID() async throws {
        let transport = StubTransport(data: Data(#"{"name":"Daily Picks","ids":{"trakt":31897770,"slug":"daily-picks"}}"#.utf8))
        let info = try await TraktClient(client: makeClient(transport)).listInfo(username: "tvgeniekodi", listSlug: "daily-picks", clientID: "key")
        #expect(info.name == "Daily Picks" && info.traktID == 31897770)
        #expect(transport.requests.first?.url?.absoluteString == "https://api.trakt.tv/users/tvgeniekodi/lists/daily-picks?extended=full")
    }

    @Test func listInfoFallsBackToTheSlugWhenTheNameIsMissing() async throws {
        let transport = StubTransport(data: Data(#"{"ids":{}}"#.utf8))
        let info = try await TraktClient(client: makeClient(transport)).listInfo(username: "u", listSlug: "my-list", clientID: "key")
        #expect(info.name == "my-list" && info.traktID == nil)
    }

    @Test func aFeedRowWithoutAClientIDRequiresConfiguration() async throws {
        let transport = StubTransport(data: Data(popularShows.utf8))
        let (service, _) = try await makeFeedService(transport: transport, clientID: nil)
        let source = WidgetSource.traktFeed(.showsPopular)
        #expect(await service.issue(with: source) == .needsTraktClientID)
        await #expect(throws: WidgetSourceError.needsTraktClientID) {
            try await service.items(for: source, cacheTTL: 0)
        }
        #expect(transport.callCount == 0)
    }

    @Test func aFeedRowLoadsWithTheClientID() async throws {
        let transport = StubTransport(data: Data(popularShows.utf8))
        let (service, _) = try await makeFeedService(transport: transport, clientID: "key-2")
        let source = WidgetSource.traktFeed(.showsPopular)
        let items = try await service.items(for: source, limit: 20, cacheTTL: 0)
        #expect(items.map(\.id) == ["tt0903747"])
        #expect(await service.issue(with: source) == nil)
        #expect(transport.requests.last?.value(forHTTPHeaderField: "trakt-api-key") == "key-2")
    }

    @Test func aFeedRoundTripsThroughFusionAsBlusionKind() throws {
        let widget = HomeWidget(id: "f", title: "Trending", content: .row(RowConfiguration(source: .traktFeed(.moviesTrending))))
        let data = try FusionWidgetCodec.encode([widget])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"blusion.traktFeed\"") && text.contains("\"moviesTrending\""))
        let result = try FusionWidgetCodec.decode(data, installed: [])
        #expect(result.widgets == [widget])
        #expect(result.skipped == 0)
    }

    @Test func anUnknownFeedNameIsKeptAsUnsupported() throws {
        let text = #"""
        { "widgets": [ { "id": "x", "title": "X", "type": "row.classic",
          "dataSource": { "kind": "blusion.traktFeed", "payload": { "feed": "weekly" } } } ] }
        """#
        let result = try FusionWidgetCodec.decode(Data(text.utf8), installed: [])
        guard case .row(let row) = result.widgets.first?.content else {
            Issue.record("the row should still be kept")
            return
        }
        #expect(row.source == .unsupported(kind: "blusion.traktFeed"))
    }

    /// A service whose only addon is the stub catalog; Trakt requests are answered by `transport`.
    private func makeFeedService(transport: StubTransport, clientID: String?) async throws -> (service: WidgetContentService, registry: AddonRegistry) {
        let (registry, client) = try await makeStubbedRegistry(manifests: [], transport: transport)
        let settings = PlaybackSettings(traktClientID: clientID)
        let service = WidgetContentService(registry: registry, client: client, settings: InMemorySettingsStore(settings))
        return (service, registry)
    }
}
