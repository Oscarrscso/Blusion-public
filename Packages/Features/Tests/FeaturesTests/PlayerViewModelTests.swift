import Foundation
import Testing
import PlayerKit
import PlayerKitTestSupport
import StremioKit
import StremioKitTestSupport
@testable import Features

@MainActor
@Suite struct PlayerViewModelTests {
    private let request = StreamRequest(type: "movie", id: "tt1", title: "Movie")
    private let srt = "1\n00:00:01,000 --> 00:00:03,000\nFirst cue\n\n2\n00:00:04,500 --> 00:00:06,250\nSecond cue\n\n3\n00:00:08,000 --> 00:00:09,500\nThird cue\n"

    @MainActor
    private final class Engines {
        var made: [String: MockEngine] = [:]
        var fallbackMade: [String: MockEngine] = [:]
        let outcomes: [String: MockEngine.Outcome]
        /// The fastest rate each engine plays, by candidate; the mock's generous default otherwise.
        let maximumRates: [String: Float]
        init(_ outcomes: [String: MockEngine.Outcome], maximumRates: [String: Float] = [:]) {
            self.outcomes = outcomes
            self.maximumRates = maximumRates
        }
        func make(_ candidate: PlaybackCandidate) -> (any PlaybackEngine)? {
            guard let outcome = outcomes[candidate.id] else { return nil }
            let engine = MockEngine(outcome)
            if let maximum = maximumRates[candidate.id] { engine.maximumRate = maximum }
            if case .fallback = candidate.route {
                fallbackMade[candidate.id] = engine
            } else {
                made[candidate.id] = engine
            }
            return engine
        }
    }

    private func candidate(_ id: String, subtitles: [SubtitleItem] = [], binge: String? = nil) -> PlaybackCandidate {
        PlaybackCandidate(id: id, title: "Stream \(id)", addonName: "A", route: .native(URL(string: "https://e.example.com/\(id).mp4")!), subtitles: subtitles,
                          bingeContext: binge.map { BingeContext(bingeGroup: $0) })
    }

    private func services(settings: PlaybackSettings = PlaybackSettings(), progress: (any ProgressStore)? = nil, engines: Engines,
                          subtitleBody: String? = nil, streamBodies: [String] = []) async throws -> AppServices {
        let transport = StubTransport { request, _ in
            let host = request.url?.host ?? ""
            if host == "subs.example.com" { return StubTransport.response(Data((subtitleBody ?? "").utf8), for: request) }
            let index = Int(host.dropFirst(4).prefix(while: \.isNumber)) ?? 0
            return StubTransport.response(Data((index < streamBodies.count ? streamBodies[index] : #"{"streams":[]}"#).utf8), for: request)
        }
        let manifests = streamBodies.indices.map { streamManifest("addon\($0)") }
        let (registry, client) = try await makeStubbedRegistry(manifests: manifests, transport: transport)
        return AppServices(registry: registry, client: client, settings: InMemorySettingsStore(settings), progress: progress, makeEngine: { engines.make($0) })
    }

    private let english = SubtitleItem(id: "en", url: URL(string: "https://subs.example.com/en.srt")!, lang: "eng")
    private let french = SubtitleItem(id: "fr", url: URL(string: "https://subs.example.com/fr.srt")!, lang: "fre")

    // MARK: start and resume

    @Test func startsPlaybackAndExposesItsState() async throws {
        let engines = Engines(["a": .plays(duration: 120)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        #expect(model.title == "Movie")
        await model.start()
        #expect(model.isPlaying)
        #expect(model.title == "Stream a")
        #expect(model.duration == 120)
        engines.made["a"]?.simulate(position: 30)
        try await waitUntil { model.position == 30 }
        #expect(model.fraction == 0.25)
        #expect(model.positionText == "0:30" && model.remainingText == "-1:30")
        #expect(model.failureMessage == nil && !model.isBuffering)
        await model.close()
    }

    @Test func theSpinnerShowsOnlyForAStallOnceTheStreamHasStartedAndTheControlsAreHidden() async throws {
        let hanging = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("h")]),
                                      services: try await services(engines: Engines(["h": .hangs])))
        let starting = Task { await hanging.start() }
        try await waitUntil { hanging.coordinator?.phase == .starting }
        #expect(hanging.isBuffering)
        hanging.toggleControls()
        #expect(!hanging.showsBufferingIndicator)
        await hanging.close()
        await starting.value

        let engines = Engines(["a": .plays(duration: 120)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        engines.made["a"]?.simulateBuffering()
        try await waitUntil { model.isBuffering }
        #expect(model.controlsVisible && !model.showsBufferingIndicator)
        model.toggleControls()
        #expect(model.showsBufferingIndicator)
        model.togglePlayPause()
        #expect(!model.isStalled && !model.wantsPlayback, "a deliberate pause must dismiss buffering")
        await model.close()
    }

    @Test func resumesFromSavedProgress() async throws {
        let store = InMemoryProgressStore()
        await store.save(WatchProgress(id: request.identity, type: "movie", contentID: "tt1", title: "Movie",
            position: 75, duration: 120, isWatched: false, updatedAt: Date()))
        let engines = Engines(["a": .plays(duration: 120)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(progress: store, engines: engines))
        await model.start()
        #expect(engines.made["a"]?.loadedItems.first?.startPosition == 75)
        await model.close()
    }

    @Test func aWatchedTitleStartsFromTheBeginning() async throws {
        let store = InMemoryProgressStore()
        await store.save(WatchProgress(id: request.identity, type: "movie", contentID: "tt1", title: "Movie",
            position: 100, duration: 120, isWatched: true, updatedAt: Date()))
        let engines = Engines(["a": .plays(duration: 120)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(progress: store, engines: engines))
        await model.start()
        #expect(engines.made["a"]?.loadedItems.first?.startPosition == 0)
        await model.close()
    }

    @Test func closingSavesProgress() async throws {
        let store = InMemoryProgressStore()
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(progress: store, engines: engines))
        await model.start()
        engines.made["a"]?.simulate(position: 64)
        try await waitUntil { model.position == 64 }
        await model.close()
        let saved = await store.progress(for: request.identity)
        #expect(saved?.position == 64 && saved?.duration == 200 && saved?.title == "Movie")
    }

    // MARK: readied before the screen shows

    @Test func aPreparedPlayerHoldsMutedAndPausedThenPlaysWhenItsScreenStarts() async throws {
        let engines = Engines(["a": .plays(duration: 120)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        #expect(!model.hasStartedPlayback)
        await model.prepare()
        let engine = try #require(engines.made["a"])
        #expect(model.isPrepared && model.hasStartedPlayback)
        #expect(engine.mutes.first == true, "muted before it made a sound")
        #expect(engine.state.status == .paused, "held on its first frame")
        await model.start()
        #expect(engine.state.status == .playing && engine.mutes.last == false)
        #expect(engines.made.count == 1, "the screen does not start it again")
        await model.close()
    }

    @Test func aPreparedPlayerNobodyWatchesSavesNoProgress() async throws {
        let store = InMemoryProgressStore()
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(progress: store, engines: engines))
        await model.prepare()
        engines.made["a"]?.simulate(position: 64)
        try await waitUntil { model.position == 64 }
        await model.close()
        #expect(await store.progress(for: request.identity) == nil)
    }

    @Test func aPreparedPlayerSavesProgressOnceItsScreenStarts() async throws {
        let store = InMemoryProgressStore()
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(progress: store, engines: engines))
        await model.prepare()
        await model.start()
        engines.made["a"]?.simulate(position: 64)
        try await waitUntil { model.position == 64 }
        await model.close()
        #expect(await store.progress(for: request.identity)?.position == 64)
    }

    @Test func closingBeforeAPreparedPlayerHasLoadedMakesNoEngine() async throws {
        let engines = Engines(["a": .plays(duration: 120)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        let preparing = Task { await model.prepare() }
        await model.close()
        await preparing.value
        #expect(engines.made.isEmpty, "closed while it read its settings, so it made no player")
    }

    @Test func failureMessagesExplainWhenNothingPlays() async throws {
        let engines = Engines(["a": .failsToLoad(PlaybackFailure(.network, "Connection refused"))])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        #expect(model.failureMessage == "None of the streams could be played. Connection refused")
    }

    @Test func nextStreamIsOfferedOnlyWhenThereIsAnother() async throws {
        let engines = Engines(["a": .plays(duration: 10), "b": .plays(duration: 10)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a"), candidate("b")]), services: try await services(engines: engines))
        await model.start()
        #expect(model.hasNextStream)
        await model.nextStream()
        #expect(model.title == "Stream b")
        #expect(!model.hasNextStream)
        await model.close()
    }

    // MARK: subtitles

    @Test func theDefaultLanguageIsSelectedAndDrawnAtTheRightTimes() async throws {
        let engines = Engines(["a": .plays(duration: 60)])
        let services = try await services(settings: PlaybackSettings(subtitleLanguage: "en"), engines: engines, subtitleBody: srt)
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a", subtitles: [english, french])], ), services: services)
        await model.start()
        await model.waitForSubtitles()
        #expect(model.subtitleChoice == .external(model.subtitleOptions[0].id), "English matches the preference")
        #expect(model.subtitleOptions.map(\.language) == ["eng", "fre"])
        let engine = try #require(engines.made["a"])
        for (position, expected) in [(0.5, nil), (1.0, "First cue"), (2.9, "First cue"), (3.0, nil),
            (5.0, "Second cue"), (8.2, "Third cue"), (9.6, nil)] as [(Double, String?)] {
            engine.simulate(position: position)
            try await waitUntil { model.state.position == position }
            #expect(model.cueText == expected, "at \(position)s")
        }
        await model.close()
    }

    @Test func noDefaultLanguageMeansSubtitlesStayOff() async throws {
        let engines = Engines(["a": .plays(duration: 60)])
        let model = PlayerViewModel(
            plan: PlaybackPlan(request: request, candidates: [candidate("a", subtitles: [english])]),
            services: try await services(engines: engines, subtitleBody: srt))
        await model.start()
        await model.waitForSubtitles()
        #expect(model.subtitleChoice == .off && model.cueText == nil)
        #expect(model.subtitleOptions.count == 1, "but the choice is there in the menu")
        await model.close()
    }

    @Test func choosingASubtitleManuallyBeatsTheDefaultAndOffSticks() async throws {
        let engines = Engines(["a": .plays(duration: 60)])
        let services = try await services(settings: PlaybackSettings(subtitleLanguage: "eng"), engines: engines, subtitleBody: srt)
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a", subtitles: [english, french])]), services: services)
        await model.start()
        await model.waitForSubtitles()
        let frenchOption = try #require(model.subtitleOptions.first { $0.language == "fre" })
        await model.selectSubtitle(.external(frenchOption.id))
        #expect(model.subtitleChoice == .external(frenchOption.id))
        await model.selectSubtitle(.off)
        #expect(model.subtitleChoice == .off && model.cueText == nil)
        await model.close()
    }

    @Test func offsetMovesTheCuesAndIsClamped() async throws {
        let engines = Engines(["a": .plays(duration: 60)])
        let services = try await services(settings: PlaybackSettings(subtitleLanguage: "eng"), engines: engines, subtitleBody: srt)
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a", subtitles: [english])]), services: services)
        await model.start()
        await model.waitForSubtitles()
        let engine = try #require(engines.made["a"])
        engine.simulate(position: 3.5)
        try await waitUntil { model.state.position == 3.5 }
        #expect(model.cueText == nil)
        model.adjustSubtitleOffset(by: 1.0)
        model.adjustSubtitleOffset(by: 1.0)   // delayed by 2 s: "First cue" now runs 3.0-5.0
        #expect(model.subtitleOffset == 2.0 && model.cueText == "First cue")
        model.adjustSubtitleOffset(by: -0.1)
        #expect(model.subtitleOffset == 1.9)
        model.adjustSubtitleOffset(by: 1000)
        #expect(model.subtitleOffset == 60)
        model.adjustSubtitleOffset(by: -1000)
        #expect(model.subtitleOffset == -60)
        model.resetSubtitleOffset()
        #expect(model.subtitleOffset == 0)
        await model.close()
    }

    @Test func embeddedTracksGoToTheEngineAndReplaceExternalOnes() async throws {
        let engines = Engines(["a": .plays(duration: 60)])
        let services = try await services(settings: PlaybackSettings(subtitleLanguage: "eng"), engines: engines, subtitleBody: srt)
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a", subtitles: [english])]), services: services)
        await model.start()
        await model.waitForSubtitles()
        let engine = try #require(engines.made["a"])
        engine.simulate(tracks: [MediaTrack(id: "a1", title: "English"), MediaTrack(id: "a2", title: "Commentary")], subtitles: [MediaTrack(id: "s1", title: "French")])
        try await waitUntil { !model.audioTracks.isEmpty }
        #expect(model.embeddedSubtitleTracks.map(\.id) == ["s1"])
        await model.selectSubtitle(.embedded("s1"))
        #expect(model.subtitleChoice == .embedded("s1") && model.cueText == nil, "external cues are not drawn over embedded subtitles")
        #expect(engine.selectedEmbeddedSubtitles.last == "s1")
        model.selectAudioTrack(id: "a2")
        #expect(engine.selectedAudio == ["a2"])
        await model.close()
    }

    @Test func aBrokenSubtitleFileIsReportedNotFatal() async throws {
        let engines = Engines(["a": .plays(duration: 60)])
        let services = try await services(settings: PlaybackSettings(subtitleLanguage: "eng"), engines: engines, subtitleBody: "this is not a subtitle file")
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a", subtitles: [english])]), services: services)
        await model.start()
        await model.waitForSubtitles()
        #expect(model.subtitleChoice == .off)
        #expect(model.subtitleStatus == "Couldn't load these subtitles.")
        #expect(model.isPlaying, "playback is unaffected")
        await model.close()
    }

    // MARK: controls

    @Test func controlsHideWhenIdleWhilePlayingButNotWhilePausedOrScrubbing() async throws {
        let clock = ClockBox2(Date(timeIntervalSince1970: 1000))
        let engines = Engines(["a": .plays(duration: 100)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]),
            services: try await services(engines: engines), now: { clock.now })
        await model.start()
        #expect(model.controlsVisible)
        clock.now = clock.now.addingTimeInterval(2)
        model.hideControlsIfIdle()
        #expect(model.controlsVisible, "not idle long enough")
        clock.now = clock.now.addingTimeInterval(1.5)
        model.beginScrub()
        clock.now = clock.now.addingTimeInterval(10)
        model.hideControlsIfIdle()
        #expect(model.controlsVisible, "never while scrubbing")
        await model.endScrub()
        clock.now = clock.now.addingTimeInterval(10)
        model.togglePlayPause()   // pause; shows controls and resets the idle clock
        try await waitUntil { model.state.status == .paused }
        clock.now = clock.now.addingTimeInterval(10)
        model.hideControlsIfIdle()
        #expect(model.controlsVisible, "never while paused")
        model.togglePlayPause()
        try await waitUntil { model.isPlaying }
        clock.now = clock.now.addingTimeInterval(3.1)
        model.hideControlsIfIdle()
        #expect(!model.controlsVisible)
        model.toggleControls()
        #expect(model.controlsVisible)
        model.toggleControls()
        #expect(!model.controlsVisible)
        await model.close()
    }

    /// A stall is still playing to the viewer: the controls go away on their own so the spinner stands alone, the play button offers
    /// Pause, and pressing it pauses.
    @Test func duringAStallTheControlsHideAndThePlayButtonPauses() async throws {
        let clock = ClockBox2(Date(timeIntervalSince1970: 1000))
        let engines = Engines(["a": .plays(duration: 100)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]),
            services: try await services(engines: engines), now: { clock.now })
        await model.start()
        engines.made["a"]?.simulateBuffering()
        try await waitUntil { model.isStalled }
        #expect(model.wantsPlayback && model.controlsVisible && !model.showsBufferingIndicator)
        clock.now = clock.now.addingTimeInterval(3.1)
        model.hideControlsIfIdle()
        #expect(!model.controlsVisible && model.showsBufferingIndicator)
        model.togglePlayPause()
        try await waitUntil { model.state.status == .paused }
        #expect(!model.wantsPlayback && !model.isStalled && model.controlsVisible)
        await model.close()
    }

    @Test func pictureGesturesKeepControlsHiddenUntilTapped() async throws {
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        engines.made["a"]?.simulate(position: 40)
        try await waitUntil { model.position == 40 }
        model.toggleControls()
        #expect(!model.controlsVisible)

        model.beginScrub()
        #expect(!model.controlsVisible)
        model.updateScrub(fraction: 0.5)
        #expect(!model.controlsVisible && model.position == 100)
        await model.endScrub()
        #expect(!model.controlsVisible && engines.made["a"]?.seeks == [100])

        model.pinchZoom(in: true)
        #expect(!model.controlsVisible && model.zoomMode == .fill)
        model.pinchZoom(in: false)
        #expect(!model.controlsVisible && model.zoomMode == .normal)

        model.beginScrub()
        model.updateScrub(fraction: 0.75)
        model.cancelScrub()
        #expect(!model.controlsVisible && engines.made["a"]?.seeks == [100])
        model.toggleControls()
        #expect(model.controlsVisible, "an explicit tap still reveals controls")
        model.beginScrub()
        model.updateScrub(fraction: 0.6)
        #expect(model.controlsVisible, "the visible timeline keeps working")
        model.cancelScrub()
        await model.close()
    }

    @Test func scrubbingSeeksOnReleaseToTheRightPosition() async throws {
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        engines.made["a"]?.simulate(position: 40)
        try await waitUntil { model.position == 40 }
        model.beginScrub()
        #expect(model.position == 40 && model.fraction == 0.2, "touching the timeline must retain the current playhead")
        model.updateScrub(fraction: 0.25)
        #expect(model.isScrubbing && model.position == 50 && model.fraction == 0.25 && model.positionText == "0:50")
        #expect(engines.made["a"]?.seeks.isEmpty == true, "dragging alone does not seek")
        model.updateScrub(fraction: 5)   // clamped
        #expect(model.fraction == 1)
        model.updateScrub(fraction: 0.5)
        await model.endScrub()
        #expect(engines.made["a"]?.seeks == [100])
        #expect(!model.isScrubbing)
        await model.endScrub()   // a second release is a no-op
        #expect(engines.made["a"]?.seeks == [100])
        await model.close()
    }

    @Test func cancellingAScrubSeeksNowhereAndTheTimelineFollowsTheFilmAgain() async throws {
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        engines.made["a"]?.simulate(position: 40)
        try await waitUntil { model.position == 40 }
        model.beginScrub()
        model.updateScrub(fraction: 0.75)
        #expect(model.isScrubbing && model.position == 150)
        model.cancelScrub()   // a sideways swipe that turned out to be a pinch
        #expect(!model.isScrubbing && model.position == 40 && model.fraction == 0.2)
        #expect(engines.made["a"]?.seeks.isEmpty == true, "a cancelled scrub does not seek")
        await model.endScrub()   // a release after the cancel is a no-op
        #expect(engines.made["a"]?.seeks.isEmpty == true)
        await model.close()
    }

    /// AetherEngine left films without a length, and letting go of the timeline then sent the film back to its start.
    @Test func aScrubWithNoLengthKnownSeeksNowhere() async throws {
        let engines = Engines(["a": .plays(duration: 0)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        engines.made["a"]?.simulate(position: 40)
        try await waitUntil { model.position == 40 }
        model.beginScrub()
        model.updateScrub(fraction: 0.5)
        await model.endScrub()
        #expect(engines.made["a"]?.seeks.isEmpty == true, "no length, no time to seek to: never back to the start")
        #expect(!model.isScrubbing && model.position == 40)
        await model.close()
    }

    /// A hold begins at 2×; dragging up steps it to 3× and 4×, dragging back steps it down, and letting go returns the film to the speed it
    /// was at, exactly. Each step is one engine call, and a finger moving within one step makes none.
    @Test func holdStepsUpAndDownAndReturnsToTheSpeedBeforeLetGo() async throws {
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        try await waitUntil { model.isPlaying }
        model.setRate(1.25)
        #expect(model.beginHeldSpeed())
        #expect(model.heldSpeed == PlayerViewModel.HeldSpeed(restoreRate: 1.25, rate: 2))
        #expect(model.state.rate == 2, "the badge reads the speed the engine reports")
        let steps: [(Double, Float)] = [(-40, 3), (-80, 4), (-200, 4), (-40, 3), (-20, 2), (0, 2)]
        for (displacement, expected) in steps {
            model.setHeldSpeed(SpeedHoldRules.rate(displacement: displacement, maximum: model.heldSpeedMaximum))
            #expect(model.heldSpeed?.rate == expected, "\(displacement) points from the hold's start")
        }
        model.endHeldSpeed()
        #expect(model.heldSpeed == nil)
        #expect(engines.made["a"]?.rates == [1.25, 2, 3, 4, 3, 2, 1.25])
        await model.close()
    }

    /// The engine's own ceiling caps the hold: a hold on an engine topping out at 2× never asks for more.
    @Test func holdStopsAtTheEnginesOwnCeiling() async throws {
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        try await waitUntil { model.isPlaying }
        engines.made["a"]?.maximumRate = 2
        #expect(model.heldSpeedMaximum == 2)
        #expect(model.beginHeldSpeed())
        model.setHeldSpeed(SpeedHoldRules.rate(displacement: -300, maximum: model.heldSpeedMaximum))
        #expect(model.heldSpeed?.rate == 2)
        #expect(engines.made["a"]?.rates == [2], "the engine is asked for 2× once, never 3× or 4×")
        model.endHeldSpeed()
        await model.close()
    }

    @Test func heldSpeedRejectsInvalidRatesAndClampsBothEnds() async throws {
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        try await waitUntil { model.isPlaying }
        model.setRate(1.25)
        #expect(model.beginHeldSpeed())
        model.setHeldSpeed(-1)
        model.setHeldSpeed(.nan)
        model.setHeldSpeed(.infinity)
        model.setHeldSpeed(100)
        model.setHeldSpeed(100)
        model.endHeldSpeed()
        #expect(engines.made["a"]?.rates == [1.25, 2, 4, 1.25])
        await model.close()
    }

    /// A paused film takes no hold, and the engine hears nothing of the press.
    @Test func aPausedFilmTakesNoHold() async throws {
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        try await waitUntil { model.isPlaying }
        model.togglePlayPause()
        try await waitUntil { !model.isPlaying }
        #expect(model.beginHeldSpeed() == false)
        #expect(model.heldSpeed == nil)
        #expect(engines.made["a"]?.rates.isEmpty == true)
        await model.close()
    }

    /// Begin and end are idempotent: a second begin takes nothing, a second end undoes nothing, and a repeated step makes no call.
    @Test func repeatedBeginAndEndDoNothingTwice() async throws {
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        try await waitUntil { model.isPlaying }
        model.setRate(1.25)
        #expect(model.beginHeldSpeed())
        #expect(model.beginHeldSpeed() == false)
        model.setHeldSpeed(2)
        model.endHeldSpeed()
        model.endHeldSpeed()
        #expect(model.heldSpeed == nil)
        #expect(engines.made["a"]?.rates == [1.25, 2, 1.25])
        await model.close()
    }

    /// Holds come and go: each release returns the film to its speed, and the next hold starts again from there.
    @Test func consecutiveHoldsEachReturnToTheSpeedBeforeThem() async throws {
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        try await waitUntil { model.isPlaying }
        model.setRate(1.25)
        #expect(model.beginHeldSpeed())
        model.setHeldSpeed(3)
        model.endHeldSpeed()
        #expect(model.beginHeldSpeed())
        model.endHeldSpeed()
        #expect(model.heldSpeed == nil)
        #expect(engines.made["a"]?.rates == [1.25, 2, 3, 1.25, 2, 1.25])
        await model.close()
    }

    /// A speed chosen from the Speed panel during a hold is the one the hold returns to; the speed held now is unchanged.
    @Test func aSpeedChosenDuringAHoldIsTheOneItReturnsTo() async throws {
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        try await waitUntil { model.isPlaying }
        model.setRate(1.25)
        #expect(model.beginHeldSpeed())
        model.setRate(1.5)
        #expect(model.heldSpeed == PlayerViewModel.HeldSpeed(restoreRate: 1.5, rate: 2))
        model.endHeldSpeed()
        #expect(engines.made["a"]?.rates == [1.25, 2, 1.5])
        await model.close()
    }

    /// A film that ends mid-hold comes back to its speed, so the next film does not start at the held speed.
    @Test func theFilmEndingReleasesAHold() async throws {
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        try await waitUntil { model.isPlaying }
        model.setRate(1.25)
        #expect(model.beginHeldSpeed())
        model.setHeldSpeed(3)
        engines.made["a"]?.simulateEnd()
        try await waitUntil { model.hasFinished }
        #expect(model.heldSpeed == nil)
        #expect(engines.made["a"]?.rates.last == 1.25)
        await model.close()
    }

    /// Closing the player drops a hold without an engine call, because the engine is being stopped.
    @Test func closingDuringAHoldDropsIt() async throws {
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        try await waitUntil { model.isPlaying }
        #expect(model.beginHeldSpeed())
        await model.close()
        #expect(model.heldSpeed == nil)
        #expect(engines.made["a"]?.rates == [2])
    }

    /// Replacing the stream ends the old picture's hold before applying session settings to the new engine.
    @Test func changingStreamsRestoresThePreHoldSpeed() async throws {
        let engines = Engines(["a": .plays(duration: 200), "b": .plays(duration: 200)], maximumRates: ["b": 2])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a"), candidate("b")]),
                                    services: try await services(engines: engines))
        await model.start()
        try await waitUntil { model.isPlaying }
        #expect(model.beginHeldSpeed())
        model.setHeldSpeed(SpeedHoldRules.rate(displacement: -200, maximum: model.heldSpeedMaximum))
        #expect(model.heldSpeed?.rate == 4)
        await model.selectStream(at: 1)
        try await waitUntil { model.isPlaying }
        #expect(model.heldSpeed == nil)
        #expect(engines.made["b"]?.rates.isEmpty == true, "the replacement starts at the original 1×")
        model.endHeldSpeed()
        #expect(engines.made["b"]?.rates.isEmpty == true)
        await model.close()
    }

    /// The pinch is a shortcut for Zoom Mode: out selects Fill, in shows the whole picture (Normal).
    @Test func pinchingSwitchesBetweenNormalAndFill() async throws {
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        model.setAspectRatio(.widescreenA)
        #expect(model.zoomMode == .crop && model.videoLayout == VideoLayout(fit: .fit, crop: .ratio185))
        model.pinchZoom(in: false)
        #expect(model.zoomMode == .normal && model.videoLayout == VideoLayout(fit: .fit))
        model.pinchZoom(in: true)
        #expect(model.zoomMode == .fill && model.videoLayout == VideoLayout(fit: .fill, crop: .ratio185))
        model.pinchZoom(in: true)
        #expect(model.zoomMode == .fill, "Pinching outward keeps Fill selected")
        model.setZoomMode(.stretch)
        model.pinchZoom(in: false)
        #expect(model.zoomMode == .normal)
        await model.close()
    }

    /// Normal and Aspect Fit show the uncropped frame, Crop trims bars for the chosen Aspect Ratio and fits proportionally,
    /// Fill covers the viewport intentionally sacrificing outer edges, and Stretch fills non-uniformly.
    @Test func zoomModesSetTheRenderersLayout() async throws {
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        #expect(model.zoomMode == .normal && model.aspectRatio == .original, "the defaults: Normal, Original")
        model.setSafeAreaInset(59)
        #expect(model.videoLayout == VideoLayout(fit: .fit, inset: 59), "Normal fits inside the safe area")
        model.setZoomMode(.aspectFit)
        if PlayerViewModel.ZoomMode.available.contains(.aspectFit) {
            #expect(model.videoLayout == VideoLayout(fit: .fit), "Aspect Fit fits to the whole screen")
        } else {
            #expect(model.zoomMode == .normal && model.videoLayout == VideoLayout(fit: .fit, inset: 59), "a Mac has no Aspect Fit")
        }
        model.setZoomMode(.crop)
        #expect(model.videoLayout == VideoLayout(fit: .fit), "Original preserves the whole frame without overshooting")
        model.setAspectRatio(.widescreenA)
        #expect(model.videoLayout == VideoLayout(fit: .fit, crop: .ratio185), "Crop trims bars and proportionally fits")
        model.setZoomMode(.fill)
        #expect(model.videoLayout == VideoLayout(fit: .fill, crop: .ratio185), "Fill covers the screen intentionally")
        model.setZoomMode(.stretch)
        #expect(model.videoLayout == VideoLayout(fit: .stretch, crop: .ratio185))
        model.setZoomMode(.normal)
        #expect(model.videoLayout == VideoLayout(fit: .fit, inset: 59))
        await model.close()
    }

    /// The zoom button steps through every mode this device offers and round again.
    @Test func theZoomButtonCyclesTheModes() async throws {
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        var seen: [PlayerViewModel.ZoomMode] = []
        for _ in PlayerViewModel.ZoomMode.available {
            model.cycleZoomMode()
            seen.append(model.zoomMode)
        }
        #expect(seen == Array(PlayerViewModel.ZoomMode.available.dropFirst()) + [.normal])
        await model.close()
    }

    @Test func selectingAspectRatioInNormalPromotesToCropAndKeepsManualCropAcrossModes() async throws {
        let engines = Engines(["a": .plays(duration: 200)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        model.setAspectRatio(.widescreenB)
        #expect(model.zoomMode == .crop && model.videoLayout == VideoLayout(fit: .fit, crop: .ratio2x1))
        for mode in [PlayerViewModel.ZoomMode.crop, .fill, .stretch] {
            model.setZoomMode(mode)
            #expect(model.videoLayout.aspect == .source)
            #expect(model.videoLayout.crop == .ratio2x1)
            #expect(model.videoLayout.zoom == 1)
        }
        model.setZoomMode(.normal)
        #expect(model.videoLayout == VideoLayout(fit: .fit))
        model.setAspectRatio(.original)
        #expect(model.videoLayout.aspect == .source && model.videoLayout.crop == .off)
        await model.close()
    }

    @Test func manualCropStaysSelectedWhilePinchingRotatingAndSwitchingStreams() async throws {
        let engines = Engines(["a": .plays(duration: 200), "b": .plays(duration: 200)])
        let plan = PlaybackPlan(request: request, candidates: [candidate("a"), candidate("b")], retriesInFallbackEngine: true)
        let model = PlayerViewModel(plan: plan, services: try await services(engines: engines))
        await model.start()
        model.setAspectRatio(.anamorphicB)
        for _ in 0..<3 {
            model.pinchZoom(in: true)
            model.setSafeAreaInset(59)
            #expect(model.videoLayout == VideoLayout(fit: .fill, crop: .ratio239))
            model.pinchZoom(in: false)
            #expect(model.videoLayout == VideoLayout(fit: .fit, inset: 59))
            model.setSafeAreaInset(0)
        }
        model.pinchZoom(in: true)
        await model.openInAdvancedPlayer()
        #expect(model.videoLayout == VideoLayout(fit: .fill, crop: .ratio239))
        #expect(engines.fallbackMade["a"] != nil)
        await model.nextStream()
        #expect(model.videoLayout == VideoLayout(fit: .fill, crop: .ratio239))
        await model.close()
    }

    @Test func skippingMovesRelativeToThePosition() async throws {
        let engines = Engines(["a": .plays(duration: 100)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        engines.made["a"]?.simulate(position: 40)
        try await waitUntil { model.position == 40 }
        await model.skip(by: 10)
        try await waitUntil { model.position == 50 }
        await model.skip(by: -10)
        #expect(engines.made["a"]?.seeks == [50, 40])
        await model.close()
    }

    @Test func formatsTime() {
        #expect(PlayerTime.format(0) == "0:00" && PlayerTime.format(5.9) == "0:05" && PlayerTime.format(125) == "2:05")
        #expect(PlayerTime.format(3723) == "1:02:03" && PlayerTime.format(36000) == "10:00:00")
        #expect(PlayerTime.format(-5) == "0:00" && PlayerTime.format(.nan) == "0:00" && PlayerTime.format(.infinity) == "0:00")
    }

    // MARK: next episode

    @Test func nextEpisodeAutoSelectsTheStreamInTheSameBingeGroup() async throws {
        let withGroup = { (name: String, url: String, group: String) in #"{"name":"\#(name)","url":"\#(url)","behaviorHints":{"bingeGroup":"\#(group)"}}"# }
        let next = #"{"streams":[\#(withGroup("other", "https://a.example.com/e2-other.mp4", "g-720")),\#(withGroup("match", "https://a.example.com/e2-match.mp4", "g-1080"))]}"#
        let episode = StreamRequest(type: "series", id: "tt9:1:1", title: "Show · One", season: 1, episode: 1,
            nextID: "tt9:1:2", nextTitle: "Show · Two", nextSeason: 1, nextEpisode: 2)
        let engines = Engines(["a": .plays(duration: 10)])
        let services = try await services(engines: engines, streamBodies: [next])
        let model = PlayerViewModel(plan: PlaybackPlan(request: episode, candidates: [candidate("a", binge: "g-1080")], ), services: services)
        #expect(model.hasNextEpisode)
        await model.start()
        let nextPlan = await model.prepareNextEpisode()
        #expect(nextPlan?.request.id == "tt9:1:2")
        #expect(nextPlan?.candidates.first?.title == "match")
        await model.close()
    }

    @Test func noMatchingBingeGroupMeansNoAutoSelection() async throws {
        let next = #"{"streams":[{"name":"x","url":"https://a.example.com/e2.mp4","behaviorHints":{"bingeGroup":"different"}}]}"#
        let episode = StreamRequest(type: "series", id: "tt9:1:1", title: "Show · One", nextID: "tt9:1:2", nextTitle: "Show · Two")
        let services = try await services(engines: Engines(["a": .plays(duration: 10)]), streamBodies: [next])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a", binge: "g-1080")]), services: services)
        await model.start()
        #expect(await model.prepareNextEpisode() == nil)
        await model.close()
        let movie = PlayerViewModel(plan: PlaybackPlan(request: episode, candidates: [candidate("a", binge: "g-1080")]), services: services)
        #expect(movie.hasNextEpisode)
        #expect(await movie.prepareNextEpisode() == nil)
    }

    @Test func reachingTheEndMarksTheViewModelFinished() async throws {
        let engines = Engines(["a": .plays(duration: 10)])
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]), services: try await services(engines: engines))
        await model.start()
        #expect(!model.hasFinished)
        engines.made["a"]?.simulate(position: 10)
        engines.made["a"]?.simulateEnd()
        try await waitUntil { model.hasFinished }
        await model.close()
    }
}

final class ClockBox2: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
