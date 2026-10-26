import Foundation

/// Reads the Dolby Vision decoder configuration record (the body of an MP4 dvcC/dvvC atom).
/// Parsing this record does not decode or tone-map Dolby Vision or identify Profile 7 FEL versus MEL.
public struct DolbyVisionConfiguration: Equatable, Sendable {
    public let profile: Int
    public let level: Int
    public let hasRPU: Bool
    public let hasEnhancementLayer: Bool
    public let hasBaseLayer: Bool
    public let compatibilityID: Int

    /// Atoms always contain a 24-byte DOVIDecoderConfigurationRecord. Never read past truncated data.
    public init?(record: Data) {
        guard record.count >= 24 else { return nil }
        let bytes = Array(record.prefix(5))
        guard bytes[0] == 1 else { return nil }
        let profile = Int(bytes[2] >> 1)
        let level = Int((bytes[2] & 1) << 5 | bytes[3] >> 3)
        guard [5, 7, 8].contains(profile), level > 0 else { return nil }
        let hasBaseLayer = bytes[3] & 1 != 0
        guard hasBaseLayer else { return nil }
        self.profile = profile
        self.level = level
        self.hasRPU = bytes[3] & 4 != 0
        self.hasEnhancementLayer = bytes[3] & 2 != 0
        self.hasBaseLayer = hasBaseLayer
        self.compatibilityID = Int(bytes[4] >> 4)
    }

    /// The sample-description atom payload, without its eight-byte MP4 box header.
    public static func parse(atomPayloads: [String: Data]) -> Self? {
        for key in ["dvcC", "dvvC"] {
            if let payload = atomPayloads[key], let configuration = Self(record: payload) { return configuration }
        }
        return nil
    }

    public var baseLayer: String? {
        switch profile {
        case 7: "HDR10"
        case 8 where compatibilityID == 1: "HDR10"
        case 8 where compatibilityID == 4: "HLG"
        default: nil
        }
    }

    public var label: String {
        var text = "Dolby Vision Profile \(profile) (level \(level))"
        if profile == 8 {
            if compatibilityID == 1 { text += " · 8.1" }
            if compatibilityID == 4 { text += " · 8.4" }
        }
        if profile == 7 && hasEnhancementLayer { text += " · dual layer" }
        return text
    }

    /// Do not present base-layer playback or enhanced rendering as verified by parsing alone.
    public var macPlaybackNote: String {
        switch profile {
        case 5:
            "Profile 5 has no HDR10/HLG fallback. macOS Dolby Vision playback requires a supported decoder and container."
        case 7:
            "Profile 7 carries an HDR10 base layer. AVPlayer does not reconstruct its enhancement layer; FEL versus MEL is not known from this record."
        default:
            switch compatibilityID {
            case 1: "Profile 8.1 carries an HDR10 base layer. Dolby Vision processing depends on the Mac and playback path."
            case 4: "Profile 8.4 carries an HLG base layer. Dolby Vision processing depends on the Mac and playback path."
            default: "Profile 8 compatibility is not identified as HDR10 or HLG by this record."
            }
        }
    }
}

/// Reads already-demuxed HEVC Annex B NAL units (not MKV/MP4 containers).
/// In Profile 7, type 62 contains RPU metadata and type 63 wraps the enhancement layer.
/// Removing these NALs leaves the HDR10-compatible base-layer bitstream. It does not remux
/// containers or reconstruct the full Dolby Vision enhancement (MEL/FEL).
public enum DolbyVisionHEVCParser {
    public struct Inspection: Equatable, Sendable {
        public let nalCount: Int
        public let rpuCount: Int
        public let enhancementCount: Int
        public var hasRPU: Bool { rpuCount > 0 }
        public var hasEnhancementLayer: Bool { enhancementCount > 0 }
    }

    /// A NAL requires a two-byte HEVC header; zero-length/malformed NALs are rejected.
    private struct Unit {
        let start: Int
        let header: Int
        let end: Int
        let type: UInt8
    }

    private static func startCodeLength(_ bytes: [UInt8], at index: Int) -> Int? {
        guard index + 2 < bytes.count, bytes[index] == 0, bytes[index + 1] == 0 else { return nil }
        if bytes[index + 2] == 1 { return 3 }
        if index + 3 < bytes.count && bytes[index + 2] == 0 && bytes[index + 3] == 1 { return 4 }
        return nil
    }

    private static func units(_ bytes: [UInt8]) -> [Unit]? {
        guard !bytes.isEmpty else { return nil }
        var result: [Unit] = []
        var start: Int?
        var header = 0
        var i = 0
        while i < bytes.count {
            guard let length = startCodeLength(bytes, at: i) else { i += 1; continue }
            if let start {
                guard i - header >= 2 else { return nil }
                let first = bytes[header]
                guard first & 0x80 == 0, bytes[header + 1] & 0x07 != 0 else { return nil }
                result.append(Unit(start: start, header: header, end: i, type: (first >> 1) & 0x3F))
            } else if bytes[..<i].contains(where: { $0 != 0 }) {
                return nil
            }
            start = i
            header = i + length
            i += length
        }
        guard let start, bytes.count - header >= 2 else { return nil }
        let first = bytes[header]
        guard first & 0x80 == 0, bytes[header + 1] & 0x07 != 0 else { return nil }
        result.append(Unit(start: start, header: header, end: bytes.count, type: (first >> 1) & 0x3F))
        return result
    }

    public static func inspect(annexB: Data) -> Inspection? {
        guard let units = units(Array(annexB)) else { return nil }
        return Inspection(nalCount: units.count, rpuCount: units.filter { $0.type == 62 }.count,
                          enhancementCount: units.filter { $0.type == 63 }.count)
    }

    /// Only Profile 7 has a guaranteed HDR10 base layer; don't strip RPU from Profile 5.
    /// The returned bytes are still raw HEVC Annex B, not a playable video file.
    public static func hdr10BaseLayer(annexB: Data, configuration: DolbyVisionConfiguration) -> Data? {
        guard configuration.profile == 7, configuration.hasBaseLayer else { return nil }
        let bytes = Array(annexB)
        guard let units = units(bytes), !units.isEmpty else { return nil }
        var stripped = Data()
        for unit in units where unit.type != 62 && unit.type != 63 {
            stripped.append(contentsOf: bytes[unit.start..<unit.end])
        }
        return stripped.isEmpty ? nil : stripped
    }
}
