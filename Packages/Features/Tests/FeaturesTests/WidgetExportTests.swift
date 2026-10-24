import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

/// One movie catalog, `top`.
private let catalogAddon = Manifest(id: "test.cinemeta", name: "Cinemeta", version: "1", resources: [ResourceDescriptor(name: "catalog")],
                                    types: ["movie"], catalogs: [CatalogDescriptor(type: "movie", id: "top", name: "Popular")])

/// One widget exported on its own reads back through Import Widgets as that widget.
@MainActor
@Suite struct WidgetExportTests {
    private let row = HomeWidget(id: "mine", title: "My Films", content: .row(RowConfiguration(
        source: .addonCatalog(AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "movie", catalogID: "top")), limit: 30)))

    @Test func oneWidgetsExportImportsAsThatWidget() async throws {
        let text = try #require(WidgetsManagerViewModel.exportJSON(of: row))
        let (registry, client) = try await makeStubbedRegistry(manifests: [catalogAddon], transport: StubTransport(data: Data()))
        let addons = await registry.addons
        let imported = try FusionWidgetCodec.decode(Data(text.utf8), installed: addons)
        #expect(imported.widgets.count == 1)
        let widget = try #require(imported.widgets.first)
        #expect(widget.title == "My Films")
        guard case .row(let config) = widget.content, case .addonCatalog(let reference) = config.source else {
            Issue.record("not the same row"); return
        }
        #expect(reference.catalogID == "top" && reference.catalogType == "movie" && config.limit == 30)
        _ = client
    }

    @Test func homeExportsTheSavedWidgetNotTodaysPick() async throws {
        let transport = StubTransport { request, _ in StubTransport.response(Data(#"{"metas":[]}"#.utf8), for: request) }
        let (registry, client) = try await makeStubbedRegistry(manifests: [catalogAddon], transport: transport)
        var random = row
        if case .row(var config) = random.content {
            config.randomSource = RandomSource()
            random.content = .row(config)
        }
        let settings = InMemorySettingsStore()
        let services = AppServices(registry: registry, client: client, settings: settings, widgets: InMemoryWidgetStore([random]),
                                   widgetContent: WidgetContentService(registry: registry, client: client, settings: settings))
        let model = HomeViewModel(services: services)
        await model.load()
        #expect(model.layoutWidgets["mine"]?.title == "My Films")
        #expect(model.sections.first { $0.id == "mine" }?.widget.title != "My Films", "Home shows the picked source's name")
    }
}
