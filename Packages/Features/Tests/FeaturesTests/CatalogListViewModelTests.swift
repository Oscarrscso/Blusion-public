import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StremioKit
import StremioKitTestSupport
@testable import Features

/// Two catalogs of one addon: `all` (movies, paged by `skip`) and `other` (a short list that overlaps with `all` at `t0`).
private let movieAddon = Manifest(
    id: "test.movies", name: "Movies", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
    catalogs: [CatalogDescriptor(type: "movie", id: "all", name: "All", extra: [ExtraDescriptor(name: "skip")]),
               CatalogDescriptor(type: "movie", id: "other", name: "Other")])

/// The `skip` a request asks for; 0 when it asks for none.
private func skip(of request: URLRequest) -> Int {
    let text = request.url?.absoluteString ?? ""
    guard let range = text.range(of: "skip=") else { return 0 }
    return Int(text[range.upperBound...].prefix(while: { $0.isNumber })) ?? 0
}

private func metas(_ ids: [String], for request: URLRequest) -> HTTPResult {
    let items = ids.map { "{\"id\":\"\($0)\",\"type\":\"movie\"}" }.joined(separator: ",")
    return StubTransport.response(Data("{\"metas\":[\(items)]}".utf8), for: request)
}

/// `all` is a catalog of `total` movies (`t0`, `t1`, ...), 50 to a page. With `failingSkip`, that page answers 500. With `repeatsFirst`,
/// every later page starts again with `t0`, as addons with overlapping pages do. `other` always answers `o0`, `o1` and `t0`.
private func catalogs(total: Int, failingSkip: Int? = nil, repeatsFirst: Bool = false) -> StubTransport {
    StubTransport { request, _ in
        if request.url?.path.contains("/catalog/movie/other") == true { return metas(["o0", "o1", "t0"], for: request) }
        let offset = skip(of: request)
        if offset == failingSkip { return StubTransport.response(Data(), status: 500, for: request) }
        var ids = offset < total ? (offset..<min(offset + 50, total)).map { "t\($0)" } : []
        if repeatsFirst, offset > 0, !ids.isEmpty { ids[0] = "t0" }
        return metas(ids, for: request)
    }
}

private func source(_ catalogID: String) -> WidgetSource {
    .addonCatalog(AddonCatalogReference(manifestID: "test.movies", catalogType: "movie", catalogID: catalogID))
}

@MainActor
@Suite struct CatalogListViewModelTests {
    private func services(_ transport: StubTransport) async throws -> AppServices {
        let (registry, client) = try await makeStubbedRegistry(manifests: [movieAddon], transport: transport)
        return AppServices(registry: registry, client: client)
    }

    private func grid(_ title: String, _ sources: [WidgetSource], _ services: AppServices) -> CatalogListViewModel {
        CatalogListViewModel(request: CatalogListRequest(title: title, sources: sources), services: services)
    }

    @Test func aGridStartsEmptyAndLoadingThenShowsItsFirstPage() async throws {
        let transport = catalogs(total: 120)
        let model = grid("All", [source("all")], try await services(transport))
        #expect(model.state == .loading && model.items.isEmpty && !model.isEmpty)
        #expect(model.request.title == "All")
        await model.load()
        #expect(model.state == .loaded && model.items.count == 50 && model.canLoadMore)
        #expect(transport.requests.last?.url?.absoluteString.contains("skip=") == false, "the first page asks for no skip")
    }

    @Test func pagesAskForSkipUntilAnEmptyPageEndsThem() async throws {
        let transport = catalogs(total: 120)
        let model = grid("All", [source("all")], try await services(transport))
        await model.load()

        await model.loadMore()
        #expect(model.items.count == 100)
        #expect(transport.requests.last?.url?.absoluteString.contains("skip=50") == true)

        await model.loadMore()
        #expect(model.items.count == 120 && model.canLoadMore)
        #expect(transport.requests.last?.url?.absoluteString.contains("skip=100") == true)

        await model.loadMore()
        #expect(model.items.count == 120 && !model.canLoadMore, "the empty page at skip 120 ends paging")
        #expect(transport.requests.last?.url?.absoluteString.contains("skip=120") == true)
        let asked = transport.callCount
        await model.loadMore()
        #expect(transport.callCount == asked, "after the end nothing is asked")
        #expect(model.state == .loaded && !model.isEmpty)
    }

    @Test func anEmptyCatalogIsLoadedAndEmpty() async throws {
        let transport = catalogs(total: 0)
        let model = grid("Nothing", [source("all")], try await services(transport))
        await model.load()
        #expect(model.state == .loaded && model.isEmpty && !model.canLoadMore)
        #expect(transport.callCount == 1)
    }

    @Test func noSourcesIsLoadedAndEmptyWithoutAnyRequest() async throws {
        let transport = catalogs(total: 120)
        let model = grid("Nothing", [], try await services(transport))
        await model.load()
        #expect(model.state == .loaded && model.isEmpty)
        #expect(transport.callCount == 0)
    }

    @Test func severalSourcesLoadOnceAsOneMergedList() async throws {
        let transport = catalogs(total: 120)
        let model = grid("Mixed", [source("all"), source("other")], try await services(transport))
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.items.count == 52, "50 from all, and o0 and o1 from other; the t0 that other repeats is dropped")
        #expect(model.items.prefix(3).map(\.id) == ["t0", "o0", "t1"], "the sources are interleaved")
        #expect(!model.canLoadMore, "several sources do not page")
        #expect(transport.callCount == 2)
        await model.loadMore()
        #expect(transport.callCount == 2 && model.items.count == 52)
    }

    @Test func aFailedFirstPageIsAFailureNotAnEmptyGrid() async throws {
        let model = grid("All", [source("all")], try await services(catalogs(total: 120, failingSkip: 0)))
        await model.load()
        #expect(model.state == .failed(.addon(.http(status: 500))))
        #expect(model.items.isEmpty && !model.isEmpty, "a failure is not the same as having nothing")
        #expect(!model.canLoadMore)
    }

    @Test func aFailedNextPageKeepsWhatIsThereAndCanBeTriedAgain() async throws {
        let transport = catalogs(total: 120, failingSkip: 50)
        let model = grid("All", [source("all")], try await services(transport))
        await model.load()
        await model.loadMore()
        #expect(model.state == .loaded, "the failed page goes back to loaded")
        #expect(model.items.count == 50 && model.canLoadMore, "what is there stays, and scrolling again may retry")
        await model.loadMore()
        #expect(transport.callCount == 3, "the retry asks for the same page again")
    }

    @Test func aPageThatRepeatsItemsAddsOnlyTheNewOnes() async throws {
        let model = grid("All", [source("all")], try await services(catalogs(total: 120, repeatsFirst: true)))
        await model.load()
        await model.loadMore()
        #expect(model.items.count == 99, "the repeated t0 is dropped, the other 49 are new")
        let ids = model.items.map(\.identity)
        #expect(Set(ids).count == ids.count, "no duplicates across pages")
    }

    @Test func aLoadThatStartsAgainReplacesWhatWasThere() async throws {
        let model = grid("All", [source("all")], try await services(catalogs(total: 120)))
        await model.load()
        await model.loadMore()
        #expect(model.items.count == 100)
        await model.load()
        #expect(model.items.count == 50 && model.canLoadMore, "a reload starts again from the first page")
    }

    @Test func pullToRefreshAsksForANewPageInsteadOfReusingTheCache() async throws {
        let transport = catalogs(total: 120)
        let model = grid("All", [source("all")], try await services(transport))
        await model.load()
        await model.load()
        #expect(transport.callCount == 1)
        await model.refresh()
        #expect(transport.callCount == 2)
        #expect(model.items.count == 50)
    }
}
