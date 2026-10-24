#if canImport(CryptoKit)
import Foundation
import Testing
@testable import Features

@Suite struct TraktWebAuthenticationTests {
    @Test func challengeMatchesThePublishedPKCEExample() {
        // RFC 7636, Appendix B: URL-safe SHA-256 challenge without padding.
        #expect(TraktWebAuthentication.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedProofUsesTheAllowedVerifierAlphabetAndChallengeLength() {
        let proof = TraktWebAuthentication.proof()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect(proof.verifier.count == 64)
        #expect(proof.verifier.unicodeScalars.allSatisfy(allowed.contains))
        #expect(proof.challenge.count == 43)
        #expect(!proof.challenge.contains("=") && !proof.challenge.contains("+") && !proof.challenge.contains("/"))
    }
}
#endif
