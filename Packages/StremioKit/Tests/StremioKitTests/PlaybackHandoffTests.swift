import Foundation
import Testing
@testable import StremioKit

@Suite struct PlaybackHandoffTests {
    // The stores prune against the real clock, so the test times are relative to now.
    private let now = Date()
    private let request = StreamRequest(type: "movie", id: "tt1", title: "Film", expectedDuration: 7200)

    private func handoff(_ id: String, startedAt: Date, contentID: String? = nil) -> PlaybackHandoff {
        var title = request
        if let contentID { title.id = contentID }
        return PlaybackHandoff(id: id, request: title, player: .infuse, startedAt: startedAt)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "test.handoffs.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func aHandoffRoundTripsThroughJSON() throws {
        let original = handoff("abc", startedAt: now)
        let decoded = try JSONDecoder().decode(PlaybackHandoff.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func eachNewHandoffGetsItsOwnToken() {
        let first = PlaybackHandoff(request: request, player: .infuse)
        let second = PlaybackHandoff(request: request, player: .infuse)
        #expect(!first.id.isEmpty && first.id != second.id)
    }

    @Test func aMemoryStoreHandsEachHandoffOutOnce() async {
        let store = InMemoryHandoffStore()
        await store.save(handoff("a", startedAt: now))
        let taken = await store.take(id: "a")
        #expect(taken?.request == request)
        let again = await store.take(id: "a")
        #expect(again == nil, "taking removes the hand-off")
        let unknown = await store.take(id: "missing")
        #expect(unknown == nil)
        await store.save(handoff("b", startedAt: now))
        await store.clear()
        let cleared = await store.take(id: "b")
        #expect(cleared == nil)
    }

    @Test func aMemoryStoreKeepsTheTwentyNewest() async {
        let store = InMemoryHandoffStore()
        for index in 0..<25 {
            await store.save(handoff("h\(index)", startedAt: now.addingTimeInterval(TimeInterval(index)), contentID: "tt\(index)"))
        }
        let oldest = await store.take(id: "h4")
        #expect(oldest == nil, "the five oldest were dropped")
        let kept = await store.take(id: "h5")
        #expect(kept != nil)
        let newest = await store.take(id: "h24")
        #expect(newest != nil)
    }

    @Test func aMemoryStoreDropsHandoffsOlderThanAWeek() async {
        let store = InMemoryHandoffStore()
        await store.save(handoff("old", startedAt: now.addingTimeInterval(-8 * 86_400)))
        await store.save(handoff("recent", startedAt: now.addingTimeInterval(-6 * 86_400)))
        let old = await store.take(id: "old")
        #expect(old == nil)
        let recent = await store.take(id: "recent")
        #expect(recent != nil)
    }

    @Test func theDefaultsStoreKeepsHandoffsAcrossInstances() async throws {
        let defaults = try isolatedDefaults()
        await DefaultsHandoffStore(defaults: defaults).save(handoff("abc", startedAt: now))
        #expect(defaults.data(forKey: "playback.handoffs.v1") != nil)
        let reopened = DefaultsHandoffStore(defaults: defaults)
        let found = await reopened.take(id: "abc")
        #expect(found?.request == request && found?.player == .infuse)
        let again = await reopened.take(id: "abc")
        #expect(again == nil)
    }

    @Test func theDefaultsStoreKeepsTheTwentyNewestAndDropsOldOnes() async throws {
        let store = DefaultsHandoffStore(defaults: try isolatedDefaults())
        await store.save(handoff("ancient", startedAt: now.addingTimeInterval(-30 * 86_400)))
        for index in 0..<22 {
            await store.save(handoff("h\(index)", startedAt: now.addingTimeInterval(TimeInterval(index)), contentID: "tt\(index)"))
        }
        let ancient = await store.take(id: "ancient")
        #expect(ancient == nil)
        let dropped = await store.take(id: "h1")
        #expect(dropped == nil, "the two oldest of the 22 are gone")
        let kept = await store.take(id: "h2")
        #expect(kept != nil)
    }

    @Test func clearingTheDefaultsStoreRemovesEverything() async throws {
        let defaults = try isolatedDefaults()
        let store = DefaultsHandoffStore(defaults: defaults)
        await store.save(handoff("abc", startedAt: now))
        await store.clear()
        #expect(defaults.object(forKey: "playback.handoffs.v1") == nil)
    }

    @Test func aNewPlaySupersedesOlderCallbacksButSavingDoesNot() async throws {
        let stores: [any HandoffStore] = [InMemoryHandoffStore(), DefaultsHandoffStore(defaults: try isolatedDefaults())]
        for store in stores {
            await store.save(handoff("old", startedAt: now))
            await store.save(handoff("new", startedAt: now))
            await store.save(PlaybackHandoff(id: "save", request: request, player: .infuse, startedAt: now, action: .save))
            #expect(await store.take(id: "old") == nil)
            #expect(await store.take(id: "new") != nil)
            #expect(await store.take(id: "save")?.action == .save)
        }
    }

    @Test func unreadableDefaultsDataLoadsAsNothing() async throws {
        let defaults = try isolatedDefaults()
        defaults.set(Data("not json".utf8), forKey: "playback.handoffs.v1")
        let store = DefaultsHandoffStore(defaults: defaults)
        let missing = await store.take(id: "abc")
        #expect(missing == nil)
        await store.save(handoff("abc", startedAt: now))
        let saved = await store.take(id: "abc")
        #expect(saved != nil, "a bad value is replaced, not a reason to fail")
    }
}
