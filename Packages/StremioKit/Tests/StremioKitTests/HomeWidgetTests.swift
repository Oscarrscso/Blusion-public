import Foundation
import Testing
@testable import StremioKit

@Suite struct HomeWidgetTests {
    private func installed(_ manifestID: String, host: String = "example.com", catalogs: [CatalogDescriptor], enabled: Bool = true) throws -> InstalledAddon {
        let base = try #require(URL(string: "https://\(host)"))
        let manifest = Manifest(id: manifestID, name: manifestID, version: "1", resources: [ResourceDescriptor(name: "catalog")],
                                types: ["movie", "series"], catalogs: catalogs)
        return InstalledAddon(manifestURL: base.appendingPathComponent("manifest.json"), baseURL: base, manifest: manifest, isEnabled: enabled)
    }

    @Test func rowConfigurationClampsItsNumbers() {
        let source = WidgetSource.unsupported(kind: "anything")
        let high = RowConfiguration(source: source, limit: 500, cacheTTL: 900_000)
        #expect(high.limit == 100 && high.cacheTTL == 86_400)
        let low = RowConfiguration(source: source, limit: 0, cacheTTL: -1)
        #expect(low.limit == 1 && low.cacheTTL == 0)
        let defaults = RowConfiguration(source: source)
        #expect(defaults.limit == 20 && defaults.cacheTTL == 3600 && defaults.presentation == WidgetPresentation())
    }

    @Test func presentationDefaultsAreThePosterGrid() {
        let presentation = WidgetPresentation()
        #expect(presentation.aspectRatio == .poster && presentation.cardStyle == .medium)
        #expect(presentation.showsRatings && !presentation.showsProviders)
    }

    @Test func everyContentKindRoundTripsThroughCodable() throws {
        let row = RowConfiguration(
            source: .addonCatalog(AddonCatalogReference(manifestID: "org.example", host: "example.com", catalogType: "movie", catalogID: "top", genre: "Drama")),
            presentation: WidgetPresentation(aspectRatio: .wide, cardStyle: .large, showsRatings: false, showsProviders: true),
            limit: 50, cacheTTL: 60)
        let tiles = [
            CollectionItem(id: "t1", title: "Streaming", imageAspect: .square, imageURL: URL(string: "https://example.com/n.png"),
                           sources: [.traktList(TraktListReference(username: "someone", listSlug: "films", listName: "Films", traktID: 7)),
                                     .unsupported(kind: "anilistCatalog")]),
            CollectionItem(id: "t2", title: "1980s", hideTitle: true),
        ]
        let widgets = [
            HomeWidget(id: "hero", title: "Spotlight", hideTitle: true, content: .hero(row)),
            HomeWidget(id: "row", title: "Row", content: .row(row)),
            HomeWidget(id: "tiles", title: "Tiles", content: .collection(tiles)),
            HomeWidget(id: "continue", title: "Continue Watching", content: .continueWatching),
        ]
        let data = try JSONEncoder().encode(widgets)
        #expect(try JSONDecoder().decode([HomeWidget].self, from: data) == widgets)
    }

    @Test func storedNumbersAreClampedWhenDecoded() throws {
        let row = RowConfiguration(source: .unsupported(kind: "anything"), limit: 10, cacheTTL: 10)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        object["limit"] = 500
        object["cacheTTL"] = -4
        let decoded = try JSONDecoder().decode(RowConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.limit == 100 && decoded.cacheTTL == 0)
    }

    @Test func aReferenceResolvesToTheNamedAddonBeforeAnyOtherMatch() throws {
        let first = try installed("first", host: "one.example.com", catalogs: [CatalogDescriptor(type: "movie", id: "top", name: "One")])
        let named = try installed("named", host: "two.example.com", catalogs: [CatalogDescriptor(type: "movie", id: "top", name: "Two")])
        let reference = AddonCatalogReference(manifestID: "named", catalogType: "movie", catalogID: "top")
        let resolved = try #require(reference.resolve(in: [first, named]))
        #expect(resolved.addon.manifest.id == "named", "the named addon wins even though it comes second")
        #expect(resolved.catalog.name == "Two")

        let fallback = AddonCatalogReference(manifestID: "gone", catalogType: "movie", catalogID: "top")
        #expect(fallback.resolve(in: [first, named])?.addon.manifest.id == "first", "an unknown manifest id falls back to the first match")
        #expect(AddonCatalogReference(catalogType: "movie", catalogID: "top").resolve(in: [first, named])?.addon.manifest.id == "first")
    }

    @Test func disabledAddonsAreNeverResolved() throws {
        let off = try installed("off", catalogs: [CatalogDescriptor(type: "movie", id: "top")], enabled: false)
        let on = try installed("on", catalogs: [CatalogDescriptor(type: "movie", id: "top")])
        let reference = AddonCatalogReference(manifestID: "off", catalogType: "movie", catalogID: "top")
        #expect(reference.resolve(in: [off, on])?.addon.manifest.id == "on")
        #expect(reference.resolve(in: [off]) == nil)
    }

    @Test func aTypeMismatchFallsBackToTheIdAsTheLastResort() throws {
        let shows = try installed("shows", catalogs: [CatalogDescriptor(type: "series", id: "top", name: "Shows")])
        let reference = AddonCatalogReference(manifestID: "shows", catalogType: "movie", catalogID: "top")
        let onlyShows = try #require(reference.resolve(in: [shows]))
        #expect(onlyShows.catalog.type == "series", "the catalog keeps its own type")

        let movies = try installed("movies", catalogs: [CatalogDescriptor(type: "movie", id: "top")])
        #expect(reference.resolve(in: [shows, movies])?.addon.manifest.id == "movies", "an exact type match beats an id-only match")
        #expect(AddonCatalogReference(catalogType: "movie", catalogID: "nothing").resolve(in: [shows, movies]) == nil)
        #expect(AddonCatalogReference(catalogType: "movie", catalogID: "top").resolve(in: []) == nil)
    }

    @Test func aPresentationWrittenBeforeBetterPostersDecodesWithItOff() throws {
        let old = Data(#"{"aspectRatio":"wide","cardStyle":"large","showsRatings":false,"showsProviders":true,"showsRank":true}"#.utf8)
        let presentation = try JSONDecoder().decode(WidgetPresentation.self, from: old)
        #expect(presentation == WidgetPresentation(aspectRatio: .wide, cardStyle: .large, showsRatings: false, showsProviders: true,
            showsRank: true))
        #expect(presentation.usesBetterPosters == false)
        let json = #"{"aspectRatio":"poster","cardStyle":"medium","showsRatings":true,"showsProviders":false,"usesBetterPosters":true}"#
        let on = try JSONDecoder().decode(WidgetPresentation.self, from: Data(json.utf8))
        #expect(on.usesBetterPosters)
    }

    @Test func aTMDbDiscoverSourceRoundTripsAndIsNotTrakt() throws {
        let query = TMDbDiscoverQuery(kind: .series, ordering: .trendingToday, genres: [.init(id: 16, name: "Animation")], minimumVotes: 50)
        let widget = HomeWidget(id: "d", title: "Discover", content: .hero(RowConfiguration(
            source: .tmdbDiscover(query), presentation: WidgetPresentation(usesBetterPosters: true), limit: 8)))
        let decoded = try JSONDecoder().decode(HomeWidget.self, from: JSONEncoder().encode(widget))
        #expect(decoded == widget)
        #expect(WidgetSource.tmdbDiscover(query).usesTrakt == false)
    }
}
