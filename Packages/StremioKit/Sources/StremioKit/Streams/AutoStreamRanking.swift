import Foundation

/// Auto Pick and Best match share this ranking. Confirmed Blu-ray REMUX releases have unconditional release priority;
/// resolution, video, audio and bitrate scores compare releases within the same priority tier.
/// Contradicted facts earn nothing. Seeder tie-breakers stay within the winning tier.
public enum AutoStreamRanking {
    public struct Assessment: Sendable {
        public let item: RankedStream
        public let qualityScore: Double
        public let bitrateMbps: Double?
        public let seeders: Int?
        public let isRemux: Bool
    }

    public static func assess(_ item: RankedStream, duration: TimeInterval?) -> Assessment {
        let quality = item.quality
        // A contradicted resolution, source or codec is left out. The bitrate reference depends on the resolution and codec, so it goes too.
        let resolution = quality.hasConflictingResolution ? nil : quality.resolution
        let source = quality.hasConflictingSource ? nil : quality.source
        let codec = quality.hasConflictingVideoCodec ? nil : quality.videoCodec
        let bitrate = bitrateMbps(quality, duration: duration)
        var score = resolutionPoints(resolution) + sourcePoints(source) + videoCodecPoints(codec)
        score += bitDepthPoints(quality.bitDepth) + hdrPoints(quality)
        score += bitratePoints(bitrate, resolution: resolution, codec: codec)
        score += audioPoints(quality)
        // A REMUX name counts only when no other source is named beside it.
        if quality.isRemux && !quality.hasConflictingSource { score += remuxPoints }
        return Assessment(item: item, qualityScore: score, bitrateMbps: bitrate, seeders: quality.seeders, isRemux: quality.isRemux)
    }

    public static func best(from items: [RankedStream], duration: TimeInterval?) -> Assessment? {
        let items = StreamAvailability.automaticCandidates(from: items)
        // Restrict every later tie-breaker, including swarm health, to the highest release tier.
        guard let priority = items.map({ $0.quality.releasePriority }).max() else { return nil }
        let ranked = items.filter { $0.quality.releasePriority == priority }.map { assess($0, duration: duration) }.sorted {
            if $0.qualityScore != $1.qualityScore { return $0.qualityScore > $1.qualityScore }
            return StreamRanking.isOrdered($0.item, before: $1.item)
        }
        guard let best = ranked.first else { return nil }
        // Known-dead torrents lose to available alternatives; unknown counts remain eligible.
        let available = ranked.filter { $0.seeders != 0 }
        let leader = best.seeders == 0 ? (available.first ?? best) : best
        let close = ranked.filter { $0.qualityScore >= leader.qualityScore - 6 && ($0.seeders ?? -1) >= 5 }
        if let seeds = leader.seeders, seeds < 5, let healthy = close.first { return healthy }
        // Within a very small quality difference, use a known healthy swarm as the tie-breaker.
        return close.filter { $0.qualityScore >= leader.qualityScore - 2 }.max {
            ($0.seeders ?? 0) < ($1.seeders ?? 0)
        } ?? leader
    }

    /// A score contribution within the release tier; the shared tier enforces REMUX priority.
    private static let remuxPoints: Double = 4

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
        if let channels = quality.audioChannels { points += channels >= 8 ? 3 : channels >= 6 ? 2 : 0 }
        if quality.atmosFormat != nil { points += 2 }
        return points
    }

    /// Lossless tracks keep the studio's mix bit for bit, so they sit well above every lossy codec. Plain DTS-HD is read as its lossless
    /// Master Audio form, which is what release names mean by it.
    private static func audioCodecPoints(_ codec: AudioCodec) -> Double {
        switch codec {
        case .trueHD, .dtsHD, .flac: return 14
        case .eac3: return 8
        case .dts, .ac3: return 6
        case .aac, .opus: return 5
        case .mp3: return 2
        }
    }
}
