import CoreGraphics
import Foundation

/// The press-and-hold speed-up: where a hold begins, how far a drag steps it, how far it may go, and how long a press must rest, within
/// how far it may drift, before it is a hold. The arithmetic is pure, so the steps are tested on the host; `PictureHoldGesture` times the
/// press and `PlayerScreen` feeds it the finger.
enum SpeedHoldRules {
    /// The speed a hold begins at, whatever the film was playing at.
    static let startRate: Float = 2
    /// The highest a hold goes, where the engine allows it (`PlaybackEngine.maximumRate` lowers it further).
    static let ceilingRate: Float = 4
    /// Points of movement per step: each full 40 points up adds 1×, and moving back down steps back, never below `startRate`.
    static let pointsPerStep: Double = 40
    /// How long a press must rest before it is a hold.
    static let holdDelay: TimeInterval = 0.4
    /// How far a resting press may drift and still be a hold; a press that moves further first fails as a hold.
    static let holdTolerance: CGFloat = 10

    /// The speed for a finger `displacement` points from where the hold began (negative when it has moved up), within the engine's
    /// `maximum`. Returning down past a step has a six-point dead band, so a resting finger cannot chatter across its threshold.
    static func rate(displacement: Double, maximum: Float, current: Float? = nil) -> Float {
        let cap = min(ceilingRate, maximum)
        let base = min(startRate, cap)
        guard displacement.isFinite else { return base }
        let steps = (-displacement / pointsPerStep).rounded(.down)
        let target = Float(min(Double(cap), max(Double(base), Double(startRate) + steps)))
        if let current, current <= cap, target < current,
           -displacement > Double(current - startRate) * pointsPerStep - 6 { return current }
        return target
    }
}
