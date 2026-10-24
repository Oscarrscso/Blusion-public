import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

/// A catalog addon with a popular movie list (with three genres) and a series list.
private let cinemeta = Manifest(
    id: "test.cinemeta", name: "Cinemeta", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie", "series"],
    catalogs: [CatalogDescriptor(type: "movie", id: "top", name: "Popular", extra: [ExtraDescriptor(name: "genre", options: ["Action", "Drama", "Comedy"]),
                                                                                   ExtraDescriptor(name: "skip")]),
               CatalogDescriptor(type: "series", id: "trending", name: "Trending")])

/// A Fusion export: one row of Cinemeta's popular list, one genre collection, one unreadable widget with no type (skipped) and Continue Watching.
private let fusionExport = #"""
{ "exportType": "fusionWidgets", "exportVersion": 1, "widgets": [
  { "id": "daily", "title": "Popular", "type": "row.classic", "limit": 12,
    "presentation": { "aspectRatio": "wide", "cardStyle": "large", "badges": { "ratings": false } },
    "dataSource": { "kind": "addonCatalog", "payload": { "addonId": "blusion:test.cinemeta", "catalogId": "movie::top", "catalogType": "movie" } } },
  { "id": "tiles", "title": "Genres", "type": "collection.row", "dataSource": { "kind": "collection", "payload": { "items": [
      { "id": "action", "title": "Action", "dataSources": [ { "kind": "addonCatalog",
          "payload": { "addonId": "blusion:test.cinemeta", "catalogId": "movie::top", "catalogType": "movie", "genre": "Action" } } ] } ] } } },
  { "id": "broken", "title": "Broken" },
  { "id": "ctw", "title": "Continue", "type": "blusion.continueWatching" }
] }
"""#

/// A widget file that needs an addon nobody has installed. The link carries a token, which must never leave the import.
private let linkToTV = "https://tv.example.com/TOKEN/manifest.json"

/// One row of a catalog that only the tv addon has (`tvtop`), so Cinemeta cannot stand in for it.
private func tvImport(id: String = "tv") -> String {
    #"""
    { "widgets": [ { "id": "\#(id)", "title": "TV", "type": "row.classic",
        "dataSource": { "kind": "addonCatalog", "payload": { "addonId": "\#(linkToTV)", "catalogId": "movie::tvtop", "catalogType": "movie" } } } ] }
    """#
}

/// The manifest the tv addon serves at `linkToTV`.
private let tvManifest = Manifest(id: "test.tv", name: "TV Catalogs", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
                                  catalogs: [CatalogDescriptor(type: "movie", id: "tvtop", name: "Top")])

@MainActor
@Suite struct WidgetsManagerViewModelTests {
    private func services(_ manifests: [Manifest] = [cinemeta], transport: StubTransport = StubTransport(data: Data()),
                          widgets: [HomeWidget]? = nil) async throws -> AppServices {
        let (registry, client) = try await makeStubbedRegistry(manifests: manifests, transport: transport)
        return AppServices(registry: registry, client: client, widgets: InMemoryWidgetStore(widgets))
    }

    private func loaded(_ services: AppServices) async -> WidgetsManagerViewModel {
        let model = WidgetsManagerViewModel(services: services)
        await model.load()
        return model
    }

    private func choice(_ model: WidgetsManagerViewModel, _ id: String = "test.cinemeta/movie/top") throws -> WidgetsManagerViewModel.CatalogChoice {
        try #require(model.catalogChoices.first(where: { $0.id == id }))
    }

    /// Continue Watching, which every saved layout keeps (`HomeLayout`).
    private let continueWatching = HomeWidget(id: "cw", title: "Continue", content: .continueWatching)

    private func plainRow(_ id: String) -> HomeWidget {
        let reference = AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "movie", catalogID: "top")
        return HomeWidget(id: id, title: id, content: .row(RowConfiguration(source: .addonCatalog(reference))))
    }

    // MARK: Loading and editing

    private func spotlight(_ id: String = "hero") -> HomeWidget {
        let reference = AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "movie", catalogID: "top")
        return HomeWidget(id: id, title: "Spotlight", hideTitle: true, content: .hero(RowConfiguration(source: .addonCatalog(reference))))
    }

    /// A saved layout that lost Continue Watching (it was deleted from the widgets page) gets it back after the showcase, once.
    @Test func aLayoutWithoutContinueWatchingIsRepairedOnceOnLoad() async throws {
        let saved = [spotlight(), plainRow("a"), plainRow("b"), plainRow("c")]
        let services = try await services(widgets: saved)
        let model = await loaded(services)
        let expected = ["hero", HomeLayout.continueWatchingID, "a", "b", "c"]
        #expect(model.widgets.map(\.id) == expected)
        let stored = try #require(await services.widgets.load())
        #expect(stored.map(\.id) == expected, "the repair is saved")
        #expect(Array(stored.dropFirst(2)) == Array(saved.dropFirst()), "every other row keeps its order and settings")
        let again = await loaded(services)
        #expect(again.widgets == stored, "a second load changes nothing")
        #expect(await services.widgets.load() == stored)
    }

    @Test func aLayoutThatKeepsTheRulesIsNotSavedOnLoad() async throws {
        let saved = [spotlight(), plainRow("a"), HomeWidget(id: "cw", title: "Continue", content: .continueWatching), plainRow("b")]
        let services = try await services(widgets: saved)
        let model = await loaded(services)
        #expect(model.widgets == saved, "Continue Watching keeps its own place")
        #expect(model.saveRevision == 0)
    }

    @Test func continueWatchingCannotBeRemovedButMoves() async throws {
        let continueWatching = HomeWidget(id: "cw", title: "Continue", content: .continueWatching)
        let services = try await services(widgets: [spotlight(), continueWatching, plainRow("a"), plainRow("b")])
        let model = await loaded(services)
        await model.remove(id: "cw")
        await model.remove(atOffsets: IndexSet(integer: 1))
        #expect(model.widgets.map(\.id) == ["hero", "cw", "a", "b"], "neither removal takes it")
        await model.move(fromOffsets: IndexSet(integer: 1), toOffset: 4)
        #expect(model.widgets.map(\.id) == ["hero", "a", "b", "cw"])
        #expect(await services.widgets.load()?.map(\.id) == ["hero", "a", "b", "cw"])
        await model.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(model.widgets.map(\.id) == ["hero", "a", "b", "cw"], "the showcase does not move")
    }

    @Test func theAutomaticLayoutShowsUntilTheFirstChange() async throws {
        let services = try await services()
        let model = await loaded(services)
        #expect(!model.isCustomised)
        let addons = await services.registry.addons
        #expect(model.widgets == DefaultWidgets.make(for: addons))
        let stored = await services.widgets.load()
        #expect(stored == nil, "looking at the layout saves nothing")
    }

    @Test func theFirstChangeSavesTheWholeAutomaticLayoutPlusTheChange() async throws {
        let services = try await services()
        let model = await loaded(services)
        let automatic = model.widgets
        let extra = plainRow("extra")
        await model.add(extra)
        #expect(model.isCustomised)
        #expect(model.widgets == automatic + [extra])
        let saved = await services.widgets.load()
        #expect(saved == automatic + [extra], "the saved list is the whole layout, not just the change")
    }

    @Test func mutationsPersistAndKeepTheirOrder() async throws {
        let services = try await services(widgets: [plainRow("a"), plainRow("b"), plainRow("c"), continueWatching])
        let model = await loaded(services)
        #expect(model.isCustomised)

        await model.add(plainRow("d"))
        await model.update(HomeWidget(id: "b", title: "Renamed", content: .banner(RowConfiguration(source: .tmdbDiscover(TMDbDiscoverQuery())))))
        #expect(model.widgets.map(\.id) == ["a", "b", "c", "cw", "d"])
        #expect(model.widgets[1].title == "Renamed", "update replaces in place")

        await model.remove(id: "c")
        #expect(model.widgets.map(\.id) == ["a", "b", "cw", "d"])
        await model.remove(atOffsets: IndexSet(integer: 0))
        #expect(model.widgets.map(\.id) == ["b", "cw", "d"])
        let saved = await services.widgets.load()
        #expect(saved?.map(\.id) == ["b", "cw", "d"], "every change is saved")
    }

    @Test func moveFollowsTheOnMoveShape() async throws {
        let model = await loaded(try await services(widgets: [plainRow("a"), plainRow("b"), plainRow("c"), plainRow("d"), continueWatching]))
        await model.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(model.widgets.map(\.id) == ["b", "c", "a", "d", "cw"])
        await model.move(fromOffsets: IndexSet([2, 3]), toOffset: 0)
        #expect(model.widgets.map(\.id) == ["a", "d", "b", "c", "cw"])
        await model.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        #expect(model.widgets.map(\.id) == ["c", "a", "d", "b", "cw"])
        await model.move(fromOffsets: IndexSet(integer: 0), toOffset: 9)
        #expect(model.widgets.map(\.id) == ["a", "d", "b", "cw", "c"], "a destination past the end moves to the end")
        await model.move(fromOffsets: IndexSet(integer: 9), toOffset: 0)
        #expect(model.widgets.map(\.id) == ["a", "d", "b", "cw", "c"], "an offset outside the list changes nothing")
    }

    @Test func updatingAnUnknownWidgetOrRemovingNothingChangesNothing() async throws {
        let services = try await services()
        let model = await loaded(services)
        await model.update(plainRow("nobody"))
        await model.remove(id: "nobody")
        await model.remove(atOffsets: IndexSet(integer: 99))
        let addons = await services.registry.addons
        let stored = await services.widgets.load()
        #expect(!model.isCustomised && model.widgets == DefaultWidgets.make(for: addons))
        #expect(stored == nil)
    }

    @Test func addingAWidgetWithAUsedIDGivesItANewOne() async throws {
        let model = await loaded(try await services(widgets: [plainRow("a"), continueWatching]))
        await model.add(plainRow("a"))
        #expect(model.widgets.count == 3)
        #expect(Set(model.widgets.map(\.id)).count == 3, "ids stay unique")
        #expect(model.widgets[0].id == "a")
    }

    @Test func everySaveBumpsTheRevisionButAnUpdateOfAnUnknownWidgetDoesNot() async throws {
        let model = await loaded(try await services(widgets: [plainRow("a")]))
        #expect(model.saveRevision == 0)
        await model.add(plainRow("b"))
        #expect(model.saveRevision == 1)
        await model.update(plainRow("a"))
        #expect(model.saveRevision == 2)
        await model.update(plainRow("nobody"))
        #expect(model.saveRevision == 2, "an update that saves nothing is not a save")
    }

    @Test func resetGoesBackToTheAutomaticLayout() async throws {
        let services = try await services()
        let model = await loaded(services)
        await model.add(plainRow("extra"))
        #expect(model.isCustomised)
        await model.resetToAutomatic()
        #expect(!model.isCustomised)
        let addons = await services.registry.addons
        #expect(model.widgets == DefaultWidgets.make(for: addons))
        let stored = await services.widgets.load()
        #expect(stored == nil)
    }

    @Test func everyChangeForgetsTheCachedRows() async throws {
        let transport = StubTransport(data: Data(#"{"metas":[{"id":"tt1","type":"movie"}]}"#.utf8))
        let services = try await services(transport: transport)
        let model = await loaded(services)
        let source = WidgetSource.addonCatalog(AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "movie", catalogID: "top"))
        _ = try await services.widgetContent.items(for: source, limit: 5)
        _ = try await services.widgetContent.items(for: source, limit: 5)
        #expect(transport.callCount == 1, "the second read is cached")
        await model.add(plainRow("extra"))
        _ = try await services.widgetContent.items(for: source, limit: 5)
        #expect(transport.callCount == 2, "a change to Home asks the addons again")
    }

    // MARK: Import

    @Test func aFusionExportReplacesTheListAndSkipsWhatItCannotRead() async throws {
        let services = try await services(widgets: [plainRow("old")])
        let model = await loaded(services)
        await model.importJSON(fusionExport, mode: .replace)
        #expect(model.widgets.map(\.id) == ["daily", "tiles", "ctw"])
        #expect(model.message == "Imported 3 widgets, skipped 1.")
        #expect(!model.messageIsError && model.isCustomised && model.pendingImport == nil)
        let saved = await services.widgets.load()
        #expect(saved?.map(\.id) == ["daily", "tiles", "ctw"])
    }

    @Test func aFusionExportAppendsAndGivesRepeatedIDsNewOnes() async throws {
        let services = try await services(widgets: [plainRow("daily"), continueWatching])
        let model = await loaded(services)
        await model.importJSON(fusionExport, mode: .append)
        #expect(model.widgets.count == 4, "the file's Continue Watching is not added a second time")
        #expect(model.widgets[0].id == "daily", "the widget already there keeps its id")
        #expect(Set(model.widgets.map(\.id)).count == 4, "the imported copy gets a new id")
        #expect(model.widgets.filter(HomeLayout.isContinueWatching).map(\.id) == ["cw"])
        #expect(model.message == "Imported 2 widgets, skipped 1.")
    }

    @Test func aFileThatRepeatsAnIDKeepsEveryWidget() async throws {
        let model = await loaded(try await services())
        let text = #"{"widgets":[{"id":"x","title":"A","type":"blusion.continueWatching"},{"id":"x","title":"B","type":"blusion.continueWatching"}]}"#
        await model.importJSON(text, mode: .replace)
        #expect(model.widgets.count == 2 && Set(model.widgets.map(\.id)).count == 2)
        #expect(model.message == "Imported 2 widgets.")
    }

    @Test func importErrorsAreSentencesAndChangeNothing() async throws {
        let services = try await services()
        let model = await loaded(services)
        let before = model.widgets
        await model.importJSON("not json", mode: .replace)
        #expect(model.message == WidgetImportError.notWidgetJSON.message && model.messageIsError)
        await model.importJSON(#"{"widgets": []}"#, mode: .replace)
        #expect(model.message == WidgetImportError.empty.message && model.messageIsError)
        await model.importJSON(String(repeating: " ", count: 2 * 1024 * 1024 + 1), mode: .append)
        #expect(model.message == WidgetImportError.tooLarge.message)
        #expect(model.widgets == before && !model.isCustomised)
        let stored = await services.widgets.load()
        #expect(stored == nil)
    }

    @Test func anImportNamingAMissingAddonWaitsAndSavesNothingUntilDecided() async throws {
        let services = try await services()
        let model = await loaded(services)
        await model.importJSON(tvImport(), mode: .replace)
        #expect(model.pendingImport == WidgetsManagerViewModel.PendingImport(widgetCount: 1, missingAddonHosts: ["tv.example.com"]))
        let stored = await services.widgets.load()
        #expect(stored == nil, "nothing is saved until the user decides")
        #expect(!model.isCustomised && model.message == nil)

        let shown = [model.message ?? "", String(describing: model.pendingImport), model.exportJSON() ?? ""]
        for text in shown {
            #expect(!text.contains("TOKEN") && !text.contains("manifest.json"), "the link never reaches the screen: \(text)")
        }
        model.cancelImport()
        let afterCancel = await services.widgets.load()
        #expect(model.pendingImport == nil && afterCancel == nil)
    }

    @Test func finishingWithoutAddonsSavesTheWidgetsAsTheyAre() async throws {
        let services = try await services()
        let model = await loaded(services)
        await model.importJSON(tvImport(), mode: .replace)
        await model.finishImportWithoutAddons()
        #expect(model.pendingImport == nil)
        #expect(model.message == "Imported 1 widget.")
        let stored = await services.widgets.load()
        let saved = try #require(stored)
        #expect(saved.map(\.id) == [HomeLayout.continueWatchingID, "tv"], "Continue Watching comes with every layout")
        let text = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        #expect(!text.contains("TOKEN") && !text.contains("manifest.json"), "what is saved holds the host, never the link")
        let source = try #require(saved.last?.content.rowSource)
        #expect(model.describe(source) == "Catalog from tv.example.com (addon not installed)")
    }

    @Test func installingTheMissingAddonFinishesTheImport() async throws {
        let manifest = try JSONEncoder().encode(tvManifest)
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/manifest.json") == true { return StubTransport.response(manifest, for: request) }
            return StubTransport.response(Data(#"{"metas":[]}"#.utf8), for: request)
        }
        let services = try await services(transport: transport)
        let model = await loaded(services)
        await model.importJSON(tvImport(), mode: .replace)
        await model.installMissingAddonsAndFinishImport()
        #expect(model.message == "Imported 1 widget and installed 1 addon.")
        #expect(!model.messageIsError && model.pendingImport == nil && !model.isWorking)
        let installed = await services.registry.addons.map(\.manifest.id)
        #expect(installed == ["test.cinemeta", "test.tv"])
        let stored = await services.widgets.load()
        let saved = try #require(stored)
        let source = try #require(saved.last?.content.rowSource)
        guard case .addonCatalog(let reference) = source else {
            Issue.record("the imported row should read an addon catalog")
            return
        }
        #expect(reference.manifestID == "test.tv" && reference.host == "tv.example.com")
        #expect(model.catalogChoices.map(\.id) == ["test.cinemeta/movie/top", "test.cinemeta/series/trending", "test.tv/movie/tvtop"])
    }

    @Test func aMissingAddonThatCannotBeInstalledIsCountedWithoutItsLink() async throws {
        let transport = StubTransport { request, _ in StubTransport.response(Data(), status: 500, for: request) }
        let services = try await services(transport: transport)
        let model = await loaded(services)
        await model.importJSON(tvImport(), mode: .replace)
        await model.installMissingAddonsAndFinishImport()
        #expect(model.message == "Imported 1 widget. 1 addon couldn't be installed.")
        #expect(!model.messageIsError)
        let message = model.message ?? ""
        #expect(!message.contains("TOKEN") && !message.contains("http"))
        let stored = await services.widgets.load()
        #expect(stored?.map(\.id) == [HomeLayout.continueWatchingID, "tv"], "the widget is still saved, showing its addon as missing")
    }

    @Test func anAddonInstalledMeanwhileIsNotAFailure() async throws {
        let manifest = try JSONEncoder().encode(tvManifest)
        let transport = StubTransport { request, _ in StubTransport.response(manifest, for: request) }
        let services = try await services(transport: transport)
        let model = await loaded(services)
        await model.importJSON(tvImport(), mode: .replace)
        _ = try await services.registry.install(from: linkToTV)
        await model.installMissingAddonsAndFinishImport()
        #expect(model.message == "Imported 1 widget.", "already installed is neither a failure nor a new install")
        let stored = await services.widgets.load()
        #expect(stored?.map(\.id) == [HomeLayout.continueWatchingID, "tv"])
    }

    @Test func aWebLinkImportsItsFileWithinTheLimit() async throws {
        let transport = StubTransport { request, _ in StubTransport.response(Data(fusionExport.utf8), for: request) }
        let services = try await services(transport: transport)
        let model = await loaded(services)
        await model.importFromURL("  https://lists.example.com/home.json \n", mode: .replace)
        #expect(transport.requests.last?.url?.absoluteString == "https://lists.example.com/home.json")
        #expect(transport.limits.last?.maxBytes == 2 * 1024 * 1024)
        #expect(model.widgets.map(\.id) == ["daily", "tiles", "ctw"])
        #expect(model.message == "Imported 3 widgets, skipped 1.")
        #expect(!model.isWorking)
    }

    @Test func aLinkThatIsNotAWebAddressIsRefusedWithoutARequest() async throws {
        let transport = StubTransport(data: Data())
        let model = await loaded(try await services(transport: transport))
        for text in ["", "not a link", "ftp://example.com/home.json", "https://", "file:///etc/passwd"] {
            await model.importFromURL(text, mode: .append)
            #expect(model.messageIsError && model.message != nil, "refused: \(text)")
        }
        #expect(transport.callCount == 0)
        #expect(model.message?.contains("https://") == true, "the message says what to paste")
    }

    @Test func aFailedDownloadSaysWhy() async throws {
        let transport = StubTransport { request, _ in StubTransport.response(Data(), status: 404, for: request) }
        let services = try await services(transport: transport)
        let model = await loaded(services)
        await model.importFromURL("https://lists.example.com/gone.json", mode: .replace)
        #expect(model.message == "Couldn't download the widget file (not found).")
        #expect(model.messageIsError && !model.isWorking)
        let stored = await services.widgets.load()
        #expect(stored == nil)
    }

    @Test func exportReadsBackWithReplaceAsTheSameWidgets() async throws {
        let services = try await services(widgets: [])
        let author = await loaded(services)
        let popular = try choice(author)
        await author.add(WidgetsManagerViewModel.makeRow(title: "Action", choice: popular, genre: "Action",
                                                         presentation: WidgetPresentation(aspectRatio: .wide, cardStyle: .large, showsRatings: false,
                                                                                          showsProviders: true),
                                                         limit: 30))
        await author.add(WidgetsManagerViewModel.makeHero(choice: popular))
        await author.add(WidgetsManagerViewModel.makeGenreCollection(title: "Genres", choice: popular))
        #expect(author.widgets.contains(where: HomeLayout.isContinueWatching), "an empty layout has Continue Watching")
        let text = try #require(author.exportJSON())
        #expect(text.contains("fusionWidgets") && !text.contains("TOKEN"))

        let reader = await loaded(services)
        await reader.importJSON(text, mode: .replace)
        #expect(reader.widgets == author.widgets)
        #expect(reader.message == "Imported 4 widgets.")
    }

    // MARK: Describing and making

    @Test func describeNamesEachKindOfSource() async throws {
        let model = await loaded(try await services())
        let resolved = AddonCatalogReference(manifestID: "test.cinemeta", host: "stub0.example.com", catalogType: "movie", catalogID: "top")
        #expect(model.describe(.addonCatalog(resolved)) == "Popular Movies · Cinemeta")
        let withGenre = AddonCatalogReference(manifestID: "test.cinemeta", host: "stub0.example.com", catalogType: "movie", catalogID: "top", genre: "Action")
        #expect(model.describe(.addonCatalog(withGenre)) == "Popular Movies · Action · Cinemeta")
        let list = TraktListReference(username: "tvgeniekodi", listSlug: "daily-picks", listName: "Daily Picks")
        #expect(model.describe(.traktList(list)) == "Trakt list · Daily Picks by tvgeniekodi")
        #expect(model.describe(.unsupported(kind: "anilistCatalog")) == "Not supported (anilistCatalog)")
        let missingHost = AddonCatalogReference(host: "example.com", catalogType: "movie", catalogID: "nowhere")
        #expect(model.describe(.addonCatalog(missingHost)) == "Catalog from example.com (addon not installed)")
        let missingAll = AddonCatalogReference(catalogType: "movie", catalogID: "nowhere")
        #expect(model.describe(.addonCatalog(missingAll)) == "Catalog (addon not installed)")
    }

    @Test func summaryNamesTheKindOfWidget() async throws {
        let model = await loaded(try await services())
        let popular = try choice(model)
        let row = HomeWidget(title: "Popular", content: .row(RowConfiguration(source: .addonCatalog(popular.reference))))
        #expect(model.summary(of: row) == "Row · Popular Movies · Cinemeta")
        #expect(model.summary(of: WidgetsManagerViewModel.makeHero(choice: popular)) == "Spotlight · Popular Movies · Cinemeta")
        #expect(model.summary(of: WidgetsManagerViewModel.makeBanner(choice: popular)).hasPrefix("Banner · "))
        let tiles = (0..<12).map { CollectionItem(id: "\($0)", title: "Tile \($0)") }
        #expect(model.summary(of: HomeWidget(title: "Tiles", content: .collection(tiles))) == "Collection · 12 tiles")
        #expect(model.summary(of: HomeWidget(title: "One", content: .collection([tiles[0]]))) == "Collection · 1 tile")
        #expect(model.summary(of: HomeWidget(title: "Continue", content: .continueWatching)) == "Continue")
    }

    @Test func aDiscoverSourceIsNamedByItsQuery() async throws {
        let model = await loaded(try await services())
        let query = TMDbDiscoverQuery(kind: .series, ordering: .trendingThisWeek, genres: [.init(id: 16, name: "Animation")],
            minimumVotes: 50)
        let source = WidgetSource.tmdbDiscover(query)
        #expect(model.describe(source) == "TMDB · Trending Animation Series This Week · 1 filter")
        #expect(model.autoTitle(for: source) == "Trending Animation Series This Week")
        let row = HomeWidget(title: "Discover", content: .row(RowConfiguration(source: source)))
        #expect(model.summary(of: row) == "Row · TMDB · Trending Animation Series This Week · 1 filter")
        #expect(model.autoTitle(for: .tmdbDiscover(TMDbDiscoverQuery())) == "Popular Movies")
        #expect(WidgetsManagerViewModel.traktTitle(source) == "Trakt", "a discover list is not a Trakt list")
    }

    @Test func detailsRevealEverySettingOfAWidget() async throws {
        let model = await loaded(try await services())
        let popular = try choice(model)
        let row = HomeWidget(id: "r", title: "Popular", hideTitle: true,
                             content: .row(RowConfiguration(source: .addonCatalog(popular.reference),
                                                            presentation: WidgetPresentation(aspectRatio: .wide, cardStyle: .large, showsRatings: false,
                                                                                             showsRank: true),
                                                            limit: 12, cacheTTL: 0)))
        let details = model.details(of: row)
        #expect(details.map(\.label) == ["Type", "Source", "Items", "Card shape", "Card size", "Ratings", "Providers", "Numbered", "Better Posters",
                                         "Saved for", "Title"])
        #expect(details.map(\.value) == ["Numbered row", "Popular Movies · Cinemeta", "12", "Wide", "Large", "No", "No", "Yes", "No", "Not saved",
                                         "Hidden"])
        #expect(details.map(\.id) == Array(0..<details.count))

        let tiles = [CollectionItem(title: "Action", sources: [.addonCatalog(popular.reference)]), CollectionItem(title: "", sources: [])]
        let collection = model.details(of: HomeWidget(title: "Genres", content: .collection(tiles)))
        #expect(collection.map(\.label) == ["Type", "Tiles", "Action", "Untitled tile", "Title"])
        #expect(collection.map(\.value) == ["Collection", "2 tiles", "Popular Movies · Cinemeta", "No source", "Shown"])

        let hero = model.details(of: WidgetsManagerViewModel.makeHero(choice: popular))
        #expect(hero.first?.value == "Spotlight")
        #expect(hero.first { $0.label == "Saved for" }?.value == "1 hour")
    }

    @Test func catalogChoicesListEnabledBrowsableCatalogsOnce() async throws {
        let needsSearch = Manifest(id: "test.search", name: "Search", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
                                   catalogs: [CatalogDescriptor(type: "movie", id: "search", name: "Search",
                                                                extra: [ExtraDescriptor(name: "search", isRequired: true)])])
        let disabled = Manifest(id: "test.off", name: "Off", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
                                catalogs: [CatalogDescriptor(type: "movie", id: "off", name: "Off")])
        let manifests = [cinemeta, cinemeta, needsSearch, disabled]
        let (registry, client) = try await makeStubbedRegistry(manifests: manifests, transport: StubTransport(data: Data()))
        let addons = await registry.addons
        try await registry.setEnabled(false, id: try #require(addons.first { $0.name == "Off" }).id)
        let model = await loaded(AppServices(registry: registry, client: client))
        #expect(model.catalogChoices.map(\.id) == ["test.cinemeta/movie/top", "test.cinemeta/series/trending"],
                "a catalog that needs input, a disabled addon and a repeated addon add nothing")
        #expect(model.catalogChoices.map(\.title) == ["Popular Movies", "Trending Series"])
        #expect(model.catalogChoices.first?.addonName == "Cinemeta")
        #expect(model.catalogChoices.first?.genres == ["Action", "Drama", "Comedy"])
    }

    @Test func theMakersBuildRowsHeroesAndGenreTiles() async throws {
        let model = await loaded(try await services())
        let popular = try choice(model)

        let row = WidgetsManagerViewModel.makeRow(title: "Action", choice: popular, genre: "Action")
        guard case .row(let config) = row.content else {
            Issue.record("makeRow should make a row")
            return
        }
        #expect(row.title == "Action" && config.limit == 20 && !row.id.isEmpty)
        let actionReference = AddonCatalogReference(manifestID: "test.cinemeta", host: "stub0.example.com", catalogType: "movie", catalogID: "top",
                                                    genre: "Action")
        #expect(config.source == .addonCatalog(actionReference))

        let hero = WidgetsManagerViewModel.makeHero(choice: popular)
        guard case .hero(let spotlight) = hero.content else {
            Issue.record("makeHero should make a hero")
            return
        }
        #expect(hero.hideTitle && spotlight.limit == 8 && spotlight.source == .addonCatalog(popular.reference))
        let actionHero = WidgetsManagerViewModel.makeHero(choice: popular, genre: "Action")
        guard case .hero(let filteredSpotlight) = actionHero.content else {
            Issue.record("Expected spotlight")
            return
        }
        #expect(filteredSpotlight.source == .addonCatalog(actionReference))

        let genres = WidgetsManagerViewModel.makeGenreCollection(title: "Genres", choice: popular)
        guard case .collection(let tiles) = genres.content else {
            Issue.record("makeGenreCollection should make a collection")
            return
        }
        #expect(tiles.map(\.title) == ["Action", "Drama", "Comedy"], "one tile per genre")
        let dramaReference = AddonCatalogReference(manifestID: "test.cinemeta", host: "stub0.example.com", catalogType: "movie", catalogID: "top",
                                                   genre: "Drama")
        #expect(tiles[1].sources == [.addonCatalog(dramaReference)])
        #expect(Set(tiles.map(\.id)).count == 3)
    }
}

private extension HomeWidget.Content {
    /// The source of a `.row`, `.hero` or `.banner`, for assertions.
    var rowSource: WidgetSource? {
        switch self {
        case .row(let row), .hero(let row), .banner(let row): return row.source
        case .collection, .continueWatching, .unsupported: return nil
        }
    }
}
