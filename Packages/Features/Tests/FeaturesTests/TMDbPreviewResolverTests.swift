import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

@MainActor
@Suite struct TMDbPreviewResolverTests {
    private func services(token: String?, transport: StubTransport) -> AppServices {
        let client = makeClient(transport, retries: 0)
        let registry = AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client)
        var settings = PlaybackSettings()
        settings.tmdbReadToken = token
        return AppServices(registry: registry, client: client, settings: InMemorySettingsStore(settings))
    }

    @Test func aTMDbNumberIsReadFromEitherFormAndAnyOtherIDIsLeftAlone() {
        let film = TMDbPreviewResolver.tmdbIdentity(of: MetaPreview(id: "tmdb:354857", type: "movie", name: "Regular Show: The Movie"))
        #expect(film?.tmdbID == 354857 && film?.mediaType == "movie")
        let show = TMDbPreviewResolver.tmdbIdentity(of: MetaPreview(id: "tmdb:1399", type: "series", name: "S"))
        #expect(show?.tmdbID == 1399 && show?.mediaType == "tv")
        let typed = TMDbPreviewResolver.tmdbIdentity(of: MetaPreview(id: "tmdb:tv:1399", type: "series", name: "S"))
        #expect(typed?.tmdbID == 1399 && typed?.mediaType == "tv")
        for id in ["tt4920274", "tmdb:", "tmdb:abc", "tmdb:0", "tmdb:person:12", "kitsu:1"] {
            #expect(TMDbPreviewResolver.tmdbIdentity(of: MetaPreview(id: id, type: "movie", name: "X")) == nil, "\(id) is not a title's TMDb number")
        }
        #expect(TMDbPreviewResolver.tmdbIdentity(of: MetaPreview(id: "tmdb:5", type: "channel", name: "X")) == nil, "a bare number needs a type")
    }

    @Test func aTitleUnderItsTMDbNumberOpensUnderItsIMDbID() async {
        let transport = StubTransport(data: Data(#"{"id":354857,"imdb_id":"tt4920274"}"#.utf8))
        let preview = MetaPreview(id: "tmdb:354857", type: "movie", name: "Regular Show: The Movie", poster: URL(string: "https://e.com/p.jpg"))
        #expect(TMDbPreviewResolver.readyPreview(for: preview) == nil, "it must be looked up first")
        let resolved = await TMDbPreviewResolver.resolve(preview, services: services(token: "token", transport: transport))
        #expect(resolved.id == "tt4920274" && resolved.type == "movie" && resolved.name == preview.name && resolved.poster == preview.poster)
        #expect(transport.requests.first?.url?.path.hasSuffix("/movie/354857/external_ids") == true)
        #expect(TMDbPreviewResolver.readyPreview(for: preview)?.id == "tt4920274", "looked up once a session")
        #expect(TMDbPreviewResolver.readyPreview(for: MetaPreview(id: "tmdb:354857", type: "series", name: "Another")) == nil,
                "a series with the same number is another title")
    }

    @Test func withoutATokenOrAnIMDbIDTheTitleOpensAsItCame() async {
        let none = StubTransport(data: Data(#"{"id":1,"imdb_id":null}"#.utf8))
        let first = MetaPreview(id: "tmdb:111111", type: "movie", name: "No IMDb")
        #expect(await TMDbPreviewResolver.resolve(first, services: services(token: "token", transport: none)) == first)
        let untouched = StubTransport(data: Data())
        let second = MetaPreview(id: "tmdb:222222", type: "movie", name: "No token")
        #expect(await TMDbPreviewResolver.resolve(second, services: services(token: nil, transport: untouched)) == second)
        #expect(untouched.callCount == 0, "nothing is asked without a token")
        let imdb = MetaPreview(id: "tt0133093", type: "movie", name: "The Matrix")
        #expect(TMDbPreviewResolver.readyPreview(for: imdb) == imdb, "an IMDb id opens at once")
    }
}
