import Foundation
import Testing
@testable import PlayerKit

@Suite struct DolbyVisionParserTests {
    private func record(profile: Int, level: Int = 7, rpu: Bool = true, enhancement: Bool = false,
                        base: Bool = true, compatibility: Int = 0) -> Data {
        var bytes = [UInt8](repeating: 0, count: 24)
        bytes[0] = 1
        bytes[2] = UInt8((profile << 1) | (level >> 5))
        bytes[3] = UInt8(((level & 31) << 3) | (rpu ? 4 : 0) | (enhancement ? 2 : 0) | (base ? 1 : 0))
        bytes[4] = UInt8(compatibility << 4)
        return Data(bytes)
    }

    @Test func profile5HasNoCompatibleBaseLayer() throws {
        let config = try #require(DolbyVisionConfiguration(record: record(profile: 5)))
        #expect(config.profile == 5)
        #expect(config.level == 7)
        #expect(config.hasRPU)
        #expect(!config.hasEnhancementLayer)
        #expect(config.baseLayer == nil)
        #expect(config.label.contains("Profile 5"))
    }

    @Test func profile7DetectsDualLayerWithoutClaimingFEL() throws {
        let config = try #require(DolbyVisionConfiguration(record: record(profile: 7, enhancement: true, compatibility: 6)))
        #expect(config.profile == 7)
        #expect(config.hasEnhancementLayer)
        #expect(config.baseLayer == "HDR10")
        #expect(config.label.contains("dual layer"))
        #expect(config.macPlaybackNote.contains("FEL versus MEL is not known"))
    }

    @Test func profile8RecognisesBaseLayerCompatibility() throws {
        let hdr10 = try #require(DolbyVisionConfiguration.parse(atomPayloads: ["dvvC": record(profile: 8, compatibility: 1)]))
        let hlg = try #require(DolbyVisionConfiguration.parse(atomPayloads: ["dvvC": record(profile: 8, compatibility: 4)]))
        let unspecified = try #require(DolbyVisionConfiguration(record: record(profile: 8, compatibility: 0)))
        #expect(hdr10.baseLayer == "HDR10")
        #expect(hlg.baseLayer == "HLG")
        #expect(unspecified.baseLayer == nil)
        #expect(hdr10.label.contains("8.1"))
        #expect(hlg.label.contains("8.4"))
    }

    @Test func versionLengthAndFlagsAreValidated() {
        #expect(DolbyVisionConfiguration(record: Data([1, 0, 14])) == nil)
        #expect(DolbyVisionConfiguration(record: Data(repeating: 0, count: 24)) == nil)
        #expect(DolbyVisionConfiguration(record: record(profile: 6)) == nil)
        #expect(DolbyVisionConfiguration(record: record(profile: 7, level: 0)) == nil)
        #expect(DolbyVisionConfiguration(record: record(profile: 7, base: false)) == nil)
        #expect(DolbyVisionConfiguration.parse(atomPayloads: ["hvcC": record(profile: 7)]) == nil)
    }

    @Test func annexBInspectionAndHDR10BaseLayerExtraction() throws {
        // VPS, RPU (type 62), enhancement (type 63), IDR (type 19).
        let bytes = Data([0, 0, 0, 1, 0x40, 0x01, 0xAA,
                          0, 0, 1, 0x7C, 0x01, 0xBB,
                          0, 0, 1, 0x7E, 0x01, 0xCC,
                          0, 0, 1, 0x26, 0x01, 0xDD])
        let inspection = try #require(DolbyVisionHEVCParser.inspect(annexB: bytes))
        #expect(inspection.nalCount == 4)
        #expect(inspection.rpuCount == 1)
        #expect(inspection.enhancementCount == 1)
        let profile7 = try #require(DolbyVisionConfiguration(record: record(profile: 7, enhancement: true)))
        let base = try #require(DolbyVisionHEVCParser.hdr10BaseLayer(annexB: bytes, configuration: profile7))
        #expect(base == Data([0, 0, 0, 1, 0x40, 0x01, 0xAA, 0, 0, 1, 0x26, 0x01, 0xDD]))
        let profile5 = try #require(DolbyVisionConfiguration(record: record(profile: 5)))
        #expect(DolbyVisionHEVCParser.hdr10BaseLayer(annexB: bytes, configuration: profile5) == nil)
    }

    @Test func malformedHEVCIsRejected() throws {
        #expect(DolbyVisionHEVCParser.inspect(annexB: Data()) == nil)
        #expect(DolbyVisionHEVCParser.inspect(annexB: Data([0x40, 0x01])) == nil)
        #expect(DolbyVisionHEVCParser.inspect(annexB: Data([0, 0, 1, 0x40])) == nil)
        #expect(DolbyVisionHEVCParser.inspect(annexB: Data([0, 0, 1, 0x40, 0])) == nil)
        #expect(DolbyVisionHEVCParser.inspect(annexB: Data([0, 0, 1, 0x80, 1])) == nil)
    }
}
