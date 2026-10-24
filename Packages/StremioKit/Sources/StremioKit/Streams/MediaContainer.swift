import Foundation

public enum MediaContainer: String, Sendable, Equatable, Hashable, CaseIterable {
    case mp4, mov, m4v, hls
    case matroska, webm, avi, mpegTS, mpegPS, flv, ogg, asf, wav, mp3

    /// Containers AVPlayer opens natively (PLAN §4).
    public var isNativelyPlayable: Bool {
        switch self {
        case .mp4, .mov, .m4v, .hls: return true
        default: return false
        }
    }
}

/// Container detection from bytes, Content-Type and file extension, in that order of trust. URLs often have no extension.
public enum ContainerSniffer {
    /// Needs at least ~12 bytes; MPEG-TS confirmation wants ≥ 189.
    public static func container(fromBytes data: Data) -> MediaContainer? {
        let bytes = [UInt8](data.prefix(4096))
        guard bytes.count >= 4 else { return nil }

        // HLS: a playlist starts with #EXTM3U (maybe after a BOM or whitespace).
        var start = 0
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { start = 3 }
        while start < bytes.count, bytes[start] == 0x20 || bytes[start] == 0x0A || bytes[start] == 0x0D || bytes[start] == 0x09 { start += 1 }
        if bytes.count >= start + 7, Array(bytes[start..<start + 7]) == Array("#EXTM3U".utf8) { return .hls }

        // ISO base media: `ftyp` at offset 4, brand at offset 8.
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            switch brand {
            case "qt  ": return .mov
            case "M4V ", "M4VH", "M4VP": return .m4v
            default: return .mp4
            }
        }
        // Matroska / WebM: EBML header.
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            let head = String(decoding: bytes.prefix(64), as: UTF8.self).lowercased()
            return head.contains("webm") ? .webm : .matroska
        }
        // RIFF: AVI or WAV.
        if bytes.count >= 12, bytes.starts(with: Array("RIFF".utf8)) {
            let kind = String(decoding: bytes[8..<12], as: UTF8.self)
            if kind == "AVI " { return .avi }
            if kind == "WAVE" { return .wav }
        }
        if bytes.starts(with: Array("FLV".utf8)) && bytes.count > 3 && bytes[3] == 0x01 { return .flv }
        if bytes.starts(with: Array("OggS".utf8)) { return .ogg }
        if bytes.starts(with: [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) { return .asf }
        if bytes.starts(with: [0x00, 0x00, 0x01, 0xBA]) { return .mpegPS }
        if bytes.starts(with: Array("ID3".utf8)) || (bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0) { return .mp3 }
        // MPEG-TS: sync byte 0x47 every 188 bytes.
        if bytes.count >= 377, bytes[0] == 0x47, bytes[188] == 0x47, bytes[376] == 0x47 { return .mpegTS }
        return nil
    }

    public static func container(fromContentType contentType: String?) -> MediaContainer? {
        guard let raw = contentType?.split(separator: ";").first else { return nil }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "video/mp4", "audio/mp4", "application/mp4": return .mp4
        case "video/quicktime": return .mov
        case "video/x-m4v": return .m4v
        case "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl", "application/mpegurl": return .hls
        case "video/x-matroska", "video/matroska", "audio/x-matroska": return .matroska
        case "video/webm", "audio/webm": return .webm
        case "video/x-msvideo", "video/avi", "video/msvideo": return .avi
        case "video/mp2t", "video/mpeg2-ts": return .mpegTS
        case "video/mpeg", "video/x-mpeg": return .mpegPS
        case "video/x-flv": return .flv
        case "video/ogg", "application/ogg", "audio/ogg": return .ogg
        case "video/x-ms-wmv", "video/x-ms-asf": return .asf
        case "audio/mpeg", "audio/mp3": return .mp3
        case "audio/wav", "audio/x-wav", "audio/wave": return .wav
        default: return nil   // application/octet-stream, text/plain, … say nothing
        }
    }

    public static func container(fromPathExtension ext: String) -> MediaContainer? {
        switch ext.lowercased() {
        case "mp4", "m4a": return .mp4
        case "m4v": return .m4v
        case "mov": return .mov
        case "m3u8", "m3u": return .hls
        case "mkv", "mka": return .matroska
        case "webm": return .webm
        case "avi": return .avi
        case "ts", "m2ts", "mts": return .mpegTS
        case "mpg", "mpeg", "vob": return .mpegPS
        case "flv": return .flv
        case "ogv", "ogg": return .ogg
        case "wmv", "asf": return .asf
        case "mp3": return .mp3
        case "wav": return .wav
        default: return nil
        }
    }

    /// From the addon's `filename` hint, then the URL path's extension.
    public static func container(url: URL, filename: String?) -> MediaContainer? {
        if let filename, let found = container(fromPathExtension: (filename as NSString).pathExtension) { return found }
        return container(fromPathExtension: url.pathExtension)
    }

    /// Bytes beat Content-Type beat extension.
    public static func detect(bytes: Data?, contentType: String?, url: URL, filename: String? = nil) -> MediaContainer? {
        if let bytes, let found = container(fromBytes: bytes) { return found }
        if let found = container(fromContentType: contentType) { return found }
        return container(url: url, filename: filename)
    }
}

public protocol ContainerSniffing: Sendable {
    func sniff(url: URL, headers: [String: String]) async -> MediaContainer?
}

/// Sniffs with a ranged GET of the first 4 KB. `nil` means "could not tell", never an error.
public struct RangedContainerSniffer: ContainerSniffing {
    private let client: AddonClient

    public init(client: AddonClient) {
        self.client = client
    }

    public func sniff(url: URL, headers: [String: String]) async -> MediaContainer? {
        guard let prefix = try? await client.prefix(of: url, bytes: 4096, headers: headers) else { return nil }
        return ContainerSniffer.detect(bytes: prefix.data, contentType: prefix.contentType, url: url)
    }
}
