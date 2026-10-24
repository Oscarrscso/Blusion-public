import Foundation
import Testing
import StremioKit
import PlayerKitTestSupport
@testable import PlayerKit

/// What the listener set carries over when the coordinator replaces the engine.
@MainActor
@Suite struct PlaybackContinuityTests {
    private let request = StreamRequest(type: "movie", id: "tt1", title: "Movie")
    private let english = MediaTrack(id: "audio-0", title: "English 5.1", language: "en")
    private let french = MediaTrack(id: "audio-1", title: "French", language: "fr")
    private let englishSubs = MediaTrack(id: "subtitle-0", title: "English", language: "eng")
    private let englishForced = MediaTrack(id: "subtitle-1", title: "English (forced)", language: "eng", isForced: true)

    private func candidate(_ name: String) -> PlaybackCandidate {
        PlaybackCandidate(id: name, title: name, route: .native(URL(string: "https://e.example.com/\(name).mp4")!))
    }

    /// Engines in creation order, each with tracks numbered its own way (as AVPlayer's and mpv's are).
    @MainActor private final class Rig {
        var engines: [MockEngine] = []
        var made: [PlaybackCandidate] = []
        let make: (PlaybackCandidate, Int) -> MockEngine?
        init(_ make: @escaping (PlaybackCandidate, Int) -> MockEngine?) { self.make = make }
        func engine(for candidate: PlaybackCandidate) -> (any PlaybackEngine)? {
            made.append(candidate)
            guard let engine = make(candidate, engines.count) else { return nil }
            engines.append(engine)
            return engine
        }
    }

    private func mpvTracks() -> (audio: [MediaTrack], subtitles: [MediaTrack]) {
        ([MediaTrack(id: "a1", title: "English 5.1", language: "eng"), MediaTrack(id: "a2", title: "French", language: "fre")],
         [MediaTrack(id: "s1", title: "English", language: "eng"), MediaTrack(id: "s2", title: "Forced", language: "eng", isForced: true)])
    }

    @Test func rateTracksDelaysAndPictureSettingsCarryOverToTheNextStream() async throws {
        let tracks = mpvTracks()
        let rig = Rig { [english, french, englishSubs, englishForced] _, index in
            index == 0 ? MockEngine(audio: [english, french], subtitles: [englishSubs, englishForced])
                : MockEngine(capabilities: [.audioDelay, .subtitleDelay], audio: tracks.audio, subtitles: tracks.subtitles)
        }
        let plan = PlaybackPlan(request: request, candidates: [candidate("a"), candidate("b")])
        let coordinator = PlaybackCoordinator(plan: plan, makeEngine: { rig.engine(for: $0) })
        await coordinator.start()
        coordinator.setRate(1.5)
        coordinator.selectAudioTrack(id: "audio-1")
        coordinator.selectEmbeddedSubtitleTrack(id: "subtitle-1")
        coordinator.setAudioDelay(0.25)
        coordinator.setSubtitleDelay(-1)
        let layout = VideoLayout(fit: .fill, zoom: 1.2)
        coordinator.setVideoLayout(layout)
        coordinator.setProcessing(VideoProcessing(toneMapping: .spline))
        await coordinator.advance()

        let second = try #require(rig.engines.last)
        try await waitUntil { second.selectedEmbeddedSubtitles.last == "s2" }
        #expect(second.rates == [1.5])
        #expect(second.selectedAudio.last == "a2", "French, by language, though the id differs")
        #expect(second.audioDelays == [0.25] && second.subtitleDelays == [-1])
        #expect(second.layouts.last == layout)
        #expect(second.processings.last?.toneMapping == .spline)
        #expect(coordinator.rate == 1.5)
    }

    @Test func subtitlesTurnedOffStayOffInTheNextEngine() async throws {
        let tracks = mpvTracks()
        let rig = Rig { [englishSubs] _, index in
            index == 0 ? MockEngine(subtitles: [englishSubs]) : MockEngine(audio: tracks.audio, subtitles: tracks.subtitles)
        }
        let plan = PlaybackPlan(request: request, candidates: [candidate("a"), candidate("b")])
        let coordinator = PlaybackCoordinator(plan: plan, makeEngine: { rig.engine(for: $0) })
        await coordinator.start()
        coordinator.selectEmbeddedSubtitleTrack(id: nil)
        await coordinator.advance()
        let second = try #require(rig.engines.last)
        #expect(second.selectedEmbeddedSubtitles.isEmpty, "nothing selected, nothing to turn off")
        #expect(second.selectedAudio.isEmpty, "no audio choice was made, so the file's default stays")
    }

    @Test func engineLoadedSubtitlesAreLoadedAgainAndReselected() async throws {
        let rig = Rig { _, _ in MockEngine(capabilities: [.engineSubtitles], subtitles: [MediaTrack(id: "s1", title: "English", language: "eng")]) }
        let plan = PlaybackPlan(request: request, candidates: [candidate("a"), candidate("b")])
        let coordinator = PlaybackCoordinator(plan: plan, makeEngine: { rig.engine(for: $0) })
        await coordinator.start()
        let file = ExternalSubtitle(url: URL(string: "https://subs.example.com/a.ass")!, title: "Signs & Songs", language: "eng")
        coordinator.addEngineSubtitle(file)
        #expect(rig.engines[0].addedSubtitles == [file])
        coordinator.selectEmbeddedSubtitleTrack(id: "s1")
        coordinator.addEngineSubtitle(file)
        await coordinator.advance()
        let second = try #require(rig.engines.last)
        try await waitUntil { second.addedSubtitles == [file] }
        #expect(second.state.embeddedSubtitleTracks.contains { $0.isExternal && $0.title == "Signs & Songs" })
        #expect(second.state.selectedEmbeddedSubtitleID == "x1")
    }

    @Test func engineSubtitlesAreIgnoredByAnEngineThatCannotDrawThem() async {
        let rig = Rig { _, _ in MockEngine() }
        let coordinator = PlaybackCoordinator(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), makeEngine: { rig.engine(for: $0) })
        await coordinator.start()
        coordinator.addEngineSubtitle(ExternalSubtitle(url: URL(string: "https://subs.example.com/a.sup")!, title: "PGS"))
        #expect(rig.engines[0].addedSubtitles.isEmpty)
    }

    @Test func aBufferThatKeepsFillingIsNotAStall() async throws {
        let rig = Rig { _, _ in MockEngine() }
        let plan = PlaybackPlan(request: request, candidates: [candidate("a"), candidate("b")])
        let coordinator = PlaybackCoordinator(plan: plan, stallTimeout: .seconds(1), makeEngine: { rig.engine(for: $0) })
        await coordinator.start()
        let engine = rig.engines[0]
        engine.simulateBuffering()
        // 1.6 s of buffering against a 1 s stall timeout, with data every 0.1 s.
        for step in 1...16 {
            try await Task.sleep(for: .milliseconds(100))
            engine.simulate(bufferedUntil: Double(step) * 5)
        }
        #expect(rig.engines.count == 1 && coordinator.failedAttempts.isEmpty, "data was arriving the whole time")
        await coordinator.stop()
    }

    @Test func aFormatFailureMidStreamIsNotReconnected() async throws {
        let rig = Rig { _, _ in MockEngine() }
        let plan = PlaybackPlan(request: request, candidates: [candidate("a"), candidate("b")])
        let coordinator = PlaybackCoordinator(plan: plan, makeEngine: { rig.engine(for: $0) })
        await coordinator.start()
        rig.engines[0].simulateFailure(PlaybackFailure(.format, "corrupt"))
        try await waitUntil { coordinator.current?.id == "b" && coordinator.phase == .playing }
        #expect(rig.made.map(\.id) == ["a", "b"])
    }

    @Test func reopeningInTheFallbackEngineKeepsThePositionAndTheStream() async throws {
        let rig = Rig { _, _ in MockEngine(capabilities: []) }
        let plan = PlaybackPlan(request: request, candidates: [candidate("a"), candidate("b")], retriesInFallbackEngine: true)
        let coordinator = PlaybackCoordinator(plan: plan, makeEngine: { rig.engine(for: $0) })
        var changes: [String] = []
        coordinator.onCandidateChange = { changes.append($0.id) }
        await coordinator.start()
        rig.engines[0].simulate(position: 61)
        try await waitUntil { coordinator.state.position == 61 }
        await coordinator.reopenInFallbackEngine()
        let reopened = try #require(rig.made.last)
        #expect(reopened.id == "a")
        if case .fallback = reopened.route {} else { Issue.record("expected the fallback route, got \(reopened.route)") }
        #expect(rig.engines.last?.loadedItems.first?.startPosition == 61)
        #expect(coordinator.phase == .playing)
        #expect(changes == ["a"], "the same stream: stream-specific extras are not looked up again")
        await coordinator.reopenInFallbackEngine()
        #expect(rig.made.count == 2, "already in the fallback engine")
    }

    @Test func reopeningNeedsAFallbackEngine() async {
        let rig = Rig { _, _ in MockEngine() }
        let coordinator = PlaybackCoordinator(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), makeEngine: { rig.engine(for: $0) })
        await coordinator.start()
        await coordinator.reopenInFallbackEngine()
        #expect(rig.made.count == 1)
    }

    @Test func reopeningAFallbackEngineThatCannotDrawSubtitlesMovesTheStreamToTheFullFeaturedEngine() async throws {
        let url = URL(string: "https://e.example.com/a.mkv")!
        let stream = PlaybackCandidate(id: "a", title: "a", route: .fallback(url, .container(.matroska)))
        let rig = Rig { _, _ in MockEngine(capabilities: []) }
        let plan = PlaybackPlan(request: request, candidates: [stream, candidate("b")], retriesInFallbackEngine: true, retriesInBackupEngine: true)
        let coordinator = PlaybackCoordinator(plan: plan, makeEngine: { rig.engine(for: $0) })
        await coordinator.start()
        rig.engines[0].simulate(position: 61)
        try await waitUntil { coordinator.state.position == 61 }
        await coordinator.reopenInFallbackEngine()
        #expect(rig.made.last?.route == .fallback(url, .fullFeaturedEngine))
        #expect(coordinator.current?.id == "a" && coordinator.phase == .playing)
        #expect(rig.engines.last?.loadedItems.first?.startPosition == 61, "from where it is now")
        await coordinator.reopenInFallbackEngine()
        #expect(rig.made.count == 2, "already in the full-featured engine")
        await coordinator.stop()
    }

    @Test func reopeningDoesNothingInAnEngineThatDrawsSubtitlesItself() async {
        let url = URL(string: "https://e.example.com/a.mkv")!
        let stream = PlaybackCandidate(id: "a", title: "a", route: .fallback(url, .container(.matroska)))
        let rig = Rig { _, _ in MockEngine(capabilities: [.engineSubtitles]) }
        let plan = PlaybackPlan(request: request, candidates: [stream], retriesInFallbackEngine: true, retriesInBackupEngine: true)
        let coordinator = PlaybackCoordinator(plan: plan, makeEngine: { rig.engine(for: $0) })
        await coordinator.start()
        await coordinator.reopenInFallbackEngine()
        #expect(rig.made.count == 1, "the engine draws styled subtitles itself")
        #expect(coordinator.current?.route == .fallback(url, .container(.matroska)))
        await coordinator.stop()
    }

    @Test func anotherStreamIsAnnounced() async {
        let rig = Rig { candidate, _ in candidate.id == "a" ? MockEngine(.failsToLoad(PlaybackFailure(.notFound, "gone"))) : MockEngine() }
        let plan = PlaybackPlan(request: request, candidates: [candidate("a"), candidate("b")])
        let coordinator = PlaybackCoordinator(plan: plan, makeEngine: { rig.engine(for: $0) })
        var changes: [String] = []
        coordinator.onCandidateChange = { changes.append($0.id) }
        await coordinator.start()
        #expect(changes == ["a", "b"])
    }
}

@Suite struct SkipMarkerTests {
    @Test func chapterNamesMarkIntrosRecapsAndCredits() {
        let chapters = [Chapter(index: 0, title: "Previously On", start: 0), Chapter(index: 1, title: "Opening Credits", start: 45),
                        Chapter(index: 2, title: "Chapter 2", start: 130), Chapter(index: 3, title: "End Credits", start: 2500)]
        let markers = SkipMarkers.markers(chapters: chapters, duration: 2600)
        #expect(markers == [SkipMarker(kind: .recap, start: 0, end: 45), SkipMarker(kind: .intro, start: 45, end: 130),
                            SkipMarker(kind: .credits, start: 2500, end: 2600)])
    }

    @Test func animeStyleShortNamesCount() {
        let chapters = [Chapter(index: 0, title: "Prologue", start: 0), Chapter(index: 1, title: "OP", start: 60),
                        Chapter(index: 2, title: "Part A", start: 150), Chapter(index: 3, title: "ED", start: 1300), Chapter(index: 4, title: "Preview", start: 1390)]
        let kinds = SkipMarkers.markers(chapters: chapters, duration: 1420).map(\.kind)
        #expect(kinds == [.intro, .credits, .preview])
    }

    @Test func implausibleOrUnnamedChaptersAreNotMarkers() {
        let chapters = [Chapter(index: 0, title: "Intro", start: 0), Chapter(index: 1, title: "Chapter 2", start: 1800),
                        Chapter(index: 2, title: "Introduction to the Case", start: 1900), Chapter(index: 3, title: "Operation", start: 1901)]
        #expect(SkipMarkers.markers(chapters: chapters, duration: 4000).isEmpty, "a 30-minute intro, a 1-second one, and words that only contain the names")
    }
}
