import Foundation

#if canImport(CryptoKit)
import CryptoKit

enum TraktWebAuthentication {
    static func proof() -> (verifier: String, challenge: String) {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var random = SystemRandomNumberGenerator()
        let verifier = String((0..<64).map { _ in alphabet.randomElement(using: &random)! })
        return (verifier, challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif

#if canImport(UIKit)
import AuthenticationServices
import SwiftUI

extension TraktWebAuthentication {
    @MainActor
    static func authenticate(using session: WebAuthenticationSession, url: URL, redirectURI: String) async throws -> URL {
        guard let redirect = URL(string: redirectURI), let scheme = redirect.scheme?.lowercased() else {
            throw AuthenticationError.invalidRedirectURI
        }
        let callback: ASWebAuthenticationSession.Callback
        if scheme == "https", let host = redirect.host {
            callback = .https(host: host, path: redirect.path.isEmpty ? "/" : redirect.path)
        } else if scheme != "https", scheme != "http", scheme != "urn" {
            callback = .customScheme(scheme)
        } else {
            throw AuthenticationError.invalidRedirectURI
        }
        return try await session.authenticate(using: url, callback: callback, preferredBrowserSession: .shared,
                                              additionalHeaderFields: [:])
    }

    enum AuthenticationError: LocalizedError {
        case invalidRedirectURI

        var errorDescription: String? {
            "Trakt browser sign-in needs a registered HTTPS or app callback URL."
        }
    }
}
#endif
