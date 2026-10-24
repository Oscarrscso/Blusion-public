// swiftlint:disable line_length
import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

/// Real Fusion exports, verbatim. `Netflix` uses an addon link with a secret token; it must never reach a widget.
private let bigSample = #"""
{ "exportType": "fusionWidgets", "exportVersion": 1, "widgets": [
  { "id": "trakt.EF19B376", "title": "Daily Picks", "type": "row.classic", "cacheTTL": 3600, "limit": 50,
    "presentation": { "aspectRatio": "poster", "cardStyle": "medium", "badges": { "providers": false, "ratings": true } },
    "dataSource": { "kind": "traktList", "payload": { "listName": "Daily Picks", "listSlug": "daily-picks", "traktId": 31897770, "username": "tvgeniekodi" } } },
  { "id": "aio.1", "title": "Netflix", "type": "row.classic", "cacheTTL": 3600, "limit": 20,
    "presentation": { "aspectRatio": "wide", "cardStyle": "large", "badges": { "providers": true, "ratings": false } },
    "dataSource": { "sourceType": "aiometadata", "kind": "addonCatalog",
                    "payload": { "addonId": "https://stub0.example.com/TOKEN/manifest.json", "catalogId": "movie::mdblist.wb", "catalogType": "movie" } } },
  { "id": "collection.2F452A70", "title": "Streaming Services", "type": "collection.row",
    "dataSource": { "kind": "collection", "payload": { "items": [
      { "id": "BCC26070", "title": "Netflix", "hideTitle": false, "imageAspect": "square",
        "imageURL": "https://files.orangebyte.io/resources/omni/images/groups/netflix.png",
        "dataSources": [
          { "kind": "traktList", "payload": { "listName": "Netflix Movies", "listSlug": "netflix-movies", "traktId": 30828956, "username": "tvgeniekodi" } },
          { "kind": "traktList", "payload": { "listName": "Netflix Shows", "listSlug": "netflix-shows", "traktId": 30828975, "username": "tvgeniekodi" } } ] },
      { "id": "8E789D0D", "title": "1980s", "hideTitle": true, "imageAspect": "wide",
        "imageURL": "https://raw.githubusercontent.com/itsrenoria/fusion-starter-kit/refs/heads/main/resources/widgets/decades/wide/rdnoni/1980s-wide.jpg" } ] } } }
] }
"""#

@Suite struct FusionWidgetCodecTests {
    private func decode(_ text: String, installed: [InstalledAddon] = []) throws -> FusionWidgetCodec.ImportResult {
        try FusionWidgetCodec.decode(Data(text.utf8), installed: installed)
    }

    private func config(_ widget: HomeWidget) -> RowConfiguration? {
        switch widget.content {
        case .row(let config), .hero(let config), .banner(let config): return config
        case .collection, .continueWatching, .unsupported: return nil
        }
    }

    private func tiles(_ widget: HomeWidget) -> [CollectionItem]? {
        if case .collection(let tiles) = widget.content { return tiles }
        return nil
    }

    /// A catalog addon whose manifest id and catalog match the big sample's Netflix row.
    private func netflixAddon() -> Manifest {
        Manifest(id: "com.example.catalogs", name: "Catalogs", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
                 catalogs: [CatalogDescriptor(type: "movie", id: "mdblist.wb", name: "Warner Bros")])
    }

    // MARK: Real samples

    @Test func theBigSampleDecodesToItsThreeWidgets() throws {
        let result = try decode(bigSample)
        #expect(result.widgets.map(\.id) == ["trakt.EF19B376", "aio.1", "collection.2F452A70"])
        #expect(result.widgets.map(\.title) == ["Daily Picks", "Netflix", "Streaming Services"])
        #expect(result.skipped == 0)

        let daily = try #require(config(result.widgets[0]))
        #expect(daily.limit == 50 && daily.cacheTTL == 3600)
        #expect(daily.presentation == WidgetPresentation(aspectRatio: .poster, cardStyle: .medium, showsRatings: true, showsProviders: false))
        #expect(daily.source == .traktList(TraktListReference(username: "tvgeniekodi", listSlug: "daily-picks", listName: "Daily Picks", traktID: 31897770)))

        if case .row = result.widgets[0].content {} else { Issue.record("Daily Picks should be a row") }
        let netflix = try #require(config(result.widgets[1]))
        #expect(netflix.limit == 20)
        #expect(netflix.presentation == WidgetPresentation(aspectRatio: .wide, cardStyle: .large, showsRatings: false, showsProviders: true))
        #expect(netflix.source == .addonCatalog(AddonCatalogReference(host: "stub0.example.com", catalogType: "movie", catalogID: "mdblist.wb")))

        let collection = try #require(tiles(result.widgets[2]))
        #expect(collection.map(\.title) == ["Netflix", "1980s"])
        #expect(collection[0].id == "BCC26070" && collection[0].imageAspect == .square && !collection[0].hideTitle)
        #expect(collection[0].imageURL == URL(string: "https://files.orangebyte.io/resources/omni/images/groups/netflix.png"))
        #expect(collection[0].sources == [
            .traktList(TraktListReference(username: "tvgeniekodi", listSlug: "netflix-movies", listName: "Netflix Movies", traktID: 30828956)),
            .traktList(TraktListReference(username: "tvgeniekodi", listSlug: "netflix-shows", listName: "Netflix Shows", traktID: 30828975)),
        ])
        #expect(collection[1].hideTitle && collection[1].imageAspect == .wide && collection[1].sources.isEmpty)
    }

    @Test func aMissingAddonIsReportedWithItsHostAndLink() throws {
        let result = try decode(bigSample, installed: [])
        #expect(result.missingAddonHosts == ["stub0.example.com"])
        #expect(result.missingAddonLinks == ["https://stub0.example.com/TOKEN/manifest.json"])
    }

    @Test func anInstalledAddonResolvesTheSampleAndNothingIsMissing() async throws {
        let (registry, _) = try await makeStubbedRegistry(manifests: [netflixAddon()], transport: StubTransport(data: Data()))
        let addons = await registry.addons
        let result = try decode(bigSample, installed: addons)
        let netflix = try #require(config(result.widgets[1]))
        guard case .addonCatalog(let reference) = netflix.source else {
            Issue.record("Netflix should be an addon catalog")
            return
        }
        #expect(reference.manifestID == "com.example.catalogs")
        #expect(reference.host == "stub0.example.com")
        #expect(reference.resolve(in: addons)?.catalog.id == "mdblist.wb")
        #expect(result.missingAddonHosts.isEmpty && result.missingAddonLinks.isEmpty)
    }

    @Test func noTokenSurvivesDecodingIntoAnyPersistableForm() async throws {
        let (registry, _) = try await makeStubbedRegistry(manifests: [netflixAddon()], transport: StubTransport(data: Data()))
        let addons = await registry.addons
        for installed in [addons, []] {
            let result = try decode(bigSample, installed: installed)
            let json = String(decoding: try JSONEncoder().encode(result.widgets), as: UTF8.self)
            let fusion = String(decoding: try FusionWidgetCodec.encode(result.widgets), as: UTF8.self)
            #expect(!json.contains("TOKEN") && !fusion.contains("TOKEN"), "the token is never stored")
            #expect(!json.contains("manifest.json") && !fusion.contains("manifest.json"), "the manifest link is never stored")
        }
    }

    // MARK: Widgets

    @Test func unknownAndBrokenWidgetsAreSkippedAndCounted() throws {
        let result = try decode(#"""
        { "widgets": [
          { "id": "ok-row", "title": "Row", "type": "row.classic", "dataSource": { "kind": "traktList", "payload": { "username": "u", "listSlug": "s" } } },
          { "id": "unknown", "title": "Unknown", "type": "some.future.type" },
          { "id": "no-source", "title": "No source", "type": "row.classic" },
          { "id": "empty-tiles", "title": "Empty", "type": "collection.row", "dataSource": { "kind": "collection", "payload": { "items": [1, "two"] } } },
          "not an object",
          { "id": "ok-continue", "title": "Continue", "type": "blusion.continueWatching" },
          { "id": "mixed", "title": "Mixed", "type": "collection.row", "dataSource": { "kind": "collection", "payload": { "items": [ { "id": "good",
              "title": "Good" }, 7 ] } } }
        ] }
        """#)
        #expect(result.widgets.map(\.id) == ["ok-row", "unknown", "ok-continue", "mixed"], "an unknown type is kept, not dropped")
        #expect(result.skipped == 4, "row without a source, tile-less collection, non-object widget, one bad tile")
        #expect(result.widgets[1].content == .unsupported(type: "some.future.type"))
        #expect(result.widgets[2].content == .continueWatching)
        #expect(tiles(result.widgets[3])?.map(\.id) == ["good"])
    }

    @Test func aRowWithoutAReadableSourceIsSkipped() throws {
        let result = try decode(#"""
        { "widgets": [
          { "id": "no-kind", "title": "No kind", "type": "row.classic", "dataSource": { "payload": { "catalogId": "movie::top" } } },
          { "id": "no-catalog", "title": "No catalog", "type": "row.classic",
            "dataSource": { "kind": "addonCatalog", "payload": { "addonId": "https://a.example.com/manifest.json", "catalogType": "movie" } } },
          { "id": "empty-id", "title": "Empty id", "type": "row.classic",
            "dataSource": { "kind": "addonCatalog", "payload": { "catalogId": "movie::", "catalogType": "movie" } } },
          { "id": "kept", "title": "Kept", "type": "row.classic", "dataSource": { "kind": "traktList", "payload": { "username": "u", "listSlug": "s" } } }
        ] }
        """#)
        #expect(result.widgets.map(\.id) == ["kept"])
        #expect(result.skipped == 3)
        #expect(result.missingAddonHosts.isEmpty, "a skipped row never reports its addon as missing")
    }

    @Test func rowsReadNumbersAsStringsAndClampThem() throws {
        let result = try decode(#"""
        { "widgets": [
          { "id": "lenient", "title": "Lenient", "type": "row.classic", "limit": "50", "cacheTTL": "120",
            "presentation": { "aspectRatio": "LANDSCAPE", "cardStyle": "Large" },
            "dataSource": { "kind": "traktList", "payload": { "username": "u", "listSlug": "s" } } },
          { "id": "high", "title": "High", "type": "row.classic", "limit": 500,
            "dataSource": { "kind": "traktList", "payload": { "username": "u", "listSlug": "s" } } },
          { "id": "nonsense", "title": "Nonsense", "type": "row.classic", "limit": "lots", "cacheTTL": null,
            "dataSource": { "kind": "traktList", "payload": { "username": "u", "listSlug": "s" } } }
        ] }
        """#)
        let lenient = try #require(config(result.widgets[0]))
        #expect(lenient.limit == 50 && lenient.cacheTTL == 120)
        #expect(lenient.presentation == WidgetPresentation(aspectRatio: .wide, cardStyle: .large, showsRatings: true, showsProviders: false))
        #expect(try #require(config(result.widgets[1])).limit == 100)
        let nonsense = try #require(config(result.widgets[2]))
        #expect(nonsense.limit == 20 && nonsense.cacheTTL == 3600)
    }

    @Test func badgesAndUnknownPresentationValuesFallBack() throws {
        let result = try decode(#"""
        { "widgets": [
          { "id": "a", "title": "A", "type": "row.classic", "presentation": { "aspectRatio": "banana", "cardStyle": "huge", "badges": { "providers": "yes" } },
            "dataSource": { "kind": "traktList", "payload": { "username": "u", "listSlug": "s" } } },
          { "id": "b", "title": "B", "type": "blusion.hero", "presentation": { "badges": { "ratings": false } },
            "dataSource": { "kind": "traktList", "payload": { "username": "u", "listSlug": "s" } } }
        ] }
        """#)
        let first = try #require(config(result.widgets[0]))
        #expect(first.presentation == WidgetPresentation(aspectRatio: .poster, cardStyle: .medium, showsRatings: true, showsProviders: true))
        let hero = try #require(config(result.widgets[1]))
        #expect(hero.presentation == WidgetPresentation(aspectRatio: .poster, cardStyle: .medium, showsRatings: false, showsProviders: false))
        if case .hero = result.widgets[1].content {} else { Issue.record("blusion.hero should decode to a hero") }
    }

    @Test func aTraktListWithoutAUserOrSlugIsKeptAsUnsupported() throws {
        let result = try decode(#"""
        { "widgets": [
          { "id": "partial", "title": "Partial", "type": "row.classic", "dataSource": { "kind": "traktList", "payload": { "listSlug": "only-slug" } } }
        ] }
        """#)
        #expect(result.skipped == 0)
        #expect(config(result.widgets[0])?.source == .unsupported(kind: "traktList"))
    }

    @Test func traktIDsAcceptNumbersNumericStringsAndNull() throws {
        let result = try decode(#"""
        { "widgets": [
          { "id": "t1", "title": "A", "type": "row.classic", "dataSource": { "kind": "traktList", "payload": { "username": "u", "listSlug": "a",
              "traktId": "30828956" } } },
          { "id": "t2", "title": "B", "type": "row.classic", "dataSource": { "kind": "traktList", "payload": { "username": "u", "listSlug": "b", "traktId": null } } },
          { "id": "t3", "title": "C", "type": "row.classic", "dataSource": { "kind": "traktList", "payload": { "username": "u", "listSlug": "c", "traktId": "soon" } } }
        ] }
        """#)
        #expect(config(result.widgets[0])?.source == .traktList(TraktListReference(username: "u", listSlug: "a", listName: "a", traktID: 30828956)))
        #expect(config(result.widgets[1])?.source == .traktList(TraktListReference(username: "u", listSlug: "b", listName: "b", traktID: nil)))
        #expect(config(result.widgets[2])?.source == .traktList(TraktListReference(username: "u", listSlug: "c", listName: "c", traktID: nil)))
    }

    @Test func unknownSourceKindsAreKeptForTheUIToExplain() throws {
        let result = try decode(#"""
        { "widgets": [
          { "id": "anilist", "title": "AniList", "type": "row.classic", "dataSource": { "kind": "anilistCatalog", "payload": { "listId": 4 } } },
          { "id": "tiles", "title": "Tiles", "type": "collection.row", "dataSource": { "kind": "collection", "payload": { "items": [
            { "id": "x", "title": "X", "dataSources": [ { "kind": "anilistCatalog", "payload": {} } ] } ] } } }
        ] }
        """#)
        #expect(result.widgets.count == 2 && result.skipped == 0)
        #expect(config(result.widgets[0])?.source == .unsupported(kind: "anilistCatalog"))
        #expect(tiles(result.widgets[1])?.first?.sources == [.unsupported(kind: "anilistCatalog")])
    }

    // MARK: Addon identities

    @Test func catalogIDsSplitOnTheFirstSeparatorAndTheGenreIsKept() throws {
        let result = try decode(#"""
        { "widgets": [
          { "id": "s1", "title": "Split", "type": "row.classic",
            "dataSource": { "kind": "addonCatalog", "payload": { "addonId": "YOUR_AIOMETADATA", "catalogId": "all::trakt.list.884", "catalogType": "series",
                "genre": "Drama" } } },
          { "id": "s2", "title": "Plain", "type": "row.classic",
            "dataSource": { "kind": "addonCatalog", "payload": { "addonId": "blusion:com.example.one", "catalogId": "plain-id", "catalogType": "movie" } } }
        ] }
        """#)
        #expect(config(result.widgets[0])?.source == .addonCatalog(AddonCatalogReference(catalogType: "all", catalogID: "trakt.list.884", genre: "Drama")))
        #expect(config(result.widgets[1])?.source == .addonCatalog(AddonCatalogReference(manifestID: "com.example.one", catalogType: "movie", catalogID: "plain-id")))
        #expect(result.missingAddonHosts.isEmpty && result.missingAddonLinks.isEmpty, "placeholders and blusion: ids are not links")
    }

    @Test func aPlaceholderAddonLeavesTheReferenceUnidentified() throws {
        let result = try decode(#"""
        { "widgets": [
          { "id": "p", "title": "P", "type": "row.classic",
            "dataSource": { "kind": "addonCatalog", "payload": { "addonId": "YOUR_AIOMETADATA", "catalogId": "movie::top", "catalogType": "movie" } } }
        ] }
        """#)
        #expect(config(result.widgets[0])?.source == .addonCatalog(AddonCatalogReference(catalogType: "movie", catalogID: "top")))
    }

    @Test func aMissingLocalAddonIsReportedByItsURLHostWithoutThePort() throws {
        let result = try decode(#"""
        { "widgets": [
          { "id": "lan", "title": "LAN", "type": "row.classic",
            "dataSource": { "kind": "addonCatalog", "payload": { "addonId": "http://192.168.1.5:7000/manifest.json", "catalogId": "movie::top" } } }
        ] }
        """#)
        #expect(result.missingAddonHosts == ["192.168.1.5"])
        #expect(result.missingAddonLinks == ["http://192.168.1.5:7000/manifest.json"])
    }

    @Test func missingAddonsAreListedOncePerHostAndLinkInOrder() throws {
        let result = try decode(#"""
        { "widgets": [
          { "id": "a", "title": "A", "type": "row.classic", "dataSource": { "kind": "addonCatalog", "payload": { "addonId": "https://a.example.com/x/manifest.json",
              "catalogId": "movie::top" } } },
          { "id": "b", "title": "B", "type": "row.classic", "dataSource": { "kind": "addonCatalog", "payload": { "addonId": "https://b.example.com/manifest.json",
              "catalogId": "movie::top" } } },
          { "id": "c", "title": "C", "type": "row.classic", "dataSource": { "kind": "addonCatalog", "payload": { "addonId": "https://a.example.com/x/manifest.json",
              "catalogId": "series::top" } } },
          { "id": "d", "title": "D", "type": "row.classic", "dataSource": { "kind": "addonCatalog", "payload": { "addonId": "https://a.example.com/y/manifest.json",
              "catalogId": "movie::top" } } }
        ] }
        """#)
        #expect(result.missingAddonHosts == ["a.example.com", "b.example.com"])
        #expect(result.missingAddonLinks == ["https://a.example.com/x/manifest.json", "https://b.example.com/manifest.json", "https://a.example.com/y/manifest.json"])
    }

    @Test func aLinkMatchesAnInstalledAddonWhateverItsSpelling() async throws {
        let (registry, _) = try await makeStubbedRegistry(manifests: [netflixAddon()], transport: StubTransport(data: Data()))
        let addons = await registry.addons
        let result = try decode(#"""
        { "widgets": [
          { "id": "a", "title": "A", "type": "row.classic", "dataSource": { "kind": "addonCatalog",
              "payload": { "addonId": "stremio://STUB0.example.com/TOKEN/manifest.json", "catalogId": "movie::mdblist.wb" } } }
        ] }
        """#, installed: addons)
        #expect(config(result.widgets[0])?.source == .addonCatalog(AddonCatalogReference(manifestID: "com.example.catalogs", host: "stub0.example.com",
            catalogType: "movie", catalogID: "mdblist.wb")))
        #expect(result.missingAddonLinks.isEmpty)
    }

    @Test func aBlusionIDTakesTheHostFromAnInstalledAddon() async throws {
        let (registry, _) = try await makeStubbedRegistry(manifests: [netflixAddon()], transport: StubTransport(data: Data()))
        let addons = await registry.addons
        let result = try decode(#"""
        { "widgets": [
          { "id": "a", "title": "A", "type": "row.classic", "dataSource": { "kind": "addonCatalog", "payload": { "addonId": "blusion:com.example.catalogs",
              "catalogId": "movie::mdblist.wb" } } }
        ] }
        """#, installed: addons)
        #expect(config(result.widgets[0])?.source == .addonCatalog(AddonCatalogReference(manifestID: "com.example.catalogs", host: "stub0.example.com",
            catalogType: "movie", catalogID: "mdblist.wb")))
    }

    // MARK: Collections and tiles

    @Test func aBareArrayBecomesOneCollectionWidget() throws {
        let result = try decode(#"""
        [ { "id": "824E1B1F", "name": "1980s", "hideTitle": true, "layout": "Wide", "backgroundImageURL": "https://example.com/1980s-wide.jpg" },
          { "id": "2", "name": "Ftp", "layout": "Landscape", "backgroundImageURL": "ftp://example.com/x.jpg" } ]
        """#)
        #expect(result.widgets.count == 1 && result.widgets[0].title == "Collections")
        let tiles = try #require(self.tiles(result.widgets[0]))
        #expect(tiles.map(\.id) == ["824E1B1F", "2"])
        #expect(tiles[0].title == "1980s" && tiles[0].hideTitle && tiles[0].imageAspect == .wide)
        #expect(tiles[0].imageURL == URL(string: "https://example.com/1980s-wide.jpg") && tiles[0].sources.isEmpty)
        #expect(tiles[1].imageURL == nil, "only http(s) images are kept")
        #expect(tiles[1].imageAspect == .wide, "landscape means wide")
    }

    @Test func aRepeatedTileIDGetsAFreshOne() throws {
        let result = try decode(#"""
        [ { "id": "1", "name": "Alpha" }, { "id": "1", "name": "Beta" }, { "id": "2", "name": "Gamma" }, { "id": "1", "name": "Delta" } ]
        """#)
        let tiles = try #require(self.tiles(result.widgets[0]))
        #expect(tiles.map(\.title) == ["Alpha", "Beta", "Gamma", "Delta"])
        #expect(tiles[0].id == "1" && tiles[2].id == "2", "the first tile with an id keeps it")
        #expect(tiles[1].id != "1" && tiles[3].id != "1", "a repeat gets a fresh id")
        #expect(Set(tiles.map(\.id)).count == 4, "every tile has its own id")
    }

    @Test func tileAspectsAndImagesAreReadLeniently() throws {
        let result = try decode(#"""
        [ { "id": "p", "title": "Poster", "imageAspect": "POSTER", "imageURL": "https://example.com/p.png" },
          { "id": "s", "title": "Square", "imageAspect": "square", "imageURL": "file:///etc/passwd", "backgroundImageURL": "https://example.com/s.png" },
          { "id": "u", "title": "Unknown", "imageAspect": "banana" } ]
        """#)
        let tiles = try #require(self.tiles(result.widgets[0]))
        #expect(tiles[0].imageAspect == .poster && tiles[0].imageURL == URL(string: "https://example.com/p.png"))
        #expect(tiles[1].imageAspect == .square && tiles[1].imageURL == URL(string: "https://example.com/s.png"), "a bad imageURL falls back to the background")
        #expect(tiles[2].imageAspect == .wide && tiles[2].imageURL == nil)
    }

    @Test func unreadableTilesInABareArrayAreCountedWhenOthersSurvive() throws {
        let result = try decode(#"[ { "id": "ok", "name": "Ok" }, 2, "x" ]"#)
        #expect(result.widgets.count == 1 && tiles(result.widgets[0])?.map(\.id) == ["ok"])
        #expect(result.skipped == 2)
    }

    @Test func aBareArrayWithNoReadableTileIsEmpty() {
        for text in ["[]", "[1, 2]", #"["x"]"#] {
            #expect(throws: WidgetImportError.empty) { try FusionWidgetCodec.decode(Data(text.utf8), installed: []) }
        }
    }

    // MARK: Refusals

    @Test func emptyExportsAreRefused() {
        // A widget with an unknown type is kept as a placeholder, so only a widget without any type leaves the import empty.
        for text in [#"{"widgets": []}"#, #"{"widgets": [{"id": "x", "title": "No type"}]}"#] {
            #expect(throws: WidgetImportError.empty) { try FusionWidgetCodec.decode(Data(text.utf8), installed: []) }
        }
    }

    @Test func notWidgetJSONIsRefused() {
        for text in ["not json", #""hello""#, "null", "42", #"{"foo": 1}"#, #"{"widgets": "x"}"#] {
            #expect(throws: WidgetImportError.notWidgetJSON) { try FusionWidgetCodec.decode(Data(text.utf8), installed: []) }
        }
    }

    @Test func oversizedFilesAreRefusedBeforeParsing() {
        let limit = 2 * 1024 * 1024
        #expect(throws: WidgetImportError.tooLarge) { try FusionWidgetCodec.decode(Data(repeating: UInt8(ascii: " "), count: limit + 1), installed: []) }
        #expect(throws: WidgetImportError.notWidgetJSON) { try FusionWidgetCodec.decode(Data(repeating: UInt8(ascii: " "), count: limit), installed: []) }
    }

    @Test func everyImportErrorHasASentence() {
        let errors: [WidgetImportError] = [.tooLarge, .notWidgetJSON, .empty]
        for error in errors {
            #expect(error.message.hasSuffix(".") && error.message.count > 20)
        }
    }

    // MARK: Encoding

    @Test func encodingWritesTheFusionEnvelope() throws {
        let widgets = [HomeWidget(id: "w", title: "Movies", content: .row(RowConfiguration(
            source: .addonCatalog(AddonCatalogReference(manifestID: "com.example.one", catalogType: "movie", catalogID: "top", genre: "Drama")), limit: 30)))]
        let data = try FusionWidgetCodec.encode(widgets)
        let text = String(decoding: data, as: UTF8.self)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["exportType"] as? String == "fusionWidgets")
        #expect(root["exportVersion"] as? Int == 1)
        let widget = try #require((root["widgets"] as? [[String: Any]])?.first)
        #expect(widget["id"] as? String == "w" && widget["type"] as? String == "row.classic" && widget["limit"] as? Int == 30)
        let source = try #require(widget["dataSource"] as? [String: Any])
        #expect(source["kind"] as? String == "addonCatalog")
        let payload = try #require(source["payload"] as? [String: Any])
        #expect(payload["addonId"] as? String == "blusion:com.example.one")
        #expect(payload["catalogId"] as? String == "movie::top")
        #expect(payload["catalogType"] as? String == "movie")
        #expect(payload["genre"] as? String == "Drama")
        let exportType = try #require(text.range(of: "\"exportType\""))
        let widgetsKey = try #require(text.range(of: "\"widgets\""))
        #expect(exportType.lowerBound < widgetsKey.lowerBound, "keys are sorted")
        #expect(text.contains("\n"), "pretty-printed")
    }

    @Test func aSourceWithoutAKnownAddonGetsThePlaceholderAndNoGenre() throws {
        let widgets = [HomeWidget(id: "w", title: "Shows", content: .row(RowConfiguration(
            source: .addonCatalog(AddonCatalogReference(catalogType: "series", catalogID: "top")))))]
        let root = try #require(JSONSerialization.jsonObject(with: FusionWidgetCodec.encode(widgets)) as? [String: Any])
        let widget = try #require((root["widgets"] as? [[String: Any]])?.first)
        let payload = try #require((widget["dataSource"] as? [String: Any])?["payload"] as? [String: Any])
        #expect(payload["addonId"] as? String == "YOUR_ADDON")
        #expect(payload["genre"] == nil)
    }

    @Test func everyKindRoundTripsThroughEncodeAndDecode() throws {
        let widgets: [HomeWidget] = [
            HomeWidget(id: "row", title: "Movies", content: .row(RowConfiguration(
                source: .addonCatalog(AddonCatalogReference(manifestID: "com.example.one", catalogType: "movie", catalogID: "top", genre: "Drama")),
                presentation: WidgetPresentation(aspectRatio: .square, cardStyle: .small, showsRatings: false, showsProviders: true),
                limit: 7, cacheTTL: 90))),
            HomeWidget(id: "hero", title: "Spotlight", hideTitle: true, content: .hero(RowConfiguration(
                source: .traktList(TraktListReference(username: "u", listSlug: "s", listName: "S", traktID: nil)), limit: 8))),
            HomeWidget(id: "tiles", title: "Streaming", content: .collection([
                CollectionItem(id: "n", title: "Netflix", imageAspect: .poster, imageURL: URL(string: "https://example.com/n.png"), sources: [
                    .traktList(TraktListReference(username: "u", listSlug: "films", listName: "Films", traktID: 3)),
                    .addonCatalog(AddonCatalogReference(manifestID: "com.example.one", catalogType: "series", catalogID: "top")),
                    .unsupported(kind: "anilistCatalog"),
                ]),
                CollectionItem(id: "h", title: "Hidden", hideTitle: true, imageAspect: .square),
            ])),
            HomeWidget(id: "continue", title: "Continue Watching", content: .continueWatching),
            HomeWidget(id: "other", title: "Other", content: .row(RowConfiguration(source: .unsupported(kind: "anilistCatalog")))),
        ]
        let result = try FusionWidgetCodec.decode(FusionWidgetCodec.encode(widgets), installed: [])
        #expect(result.widgets == widgets)
        #expect(result.skipped == 0)
    }

    @Test func aNonObjectWidgetIsCountedAsOneSkip() throws {
        let result = try decode(#"{"widgets": [[1, 2], {"id": "ok", "type": "blusion.continueWatching"}]}"#)
        #expect(result.widgets.map(\.id) == ["ok"])
        #expect(result.skipped == 1)
    }

    @Test func aHeroBannerDecodesToABannerWithItsSource() throws {
        let text = #"""
        { "exportType": "fusionWidgets", "exportVersion": 1, "widgets": [
          {"cacheTTL":3600,"dataSource":{"kind":"traktList","payload":{"listName":"The Complete Criterion Collection","listSlug":"the-complete-criterion-collection","traktId":10851163,"username":"TwentyWasHere"}},"id":"trakt.9DA25D7B-518C-43C8-BA43-07EBEBD16078","limit":50,"presentation":{"aspectRatio":"poster","badges":{"providers":false,"ratings":true},"cardStyle":"medium"},"title":"Criterion Collection","type":"hero.banner"}
        ] }
        """#
        let result = try decode(text)
        #expect(result.widgets.map(\.id) == ["trakt.9DA25D7B-518C-43C8-BA43-07EBEBD16078"])
        #expect(result.widgets.map(\.title) == ["Criterion Collection"])
        #expect(result.skipped == 0)

        let widget = try #require(result.widgets.first)
        guard case .banner(let row) = widget.content else {
            Issue.record("hero.banner should decode to a banner")
            return
        }
        #expect(row.limit == 50 && row.cacheTTL == 3600)
        #expect(row.presentation.showsRatings && !row.presentation.showsProviders)
        #expect(row.source == .traktList(TraktListReference(username: "TwentyWasHere", listSlug: "the-complete-criterion-collection",
                                                            listName: "The Complete Criterion Collection", traktID: 10851163)))
    }

    @Test func aHeroBannerRoundTripsAndEncodesItsType() throws {
        let widget = HomeWidget(id: "banner", title: "Featured", content: .banner(RowConfiguration(
            source: .traktList(TraktListReference(username: "u", listSlug: "s", listName: "S", traktID: nil)), limit: 12)))
        let data = try FusionWidgetCodec.encode([widget])
        #expect(String(decoding: data, as: UTF8.self).contains("\"type\" : \"hero.banner\""))
        let result = try FusionWidgetCodec.decode(data, installed: [])
        #expect(result.widgets == [widget])
    }

    @Test func aHeroBannerWithoutASourceIsSkipped() throws {
        let result = try decode(#"{"widgets": [{"id": "bad", "title": "No source", "type": "hero.banner"}, {"id": "ok", "type": "blusion.continueWatching"}]}"#)
        #expect(result.widgets.map(\.id) == ["ok"])
        #expect(result.skipped == 1)
    }

    @Test func aDiscoverWidgetAndBetterPostersSurviveEncodeThenDecode() throws {
        let query = TMDbDiscoverQuery(kind: .series, ordering: .trendingThisWeek, genres: [.init(id: 16, name: "Animation")],
                                      minimumScore: 7, releasedFrom: "2020-01-01")
        let widget = HomeWidget(id: "discover", title: "Animation Series", content: .row(RowConfiguration(
            source: .tmdbDiscover(query), presentation: WidgetPresentation(usesBetterPosters: true))))
        let data = try FusionWidgetCodec.encode([widget])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"blusion.tmdbDiscover\"") && text.contains("\"blusionBetterPosters\""))
        let result = try FusionWidgetCodec.decode(data, installed: [])
        #expect(result.widgets == [widget])
        #expect(result.skipped == 0)
    }

    @Test func aPresentationWithoutBetterPostersWritesNoKeyAndReadsAsOff() throws {
        let plain = HomeWidget(id: "plain", title: "Plain", content: .row(RowConfiguration(source: .tmdbDiscover(TMDbDiscoverQuery()))))
        let text = String(decoding: try FusionWidgetCodec.encode([plain]), as: UTF8.self)
        #expect(!text.contains("blusionBetterPosters"))
        let result = try FusionWidgetCodec.decode(Data(text.utf8), installed: [])
        #expect(result.widgets == [plain])
        let missing = try decode(#"{"widgets": [{"id": "x", "title": "X", "type": "row.classic","#
            + #""presentation": {"aspectRatio": "poster"},"#
            + #""dataSource": {"kind": "blusion.tmdbDiscover", "payload": {"query": {"kind": "series"}}}}]}"#)
        guard case .row(let row) = missing.widgets.first?.content else {
            Issue.record("the row should be kept")
            return
        }
        #expect(row.presentation.usesBetterPosters == false)
        #expect(row.source == .tmdbDiscover(TMDbDiscoverQuery(kind: .series)))
    }

    @Test func theAdultAnimationRowFromTheUsersExportLeavesOutTheFamilyTitles() throws {
        // Two widgets exactly as Fusion exported them. A TMDb list carries an empty payload, so its title is all there is to read.
        let text = #"""
        { "widgets": [
          { "cacheTTL": 1800, "dataSource": { "kind": "tmdbDiscover", "payload": {} }, "hideTitle": false,
            "id": "discover.4A68472A-B3CD-4AEB-A363-C15ED3885518", "limit": 20,
            "presentation": { "aspectRatio": "poster", "badges": { "providers": false, "ratings": true }, "cardStyle": "medium" },
            "title": "Adult Animation", "type": "row.classic" },
          { "cacheTTL": 1800, "dataSource": { "kind": "tmdbDiscover", "payload": {} }, "hideTitle": false,
            "id": "discover.D4983A40-4D81-4290-90C5-27CB01DC03B6", "limit": 20,
            "presentation": { "aspectRatio": "poster", "badges": { "providers": false, "ratings": true }, "cardStyle": "medium" },
            "title": "Popular Animation Movies", "type": "row.classic" } ] }
        """#
        let result = try decode(text)
        #expect(result.skipped == 0)
        let animation = TMDbDiscoverQuery.Named(id: 16, name: "Animation")
        let family = TMDbDiscoverQuery.Named(id: 10751, name: "Family")
        guard case .row(let adult) = result.widgets.first?.content, case .row(let popular) = result.widgets.last?.content else {
            Issue.record("both rows should be kept")
            return
        }
        // An adult animation row names neither films nor shows, so it holds both (see `spansBothKinds`).
        // A saved list is given the keyword and the exclusions its title names, as a list saved before them is.
        let adultKeyword = TMDbDiscoverQuery.Named(id: 161919, name: "adult animation")
        let anime = TMDbDiscoverQuery.Named(id: 210024, name: "anime")
        let hentai = TMDbDiscoverQuery.Named(id: 198385, name: "hentai")
        #expect(adult.source == .tmdbDiscover(TMDbDiscoverQuery(genres: [animation], keywords: [adultKeyword], excludedKeywords: [anime, hentai],
                                                                excludedGenres: [family], spansBothKinds: true)))
        #expect(popular.source == .tmdbDiscover(TMDbDiscoverQuery(genres: [animation])))
    }

    @Test func aBrokenDiscoverQueryReadsAsUnsupported() throws {
        let text = #"""
        { "widgets": [
          { "id": "a", "title": "A", "type": "row.classic",
            "dataSource": { "kind": "blusion.tmdbDiscover", "payload": { "query": "not an object" } } },
          { "id": "b", "title": "B", "type": "row.classic",
            "dataSource": { "kind": "blusion.tmdbDiscover", "payload": {} } },
          { "id": "c", "title": "C", "type": "row.classic",
            "dataSource": { "kind": "blusion.tmdbDiscover", "payload": { "query": { "genres": "animation" } } } } ] }
        """#
        let result = try decode(text)
        #expect(result.skipped == 0, "the rows are kept, with their source unsupported")
        for widget in result.widgets {
            guard case .row(let row) = widget.content else {
                Issue.record("each row should be kept")
                continue
            }
            #expect(row.source == .unsupported(kind: "blusion.tmdbDiscover"))
        }
        #expect(result.widgets.count == 3)
    }
}
// swiftlint:enable line_length
