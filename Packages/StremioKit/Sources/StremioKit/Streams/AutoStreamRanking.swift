import Foundation

/// The one quality model behind every automatic choice: Auto Pick, Play Best, automatic starts, episode switching, fallback ordering and
/// downloads. Player policy has already removed what this device cannot play. Then, in order:
/// - a release that plays now outranks one that must download first (`Assessment.needsDownload`);
/// - an explicit resolution preference is a constraint: the releases nearest that resolution compete first;
/// - the additive score decides. A source preference or binge continuity adds `preferenceBonus` to the releases it names, so it only
///   breaks near-ties and never outweighs a clearly better release.
/// Every fact of the score is kept as a `Contribution`, so `explain` can say why a release wins or loses.
public enum AutoStreamRanking {
    /// Points a preference adds to a release that matches it: the source kind Settings prefers, or the addon a binge continues from. It is
    /// less than one resolution step (6 points), so a clearly better release still wins.
    public static let preferenceBonus: Double = 4

    /// One fact of the score: what the release says about it (`detail`, nil when it says nothing) and the points it adds or takes away.
    public struct Contribution: Sendable, Equatable {
        public let fact: String
        public let detail: String?
        public let points: Double
    }

    public struct Assessment: Sendable {
        public let item: RankedStream
        public let qualityScore: Double
        public let bitrateMbps: Double?
        public let seeders: Int?
        public let isRemux: Bool
        /// The release must download before it plays (an uncached torrent on a streaming server). It ranks below every release that plays now.
        public let needsDownload: Bool
        /// Every fact of the score, in a fixed order, so two releases line up fact by fact.
        public let contributions: [Contribution]
    }

    /// Why a release sits where it does: the reasons are plain lines for logs and tests.
    public struct Explanation: Sendable, Equatable {
        public let id: String
        public let title: String
        /// 1 for the chosen release.
        public let rank: Int
        public let qualityScore: Double
        public let reasons: [String]
    }

    public static func assess(_ item: RankedStream, duration: TimeInterval?, preferences: RankingPreferences = .init(),
                              continuing: BingeContext? = nil) -> Assessment {
        let quality = item.quality
        // Contradicted facts earn no bonus and take a bounded penalty.
        let resolution = quality.hasConflictingResolution ? nil : quality.resolution
        let source = quality.hasConflictingSource ? nil : quality.source
        let codec = quality.hasConflictingVideoCodec ? nil : quality.videoCodec
        let bitrate = bitrateMbps(quality, duration: duration)
        var playableAudio = quality
        if case .native = item.route {
            playableAudio.audioCodecs.removeAll { $0.needsFallbackEngine }
            playableAudio.hasDTSX = false
        }
        let contradictions = [quality.hasConflictingResolution, quality.hasConflictingSource, quality.hasConflictingVideoCodec].filter { $0 }.count
        let statedRateContradictsSize: Bool = {
            guard let declared = quality.declaredBitrateMbps, let measured = sizeOverRuntimeMbps(quality, duration: duration) else { return false }
            return max(declared, measured) > 2 * min(declared, measured)
        }()
        // An implausibly small disc copy should not profit from a REMUX label.
        let implausibleRemux = quality.isRemux && (bitrate.map { $0 < ((resolution ?? 0) >= 2160 ? 15 : 8) } ?? false)
        let remuxCounts = quality.isRemux && !quality.hasConflictingSource
        let cached = StreamAvailability.isCached(item.stream)
        let seederPoints: Double = {
            guard !cached, let seeds = quality.seeders else { return 0 }
            return seeds == 0 ? -35 : min(5, log2(Double(max(1, seeds))))
        }()
        let prefers = preferences.sourcePreference.prefers(item.stream)
        let continues = continuing.map { previous in
            previous.addonID != nil && previous.addonID == item.addon.id && previous.bingeGroup == item.bingeContext?.bingeGroup
        } ?? false

        let contributions = [
            Contribution(fact: "resolution", detail: resolution.map(resolutionLabel), points: resolutionPoints(resolution)),
            Contribution(fact: "source", detail: source?.label, points: sourcePoints(source)),
            Contribution(fact: "REMUX", detail: remuxCounts ? "REMUX" : nil, points: remuxCounts ? remuxPoints : 0),
            Contribution(fact: "video codec", detail: codec?.label, points: videoCodecPoints(codec)),
            Contribution(fact: "bit depth", detail: quality.bitDepth.map { "\($0)-bit" }, points: bitDepthPoints(quality.bitDepth)),
            Contribution(fact: "HDR", detail: hdrLabel(quality), points: hdrPoints(quality)),
            Contribution(fact: "bitrate", detail: bitrate.map { "\(format($0)) Mbps" }, points: bitratePoints(bitrate, resolution: resolution, codec: codec)),
            Contribution(fact: "audio", detail: audioLabel(playableAudio), points: audioPoints(playableAudio)),
            Contribution(fact: "provider", detail: quality.provider?.name, points: quality.provider == nil ? 0 : 3),
            Contribution(fact: "release group", detail: quality.hasReputableGroup ? "reputable" : nil, points: quality.hasReputableGroup ? 3 : 0),
            Contribution(fact: "contradictions", detail: contradictions == 0 ? nil : "\(contradictions)", points: -8 * Double(contradictions)),
            Contribution(fact: "stated bitrate", detail: statedRateContradictsSize ? "contradicts size" : nil,
                         points: statedRateContradictsSize ? -8 : 0),
            Contribution(fact: "REMUX bitrate", detail: implausibleRemux ? "implausibly small" : nil, points: implausibleRemux ? -18 : 0),
            Contribution(fact: "cache", detail: cached ? "cached" : nil, points: cached ? 6 : 0),
            Contribution(fact: "seeders", detail: !cached ? quality.seeders.map(String.init) : nil, points: seederPoints),
            Contribution(fact: "source preference", detail: prefers ? preferences.sourcePreference.title : nil,
                         points: prefers ? preferenceBonus : 0),
            Contribution(fact: "continuity", detail: continues ? "same addon" : nil, points: continues ? preferenceBonus : 0),
        ]
        return Assessment(item: item, qualityScore: contributions.reduce(0) { $0 + $1.points }, bitrateMbps: bitrate, seeders: quality.seeders,
                          isRemux: quality.isRemux, needsDownload: StreamAvailability.cacheStatus(for: item.stream) == .uncached,
                          contributions: contributions)
    }

    public static func best(from items: [RankedStream], duration: TimeInterval?, preferences: RankingPreferences = .init(),
                            continuing: BingeContext? = nil) -> Assessment? {
        ranked(items, duration: duration, preferences: preferences, continuing: continuing).first
    }

    /// The automatic candidates (see `StreamAvailability`), best first, under the order described at the top of this type.
    public static func ranked(_ items: [RankedStream], duration: TimeInterval?, preferences: RankingPreferences = .init(),
                              continuing: BingeContext? = nil) -> [Assessment] {
        StreamAvailability.automaticCandidates(from: items)
            .map { assess($0, duration: duration, preferences: preferences, continuing: continuing) }
            .sorted { a, b in
                if a.needsDownload != b.needsDownload { return !a.needsDownload }
                if let preferred = preferences.preferredResolution {
                    let da = distance(a.item.quality, from: preferred)
                    let db = distance(b.item.quality, from: preferred)
                    if da != db { return da < db }
                }
                if a.qualityScore != b.qualityScore { return a.qualityScore > b.qualityScore }
                return StreamRanking.isOrdered(a.item, before: b.item)
            }
    }

    /// Why each release ranks where it does. The chosen release is compared with the one behind it, and every other release with the chosen
    /// one. A reason names a fact the two score differently on, largest difference first, with both releases' points for it.
    public static func explain(_ ranked: [Assessment]) -> [Explanation] {
        guard let chosen = ranked.first else { return [] }
        return ranked.enumerated().map { index, entry in
            var reasons: [String] = []
            let rival = index == 0 ? ranked.dropFirst().first : chosen
            if let rival {
                let gap = entry.qualityScore - rival.qualityScore
                if index == 0 {
                    reasons.append("chosen, \(amount(gap)) points ahead of \(rival.item.title)")
                } else {
                    reasons.append("\(amount(-gap)) points behind \(chosen.item.title)")
                }
                if entry.needsDownload && !rival.needsDownload { reasons.append("must download before it plays") }
                let pairs = zip(entry.contributions, rival.contributions).filter { pair in pair.0.points != pair.1.points }
                    .sorted { lhs, rhs in abs(lhs.0.points - lhs.1.points) > abs(rhs.0.points - rhs.1.points) }
                for pair in pairs {
                    reasons.append("\(pair.0.fact) \(describe(pair.0)) against \(describe(pair.1))")
                }
            } else {
                reasons.append("the only candidate")
            }
            return Explanation(id: entry.item.id, title: entry.item.title, rank: index + 1, qualityScore: entry.qualityScore, reasons: reasons)
        }
    }

    private static let remuxPoints: Double = 10

    private static func distance(_ quality: StreamQuality, from preferred: Int) -> Int {
        guard !quality.hasConflictingResolution, let resolution = quality.resolution else { return Int.max }
        return abs(resolution - preferred)
    }

    private static func describe(_ contribution: Contribution) -> String {
        "\(contribution.detail ?? "none") (\(signed(contribution.points)))"
    }

    /// Points with a sign, to one decimal place at most: "+12", "-7.4".
    private static func signed(_ value: Double) -> String {
        let text = amount(value)
        return value >= 0 ? "+\(text)" : "-\(text)"
    }

    /// The magnitude of points, to one decimal place at most, without a sign.
    private static func amount(_ value: Double) -> String {
        let rounded = (abs(value) * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func resolutionLabel(_ height: Int) -> String {
        height >= 2160 ? "4K" : "\(height)p"
    }

    private static func hdrLabel(_ quality: StreamQuality) -> String? {
        quality.isDolbyVision ? "Dolby Vision" : quality.isHDR ? "HDR" : nil
    }

    private static func audioLabel(_ quality: StreamQuality) -> String? {
        quality.audioCodecs.isEmpty ? nil : quality.audioCodecs.map(\.label).joined(separator: ", ")
    }

    // MARK: - Video

    private static func resolutionPoints(_ height: Int?) -> Double {
        guard let height else { return 0 }
        if height >= 2160 { return 24 }
        if height >= 1440 { return 18 }
        if height >= 1080 { return 12 }
        if height >= 720 { return 6 }
        if height >= 576 { return 3 }
        if height >= 480 { return 1 }
        return 0
    }

    /// Blu-ray is the source of a REMUX and of most encodes made from discs; a cam is the worst source there is.
    private static func sourcePoints(_ source: StreamSourceKind?) -> Double {
        switch source {
        case .bluray?: return 14
        case .webDL?: return 10
        case .webRip?: return 6
        case .hdtv?: return 3
        case .dvd?: return 1
        case .cam?: return -40
        case nil: return 0
        }
    }

    private static func videoCodecPoints(_ codec: VideoCodec?) -> Double {
        switch codec {
        case .hevc?, .av1?: return 2
        case .vp9?: return 1
        case .h264?, nil: return 0
        // Old codecs mean old, low-bitrate encodes; VVC cannot be decoded here at all.
        case .mpeg2?, .vc1?, .mpeg4?: return -1
        case .vvc?: return -4
        }
    }

    private static func bitDepthPoints(_ depth: Int?) -> Double {
        (depth ?? 0) >= 10 ? 3 : 0
    }

    private static func hdrPoints(_ quality: StreamQuality) -> Double {
        quality.isDolbyVision ? 5 : quality.isHDR ? 3 : 0
    }

    /// Size relative to runtime, against what the resolution usually needs. Doubling the rate is worth 5 points, and the score is capped
    /// above and floored below, so a huge file gains no more than a well-encoded one, and a starved one loses only so much.
    private static func bitratePoints(_ mbps: Double?, resolution: Int?, codec: VideoCodec?) -> Double {
        guard let mbps, let resolution, let reference = referenceMbps(resolution) else { return 0 }
        // HEVC and AV1 reach the same picture at a lower rate than H.264.
        let efficiency: Double = switch codec {
        case .hevc?, .vp9?: 0.7
        case .av1?: 0.6
        case .vvc?: 0.5
        default: 1
        }
        return min(6, max(-8, 5 * log2(mbps / (reference * efficiency))))
    }

    /// The rate, in Mbps, that an H.264 release of this height is usually encoded at for good quality.
    private static func referenceMbps(_ height: Int) -> Double? {
        if height >= 2160 { return 35 }
        if height >= 1440 { return 20 }
        if height >= 1080 { return 14 }
        if height >= 720 { return 6 }
        if height >= 480 { return 2 }
        return nil
    }

    /// The bitrate in Mbps: the one the addon states, else size over runtime. When both are known and differ by more than twice, the release
    /// contradicts itself, so neither is trusted.
    private static func bitrateMbps(_ quality: StreamQuality, duration: TimeInterval?) -> Double? {
        let sized = sizeOverRuntimeMbps(quality, duration: duration)
        guard let declared = quality.declaredBitrateMbps else { return sized }
        guard let measured = sized else { return declared }
        return max(declared, measured) <= 2 * min(declared, measured) ? declared : nil
    }

    private static func sizeOverRuntimeMbps(_ quality: StreamQuality, duration: TimeInterval?) -> Double? {
        guard let bytes = quality.sizeBytes, bytes > 0, let duration, duration > 0 else { return nil }
        return Double(bytes) * 8 / duration / 1_000_000
    }

    // MARK: - Audio

    /// The best track the text names counts, since the player picks a track it can play. Channels add a little, and Atmos counts only with
    /// a codec that carries it: an Atmos label beside AAC contradicts itself.
    private static func audioPoints(_ quality: StreamQuality) -> Double {
        var points = quality.audioCodecs.map { audioCodecPoints($0) }.max() ?? 0
        if let channels = quality.audioChannels { points += channels >= 8 ? 6 : channels >= 6 ? 4 : 0 }
        if quality.atmosFormat == .lossless { points += 9 }
        if quality.atmosFormat == .streaming { points += 6 }
        if quality.hasDTSX { points += 7 }
        if let kbps = quality.audioBitrateKbps { points += min(3, max(0, log2(kbps / 192))) }
        return points
    }

    /// Lossless tracks keep the studio's mix bit for bit, so they sit well above every lossy codec. Plain DTS-HD is read as its lossless
    /// Master Audio form, which is what release names mean by it.
    private static func audioCodecPoints(_ codec: AudioCodec) -> Double {
        switch codec {
        case .trueHD, .dtsHD, .flac: return 20
        case .eac3: return 11
        case .dts, .ac3: return 6
        case .aac, .opus: return 5
        case .mp3: return 2
        }
    }
}
