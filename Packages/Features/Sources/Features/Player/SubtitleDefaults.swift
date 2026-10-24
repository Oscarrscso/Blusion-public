import Foundation
import PlayerKit
import StremioKit

/// The subtitles that come on by themselves, from the Settings preferences. Embedded tracks win over files (they are timed to the media),
/// files bundled with the stream over addon ones.
enum SubtitleDefaults {
    static func choice(embedded: [MediaTrack], external: [SubtitleOption], language: String?, audioLanguage: String?,
                       mode: SubtitleMode, prefersSDH: Bool) -> PlayerViewModel.SubtitleChoice? {
        switch mode {
        case .off:
            return nil
        case .forcedOnly:
            // Forced lines translate the dialogue the audio does not carry, so they follow the listener's language, else the audio's.
            guard let wanted = language ?? audioLanguage else { return nil }
            return forced(embedded: embedded, external: external, language: wanted)
        case .always:
            guard let language, !language.isEmpty else { return nil }
            let full = embedded.filter { !$0.isForced && matches($0.language, language) }
            if let track = full.first(where: { $0.isHearingImpaired == prefersSDH }) ?? full.first { return .embedded(track.id) }
            if let option = SubtitleService.defaultOption(in: external, preferredLanguage: language, prefersSDH: prefersSDH) {
                return .external(option.id)
            }
            return forced(embedded: embedded, external: external, language: language)
        }
    }

    private static func forced(embedded: [MediaTrack], external: [SubtitleOption], language: String) -> PlayerViewModel.SubtitleChoice? {
        if let track = embedded.first(where: { $0.isForced && matches($0.language, language) }) { return .embedded(track.id) }
        if let option = external.first(where: { $0.isForced && LanguageCodes.matches($0.language, preferred: language) }) { return .external(option.id) }
        return nil
    }

    private static func matches(_ language: String?, _ preferred: String) -> Bool {
        language.map { LanguageCodes.matches($0, preferred: preferred) } ?? false
    }

    /// The audio track in the preferred language, when the one playing is in another.
    static func audioTrack(in tracks: [MediaTrack], selected: String?, language: String?) -> MediaTrack? {
        guard let language, !language.isEmpty,
              tracks.first(where: { $0.id == selected }).flatMap({ $0.language }).map({ !LanguageCodes.matches($0, preferred: language) }) ?? true
        else { return nil }
        let candidates = tracks.filter { matches($0.language, language) && !$0.isHearingImpaired }
        return candidates.max { ($0.channelCount ?? 0) < ($1.channelCount ?? 0) }
    }
}
