// swiftlint:disable line_length
import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StremioKit
import StremioKitTestSupport
@testable import Features

private func lists(_ names: [String], offset: Int = 0) -> Data {
    let body = names.enumerated().map { index, name in
        #"{"like_count":3,"list":{"name":"\#(name)","description":"d","item_count":10,"likes":3,"ids":{"trakt":\#(offset + index + 1),"slug":"l\#(offset + index + 1)"},"user":{"ids":{"slug":"owner"}}}}"#
    }
    return Data("[\(body.joined(separator: ","))]".utf8)
}

private func page(of request: URLRequest) -> Int {
    let items = URLComponents(url: request.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?.queryItems ?? []
    return items.first { $0.name == "page" }.flatMap { $0.value }.flatMap(Int.init) ?? 1
}

/// The Trakt list browser of the New Widget screen, the widget styles and titles it relies on, and Trakt paging in a grid.
@MainActor
@Suite struct TraktBrowserViewModelTests {
    private func services(_ transport: StubTransport, clientID: String? = "test-client") async throws -> AppServices {
        let (registry, client) = try await makeStubbedRegistry(manifests: [], transport: transport)
        return AppServices(registry: registry, client: client, settings: InMemorySettingsStore(PlaybackSettings(traktClientID: clientID)),
                           widgets: InMemoryWidgetStore(nil))
    }

    @Test func popularListsLoadFirstAndPageOnScrollingToTheEnd() async throws {
        let transport = StubTransport { request, _ in
            let pageNumber = page(of: request)
            let names = pageNumber == 1 ? ["A", "B"] : ["B", "C"]
            return StubTransport.response(lists(names, offset: pageNumber == 1 ? 0 : 1), for: request, headers: ["x-pagination-page-count": "2"])
        }
        let browser = TraktBrowserViewModel(services: try await services(transport))
        await browser.load()
        #expect(browser.phase == .loaded && browser.lists.map(\.name) == ["A", "B"] && browser.canLoadMore)
        #expect(transport.requests.first?.url?.path == "/lists/popular")
        await browser.loadMore()
        #expect(browser.lists.map(\.name) == ["A", "B", "C"], "a list already shown is not shown twice")
        #expect(!browser.canLoadMore)
        await browser.loadMore()
        #expect(transport.callCount == 2)
    }

    @Test func trendingAndSearchAskTheirOwnEndpointsAndSearchWinsOverTheScope() async throws {
        let transport = StubTransport { request, _ in StubTransport.response(lists(["X"]), for: request) }
        let browser = TraktBrowserViewModel(services: try await services(transport))
        browser.scope = .trending
        await browser.load()
        #expect(transport.requests.last?.url?.path == "/lists/trending")
        browser.query = "  cult classics "
        await browser.load()
        let search = try #require(transport.requests.last?.url)
        #expect(search.path == "/search/list" && search.absoluteString.contains("query=cult%20classics"))
    }

    @Test func aSearchWithNoResultsSaysSoByName() async throws {
        let transport = StubTransport(data: Data("[]".utf8))
        let browser = TraktBrowserViewModel(services: try await services(transport))
        browser.query = "zzz"
        await browser.load()
        #expect(browser.isEmpty && browser.emptyMessage.contains("zzz"))
    }

    @Test func signedInListsAndUserSearchNeedTheTraktSignInAndAskNothingWithout() async throws {
        let transport = StubTransport(data: Data("[]".utf8))
        let browser = TraktBrowserViewModel(services: try await services(transport))
        browser.scope = .mine
        await browser.load()
        guard case .needsSignIn = browser.phase else {
            Issue.record("My Lists without a sign-in should ask for one, got \(browser.phase)")
            return
        }
        browser.scope = .liked
        await browser.load()
        guard case .needsSignIn = browser.phase else {
            Issue.record("Liked Lists without a sign-in should ask for one")
            return
        }
        browser.tab = .users
        browser.query = "sean"
        await browser.load()
        guard case .needsSignIn = browser.phase else {
            Issue.record("Searching users without a sign-in should ask for one")
            return
        }
        #expect(transport.callCount == 0)
    }

    @Test func theUsersTabWaitsForAQueryBeforeAskingAnything() async throws {
        let transport = StubTransport(data: Data("[]".utf8))
        let browser = TraktBrowserViewModel(services: try await services(transport))
        browser.tab = .users
        await browser.load()
        #expect(browser.phase == .idle && transport.callCount == 0 && browser.showsUsers)
    }

    @Test func aPickedUsersPublicListsLoadAndLeavingGoesBack() async throws {
        let transport = StubTransport { request, _ in StubTransport.response(lists(["Mine"]), for: request) }
        let browser = TraktBrowserViewModel(services: try await services(transport))
        browser.tab = .users
        browser.browse(user: TraktUserSummary(username: "sean"))
        #expect(!browser.showsUsers && browser.request.user == "sean")
        await browser.load()
        #expect(transport.requests.last?.url?.path == "/users/sean/lists")
        #expect(browser.lists.map(\.name) == ["Mine"] && !browser.canLoadMore)
        browser.leaveUser()
        #expect(browser.showsUsers)
    }

    @Test func aFailedLoadIsAMessageNotAnEmptyList() async throws {
        let transport = StubTransport(data: Data(), status: 500)
        let browser = TraktBrowserViewModel(services: try await services(transport))
        await browser.load()
        guard case .failed(let message) = browser.phase else {
            Issue.record("a server error should fail the load, got \(browser.phase)")
            return
        }
        #expect(message.hasPrefix("Trakt couldn't load this") && !browser.isEmpty)
    }

    @Test func theTraktBrowserRequiresTheConfiguredClientID() async throws {
        let transport = StubTransport { request, _ in StubTransport.response(lists(["A"]), for: request) }
        let plain = TraktBrowserViewModel(services: try await services(transport, clientID: nil))
        await plain.load()
        #expect(transport.callCount == 0)
        #expect(plain.phase == .failed(WidgetSourceError.needsTraktClientID.message))
        let own = TraktBrowserViewModel(services: try await services(transport, clientID: "mine"))
        await own.load()
        #expect(transport.requests.last?.value(forHTTPHeaderField: "trakt-api-key") == "mine")
    }

    // MARK: Styles and titles

    @Test func switchingStyleKeepsTheSourceAndFollowsTheDefaultsUntilTheUserChangesThem() {
        let source = WidgetSource.traktFeed(.moviesTrending)
        let row = HomeWidget(id: "w", title: "T", content: .row(RowConfiguration(source: source)))
        let spotlight = WidgetStyle.restyled(row, as: .spotlight)
        guard case .hero(let hero) = spotlight.content else {
            Issue.record("expected a spotlight")
            return
        }
        #expect(hero.source == source && hero.limit == 8 && spotlight.hideTitle)
        let back = WidgetStyle.restyled(spotlight, as: .banner)
        guard case .banner(let banner) = back.content else {
            Issue.record("expected a banner")
            return
        }
        #expect(banner.limit == 20 && !back.hideTitle)
        let custom = HomeWidget(id: "c", title: "T", content: .row(RowConfiguration(source: source, limit: 35)))
        guard case .banner(let kept) = WidgetStyle.restyled(custom, as: .banner).content else {
            Issue.record("expected a banner")
            return
        }
        #expect(kept.limit == 35, "a count the user chose survives a change of style")
        let continueRow = HomeWidget(id: "k", title: "Continue", content: .continueWatching)
        #expect(WidgetStyle.restyled(continueRow, as: .row) == continueRow && WidgetStyle(continueRow.content) == nil)
    }

    @Test func aTraktListIsTitledByItsNameAndDescribedWithItsSort() async throws {
        let (registry, client) = try await makeStubbedRegistry(manifests: [], transport: StubTransport(data: Data()))
        let model = WidgetsManagerViewModel(services: AppServices(registry: registry, client: client, widgets: InMemoryWidgetStore(nil)))
        let list = TraktListReference(username: "justin", listSlug: "top", listName: "Top Rated", sort: .releaseDate)
        #expect(model.autoTitle(for: .traktList(list)) == "Top Rated")
        #expect(model.describe(.traktList(list)) == "Trakt list · Top Rated by justin · Release Date")
        #expect(model.describe(.traktList(TraktListReference(username: "j", listSlug: "t", listName: "T"))) == "Trakt list · T by j")
        #expect(model.autoTitle(for: .traktFeed(.showsPopular)) == "Popular Shows")
        #expect(model.autoTitle(for: .unsupported(kind: "x")) == "")
    }

    // MARK: Paging

    @Test func aTraktGridAsksForTheNextPageEvenWhenTraktDroppedEntriesFromThisOne() async throws {
        let transport = StubTransport { request, _ in
            let entries = #"[{"type":"movie","movie":{"title":"A","ids":{"imdb":"tt\#(page(of: request))"}}},{"type":"movie","movie":{"title":"No id","ids":{}}}]"#
            return StubTransport.response(Data(entries.utf8), for: request)
        }
        let services = try await services(transport)
        let reference = TraktListReference(username: "u", listSlug: "s", listName: "S")
        let grid = CatalogListViewModel(request: CatalogListRequest(title: "S", sources: [.traktList(reference)]), services: services)
        await grid.load()
        await grid.loadMore()
        await grid.loadMore()
        let pages = transport.requests.filter { $0.url?.host == "api.trakt.tv" }.map { page(of: $0) }
        #expect(pages == [1, 2, 3], "short pages must not make the grid ask for the same page again")
        #expect(grid.items.map(\.id) == ["tt1", "tt2", "tt3"])
    }
}
// swiftlint:enable line_length
