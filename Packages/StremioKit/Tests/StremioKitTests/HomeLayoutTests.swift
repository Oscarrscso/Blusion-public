import Foundation
import Testing
@testable import StremioKit

@Suite struct HomeLayoutTests {
    private func config(_ id: String) -> RowConfiguration {
        RowConfiguration(source: .addonCatalog(AddonCatalogReference(manifestID: "m", catalogType: "movie", catalogID: id)), limit: 12)
    }

    private func row(_ id: String) -> HomeWidget { HomeWidget(id: id, title: id, content: .row(config(id))) }
    private func banner(_ id: String) -> HomeWidget { HomeWidget(id: id, title: id, content: .banner(config(id))) }
    private func showcase(_ id: String) -> HomeWidget { HomeWidget(id: id, title: id, hideTitle: true, content: .hero(config(id))) }
    private func continueWatching(_ id: String = "cw") -> HomeWidget { HomeWidget(id: id, title: "Continue", content: .continueWatching) }

    @Test func aLayoutThatKeepsTheRulesIsUnchanged() {
        let layout = [showcase("s"), row("a"), continueWatching(), row("b"), banner("c")]
        #expect(HomeLayout.normalised(layout) == layout, "Continue Watching keeps its own place")
    }

    @Test func everyWidgetIsKept() {
        let layout = [row("a"), continueWatching(), showcase("s1"), row("b"), showcase("s2"), banner("c")]
        let ids = HomeLayout.normalised(layout).map(\.id)
        #expect(ids.count == layout.count)
        #expect(Set(ids) == Set(layout.map(\.id)))
    }

    @Test func theShowcaseComesFirstAndTheRestKeepTheirOrder() {
        let layout = [row("a"), continueWatching(), showcase("s"), row("b")]
        #expect(HomeLayout.normalised(layout).map(\.id) == ["s", "a", "cw", "b"])
    }

    @Test func anotherShowcaseStaysWhereItWasAsABanner() {
        let layout = [showcase("s1"), continueWatching(), row("a"), showcase("s2"), row("b")]
        let normal = HomeLayout.normalised(layout)
        #expect(normal.map(\.id) == ["s1", "cw", "a", "s2", "b"])
        #expect(normal[3] == HomeWidget(id: "s2", title: "s2", hideTitle: true, content: .banner(config("s2"))),
                "the source, the title and the settings stay")
        #expect(normal.filter(HomeLayout.isShowcase).map(\.id) == ["s1"])
    }

    @Test func continueWatchingGoesBackRightAfterTheShowcase() {
        let layout = [showcase("s"), row("a"), row("b"), banner("c")]
        let normal = HomeLayout.normalised(layout)
        #expect(normal.map(\.id) == ["s", HomeLayout.continueWatchingID, "a", "b", "c"])
        #expect(normal[1].content == .continueWatching)
        #expect(normal[1].title == "Continue")
    }

    @Test func withoutAShowcaseContinueWatchingGoesFirst() {
        #expect(HomeLayout.normalised([row("a"), row("b")]).map(\.id) == [HomeLayout.continueWatchingID, "a", "b"])
        #expect(HomeLayout.normalised([]).map(\.id) == [HomeLayout.continueWatchingID])
    }

    @Test func continueWatchingTakesANewIDWhenItsOwnIsTaken() {
        let taken = HomeWidget(id: HomeLayout.continueWatchingID, title: "Odd", content: .row(config("x")))
        let normal = HomeLayout.normalised([showcase("s"), taken])
        #expect(normal.count == 3)
        #expect(normal[1].content == .continueWatching)
        #expect(normal[1].id != HomeLayout.continueWatchingID)
        #expect(normal[2] == taken)
    }

    @Test func theRepairIsIdempotent() {
        let layouts: [[HomeWidget]] = [
            [],
            [row("a")],
            [showcase("s"), row("a"), row("b")],
            [row("a"), showcase("s1"), showcase("s2"), continueWatching()],
            [continueWatching(), showcase("s")],
        ]
        for layout in layouts {
            let once = HomeLayout.normalised(layout)
            #expect(HomeLayout.normalised(once) == once, "a second pass changes nothing: \(layout.map(\.id))")
        }
    }

    /// The phone's layout on 14 October: the spotlight, then 43 rows and banners, and no Continue Watching.
    @Test func aLayoutThatLostContinueWatchingGetsItBackAfterTheShowcaseOnly() {
        let rows = (0..<43).map { $0.isMultiple(of: 7) ? banner("r\($0)") : row("r\($0)") }
        let layout = [showcase("auto.hero")] + rows
        let normal = HomeLayout.normalised(layout)
        #expect(normal.first == layout.first)
        #expect(normal[1].content == .continueWatching)
        #expect(Array(normal.dropFirst(2)) == rows, "every other row keeps its order and its settings")
    }

    @Test func theAutomaticLayoutKeepsTheRules() {
        let base = URL(string: "https://example.com")!
        let addon = InstalledAddon(manifestURL: base.appendingPathComponent("manifest.json"), baseURL: base,
                                   manifest: Manifest(id: "m", name: "M", version: "1", resources: [ResourceDescriptor(name: "catalog")],
                                                      types: ["movie"], catalogs: [CatalogDescriptor(type: "movie", id: "top", name: "Top")]))
        let automatic = DefaultWidgets.make(for: [addon])
        #expect(HomeLayout.normalised(automatic) == automatic)
        #expect(automatic.contains { $0.id == HomeLayout.continueWatchingID && $0.content == .continueWatching })
    }
}
