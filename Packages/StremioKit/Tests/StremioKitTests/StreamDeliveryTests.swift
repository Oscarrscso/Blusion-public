import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

/// The texts are as AIOStreams, Torrentio and Comet sent them on 17 Oct 2026 (see `TorBoxCacheTests`).
@Suite struct StreamDeliveryTests {
    private func stream(_ name: String?, _ description: String? = nil) -> AddonStream {
        AddonStream(name: name, description: description, source: .direct(URL(string: "https://stream.example/file.mkv")!))
    }

    private func ranked(_ id: String, _ name: String, _ description: String? = nil) -> RankedStream {
        let item = stream(name, description)
        return RankedStream(id: id, stream: item, addon: S.addon("A"), alsoProvidedBy: [], quality: StreamQuality.parse(item), container: nil,
                            route: .native(URL(string: "https://stream.example/\(id).mkv")!), addonIndex: 0, indexInAddon: 0)
    }

    @Test func aioStreamsMarksUsenetWithANewspaperAndDebridWithACloud() {
        #expect(StreamDelivery.detect(in: stream("📰 ⚡ Movie · 2160p", "💾 File: 61.9 GB\n📡 Source: 📰 TB · Library")) == .usenet,
                "TorBox's Usenet downloads carry its tag too, and are Usenet")
        #expect(StreamDelivery.detect(in: stream("📰 ⚡ Movie · 2160p", "📡 Source: 📰 EN · Sootio")) == .usenet, "Easynews")
        #expect(StreamDelivery.detect(in: stream("☁️ ⚡ Movie · 2160p", "📡 Source: ☁️ TB · Library")) == .debrid)
        #expect(StreamDelivery.detect(in: stream("☁️ ⚡ Movie", "📡 Source: ☁️ RD · TorBox Search")) == .debrid)
    }

    @Test func serviceTagsAndNamesAreRead() {
        #expect(StreamDelivery.detect(in: stream("[RD+] Torrentio\n4k", "Movie.2160p.mkv")) == .debrid)
        #expect(StreamDelivery.detect(in: stream("[TB download] Torrentio\n1080p", "Movie.1080p.mkv")) == .debrid)
        #expect(StreamDelivery.detect(in: stream("[TORBOX⚡] Comet 4K", "Movie.2160p.mkv")) == .debrid)
        #expect(StreamDelivery.detect(in: stream("Premiumize", "Movie.mkv")) == .debrid)
        #expect(StreamDelivery.detect(in: stream("Usenet Streamer", "Movie.mkv")) == .usenet)
        #expect(StreamDelivery.detect(in: stream("NZB 4K", "Movie.mkv")) == .usenet)
    }

    @Test func plainStreamsSizesAndReleaseNamesSayNeither() {
        #expect(StreamDelivery.detect(in: stream("Torrentio\n1080p", "Movie.1080p.WEB-DL.mkv\n👤 12 💾 4 GB")) == nil)
        #expect(StreamDelivery.detect(in: stream("⚡ Movie · 2160p", "💾 File: 1.2 TB · 600 Mbps")) == nil, "a size in terabytes")
        #expect(StreamDelivery.detect(in: stream("MyCDN", "Movie.Directors.Cut.mkv")) == nil)
        let page = AddonStream(name: "☁️ Scrape Summary", source: .external(URL(string: "https://aio.example")!))
        #expect(StreamDelivery.detect(in: page) == nil, "a web page is never a stream")
    }

    @Test func aPreferenceKeepsAutoPickToThatKindWheneverThereIsOne() {
        let usenet = ranked("u", "📰 ⚡ Movie · 1080p")
        let debrid = ranked("d", "☁️ ⚡ Movie · 2160p")
        let plain = ranked("p", "Movie · 2160p")
        let all = [debrid, plain, usenet]
        #expect(StreamSourcePreference.usenet.candidates(from: all).map(\.id) == ["u"])
        #expect(StreamSourcePreference.debrid.candidates(from: all).map(\.id) == ["d"])
        #expect(StreamSourcePreference.balanced.candidates(from: all).map(\.id) == ["d", "p", "u"])
        #expect(StreamSourcePreference.usenet.candidates(from: [debrid, plain]).map(\.id) == ["d", "p"],
                "with no Usenet stream at all, Auto Pick still has every stream to choose from")
    }
}
