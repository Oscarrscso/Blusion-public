import Foundation
import Testing
import StremioKit
import PlayerKitTestSupport
@testable import PlayerKit

@MainActor
@Suite struct FallbackEngineTests {
    private let item = PlaybackItem(url: URL(string: "https://e.example.com/movie.mkv")!, headers: ["X-A": "1"], title: "MKV", startPosition: 12)
    private let audio = [MediaTrack(id: "a1", title: "English AC3", language: "eng", isDefault: true), MediaTrack(id: "a2", title: "French DTS", language: "fre")]
    private let subs = [MediaTrack(id: "s1", title: "English", language: "eng")]

    private func make(autoLoad: Bool = true, fail: PlaybackFailure? = nil) -> (FallbackEngine, MockBackend) {
        let backend = MockBackend(autoLoad: autoLoad ? (200, [], []) : nil, failOnLoad: fail)
        return (FallbackEngine(backend: backend), backend)
    }

    private func settle(_ engine: FallbackEngine, until condition: @MainActor (PlaybackState) -> Bool) async throws {
        try await waitUntil { condition(engine.state) }
    }

    @Test func loadingThenReadyWhenPlayWasNotRequested() async throws {
        let (engine, backend) = make()
        #expect(engine.state.status == .idle)
        engine.load(item)
        #expect(engine.state.status == .loading)
        try await settle(engine) { $0.status == .ready }
        #expect(engine.state.duration == 200)
        #expect(backend.loads.first?.url == item.url && backend.loads.first?.headers == ["X-A": "1"] && backend.loads.first?.start == 12)
    }

    @Test func playStartsPlaybackAndPauseStopsIt() async throws {
        let (engine, backend) = make()
        engine.load(item)
        engine.play()
        try await settle(engine) { $0.status == .playing }
        engine.pause()
        try await settle(engine) { $0.status == .paused }
        engine.play()
        try await settle(engine) { $0.status == .playing }
        #expect(backend.pausedCalls == [false, true, false])
    }

    @Test func positionDurationAndBufferFollowTheBackend() async throws {
        let (engine, backend) = make()
        engine.load(item)
        engine.play()
        try await settle(engine) { $0.status == .playing }
        backend.emit(.position(42.5))
        backend.emit(.buffered(60))
        try await settle(engine) { $0.position == 42.5 && $0.bufferedUntil == 60 }
        backend.emit(.position(-3))
        try await settle(engine) { $0.position == 0 }
    }

    @Test func bufferingShowsOnlyWhileTryingToPlay() async throws {
        let (engine, backend) = make()
        engine.load(item)
        engine.play()
        try await settle(engine) { $0.status == .playing }
        backend.emit(.buffering(true))
        try await settle(engine) { $0.status == .buffering }
        backend.emit(.buffering(false))
        try await settle(engine) { $0.status == .playing }
        engine.pause()
        try await settle(engine) { $0.status == .paused }
        backend.emit(.buffering(true))
        try await Task.sleep(for: .milliseconds(30))
        #expect(engine.state.status == .paused, "buffering while paused is not shown")
    }

    @Test func tracksAndTheirSelection() async throws {
        let backend = MockBackend(autoLoad: (60, audio, subs))
        let engine = FallbackEngine(backend: backend)
        engine.load(item)
        try await settle(engine) { $0.status == .ready }
        #expect(engine.state.audioTracks.map(\.id) == ["a1", "a2"] && engine.state.embeddedSubtitleTracks.map(\.id) == ["s1"])
        #expect(engine.state.selectedAudioTrackID == "a1")
        engine.selectAudioTrack(id: "a2")
        engine.selectEmbeddedSubtitleTrack(id: "s1")
        #expect(backend.audioSelections == ["a2"] && backend.subtitleSelections == ["s1"])
        #expect(engine.state.selectedAudioTrackID == "a2" && engine.state.selectedEmbeddedSubtitleID == "s1")
        engine.selectEmbeddedSubtitleTrack(id: nil)
        #expect(engine.state.selectedEmbeddedSubtitleID == nil)
    }

    @Test func seekAndRateReachTheBackend() async throws {
        let (engine, backend) = make()
        engine.load(item)
        await engine.seek(to: 99)
        await engine.seek(to: -4)
        engine.setRate(1.5)
        #expect(backend.seeks == [99, 0] && backend.rates == [1.5] && engine.state.rate == 1.5)
    }

    @Test func volumeAndMuteReachTheBackend() {
        let (engine, backend) = make()
        engine.setVolume(0.4)
        engine.setMuted(true)
        #expect(backend.volumes == [0.4] && backend.mutes == [true])
    }

    @Test func endingAndReplaying() async throws {
        let (engine, backend) = make()
        engine.load(item)
        engine.play()
        try await settle(engine) { $0.status == .playing }
        backend.emit(.ended)
        try await settle(engine) { $0.status == .ended }
        engine.play()   // replay: seek to the start, then play
        try await settle(engine) { $0.status == .playing }
        #expect(backend.seeks.last == 0)
    }

    @Test func aLoadFailureIsReportedThroughState() async throws {
        let failure = PlaybackFailure(.format, "Unsupported codec")
        let (engine, _) = make(fail: failure)
        engine.load(item)
        try await settle(engine) { $0.failure == failure }
        #expect(!engine.state.hasStarted)
    }

    @Test func stoppingShutsTheBackendDownAndGoesIdle() async throws {
        let (engine, backend) = make()
        engine.load(item)
        engine.play()
        try await settle(engine) { $0.status == .playing }
        engine.stop()
        #expect(backend.isShutDown)
        #expect(engine.state.status == .idle)
        backend.emit(.position(5))
        try await Task.sleep(for: .milliseconds(30))
        #expect(engine.state.status == .idle && engine.state.position != 5, "events after stop are ignored")
    }

    @Test func exposesTheVideoSurface() {
        let (engine, backend) = make()
        let direct = engine.videoSurface === backend.videoSurface
        #expect(direct)
        let provider: any VideoSurfaceProviding = engine
        let viaProtocol = provider.videoSurface === backend.videoSurface
        #expect(viaProtocol)
    }

    @Test func aReloadResetsTheState() async throws {
        let (engine, _) = make()
        engine.load(item)
        engine.play()
        try await settle(engine) { $0.status == .playing }
        engine.load(item)
        #expect(engine.state.status == .loading && engine.state.position == 0)
    }

    @Test func theCoordinatorPlaysFallbackRoutesThroughThisEngine() async throws {
        let url = URL(string: "https://e.example.com/movie.mkv")!
        let candidate = PlaybackCandidate(id: "mkv", title: "MKV", route: .fallback(url, .container(.matroska)))
        let plan = PlaybackPlan(request: StreamRequest(type: "movie", id: "tt1", title: "Movie"), candidates: [candidate])
        let backend = MockBackend(autoLoad: (50, audio, subs))
        let coordinator = PlaybackCoordinator(plan: plan, startupTimeout: .seconds(2), makeEngine: { candidate in
            if case .fallback = candidate.route { return FallbackEngine(backend: backend) }
            return nil
        })
        await coordinator.start()
        #expect(coordinator.phase == .playing)
        #expect(coordinator.state.audioTracks.count == 2)
        let hostsOwnSurface = (coordinator.engine as? any VideoSurfaceProviding) != nil
        #expect(hostsOwnSurface)
        await coordinator.stop()
        #expect(backend.isShutDown)
    }

    @Test func addedFilesChaptersAndExtrasGoThroughTheBackend() async throws {
        let (engine, backend) = make()
        engine.load(item)
        engine.play()
        try await settle(engine) { $0.status == .playing }
        #expect(engine.capabilities.contains(.engineSubtitles) && engine.capabilities.contains(.audioDelay))
        let subtitle = ExternalSubtitle(url: URL(string: "https://subs.example.com/a.ass")!, title: "Styled", language: "eng")
        engine.addExternalSubtitle(subtitle)
        engine.setSubtitleDelay(1.5)
        engine.setAudioDelay(-0.2)
        engine.apply(layout: VideoLayout(fit: .fill))
        engine.apply(processing: VideoProcessing(deinterlace: .on))
        #expect(backend.addedSubtitles == [subtitle])
        #expect(backend.subtitleDelays == [1.5] && backend.audioDelays == [-0.2])
        #expect(backend.layouts.last?.fit == .fill && backend.processings.last?.deinterlace == .on)

        let added = MediaTrack(id: "s9", title: "Styled", language: "eng", isExternal: true)
        backend.emit(.tracks(audio: audio, subtitles: subs + [added], selectedAudio: audio.first?.id, selectedSubtitle: "s9"))
        try await settle(engine) { $0.selectedEmbeddedSubtitleID == "s9" }
        #expect(engine.state.embeddedSubtitleTracks.last?.isExternal == true)

        backend.emit(.chapters([Chapter(index: 0, title: "Intro", start: 0), Chapter(index: 1, title: "Part 1", start: 90)]))
        try await settle(engine) { $0.chapters.count == 2 }
        #expect(engine.state.status == .playing, "track and chapter updates keep the status")
        #expect(engine.statistics().engine == "MockBackend")
    }
}
