import Foundation
import Testing
@testable import StremioKit

@Suite struct AddonRequestBuilderTests {
    let base = URL(string: "https://addon.example.com/token123")!

    @Test func plainResource() throws {
        let url = try #require(AddonRequestBuilder.url(base: base, resource: .catalog, type: "movie", id: "top"))
        #expect(url.absoluteString == "https://addon.example.com/token123/catalog/movie/top.json")
    }

    @Test func trailingSlashOnBaseIsIgnored() throws {
        let url = try #require(AddonRequestBuilder.url(base: URL(string: "https://a.example.com/x/")!, resource: .meta, type: "movie", id: "tt1"))
        #expect(url.absoluteString == "https://a.example.com/x/meta/movie/tt1.json")
    }

    @Test func extrasAreOneSegmentWithPercentEncodedValues() throws {
        let url = try #require(AddonRequestBuilder.url(base: base, resource: .catalog, type: "movie", id: "top",
                                                       extras: [ExtraParam("genre", "Sci-Fi & Fantasy"), ExtraParam("skip", "20")]))
        #expect(url.absoluteString == "https://addon.example.com/token123/catalog/movie/top/genre=Sci-Fi%20%26%20Fantasy&skip=20.json")
    }

    @Test func specialCharactersAreEncodedInValues() throws {
        let url = try #require(AddonRequestBuilder.url(base: base, resource: .catalog, type: "movie", id: "top",
                                                       extras: [ExtraParam("search", "a&b=c/d e?f#g%h+i")]))
        #expect(url.absoluteString.hasSuffix("/search=a%26b%3Dc%2Fd%20e%3Ff%23g%25h%2Bi.json"))
    }

    @Test func episodeIdsKeepTheirColons() throws {
        let url = try #require(AddonRequestBuilder.url(base: base, resource: .stream, type: "series", id: "tt1234567:2:5"))
        #expect(url.absoluteString.hasSuffix("/stream/series/tt1234567:2:5.json"))
    }

    @Test func unicodeIsPercentEncodedAsUTF8() throws {
        let url = try #require(AddonRequestBuilder.url(base: base, resource: .catalog, type: "movie", id: "top",
                                                       extras: [ExtraParam("search", "Amélie 映画")]))
        #expect(url.absoluteString.hasSuffix("/search=Am%C3%A9lie%20%E6%98%A0%E7%94%BB.json"))
    }

    @Test func idContainingSlashStaysOneSegment() throws {
        let url = try #require(AddonRequestBuilder.url(base: base, resource: .meta, type: "movie", id: "a/b/c"))
        #expect(url.absoluteString.hasSuffix("/meta/movie/a%2Fb%2Fc.json"))
        let parsed = try #require(AddonRequestBuilder.parse(url))
        #expect(parsed.id == "a/b/c")
    }

    @Test func parsesWhatItBuilds() throws {
        let url = try #require(AddonRequestBuilder.url(base: base, resource: .catalog, type: "movie", id: "top",
                                                       extras: [ExtraParam("genre", "Action"), ExtraParam("skip", "40")]))
        let parsed = try #require(AddonRequestBuilder.parse(url))
        #expect(parsed == ParsedAddonRequest(resource: .catalog, type: "movie", id: "top", extras: [ExtraParam("genre", "Action"), ExtraParam("skip", "40")]))
    }

    @Test func parseRejectsOtherURLs() throws {
        #expect(AddonRequestBuilder.parse(URL(string: "https://a.example.com/manifest.json")!) == nil)
        #expect(AddonRequestBuilder.parse(URL(string: "https://a.example.com/catalog/movie/top")!) == nil)
        #expect(AddonRequestBuilder.parse(URL(string: "https://a.example.com/")!) == nil)
    }

    @Test func extraWithoutValueParses() {
        #expect(AddonRequestBuilder.parseExtras("a=1&b&c=") == [ExtraParam("a", "1"), ExtraParam("b", ""), ExtraParam("c", "")])
        #expect(AddonRequestBuilder.parseExtras("=x&&").isEmpty)
    }

    @Test func roundTripsHostileStrings() throws {
        let hostile = ["a b", "a&b", "a=b", "a/b", "a?b", "a#b", "a%b", "a%2Fb", "a+b", "ü", "映画", "🎬", "tt1:1:2", "a.json", "..", "a\\b",
                       "quote\"s", "semi;colon", "dollar$", "{json}", "<tag>", "", " ", "\n", "x=1&y=2"]
        for value in hostile where !value.isEmpty {
            let url = try #require(AddonRequestBuilder.url(base: base, resource: .catalog, type: "movie", id: value,
                                                           extras: [ExtraParam(value, value)]))
            let parsed = try #require(AddonRequestBuilder.parse(url), "failed to parse \(url.absoluteString)")
            #expect(parsed.id == value)
            #expect(parsed.extras == [ExtraParam(value, value)])
            #expect(parsed.type == "movie")
        }
    }

    @Test func roundTripsRandomUnicodeStrings() throws {
        var rng = SplitMix64(seed: 0xB10510)
        let alphabet = Array("abcXYZ019 &=/?#%+:;,.\\\"'<>[]{}()!@$^*|~`_-éüñ映画🎬\t")
        for _ in 0..<600 {
            let length = Int.random(in: 1...24, using: &rng)
            let value = String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
            let other = String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
            let url = try #require(AddonRequestBuilder.url(base: base, resource: .stream, type: "series", id: value,
                                                           extras: [ExtraParam("k", other), ExtraParam(other, value)]))
            let parsed = try #require(AddonRequestBuilder.parse(url), "failed to parse \(url.absoluteString)")
            #expect(parsed.resource == .stream)
            #expect(parsed.id == value)
            #expect(parsed.extras == [ExtraParam("k", other), ExtraParam(other, value)])
        }
    }
}
