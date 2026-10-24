import Foundation
import Testing
@testable import StremioKit

struct NormaliseCase: Sendable, CustomTestStringConvertible {
    var input: String
    var manifest: String
    var base: String
    var testDescription: String { input }
}

private let cases: [NormaliseCase] = [
    .init(input: "stremio://v3-cinemeta.strem.io/manifest.json", manifest: "https://v3-cinemeta.strem.io/manifest.json", base: "https://v3-cinemeta.strem.io"),
    .init(input: "stremio://192.168.1.5:7000/manifest.json", manifest: "http://192.168.1.5:7000/manifest.json", base: "http://192.168.1.5:7000"),
    .init(input: "stremio://nas.local:7000/abc/manifest.json", manifest: "http://nas.local:7000/abc/manifest.json", base: "http://nas.local:7000/abc"),
    .init(input: "https://example.com/abc/manifest.json", manifest: "https://example.com/abc/manifest.json", base: "https://example.com/abc"),
    .init(input: "https://example.com/abc", manifest: "https://example.com/abc/manifest.json", base: "https://example.com/abc"),
    .init(input: "https://example.com/abc/", manifest: "https://example.com/abc/manifest.json", base: "https://example.com/abc"),
    .init(input: "https://example.com", manifest: "https://example.com/manifest.json", base: "https://example.com"),
    .init(input: "example.com/abc/manifest.json", manifest: "https://example.com/abc/manifest.json", base: "https://example.com/abc"),
    .init(input: "192.168.0.10:7000", manifest: "http://192.168.0.10:7000/manifest.json", base: "http://192.168.0.10:7000"),
    .init(input: "localhost:7001/x", manifest: "http://localhost:7001/x/manifest.json", base: "http://localhost:7001/x"),
    .init(input: "  <stremio://host.example.com/path/manifest.json>  ", manifest: "https://host.example.com/path/manifest.json", base: "https://host.example.com/path"),
    .init(input: "http://example.com/manifest.json", manifest: "http://example.com/manifest.json", base: "http://example.com"),
    .init(input: "HTTPS://Example.COM/Path/Manifest.JSON", manifest: "https://example.com/Path/Manifest.JSON", base: "https://example.com/Path"),
    .init(input: "stremio:///example.com/manifest.json", manifest: "https://example.com/manifest.json", base: "https://example.com"),
    .init(input: "stremio://example.com/%7B%22a%22%3A1%7D/manifest.json", manifest: "https://example.com/%7B%22a%22%3A1%7D/manifest.json", base: "https://example.com/%7B%22a%22%3A1%7D"),
    .init(input: "https://example.com/tok_ABC123/manifest.json#frag", manifest: "https://example.com/tok_ABC123/manifest.json", base: "https://example.com/tok_ABC123"),
]

@Suite struct URLNormaliseTests {
    @Test(arguments: cases)
    func normalises(_ c: NormaliseCase) throws {
        let location = try AddonURLNormaliser.normalise(c.input)
        #expect(location.manifestURL.absoluteString == c.manifest)
        #expect(location.baseURL.absoluteString == c.base)
    }

    @Test func rejectsBadInput() {
        #expect(throws: AddonURLError.empty) { try AddonURLNormaliser.normalise("") }
        #expect(throws: AddonURLError.empty) { try AddonURLNormaliser.normalise("   \n") }
        #expect(throws: AddonURLError.unsupportedScheme("ftp")) { try AddonURLNormaliser.normalise("ftp://example.com/manifest.json") }
        #expect(throws: AddonURLError.unsupportedScheme("file")) { try AddonURLNormaliser.normalise("file:///etc/passwd") }
        #expect(throws: AddonURLError.missingHost) { try AddonURLNormaliser.normalise("https://") }
        #expect(throws: AddonURLError.unsupportedQuery) { try AddonURLNormaliser.normalise("https://example.com/manifest.json?token=abc") }
        #expect(throws: AddonURLError.invalid) { try AddonURLNormaliser.normalise("1http://example.com") }
    }

    @Test func errorsHaveUserFacingMessages() {
        for error in [AddonURLError.empty, .invalid, .unsupportedScheme("ftp"), .missingHost, .unsupportedQuery] {
            #expect(!error.message.isEmpty)
        }
    }

    @Test func locationFromManifestURL() throws {
        let url = try #require(URL(string: "https://example.com/a/b/manifest.json"))
        let location = try #require(AddonLocation(manifestURL: url))
        #expect(location.baseURL.absoluteString == "https://example.com/a/b")
        #expect(AddonLocation(manifestURL: try #require(URL(string: "https://example.com/a/b"))) == nil)
    }

    @Test(arguments: [
        ("10.0.0.1", true), ("172.16.5.4", true), ("172.31.255.255", true), ("172.32.0.1", false), ("192.168.1.1", true),
        ("8.8.8.8", false), ("127.0.0.1", true), ("169.254.1.1", true), ("100.100.1.1", true), ("localhost", true),
        ("raspberrypi", true), ("nas.local", true), ("example.com", false), ("sub.example.co.uk", false),
        ("::1", true), ("fe80::1", true), ("fd12:3456::1", true), ("2001:db8::1", false), ("[::1]", true), ("999.1.1.1", false),
    ] as [(String, Bool)])
    func classifiesHosts(host: String, lan: Bool) {
        #expect(HostClassifier.isLAN(host) == lan)
    }
}
