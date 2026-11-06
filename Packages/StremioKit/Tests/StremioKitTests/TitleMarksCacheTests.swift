import Foundation
@testable import StremioKit
import Testing

struct TitleMarksCacheTests {
    private let day = Date(timeIntervalSince1970: 1_790_000_000)
    private let netflix = TMDbWatchService(id: 8, name: "Netflix", logo: URL(string: "https://image.tmdb.org/t/p/w92/netflix.jpg"))

    @Test func keepsDiscsAndStreamersInTwelveBytesATitle() throws {
        var entries: [UInt32: TitleMarksCache.Entry] = [:]
        for number in 1...1_000 { entries[UInt32(number)] = .init(discDay: 2_000, streamerDay: 2_001, streamer: 8, disc: 2) }
        let data = TitleMarksCache.encode(entries: entries, services: [8: netflix], region: "GB")
        let header = 4 + 1 + 3 + 2 + (2 + 1 + 7 + 1 + netflix.logo!.absoluteString.utf8.count) + 4
        #expect(data.count == header + 1_000 * 12)
        let decoded = try #require(TitleMarksCache.decode(data, region: "GB"))
        #expect(decoded.entries == entries)
        #expect(decoded.services[8] == netflix)
    }

    @Test func anotherRegionKeepsDiscsAndDropsStreamers() throws {
        let entries: [UInt32: TitleMarksCache.Entry] = [
            468_569: .init(discDay: 2_000, streamerDay: 2_000, streamer: 8, disc: 2),
            1: .init(discDay: 0, streamerDay: 2_000, streamer: 8, disc: 0),
        ]
        let data = TitleMarksCache.encode(entries: entries, services: [8: netflix], region: "GB")
        let decoded = try #require(TitleMarksCache.decode(data, region: "US"))
        #expect(decoded.entries == [468_569: .init(discDay: 2_000, streamerDay: 0, streamer: 0, disc: 2)])
        #expect(decoded.services.isEmpty)
    }

    @Test func recordsReadBackByIMDbID() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("marks-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = TitleMarksCache(fileURL: file, region: "GB", capacity: 100, flushInterval: .zero)
        await cache.storeDisc(.uhdBluRay, for: "tt0468569", checkedAt: day)
        await cache.storeStreamer(netflix, for: "tt0903747", checkedAt: day)
        await cache.storeStreamer(nil, for: "tt0468569", checkedAt: day)
        let film = try #require(await cache.record(for: "tt0468569"))
        #expect(film.disc == .uhdBluRay)
        #expect(film.streamer == nil)
        #expect(film.streamerCheckedAt != nil)
        #expect(await cache.record(for: "tt0903747")?.streamer == netflix)
        #expect(await cache.record(for: "tt0903747")?.discCheckedAt == nil)
        #expect(await cache.record(for: "tt9999999") == nil)
        #expect(TitleMarksCache.date(TitleMarksCache.day(day))! <= day)
    }
}
