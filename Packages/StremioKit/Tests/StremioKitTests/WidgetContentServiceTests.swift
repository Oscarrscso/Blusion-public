import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import StremioKit
import StremioKitTestSupport

/// A clock that tests can move forward.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// `top` has sixty items (`t0`...`t59`) and takes a genre and skip; `other` has `t1`, `b1`, `t2` and no skip; `broken` always fails.
private func catalogResponse(for request: URLRequest) -> HTTPResult {
    let path = request.url?.path ?? ""
    if path.contains("/catalog/movie/broken") { return StubTransport.response(Data(), status: 500, for: request) }
    if path.contains("/catalog/movie/other") {
        return StubTransport.response(Data(#"{"metas":[{"id":"t1"},{"id":"b1"},{"id":"t2"}]}"#.utf8), for: request)
    }
    let metas = (0..<60).map { "{\"id\":\"t\($0)\"}" }.joined(separator: ",")
    return StubTransport.response(Data("{\"metas\":[\(metas)]}".utf8), for: request)
}

@Suite struct WidgetContentServiceTests {
    private let catalog = Manifest(
        id: "test.catalog", name: "Catalog", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
        catalogs: [
            CatalogDescriptor(type: "movie", id: "top", name: "Top", extra: [ExtraDescriptor(name: "genre", options: ["Action", "Drama"]),
                ExtraDescriptor(name: "skip")]),
            CatalogDescriptor(type: "movie", id: "other", name: "Other"),
            CatalogDescriptor(type: "movie", id: "broken", name: "Broken"),
        ])

    private func makeService(transport: StubTransport, settings: PlaybackSettings = PlaybackSettings(),
                             snapshots: (any WidgetSnapshotStore)? = nil,
                             now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_000_000) }) async throws
        -> (service: WidgetContentService, registry: AddonRegistry) {
        let (registry, client) = try await makeStubbedRegistry(manifests: [catalog], transport: transport)
        let service = WidgetContentService(registry: registry, client: client, settings: InMemorySettingsStore(settings), snapshots: snapshots, now: now)
        return (service, registry)
    }

    /// A service as a new launch builds it: a fresh registry and an empty memory cache, reading the same snapshot store.
    private func relaunch(transport: StubTransport, snapshots: any WidgetSnapshotStore) async throws -> WidgetContentService {
        let (registry, client) = try await makeStubbedRegistry(manifests: [catalog], transport: transport)
        return WidgetContentService(registry: registry, client: client, settings: InMemorySettingsStore(), snapshots: snapshots)
    }

    private func catalogSource(_ catalogID: String, genre: String? = nil) -> WidgetSource {
        .addonCatalog(AddonCatalogReference(manifestID: "test.catalog", host: "stub0.example.com", catalogType: "movie", catalogID: catalogID, genre: genre))
    }

    private let traktList = WidgetSource.traktList(TraktListReference(username: "tvgeniekodi", listSlug: "daily-picks", listName: "Daily Picks"))

    // MARK: Requests

    @Test func genreAndSkipReachTheCatalogRequest() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (service, _) = try await makeService(transport: transport)
        _ = try await service.items(for: catalogSource("top", genre: "Action"), limit: 20, cacheTTL: 0)
        let genreOnly = try #require(transport.requests.last?.url?.absoluteString)
        #expect(genreOnly.hasSuffix("/catalog/movie/top/genre=Action.json"))

        _ = try await service.items(for: catalogSource("top", genre: "Action"), limit: 20, skip: 20, cacheTTL: 0)
        let genreAndSkip = try #require(transport.requests.last?.url?.absoluteString)
        #expect(genreAndSkip.hasSuffix("/catalog/movie/top/genre=Action&skip=20.json"))
    }

    @Test func theLimitIsAppliedToTheResponse() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (service, _) = try await makeService(transport: transport)
        let page = try await service.items(for: catalogSource("top"), limit: 20, cacheTTL: 0)
        #expect(page.count == 20 && page.first?.id == "t0")
    }

    @Test func heroAndRowShareOnePendingCatalogPageAcrossDisplayLimits() async throws {
        let transport = StubTransport { request, _ in
            try await Task.sleep(for: .milliseconds(50))
            return catalogResponse(for: request)
        }
        let (service, _) = try await makeService(transport: transport)
        async let hero = service.items(for: catalogSource("top"), limit: 8)
        async let row = service.items(for: catalogSource("top"), limit: 20)
        let (heroItems, rowItems) = try await (hero, row)
        #expect(heroItems.count == 8 && rowItems.count == 20)
        #expect(transport.callCount == 1)
        #expect(try await service.items(for: catalogSource("top"), limit: 40).count == 40)
        #expect(transport.callCount == 1, "the full page is cached, not the hero's truncated prefix")
    }

    @Test func cancellingOneWidgetKeepsTheSharedRequestForTheOtherWidget() async throws {
        let transport = StubTransport { request, _ in
            try await Task.sleep(for: .milliseconds(150))
            return catalogResponse(for: request)
        }
        let (service, _) = try await makeService(transport: transport)
        let hero = Task { try await service.items(for: catalogSource("top"), limit: 8) }
        let row = Task { try await service.items(for: catalogSource("top"), limit: 20) }
        try await Task.sleep(for: .milliseconds(30))
        hero.cancel()
        #expect(try await row.value.count == 20)
        if case .success = await hero.result { Issue.record("a cancelled caller must not publish a result") }
        #expect(transport.callCount == 1)
    }

    @Test func aCatalogThatCannotPageReturnsNothingBeyondItsFirstPageWithoutARequest() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (service, _) = try await makeService(transport: transport)
        let page = try await service.items(for: catalogSource("other"), limit: 20, skip: 20, cacheTTL: 0)
        #expect(page.isEmpty)
        #expect(transport.callCount == 0)
        let firstPage = try await service.items(for: catalogSource("other"), limit: 20, cacheTTL: 0)
        #expect(firstPage.map(\.id) == ["t1", "b1", "t2"])
    }

    @Test func aZeroLimitAsksForNothing() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (service, _) = try await makeService(transport: transport)
        #expect(try await service.items(for: catalogSource("top"), limit: 0).isEmpty)
        #expect(transport.callCount == 0)
    }

    // MARK: Cache

    @Test func aSecondCallWithinTheTTLIsServedFromMemoryAndALaterOneReloads() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let (service, _) = try await makeService(transport: transport, now: { clock.now })
        _ = try await service.items(for: catalogSource("top"), limit: 5, cacheTTL: 3600)
        #expect(transport.callCount == 1)
        _ = try await service.items(for: catalogSource("top"), limit: 5, cacheTTL: 3600)
        #expect(transport.callCount == 1, "within the TTL: no request")

        clock.advance(by: 3599)
        _ = try await service.items(for: catalogSource("top"), limit: 5, cacheTTL: 3600)
        #expect(transport.callCount == 1, "one second before expiry is still fresh")

        clock.advance(by: 2)
        _ = try await service.items(for: catalogSource("top"), limit: 5, cacheTTL: 3600)
        #expect(transport.callCount == 2, "after the TTL: a new request")
    }

    @Test func aZeroTTLAlwaysRequests() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (service, _) = try await makeService(transport: transport)
        _ = try await service.items(for: catalogSource("top"), limit: 5, cacheTTL: 0)
        _ = try await service.items(for: catalogSource("top"), limit: 5, cacheTTL: 0)
        #expect(transport.callCount == 2)
    }

    @Test func addonPagesShareDisplayLimitsButKeepSkipSeparate() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (service, _) = try await makeService(transport: transport)
        _ = try await service.items(for: catalogSource("top"), limit: 5)
        _ = try await service.items(for: catalogSource("top"), limit: 10)
        _ = try await service.items(for: catalogSource("top"), limit: 5, skip: 5)
        _ = try await service.items(for: catalogSource("top"), limit: 5)
        #expect(transport.callCount == 2)
    }

    @Test func invalidateForgetsEveryCachedPage() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (service, _) = try await makeService(transport: transport)
        _ = try await service.items(for: catalogSource("top"), limit: 5)
        await service.invalidate()
        _ = try await service.items(for: catalogSource("top"), limit: 5)
        #expect(transport.callCount == 2)
    }

    @Test func aFailedLoadIsNotCached() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (service, _) = try await makeService(transport: transport)
        await #expect(throws: WidgetSourceError.addon(.http(status: 500))) { try await service.items(for: catalogSource("broken"), limit: 5) }
        await #expect(throws: WidgetSourceError.addon(.http(status: 500))) { try await service.items(for: catalogSource("broken"), limit: 5) }
        #expect(transport.callCount == 2)
    }

    // MARK: Last-known items

    @Test func lastKnownItemsSurviveANewLaunchSharingTheSnapshotStore() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let snapshots = InMemoryWidgetSnapshotStore()
        let (first, _) = try await makeService(transport: transport, snapshots: snapshots)
        _ = try await first.items(for: catalogSource("top"), limit: 5)
        let relaunched = try await relaunch(transport: transport, snapshots: snapshots)
        let known = await relaunched.lastKnownItems(for: catalogSource("top"), limit: 5)
        #expect(known?.map(\.id) == ["t0", "t1", "t2", "t3", "t4"])
        #expect(transport.callCount == 1, "last-known items never ask an addon")
        let twoOnly = await relaunched.lastKnownItems(for: catalogSource("top"), limit: 2)
        #expect(twoOnly?.map(\.id) == ["t0", "t1"], "the limit applies to what is returned")
    }

    @Test func lastKnownItemsSurviveInvalidateAndExpiry() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let snapshots = InMemoryWidgetSnapshotStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let (service, _) = try await makeService(transport: transport, snapshots: snapshots, now: { clock.now })
        _ = try await service.items(for: catalogSource("top"), limit: 5, cacheTTL: 60)
        clock.advance(by: 3600)
        let expired = await service.lastKnownItems(for: catalogSource("top"), limit: 5)
        #expect(expired?.count == 5, "an expired page is still last-known")
        await service.invalidate()
        let afterInvalidate = await service.lastKnownItems(for: catalogSource("top"), limit: 5)
        #expect(afterInvalidate?.count == 5, "invalidate forgets the memory cache, not the snapshot")
        #expect(transport.callCount == 1)
    }

    @Test func anExpiredPageStaysKnownInMemoryWithoutASnapshotStore() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let (service, _) = try await makeService(transport: transport, now: { clock.now })
        _ = try await service.items(for: catalogSource("top"), limit: 5, cacheTTL: 60)
        clock.advance(by: 3600)
        let expired = await service.lastKnownItems(for: catalogSource("top"), limit: 5)
        #expect(expired?.count == 5)
        await service.invalidate()
        let afterInvalidate = await service.lastKnownItems(for: catalogSource("top"), limit: 5)
        #expect(afterInvalidate == nil, "with no snapshot store, invalidate leaves nothing to show")
    }

    @Test func theMostRecentFirstPageWinsWhateverItsLimit() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let (service, _) = try await makeService(transport: transport, now: { clock.now })
        _ = try await service.items(for: catalogSource("top"), limit: 5, cacheTTL: 3600)
        clock.advance(by: 10)
        _ = try await service.items(for: catalogSource("top"), limit: 10, cacheTTL: 3600)
        let known = await service.lastKnownItems(for: catalogSource("top"), limit: 20)
        #expect(known?.count == 20, "the full fetched page supplies any requested display prefix")
    }

    @Test func pagingDoesNotOverwriteTheSnapshotAndFailuresDoNotEither() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let snapshots = InMemoryWidgetSnapshotStore()
        let (service, _) = try await makeService(transport: transport, snapshots: snapshots)
        _ = try await service.items(for: catalogSource("top"), limit: 5)
        _ = try await service.items(for: catalogSource("top"), limit: 5, skip: 5)
        _ = try? await service.items(for: catalogSource("broken"), limit: 5)
        let relaunched = try await relaunch(transport: transport, snapshots: snapshots)
        let known = await relaunched.lastKnownItems(for: catalogSource("top"), limit: 5)
        #expect(known?.map(\.id) == ["t0", "t1", "t2", "t3", "t4"], "only the first page is the snapshot")
        let broken = await relaunched.lastKnownItems(for: catalogSource("broken"), limit: 5)
        #expect(broken == nil, "a failed load saves nothing")
    }

    @Test func aSourceNeverLoadedHasNothingKnownAndNeverRequests() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (service, _) = try await makeService(transport: transport, snapshots: InMemoryWidgetSnapshotStore())
        let known = await service.lastKnownItems(for: catalogSource("top"))
        #expect(known == nil)
        #expect(transport.callCount == 0)
    }

    @Test func forgetEverythingRemovesTheLastKnownItemsEverywhere() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let snapshots = InMemoryWidgetSnapshotStore()
        let (service, _) = try await makeService(transport: transport, snapshots: snapshots)
        _ = try await service.items(for: catalogSource("top"), limit: 5)
        await service.forgetEverything()
        let known = await service.lastKnownItems(for: catalogSource("top"), limit: 5)
        #expect(known == nil, "the memory cache is forgotten")
        let relaunched = try await relaunch(transport: transport, snapshots: snapshots)
        let stored = await relaunched.lastKnownItems(for: catalogSource("top"), limit: 5)
        #expect(stored == nil, "and so is the snapshot store")
    }

    // MARK: Addons and sources that cannot load

    @Test func anUnknownCatalogIsAddonMissingWithItsHost() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (service, _) = try await makeService(transport: transport)
        let missing = catalogSource("nowhere")
        await #expect(throws: WidgetSourceError.addonMissing(host: "stub0.example.com")) { try await service.items(for: missing) }
        let issue = await service.issue(with: missing)
        #expect(issue == .addonMissing(host: "stub0.example.com"))
        #expect(transport.callCount == 0)
    }

    @Test func aDisabledAddonCountsAsMissing() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (service, registry) = try await makeService(transport: transport)
        let addons = await registry.addons
        try await registry.setEnabled(false, id: try #require(addons.first).id)
        let issue = await service.issue(with: catalogSource("top"))
        #expect(issue == .addonMissing(host: "stub0.example.com"))
        await #expect(throws: WidgetSourceError.addonMissing(host: "stub0.example.com")) { try await service.items(for: catalogSource("top"), cacheTTL: 0) }
        #expect(transport.callCount == 0)
    }

    @Test func aTraktListWithoutAClientIDRequiresConfigurationBeforeNetwork() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (service, _) = try await makeService(transport: transport)
        #expect(await service.issue(with: traktList) == .needsTraktClientID)
        await #expect(throws: WidgetSourceError.needsTraktClientID) {
            try await service.items(for: traktList, cacheTTL: 0)
        }
        #expect(transport.callCount == 0)
    }

    @Test func aBlankTraktClientIDCountsAsNoneAtAll() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let settings = InMemorySettingsStore(PlaybackSettings(traktClientID: "   "))
        #expect(await TraktClient.clientID(in: settings) == "")
        _ = transport
    }

    @Test func aPrivateTraktListNeedsTheSignInBeforeAnyRequest() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (service, _) = try await makeService(transport: transport)
        let source = WidgetSource.traktList(TraktListReference(username: "me", listSlug: "secret", listName: "Secret", isPrivate: true))
        #expect(await service.issue(with: source) == .needsTraktSignIn)
        #expect(transport.callCount == 0)
    }

    @Test func aTraktListReadsWithTheTrimmedClientID() async throws {
        let transport = StubTransport { request, _ in
            if request.url?.host == "api.trakt.tv" {
                return StubTransport.response(Data(#"[{"type":"movie","movie":{"title":"Film","ids":{"imdb":"tt42"}}}]"#.utf8), for: request)
            }
            return catalogResponse(for: request)
        }
        let (service, _) = try await makeService(transport: transport, settings: PlaybackSettings(traktClientID: "  key-1  "))
        let items = try await service.items(for: traktList, limit: 20, cacheTTL: 0)
        #expect(items.map(\.id) == ["tt42"])
        let request = try #require(transport.requests.last)
        #expect(request.value(forHTTPHeaderField: "trakt-api-key") == "key-1")
        #expect(await service.issue(with: traktList) == nil)
    }

    @Test func anUnsupportedSourceFailsWithItsKindAndNeverRequests() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (service, _) = try await makeService(transport: transport)
        let unsupported = WidgetSource.unsupported(kind: "anilistCatalog")
        await #expect(throws: WidgetSourceError.unsupported(kind: "anilistCatalog")) { try await service.items(for: unsupported) }
        let issue = await service.issue(with: unsupported)
        #expect(issue == .unsupported(kind: "anilistCatalog"))
        #expect(transport.callCount == 0)
    }

    @Test func errorMessagesAreSentencesAndNameTheHostWhenKnown() {
        #expect(WidgetSourceError.addonMissing(host: "example.com").message.contains("example.com"))
        #expect(!WidgetSourceError.addonMissing(host: nil).message.contains("example"))
        #expect(WidgetSourceError.needsTraktClientID.message.contains("Trakt"))
        #expect(WidgetSourceError.addon(.http(status: 500)).message.contains("server error (500)"))
        #expect(WidgetSourceError.unsupported(kind: "x").message.hasSuffix("."))
    }

    // MARK: TMDb discover lists

    private let discover = WidgetSource.tmdbDiscover(TMDbDiscoverQuery(providers: [.init(id: 8, name: "Netflix")]))
    private let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ0ZXN0In0.signature"

    /// TMDb's answers for a two-title discover list (ids 880001 and 880002) and their IMDb ids; other hosts get the catalog answers.
    private func tmdbOrCatalog(for request: URLRequest) -> HTTPResult {
        guard request.url?.host == "api.themoviedb.org" else { return catalogResponse(for: request) }
        let path = request.url?.path ?? ""
        if path.hasPrefix("/3/discover/") {
            let body = #"""
                {"page":1,"total_pages":1,"results":[{"id":880001,"title":"First","overview":"A film.","poster_path":"/a.jpg",
                "backdrop_path":null,
                "release_date":"2024-01-01","genre_ids":[16],"vote_average":7.1,"vote_count":300,"original_language":"en"},
                {"id":880002,"title":"Second","overview":"","poster_path":null,"backdrop_path":null,"release_date":"","genre_ids":[],
                "vote_average":6,"vote_count":10,"original_language":"en"}]}
                """#
            return StubTransport.response(Data(body.utf8), for: request)
        }
        let imdb = path.contains("880001") ? "tt8800001" : "tt8800002"
        return StubTransport.response(Data(#"{"imdb_id":"\#(imdb)"}"#.utf8), for: request)
    }

    @Test func aDiscoverListWithoutATokenNeedsOneAndSendsNothing() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (registry, client) = try await makeStubbedRegistry(manifests: [catalog], transport: transport)
        let service = WidgetContentService(registry: registry, client: client,
            settings: InMemorySettingsStore(PlaybackSettings(tmdbReadToken: "  ")))
        #expect(await service.issue(with: discover) == .needsTMDbToken)
        await #expect(throws: WidgetSourceError.needsTMDbToken) { try await service.items(for: discover, cacheTTL: 0) }
        #expect(transport.callCount == 0)
    }

    @Test func aDiscoverListLoadsWithTheSavedTokenAndTheRegion() async throws {
        let transport = StubTransport { request, _ in tmdbOrCatalog(for: request) }
        let (registry, client) = try await makeStubbedRegistry(manifests: [catalog], transport: transport)
        let settings = InMemorySettingsStore(PlaybackSettings(tmdbReadToken: " \(jwt) "))
        let service = WidgetContentService(registry: registry, client: client, settings: settings, region: { "IE" })
        #expect(await service.issue(with: discover) == nil)
        let items = try await service.items(for: discover, limit: 5, cacheTTL: 0)
        #expect(items.map(\.id) == ["tt8800001", "tt8800002"] && items.map(\.type) == ["movie", "movie"])
        let list = try #require(transport.requests.first { $0.url?.path == "/3/discover/movie" })
        #expect(list.value(forHTTPHeaderField: "Authorization") == "Bearer \(jwt)")
        #expect(list.url?.absoluteString.contains("watch_region=IE") == true, "the device region the service was given")
    }

    @Test func aDiscoverListTurnsATMDbRefusalIntoAnAddonError() async throws {
        let transport = StubTransport { request, _ in
            if request.url?.host == "api.themoviedb.org" { return StubTransport.response(Data(), status: 401, for: request) }
                return catalogResponse(for: request)
        }
        let (registry, client) = try await makeStubbedRegistry(manifests: [catalog], transport: transport)
        let service = WidgetContentService(registry: registry, client: client,
            settings: InMemorySettingsStore(PlaybackSettings(tmdbReadToken: jwt)))
        await #expect(throws: WidgetSourceError.addon(.http(status: 401))) { try await service.items(for: discover, cacheTTL: 0) }
    }

    @Test func theNeedsTMDbTokenMessageNamesTheSetting() {
        #expect(WidgetSourceError.needsTMDbToken.message == "Add a TMDB Read Access Token in Settings to show this row.")
    }

    // MARK: Several sources

    @Test func severalSourcesInterleaveRoundRobinAndDropDuplicates() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (service, _) = try await makeService(transport: transport)
        // `top` gives t0...t4 at this limit, `other` gives t1, b1, t2: t1 and t2 appear in both.
        let merged = try await service.items(for: [catalogSource("top"), catalogSource("other")], limit: 5, cacheTTL: 0)
        #expect(merged.map(\.id) == ["t0", "t1", "b1", "t2", "t3"])
    }

    @Test func aFailingSourceIsSkippedUntilEverySourceFails() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (service, _) = try await makeService(transport: transport)
        let merged = try await service.items(for: [catalogSource("broken"), catalogSource("other")], limit: 10, cacheTTL: 0)
        #expect(merged.map(\.id) == ["t1", "b1", "t2"])
        await #expect(throws: WidgetSourceError.addon(.http(status: 500))) { try await service.items(for: [catalogSource("broken")], limit: 10, cacheTTL: 0) }
    }

    @Test func whenEverySourceFailsTheFirstSourcesErrorIsThrown() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (service, _) = try await makeService(transport: transport)
        let missing = catalogSource("nowhere")
        let broken = catalogSource("broken")
        await #expect(throws: WidgetSourceError.addonMissing(host: "stub0.example.com")) { try await service.items(for: [missing, broken], cacheTTL: 0) }
        await #expect(throws: WidgetSourceError.addon(.http(status: 500))) { try await service.items(for: [broken, missing], cacheTTL: 0) }
    }

    @Test func noSourcesGiveNoItemsAndNoRequests() async throws {
        let transport = StubTransport { request, _ in catalogResponse(for: request) }
        let (service, _) = try await makeService(transport: transport)
        let none: [WidgetSource] = []
        #expect(try await service.items(for: none).isEmpty)
        #expect(transport.callCount == 0)
    }
}
