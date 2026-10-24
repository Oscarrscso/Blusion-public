import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

/// One movie catalog, `top`, with genres. A genre's page leads with that genre's own movie, then a movie every genre shares.
private let catalogAddon = Manifest(id: "test.cinemeta", name: "Cinemeta", version: "1", resources: [ResourceDescriptor(name: "catalog")],
                                    types: ["movie"], catalogs: [CatalogDescriptor(type: "movie", id: "top", name: "Popular",
                                                                                   extra: [ExtraDescriptor(name: "genre", options: ["Action", "Drama"])])])

/// Genre tiles on Home take a photo from a title in their genre, a different title for each tile.
@MainActor
@Suite struct GenreTilePhotosTests {
    private func movie(_ id: String, background: Bool = true) -> MetaPreview {
        MetaPreview(id: id, type: "movie", name: id, poster: URL(string: "https://img.example.com/\(id)-poster.jpg"),
                    background: background ? URL(string: "https://img.example.com/\(id)-wide.jpg") : nil)
    }

    private func reference(genre: String?) -> AddonCatalogReference {
        AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "movie", catalogID: "top", genre: genre)
    }

    private func tile(_ id: String, genre: String?, aspect: WidgetPresentation.AspectRatio = .wide, image: URL? = nil) -> CollectionItem {
        CollectionItem(id: id, title: id, imageAspect: aspect, imageURL: image, sources: [.addonCatalog(reference(genre: genre))])
    }

    @Test func aTileStandsForAGenreWhenEverySourceIsOneAndItHasNoPicture() {
        #expect(HomeViewModel.isGenreTile(tile("a", genre: "Action")))
        #expect(!HomeViewModel.isGenreTile(tile("a", genre: nil)), "a whole catalog")
        #expect(!HomeViewModel.isGenreTile(tile("a", genre: "Action", image: URL(string: "https://img.example.com/own.jpg"))), "its own picture")
        let discover = CollectionItem(title: "Animation", sources: [.tmdbDiscover(TMDbDiscoverQuery(genres: [.init(id: 16, name: "Animation")]))])
        #expect(HomeViewModel.isGenreTile(discover))
        #expect(!HomeViewModel.isGenreTile(CollectionItem(title: "Empty")))
    }

    @Test func eachTileTakesATitleNoEarlierTileShows() {
        let tiles = [tile("action", genre: "Action"), tile("drama", genre: "Drama"), tile("poster", genre: "Comedy", aspect: .poster),
                     tile("bare", genre: "War")]
        let items = ["action": [movie("shared"), movie("a1")], "drama": [movie("shared"), movie("noWide", background: false), movie("d1")],
                     "poster": [movie("shared"), movie("c1")], "bare": [movie("shared")]]
        let photos = HomeViewModel.tilePhotos(for: tiles, items: items)
        #expect(photos["action"] == URL(string: "https://img.example.com/shared-wide.jpg"))
        #expect(photos["drama"] == URL(string: "https://img.example.com/d1-wide.jpg"), "a wide tile skips a title without a backdrop")
        #expect(photos["poster"] == URL(string: "https://img.example.com/c1-poster.jpg"), "a poster tile takes the poster")
        #expect(photos["bare"] == nil, "nothing left to show")
    }

    @Test func homeGivesEveryGenreTileAPhoto() async throws {
        let transport = StubTransport { request, _ in
            let path = request.url?.path ?? ""
            let lead = path.contains("genre=Action") ? "tt-action" : path.contains("genre=Drama") ? "tt-drama" : "tt-all"
            let metas = [lead, "tt-shared"].map { id in
                #"{"id":"\#(id)","type":"movie","name":"\#(id)","background":"https://img.example.com/\#(id)-wide.jpg"}"#
            }
            return StubTransport.response(Data(#"{"metas":[\#(metas.joined(separator: ","))]}"#.utf8), for: request)
        }
        let (registry, client) = try await makeStubbedRegistry(manifests: [catalogAddon], transport: transport)
        let settings = InMemorySettingsStore()
        let genres = HomeWidget(id: "g", title: "Genres", content: .collection([tile("action", genre: "Action"), tile("drama", genre: "Drama"),
                                                                                tile("all", genre: nil)]))
        let services = AppServices(registry: registry, client: client, settings: settings,
                                   widgets: InMemoryWidgetStore([genres, HomeWidget(id: "cw", title: "Continue", content: .continueWatching)]),
                                   widgetContent: WidgetContentService(registry: registry, client: client, settings: settings))
        let model = HomeViewModel(services: services)
        await model.load()
        func photo(_ tile: CollectionItem) -> URL? { model.tilePhotos[HomeViewModel.tilePhotoKey(widgetID: "g", tile: tile)] }
        #expect(model.tilePhotos[HomeViewModel.tilePhotoKey(widgetID: "g", tile: tile("action", genre: "Action"))] == URL(string: "https://img.example.com/tt-action-wide.jpg"))
        #expect(photo(tile("drama", genre: "Drama")) == URL(string: "https://img.example.com/tt-drama-wide.jpg"))
        #expect(photo(tile("all", genre: nil)) == nil, "a tile without a genre keeps its colours")
        let saved = try #require(await services.widgets.load()?.first { $0.id == "g" })
        #expect(saved == genres, "the photos are not saved into the widget")
        #expect(photo(tile("action", genre: "Comedy")) == nil, "a tile edited to another genre does not keep the old genre's photo")
    }
}
