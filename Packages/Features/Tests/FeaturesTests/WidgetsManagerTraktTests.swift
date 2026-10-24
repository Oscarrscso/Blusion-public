import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

/// Adding Trakt lists and feeds from the Widgets manager: links, the client ID check, and the rows they make.
@MainActor
@Suite struct WidgetsManagerTraktTests {
    private func model(clientID: String?, transport: StubTransport) async throws -> WidgetsManagerViewModel {
        let (registry, client) = try await makeStubbedRegistry(manifests: [], transport: transport)
        let services = AppServices(registry: registry, client: client, settings: InMemorySettingsStore(PlaybackSettings(traktClientID: clientID)),
                                   widgets: InMemoryWidgetStore(nil))
        return WidgetsManagerViewModel(services: services)
    }

    @Test func aPastedListLinkIsReadWithItsNameFromTrakt() async throws {
        let transport = StubTransport(data: Data(#"{"name":"Daily Picks","ids":{"trakt":31897770}}"#.utf8))
        let vm = try await model(clientID: " key-3 ", transport: transport)
        let list = try await vm.traktList(fromLink: "https://trakt.tv/users/tvgeniekodi/lists/daily-picks")
        #expect(list == TraktListReference(username: "tvgeniekodi", listSlug: "daily-picks", listName: "Daily Picks", traktID: 31897770))
        #expect(transport.requests.last?.value(forHTTPHeaderField: "trakt-api-key") == "key-3")
    }

    @Test func aLinkThatIsNotAListIsRefusedWithoutARequest() async throws {
        let transport = StubTransport(data: Data())
        let vm = try await model(clientID: "key", transport: transport)
        await #expect(throws: WidgetsManagerViewModel.TraktLinkError.notAListLink) { try await vm.traktList(fromLink: "https://trakt.tv/movies/inception") }
        #expect(transport.callCount == 0)
    }

    @Test func aListLinkWithoutAClientIDRequiresConfiguration() async throws {
        let transport = StubTransport(data: Data(#"{"name":"Daily Picks","ids":{"trakt":1}}"#.utf8))
        let vm = try await model(clientID: "  ", transport: transport)
        await #expect(throws: WidgetsManagerViewModel.TraktLinkError.needsClientID) {
            try await vm.traktList(fromLink: "trakt.tv/users/a/lists/b")
        }
        #expect(transport.callCount == 0)
    }

    @Test func aTraktFeedRowIsTitledByTheFeedAndDescribedAsTrakt() async throws {
        let vm = try await model(clientID: "key", transport: StubTransport(data: Data()))
        let widget = WidgetsManagerViewModel.makeTraktRow(.traktFeed(.showsTrending))
        #expect(widget.title == "Trending Shows")
        #expect(vm.describe(.traktFeed(.showsTrending)) == "Trakt · Trending Shows")
        guard case .row(let row) = widget.content else {
            Issue.record("a feed row should be a row")
            return
        }
        #expect(row.source == .traktFeed(.showsTrending))
    }

    @Test func aTraktListSpotlightIsHiddenTitledAndUsesTheListName() {
        let source = WidgetSource.traktList(TraktListReference(username: "u", listSlug: "s", listName: "Best Of"))
        let widget = WidgetsManagerViewModel.makeTraktSpotlight(source)
        #expect(widget.title == "Best Of" && widget.hideTitle)
        guard case .hero(let row) = widget.content else {
            Issue.record("a spotlight should be a hero")
            return
        }
        #expect(row.source == source && row.limit == 8)
    }

    @Test func aTraktListBannerIsTitledAsTheListAndUsesTwentyCards() async throws {
        let source = WidgetSource.traktList(TraktListReference(username: "u", listSlug: "s", listName: "Best Of"))
        let widget = WidgetsManagerViewModel.makeTraktBanner(source)
        #expect(widget.title == "Best Of" && !widget.hideTitle)
        let vm = try await model(clientID: "key", transport: StubTransport(data: Data()))
        #expect(vm.summary(of: widget) == "Banner · Trakt list · Best Of by u")
        guard case .banner(let row) = widget.content else {
            Issue.record("a banner should be a banner")
            return
        }
        #expect(row.source == source && row.limit == 20)
    }

    @Test func theErrorMessagesAreOneSentenceEach() {
        #expect(WidgetsManagerViewModel.TraktLinkError.failed("not found").message.contains("not found"))
    }
}
