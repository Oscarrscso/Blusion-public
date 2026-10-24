import Foundation
import PlayerKit

/// Display text is separate from decoder identity: equally named tracks can be
/// different translations, codecs or edits and must remain independently selectable.
public struct PlayerTrackRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let tags: [String]
}

public enum PlayerTrackPresentation {
    public static func embedded(_ tracks: [MediaTrack], audio: Bool = false) -> [PlayerTrackRow] {
        var seen: Set<String> = []
        return tracks.filter { seen.insert($0.id).inserted }.map { track in
            var details: [String] = []
            if let language = track.language, !language.isEmpty {
                let name = LanguageCodes.displayName(language)
                if !track.title.localizedCaseInsensitiveContains(name) { details.append(name) }
            }
            details.append(track.isExternal ? "Added file" : "In video")
            if let codec = track.codec, !codec.isEmpty, !track.title.localizedCaseInsensitiveContains(codec) {
                details.append(codec.uppercased())
            }
            if let channels = track.channelCount, channels > 0 {
                let layout = channels == 6 ? "5.1" : channels == 8 ? "7.1" : "\(channels) ch"
                if !track.title.localizedCaseInsensitiveContains(layout) { details.append(layout) }
            }
            // Always expose the stable decoder ID: this also distinguishes tracks
            // whose files provide no useful metadata beyond “English · Main”.
            details.append("Track \(track.id)")
            var tags: [String] = []
            if track.isForced, !track.title.localizedCaseInsensitiveContains("forced") { tags.append("Forced") }
            let accessible = audio ? "Audio description" : "SDH"
            if track.isHearingImpaired, !track.title.localizedCaseInsensitiveContains(accessible) { tags.append(accessible) }
            if track.isDefault { tags.append("Default") }
            return PlayerTrackRow(id: track.id, title: track.title.isEmpty ? "Track \(track.id)" : track.title,
                                  subtitle: details.joined(separator: " · "), tags: tags)
        }
    }

    public static func external(_ options: [SubtitleOption]) -> [PlayerTrackRow] {
        options.enumerated().map { index, option in
            var details = [LanguageCodes.displayName(option.language)]
            switch option.source {
            case .stream: details.append("From stream")
            case .addon(let name): details.append(name)
            case .local: details.append("Added file")
            case .openSubtitles: details.append("OpenSubtitles")
            }
            if option.format != .unknown { details.append(option.format.rawValue.uppercased()) }
            // URLs and provider IDs can carry credentials. Use only a safe list
            // number to distinguish otherwise identical provider descriptions.
            details.append("Track \(index + 1)")
            var tags: [String] = []
            if option.isForced { tags.append("Forced") }
            if option.isHearingImpaired { tags.append("SDH") }
            if option.format == .ass { tags.append("Styled") }
            if option.format == .pgs || option.format == .vobsub { tags.append("Image") }
            return PlayerTrackRow(id: option.id, title: option.title, subtitle: details.joined(separator: " · "), tags: tags)
        }
    }
}
