import Foundation
import Persistence
import PlayerKit
import PlayerKitTestSupport
import StremioKit
import StremioKitTestSupport
import Testing
@testable import Features

/// The player's side of the previous session: it reports where it is for the snapshot to follow, and takes a saved one back over.
@MainActor
@Suite struct PlayerSnapshotTests {
    private let request = StreamRequest(type: "movie", id: "tt1", title: "Movie")
    private let audio = [MediaTrack(id: "a1", title: "English", language: "eng"), MediaTrack(id: "a2", title: "French", language: "fre")]
    private let subtitles = [MediaTrack(id: "s1", title: "English", language: "eng"), MediaTrack(id: "s2", title: "Spanish", language: "spa")]

    @MainActor
    private final class Engines {
        var made: [MockEngine] = []
        private let make: () -> MockEngine
        init(_ make: @escaping () -> MockEngine) { self.make = make }
        func engine(_ candidate: PlaybackCandidate) -> (any PlaybackEngine)? {
            let engine = make()
            made.append(engine)
            return engine
        }
    }

    private func services(engines: Engines) async throws -> AppServices {
        let transport = StubTransport { request, _ in StubTransport.response(Data("{}".utf8), for: request) }
        let (registry, client) = try await makeStubbedRegistry(manifests: [], transport: transport)
        return AppServices(registry: registry, client: client, settings: InMemorySettingsStore(PlaybackSettings(subtitleLanguage: nil)),
                           makeEngine: { engines.engine($0) })
    }

    /// A stream the way a plan carries it, whose id is the deduplication key with its token still on it.
    private func candidate() -> PlaybackCandidate {
        PlaybackCandidate(id: "url:https://e.example.com/f.mkv?token=SECRET", title: "4K REMUX", addonName: "Addon",
                          route: .native(URL(string: "https://e.example.com/f.mkv?token=SECRET")!),
                          filename: "Movie.2020.2160p.REMUX.mkv", videoSize: 8_800_000_000)
    }

    private func player(engines: Engines, store: (any PlaybackSnapshotStore)? = nil) async throws -> PlayerViewModel {
        PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate()]),
                       services: try await services(engines: engines), snapshotStore: store ?? InMemoryPlaybackSnapshotStore())
    }

    @Test func thePlayerReportsItsStateForTheSnapshotToFollow() async throws {
        let engines = Engines { MockEngine(.plays(duration: 100), audio: audio, subtitles: subtitles) }
        let model = try await player(engines: engines)
        await model.start()
        model.selectAudioTrack(id: "a2")
        await model.selectSubtitle(.embedded("s2"))
        try await waitUntil { model.selectedAudioTrackID == "a2" && model.subtitleChoice == .embedded("s2") }
        let engine = try #require(engines.made.last)
        engine.simulate(position: 37)
        try await waitUntil { model.position == 37 }
        let state = model.saveState
        #expect(state.position == 37)
        #expect(state.duration == 100)
        #expect(state.isPaused == false)
        #expect(state.audioTrack == SnapshotTrack(title: "French", language: "fre", isExternal: false))
        #expect(state.subtitleTrack == SnapshotTrack(title: "Spanish", language: "spa", isExternal: false))
        #expect(state.subtitlesOff == false)
        await model.close()
    }

    @Test func aRestoredSessionResumesAtItsOwnPlaceWithItsOwnChoices() async throws {
        let engines = Engines { MockEngine(.plays(duration: 100), audio: audio, subtitles: subtitles) }
        let layout = VideoLayout(fit: .fill, crop: VideoCrop.precise(2.39))
        let processing = VideoProcessing(toneMapping: .hable)
        let snapshot = PlaybackSnapshot(request: request, stream: PlaybackStreamIdentity(kind: .direct), position: 42,
                                        duration: 100, wasPaused: true,
                                        audioTrack: SnapshotTrack(title: "French", language: "fre"),
                                        subtitleTrack: SnapshotTrack(title: "Spanish", language: "spa"),
                                        layout: layout, processing: processing)
        let model = try await player(engines: engines)
        model.resumePlayback(from: snapshot)
        await model.start()
        let engine = try #require(engines.made.last)
        #expect(engine.loadedItems.first?.startPosition == 42, "the session's place, not the start")
        #expect(engine.layouts.first == VideoLayout(), "the picture is the saved Zoom Mode and the title's Aspect Ratio, as in Infuse")
        #expect(engine.processings.contains(processing))
        try await waitUntil { model.selectedAudioTrackID == "a2" }
        try await waitUntil { model.subtitleChoice == .embedded("s2") }
        #expect(!model.isPlaying, "a session left paused stays paused")
        await model.close()
    }

    @Test func restoringALiveSessionUsesTheSamePictureAsRestoringBeforeStart() async throws {
        let engines = Engines { MockEngine(.plays(duration: 100)) }
        let model = try await player(engines: engines)
        await model.start()
        model.setZoomMode(.stretch)
        model.setAspectRatio(.widescreenB)
        let snapshot = PlaybackSnapshot(request: request, stream: PlaybackStreamIdentity(kind: .direct), position: 42,
                                        layout: VideoLayout(fit: .fill, zoom: 3, crop: .ratio239))
        model.resumePlayback(from: snapshot)
        #expect(model.zoomMode == .stretch && model.aspectRatio == .widescreenB)
        #expect(model.videoLayout == VideoLayout(fit: .stretch, crop: .ratio2x1))
        model.setSafeAreaInset(59)
        #expect(model.videoLayout == VideoLayout(fit: .stretch, crop: .ratio2x1))
        await model.close()
    }

    @Test func aSessionAtItsStartResumesFromProgressAndPlays() async throws {
        let engines = Engines { MockEngine(.plays(duration: 100)) }
        let snapshot = PlaybackSnapshot(request: request, stream: PlaybackStreamIdentity(kind: .direct), position: 0)
        let model = try await player(engines: engines)
        model.resumePlayback(from: snapshot)
        await model.start()
        try await waitUntil { model.isPlaying }
        await model.close()
    }

    @Test func theSnapshotFollowsOnlyTheSessionOwnRequest() async throws {
        let engines = Engines { MockEngine(.plays(duration: 100)) }
        let other = PlaybackSnapshot(request: StreamRequest(type: "movie", id: "tt2", title: "Other"),
                                     stream: PlaybackStreamIdentity(kind: .direct), position: 500)
        let store = InMemoryPlaybackSnapshotStore(other)
        let model = try await player(engines: engines, store: store)
        await model.start()
        try await waitUntil { engines.made.last?.state.duration == 100 }
        #expect(try #require(await store.load()).position == 500, "another title's session is left alone")

        var own = other
        own.request = request
        try await store.save(own)
        let engine = try #require(engines.made.last)
        engine.simulate(position: 64)
        await model.recordSessionSnapshot(force: true)
        #expect(try #require(await store.load()).position == 64, "the session's own player keeps it current")
        await model.close()
    }

    @Test func aHandOverSavesTheNextEpisodesOwnStreamWithoutItsToken() async throws {
        let engines = Engines { MockEngine(.plays(duration: 100)) }
        let store = InMemoryPlaybackSnapshotStore()
        let model = try await player(engines: engines, store: store)
        await model.start()
        let nextRequest = StreamRequest(type: "series", id: "tt1:1:2", title: "Show · Two", season: 1, episode: 2)
        let next = PlaybackPlan(request: nextRequest, candidates: [candidate()])
        await model.saveSessionSnapshot(for: next)
        let saved = try #require(await store.load())
        #expect(saved.request.identity == nextRequest.identity)
        #expect(saved.stream.kind == .direct)
        #expect(saved.stream.urlPath == "https://e.example.com/f.mkv", "the token never reaches the file")
        #expect(saved.stream.filename == "Movie.2020.2160p.REMUX.mkv" && saved.stream.videoSize == 8_800_000_000)
        #expect(saved.position == 0 && saved.wasPaused == false)
        await model.close()
    }
}
