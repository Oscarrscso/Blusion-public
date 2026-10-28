import Foundation

public enum AudioCodec: String, Sendable, Equatable, Hashable {
    case aac, ac3, eac3, dts, dtsHD, trueHD, flac, opus, mp3

    /// AVPlayer cannot decode these (PLAN §4).
    public var needsFallbackEngine: Bool { self == .dts || self == .dtsHD || self == .trueHD }

    public var label: String {
        switch self {
        case .aac: "AAC"
        case .ac3: "DD"
        case .eac3: "DD+"
        case .dts: "DTS"
        case .dtsHD: "DTS-HD"
        case .trueHD: "TrueHD"
        case .flac: "FLAC"
        case .opus: "Opus"
        case .mp3: "MP3"
        }
    }
}

public enum VideoCodec: String, Sendable, Equatable, Hashable {
    case h264, hevc, av1
    /// H.266. No decoder on Apple devices, and none in the fallback engine's FFmpeg build (MPVKit 0.41).
    case vvc
    case vp9, mpeg2, vc1
    /// MPEG-4 Part 2 (XviD, DivX).
    case mpeg4

    public var label: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .av1: "AV1"
        case .vvc: "VVC (H.266)"
        case .vp9: "VP9"
        case .mpeg2: "MPEG-2"
        case .vc1: "VC-1"
        case .mpeg4: "MPEG-4 (XviD)"
        }
    }

    /// AVPlayer cannot decode it, whatever the container: the fallback engine (FFmpeg) does.
    var needsFallbackEngine: Bool {
        switch self {
        case .vp9, .mpeg2, .vc1, .mpeg4: true
        case .h264, .hevc, .av1, .vvc: false
        }
    }
}

/// Release source, ordered best to worst by `rank`.
public enum StreamSourceKind: String, Sendable, Equatable, Hashable {
    case bluray, webDL, webRip, hdtv, dvd, cam

    public var rank: Int {
        switch self {
        case .bluray: return 5
        case .webDL: return 4
        case .webRip: return 3
        case .hdtv: return 2
        case .dvd: return 1
        case .cam: return 0
        }
    }

    public var label: String {
        switch self {
        case .bluray: "Blu-ray"
        case .webDL: "WEB-DL"
        case .webRip: "WEBRip"
        case .hdtv: "HDTV"
        case .dvd: "DVD"
        case .cam: "CAM"
        }
    }
}

/// Which Dolby Atmos a release carries, from the codec of its Atmos track: E-AC-3 (Dolby Digital Plus) with Atmos is the lossy
/// streaming kind, TrueHD with Atmos is the lossless Blu-ray kind.
public enum AtmosFormat: String, Sendable, Equatable, Hashable {
    case streaming, lossless
}

/// Facts guessed from a stream's `name`, `description` and filename. Addons put them in free text, so this is heuristic.
public struct StreamQuality: Sendable, Equatable {
    /// Vertical resolution (2160, 1080, 720, 480, …).
    public var resolution: Int?
    /// The text names more than one resolution, so this release's resolution can't be ranked on.
    public var hasConflictingResolution = false
    public var isHDR = false
    public var isDolbyVision = false
    /// HDR10+ dynamic metadata, as the name says. A label, not a verified property of the stream.
    public var isHDR10Plus = false
    public var isHLG = false
    /// The Dolby Vision profile the name gives ("DV P7", "DoVi Profile 8"); 7 for a name that says FEL or MEL.
    public var dolbyVisionProfile: Int?
    /// The name says the profile 7 enhancement layer is the full one (FEL).
    public var hasFullEnhancementLayer = false
    /// Bits per colour channel the text names (8, 10 or 12).
    public var bitDepth: Int?
    public var source: StreamSourceKind?
    /// The text names more than one source, as a WEB-DL and a REMUX would, so this release's source can't be ranked on.
    public var hasConflictingSource = false
    /// The name says REMUX: the disc's own video, not a re-encode.
    public var isRemux = false
    public var videoCodec: VideoCodec?
    /// The text names more than one video codec (an x264 transcoded from HEVC, say), so this release's codec can't be ranked on.
    public var hasConflictingVideoCodec = false
    /// The bitrate in Mbps that the addon's text states, when it states one.
    public var declaredBitrateMbps: Double?
    public var audioCodecs: [AudioCodec] = []
    /// The most channels the text names: 6 for 5.1, 8 for 7.1.
    public var audioChannels: Int?
    public var hasAtmos = false
    public var hasDTSX = false
    public var audioBitrateKbps: Double?
    public var hasReputableGroup = false
    public var sizeBytes: Int64?
    /// Peers that have the whole file and upload it, as the addon's text gives them.
    public var seeders: Int?
    /// Peers still downloading the file, as the addon's text gives them.
    public var peers: Int?
    /// The streaming service the text names, by its release tag ("NF", "AMZN") or its name. Nil when none does.
    public var provider: StreamProvider?

    public init(resolution: Int? = nil, isHDR: Bool = false, isDolbyVision: Bool = false, source: StreamSourceKind? = nil,
                videoCodec: VideoCodec? = nil, audioCodecs: [AudioCodec] = [], hasAtmos: Bool = false, sizeBytes: Int64? = nil,
                seeders: Int? = nil, peers: Int? = nil) {
        self.resolution = resolution
        self.isHDR = isHDR
        self.isDolbyVision = isDolbyVision
        self.source = source
        self.videoCodec = videoCodec
        self.audioCodecs = audioCodecs
        self.hasAtmos = hasAtmos
        self.sizeBytes = sizeBytes
        self.seeders = seeders
        self.peers = peers
    }

    /// True when the only audio the text names is something AVPlayer can't decode. A release that also lists AAC or AC-3 is fine,
    /// because the player picks a decodable track.
    public var audioNeedsFallbackEngine: Bool {
        audioCodecs.contains { $0.needsFallbackEngine } && !audioCodecs.contains { !$0.needsFallbackEngine }
    }

    /// True when the text names AV1 and this device cannot decode AV1 in hardware. AVPlayer then cannot play it, so the fallback engine
    /// does (ADR-006). Where the chip decodes AV1, AVPlayer keeps it, with its PiP and AirPlay.
    public func videoNeedsFallbackEngine(decodesAV1InHardware: Bool) -> Bool {
        guard let videoCodec, !hasConflictingVideoCodec else { return false }
        return (videoCodec == .av1 && !decodesAV1InHardware) || videoCodec.needsFallbackEngine
    }

    /// No engine in the app decodes it (VVC/H.266): shown as unsupported, and handed to another player when Settings allows.
    public var videoIsUndecodable: Bool { videoCodec == .vvc && !hasConflictingVideoCodec }

    /// The kind of Atmos, read from the audio codec beside it, not from the release's source: TrueHD wins when both are named, since
    /// a lossless track is the one a viewer picks Atmos for. Nil when there is no Atmos, or the codec does not say which kind.
    public var atmosFormat: AtmosFormat? {
        guard hasAtmos else { return nil }
        if audioCodecs.contains(.trueHD) { return .lossless }
        if audioCodecs.contains(.eac3) { return .streaming }
        return nil
    }

    public var resolutionLabel: String? {
        switch resolution {
        case .some(let value) where value >= 2160: return "4K"
        case .some(let value): return "\(value)p"
        case .none: return nil
        }
    }

    public static func parse(from texts: [String?]) -> StreamQuality {
        let text = texts.compactMap { $0 }.joined(separator: " \n ").lowercased()
        var quality = StreamQuality()
        guard !text.isEmpty else { return quality }

        quality.resolution = resolution(in: text)
        quality.hasConflictingResolution = namedHeights(in: text).count > 1
        quality.isDolbyVision = matches(#"\b(dolby[ .\-]?vision|dovi|dv)\b"#, in: text)
        quality.isHDR10Plus = matches(hdr10PlusPattern, in: text)
        quality.isHLG = matches(hlgPattern, in: text)
        quality.isHDR = matches(#"\bhdr(10)?\+?\b"#, in: text) || quality.isDolbyVision || quality.isHDR10Plus || quality.isHLG
        quality.hasFullEnhancementLayer = quality.isDolbyVision && matches(felPattern, in: text)
        quality.dolbyVisionProfile = quality.isDolbyVision ? dolbyVisionProfile(in: text) : nil
        quality.bitDepth = bitDepth(in: text)
        quality.source = source(in: text)
        quality.hasConflictingSource = namedValues(sourceRules, in: text).count > 1
        quality.isRemux = matches(remuxPattern, in: text)
        quality.videoCodec = videoCodec(in: text)
        quality.hasConflictingVideoCodec = namedValues(videoCodecRules, in: text).count > 1
        quality.declaredBitrateMbps = positiveNumber(bitratePattern, in: text)
        quality.audioCodecs = audioCodecs(in: text)
        quality.audioChannels = audioChannels(in: text)
        quality.hasAtmos = matches(#"\batmos\b"#, in: text)
        quality.hasDTSX = matches(dtsxPattern, in: text)
        quality.audioBitrateKbps = positiveNumber(audioBitratePattern, in: text)
        quality.hasReputableGroup = matches(groupPattern, in: text)
        quality.sizeBytes = size(in: text)
        // The counted form ("12 seeders") is read before the labelled one, which would otherwise take the next number as the count.
        quality.seeders = swarmCount(seedersPattern, in: text) ?? swarmCount(seedersCountedPattern, in: text)
            ?? swarmCount(seedersLabelledPattern, in: text)
        quality.peers = swarmCount(#"(?:\bpeers?:|\bp:)\s*(\d{1,3}(?:,\d{3})+|\d+)"#, in: text)
        quality.provider = StreamProvider.detect(in: texts)
        return quality
    }

    public static func parse(_ stream: AddonStream) -> StreamQuality {
        var quality = parse(from: [stream.name, stream.description, stream.behaviorHints.filename])
        // The service comes from the name or file name first: a description can name a service the release is not from.
        quality.provider = StreamProvider.detect(in: [stream.name, stream.behaviorHints.filename, stream.description])
        // The addon's exact byte count is the one authority; the size written in its text is rounded, and only a fallback.
        if let size = stream.behaviorHints.videoSize, size > 0 { quality.sizeBytes = size }
        return quality
    }

    // MARK: - Pattern helpers

    /// Seeder and peer counts above this are taken as a misread number, not a swarm.
    private static let maxSwarmCount = 1_000_000

    /// The count a pattern captures (commas allowed), or nil when there is none or it is absurd.
    private static func swarmCount(_ pattern: String, in text: String) -> Int? {
        guard let match = firstMatch(pattern, in: text), match.count == 2,
              let count = Int(match[1].replacingOccurrences(of: ",", with: "")), count <= maxSwarmCount else { return nil }
        return count
    }

    /// Resolution words, most specific first. Each names the height it stands for.
    private static let resolutionRules: [(pattern: String, value: Int)] = [
        (#"\b(2160p|4k|uhd)\b"#, 2160),
        (#"\b1440p\b"#, 1440),
        (#"\b(1080[pi]|fhd|full[ .\-]?hd)\b"#, 1080),
        (#"\b(720p|hd720)\b"#, 720),
        (#"\b576p\b"#, 576),
        (#"\b480p\b"#, 480),
        (#"\b360p\b"#, 360),
    ]

    /// "SD" as a word. Too common in release text to contradict a resolution, so it sets one only when nothing else does.
    private static let bareSDPattern = #"\bsd\b"#

    /// Codec words. Their digits read as a width in "1080 x264", so they are taken out before a WIDTHxHEIGHT is read. A codec word that is
    /// the width of a size ("h.264 x 1080") stays, so the height after it still reads.
    private static let codecWordPattern = #"(?<![a-z])(x26[45]|h[ .]?26[45]|hevc|avc|av1)(?![a-z0-9])(?!\s?x\s?\d)"#

    /// A WIDTHxHEIGHT pair such as 1920x1080.
    private static let dimensionPattern = #"\b(\d{3,4})\s?x\s?(\d{3,4})\b"#

    /// A bare standard height beside a codec word, before or after it ("1080 x264", "x265 2160"). It is a weaker signal than "1080p": it sets
    /// the resolution only when nothing else does, and it never counts as a contradiction. A height followed by a unit ("x264 720 MB",
    /// "x264 720 fps") is left out. Group 1 holds the height before the codec word, group 2 the one after.
    // swiftlint:disable:next line_length
    private static let codecAdjacentHeightPattern = #"(?<![\d.])(2160|1440|1080|720|576|480)(?=\s?(?:x26[45]|h[ .]?26[45]|hevc|avc|av1)(?![a-z0-9]))|\b(?:x26[45]|h[ .]?26[45]|hevc|avc|av1)\s(2160|1440|1080|720|576|480)(?!\d)(?!\s?(?:[kmg]i?b(?:ps|it)?|fps|subs?)\b)"#

    private static func resolution(in text: String) -> Int? {
        if let rule = resolutionRules.first(where: { matches($0.pattern, in: text) }) { return rule.value }
        // Explicit pixel dimensions win over the bare SD word, and so does a standard height beside a codec word.
        if let height = dimensionHeight(in: text) ?? codecAdjacentHeight(in: text) { return height }
        return matches(bareSDPattern, in: text) ? 480 : nil
    }

    /// The bare standard height beside a codec word, or nil.
    private static func codecAdjacentHeight(in text: String) -> Int? {
        guard let match = firstMatch(codecAdjacentHeightPattern, in: text), match.count == 3 else { return nil }
        return Int(match[1].isEmpty ? match[2] : match[1])
    }

    /// The height in a WIDTHxHEIGHT pair such as 1920x1080. Codec words come out first, so "1080 x264" is not a 1080 by 264 size.
    private static func dimensionHeight(in text: String) -> Int? {
        let unpaired = expressions[codecWordPattern]?
            .stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ") ?? text
        guard let match = firstMatch(dimensionPattern, in: unpaired), match.count == 3, let height = Int(match[2]),
              (240...4320).contains(height) else { return nil }
        return height
    }

    /// The heights the text names, for the contradiction check. A bare "sd" is left out, as it is for the resolution.
    private static func namedHeights(in text: String) -> Set<Int> {
        var heights = namedValues(resolutionRules, in: text)
        if let height = dimensionHeight(in: text) { heights.insert(height) }
        return heights
    }

    /// Source words, most specific first. The first rule that matches sets the source.
    private static let sourceRules: [(pattern: String, value: StreamSourceKind)] = [
        (#"\b(hdcam|camrip|cam|telesync|hdts|tsrip)\b"#, .cam),
        (#"\b(blu[ .\-]?ray|bdrip|brrip|remux)\b"#, .bluray),
        (#"\bweb[ .\-]?dl\b"#, .webDL),
        (#"\bweb[ .\-]?rip\b"#, .webRip),
        (#"\bhdtv\b"#, .hdtv),
        (#"\b(dvdrip|dvd)\b"#, .dvd),
    ]

    private static func source(in text: String) -> StreamSourceKind? {
        sourceRules.first(where: { matches($0.pattern, in: text) })?.value
    }

    /// The distinct values that the rules give for the words the text names. More than one is a contradiction.
    private static func namedValues<Value: Hashable>(_ rules: [(pattern: String, value: Value)], in text: String) -> Set<Value> {
        Set(rules.filter { matches($0.pattern, in: text) }.map { $0.value })
    }

    /// Video codec words, in the order they are tried. The first that matches sets the codec.
    private static let videoCodecRules: [(pattern: String, value: VideoCodec)] = [
        (#"\b(vvc|x266|h[ .]?266)\b"#, .vvc),
        (#"\b(x265|h[ .]?265|hevc)\b"#, .hevc),
        (#"\b(x264|h[ .]?264|avc)\b"#, .h264),
        (#"\bav1\b"#, .av1),
        (#"\bvp9\b"#, .vp9),
        (#"\bvc[ .\-]?1\b"#, .vc1),
        (#"\b(mpeg[ .\-]?2|mpeg2video)\b"#, .mpeg2),
        (#"\b(xvid|divx)\b"#, .mpeg4),
    ]

    private static func dolbyVisionProfile(in text: String) -> Int? {
        for pattern in [dolbyVisionProfilePattern, profilePattern] {
            if let match = firstMatch(pattern, in: text), match.count > 1, let profile = Int(match[1]) { return profile }
        }
        return matches(enhancementLayerPattern, in: text) ? 7 : nil
    }

    private static let hdr10PlusPattern = #"\bhdr10(\+|plus)|\bhdr10p\b"#
    private static let hlgPattern = #"\bhlg\b"#
    private static let felPattern = #"\bfel\b"#
    private static let enhancementLayerPattern = #"\b(fel|mel)\b"#
    private static let dolbyVisionProfilePattern = #"\b(?:dv|dovi|dolby[ .\-]?vision)[ .\-]?(?:profile[ .\-]?|p)(\d)\b"#
    private static let profilePattern = #"\bprofile[ .\-]?(\d)\b"#

    private static func videoCodec(in text: String) -> VideoCodec? {
        videoCodecRules.first(where: { matches($0.pattern, in: text) })?.value
    }

    /// Codecs are tested most specific first and each match is blanked out, so "E-AC3" doesn't also read as "AC3" and "DTS-HD" doesn't also read as "DTS".
    private static func audioCodecs(in text: String) -> [AudioCodec] {
        var remaining = text
        var found: [AudioCodec] = []
        func take(_ codec: AudioCodec, _ pattern: String) {
            guard matches(pattern, in: remaining) else { return }
            if !found.contains(codec) { found.append(codec) }
            if let regex = expressions[pattern] {
                remaining = regex.stringByReplacingMatches(in: remaining, range: NSRange(remaining.startIndex..., in: remaining), withTemplate: " ")
            }
        }
        take(.dtsHD, #"\b(dts[ .\-]?hd([ .\-]?ma)?|dts[ .:\-]?x)\b"#)
        take(.dts, #"\bdts\b"#)
        take(.trueHD, #"\btrue[ .\-]?hd\b"#)
        take(.eac3, #"\b(e[ .\-]?ac[ .\-]?3|ddp(\d\.\d)?|dd\+)(?=\W|$)"#)
        take(.ac3, #"\b(ac[ .\-]?3|dd5[ .]1|dd2[ .]0|dolby[ .\-]?digital)\b"#)
        take(.aac, #"\baac(\d\.\d)?\b"#)
        take(.flac, #"\bflac\b"#)
        take(.opus, #"\bopus\b"#)
        take(.mp3, #"\bmp3\b"#)
        return found
    }

    /// Bits per channel the text names ("10bit", "8-bit"). "Hi10P" is 10-bit by name.
    private static func bitDepth(in text: String) -> Int? {
        if let match = firstMatch(bitDepthPattern, in: text), match.count == 2, let depth = Int(match[1]) { return depth }
        return matches(highBitDepthPattern, in: text) ? 10 : nil
    }

    /// The most channels the text names for a layout such as "5.1" or "7.1", as a count: 5.1 is six. A size such as "5.1 GB" is not one.
    private static func audioChannels(in text: String) -> Int? {
        guard let regex = expressions[channelLayoutPattern] else { return nil }
        let counts = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> Int? in
            guard let front = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
                  let lfe = Range(match.range(at: 2), in: text).flatMap({ Int(text[$0]) }) else { return nil }
            return front + lfe
        }
        return counts.max()
    }

    /// The number a pattern's capture reads as, when it is a positive, finite value.
    private static func positiveNumber(_ pattern: String, in text: String) -> Double? {
        guard let match = firstMatch(pattern, in: text), match.count == 2,
              let value = Double(match[1]), value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func size(in text: String) -> Int64? {
        guard let match = firstMatch(#"(\d+(?:[.,]\d+)?)\s?(gb|gib|mb|mib)\b"#, in: text), match.count == 3,
              let value = Double(match[1].replacingOccurrences(of: ",", with: ".")) else { return nil }
        // "GB"/"MB" are decimal, as the size is shown (ByteCountFormatter's file style), so "82.8 GB" reads back as 82.8 GB.
        // Only "GiB"/"MiB" are binary.
        let isBinary = match[2].hasSuffix("ib")
        let multiplier: Double = match[2].hasPrefix("g") ? (isBinary ? 1_073_741_824 : 1_000_000_000) : (isBinary ? 1_048_576 : 1_000_000)
        return Int64(value * multiplier)
    }

    private static let dtsxPattern = #"\bdts[ .:\-]?(?:x|hd[ .\-]?ma[ .:\-]?x)\b"#
    private static let audioBitratePattern = #"([0-9]+(?:\.[0-9]+)?)\s*(?:kbps|kb/s|kbit/s)\b"#
    // Modest, bounded reputation bonus; unknown groups and filename languages remain neutral.
    private static let groupPattern = #"(?:-|\bgroup\s*[:=]\s*)(?:framestor|epsilon|wildcat|cinephiles|hdt|bhdstudio|ctrlhd|don|d-z0n3|ebp|ntb|flux|cmrg|playweb|successfulcrab)(?![a-z0-9])"#
    private static let remuxPattern = #"\bremux\b"#
    private static let bitDepthPattern = #"\b(8|10|12)[ .\-]?bits?\b"#
    private static let highBitDepthPattern = #"\bhi10p?\b"#
    private static let bitratePattern = #"([0-9]+(?:\.[0-9]+)?)\s*(?:mbps|mb/s|mbit/s)\b"#
    /// A channel layout: the front channels, then the LFE channel, so "5.1" reads as 5 and 1. Not followed by a digit or a size unit.
    private static let channelLayoutPattern = #"(?<!\d)([1-9])\.([01])(?!\d|\s?(?:gb|gib|mb|mib)\b)"#
    private static let seedersPattern = #"(?:👤|👥|🌱|\bseed(?:s|ers)?:|\bs:)\s*(\d{1,3}(?:,\d{3})+|\d+)"#
    private static let seedersLabelledPattern = #"\bseeders?\s*[:=]?\s*(\d{1,3}(?:,\d{3})+|\d+)"#
    private static let seedersCountedPattern = #"(\d{1,3}(?:,\d{3})+|\d+)\s*seeders?\b"#

    /// Fixed release patterns are compiled once and shared safely across parses.
    private static let expressions: [String: NSRegularExpression] = {
        var patterns = [
            #"\b(dolby[ .\-]?vision|dovi|dv)\b"#,
            #"\bhdr(10)?\+?\b"#,
            #"\batmos\b"#,
            StreamQuality.hdr10PlusPattern, StreamQuality.hlgPattern, StreamQuality.felPattern, StreamQuality.enhancementLayerPattern,
            StreamQuality.dolbyVisionProfilePattern, StreamQuality.profilePattern,
            StreamQuality.remuxPattern, StreamQuality.dtsxPattern, StreamQuality.audioBitratePattern, StreamQuality.groupPattern,
            StreamQuality.bitDepthPattern,
            StreamQuality.highBitDepthPattern,
            StreamQuality.bitratePattern,
            StreamQuality.channelLayoutPattern,
            StreamQuality.dimensionPattern,
            StreamQuality.codecWordPattern,
            StreamQuality.codecAdjacentHeightPattern,
            StreamQuality.bareSDPattern,
            #"\b(dts[ .\-]?hd([ .\-]?ma)?|dts[ .:\-]?x)\b"#,
            #"\bdts\b"#,
            #"\btrue[ .\-]?hd\b"#,
            #"\b(e[ .\-]?ac[ .\-]?3|ddp(\d\.\d)?|dd\+)(?=\W|$)"#,
            #"\b(ac[ .\-]?3|dd5[ .]1|dd2[ .]0|dolby[ .\-]?digital)\b"#,
            #"\baac(\d\.\d)?\b"#,
            #"\bflac\b"#,
            #"\bopus\b"#,
            #"\bmp3\b"#,
            #"(\d+(?:[.,]\d+)?)\s?(gb|gib|mb|mib)\b"#,
            StreamQuality.seedersPattern,
            StreamQuality.seedersLabelledPattern,
            StreamQuality.seedersCountedPattern,
            #"(?:\bpeers?:|\bp:)\s*(\d{1,3}(?:,\d{3})+|\d+)"#,
        ]
        patterns += StreamQuality.resolutionRules.map { $0.pattern }
        patterns += StreamQuality.sourceRules.map { $0.pattern }
        patterns += StreamQuality.videoCodecRules.map { $0.pattern }
        return Dictionary(uniqueKeysWithValues: patterns.compactMap { pattern in
            (try? NSRegularExpression(pattern: pattern)).map { (pattern, $0) }
        })
    }()

    private static func matches(_ pattern: String, in text: String) -> Bool {
        expressions[pattern]?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Whole match followed by capture groups, or nil.
    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = expressions[pattern],
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
