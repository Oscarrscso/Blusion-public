import Foundation
import Testing
@testable import StremioKit

@Suite struct RatingsCacheTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// The cache with the production limits, reopened over the same file.
    private func open(_ file: URL) -> FileRatingsCache {
        FileRatingsCache(fileURL: file, maxEntries: 5_000, flushInterval: .seconds(2))
    }

    /// A fresh folder inside this package's `.build`, so no test writes outside the sandbox. Removed by the caller.
    private func scratchDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/ratings-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Wait for the actual coalesced write; a fixed sleep races the writer when the full suite runs concurrently.
    private func waitForStoredRatings(_ file: URL, count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while true {
            if let data = try? Data(contentsOf: file),
               let stored = try? JSONDecoder().decode([String: CachedRating].self, from: data), stored.count == count { return }
            try #require(Date() < deadline, "The ratings file did not finish writing \(count) entries")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func inMemoryCacheStoresReadsAndClears() async {
        let cache = InMemoryRatingsCache()
        await cache.store(CachedRating(rating: 4.5, fetchedAt: Self.t0), for: "tt0468569")
        let stored = await cache.value(for: "tt0468569")
        #expect(stored == CachedRating(rating: 4.5, fetchedAt: Self.t0))
        await cache.clear()
        let cleared = await cache.value(for: "tt0468569")
        #expect(cleared == nil)
    }

    @Test func ratingsSurviveARestart() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ratings.json")
        let first = FileRatingsCache(fileURL: file, maxEntries: 100, flushInterval: .milliseconds(50))
        await first.store(CachedRating(rating: 4.5, fetchedAt: Self.t0), for: "tt0468569")
        await first.store(CachedRating(rating: nil, fetchedAt: Self.t0), for: "tt0944947")
        try await waitForStoredRatings(file, count: 2)

        let second = open(file)
        let rated = await second.value(for: "tt0468569")
        let unrated = await second.value(for: "tt0944947")
        let missing = await second.value(for: "tt0000001")
        #expect(rated == CachedRating(rating: 4.5, fetchedAt: Self.t0))
        #expect(unrated == CachedRating(rating: nil, fetchedAt: Self.t0))
        #expect(missing == nil)
    }

    @Test func theCapDropsTheOldestRatings() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ratings.json")
        let cache = FileRatingsCache(fileURL: file, maxEntries: 3, flushInterval: .milliseconds(10))
        for n in 1...5 {
            await cache.store(CachedRating(rating: 3, fetchedAt: Self.t0.addingTimeInterval(Double(n))), for: "tt000000\(n)")
        }
        var kept: [String] = []
        for n in 1...5 {
            let value = await cache.value(for: "tt000000\(n)")
            if value != nil { kept.append("tt000000\(n)") }
        }
        #expect(kept == ["tt0000003", "tt0000004", "tt0000005"])
    }

    @Test func clearRemovesTheFileAndEverythingInIt() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ratings.json")
        let cache = FileRatingsCache(fileURL: file, maxEntries: 5_000, flushInterval: .milliseconds(10))
        await cache.store(CachedRating(rating: 4.5, fetchedAt: Self.t0), for: "tt0468569")
        await cache.clear()
        let cleared = await cache.value(for: "tt0468569")
        #expect(cleared == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: file.path), "a write queued before the clear must not bring the file back")
        let reopened = open(file)
        let gone = await reopened.value(for: "tt0468569")
        #expect(gone == nil)
    }

    @Test func aCorruptFileStartsEmptyAndIsReplaced() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ratings.json")
        try Data("this is not json {".utf8).write(to: file)
        let cache = FileRatingsCache(fileURL: file, maxEntries: 5_000, flushInterval: .milliseconds(10))
        let before = await cache.value(for: "tt0468569")
        #expect(before == nil)
        await cache.store(CachedRating(rating: 4.5, fetchedAt: Self.t0), for: "tt0468569")
        try await waitForStoredRatings(file, count: 1)
        let reopened = open(file)
        let after = await reopened.value(for: "tt0468569")
        #expect(after == CachedRating(rating: 4.5, fetchedAt: Self.t0))
    }

    @Test func fiftyStoresInARowCauseFarFewerWrites() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ratings.json")
        let cache = FileRatingsCache(fileURL: file, maxEntries: 100, flushInterval: .milliseconds(300))
        for n in 0..<50 {
            await cache.store(CachedRating(rating: 3, fetchedAt: Self.t0), for: "tt\(1_000_000 + n)")
        }
        try await waitForStoredRatings(file, count: 50)
        let writes = await cache.writeCount
        #expect(writes >= 1 && writes <= 2, "one write at once, one when the interval ends: got \(writes)")

        let reopened = open(file)
        var found = 0
        for n in 0..<50 {
            let value = await reopened.value(for: "tt\(1_000_000 + n)")
            if value != nil { found += 1 }
        }
        #expect(found == 50, "the last stores are written too")
    }
}
