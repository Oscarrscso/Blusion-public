import Foundation
import Testing
import StremioKit
@testable import PlayerKit

@Suite struct ProgressTests {
    private let request = StreamRequest(type: "movie", id: "tt1", title: "Movie", poster: URL(string: "https://e.com/p.jpg"))
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func savesEveryTenSecondsNotBefore() {
        var recorder = ProgressRecorder(request: request, previous: nil)
        #expect(recorder.observe(position: 1, duration: 100, now: at(0)) == nil)
        #expect(recorder.observe(position: 5, duration: 100, now: at(4)) == nil)
        #expect(recorder.observe(position: 9.9, duration: 100, now: at(9.9)) == nil)
        let first = recorder.observe(position: 11, duration: 100, now: at(10))
        #expect(first?.position == 11 && first?.duration == 100 && first?.isWatched == false)
        #expect(first?.id == "movie/tt1" && first?.title == "Movie" && first?.contentID == "tt1")
        #expect(recorder.observe(position: 15, duration: 100, now: at(15)) == nil)
        #expect(recorder.observe(position: 21, duration: 100, now: at(20))?.position == 21)
    }

    @Test func crossingNinetyPercentSavesAtOnceAndMarksWatched() {
        var recorder = ProgressRecorder(request: request, previous: nil)
        _ = recorder.observe(position: 50, duration: 100, now: at(0))
        #expect(recorder.observe(position: 89.9, duration: 100, now: at(1)) == nil)
        let watched = recorder.observe(position: 90, duration: 100, now: at(2))
        #expect(watched?.isWatched == true, "90% is the watched threshold")
        #expect(recorder.observe(position: 95, duration: 100, now: at(3)) == nil, "already recorded; back to the interval")
    }

    @Test func watchedIsSticky() {
        let previous = WatchProgress(id: "movie/tt1", type: "movie", contentID: "tt1", title: "Movie", position: 95, duration: 100, isWatched: true, updatedAt: t0)
        var recorder = ProgressRecorder(request: request, previous: previous)
        _ = recorder.observe(position: 10, duration: 100, now: at(0))
        #expect(recorder.finish(now: at(30))?.isWatched == true, "rewatching from the start doesn't unwatch it")
    }

    @Test func finishAlwaysWritesTheLatestPosition() {
        var recorder = ProgressRecorder(request: request, previous: nil)
        #expect(recorder.finish(now: at(0)) == nil, "nothing observed, nothing to write")
        _ = recorder.observe(position: 3, duration: 200, now: at(0))
        let final = recorder.finish(now: at(3))
        #expect(final?.position == 3 && final?.duration == 200)
        #expect(final?.updatedAt == at(3))
    }

    @Test func invalidReadingsAreIgnored() {
        var recorder = ProgressRecorder(request: request, previous: nil)
        #expect(recorder.observe(position: 5, duration: nil, now: at(20)) == nil)
        #expect(recorder.observe(position: 5, duration: 0, now: at(20)) == nil)
        #expect(recorder.observe(position: -1, duration: 10, now: at(20)) == nil)
        #expect(recorder.observe(position: .nan, duration: 10, now: at(20)) == nil)
        #expect(recorder.observe(position: 1, duration: .infinity, now: at(20)) == nil)
        #expect(recorder.finish(now: at(20)) == nil)
    }

    @Test func episodesKeepSeasonEpisodeAndSeries() {
        let episode = StreamRequest(type: "series", id: "tt9:2:5", title: "Show · Pilot", season: 2, episode: 5)
        var recorder = ProgressRecorder(request: episode, previous: nil)
        _ = recorder.observe(position: 1, duration: 100, now: at(0))
        let saved = recorder.finish(now: at(1))
        #expect(saved?.id == "series/tt9:2:5" && saved?.season == 2 && saved?.episode == 5)
        #expect(saved?.seriesID == "tt9")
        #expect(WatchProgress(id: "m", type: "movie", contentID: "tt1", title: "", position: 0, duration: 1, isWatched: false, updatedAt: t0).seriesID == nil)
    }

    @Test func resumePolicy() {
        func progress(_ position: TimeInterval, _ duration: TimeInterval = 100, watched: Bool = false) -> WatchProgress {
            WatchProgress(id: "x", type: "movie", contentID: "x", title: "", position: position, duration: duration, isWatched: watched, updatedAt: t0)
        }
        #expect(ProgressRecorder.resumePosition(for: nil) == 0)
        #expect(ProgressRecorder.resumePosition(for: progress(4)) == 0, "barely started")
        #expect(ProgressRecorder.resumePosition(for: progress(5)) == 5)
        #expect(ProgressRecorder.resumePosition(for: progress(60)) == 60)
        #expect(ProgressRecorder.resumePosition(for: progress(96)) == 0, "nearly finished: start over")
        #expect(ProgressRecorder.resumePosition(for: progress(60, watched: true)) == 0)
        #expect(ProgressRecorder.resumePosition(for: progress(60, 0)) == 60, "an unknown length no longer means start over: see anUnknownLength...")
        #expect(ProgressRecorder.resumePosition(for: progress(30), policy: ProgressPolicy(minimumResume: 60)) == 0)
    }

    @Test func anUnknownLengthResumesWhereTheViewerStopped() {
        func progress(_ position: TimeInterval, watched: Bool = false) -> WatchProgress {
            WatchProgress(id: "x", type: "movie", contentID: "x", title: "", position: position, duration: 0, isWatched: watched, updatedAt: t0)
        }
        #expect(ProgressRecorder.resumePosition(for: progress(60)) == 60, "a hand-off reported a position but no length")
        #expect(ProgressRecorder.resumePosition(for: progress(4)) == 0, "barely started")
        #expect(ProgressRecorder.resumePosition(for: progress(5)) == 5)
        #expect(ProgressRecorder.resumePosition(for: progress(60, watched: true)) == 0, "watched starts over")
        #expect(ProgressRecorder.resumePosition(for: progress(30), policy: ProgressPolicy(minimumResume: 60)) == 0)
    }

    @Test func fractionIsClamped() {
        let p = WatchProgress(id: "x", type: "movie", contentID: "x", title: "", position: 150, duration: 100, isWatched: false, updatedAt: t0)
        #expect(p.fraction == 1)
        #expect(WatchProgress(id: "x", type: "movie", contentID: "x", title: "", position: 5, duration: 0, isWatched: false, updatedAt: t0).fraction == 0)
    }

    @Test func inMemoryStoreRoundTripsAndOrdersByRecency() async {
        let store = InMemoryProgressStore()
        func item(_ id: String, _ age: TimeInterval) -> WatchProgress {
            WatchProgress(id: id, type: "movie", contentID: id, title: id, position: 1, duration: 10, isWatched: false, updatedAt: t0.addingTimeInterval(age))
        }
        await store.save(item("old", 0))
        await store.save(item("new", 100))
        await store.save(item("mid", 50))
        #expect(await store.all().map(\.id) == ["new", "mid", "old"])
        #expect(await store.progress(for: "mid")?.title == "mid")
        await store.remove("mid")
        #expect(await store.progress(for: "mid") == nil)
        await store.clear()
        #expect(await store.all().isEmpty)
    }

    @Test @MainActor func sessionWritesOnTheIntervalAndOnFinish() async {
        let store = InMemoryProgressStore()
        let clock = ClockBox(t0)
        let session = ProgressSession(request: request, previous: nil, store: store, clock: { clock.now })
        session.observe(position: 1, duration: 100)
        clock.now = t0.addingTimeInterval(11)
        session.observe(position: 12, duration: 100)
        clock.now = t0.addingTimeInterval(13)
        session.observe(position: 14, duration: 100)
        await session.finish()
        let saved = await store.progress(for: "movie/tt1")
        #expect(saved?.position == 14, "finish wrote the latest position after the interval save at 12")
        #expect(saved?.updatedAt == t0.addingTimeInterval(13))
    }
}

final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
