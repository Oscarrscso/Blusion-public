import Foundation
import Testing
import StremioKitTestSupport
@testable import StremioKit

@Suite struct TraktPKCETests: Sendable {
    private let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    private let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    private let redirect = "blusion://trakt/callback"
    private let token = #"{"access_token":"access","refresh_token":"refresh","expires_in":604800,"created_at":1700000000}"#

    private func callback(for url: URL, state: String? = nil) throws -> URL {
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let nonce = try #require(state ?? query.first(where: { $0.name == "state" })?.value)
        var callback = URLComponents(string: redirect)!
        callback.queryItems = [URLQueryItem(name: "code", value: "approved-code"), URLQueryItem(name: "state", value: nonce)]
        return callback.url!
    }

    @Test func clientIDOnlySignInAndRefreshNeverSendASecret() async throws {
        let transport = StubTransport { request, call in
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data("{}".utf8)) as? [String: String]
            #expect(body?["client_secret"] == nil)
            if request.url?.path == "/oauth/token" {
                #expect(body?["redirect_uri"] == redirect)
                if call == 1 {
                    #expect(body?["code_verifier"] == verifier && body?["code"] == "approved-code")
                    #expect(body?["grant_type"] == "authorization_code")
                    return StubTransport.response(Data(token.utf8), for: request)
                }
                #expect(body?["grant_type"] == "refresh_token" && body?["refresh_token"] == "refresh")
                let payload = #"{"access_token":"renewed","refresh_token":"next-refresh","expires_in":604800,"created_at":1800000000}"#
                return StubTransport.response(Data(payload.utf8), for: request)
            }
            if request.url?.path == "/oauth/revoke" {
                #expect(body?["token"] == "renewed")
                return StubTransport.response(Data("{}".utf8), for: request)
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed")
            return StubTransport.response(Data("[]".utf8), for: request)
        }
        let secrets = InMemorySecretStore()
        let account = TraktAccount(settings: InMemorySettingsStore(PlaybackSettings(traktClientID: "client")), secrets: secrets,
                                   transport: transport, now: { Date(timeIntervalSince1970: 1800000001) })
        let url = try await account.beginPKCESignIn(redirectURI: redirect, codeVerifier: verifier, codeChallenge: challenge)
        #expect(url.host == "auth.trakt.tv")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first(where: { $0.name == "code_challenge" })?.value == challenge)
        #expect(query.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
        try await account.finishPKCESignIn(callbackURL: callback(for: url))
        #expect(await account.isSignedIn())
        let stored = await secrets.snapshot
        #expect(stored[TraktAccount.Keys.token]?.contains(verifier) == false)
        #expect(try await account.watchlist().isEmpty)
        await account.signOut()
        #expect(!(await account.isSignedIn()))
        #expect(transport.requests.map { $0.url?.path } == ["/oauth/token", "/oauth/token", "/sync/watchlist", "/oauth/revoke"])
    }

    @Test func mismatchedOrCancelledCallbacksCannotExchangeTokens() async throws {
        let transport = StubTransport(data: Data(token.utf8))
        let account = TraktAccount(settings: InMemorySettingsStore(PlaybackSettings(traktClientID: "client")),
                                   secrets: InMemorySecretStore(), transport: transport)
        let url = try await account.beginPKCESignIn(redirectURI: redirect, codeVerifier: verifier, codeChallenge: challenge)
        await #expect(throws: TraktAccountError.invalidCallback) {
            try await account.finishPKCESignIn(callbackURL: callback(for: url, state: "wrong-state"))
        }
        let correct = try callback(for: url)
        let wrongHost = URL(string: correct.absoluteString.replacingOccurrences(of: "//trakt/", with: "//other/"))!
        await #expect(throws: TraktAccountError.invalidCallback) { try await account.finishPKCESignIn(callbackURL: wrongHost) }
        await account.cancelPKCESignIn()
        await #expect(throws: TraktAccountError.invalidCallback) { try await account.finishPKCESignIn(callbackURL: correct) }
        #expect(transport.callCount == 0)
        #expect(!(await account.isSignedIn()))
    }

    @Test func changedAccountRejectsAnOlderSignInBeforeExchangingTheCode() async throws {
        let transport = StubTransport(data: Data(token.utf8))
        let settings = InMemorySettingsStore(PlaybackSettings(traktClientID: "client"))
        let account = TraktAccount(settings: settings, secrets: InMemorySecretStore(), transport: transport)
        let url = try await account.beginPKCESignIn(redirectURI: redirect, codeVerifier: verifier, codeChallenge: challenge)
        await settings.save(PlaybackSettings(traktClientID: "different-client"))
        await #expect(throws: TraktAccountError.credentialsChanged) {
            try await account.finishPKCESignIn(callbackURL: callback(for: url))
        }
        #expect(transport.callCount == 0)
        #expect(!(await account.isSignedIn()))
    }
}
