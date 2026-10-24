import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

/// One movie catalog, `top`.
private let catalogAddon = Manifest(id: "test.cinemeta", name: "Cinemeta", version: "1", resources: [ResourceDescriptor(name: "catalog")],
                                    types: ["movie"], catalogs: [CatalogDescriptor(type: "movie", id: "top", name: "Popular")])

/// Twelve movies, tt1 to tt12, in that order.
private let twelveMovies = Data(#"{"metas":[\#((1...12).map { #"{"id":"tt\#($0)","type":"movie","name":"Movie \#($0)"}"# }.joined(separator: ","))]}"#.utf8)

/// Shuffle on Home: a widget's titles in a new order on its schedule, Home's widgets too when asked, and nothing different when off.
@MainActor
@Suite struct WidgetShuffleHomeTests {
    private func row(_ id: String, shuffle: WidgetShuffle? = nil) -> HomeWidget {
        HomeWidget(id: id, title: id, content: .row(RowConfiguration(
            source: .addonCatalog(AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "movie", catalogID: "top")), shuffle: shuffle)))
    }

    private func services(widgets: [HomeWidget], shuffle: WidgetShuffleSettings = WidgetShuffleSettings()) async throws -> AppServices {
        let transport = StubTransport { request, _ in StubTransport.response(twelveMovies, for: request) }
        let (registry, client) = try await makeStubbedRegistry(manifests: [catalogAddon], transport: transport)
        let settings = InMemorySettingsStore()
        return AppServices(registry: registry, client: client, settings: settings,
                           widgets: InMemoryWidgetStore(widgets + [HomeWidget(id: "cw", title: "Continue", content: .continueWatching)]),
                           widgetContent: WidgetContentService(registry: registry, client: client, settings: settings),
                           widgetShuffle: InMemoryWidgetShuffleStore(shuffle))
    }

    private func ids(_ section: HomeViewModel.Section?) -> [String] { section?.state.value?.map(\.id) ?? [] }
    private let sourceOrder = (1...12).map { "tt\($0)" }

    @Test func withShuffleOffTheTitlesKeepTheSourcesOrder() async throws {
        let model = HomeViewModel(services: try await services(widgets: [row("a")]))
        await model.load()
        #expect(ids(model.sections.first) == sourceOrder)
    }

    @Test func aShuffledWidgetKeepsItsOrderUntilItsNextShuffle() async throws {
        let services = try await services(widgets: [row("a", shuffle: .daily), row("b")])
        let model = HomeViewModel(services: services)
        await model.load()
        let first = ids(model.sections.first { $0.id == "a" })
        #expect(first != sourceOrder && Set(first) == Set(sourceOrder))
        #expect(ids(model.sections.first { $0.id == "b" }) == sourceOrder, "a widget without a shuffle is as it was")
        await model.load()
        #expect(ids(model.sections.first { $0.id == "a" }) == first, "the same order until tomorrow")
        let reopened = HomeViewModel(services: services)
        await reopened.load()
        #expect(ids(reopened.sections.first { $0.id == "a" }) == first, "kept across launches")
    }

    @Test func theWidgetsPagesShuffleAppliesToWidgetsWithoutTheirOwn() async throws {
        let model = HomeViewModel(services: try await services(widgets: [row("a"), row("off", shuffle: .off)],
                                                               shuffle: WidgetShuffleSettings(schedule: .everyOpen)))
        await model.load()
        #expect(ids(model.sections.first { $0.id == "a" }) != sourceOrder)
        #expect(ids(model.sections.first { $0.id == "off" }) == sourceOrder, "a widget set to Off is never shuffled")
    }

    @Test func homesWidgetsAreShuffledOnlyWhenAskedAndContinueWatchingKeepsItsPlace() async throws {
        let rows = (1...8).map { row("r\($0)") }
        let plain = HomeViewModel(services: try await services(widgets: rows, shuffle: WidgetShuffleSettings(schedule: .daily)))
        await plain.load()
        #expect(plain.sections.map(\.id) == rows.map(\.id) + ["cw"])
        let services = try await services(widgets: rows, shuffle: WidgetShuffleSettings(schedule: .daily, shufflesOrder: true))
        let shuffled = HomeViewModel(services: services)
        await shuffled.load()
        #expect(shuffled.sections.map(\.id) != rows.map(\.id) + ["cw"])
        #expect(shuffled.sections.last?.id == "cw")
        #expect(await services.widgets.load()?.map(\.id) == rows.map(\.id) + ["cw"], "the saved layout keeps its own order")
    }

    @Test func resettingWidgetsTurnsShuffleOff() async throws {
        let services = try await services(widgets: [row("a")], shuffle: WidgetShuffleSettings(schedule: .hourly, shufflesOrder: true))
        await DataResetService(services: services).clear(.widgets)
        #expect(await services.widgetShuffle.settings() == WidgetShuffleSettings())
    }

    @Test func turningTheWidgetsPagesShuffleOffStopsShufflingHomeToo() async throws {
        let services = try await services(widgets: [row("a")])
        let model = WidgetsManagerViewModel(services: services)
        await model.setShuffle(WidgetShuffleSettings(schedule: .hourly, shufflesOrder: true))
        #expect(await services.widgetShuffle.settings().shufflesOrder)
        await model.setShuffle(WidgetShuffleSettings(schedule: .off, shufflesOrder: true))
        #expect(await services.widgetShuffle.settings() == WidgetShuffleSettings())
    }
}
