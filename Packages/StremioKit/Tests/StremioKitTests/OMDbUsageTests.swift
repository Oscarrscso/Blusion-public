import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

@Suite struct OMDbUsageTests {
    private final class MovableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        var now: Date {
            get { lock.withLock { date } }
            set { lock.withLock { date = newValue } }
        }
    }

    private let movie = Data(#"{"Response":"True","imdbRating":"8.0"}"#.utf8)
    private let season = Data(#"{"Response":"True","Episodes":[{"Episode":"1","imdbRating":"9.1"}]}"#.utf8)
    /// 2026-10-11 12:00 UTC.
    private let noon = Date(timeIntervalSince1970: 1_791_720_000)

    private func withDefaults(_ body: (UserDefaults, String) async throws -> Void) async throws {
        let name = "OMDbUsageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults, name)
    }

    @Test func everyRequestIsCountedForBothCalls() async throws {
        try await withDefaults { defaults, _ in
            let usage = OMDbUsage(defaults: defaults, now: { noon })
            let transport = StubTransport { request, _ in
                let isSeason = request.url?.absoluteString.contains("Season=") == true
                return StubTransport.response(isSeason ? season : movie, for: request)
            }
            let omdb = OMDbRatings(client: makeClient(transport, retries: 0), apiKey: "k", usage: usage)
            #expect(usage.today() == 0)
            _ = try await omdb.ratings(imdbID: "tt0944947")
            #expect(usage.today() == 1)
            _ = try await omdb.episodeRatings(imdbID: "tt0944947", season: 1)
            #expect(usage.today() == 2)
        }
    }

    @Test func failedAnswersCountToo() async throws {
        try await withDefaults { defaults, _ in
            let usage = OMDbUsage(defaults: defaults, now: { noon })
            let limited = Data(#"{"Response":"False","Error":"Request limit reached!"}"#.utf8)
            let omdb = OMDbRatings(client: makeClient(StubTransport(data: limited), retries: 0), apiKey: "k", usage: usage)
            await #expect(throws: AddonError.http(status: 429)) { try await omdb.ratings(imdbID: "tt0944947") }
            #expect(usage.today() == 1)
        }
    }

    @Test func earlyReturnsDoNotCount() async throws {
        try await withDefaults { defaults, _ in
            let usage = OMDbUsage(defaults: defaults, now: { noon })
            let transport = StubTransport(data: movie)
            let client = makeClient(transport, retries: 0)
            let noKey = OMDbRatings(client: client, apiKey: "  ", usage: usage)
            let keyed = OMDbRatings(client: client, apiKey: "k", usage: usage)
            _ = try await noKey.ratings(imdbID: "tt0944947")
            _ = try await noKey.episodeRatings(imdbID: "tt0944947", season: 1)
            _ = try await keyed.ratings(imdbID: "kitsu:1")
            _ = try await keyed.episodeRatings(imdbID: "kitsu:1", season: 1)
            #expect(usage.today() == 0 && transport.callCount == 0)
        }
    }

    @Test func theCountSurvivesANewInstanceOnTheSameDefaults() async throws {
        try await withDefaults { defaults, _ in
            let first = OMDbUsage(defaults: defaults, now: { noon })
            first.record()
            first.record()
            #expect(OMDbUsage(defaults: defaults, now: { noon }).today() == 2)
        }
    }

    @Test func theCountRestartsOnTheNextUTCDay() async throws {
        try await withDefaults { defaults, _ in
            let clock = MovableClock(noon)
            let usage = OMDbUsage(defaults: defaults, now: { clock.now })
            usage.record()
            usage.record()
            clock.now = noon.addingTimeInterval(12 * 3600)  // 2026-10-12 00:00 UTC
            #expect(usage.today() == 0)
            usage.record()
            #expect(usage.today() == 1)
        }
    }

    @Test func aLocalMidnightThatIsNotUTCMidnightDoesNotReset() async throws {
        try await withDefaults { defaults, _ in
            // 23:30 UTC on the 11th is already the 12th in Sydney and still the 11th in Los Angeles.
            let late = Date(timeIntervalSince1970: 1_791_720_000 + 11.5 * 3600)
            let clock = MovableClock(late)
            let usage = OMDbUsage(defaults: defaults, now: { clock.now })
            usage.record()
            clock.now = late.addingTimeInterval(20 * 60)  // 23:50 UTC
            #expect(usage.today() == 1)
            #expect(OMDbUsage.utcDay(late) == "2026-10-11")
            clock.now = late.addingTimeInterval(31 * 60)  // 00:01 UTC on the 12th
            #expect(usage.today() == 0)
        }
    }

    /// What a reader sees from inside a write. Written on the recording thread, read after the semaphore it signals.
    private final class Reading: @unchecked Sendable {
        var count: Int?
    }

    /// `record()` writes the count while it holds its lock, and the write posts `UserDefaults.didChangeNotification` on that thread. A
    /// reader called from there (SwiftUI's observer of the notification waits for the main thread, whose view update may be reading the
    /// count) must not wait for that lock. It did, and on 14 Oct the app froze until the system ended it.
    @Test func theCountCanBeReadWhileARequestIsBeingCounted() throws {
        let name = "OMDbUsageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let noon = self.noon
        let usage = OMDbUsage(defaults: defaults, now: { noon })
        let reading = Reading()
        let observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults,
                                                              queue: nil) { _ in reading.count = usage.today() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let counted = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            usage.record()
            counted.signal()
        }
        // Before the fix the recording thread never came back: it waited for its own lock, and held it, so nothing else may ask then.
        guard counted.wait(timeout: .now() + 5) == .success else {
            Issue.record("record() deadlocked on a read of the count made while it was writing")
            return
        }
        #expect(reading.count != nil)
        #expect(usage.today() == 1)
    }
}
