import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

@Suite struct DefaultWidgetsTests {
    private func installed(_ manifest: Manifest, host: String, enabled: Bool = true) throws -> InstalledAddon {
        let base = try #require(URL(string: "https://\(host)"))
        return InstalledAddon(manifestURL: base.appendingPathComponent("manifest.json"), baseURL: base, manifest: manifest, isEnabled: enabled)
    }

    /// `movie/top` (three genres, browsable), `series/top` (one genre, browsable), `movie/search-only` (needs a search term, so not browsable).
    private func cinemeta(enabled: Bool = true) throws -> InstalledAddon {
        try installed(try ResponseDecoder.manifest(from: Fixture.data("manifests/10-cinemeta-like.json")), host: "cinemeta.example.com", enabled: enabled)
    }

    private func manifest(_ id: String, catalogs: [CatalogDescriptor]) -> Manifest {
        Manifest(id: id, name: id, version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie", "series"], catalogs: catalogs)
    }

    private func genres(_ count: Int) -> ExtraDescriptor {
        ExtraDescriptor(name: "genre", options: (1...count).map { "Genre \($0)" })
    }

    private func configuration(_ widget: HomeWidget) -> RowConfiguration? {
        switch widget.content {
        case .row(let config), .hero(let config), .banner(let config): return config
        case .collection, .continueWatching, .unsupported: return nil
        }
    }

    private func tiles(_ widget: HomeWidget) -> [CollectionItem]? {
        if case .collection(let tiles) = widget.content { return tiles }
        return nil
    }

    @Test func theFixtureGivesSpotlightContinueAndOneRowPerBrowsableCatalog() throws {
        let widgets = DefaultWidgets.make(for: [try cinemeta()])
        #expect(widgets.map(\.id) == ["auto.hero", "auto.continue", "auto.row.org.example.cinemeta.movie.top", "auto.row.org.example.cinemeta.series.top"])
        #expect(widgets.map(\.title) == ["Spotlight", "Continue", "Popular Movies", "Popular Series"])

        let hero = try #require(configuration(widgets[0]))
        #expect(widgets[0].hideTitle && hero.limit == 8)
        #expect(hero.source == .addonCatalog(AddonCatalogReference(manifestID: "org.example.cinemeta", host: "cinemeta.example.com", catalogType: "movie",
            catalogID: "top")))
        #expect(widgets[1].content == .continueWatching)

        let movies = try #require(configuration(widgets[2]))
        #expect(movies.limit == 20 && movies.presentation == WidgetPresentation(), "automatic rows show ratings; Settings can turn them off everywhere")
        #expect(movies.source == .addonCatalog(AddonCatalogReference(manifestID: "org.example.cinemeta", host: "cinemeta.example.com", catalogType: "movie",
            catalogID: "top")))
        let shows = try #require(configuration(widgets[3]))
        #expect(shows.source == .addonCatalog(AddonCatalogReference(manifestID: "org.example.cinemeta", host: "cinemeta.example.com", catalogType: "series",
            catalogID: "top")))
    }

    @Test func noAddonsOrOnlyStreamAddonsGiveNoLayout() throws {
        #expect(DefaultWidgets.make(for: []).isEmpty)
        let streamOnly = try installed(try ResponseDecoder.manifest(from: Fixture.data("manifests/11-stream-only.json")), host: "streams.example.com")
        #expect(DefaultWidgets.make(for: [streamOnly]).isEmpty)
    }

    @Test func disabledAddonsAreIgnored() throws {
        #expect(DefaultWidgets.make(for: [try cinemeta(enabled: false)]).isEmpty)
        let other = try installed(manifest("other", catalogs: [CatalogDescriptor(type: "movie", id: "films", name: "Films")]), host: "other.example.com")
        let widgets = DefaultWidgets.make(for: [try cinemeta(enabled: false), other])
        #expect(widgets.map(\.id) == ["auto.hero", "auto.continue", "auto.row.other.movie.films"])
    }

    @Test func theLayoutIsTheSameEveryTimeAndDoesNotDependOnInstallIdentity() throws {
        let addon = try cinemeta()
        #expect(DefaultWidgets.make(for: [addon]) == DefaultWidgets.make(for: [addon]))
        #expect(DefaultWidgets.make(for: [addon]) == DefaultWidgets.make(for: [try cinemeta()]), "a fresh install gets the same ids")
    }

    @Test func rowsFollowTheUsersAddonOrder() throws {
        let x = try installed(manifest("x.addon", catalogs: [CatalogDescriptor(type: "movie", id: "a", name: "Alpha")]), host: "x.example.com")
        let y = try installed(manifest("y.addon", catalogs: [CatalogDescriptor(type: "series", id: "b", name: "Beta")]), host: "y.example.com")
        #expect(DefaultWidgets.make(for: [x, y]).dropFirst(2).map(\.title) == ["Alpha Movies", "Beta Series"])
        #expect(DefaultWidgets.make(for: [y, x]).dropFirst(2).map(\.title) == ["Beta Series", "Alpha Movies"])
    }

    @Test func theSpotlightPrefersAMovieCatalog() throws {
        let shows = try installed(manifest("shows", catalogs: [CatalogDescriptor(type: "series", id: "top", name: "Shows")]), host: "shows.example.com")
        let films = try installed(manifest("films", catalogs: [CatalogDescriptor(type: "movie", id: "top", name: "Films")]), host: "films.example.com")
        let withMovies = DefaultWidgets.make(for: [shows, films])
        #expect(try #require(configuration(withMovies[0])).source == .addonCatalog(AddonCatalogReference(manifestID: "films", host: "films.example.com",
            catalogType: "movie", catalogID: "top")))

        let noMovies = DefaultWidgets.make(for: [shows])
        #expect(try #require(configuration(noMovies[0])).source == .addonCatalog(AddonCatalogReference(manifestID: "shows", host: "shows.example.com",
            catalogType: "series", catalogID: "top")))
    }

    @Test func aGenreRowSitsAfterTheSecondRowAndOffersTwelveTiles() throws {
        let addon = try installed(manifest("multi", catalogs: [
            CatalogDescriptor(type: "movie", id: "a", name: "A"),
            CatalogDescriptor(type: "movie", id: "b", name: "B", extra: [genres(15)]),
            CatalogDescriptor(type: "series", id: "c", name: "C"),
        ]), host: "multi.example.com")
        let widgets = DefaultWidgets.make(for: [addon])
        #expect(widgets.map(\.id) == ["auto.hero", "auto.continue", "auto.row.multi.movie.a", "auto.row.multi.movie.b", "auto.genres", "auto.row.multi.series.c"])

        let browse = try #require(widgets.first { $0.id == "auto.genres" })
        #expect(browse.title == "Browse by Genre" && browse.hideTitle == false)
        let items = try #require(tiles(browse))
        #expect(items.count == 12, "the first twelve genres")
        #expect(items[0].id == "auto.genre.Genre 1" && items[0].title == "Genre 1" && items[0].imageAspect == .wide && items[0].imageURL == nil)
        #expect(items[0].hideTitle == false)
        #expect(items[0].sources == [.addonCatalog(AddonCatalogReference(manifestID: "multi", host: "multi.example.com", catalogType: "movie", catalogID: "b",
            genre: "Genre 1"))])
    }

    @Test func theGenreRowGoesLastWhenThereAreFewerThanTwoRows() throws {
        let addon = try installed(manifest("one", catalogs: [CatalogDescriptor(type: "movie", id: "a", name: "A", extra: [genres(4)])]), host: "one.example.com")
        #expect(DefaultWidgets.make(for: [addon]).map(\.id) == ["auto.hero", "auto.continue", "auto.row.one.movie.a", "auto.genres"])
        #expect(DefaultWidgets.make(for: [addon], maxRows: 0).map(\.id) == ["auto.hero", "auto.continue", "auto.genres"])
    }

    @Test func theGenreRowNeedsAtLeastFourGenresFromTheFirstCatalogThatHasThem() throws {
        let addon = try installed(manifest("picky", catalogs: [
            CatalogDescriptor(type: "movie", id: "few", name: "Few", extra: [genres(3)]),
            CatalogDescriptor(type: "movie", id: "four", name: "Four", extra: [genres(4)]),
            CatalogDescriptor(type: "movie", id: "many", name: "Many", extra: [genres(9)]),
        ]), host: "picky.example.com")
        let browse = try #require(DefaultWidgets.make(for: [addon]).first { $0.id == "auto.genres" })
        let items = try #require(tiles(browse))
        #expect(items.map(\.title) == ["Genre 1", "Genre 2", "Genre 3", "Genre 4"], "the catalog with four genres, not the one with nine")
        #expect(DefaultWidgets.make(for: [try cinemeta()]).contains { $0.id == "auto.genres" } == false, "three genres are not enough")
    }

    @Test func maxRowsCapsTheRowsButNotTheGenreRow() throws {
        let addon = try installed(manifest("capped", catalogs: [
            CatalogDescriptor(type: "movie", id: "a", name: "A"),
            CatalogDescriptor(type: "movie", id: "b", name: "B", extra: [genres(5)]),
            CatalogDescriptor(type: "movie", id: "c", name: "C"),
        ]), host: "capped.example.com")
        #expect(DefaultWidgets.make(for: [addon], maxRows: 1).map(\.id) == ["auto.hero", "auto.continue", "auto.row.capped.movie.a", "auto.genres"])

        let many = try installed(manifest("many", catalogs: (1...16).map { CatalogDescriptor(type: "movie", id: "c\($0)", name: "Catalog \($0)") }),
                                 host: "many.example.com")
        let widgets = DefaultWidgets.make(for: [many])
        #expect(widgets.count == 2 + 14, "fourteen rows by default")
        #expect(!widgets.contains { $0.id == "auto.genres" })
    }

    @Test func rowTitlesAddTheTypeWordUnlessTheNameHasIt() {
        #expect(DefaultWidgets.rowTitle(catalogName: "Popular", type: "movie") == "Popular Movies")
        #expect(DefaultWidgets.rowTitle(catalogName: "Netflix Movies", type: "movie") == "Netflix Movies")
        #expect(DefaultWidgets.rowTitle(catalogName: "netflix MOVIES", type: "MOVIE") == "netflix MOVIES", "any case")
        #expect(DefaultWidgets.rowTitle(catalogName: "Popular", type: "series") == "Popular Series")
        #expect(DefaultWidgets.rowTitle(catalogName: "Sports", type: "tv") == "Sports Live TV")
        #expect(DefaultWidgets.rowTitle(catalogName: "Live TV Channels", type: "tv") == "Live TV Channels")
        #expect(DefaultWidgets.rowTitle(catalogName: "Kids", type: "channel") == "Kids Channels")
        #expect(DefaultWidgets.rowTitle(catalogName: "Night", type: "anime") == "Night Anime")
        #expect(DefaultWidgets.rowTitle(catalogName: "Docs", type: "documentary") == "Docs Documentary", "other types are capitalised")
        #expect(DefaultWidgets.rowTitle(catalogName: "  Top  ", type: "movie") == "Top Movies", "the name is trimmed")
        #expect(DefaultWidgets.rowTitle(catalogName: "Top", type: "") == "Top")
    }

    @Test func aManifestInstalledTwiceContributesEachRowOnce() throws {
        let first = try cinemeta()
        let second = try installed(try ResponseDecoder.manifest(from: Fixture.data("manifests/10-cinemeta-like.json")), host: "mirror.example.com")
        let widgets = DefaultWidgets.make(for: [first, second])
        #expect(widgets.map(\.id) == DefaultWidgets.make(for: [first]).map(\.id), "the first install's rows, once each")
        #expect(configuration(widgets[2])?.source == .addonCatalog(AddonCatalogReference(manifestID: "org.example.cinemeta", host: "cinemeta.example.com",
            catalogType: "movie", catalogID: "top")))
    }
}
