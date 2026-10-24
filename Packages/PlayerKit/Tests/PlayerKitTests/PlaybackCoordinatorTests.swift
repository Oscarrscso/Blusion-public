import Foundation
import Testing
import StremioKit
import PlayerKitTestSupport
@testable import PlayerKit

@MainActor
@Suite struct PlaybackCoordinatorTests {
    private let request = StreamRequest(type: "movie", id: "tt1", title: "Movie")
    private let boom = PlaybackFailure(.network, "boom")

    private func candidate(_ name: String, route: Bool = true) -> PlaybackCandidate {
        let url = URL(string: "https://e.example.com/\(name).mp4")!
        return PlaybackCandidate(id: name, title: name, addonName: "A", route: route ? .native(url) : .external(url),
            headers: name == "protected" ? ["X-Token": "abc"] : [:])
    }

    private func plan(_ names: [String]) -> PlaybackPlan { PlaybackPlan(request: request, candidates: names.map { candidate($0) }) }

    private func plan(_ names: [String], retriesInFallbackEngine: Bool, retriesInBackupEngine: Bool = false) -> PlaybackPlan {
        PlaybackPlan(request: request, candidates: names.map { candidate($0) }, retriesInFallbackEngine: retriesInFallbackEngine,
                     retriesInBackupEngine: retriesInBackupEngine)
    }

    private func mkvURL(_ name: String) -> URL { URL(string: "https://e.example.com/\(name).mkv")! }

    /// A stream on a fallback engine route (MKV here, which AVPlayer cannot open).
    private func fallbackCandidate(_ name: String, reason: FallbackReason = .container(.matroska)) -> PlaybackCandidate {
        PlaybackCandidate(id: name, title: name, addonName: "A", route: .fallback(mkvURL(name), reason))
    }

    private func fallbackPlan(_ names: [String], retriesInBackupEngine: Bool) -> PlaybackPlan {
        PlaybackPlan(request: request, candidates: names.map { fallbackCandidate($0) }, retriesInFallbackEngine: true,
                     retriesInBackupEngine: retriesInBackupEngine)
    }

    private func isNative(_ route: PlaybackRoute) -> Bool {
        if case .native = route { return true }
        return false
    }

    /// Engines are created per candidate from `script`; the coordinator under test gets them through `makeEngine`.
    private final class Rig {
        var engines: [String: MockEngine] = [:]
        var script: [String: MockEngine.Outcome]
        init(_ script: [String: MockEngine.Outcome]) { self.script = script }
        @MainActor func make(_ candidate: PlaybackCandidate) -> (any PlaybackEngine)? {
            guard let outcome = script[candidate.id] else { return nil }
            let engine = MockEngine(outcome)
            engines[candidate.id] = engine
            return engine
        }
    }

    private func coordinator(_ names: [String], _ script: [String: MockEngine.Outcome], resume: TimeInterval = 0, timeout: Duration = .seconds(2),
                             progress: ProgressSession? = nil) -> (PlaybackCoordinator, Rig) {
        let rig = Rig(script)
        return (PlaybackCoordinator(plan: plan(names), resumeFrom: resume, startupTimeout: timeout, progress: progress, makeEngine: { rig.make($0) }), rig)
    }

    @Test func playsTheFirstCandidateWhenItWorks() async {
        let (coordinator, rig) = coordinator(["a", "b"], ["a": .plays(duration: 100), "b": .plays(duration: 100)])
        await coordinator.start()
        #expect(coordinator.phase == .playing)
        #expect(coordinator.current?.id == "a")
        #expect(coordinator.state.isPlaying)
        #expect(coordinator.failedAttempts.isEmpty && coordinator.notice == nil)
        #expect(rig.engines["b"] == nil, "later candidates are never created unless needed")
        #expect(rig.engines["a"]?.loadedItems.first?.url.lastPathComponent == "a.mp4")
        #expect(rig.engines["a"]?.playCalls == 1)
    }

    @Test func movesToTheNextCandidateWhenOneFailsToLoad() async {
        let (coordinator, rig) = coordinator(["a", "b", "c"], ["a": .failsToLoad(boom), "b": .plays(duration: 50), "c": .plays(duration: 50)])
        await coordinator.start()
        #expect(coordinator.phase == .playing)
        #expect(coordinator.current?.id == "b")
        #expect(coordinator.candidateIndex == 1)
        #expect(coordinator.failedAttempts.map(\.id) == ["a"])
        #expect(coordinator.failedAttempts.first?.failure == boom)
        #expect(coordinator.notice?.contains("“a” didn't work") == true && coordinator.notice?.contains("“b”") == true)
        #expect(rig.engines["a"]?.isStopped == true, "the failed engine is released")
        #expect(rig.engines["c"] == nil)
    }

    /// Decides each engine from the candidate it is made for (id and route), and keeps what it was asked for and what it made.
    @MainActor private final class RouteRig {
        var made: [PlaybackCandidate] = []
        var engines: [MockEngine] = []
        let outcome: (PlaybackCandidate) -> MockEngine.Outcome?
        init(_ outcome: @escaping (PlaybackCandidate) -> MockEngine.Outcome?) { self.outcome = outcome }
        func make(_ candidate: PlaybackCandidate) -> (any PlaybackEngine)? {
            made.append(candidate)
            guard let scripted = outcome(candidate) else { return nil }
            let engine = MockEngine(scripted)
            engines.append(engine)
            return engine
        }
    }

    @Test func aStreamAVPlayerCannotOpenIsRetriedOnceInTheFallbackEngineFromTheSamePosition() async {
        let rig = RouteRig { candidate in
            if case .native = candidate.route { return .failsToLoad(PlaybackFailure(.format, "no decoder")) }
            return .plays(duration: 100)
        }
        let coordinator = PlaybackCoordinator(plan: plan(["a", "b"], retriesInFallbackEngine: true), resumeFrom: 42,
                                              startupTimeout: .seconds(2), makeEngine: { rig.make($0) })
        await coordinator.start()
        let url = URL(string: "https://e.example.com/a.mp4")!
        #expect(coordinator.phase == .playing && coordinator.candidateIndex == 0)
        #expect(coordinator.current?.route == .fallback(url, .unknownFormat))
        #expect(rig.made.map(\.id) == ["a", "a"], "AVPlayer, then the fallback engine for the same stream; the next stream is not tried")
        #expect(rig.engines.last?.loadedItems.first?.startPosition == 42, "the retry resumes where the viewer was")
        #expect(coordinator.failedAttempts.isEmpty && coordinator.notice == nil, "a retry that plays is not a failure")
        await coordinator.stop()
    }

    @Test func aFormatFailureIsNotRetriedWhenTheFallbackEngineIsOffInSettings() async {
        let rig = RouteRig { candidate in
            if case .fallback = candidate.route { return .plays(duration: 100) }   // linked, but Settings has it off
            return candidate.id == "a" ? .failsToLoad(PlaybackFailure(.format, "no decoder")) : .plays(duration: 50)
        }
        let coordinator = PlaybackCoordinator(plan: plan(["a", "b"], retriesInFallbackEngine: false), startupTimeout: .seconds(2),
                                              makeEngine: { rig.make($0) })
        await coordinator.start()
        #expect(coordinator.current?.id == "b" && coordinator.phase == .playing)
        #expect(rig.made.map(\.id) == ["a", "b"] && rig.made.map(\.route).allSatisfy(isNative), "no engine is asked for the fallback")
        #expect(coordinator.failedAttempts.map(\.failure.kind) == [.format])
        await coordinator.stop()
    }

    @Test func aStreamThatFailsInTheFallbackEngineTooIsRecordedOnceAndTheNextStreamPlays() async {
        let rig = RouteRig { candidate in
            candidate.id == "a" ? .failsToLoad(PlaybackFailure(.format, "no decoder")) : .plays(duration: 50)   // both routes fail for a
        }
        let coordinator = PlaybackCoordinator(plan: plan(["a", "b"], retriesInFallbackEngine: true), startupTimeout: .seconds(2),
                                              makeEngine: { rig.make($0) })
        await coordinator.start()
        #expect(coordinator.current?.id == "b" && coordinator.phase == .playing)
        #expect(rig.made.map(\.id) == ["a", "a", "b"], "AVPlayer, the fallback engine once, then the next stream")
        #expect(coordinator.failedAttempts.map(\.id) == ["a"] && coordinator.failedAttempts.map(\.failure.kind) == [.format])
        await coordinator.stop()
    }

    @Test func aRetryThatCannotBeMadeReportsTheFailureAVPlayerGaveAndPlaysTheNextStream() async {
        let rig = RouteRig { candidate in
            if case .fallback = candidate.route { return nil }   // the plan allows a retry, but no engine can be made for it
            return candidate.id == "a" ? .failsToLoad(PlaybackFailure(.format, "no decoder")) : .plays(duration: 50)
        }
        let coordinator = PlaybackCoordinator(plan: plan(["a", "b"], retriesInFallbackEngine: true), startupTimeout: .seconds(2),
                                              makeEngine: { rig.make($0) })
        await coordinator.start()
        #expect(coordinator.current?.id == "b" && coordinator.phase == .playing)
        #expect(rig.made.map(\.id) == ["a", "a", "b"], "AVPlayer, the retry that could not be made, then the next stream")
        #expect(coordinator.failedAttempts.map(\.id) == ["a"] && coordinator.failedAttempts.map(\.failure.kind) == [.format], "recorded once")
        await coordinator.stop()
    }

    @Test func withoutAFallbackEngineAFormatFailureIsReportedAndTheNextStreamPlays() async {
        let rig = RouteRig { candidate in
            if case .fallback = candidate.route { return nil }   // no fallback engine linked
            return candidate.id == "a" ? .failsToLoad(PlaybackFailure(.format, "no decoder")) : .plays(duration: 50)
        }
        let coordinator = PlaybackCoordinator(plan: plan(["a", "b"]), startupTimeout: .seconds(2), makeEngine: { rig.make($0) })
        await coordinator.start()
        #expect(coordinator.current?.id == "b" && coordinator.phase == .playing)
        #expect(coordinator.failedAttempts.map(\.failure.kind) == [.format], "the failure AVPlayer gave is reported, as before")
        #expect(coordinator.notice?.contains("“a” didn't work") == true)
        await coordinator.stop()
    }

    @Test func aNetworkFailureIsNotRetriedInTheFallbackEngine() async {
        let rig = RouteRig { candidate in
            if case .fallback = candidate.route { return .plays(duration: 100) }
            return candidate.id == "a" ? .failsToLoad(boom) : .plays(duration: 50)
        }
        let coordinator = PlaybackCoordinator(plan: plan(["a", "b"], retriesInFallbackEngine: true), startupTimeout: .seconds(2),
                                              makeEngine: { rig.make($0) })
        await coordinator.start()
        #expect(coordinator.current?.id == "b" && coordinator.failedAttempts.map(\.failure) == [boom])
        #expect(rig.made.count == 2, "a then b, both through AVPlayer")
        await coordinator.stop()
    }

    @Test func aFallbackEngineFormatFailureIsRetriedOnceInTheFullFeaturedEngineFromTheSamePosition() async {
        let url = mkvURL("a")
        let rig = RouteRig { candidate in
            candidate.route == .fallback(url, .container(.matroska)) ? .failsToLoad(PlaybackFailure(.format, "no decoder")) : .plays(duration: 100)
        }
        let coordinator = PlaybackCoordinator(plan: fallbackPlan(["a", "b"], retriesInBackupEngine: true), resumeFrom: 42,
                                              startupTimeout: .seconds(2), makeEngine: { rig.make($0) })
        await coordinator.start()
        #expect(coordinator.phase == .playing && coordinator.candidateIndex == 0)
        #expect(coordinator.current?.route == .fallback(url, .fullFeaturedEngine))
        #expect(rig.made.map(\.route) == [.fallback(url, .container(.matroska)), .fallback(url, .fullFeaturedEngine)])
        #expect(rig.engines.last?.loadedItems.first?.startPosition == 42, "the retry resumes where the viewer was")
        #expect(coordinator.failedAttempts.isEmpty && coordinator.notice == nil, "a retry that plays is not a failure")
        await coordinator.stop()
    }

    @Test func aFallbackEngineFormatFailureIsNotRetriedInTheBackupWhenThePlanHasNoBackupEngine() async {
        let url = mkvURL("a")
        let rig = RouteRig { candidate in
            candidate.route == .fallback(url, .container(.matroska)) ? .failsToLoad(PlaybackFailure(.format, "no decoder")) : .plays(duration: 50)
        }
        let coordinator = PlaybackCoordinator(plan: fallbackPlan(["a", "b"], retriesInBackupEngine: false), startupTimeout: .seconds(2),
                                              makeEngine: { rig.make($0) })
        await coordinator.start()
        #expect(coordinator.current?.id == "b" && coordinator.phase == .playing)
        #expect(rig.made.map(\.route) == [.fallback(url, .container(.matroska)), .fallback(mkvURL("b"), .container(.matroska))])
        #expect(coordinator.failedAttempts.map(\.id) == ["a"] && coordinator.failedAttempts.map(\.failure.kind) == [.format], "recorded once")
        await coordinator.stop()
    }

    @Test func aFallbackEngineFailureThatAnotherEngineWouldRepeatIsNotRetriedInTheBackup() async {
        for kind in [PlaybackFailure.Kind.unauthorized, .notFound, .network] {
            let failure = PlaybackFailure(kind, "refused")
            let url = mkvURL("a")
            let rig = RouteRig { candidate in
                candidate.route == .fallback(url, .container(.matroska)) ? .failsToLoad(failure) : .plays(duration: 50)
            }
            let coordinator = PlaybackCoordinator(plan: fallbackPlan(["a", "b"], retriesInBackupEngine: true), startupTimeout: .seconds(2),
                                                  makeEngine: { rig.make($0) })
            await coordinator.start()
            #expect(coordinator.current?.id == "b" && coordinator.phase == .playing, "\(kind)")
            #expect(rig.made.map(\.id) == ["a", "b"], "\(kind): a then b, the backup is not tried")
            #expect(coordinator.failedAttempts.map(\.failure) == [failure], "\(kind)")
            await coordinator.stop()
        }
    }

    @Test func aStreamThatFailsInTheFullFeaturedEngineIsNotRetriedAgain() async {
        let rig = RouteRig { candidate in candidate.id == "a" ? .failsToLoad(PlaybackFailure(.format, "no decoder")) : .plays(duration: 50) }
        let plan = PlaybackPlan(request: request, candidates: [fallbackCandidate("a", reason: .fullFeaturedEngine), fallbackCandidate("b")],
                                retriesInFallbackEngine: true, retriesInBackupEngine: true)
        let coordinator = PlaybackCoordinator(plan: plan, startupTimeout: .seconds(2), makeEngine: { rig.make($0) })
        await coordinator.start()
        #expect(coordinator.current?.id == "b" && coordinator.phase == .playing)
        #expect(rig.made.map(\.id) == ["a", "b"], "the full-featured engine is the last try for a")
        #expect(coordinator.failedAttempts.map(\.id) == ["a"] && coordinator.failedAttempts.map(\.failure.kind) == [.format])
        await coordinator.stop()
    }

    @Test func aStreamAVPlayerAndTheFirstFallbackEngineCannotOpenIsPlayedInTheFullFeaturedEngine() async {
        let native = URL(string: "https://e.example.com/a.mp4")!
        let rig = RouteRig { candidate in
            candidate.id == "a" && candidate.route != .fallback(native, .fullFeaturedEngine)
                ? .failsToLoad(PlaybackFailure(.format, "no decoder")) : .plays(duration: 100)
        }
        let coordinator = PlaybackCoordinator(plan: plan(["a", "b"], retriesInFallbackEngine: true, retriesInBackupEngine: true), resumeFrom: 42,
                                              startupTimeout: .seconds(2), makeEngine: { rig.make($0) })
        await coordinator.start()
        #expect(coordinator.phase == .playing && coordinator.current?.route == .fallback(native, .fullFeaturedEngine))
        #expect(coordinator.candidateIndex == 0, "the same stream: the next stream is not tried")
        #expect(rig.made.map(\.route) == [.native(native), .fallback(native, .unknownFormat), .fallback(native, .fullFeaturedEngine)])
        #expect(rig.engines.last?.loadedItems.first?.startPosition == 42)
        #expect(coordinator.failedAttempts.isEmpty && coordinator.notice == nil, "only the engine that plays counts")
        await coordinator.stop()
    }

    @Test func aFirstFallbackEngineThatCannotBeMadeHandsTheStreamToTheFullFeaturedEngine() async {
        let url = mkvURL("a")
        let rig = RouteRig { candidate in candidate.route == .fallback(url, .container(.matroska)) ? nil : .plays(duration: 50) }
        let coordinator = PlaybackCoordinator(plan: fallbackPlan(["a", "b"], retriesInBackupEngine: true), startupTimeout: .seconds(2),
                                              makeEngine: { rig.make($0) })
        await coordinator.start()
        #expect(coordinator.phase == .playing && coordinator.candidateIndex == 0)
        #expect(coordinator.current?.route == .fallback(url, .fullFeaturedEngine))
        #expect(rig.made.map(\.route) == [.fallback(url, .container(.matroska)), .fallback(url, .fullFeaturedEngine)])
        #expect(coordinator.failedAttempts.isEmpty)
        await coordinator.stop()
    }

    @Test func whenNoEngineCanBeMadeTheFailureIsRecordedOnceAndTheNextStreamPlays() async {
        for backup in [true, false] {
            let rig = RouteRig { candidate in candidate.id == "a" ? nil : .plays(duration: 50) }   // no engine for "a" on any route
            let coordinator = PlaybackCoordinator(plan: fallbackPlan(["a", "b"], retriesInBackupEngine: backup), startupTimeout: .seconds(2),
                                                  makeEngine: { rig.make($0) })
            await coordinator.start()
            #expect(coordinator.current?.id == "b" && coordinator.phase == .playing, "backup \(backup)")
            #expect(rig.made.map(\.id) == (backup ? ["a", "a", "b"] : ["a", "b"]), "backup \(backup)")
            #expect(coordinator.failedAttempts.map(\.id) == ["a"] && coordinator.failedAttempts.map(\.failure.kind) == [.noEngine],
                    "backup \(backup)")
            await coordinator.stop()
        }
    }

    @Test func aStreamThatNeverStartsTimesOut() async {
        let (coordinator, _) = coordinator(["a", "b"], ["a": .hangs, "b": .plays(duration: 50)], timeout: .milliseconds(60))
        await coordinator.start()
        #expect(coordinator.phase == .playing && coordinator.current?.id == "b")
        #expect(coordinator.failedAttempts.map(\.failure.kind) == [.timeout])
    }

    @Test func bufferingAloneDoesNotCancelTheStartupDeadline() async throws {
        let (coordinator, rig) = coordinator(["a", "b"], ["a": .hangs, "b": .plays(duration: 50)], timeout: .milliseconds(100))
        let starting = Task { await coordinator.start() }
        try await waitUntil { rig.engines["a"] != nil }
        rig.engines["a"]?.simulateBuffering()
        await starting.value
        #expect(coordinator.current?.id == "b" && coordinator.phase == .playing)
        #expect(coordinator.failedAttempts.map(\.failure.kind) == [.timeout])
        await coordinator.stop()
    }

    @Test func sustainedBufferingFailsOverButPausingDoesNot() async throws {
        let rig = Rig(["a": .plays(duration: 100), "b": .plays(duration: 100)])
        let coordinator = PlaybackCoordinator(plan: plan(["a", "b"]), stallTimeout: .milliseconds(100), makeEngine: { rig.make($0) })
        await coordinator.start()
        coordinator.pause()
        try await waitUntil { coordinator.state.status == .paused }
        try await Task.sleep(for: .milliseconds(150))
        #expect(coordinator.current?.id == "a" && coordinator.failedAttempts.isEmpty)
        coordinator.play()
        let first = rig.engines["a"]
        first?.simulate(position: 37)
        first?.simulateBuffering()
        // The first stall reloads the same stream where it stopped; a second one moves on.
        try await waitUntil { rig.engines["a"] !== first && coordinator.phase == .playing }
        #expect(rig.engines["a"]?.loadedItems.first?.startPosition == 37)
        #expect(coordinator.failedAttempts.isEmpty)
        rig.engines["a"]?.simulateBuffering()
        try await waitUntil { coordinator.current?.id == "b" && coordinator.phase == .playing }
        #expect(rig.engines["b"]?.loadedItems.first?.startPosition == 37)
        #expect(coordinator.failedAttempts.map(\.id) == ["a"])
        await coordinator.stop()
    }

    @Test func candidatesWithoutAnEngineAreSkipped() async {
        let (coordinator, _) = coordinator(["a", "b"], ["b": .plays(duration: 10)])   // no script entry for "a" => makeEngine returns nil
        await coordinator.start()
        #expect(coordinator.current?.id == "b")
        #expect(coordinator.failedAttempts.map(\.failure.kind) == [.noEngine])
    }

    @Test func everyCandidateFailingEndsExhausted() async {
        let (coordinator, _) = coordinator(["a", "b"], ["a": .failsToLoad(boom), "b": .hangs], timeout: .milliseconds(40))
        await coordinator.start()
        #expect(coordinator.phase == .exhausted)
        #expect(coordinator.failedAttempts.map(\.id) == ["a", "b"])
        #expect(coordinator.notice == "None of the streams could be played.")
    }

    @Test func anEmptyPlanSaysSo() async {
        let (coordinator, _) = coordinator([], [:])
        await coordinator.start()
        #expect(coordinator.phase == .exhausted)
        #expect(coordinator.notice == "There is nothing to play.")
    }

    @Test func resumePositionReachesTheEngineAndSurvivesFailover() async {
        let (coordinator, rig) = coordinator(["a", "b"], ["a": .failsToLoad(boom), "b": .plays(duration: 100)], resume: 42)
        await coordinator.start()
        #expect(rig.engines["a"]?.loadedItems.first?.startPosition == 42)
        #expect(rig.engines["b"]?.loadedItems.first?.startPosition == 42)
    }

    @Test func headersTravelWithTheItem() async {
        let (coordinator, rig) = coordinator(["protected"], ["protected": .plays(duration: 10)])
        await coordinator.start()
        #expect(rig.engines["protected"]?.loadedItems.first?.headers == ["X-Token": "abc"])
    }

    @Test func aMidStreamFailureContinuesOnTheNextStreamFromTheSamePosition() async throws {
        let (coordinator, rig) = coordinator(["a", "b"], ["a": .plays(duration: 100), "b": .plays(duration: 100)])
        await coordinator.start()
        rig.engines["a"]?.simulate(position: 37)
        try await waitUntil { coordinator.state.position == 37 }
        let first = rig.engines["a"]
        first?.simulateFailure(PlaybackFailure(.network, "connection lost"))
        // Once in place, as a dropped connection often comes back.
        try await waitUntil { rig.engines["a"] !== first && coordinator.phase == .playing && coordinator.state.isPlaying }
        #expect(rig.engines["a"]?.loadedItems.first?.startPosition == 37)
        #expect(coordinator.current?.id == "a" && coordinator.failedAttempts.isEmpty)
        rig.engines["a"]?.simulateFailure(PlaybackFailure(.network, "connection lost"))
        try await waitUntil { coordinator.current?.id == "b" && coordinator.phase == .playing }
        #expect(rig.engines["b"]?.loadedItems.first?.startPosition == 37)
        #expect(coordinator.failedAttempts.map(\.id) == ["a"])
    }

    @Test func aMidStreamFailureOnTheLastStreamIsFinal() async throws {
        let (coordinator, rig) = coordinator(["a"], ["a": .plays(duration: 100)])
        await coordinator.start()
        let first = rig.engines["a"]
        first?.simulateFailure(boom)
        try await waitUntil { rig.engines["a"] !== first && coordinator.state.isPlaying }
        rig.engines["a"]?.simulateFailure(boom)
        try await waitUntil { coordinator.phase == .exhausted }
        #expect(coordinator.state.failure == boom)
    }

    @Test func manualNextStreamResumesAtTheCurrentPosition() async throws {
        let (coordinator, rig) = coordinator(["a", "b"], ["a": .plays(duration: 100), "b": .plays(duration: 100)])
        await coordinator.start()
        rig.engines["a"]?.simulate(position: 12)
        try await waitUntil { coordinator.state.position == 12 }
        await coordinator.advance()
        #expect(coordinator.current?.id == "b" && coordinator.phase == .playing)
        #expect(rig.engines["b"]?.loadedItems.first?.startPosition == 12)
        await coordinator.advance()
        #expect(coordinator.current?.id == "b" && coordinator.phase == .playing, "no further stream: keep playing")
        #expect(coordinator.notice == "There are no other streams to try.")
    }

    @Test func transportCommandsReachTheEngine() async throws {
        let (coordinator, rig) = coordinator(["a"], ["a": .plays(duration: 100)])
        await coordinator.start()
        let engine = try #require(rig.engines["a"])
        coordinator.pause()
        try await waitUntil { coordinator.state.status == .paused }
        coordinator.togglePlayPause()
        try await waitUntil { coordinator.state.isPlaying }
        await coordinator.seek(to: 30)
        await coordinator.seek(to: -5)
        #expect(engine.seeks == [30, 0], "negative seeks clamp to zero")
        engine.simulate(position: 50)
        try await waitUntil { coordinator.state.position == 50 }
        await coordinator.skip(by: 10)
        await coordinator.skip(by: -100)
        await coordinator.skip(by: 1000)
        #expect(engine.seeks.suffix(3) == [60, 0, 99], "skips stay inside the media")
        coordinator.setRate(1.5)
        coordinator.selectAudioTrack(id: "a2")
        coordinator.selectEmbeddedSubtitleTrack(id: "s1")
        #expect(engine.rates == [1.5] && engine.selectedAudio == ["a2"] && engine.selectedEmbeddedSubtitles == ["s1"])
    }

    @Test func volumeAndMuteCarryOverToTheNextEngine() async {
        let (coordinator, rig) = coordinator(["a", "b"], ["a": .failsToLoad(boom), "b": .plays(duration: 50)])
        coordinator.setVolume(0.3)
        coordinator.setMuted(true)
        await coordinator.start()
        #expect(coordinator.current?.id == "b")
        #expect(rig.engines["a"]?.volumes == [0.3] && rig.engines["a"]?.mutes == [true])
        #expect(rig.engines["b"]?.volumes == [0.3] && rig.engines["b"]?.mutes == [true])
        #expect(coordinator.volume == 0.3 && coordinator.isMuted)
    }

    @Test func anEngineKeepsItsOwnMuteUntilTheListenerChoosesOne() async {
        let (coordinator, rig) = coordinator(["a"], ["a": .plays(duration: 100)])
        await coordinator.start()
        #expect(rig.engines["a"]?.volumes == [] && rig.engines["a"]?.mutes == [], "a snapshot run's silent engine is not unmuted")
    }

    @Test func tracksAreVisibleThroughTheCoordinatorState() async throws {
        let (coordinator, rig) = coordinator(["a"], ["a": .plays(duration: 100)])
        await coordinator.start()
        rig.engines["a"]?.simulate(tracks: [MediaTrack(id: "a1", title: "English", language: "eng", isDefault: true)],
            subtitles: [MediaTrack(id: "s1", title: "French", language: "fre")])
        try await waitUntil { !coordinator.state.audioTracks.isEmpty }
        #expect(coordinator.state.audioTracks.first?.language == "eng")
        #expect(coordinator.state.embeddedSubtitleTracks.map(\.id) == ["s1"])
    }

    @Test func reachingTheEndFinishesAndNotifies() async throws {
        let (coordinator, rig) = coordinator(["a"], ["a": .plays(duration: 100)])
        var ended = false
        coordinator.onEnded = { ended = true }
        await coordinator.start()
        rig.engines["a"]?.simulate(position: 100)
        rig.engines["a"]?.simulateEnd()
        try await waitUntil { ended }
        #expect(coordinator.phase == .finished)
    }

    @Test func stoppingReleasesTheEngineAndFinishes() async {
        let (coordinator, rig) = coordinator(["a"], ["a": .plays(duration: 100)])
        await coordinator.start()
        await coordinator.stop()
        #expect(rig.engines["a"]?.isStopped == true)
        #expect(coordinator.phase == .finished)
        await coordinator.start()   // restarting a stopped coordinator does nothing
        #expect(coordinator.phase == .finished)
    }

    @Test func stoppingDuringStartupDoesNotStartLaterCandidates() async throws {
        let (coordinator, rig) = coordinator(["a", "b"], ["a": .hangs, "b": .plays(duration: 10)], timeout: .seconds(5))
        let starting = Task { await coordinator.start() }
        try await Task.sleep(for: .milliseconds(50))
        await coordinator.stop()
        await starting.value
        #expect(rig.engines["b"] == nil)
        #expect(coordinator.phase == .finished)
    }

    @Test func progressIsRecordedWhilePlayingAndFlushedOnStop() async throws {
        let store = InMemoryProgressStore()
        let clock = ClockBox(Date(timeIntervalSince1970: 5_000))
        let session = ProgressSession(request: request, previous: nil, store: store, clock: { clock.now })
        let (coordinator, rig) = coordinator(["a"], ["a": .plays(duration: 200)], progress: session)
        await coordinator.start()
        rig.engines["a"]?.simulate(position: 20)
        try await waitUntil { coordinator.state.position == 20 }
        clock.now = clock.now.addingTimeInterval(12)
        rig.engines["a"]?.simulate(position: 33)
        try await waitUntil { coordinator.state.position == 33 }
        await coordinator.stop()
        let saved = await store.progress(for: "movie/tt1")
        #expect(saved?.position == 33 && saved?.duration == 200)
        #expect(saved?.isWatched == false)
    }
}

/// Polls `condition` on the main actor until it holds or the timeout passes.
@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw WaitTimeout() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

struct WaitTimeout: Error {}
