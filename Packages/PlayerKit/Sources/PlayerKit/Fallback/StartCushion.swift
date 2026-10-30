import Foundation

/// How long the first start of a stream waits for some of the film in hand, for a backend that asks (`FallbackBackend.startCushion`).
///
/// AetherEngine plays a remux by repackaging it into 4 s segments as it downloads. Started on its first segment, a high-bitrate remux
/// (a UHD Blu-ray at 50 to 100 Mbit/s) outruns a download only a little faster than the film, and the picture stops and starts until the
/// download pulls ahead. Hold the start for a downloaded cushion on both remux and FEL playback.
public struct StartCushion: Sendable, Equatable {
    /// Seconds buffered ahead of the playhead that let the stream start.
    public var seconds: TimeInterval
    /// Seconds in hand that let it start sooner, while the film arrives at least `fastFill` times faster than it plays.
    public var earlySeconds: TimeInterval
    /// Seconds of film arriving per second of waiting that make a download well ahead of the film.
    public var fastFill: Double
    /// The longest the start waits for them once the stream has loaded.
    public var maximumWait: TimeInterval
    /// Load and wait together stay inside this, below the player's start-up timeout (60 s).
    public var startBudget: TimeInterval

    public init(seconds: TimeInterval, earlySeconds: TimeInterval, fastFill: Double, maximumWait: TimeInterval, startBudget: TimeInterval) {
        self.seconds = seconds
        self.earlySeconds = earlySeconds
        self.fastFill = fastFill
        self.maximumWait = maximumWait
        self.startBudget = startBudget
    }

    /// Five seconds of media, or two when measured fill is at least 2.5× playback. Never spend more than eight seconds filling;
    /// load and fill together still stay below the player's startup timeout.
    public static let standard = StartCushion(seconds: 5, earlySeconds: 2, fastFill: 2.5, maximumWait: 8, startBudget: 50)

    /// How long the start may wait now, `loadTook` after the load began, with `ahead` seconds in hand. 0 starts at once, as does a
    /// backend that cannot say how much it holds (nil).
    public func wait(ahead: TimeInterval?, loadTook: TimeInterval) -> TimeInterval {
        guard let ahead, ahead < seconds else { return 0 }
        return max(0, min(maximumWait, startBudget - loadTook))
    }

    /// Enough is in hand to start: `seconds`, or `earlySeconds` while the film has arrived `fastFill` times faster than it plays since
    /// the wait began, `waited` seconds ago with `startAhead` in hand. A backend that can no longer say never holds a start.
    public func isMet(ahead: TimeInterval?, startAhead: TimeInterval, waited: TimeInterval) -> Bool {
        guard let ahead else { return true }
        if ahead >= seconds { return true }
        guard ahead >= earlySeconds, waited > 0 else { return false }
        return (ahead - startAhead) / waited >= fastFill
    }
}
