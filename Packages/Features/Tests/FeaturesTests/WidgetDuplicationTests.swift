import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

/// A catalog addon with one movie list, for widgets to read from.
private let catalogAddon = Manifest(
    id: "test.cinemeta", name: "Cinemeta", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
    catalogs: [CatalogDescriptor(type: "movie", id: "top", name: "Popular")])

/// Duplicating a widget puts a copy straight after it, under a new id, and both Home and the widgets page read that saved order.
@MainActor
@Suite struct WidgetDuplicationTests {
    private let continueWatching = HomeWidget(id: "cw", title: "Continue", content: .continueWatching)

    private func row(_ id: String, title: String? = nil) -> HomeWidget {
        let reference = AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "movie", catalogID: "top")
        var configuration = RowConfiguration(source: .addonCatalog(reference))
        configuration.presentation.showsRank = true
        return HomeWidget(id: id, title: title ?? id, content: .row(configuration))
    }

    private func showcase() -> HomeWidget {
        let reference = AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "movie", catalogID: "top")
        return HomeWidget(id: "hero", title: "Spotlight", hideTitle: true, content: .hero(RowConfiguration(source: .addonCatalog(reference))))
    }

    private func services(widgets: [HomeWidget]) async throws -> AppServices {
        let (registry, client) = try await makeStubbedRegistry(manifests: [catalogAddon], transport: StubTransport(data: Data()))
        return AppServices(registry: registry, client: client, widgets: InMemoryWidgetStore(widgets))
    }

    @Test func aCopyGoesStraightAfterTheOriginalWithANewID() throws {
        let list = [row("a"), row("b", title: "Top films"), row("c"), continueWatching]
        let duplicated = try #require(WidgetsManagerViewModel.duplicating("b", in: list, newID: "b-copy"))
        #expect(duplicated.map(\.id) == ["a", "b", "b-copy", "c", "cw"])
        let copy = duplicated[2]
        #expect(copy.title == "Top films")
        #expect(copy.content == list[1].content, "the same source, filters and look")
        #expect(copy.hideTitle == list[1].hideTitle)
    }

    @Test func eachCopyGetsItsOwnID() throws {
        let list = [row("a")]
        let first = try #require(WidgetsManagerViewModel.duplicating("a", in: list))
        let second = try #require(WidgetsManagerViewModel.duplicating("a", in: first))
        #expect(Set(second.map(\.id)).count == 3)
    }

    @Test func continueWatchingAndTheShowcaseAreOneOfAKind() {
        let list = [showcase(), continueWatching, row("a")]
        #expect(!WidgetsManagerViewModel.isDuplicable(continueWatching))
        #expect(!WidgetsManagerViewModel.isDuplicable(showcase()))
        #expect(WidgetsManagerViewModel.isDuplicable(row("a")))
        #expect(WidgetsManagerViewModel.duplicating("cw", in: list) == nil)
        #expect(WidgetsManagerViewModel.duplicating("hero", in: list) == nil)
        #expect(WidgetsManagerViewModel.duplicating("nobody", in: list) == nil)
    }

    @Test func theWidgetsPageSavesTheCopyAfterTheOriginal() async throws {
        let services = try await services(widgets: [row("a"), row("b"), row("c"), continueWatching])
        let model = WidgetsManagerViewModel(services: services)
        await model.load()
        await model.duplicate(id: "b")
        let ids = model.widgets.map(\.id)
        #expect(ids.count == 5)
        #expect(Array(ids.prefix(2)) == ["a", "b"] && Array(ids.suffix(2)) == ["c", "cw"])
        #expect(model.widgets[2].content == model.widgets[1].content)
        let saved = await services.widgets.load()
        #expect(saved?.map(\.id) == ids, "the order is saved, so Home shows it too")
    }

    @Test func homeSavesTheCopyAfterTheOriginal() async throws {
        let services = try await services(widgets: [row("a"), row("b"), continueWatching])
        let home = HomeViewModel(services: services)
        await home.load()
        await home.duplicateWidget(sectionID: "a")
        let saved = try #require(await services.widgets.load())
        #expect(saved.count == 4)
        #expect(saved[0].id == "a" && saved[1].id != "a" && saved[1].content == saved[0].content)
        #expect(saved.map(\.id).suffix(2) == ["b", "cw"])
        #expect(home.sections.map(\.id) == saved.map(\.id), "Home shows the copy straight after the original")
        #expect(home.sections[1].state == home.sections[0].state, "and what the original shows")
        let manager = WidgetsManagerViewModel(services: services)
        await manager.load()
        #expect(manager.widgets.map(\.id) == saved.map(\.id), "the widgets page reads the same order")
    }

    @Test func theSecondFingerScrollStaysWithinThePage() {
        #expect(WidgetSlotLayout.scrolledOffset(100, by: 40, lowest: -50, highest: 900) == 140)
        #expect(WidgetSlotLayout.scrolledOffset(100, by: -400, lowest: -50, highest: 900) == -50, "not past the top")
        #expect(WidgetSlotLayout.scrolledOffset(880, by: 40, lowest: -50, highest: 900) == 900, "not past the bottom")
        #expect(WidgetSlotLayout.scrolledOffset(0, by: 30, lowest: -50, highest: -80) == -50, "a page shorter than the screen stays put")
    }
}
