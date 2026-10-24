import Foundation
import Testing
@testable import StremioKit

/// The texts here are as AIOStreams, Torrentio and Comet sent them on 17 Oct 2026.
@Suite struct TorBoxCacheTests {
    private let url = URL(string: "https://stream.example/file.mkv")!

    private func stream(_ name: String?, _ description: String?, source: StreamSource? = nil) -> AddonStream {
        AddonStream(name: name, description: description, source: source ?? .direct(url))
    }

    @Test func aioStreamsMarksACachedTorBoxFileWithABolt() {
        let cached = stream("☁️ ⚡ The Shawshank Redemption · 2160p [DV · HDR10]",
                            "💾 File: 58.3 GB · 54.6 Mbps\n🎞️ Quality: BluRay REMUX · HEVC\n📡 Source: ☁️ TB · Library\n🌐 Lang: 🇬🇧")
        #expect(TorBoxCache.detect(in: cached) == .cached)
        let usenet = stream("📰 ⚡ The Shawshank Redemption · 2160p [HDR10]", "💾 File: 61.9 GB\n📡 Source: 📰 TB · Library")
        #expect(TorBoxCache.detect(in: usenet) == .cached, "TorBox's own usenet downloads are TorBox too")
        let waiting = stream("☁️ ⏳ The Shawshank Redemption · 1080p", "💾 File: 12 GB\n📡 Source: ☁️ TB · Torrentio")
        #expect(TorBoxCache.detect(in: waiting) == .notCached)
    }

    @Test func torrentioAndCometMarksAreRead() {
        #expect(TorBoxCache.detect(in: stream("[TB+] Torrentio\n4k", "Movie.2160p.mkv\n👤 12 💾 40 GB")) == .cached)
        #expect(TorBoxCache.detect(in: stream("[TB download] Torrentio\n1080p", "Movie.1080p.mkv")) == .notCached)
        #expect(TorBoxCache.detect(in: stream("[TORBOX⚡] Comet 4K", "Movie.2160p.mkv")) == .cached)
    }

    @Test func emojiFormsMediaFusionAndCachedFieldsAreRead() {
        #expect(TorBoxCache.detect(in: stream("TorBox ⚡\u{FE0F} Movie", "Movie.mkv")) == .cached, "the bolt with its emoji selector")
        #expect(TorBoxCache.detect(in: stream("☁️ ⏳\u{FE0F} Movie", "📡 Source: ☁️ TB")) == .notCached)
        #expect(TorBoxCache.detect(in: stream("MediaFusion | TRB ⚡️", "Movie.2160p.mkv")) == .cached)
        #expect(TorBoxCache.detect(in: stream("TorBox", "Movie.mkv\nCached: No")) == .notCached)
        #expect(TorBoxCache.detect(in: stream("TorBox", "Movie.mkv\nCached: Yes")) == .cached)
    }

    @Test func otherServicesSizesAndNotesAreNotTorBox() {
        #expect(TorBoxCache.detect(in: stream("☁️ ⚡ Movie", "📡 Source: ☁️ RD · TorBox Search")) == nil,
                "a Real-Debrid stream an addon named TorBox Search found")
        let easynews = stream("📰 ⚡ The Shawshank Redemption · 2160p", "💾 File: 58 GB\n📡 Source: 📰 EN · Sootio")
        #expect(TorBoxCache.detect(in: easynews) == nil, "Easynews plays at once but is not TorBox")
        #expect(TorBoxCache.detect(in: stream("⚡ Movie · 2160p", "💾 File: 1.2 TB · 600 Mbps")) == nil, "a size in terabytes is not TorBox")
        #expect(TorBoxCache.detect(in: stream("⚡ Movie", "💾 2TB")) == nil)
        let note = stream("🟢 [Library TB] Scrape Summary", "✔ Status : SUCCESS / ⚡ Expressions: 37ms",
                          source: .external(URL(string: "https://aiostreams.example")!))
        #expect(TorBoxCache.detect(in: note) == nil, "an aggregator's statistics note is not a stream")
        #expect(TorBoxCache.detect(in: stream("Torrentio\n1080p", "Movie.1080p.mkv")) == nil)
        #expect(TorBoxCache.detect(in: stream("TB Movie", "Movie.mkv")) == nil, "TorBox named without a cache mark says nothing")
    }

    @Test func theTechnicalDetailsSayIt() {
        let addon = AddonSummary(id: UUID(), name: "AIOStreams", host: "aio.example")
        let cached = stream("☁️ ⚡ Movie · 2160p", "📡 Source: ☁️ TB · Library")
        let item = RankedStream(id: "id", stream: cached, addon: addon, alsoProvidedBy: [], quality: StreamQuality.parse(cached),
                                container: nil, route: .native(url), addonIndex: 0, indexInAddon: 0)
        #expect(StreamFacts(item).rows.first { $0.label == "TorBox" }?.value == "Cached, plays at once")
    }
}
