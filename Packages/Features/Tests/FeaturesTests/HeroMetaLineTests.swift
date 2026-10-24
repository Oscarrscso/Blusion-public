import Foundation
import StremioKit
import StremioKitTestSupport
import Testing
@testable import Features

/// The addon's `meta` answer for a movie, as JSON. Fields left nil are left out, as an addon leaves them out.
private func heroLineMeta(_ id: String, name: String, releaseInfo: String? = nil, genres: [String] = [], runtime: String? = nil) -> String {
    var fields: [String: Any] = ["id": id, "type": "movie", "name": name, "genres": genres]
    if let releaseInfo { fields["releaseInfo"] = releaseInfo }
    if let runtime { fields["runtime"] = runtime }
    let data = try? JSONSerialization.data(withJSONObject: ["meta": fields], options: [.sortedKeys])
    return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
}

/// The spotlight's metadata line and the title page's are one line, whichever page asks first, for every kind of catalogue entry.
@MainActor
@Suite struct HeroMetaLineTests {
    /// A movie as a catalogue or list holds it, and the addon's `meta` for it. Each row names a case, so a failure names the movie.
    private struct Movie: Sendable {
        let name: String
        let preview: MetaPreview
        /// The addon's `meta` for the movie, or nil when the addon has none (it answers 404).
        let meta: String?
        /// The genres the line shows: the addon's first two once it has answered, else the catalogue's (the same as the addon's for a
        /// movie it does not answer).
        let shownGenres: [String]
    }

    private static let movies: [Movie] = [
        Movie(name: "Genre names and order differ",
              preview: MetaPreview(id: "tt0000001", type: "movie", name: "Genre Order", releaseInfo: "2014",
                                   genres: ["Science Fiction", "Adventure"]),
              meta: heroLineMeta("tt0000001", name: "Genre Order", releaseInfo: "2014", genres: ["Adventure", "Sci-Fi", "Drama"],
                                 runtime: "169 min"),
              shownGenres: ["Adventure", "Sci-Fi"]),
        Movie(name: "Name only, the Digger case",
              preview: MetaPreview(id: "tt0000002", type: "movie", name: "Digger"),
              meta: heroLineMeta("tt0000002", name: "Digger", releaseInfo: "2011", genres: ["Drama", "Thriller"], runtime: "101 min"),
              shownGenres: ["Drama", "Thriller"]),
        Movie(name: "Year text and runtime differ",
              preview: MetaPreview(id: "tt0000003", type: "movie", name: "Year Text", releaseInfo: "2026-", runtime: "90 min"),
              meta: heroLineMeta("tt0000003", name: "Year Text", releaseInfo: "2026", genres: ["Comedy"], runtime: "95 min"),
              shownGenres: ["Comedy"]),
        Movie(name: "Same data on both",
              preview: MetaPreview(id: "tt0000004", type: "movie", name: "Same Data", releaseInfo: "2019", genres: ["Drama"],
                                   runtime: "120 min"),
              meta: heroLineMeta("tt0000004", name: "Same Data", releaseInfo: "2019", genres: ["Drama"], runtime: "120 min"),
              shownGenres: ["Drama"]),
        Movie(name: "No addon answers",
              preview: MetaPreview(id: "tt0000005", type: "movie", name: "No Answer", releaseInfo: "1999", genres: ["Western"],
                                   runtime: "120 min"),
              meta: nil,
              shownGenres: ["Western"]),
        Movie(name: "Catalogue score and a different genre list",
              preview: MetaPreview(id: "tt0000006", type: "movie", name: "Catalogue Score", releaseInfo: "1984", imdbRating: 6.2,
                                   genres: ["Horror", "Mystery", "Thriller"]),
              meta: heroLineMeta("tt0000006", name: "Catalogue Score", releaseInfo: "1984", genres: ["Horror", "Slasher"],
                                 runtime: "88 min"),
              shownGenres: ["Horror", "Slasher"]),
        Movie(name: "No year in the catalogue",
              preview: MetaPreview(id: "tt0000007", type: "movie", name: "No Year", genres: ["Drama"]),
              meta: heroLineMeta("tt0000007", name: "No Year", releaseInfo: "2019", genres: ["Drama", "Romance"], runtime: "100 min"),
              shownGenres: ["Drama", "Romance"]),
    ]

    /// Services whose one addon answers `meta` for the movies' ids and every other request with 404, so nothing leaves the machine. The
    /// title page's iTunes lookup and the rest fail the way they do offline.
    private func makeServices(for movies: [Movie]) async throws -> AppServices {
        let answers = Dictionary(uniqueKeysWithValues: movies.compactMap { movie in movie.meta.map { (movie.preview.id, $0) } })
        let transport = StubTransport { request, _ in
            if request.url?.path.contains("/meta/") == true, let id = request.url?.deletingPathExtension().lastPathComponent,
               let body = answers[id] {
                return StubTransport.response(Data(body.utf8), for: request)
            }
            return StubTransport.response(Data("{}".utf8), status: 404, for: request)
        }
        let manifest = Manifest(id: "test.heroline", name: "Hero line", version: "1", resources: [ResourceDescriptor(name: "meta")],
                                types: ["movie"])
        let (registry, client) = try await makeStubbedRegistry(manifests: [manifest], transport: transport)
        return AppServices(registry: registry, client: client)
    }

    /// The spotlight's line for `movie` and the title page's line, which must be the same at this moment. Returns the spotlight's.
    private func expectSameLine(_ movie: Movie, _ services: AppServices, _ model: DetailViewModel, _ moment: String) -> [String?] {
        let spotlight = services.heroMeta.parts(for: movie.preview, certification: nil, ratings: services.posterRatings)
        let page = model.heroMetaLine
        #expect(spotlight == page, "\(movie.name), \(moment): the spotlight shows \(spotlight), the title page \(page)")
        return spotlight
    }

    /// Once the addon has answered, the line's genres are the addon's first two; a movie it does not answer keeps the catalogue's line.
    private func expectGenres(_ movie: Movie, _ line: [String?], _ moment: String) {
        let genres = [line[1], line[2]].compactMap { $0 }
        #expect(genres == movie.shownGenres, "\(movie.name), \(moment): the genres are \(genres)")
        if movie.meta == nil {
            #expect(line == DetailViewModel.heroMetaParts(for: movie.preview, certification: nil),
                    "\(movie.name), \(moment): the line is the catalogue's, as the addon has none")
        }
    }

    @Test func theLineIsTheSameWhenTheSpotlightAsksFirst() async throws {
        for movie in Self.movies {
            let services = try await makeServices(for: [movie])
            let model = DetailViewModel(preview: movie.preview, services: services)
            _ = expectSameLine(movie, services, model, "before anything loaded")
            await services.heroMeta.load(for: movie.preview)
            expectGenres(movie, expectSameLine(movie, services, model, "after the spotlight's lookup"), "after the spotlight's lookup")
            await model.load()
            let shown = expectSameLine(movie, services, model, "after the title page loaded")
            expectGenres(movie, shown, "after the title page loaded")
            expectGenres(movie, model.heroMetaLine, "on the title page after it loaded")
        }
    }

    @Test func theLineIsTheSameWhenTheTitlePageLoadsFirst() async throws {
        for movie in Self.movies {
            let services = try await makeServices(for: [movie])
            let model = DetailViewModel(preview: movie.preview, services: services)
            _ = expectSameLine(movie, services, model, "before anything loaded")
            await model.load()
            _ = expectSameLine(movie, services, model, "after the title page loaded")
            await services.heroMeta.load(for: movie.preview)
            let shown = expectSameLine(movie, services, model, "after the spotlight's lookup")
            expectGenres(movie, shown, "after the spotlight's lookup")
            expectGenres(movie, model.heroMetaLine, "on the title page after the spotlight asked")
        }
    }
}
