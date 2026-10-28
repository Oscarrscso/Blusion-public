import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

@Suite struct StreamRankingTests {
    private func ranked(_ title: String, _ description: String, addon: Int = 0, index: Int = 0, route: Bool = true) -> RankedStream {
        let stream = S.direct(title, "https://e.example.com/\(title).mp4", description: description)
        let summary = AddonSummary(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(addon)")!, name: "A\(addon)", host: "h")
        let quality = StreamQuality.parse(stream)
        return RankedStream(id: title, stream: stream, addon: summary, alsoProvidedBy: [], quality: quality, container: nil,
                            route: route ? .native(URL(string: "https://e.example.com/\(title).mp4")!) : .unsupported(.avi),
                            addonIndex: addon, indexInAddon: index)
    }

    private func order(_ items: [RankedStream], _ preferences: RankingPreferences = .init()) -> [String] {
        StreamRanking.sorted(items, preferences: preferences).map(\.id)
    }

    @Test func higherResolutionFirstUnknownLast() {
        let items = [ranked("none", ""), ranked("hd", "720p"), ranked("uhd", "2160p"), ranked("fhd", "1080p")]
        #expect(order(items) == ["uhd", "fhd", "hd", "none"])
    }

    @Test func remuxDoesNotOverrideResolutionPreferences() {
        let remux = handed("remux", "1080p BluRay REMUX")
        let web = ranked("web", "2160p WEB-DL Dolby Vision")
        for items in [[web, remux], [remux, web]] {
            #expect(order(items) == ["web", "remux"])
            #expect(order(items, RankingPreferences(preferredResolution: 2160)) == ["web", "remux"])
        }
        let contradicted = ranked("mixed", "1080p REMUX WEB-DL")
        #expect(order([contradicted, web]) == ["web", "mixed"], "contradictory source tags cannot claim priority")
    }

    @Test func nativeBeforeUnsupportedWhateverTheResolution() {
        #expect(order([ranked("big", "2160p", route: false), ranked("small", "480p")]) == ["small", "big"])
    }

    @Test func sourceThenSizeBreakTies() {
        let items = [ranked("webrip", "1080p webrip"), ranked("bluray", "1080p bluray"), ranked("webdl", "1080p web-dl")]
        #expect(order(items) == ["bluray", "webdl", "webrip"])
        let sized = [ranked("small", "1080p web-dl 1 GB"), ranked("large", "1080p web-dl 8 GB"), ranked("unsized", "1080p web-dl")]
        #expect(order(sized) == ["large", "small", "unsized"])
    }

    @Test func addonOrderThenPositionBreakRemainingTies() {
        let items = [ranked("b0", "1080p", addon: 1, index: 0), ranked("a1", "1080p", addon: 0, index: 1), ranked("a0", "1080p", addon: 0, index: 0)]
        #expect(order(items) == ["a0", "a1", "b0"])
    }

    @Test func preferredResolutionPullsTheClosestToTheTop() {
        let items = [ranked("uhd", "2160p"), ranked("fhd", "1080p"), ranked("hd", "720p"), ranked("sd", "480p")]
        #expect(order(items, RankingPreferences(preferredResolution: 1080)) == ["fhd", "hd", "sd", "uhd"])
        #expect(order(items, RankingPreferences(preferredResolution: 720)) == ["hd", "sd", "fhd", "uhd"], "480p is 240 away, 1080p is 360")
        #expect(order(items, RankingPreferences(preferredResolution: 2160)) == ["uhd", "fhd", "hd", "sd"])
    }

    @Test func equalDistanceGoesToTheHigherResolution() {
        let items = [ranked("hd", "720p"), ranked("qhd", "1440p")]
        #expect(order(items, RankingPreferences(preferredResolution: 1080)) == ["qhd", "hd"])
    }

    @Test func unknownResolutionStaysLastEvenWithAPreference() {
        let items = [ranked("none", ""), ranked("uhd", "2160p")]
        #expect(order(items, RankingPreferences(preferredResolution: 480)) == ["uhd", "none"])
    }

    @Test func sortingIsADeterministicTotalOrder() {
        var items: [RankedStream] = []
        for (i, text) in ["", "720p", "1080p", "1080p bluray", "2160p hdr", "480p", "1080p web-dl 2 GB"].enumerated() {
            items.append(ranked("s\(i)", text, addon: i % 3, index: i))
        }
        let expected = order(items)
        for _ in 0..<20 { #expect(order(items.shuffled()) == expected) }
    }

    @Test func bingeSelectionPrefersTheSameGroupAndAddon() {
        let a = S.addon("A"), b = S.addon("B")
        func item(_ title: String, _ addon: AddonSummary, group: String?, native: Bool = true) -> RankedStream {
            let stream = S.direct(title, "https://e.example.com/\(title).mp4", bingeGroup: group)
            return RankedStream(id: title, stream: stream, addon: addon, alsoProvidedBy: [], quality: .init(), container: nil,
                                route: native ? .native(URL(string: "https://e.example.com/\(title).mp4")!) : .external(URL(string: "https://e.example.com")!),
                                addonIndex: 0, indexInAddon: 0)
        }
        let list = [item("other", a, group: "x"), item("b-match", b, group: "g"), item("a-match", a, group: "g"), item("ext", a, group: "g", native: false)]
        #expect(BingeSelection.pick(from: list, continuing: BingeContext(bingeGroup: "g", addonID: a.id))?.id == "a-match")
        #expect(BingeSelection.pick(from: list, continuing: BingeContext(bingeGroup: "g", addonID: UUID()))?.id == "b-match", "first match when the addon is gone")
        #expect(BingeSelection.pick(from: list, continuing: BingeContext(bingeGroup: "none")) == nil)
        #expect(BingeSelection.pick(from: list, continuing: nil) == nil)
        #expect(BingeSelection.pick(from: [item("ext", a, group: "g", native: false)], continuing: BingeContext(bingeGroup: "g")) == nil, "only playable streams qualify")
    }

    /// A stream Infuse plays: its route is a hand-off, which ranks with the natively playable ones.
    private func handed(_ title: String, _ description: String) -> RankedStream {
        let stream = S.direct(title, "https://e.example.com/\(title).mkv", description: description)
        return RankedStream(id: title, stream: stream, addon: S.addon("Infuse"), alsoProvidedBy: [], quality: StreamQuality.parse(stream),
                            container: .matroska, route: .handoff(.infuse, URL(string: "https://e.example.com/\(title).mkv")!),
                            addonIndex: 0, indexInAddon: 0)
    }

    @Test func aHandoffRanksAboveANativeStreamOfLowerQuality() {
        #expect(order([ranked("native 1080", "1080p"), handed("handoff 2160", "2160p")]) == ["handoff 2160", "native 1080"])
        #expect(order([ranked("native 720", "720p"), handed("handoff 1080", "1080p")]) == ["handoff 1080", "native 720"])
    }

    @Test func aHandoffStaysAheadOfUnsupportedStreamsWhateverTheResolution() {
        #expect(order([ranked("big", "2160p", route: false), handed("low", "480p")]) == ["low", "big"])
    }

    @Test func linksToWebPagesSortBelowUnsupportedStreams() {
        // Aggregators add informational entries that are web pages. They never outrank a stream the user could start.
        let page = RankedStream(id: "page", stream: S.external("Removal Reasons", "https://example.com/summary"), addon: S.addon("A"),
                                alsoProvidedBy: [], quality: StreamQuality.parse(from: ["2160p"]), container: nil,
                                route: .external(URL(string: "https://example.com/summary")!), addonIndex: 0, indexInAddon: 0)
        #expect(order([page, ranked("mkv", "480p", route: false), ranked("sd", "480p")]) == ["sd", "mkv", "page"])
    }

    @Test func identityKeysNormaliseURLsButNotPaths() throws {
        func key(_ text: String) throws -> String { StreamIdentity.key(for: .direct(try #require(URL(string: text)))) }
        #expect(try key("HTTPS://Cdn.Example.com/x.mp4") == key("https://cdn.example.com/x.mp4#frag"))
        #expect(try key("https://cdn.example.com/x.mp4") != key("https://cdn.example.com/X.mp4"), "paths are case-sensitive")
        #expect(try key("https://cdn.example.com/x.mp4?t=1") != key("https://cdn.example.com/x.mp4?t=2"))
        #expect(StreamIdentity.key(for: .torrent(infoHash: "ABC", fileIndex: nil, sources: [])) == "torrent:abc:-1")
        #expect(StreamIdentity.key(for: .youtube("id")) == "youtube:id")
    }
}
