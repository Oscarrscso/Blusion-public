import Foundation
import Testing
import StremioKit
@testable import Features

@Suite struct AddonLinkTests {
    private func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    @Test func aStremioManifestLinkBecomesInstallText() throws {
        let link = try url("stremio://addons.example.com/abc/manifest.json")
        #expect(AddonLink.installText(from: link) == "stremio://addons.example.com/abc/manifest.json")
    }

    @Test func httpsAndHTTPManifestLinksBecomeInstallText() throws {
        let secure = try url("https://addons.example.com/abc/manifest.json")
        #expect(AddonLink.installText(from: secure) == "https://addons.example.com/abc/manifest.json")
        let plain = try url("http://192.168.1.10:7000/manifest.json")
        #expect(AddonLink.installText(from: plain) == "http://192.168.1.10:7000/manifest.json")
    }

    @Test func theSchemeIsRecognisedInUpperCaseAndTheTextStillInstalls() throws {
        let link = try url("STREMIO://addons.example.com/manifest.json")
        let text = try #require(AddonLink.installText(from: link))
        #expect(text == link.absoluteString)
        #expect((try? AddonURLNormaliser.normalise(text)) != nil, "the install field accepts what the link gave it")
    }

    @Test func blusionCallbacksAreNotAddonLinks() throws {
        let callback = try url("blusion://x-callback-url/play?id=tt1")
        #expect(AddonLink.installText(from: callback) == nil)
    }

    @Test func anHTTPSPageThatIsNotAManifestIsIgnored() throws {
        let page = try url("https://example.com/catalog/top")
        #expect(AddonLink.installText(from: page) == nil)
        let nearMiss = try url("https://example.com/manifest.json.bak")
        #expect(AddonLink.installText(from: nearMiss) == nil)
        let root = try url("https://example.com/")
        #expect(AddonLink.installText(from: root) == nil)
    }
}
