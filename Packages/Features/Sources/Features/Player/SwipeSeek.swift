import Foundation

/// Seeking with a sideways swipe anywhere on the player (iPhone and iPad): right goes forward, left goes back. A swipe across the
/// picture's whole width moves two minutes, or the whole of a shorter video, so a short swipe seeks a few seconds; the timeline is there
/// for long jumps.
enum SwipeSeek {
    /// Seconds a swipe across the whole width moves.
    static let secondsAcrossWidth: TimeInterval = 120

    /// The timeline fraction a swipe of `translation` points across a picture `width` points wide leads to, from `start`.
    static func fraction(from start: Double, translation: Double, width: Double, duration: TimeInterval) -> Double {
        guard width > 0, duration > 0 else { return start }
        let seconds = translation / width * min(secondsAcrossWidth, duration)
        return min(1, max(0, start + seconds / duration))
    }
}
