import Foundation
import Testing
@testable import Features

@MainActor
@Suite struct TrailerDurationsTests {
    /// Defaults of their own, so a test never reads or writes the app's saved lengths.
    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "TrailerDurationsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func aPlausibleLengthIsKeptByTrailerID() throws {
        let durations = TrailerDurations(defaults: try isolatedDefaults())
        durations.record(123.5, for: "yt:abc123")
        #expect(durations.seconds == ["yt:abc123": 123.5])
        durations.record(124, for: "yt:abc123")
        #expect(durations.seconds["yt:abc123"] == 124, "a later play replaces the length")
    }

    @Test func impossibleLengthsAreRejected() throws {
        let durations = TrailerDurations(defaults: try isolatedDefaults())
        for value in [Double.nan, .infinity, -.infinity, 0, 0.5, -10, 36_000.5, 1_000_000] {
            durations.record(value, for: "yt:abc123")
        }
        #expect(durations.seconds.isEmpty)
        durations.record(1, for: "yt:short")
        durations.record(36_000, for: "yt:long")
        #expect(durations.seconds == ["yt:short": 1, "yt:long": 36_000], "the bounds themselves are kept")
    }

    @Test func lengthsSurviveAFreshInstanceOnTheSameDefaults() throws {
        let defaults = try isolatedDefaults()
        TrailerDurations(defaults: defaults).record(90, for: "url:https://cdn.example.com/t.mp4")
        let reloaded = TrailerDurations(defaults: defaults)
        #expect(reloaded.seconds == ["url:https://cdn.example.com/t.mp4": 90])
    }
}
