import Foundation
import StremioKit
import Testing
@testable import Features

@Suite struct LaunchRouteTests {
    @Test func tabsParseByName() {
        #expect(LaunchRoute.parse("library") == LaunchRoute(tab: .library))
        #expect(LaunchRoute.parse(" Discover ") == LaunchRoute(tab: .discover))
        #expect(LaunchRoute.parse("home") == .home)
        #expect(LaunchRoute.Tab.allCases == [.home, .discover, .library, .settings, .search, .widgets])
    }

    @Test func searchCarriesItsQuery() {
        #expect(LaunchRoute.parse("search") == LaunchRoute(tab: .search))
        #expect(LaunchRoute.parse("search:breaking bad") == LaunchRoute(tab: .search, searchQuery: "breaking bad"))
        #expect(LaunchRoute.parse("search:a:b") == LaunchRoute(tab: .search, searchQuery: "a:b"))
    }

    @Test func detailAndStreamsKeepColonsInTheID() {
        let detail = LaunchRoute.parse("detail:series:tt0903747:1:2")
        #expect(detail?.detail?.type == "series")
        #expect(detail?.detail?.id == "tt0903747:1:2")
        #expect(detail?.tab == .home)
        let streams = LaunchRoute.parse("streams:movie:tt0468569")
        #expect(streams?.streams?.identity == "movie/tt0468569")
    }

    @Test func streamsRoutesCanNameTheTitleAndItsPoster() {
        let named = LaunchRoute.parse("streams:series:tt0903747:1:2?title=Breaking%20Bad%20%C2%B7%20Cat%27s&poster=https://example.com/p.jpg")
        #expect(named?.streams?.id == "tt0903747:1:2" && named?.streams?.type == "series")
        #expect(named?.streams?.title == "Breaking Bad · Cat's")
        #expect(named?.streams?.poster?.absoluteString == "https://example.com/p.jpg")
        let bare = LaunchRoute.parse("streams:movie:tt1?")
        #expect(bare?.streams?.id == "tt1" && bare?.streams?.title == "tt1" && bare?.streams?.poster == nil)
        #expect(LaunchRoute.parse("streams:movie:?title=x") == nil)
    }

    @Test func sheetsAndGallery() {
        #expect(LaunchRoute.parse("settings")?.sheet == .settings)
        #expect(LaunchRoute.parse("widgets")?.sheet == .widgets)
        #expect(LaunchRoute.parse("Addons") == LaunchRoute(sheet: .addons), "addons live inside Settings, not on a tab")
        #expect(LaunchRoute.parse("gallery")?.showsGallery == true)
        #expect(LaunchRoute.parse("gallery:cards")?.gallerySection == "cards")
        #expect(LaunchRoute.parse("player")?.showsPlayerDemo == true)
    }

    @Test func anythingElseIsNotARoute() {
        #expect(LaunchRoute.parse(nil) == nil)
        #expect(LaunchRoute.parse("") == nil)
        #expect(LaunchRoute.parse("nonsense") == nil)
        #expect(LaunchRoute.parse("detail:movie") == nil)
        #expect(LaunchRoute.parse("detail::tt1") == nil)
    }
}
