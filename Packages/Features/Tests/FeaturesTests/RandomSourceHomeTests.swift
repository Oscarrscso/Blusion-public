import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

/// Two movie catalogs, `top` and `new`; each answers with the catalog's own name as its one movie's id.
private let catalogAddon = Manifest(id: "test.cinemeta", name: "Cinemeta", version: "1", resources: [ResourceDescriptor(name: "catalog")],
                                    types: ["movie"], catalogs: [CatalogDescriptor(type: "movie", id: "top", name: "Popular"),
                                                                 CatalogDescriptor(type: "movie", id: "new", name: "New")])

/// Home with a widget whose source is picked at random.
@MainActor
@Suite struct RandomSourceHomeTests {
    private func catalog(_ id: String) -> WidgetSource {
        .addonCatalog(AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "movie", catalogID: id))
    }

    private func services(_ widgets: [HomeWidget]) async throws -> AppServices {
        let transport = StubTransport { request, _ in
            let id = request.url?.path.contains("/new") == true ? "new" : "top"
            return StubTransport.response(Data(#"{"metas":[{"id":"tt-\#(id)","type":"movie","name":"\#(id)"}]}"#.utf8), for: request)
        }
        let (registry, client) = try await makeStubbedRegistry(manifests: [catalogAddon], transport: transport)
        let settings = InMemorySettingsStore()
        return AppServices(registry: registry, client: client, settings: settings,
                           widgets: InMemoryWidgetStore(widgets + [HomeWidget(id: "cw", title: "Continue", content: .continueWatching)]),
                           widgetContent: WidgetContentService(registry: registry, client: client, settings: settings))
    }

    private func randomRow(_ sources: [WidgetSource]) -> HomeWidget {
        HomeWidget(id: "r", title: "Mine", content: .row(RowConfiguration(source: catalog("top"),
                                                                           randomSource: RandomSource(sources: sources, schedule: .daily))))
    }

    @Test func homeShowsThePickedSourceNamedAfterIt() async throws {
        let services = try await services([randomRow([catalog("new")])])
        let model = HomeViewModel(services: services)
        await model.load()
        let section = try #require(model.sections.first { $0.id == "r" })
        #expect(section.widget.title == "New Movies")
        #expect(section.state.value?.map(\.id) == ["tt-new"], "the items come from the picked source")
        let saved = try #require(await services.widgets.load()?.first { $0.id == "r" })
        #expect(saved == randomRow([catalog("new")]), "the saved widget keeps its own source, title and setting")
    }

    @Test func thePickStaysAcrossOpeningsUntilItsTime() async throws {
        let services = try await services([randomRow([])])
        let model = HomeViewModel(services: services)
        await model.load()
        let first = model.sections.first { $0.id == "r" }?.widget
        for _ in 0..<3 { await model.load() }
        #expect(model.sections.first { $0.id == "r" }?.widget == first)
    }

    @Test func betterPostersFromHomeKeepsTheRandomSourceSetting() async throws {
        let services = try await services([randomRow([catalog("new")])])
        let model = HomeViewModel(services: services)
        await model.load()
        await model.setBetterPosters(true, sectionID: "r")
        let saved = try #require(await services.widgets.load()?.first { $0.id == "r" })
        guard case .row(let row) = saved.content else { Issue.record("not a row"); return }
        #expect(row.presentation.usesBetterPosters)
        #expect(row.source == catalog("top") && saved.title == "Mine" && row.randomSource?.sources == [catalog("new")])
    }
}
