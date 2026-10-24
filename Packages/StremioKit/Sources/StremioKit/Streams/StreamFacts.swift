import Foundation

/// Every fact a viewer can read about one stream, in the order the stream's technical details list them. Built here from the typed quality
/// and the addon's stream, so the view only renders it. Empty facts are left out.
///
/// Request headers are never shown, only that there are some: their values can hold tokens.
public struct StreamFacts: Sendable, Equatable {
    public struct Fact: Sendable, Equatable {
        public let label: String
        public let value: String
        /// A hash or other identifier, which reads best in a monospaced face.
        public let isIdentifier: Bool
    }

    public let rows: [Fact]

    public init(_ item: RankedStream) {
        let stream = item.stream
        let quality = item.quality
        var rows: [Fact] = []
        func add(_ label: String, _ value: String?, isIdentifier: Bool = false) {
            guard let value, !value.isEmpty else { return }
            rows.append(Fact(label: label, value: value, isIdentifier: isIdentifier))
        }

        add("Seeders", quality.seeders.map { String($0) })
        add("Peers", quality.peers.map { String($0) })
        add("Size", quality.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
        add("Resolution", quality.resolutionLabel)
        add("Source", quality.source?.label)
        add("HDR / Dolby Vision", Self.hdrLabel(quality))
        add("Video codec", quality.videoCodec?.label)
        let audio = quality.audioCodecs.map(\.label) + (quality.hasAtmos ? ["Atmos"] : [])
        add("Audio", audio.isEmpty ? nil : audio.joined(separator: ", "))
        add("Filename", stream.behaviorHints.filename?.trimmingCharacters(in: .whitespacesAndNewlines))
        add("Container", item.container.map { $0.fileExtension.uppercased() })
        add("Addon", item.addon.name)
        add("Also from", item.alsoProvidedBy.isEmpty ? nil : item.alsoProvidedBy.map(\.name).joined(separator: ", "))
        add("TorBox", TorBoxCache.detect(in: stream).map { $0 == .cached ? "Cached, plays at once" : "Not cached, fetched first" })
        if case .torrent(let hash, let fileIndex, let sources) = stream.source {
            add("Info hash", hash, isIdentifier: true)
            add("File index", fileIndex.map { String($0) })
            // Trackers are the `tracker:` entries; `dht:` entries are peers to find, not trackers.
            let trackers = sources.filter { $0.hasPrefix("tracker:") }.count
            add("Trackers", trackers == 0 ? nil : String(trackers))
        }
        add("Binge group", stream.behaviorHints.bingeGroup)
        add("Video hash", stream.behaviorHints.videoHash, isIdentifier: true)
        add("Video size", stream.behaviorHints.videoSize.map { "\($0.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))) bytes" })
        add("Subtitles", stream.subtitles.isEmpty ? nil : String(stream.subtitles.count))
        add("Regions", stream.behaviorHints.countryWhitelist.isEmpty ? nil : stream.behaviorHints.countryWhitelist.joined(separator: ", "))
        if stream.behaviorHints.proxyHeaders.map({ !$0.isEmpty }) == true { add("Custom request headers", "Yes") }
        if stream.behaviorHints.notWebReady { add("Needs conversion", "Yes") }
        self.rows = rows
    }

    /// "Dolby Vision profile 7 (FEL), HDR10+" — what the release name says; the player's statistics show what the stream really is.
    static func hdrLabel(_ quality: StreamQuality) -> String? {
        var parts: [String] = []
        if quality.isDolbyVision {
            var text = "Dolby Vision"
            if let profile = quality.dolbyVisionProfile { text += " profile \(profile)" }
            if quality.hasFullEnhancementLayer { text += " (FEL)" }
            parts.append(text)
        }
        if quality.isHDR10Plus { parts.append("HDR10+") } else if quality.isHLG { parts.append("HLG") } else if quality.isHDR, !quality.isDolbyVision { parts.append("HDR") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
