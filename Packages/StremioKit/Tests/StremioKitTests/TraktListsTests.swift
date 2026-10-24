import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

/// Trakt list browsing: popular, trending, search, users, paging, sorting, caching, and the saved widget shape.
@Suite struct TraktListsTests {
    private let popular = #"""
    [
      { "like_count": 6080, "comment_count": 6, "list": { "name": "IMDB: Top Rated Movies", "description": "Top 250 movies.", "privacy": "public",
        "item_count": 250, "likes": 6080, "ids": { "trakt": 2142753, "slug": "imdb-top-rated-movies" },
        "user": { "username": "justin", "private": false, "ids": { "slug": "justin" } } } },
      { "like_count": 1, "list": { "name": "No ids", "ids": {} } }
    ]
    """#

    private func client(_ transport: StubTransport, cache: TraktBrowseCache? = nil) -> TraktClient {
        TraktClient(client: makeClient(transport), cache: cache)
    }

    @Test func popularListsReadTheirOwnerCountsAndPagination() async throws {
        let transport = StubTransport(data: Data(popular.utf8), headers: ["x-pagination-page-count": "7"])
        let page = try await client(transport).lists(.popular, clientID: "key", page: 2, limit: 20)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.trakt.tv/lists/popular?page=2&limit=20")
        #expect(request.value(forHTTPHeaderField: "trakt-api-key") == "key")
        #expect(request.value(forHTTPHeaderField: "trakt-api-version") == "2")
        #expect(page.items.count == 1, "a list without ids cannot be opened, so it is dropped")
        let list = try #require(page.items.first)
        #expect(list.name == "IMDB: Top Rated Movies" && list.username == "justin" && list.slug == "imdb-top-rated-movies")
        #expect(list.itemCount == 250 && list.likes == 6080 && !list.isPrivate)
        #expect(page.page == 2 && page.pageCount == 7 && page.hasMore)
    }

    @Test func trendingListsUseTheirOwnPathAndTakeLikesFromTheEntry() async throws {
        let body = #"[{ "like_count": 74, "list": { "name": "T", "ids": { "trakt": 5, "slug": "t" }, "user": { "ids": { "slug": "u" } } } }]"#
        let transport = StubTransport(data: Data(body.utf8))
        let page = try await client(transport).lists(.trending, clientID: "key")
        #expect(transport.requests.first?.url?.path == "/lists/trending")
        #expect(page.items.first?.likes == 74 && page.pageCount == 1 && !page.hasMore)
    }

    @Test func searchSendsTheEncodedQueryAndReadsWrappedLists() async throws {
        let body = #"[{ "type": "list", "score": 9, "list": { "name": "Marvel & DC", "ids": { "trakt": 8, "slug": "m" }, "user": { "ids": { "slug": "fan" } } } }]"#
        let transport = StubTransport(data: Data(body.utf8))
        let page = try await client(transport).searchLists(query: " marvel & dc ", clientID: "key")
        #expect(transport.requests.first?.url?.absoluteString == "https://api.trakt.tv/search/list?query=marvel%20%26%20dc&page=1&limit=20")
        #expect(page.items.map(\.name) == ["Marvel & DC"])
    }

    @Test func aUsersListsAreBareObjectsAndPrivateOnesAreFlagged() async throws {
        let body = #"[{ "name": "Mine", "privacy": "private", "item_count": 3, "likes": 0, "ids": { "trakt": 9, "slug": "mine" } }]"#
        let transport = StubTransport(data: Data(body.utf8))
        let page = try await client(transport).userLists(username: "sean", clientID: "key")
        #expect(transport.requests.first?.url?.absoluteString == "https://api.trakt.tv/users/sean/lists")
        let list = try #require(page.items.first)
        #expect(list.isPrivate && list.username == "me")
        #expect(list.reference().isPrivate == true && list.reference().needsAccount)
    }

    @Test func aSignedInListNeedsAnAccountBeforeAnyRequest() async throws {
        let transport = StubTransport(data: Data("[]".utf8))
        let trakt = client(transport)
        await #expect(throws: TraktAccountError.needsSignIn) { try await trakt.myLists(clientID: "key") }
        await #expect(throws: TraktAccountError.needsSignIn) { try await trakt.likedLists(clientID: "key") }
        await #expect(throws: TraktAccountError.needsSignIn) { try await trakt.searchUsers(query: "a", clientID: "key") }
        #expect(transport.callCount == 0)
    }

    @Test func aSortedListReadsThroughTheSortPathAndAnUnsortedOneKeepsItsOwnOrder() async throws {
        let transport = StubTransport(data: Data("[]".utf8))
        let trakt = client(transport)
        _ = try await trakt.listItems(TraktListReference(username: "u", listSlug: "s", listName: "S"), clientID: "key", page: 2, limit: 30)
        _ = try await trakt.listItems(TraktListReference(username: "u", listSlug: "s", listName: "S", sort: .dateAdded), clientID: "key")
        _ = try await trakt.listItems(TraktListReference(username: "u", listSlug: "s", listName: "S", sort: .customRank), clientID: "key")
        let urls = transport.requests.compactMap { $0.url?.absoluteString }
        #expect(urls[0] == "https://api.trakt.tv/users/u/lists/s/items?page=2&limit=30&extended=full")
        #expect(urls[1] == "https://api.trakt.tv/users/u/lists/s/items/movie,show/added/desc?page=1&limit=50&extended=full")
        #expect(urls[2].contains("/items/movie,show/rank/asc?"))
    }

    @Test func browsePagesAreKeptForAWhileAndRefreshAsksAgain() async throws {
        let transport = StubTransport(data: Data(popular.utf8))
        let trakt = client(transport, cache: TraktBrowseCache())
        _ = try await trakt.lists(.popular, clientID: "key")
        _ = try await trakt.lists(.popular, clientID: "key")
        #expect(transport.callCount == 1)
        _ = try await trakt.lists(.popular, clientID: "key", refresh: true)
        #expect(transport.callCount == 2)
        _ = try await trakt.lists(.trending, clientID: "key")
        #expect(transport.callCount == 3)
    }

    @Test func aCachedPageExpires() async throws {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }
        let clock = Clock()
        let transport = StubTransport(data: Data(popular.utf8))
        let trakt = client(transport, cache: TraktBrowseCache(ttl: 60, now: { clock.now }))
        _ = try await trakt.lists(.popular, clientID: "key")
        clock.now = clock.now.addingTimeInterval(61)
        _ = try await trakt.lists(.popular, clientID: "key")
        #expect(transport.callCount == 2)
    }

    @Test func aFailedResponseIsNeverCached() async throws {
        let cache = TraktBrowseCache()
        let result = HTTPResult(data: Data(), response: HTTPResponseInfo(statusCode: 500))
        await cache.store(result, for: "k")
        #expect(await cache.value(for: "k") == nil)
    }

    @Test func theClientIDComesOnlyFromSettings() async {
        #expect(await TraktClient.clientID(in: InMemorySettingsStore(PlaybackSettings(traktClientID: " mine "))) == "mine")
        #expect(await TraktClient.clientID(in: InMemorySettingsStore()) == "")
    }

    // MARK: Saved widgets

    @Test func aWidgetSavedBeforeSortingStillDecodesAsTheListsOwnOrder() throws {
        let old = #"{"username":"u","listSlug":"s","listName":"S","traktID":5}"#
        let list = try JSONDecoder().decode(TraktListReference.self, from: Data(old.utf8))
        #expect(list.sort == nil && list.isPrivate == nil && !list.needsAccount && list.traktID == 5)
    }

    @Test func anUnsortedListEncodesExactlyAsBefore() throws {
        let data = try JSONEncoder().encode(TraktListReference(username: "u", listSlug: "s", listName: "S"))
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys.sorted()
        #expect(keys == ["listName", "listSlug", "username"], "unchanged keys keep each source's saved snapshot file")
    }

    @Test func aSortRoundTripsThroughTheStoreAndThroughFusion() async throws {
        let source = WidgetSource.traktList(TraktListReference(username: "u", listSlug: "s", listName: "S", traktID: 1, sort: .rating, isPrivate: true))
        let widget = HomeWidget(id: "w", title: "S", content: .row(RowConfiguration(source: source)))
        let name = "test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DefaultsWidgetStore(defaults: defaults)
        await store.save([widget])
        #expect(await store.load() == [widget])
        let exported = try FusionWidgetCodec.encode([widget])
        let imported = try FusionWidgetCodec.decode(exported, installed: [])
        #expect(imported.widgets.first?.content == widget.content)
    }

    @Test func oneUnreadableWidgetDoesNotWipeTheLayout() async throws {
        let name = "test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let good = HomeWidget(id: "good", title: "Continue", content: .continueWatching)
        let goodJSON = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        let layout = #"{"version":1,"widgets":[\#(goodJSON),{"id":"future","title":"X","hideTitle":false,"content":{"holographic":{}}}]}"#
        defaults.set(Data(layout.utf8), forKey: DefaultsWidgetStore.key)
        #expect(await DefaultsWidgetStore(defaults: defaults).load() == [good])
    }
}
