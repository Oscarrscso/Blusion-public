import Foundation

/// When an episode's end comes up: in its last minute, or once end credits that run to the end begin, the next episode starts
/// loading off screen, and once it is ready Next Episode counts down eight seconds of playback, then plays it.
enum UpNextTiming {
    /// The next episode starts loading this long before the end.
    static let lead: TimeInterval = 60
    /// Playback the Next Episode button counts down before it plays the next episode by itself.
    static let countdown: Duration = .seconds(8)
    /// A video shorter than this gets no Up Next: most of it would be its last minute.
    static let minimumLength: TimeInterval = 180

    /// - Parameters:
    ///   - position: the playhead, not a scrub's preview.
    ///   - creditsToEnd: marked end credits that run to the end are playing.
    static func isNearEnd(position: TimeInterval, duration: TimeInterval?, creditsToEnd: Bool) -> Bool {
        guard let duration, duration.isFinite, duration >= minimumLength, position.isFinite else { return false }
        return creditsToEnd || duration - position <= lead
    }
}
