import CoreGraphics
import Foundation

/// The press-and-hold speed-up: where a hold begins, how far a drag steps it up, how far it may go, how long a press must rest, within
/// how far it may drift, before it is a hold, and how far a drag down locks it. The arithmetic is pure, so the steps are tested on the
/// host; `PictureHoldGesture` times the press and `PlayerScreen` feeds it the finger.
enum SpeedHoldRules {
    /// The speed a hold begins at, whatever the film was playing at.
    static let startRate: Float = 2
    /// The highest a hold goes, where the engine allows it (`PlaybackEngine.maximumRate` lowers it further).
    static let ceilingRate: Float = 4
    /// Points of movement per step: each full 40 points up adds 1×. Moving back down never steps the speed down; see `lockDistance`.
    static let pointsPerStep: Double = 40
    /// How long a press must rest before it is a hold.
    static let holdDelay: TimeInterval = 0.1
    /// How far a resting press may drift and still be a hold; a press that moves further first fails as a hold.
    static let holdTolerance: CGFloat = 10
    /// How far a finger must drag down, from the step its speed was reached at, to lock the hold at that speed; from a locked hold's press,
    /// the same drag down releases the lock.
    static let lockDistance: Double = 40

    /// The speed for a finger `displacement` points from where the hold began (negative when it has moved up), within the engine's
    /// `maximum`. While held the speed only climbs: a finger moving back down keeps the `current` speed.
    static func rate(displacement: Double, maximum: Float, current: Float? = nil) -> Float {
        let cap = min(ceilingRate, maximum)
        let base = min(startRate, cap)
        guard displacement.isFinite else { return current ?? base }
        let steps = (-displacement / pointsPerStep).rounded(.down)
        let target = Float(min(Double(cap), max(Double(base), Double(startRate) + steps)))
        guard let current, current <= cap else { return target }
        return max(current, target)
    }

    /// Whether a finger `displacement` points from where the hold began has dragged down far enough to lock the hold at `rate`: `lockDistance`
    /// below the point that speed was reached at. Each step above `startRate` was reached `pointsPerStep` higher up.
    static func locks(displacement: Double, at rate: Float) -> Bool {
        guard displacement.isFinite else { return false }
        let reachedAt = -Double(rate - startRate) * pointsPerStep
        return displacement > reachedAt + lockDistance
    }

    /// Whether a finger `displacement` points from where a locked hold was pressed has dragged down far enough to release the lock.
    static func unlocks(displacement: Double) -> Bool {
        displacement.isFinite && displacement > lockDistance
    }

    /// How far a finger `displacement` points from where a locked hold was pressed has got toward releasing the lock, from 0 to 1. Reaches 1
    /// where `unlocks` turns true.
    static func unlockProgress(displacement: Double) -> Double {
        guard displacement.isFinite else { return 0 }
        return min(1, max(0, displacement / lockDistance))
    }

    /// How far a finger `displacement` points from where a hold began has got toward locking at `rate`, from 0 to 1. Measured from the point
    /// that speed was reached at, as `locks` measures it, so it reaches 1 where `locks` turns true.
    static func lockProgress(displacement: Double, at rate: Float) -> Double {
        guard displacement.isFinite else { return 0 }
        let reachedAt = -Double(rate - startRate) * pointsPerStep
        return min(1, max(0, (displacement - reachedAt) / lockDistance))
    }
}
