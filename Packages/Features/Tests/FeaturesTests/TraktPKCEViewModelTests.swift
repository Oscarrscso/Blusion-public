#if canImport(CryptoKit)
import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

@MainActor
@Suite struct TraktPKCEViewModelTests {
    @Test func connectingWithOnlyAClientIDImportsWatchLaterAndCollection() async throws {
        let transport = StubTransport { request, _ in
            if request.url?.path == "/oauth/token" {
                let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
                #expect(body["client_secret"] == nil && body["code_verifier"] != nil)
                let payload = #"{"access_token":"access","refresh_token":"refresh","expires_in":604800,"created_at":1700000000}"#
                return StubTransport.response(Data(payload.utf8), for: request)
            }
            if request.url?.path == "/sync/watchlist" {
                return StubTransport.response(Data(#"[{"movie":{"title":"Watch later","ids":{"imdb":"tt1"}}}]"#.utf8), for: request)
            }
            if request.url?.path == "/sync/collection/shows" {
                return StubTransport.response(Data(#"[{"show":{"title":"Library show","ids":{"imdb":"tt2"}}}]"#.utf8), for: request)
            }
            if request.url?.path == "/sync/last_activities" {
                return StubTransport.response(Data(#"{"movies":{"watchlisted_at":"2024-01-01T00:00:00.000Z"}}"#.utf8), for: request)
            }
            return StubTransport.response(Data("[]".utf8), for: request)
        }
        let settings = InMemorySettingsStore(PlaybackSettings(traktClientID: "test-client"))
        let secrets = InMemorySecretStore()
        let account = TraktAccount(settings: settings, secrets: secrets, transport: transport,
                                   now: { Date(timeIntervalSince1970: 1700000001) })
        let client = makeClient(StubTransport(data: Data()))
        let registry = AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client)
        let services = AppServices(registry: registry, client: client, settings: settings, traktAccount: account)
        let model = TraktAccountViewModel(services: services)
        await model.load()
        #expect(await settings.load().traktClientID == "test-client" && model.canSignIn)
        await model.startPKCESignIn()
        #expect(model.errorMessage == nil && transport.callCount == 0)
        let authorizeURL = try #require(model.authorizationURL)
        let state = try #require(URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value)
        var callback = URLComponents(string: TraktAccountViewModel.redirectURI)!
        callback.queryItems = [URLQueryItem(name: "code", value: "approved"), URLQueryItem(name: "state", value: state)]
        await model.finishPKCESignIn(callbackURL: callback.url!)
        #expect(model.isSignedIn && model.errorMessage == nil && model.authorizationURL == nil)
        #expect(Set(await services.library.all().map(\.id)) == ["movie/tt1", "series/tt2"])
        #expect(await services.progress.all().isEmpty)
        #expect(transport.requests.filter { $0.httpMethod == "POST" }.map { $0.url?.path } == ["/oauth/token"])
        await model.load()
        #expect(model.isSignedIn)
    }
}
#endif
