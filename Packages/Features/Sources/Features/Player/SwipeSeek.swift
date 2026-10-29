import Foundation

/// Seeking with a sideways drag on iPhone and iPad: right goes forward, left goes back. The current finger height
/// sets the sensitivity, from two minutes across the width at the top to ten seconds at the bottom.
enum SwipeSeek {
    /// Seconds a swipe across the whole width moves at the top.
    static let secondsAcrossWidth: TimeInterval = 120

    /// Apply each new horizontal movement to the previous fraction. Changing height alone never moves the target.
    /// `heightFraction` runs from zero at the top to one at the bottom.
    static func fraction(from start: Double, translation: Double, width: Double, duration: TimeInterval,
                         heightFraction: Double = 0) -> Double {
        guard width > 0, duration > 0 else { return start }
        let sensitivity = secondsAcrossWidth - (secondsAcrossWidth - 10) * min(1, max(0, heightFraction))
        let seconds = translation / width * min(sensitivity, duration)
        return min(1, max(0, start + seconds / duration))
    }
}
