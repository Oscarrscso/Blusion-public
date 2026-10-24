import Foundation
import Observation

/// How long each trailer runs, learned the first time it plays. Neither TMDb nor the addons give a trailer's length, so a card shows the
/// duration only once its trailer has played. The lengths are kept in UserDefaults, so they survive a relaunch.
@MainActor
@Observable
final class TrailerDurations {
    static let shared = TrailerDurations()

    /// Lengths from one second to ten hours. Anything else (NaN, zero, negative, or a runaway value) is not a trailer's length.
    private static let plausible: ClosedRange<TimeInterval> = 1...36_000
    private static let defaultsKey = "trailers.durations"

    /// Length in seconds by trailer id (`Trailer.id`).
    private(set) var seconds: [String: TimeInterval]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seconds = (defaults.dictionary(forKey: Self.defaultsKey) as? [String: TimeInterval]) ?? [:]
    }

    /// Keeps the length of the trailer `id`, once it has played. A value outside `plausible` is ignored.
    func record(_ seconds: TimeInterval, for id: String) {
        guard seconds.isFinite, Self.plausible.contains(seconds), self.seconds[id] != seconds else { return }
        self.seconds[id] = seconds
        defaults.set(self.seconds, forKey: Self.defaultsKey)
    }
}
