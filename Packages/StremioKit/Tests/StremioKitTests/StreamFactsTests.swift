import Foundation
import Testing
@testable import StremioKit

@Suite struct StreamFactsTests {
    private let addon = AddonSummary(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Torrentio", host: "torrentio.example")
    private let page = URL(string: "https://e.example.com/watch")!

    private func item(_ stream: AddonStream, container: MediaContainer? = nil, alsoProvidedBy: [AddonSummary] = []) -> RankedStream {
        RankedStream(id: "id", stream: stream, addon: addon, alsoProvidedBy: alsoProvidedBy, quality: StreamQuality.parse(stream),
                     container: container, route: .native(page), addonIndex: 0, indexInAddon: 0)
    }

    private func facts(_ item: RankedStream) -> [StreamFacts.Fact] { StreamFacts(item).rows }

    private func value(_ label: String, in item: RankedStream) -> String? {
        facts(item).first { $0.label == label }?.value
    }

    private static let hash = "abcdef0123456789abcdef0123456789abcdef01"

    @Test func aTorrentListsEveryFactInOrder() {
        let name = "Movie.2020.1080p.BluRay.x265.DTS-HD.MA-GRP.mkv"
        let stream = AddonStream(
            name: "Torrentio\n1080p",
            description: "\(name)\n👤 12 💾 1.2 GB ⚙️ Site",
            source: .torrent(infoHash: Self.hash, fileIndex: 2, sources: ["tracker:udp://t.example:1", "tracker:udp://t.example:2", "dht:\(Self.hash)"]),
            subtitles: [SubtitleItem(id: "s1", url: page, lang: "eng")],
            behaviorHints: StreamBehaviorHints(notWebReady: true, bingeGroup: "group", proxyHeaders: ProxyHeaders(request: ["Authorization": "Bearer SECRET"]),
                                               videoHash: "video-hash", videoSize: 1_000, filename: name, countryWhitelist: ["US", "GB"]))
        let labels = facts(item(stream, container: .matroska, alsoProvidedBy: [AddonSummary(id: UUID(), name: "Other", host: "o.example")])).map(\.label)
        #expect(labels == ["Seeders", "Size", "Resolution", "Source", "Video codec", "Audio", "Filename", "Container", "Addon", "Also from",
                           "Info hash", "File index", "Trackers", "Binge group", "Video hash", "Video size", "Subtitles", "Regions",
                           "Custom request headers", "Needs conversion"])
    }

    @Test func theValuesAreTheTypedFactsAndTheAddonsOwn() {
        let stream = AddonStream(
            name: "Torrentio", description: "2160p WEB-DL DV HDR x265 TrueHD Atmos\n👤 12", source: .torrent(infoHash: Self.hash, fileIndex: 2, sources: []),
            subtitles: [SubtitleItem(id: "s1", url: page, lang: "eng"), SubtitleItem(id: "s2", url: page, lang: "fra")],
            behaviorHints: StreamBehaviorHints(videoHash: "video-hash", videoSize: 1_000, countryWhitelist: ["US", "GB"]))
        let ranked = item(stream, container: .matroska)
        #expect(value("Seeders", in: ranked) == "12")
        #expect(value("Resolution", in: ranked) == "4K")
        #expect(value("Source", in: ranked) == "WEB-DL")
        #expect(value("HDR / Dolby Vision", in: ranked) == "Dolby Vision")
        #expect(value("Video codec", in: ranked) == "HEVC")
        #expect(value("Audio", in: ranked) == "TrueHD, Atmos")
        #expect(value("Container", in: ranked) == "MKV")
        #expect(value("Addon", in: ranked) == "Torrentio")
        #expect(value("Info hash", in: ranked) == Self.hash, "the full hash, not a shortened one")
        #expect(value("File index", in: ranked) == "2")
        #expect(value("Trackers", in: ranked) == nil, "no trackers listed, so no row")
        #expect(value("Video hash", in: ranked) == "video-hash")
        #expect(value("Video size", in: ranked) == "1,000 bytes")
        #expect(value("Subtitles", in: ranked) == "2")
        #expect(value("Regions", in: ranked) == "US, GB")
    }

    @Test func identifiersAreFlaggedForMonospacing() {
        let stream = AddonStream(name: "x", source: .torrent(infoHash: Self.hash, fileIndex: nil, sources: []),
                                 behaviorHints: StreamBehaviorHints(videoHash: "video-hash"))
        let rows = facts(item(stream))
        #expect(rows.first { $0.label == "Info hash" }?.isIdentifier == true)
        #expect(rows.first { $0.label == "Video hash" }?.isIdentifier == true)
        #expect(rows.first { $0.label == "Addon" }?.isIdentifier == false)
    }

    @Test func emptyFactsAreLeftOut() throws {
        let stream = AddonStream(name: "Provider", source: .direct(page))
        #expect(facts(item(stream)).map(\.label) == ["Addon"], "a bare HTTP stream shows only the addon that gave it")
        let empty = AddonStream(name: "x", description: "   ", source: .direct(page),
                                behaviorHints: StreamBehaviorHints(bingeGroup: nil, proxyHeaders: ProxyHeaders(), filename: "  "))
        #expect(facts(item(empty)).map(\.label) == ["Addon"], "an empty header and filename are not shown")
    }

    @Test func aTrackerCountOnlyCountsTrackerEntries() {
        let stream = AddonStream(name: "x", source: .torrent(infoHash: Self.hash, fileIndex: nil, sources: ["dht:\(Self.hash)"]))
        #expect(value("Trackers", in: item(stream)) == nil, "DHT entries are not trackers")
    }

    @Test func requestHeaderValuesAreNeverShown() {
        let stream = AddonStream(name: "x", source: .direct(page),
                                 behaviorHints: StreamBehaviorHints(proxyHeaders: ProxyHeaders(request: ["Authorization": "Bearer SECRET-TOKEN"],
                                                                                               response: ["Set-Cookie": "session=SECRET-COOKIE"])))
        let rows = facts(item(stream))
        #expect(value("Custom request headers", in: item(stream)) == "Yes")
        #expect(rows.allSatisfy { !$0.value.contains("SECRET") && !$0.label.contains("SECRET") }, "no header value reaches a row")
        #expect(!rows.contains { $0.value.contains("Bearer") || $0.value.contains("session") })
    }

    @Test func needsConversionShowsOnlyWhenTheAddonSaysSo() {
        let stream = AddonStream(name: "x", source: .direct(page), behaviorHints: StreamBehaviorHints(notWebReady: true))
        #expect(value("Needs conversion", in: item(stream)) == "Yes")
        #expect(value("Needs conversion", in: item(AddonStream(name: "x", source: .direct(page)))) == nil)
    }

    @Test func atmosWithoutACodecIsStillListed() {
        let stream = AddonStream(name: "2160p Atmos", source: .direct(page))
        #expect(value("Audio", in: item(stream)) == "Atmos")
    }
}
