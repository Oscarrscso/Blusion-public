#if canImport(UIKit)
import StremioKit
import SwiftUI

/// A stream's quality marker: a small SF Symbol and a short label in a hairline capsule. Sharpness and format are told apart by their
/// symbol first; colour is restrained. 4K alone carries the premium champagne accent, HDR a cool lilac, and everything else stays
/// white, so the sharpest stream stands out without the list turning loud.
struct QualityBadge: View {
    let title: String
    let symbol: String
    let tint: Color
    /// What VoiceOver reads when the text on the badge is an abbreviation, such as "DV" for Dolby Vision. Nil reads the text itself.
    let spokenAs: String?

    init(_ title: String, symbol: String, tint: Color = .white, spokenAs: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.spokenAs = spokenAs
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
        }
        .qualityBadgeChrome(tint: tint)
        // The capsule is as wide as its text, so a short label is never cut short.
        .fixedSize()
        .accessibilityLabel(Text(verbatim: spokenAs ?? title))
    }
}

extension View {
    /// The hairline capsule that a quality marker and the Dolby Atmos badge share: the tint lightly filled, with a fine edge of the same colour.
    func qualityBadgeChrome(tint: Color) -> some View {
        self
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint.opacity(0.92))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.10), in: Capsule())
            .overlay { Capsule().strokeBorder(tint.opacity(0.32), lineWidth: 0.6) }
            .accessibilityElement(children: .combine)
    }
}

/// Dolby Atmos on a stream, as the AirPods symbol alone: the tags' chrome, so it is the height of the text tags beside it. VoiceOver
/// still says "Dolby Atmos", since the symbol has no text of its own.
struct SpatialAudioBadge: View {
    var body: some View {
        Image(systemName: "airpodspro")
            .qualityBadgeChrome(tint: .white)
            .accessibilityLabel(Text(verbatim: "Dolby Atmos"))
    }
}

/// The TorBox mark as its symbol alone, for a row with no room for its letters. VoiceOver still says what it means.
struct TorBoxMark: View {
    let cache: TorBoxCache

    var body: some View {
        Image(systemName: cache == .cached ? "bolt.fill" : "hourglass")
            .qualityBadgeChrome(tint: cache == .cached ? QualityBadge.cachedGreen : .white)
            .accessibilityLabel(Text(verbatim: cache == .cached ? "Cached on TorBox" : "Not cached on TorBox"))
    }
}

extension QualityBadge {
    /// The champagne of a 4K picture: the one premium accent on the list.
    static let premium = Color(red: 0.93, green: 0.82, blue: 0.62)
    /// A cool lilac for high dynamic range, quieter than the accent.
    static let dynamicRange = Color(red: 0.80, green: 0.76, blue: 0.98)
    /// A soft green for a file TorBox already holds.
    static let cachedGreen = Color(red: 0.62, green: 0.88, blue: 0.68)

    /// Whether TorBox holds the stream's file: its name beside a bolt when it does, beside an hourglass when TorBox would fetch it
    /// first. "TB", as the addons write it, where the row is narrow (iPhone in portrait).
    static func torBox(_ cache: TorBoxCache, compact: Bool) -> QualityBadge {
        let title = compact ? "TB" : "TorBox"
        switch cache {
        case .cached: return QualityBadge(title, symbol: "bolt.fill", tint: cachedGreen, spokenAs: "Cached on TorBox")
        case .notCached: return QualityBadge(title, symbol: "hourglass", spokenAs: "Not cached on TorBox")
        }
    }

    /// Honest cache readiness for any stream candidate, including `.unknown` when the addon carries no cache marker.
    static func cache(_ status: StreamCacheStatus) -> QualityBadge {
        switch status {
        case .cached: return QualityBadge("Cached", symbol: "bolt.fill", tint: cachedGreen)
        case .uncached: return QualityBadge("Uncached", symbol: "hourglass")
        case .unknown: return QualityBadge("Cache unknown", symbol: "questionmark.circle", tint: .white.opacity(0.75))
        }
    }

    /// A soft sky blue for a Usenet stream, so it tells apart from a debrid one at a glance.
    static let usenetBlue = Color(red: 0.62, green: 0.80, blue: 0.99)

    /// How the stream arrives: "Usenet" beside a newspaper, "Debrid" beside a cloud, as AIOStreams marks them. The symbol alone where
    /// the row has no room for the word.
    @ViewBuilder
    static func delivery(_ delivery: StreamDelivery, titled: Bool) -> some View {
        let symbol = delivery == .usenet ? "newspaper.fill" : "cloud.fill"
        let tint: Color = delivery == .usenet ? usenetBlue : .white
        if titled {
            QualityBadge(delivery.title, symbol: symbol, tint: tint)
        } else {
            Image(systemName: symbol)
                .qualityBadgeChrome(tint: tint)
                .accessibilityLabel(Text(verbatim: delivery.title))
        }
    }

    static func resolution(_ label: String, is4K: Bool) -> QualityBadge {
        QualityBadge(label, symbol: is4K ? "4k.tv" : "tv", tint: is4K ? premium : .white)
    }

    /// The source marker. A Blu-ray reads "BD", or "BD4K" for a 4K source.
    static func source(_ kind: StreamSourceKind, is4K: Bool = false) -> QualityBadge {
        switch kind {
        case .bluray: QualityBadge(is4K ? "BD4K" : "BD", symbol: "opticaldisc", spokenAs: is4K ? "4K Blu-ray" : "Blu-ray")
        case .webDL: QualityBadge("WEB-DL", symbol: "globe")
        case .webRip: QualityBadge("WEBRip", symbol: "globe")
        case .hdtv: QualityBadge("HDTV", symbol: "tv")
        case .dvd: QualityBadge("DVD", symbol: "opticaldisc")
        case .cam: QualityBadge("CAM", symbol: "video.slash")
        }
    }

    /// The remux marker: "REMUX" beside its symbol, or "RMX" where the row is narrow (iPhone in portrait).
    static func remux(compact: Bool) -> QualityBadge {
        QualityBadge(compact ? "RMX" : "REMUX", symbol: "aqi.medium", spokenAs: "REMUX")
    }

    /// The high dynamic range marker: "Dolby Vision" or "HDR", or "DV" for Dolby Vision where the row is narrow (iPhone in portrait).
    static func hdr(dolbyVision: Bool, compact: Bool) -> QualityBadge {
        let title = dolbyVision ? (compact ? "DV" : "Dolby Vision") : "HDR"
        return QualityBadge(title, symbol: "sun.max", tint: dynamicRange, spokenAs: dolbyVision ? "Dolby Vision" : nil)
    }
}
#endif
