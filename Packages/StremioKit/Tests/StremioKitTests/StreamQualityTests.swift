import Foundation
import Testing
@testable import StremioKit

struct QualityCase: Sendable, CustomTestStringConvertible {
    var text: String
    var resolution: Int?
    var source: StreamSourceKind?
    var video: VideoCodec?
    var audio: [AudioCodec]
    var hdr = false
    var dolbyVision = false
    var testDescription: String { text }
}

private let cases: [QualityCase] = [
    .init(text: "Provider\n4K HDR DV", resolution: 2160, source: nil, video: nil, audio: [], hdr: true, dolbyVision: true),
    .init(text: "Movie.2020.1080p.BluRay.x265.10bit.DTS-HD.MA.7.1-GRP", resolution: 1080, source: .bluray, video: .hevc, audio: [.dtsHD]),
    .init(text: "Movie.2020.720p.WEB-DL.DD5.1.H264-GRP.mkv", resolution: 720, source: .webDL, video: .h264, audio: [.ac3]),
    .init(text: "WEBRip 480p AAC", resolution: 480, source: .webRip, video: nil, audio: [.aac]),
    .init(text: "HDCAM 1080p", resolution: 1080, source: .cam, video: nil, audio: []),
    .init(text: "HDTV 576p x264", resolution: 576, source: .hdtv, video: .h264, audio: []),
    .init(text: "2160p UHD REMUX TrueHD Atmos HEVC", resolution: 2160, source: .bluray, video: .hevc, audio: [.trueHD]),
    .init(text: "1080p E-AC3 DDP5.1", resolution: 1080, source: nil, video: nil, audio: [.eac3]),
    .init(text: "1080p DD+ Atmos", resolution: 1080, source: nil, video: nil, audio: [.eac3]),
    .init(text: "1920x1080 H.264 AAC", resolution: 1080, source: nil, video: .h264, audio: [.aac]),
    .init(text: "dolby vision hdr10+ 2160p AV1 opus", resolution: 2160, source: nil, video: .av1, audio: [.opus], hdr: true, dolbyVision: true),
    .init(text: "DVDRip 480p mp3", resolution: 480, source: .dvd, video: nil, audio: [.mp3]),
    .init(text: "FLAC 1080p fhd", resolution: 1080, source: nil, video: nil, audio: [.flac]),
    .init(text: "Some Random Name With Nothing Useful", resolution: nil, source: nil, video: nil, audio: []),
    .init(text: "", resolution: nil, source: nil, video: nil, audio: []),
]

@Suite struct StreamQualityTests {
    @Test(arguments: cases)
    func parsesFreeText(_ c: QualityCase) {
        let quality = StreamQuality.parse(from: [c.text])
        #expect(quality.resolution == c.resolution)
        #expect(quality.source == c.source)
        #expect(quality.videoCodec == c.video)
        #expect(quality.audioCodecs == c.audio)
        #expect(quality.isHDR == c.hdr)
        #expect(quality.isDolbyVision == c.dolbyVision)
    }

    @Test func atmosKindFollowsTheCodecNotTheSource() {
        // Streaming Atmos is E-AC-3 (DD+) with JOC; Blu-ray Atmos is TrueHD. A Blu-ray source with DD+ is still streaming Atmos.
        #expect(StreamQuality.parse(from: ["1080p WEB-DL DDP5.1 Atmos"]).atmosFormat == .streaming)
        #expect(StreamQuality.parse(from: ["2160p BluRay REMUX TrueHD 7.1 Atmos"]).atmosFormat == .lossless)
        #expect(StreamQuality.parse(from: ["1080p BluRay DD+ Atmos"]).atmosFormat == .streaming)
        #expect(StreamQuality.parse(from: ["2160p BluRay REMUX DTS-HD MA 5.1 Atmos"]).atmosFormat == nil,
                "an Atmos label without a codec that can carry it stays unclassified")
        #expect(StreamQuality.parse(from: ["1080p BluRay DTS-HD MA 5.1"]).atmosFormat == nil, "no Atmos, no kind")
    }

    @Test func atmosIsAMarker() {
        #expect(StreamQuality.parse(from: ["TrueHD Atmos"]).hasAtmos)
        #expect(!StreamQuality.parse(from: ["AAC"]).hasAtmos)
    }

    @Test func sizesParseInBothUnitsAndSeparators() {
        #expect(StreamQuality.parse(from: ["💾 2.3 GB"]).sizeBytes == 2_300_000_000, "GB is decimal")
        #expect(StreamQuality.parse(from: ["size 700 MB"]).sizeBytes == 700_000_000)
        #expect(StreamQuality.parse(from: ["1,5 GiB"]).sizeBytes == Int64(1.5 * 1_073_741_824))
        #expect(StreamQuality.parse(from: ["no size here"]).sizeBytes == nil)
    }

    @Test func nilTextsAreIgnored() {
        #expect(StreamQuality.parse(from: [nil, "720p", nil]).resolution == 720)
        #expect(StreamQuality.parse(from: [nil, nil]) == StreamQuality())
    }

    @Test func audioFallbackOnlyWhenNothingDecodableIsNamed() {
        #expect(StreamQuality.parse(from: ["DTS"]).audioNeedsFallbackEngine)
        #expect(StreamQuality.parse(from: ["TrueHD"]).audioNeedsFallbackEngine)
        #expect(StreamQuality.parse(from: ["DTS-HD MA"]).audioNeedsFallbackEngine)
        #expect(!StreamQuality.parse(from: ["DTS AAC"]).audioNeedsFallbackEngine, "a decodable track exists")
        #expect(!StreamQuality.parse(from: ["TrueHD AC3"]).audioNeedsFallbackEngine)
        #expect(!StreamQuality.parse(from: ["AAC"]).audioNeedsFallbackEngine)
        #expect(!StreamQuality.parse(from: ["1080p"]).audioNeedsFallbackEngine, "unknown audio is assumed playable")
    }

    @Test func labels() {
        #expect(StreamQuality(resolution: 2160).resolutionLabel == "4K")
        #expect(StreamQuality(resolution: 1080).resolutionLabel == "1080p")
        #expect(StreamQuality().resolutionLabel == nil)
        #expect(StreamSourceKind.bluray.rank > StreamSourceKind.webDL.rank)
        #expect(StreamSourceKind.webDL.rank > StreamSourceKind.webRip.rank)
        #expect(StreamSourceKind.webRip.rank > StreamSourceKind.hdtv.rank)
        #expect(StreamSourceKind.hdtv.rank > StreamSourceKind.dvd.rank)
        #expect(StreamSourceKind.dvd.rank > StreamSourceKind.cam.rank)
    }

    @Test func parsesAStreamUsingNameDescriptionFilenameAndVideoSize() throws {
        let url = try #require(URL(string: "https://e.com/x"))
        let stream = AddonStream(name: "1080p", description: "WEB-DL AAC", source: .direct(url),
                                 behaviorHints: StreamBehaviorHints(videoSize: 5_000_000, filename: "Movie.x264.mkv"))
        let quality = StreamQuality.parse(stream)
        #expect(quality.resolution == 1080 && quality.source == .webDL && quality.videoCodec == .h264 && quality.audioCodecs == [.aac])
        #expect(quality.sizeBytes == 5_000_000, "uses the addon's videoSize")
        let withText = AddonStream(name: "x", description: "💾 82.8 GB", source: .direct(url),
                                   behaviorHints: StreamBehaviorHints(videoSize: 82_773_153_030))
        #expect(StreamQuality.parse(withText).sizeBytes == 82_773_153_030, "the exact byte count wins over the rounded text")
        let textOnly = AddonStream(name: "x", description: "💾 82.8 GB", source: .direct(url))
        #expect(StreamQuality.parse(textOnly).sizeBytes == 82_800_000_000, "text alone reads back as written")
    }

    @Test func seedersAndPeersReadFromTheFormatsAddonsUse() {
        #expect(StreamQuality.parse(from: ["Movie 1080p\n👤 12 💾 1.2 GB ⚙️ Site"]).seeders == 12)
        #expect(StreamQuality.parse(from: ["👤 1,234"]).seeders == 1234, "thousands separators are tolerated")
        #expect(StreamQuality.parse(from: ["👤1234"]).seeders == 1234)
        #expect(StreamQuality.parse(from: ["Seeds: 7"]).seeders == 7)
        #expect(StreamQuality.parse(from: ["Seeders: 8"]).seeders == 8)
        #expect(StreamQuality.parse(from: ["S: 9"]).seeders == 9)
        #expect(StreamQuality.parse(from: ["Peers: 12"]).peers == 12)
        #expect(StreamQuality.parse(from: ["P: 3"]).peers == 3)
        #expect(StreamQuality.parse(from: ["SEEDS: 4 PEERS: 5"]).seeders == 4 && StreamQuality.parse(from: ["SEEDS: 4 PEERS: 5"]).peers == 5,
                "case-insensitive")
        #expect(StreamQuality.parse(from: ["Movie 1080p 💾 1.2 GB"]).seeders == nil)
        #expect(StreamQuality.parse(from: ["Movie 1080p 💾 1.2 GB"]).peers == nil)
    }

    @Test func seedersAndPeersIgnoreTextThatIsNotACount() {
        #expect(StreamQuality.parse(from: ["1080p: 12"]).peers == nil, "p: inside a resolution is not peers")
        #expect(StreamQuality.parse(from: ["Season: 2"]).seeders == nil)
        #expect(StreamQuality.parse(from: ["👤 99999999"]).seeders == nil, "an absurd count is a misread, not a swarm")
    }
}
