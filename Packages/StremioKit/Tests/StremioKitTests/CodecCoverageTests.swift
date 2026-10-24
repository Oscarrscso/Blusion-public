import Foundation
import Testing
@testable import StremioKit

/// Codecs and HDR formats read from release names, and where they are routed. Names are labels: the player's statistics show the truth.
@Suite struct CodecCoverageTests {
    private func quality(_ name: String) -> StreamQuality { StreamQuality.parse(from: [name]) }

    @Test func newerAndOlderVideoCodecsAreRecognised() {
        #expect(quality("Movie.2024.2160p.WEB-DL.VVC.10bit").videoCodec == .vvc)
        #expect(quality("Movie 2024 H.266 x266").videoCodec == .vvc)
        #expect(quality("Movie.2019.1080p.WEBRip.VP9.Opus").videoCodec == .vp9)
        #expect(quality("Movie.1999.1080i.BluRay.VC-1.DTS-HD").videoCodec == .vc1)
        #expect(quality("Movie.1994.DVD.MPEG-2.AC3").videoCodec == .mpeg2)
        #expect(quality("Movie.2003.DVDRip.XviD-GRP").videoCodec == .mpeg4)
        #expect(quality("Movie.2020.1080p.x265").videoCodec == .hevc, "the existing codecs are unchanged")
    }

    @Test func hdrFormatsAndDolbyVisionProfilesAreRead() {
        let fel = quality("Movie.2160p.UHD.BluRay.REMUX.DV.P7.FEL.HDR10.TrueHD.Atmos")
        #expect(fel.isDolbyVision && fel.dolbyVisionProfile == 7 && fel.hasFullEnhancementLayer && fel.isHDR)
        let p8 = quality("Movie 2160p WEB-DL DoVi Profile 8 HDR10+ DDP5.1 Atmos")
        #expect(p8.dolbyVisionProfile == 8 && p8.isHDR10Plus)
        let mel = quality("Movie.2160p.BluRay.DV.MEL")
        #expect(mel.dolbyVisionProfile == 7 && !mel.hasFullEnhancementLayer)
        let hlg = quality("Event.2160p.HLG.UHDTV")
        #expect(hlg.isHLG && hlg.isHDR && !hlg.isDolbyVision)
        #expect(StreamFacts.hdrLabel(fel) == "Dolby Vision profile 7 (FEL)")
        #expect(StreamFacts.hdrLabel(p8) == "Dolby Vision profile 8, HDR10+")
        #expect(StreamFacts.hdrLabel(hlg) == "HLG")
    }

    @Test func codecsAVPlayerCannotDecodeGoToTheFallbackEngine() {
        #expect(quality("Movie.VP9").videoNeedsFallbackEngine(decodesAV1InHardware: true))
        #expect(quality("Movie.VC-1").videoNeedsFallbackEngine(decodesAV1InHardware: true))
        #expect(!quality("Movie.x265").videoNeedsFallbackEngine(decodesAV1InHardware: false))
        #expect(!quality("Movie.VVC").videoNeedsFallbackEngine(decodesAV1InHardware: false), "no engine decodes VVC")
        #expect(quality("Movie.VVC").videoIsUndecodable)
        #expect(!quality("Movie.VVC.x265").videoIsUndecodable, "conflicting names are not trusted")
    }

    @Test func vvcIsUnsupportedRatherThanFailingInAnEngine() {
        let stream = AddonStream(name: "Movie 2160p VVC", source: .direct(URL(string: "https://e.example.com/movie.mkv")!))
        let config = PolicyConfiguration(fallbackEngineAvailable: true)
        let route = PlaybackPolicy.route(for: stream, container: nil, quality: StreamQuality.parse(stream), config: config)
        #expect(route == .unsupported(.matroska))
        let mp4 = AddonStream(name: "Movie 1080p VP9", source: .direct(URL(string: "https://e.example.com/movie.mp4")!))
        let routed = PlaybackPolicy.route(for: mp4, container: nil, quality: StreamQuality.parse(mp4), config: config)
        #expect(routed == .fallback(URL(string: "https://e.example.com/movie.mp4")!, .videoCodec))
    }
}
