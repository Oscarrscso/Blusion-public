import Foundation
import Testing
import PlayerKit
import PlayerKitTestSupport
import StremioKit
import StremioKitTestSupport
@testable import Features

/// Subtitle defaults, engine-drawn subtitle files, local files, skip markers and saved player preferences.
@MainActor
@Suite struct PlayerFeatureTests {
    private let request = StreamRequest(type: "movie", id: "tt1", title: "Movie")
    private let srt = "1\n00:00:01,000 --> 00:00:03,000\n<i>First</i> cue\n\n2\n00:00:04,500 --> 00:00:06,250\nSecond cue\n"
    private let englishFile = SubtitleItem(id: "en", url: URL(string: "https://subs.example.com/en.srt")!, lang: "eng")

    @MainActor
    private final class Engines {
        var made: [MockEngine] = []
        let make: (PlaybackCandidate) -> MockEngine?
        init(_ make: @escaping (PlaybackCandidate) -> MockEngine?) { self.make = make }
        func engine(_ candidate: PlaybackCandidate) -> (any PlaybackEngine)? {
            guard let engine = make(candidate) else { return nil }
            made.append(engine)
            return engine
        }
    }

    private func candidate(_ id: String, subtitles: [SubtitleItem] = []) -> PlaybackCandidate {
        PlaybackCandidate(id: id, title: "Stream \(id)", route: .native(URL(string: "https://e.example.com/\(id).mp4")!), subtitles: subtitles)
    }

    private func services(_ settings: PlaybackSettings = PlaybackSettings(), store: (any SettingsStore)? = nil, engines: Engines) async throws -> AppServices {
        let body = srt
        let transport = StubTransport { request, _ in StubTransport.response(Data(body.utf8), for: request) }
        let (registry, client) = try await makeStubbedRegistry(manifests: [], transport: transport)
        return AppServices(registry: registry, client: client, settings: store ?? InMemorySettingsStore(settings), makeEngine: { engines.engine($0) })
    }

    private func settings(language: String? = "eng", mode: SubtitleMode = .always, sdh: Bool = false, audio: String? = nil) -> PlaybackSettings {
        PlaybackSettings(subtitleLanguage: language, player: PlayerPreferences(subtitleMode: mode, prefersSDH: sdh, audioLanguage: audio))
    }

    // MARK: Defaults

    @Test func anEmbeddedTrackInThePreferredLanguageIsPreferredToAFile() async throws {
        let tracks = [MediaTrack(id: "s1", title: "French", language: "fre"), MediaTrack(id: "s2", title: "English", language: "eng"),
                      MediaTrack(id: "s3", title: "English SDH", language: "eng", isHearingImpaired: true)]
        let engines = Engines { _ in MockEngine(subtitles: tracks) }
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a", subtitles: [englishFile])]),
                                    services: try await services(settings(), engines: engines))
        await model.start()
        try await waitUntil { model.subtitleChoice == .embedded("s2") }
        #expect(engines.made[0].selectedEmbeddedSubtitles.last == "s2")
        await model.close()
    }

    @Test func sdhIsTakenWhenPreferred() async throws {
        let tracks = [MediaTrack(id: "s2", title: "English", language: "eng"), MediaTrack(id: "s3", title: "English SDH", language: "eng", isHearingImpaired: true)]
        let engines = Engines { _ in MockEngine(subtitles: tracks) }
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]),
                                    services: try await services(settings(sdh: true), engines: engines))
        await model.start()
        try await waitUntil { model.subtitleChoice == .embedded("s3") }
        await model.close()
    }

    @Test func forcedOnlyFollowsTheAudioLanguageWhenNoSubtitleLanguageIsSet() async throws {
        let tracks = [MediaTrack(id: "s1", title: "English", language: "eng"), MediaTrack(id: "s2", title: "Signs", language: "eng", isForced: true)]
        let engines = Engines { _ in MockEngine(audio: [MediaTrack(id: "a1", title: "English", language: "eng")], subtitles: tracks) }
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]),
                                    services: try await services(settings(language: nil, mode: .forcedOnly), engines: engines))
        await model.start()
        try await waitUntil { model.subtitleChoice == .embedded("s2") }
        await model.close()
    }

    @Test func subtitlesStayOffWhenTheModeIsOff() async throws {
        let engines = Engines { _ in MockEngine(subtitles: [MediaTrack(id: "s1", title: "English", language: "eng")]) }
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a", subtitles: [englishFile])]),
                                    services: try await services(settings(mode: .off), engines: engines))
        await model.start()
        await model.waitForSubtitles()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.subtitleChoice == .off)
        await model.close()
    }

    @Test func thePreferredAudioLanguageIsSelected() async throws {
        let audio = [MediaTrack(id: "a1", title: "Japanese", language: "jpn"), MediaTrack(id: "a2", title: "English 2.0", language: "eng", channelCount: 2),
                     MediaTrack(id: "a3", title: "English 5.1", language: "eng", channelCount: 6)]
        let engines = Engines { _ in MockEngine(audio: audio) }
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]),
                                    services: try await services(settings(language: nil, audio: "en"), engines: engines))
        await model.start()
        try await waitUntil { model.selectedAudioTrackID == "a3" }
        await model.close()
    }

    // MARK: Engine-drawn files

    @Test func anEngineThatDrawsFilesGetsTheChosenFileAndItsTiming() async throws {
        let engines = Engines { _ in MockEngine(capabilities: [.engineSubtitles, .subtitleDelay]) }
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a", subtitles: [englishFile])]),
                                    services: try await services(settings(), engines: engines))
        await model.start()
        let option = try #require(model.subtitleOptions.first)
        try await waitUntil { model.subtitleChoice == .external(option.id) }
        let engine = engines.made[0]
        #expect(engine.addedSubtitles.map(\.url) == [englishFile.url])
        #expect(engine.addedSubtitles.first?.language == "en", "engines take two-letter codes")
        #expect(model.cueText == nil && model.activeCues.isEmpty, "the engine draws it, not the overlay")
        #expect(model.embeddedSubtitleTracks.isEmpty, "the loaded file is listed with the files, not as a track")
        #expect(model.canShiftSubtitles)
        model.adjustSubtitleOffset(by: 0.5)
        #expect(engine.subtitleDelays.last == 0.5)
        await model.selectSubtitle(.off)
        await model.selectSubtitle(.external(option.id))
        #expect(engine.addedSubtitles.count == 1, "selected again, not loaded twice: \(engine.addedSubtitles.map(\.title))")
        await model.close()
    }

    @Test func theOverlayDrawsStyledCuesForAnEngineThatDoesNot() async throws {
        let engines = Engines { _ in MockEngine() }
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a", subtitles: [englishFile])]),
                                    services: try await services(settings(), engines: engines))
        await model.start()
        try await waitUntil { if case .external = model.subtitleChoice { return true } else { return false } }
        engines.made[0].simulate(position: 2)
        try await waitUntil { !model.activeCues.isEmpty }
        #expect(model.activeCues.first?.spans.first?.isItalic == true)
        #expect(model.cueText == "First cue")
        await model.close()
    }

    @Test func aLocalFileJoinsTheListAndIsSelected() async throws {
        let engines = Engines { _ in MockEngine() }
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]),
                                    services: try await services(settings(language: nil), engines: engines))
        await model.start()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Movie.2020.fr.srt")
        try Data(srt.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await model.loadSubtitleFile(at: file)
        let option = try #require(model.subtitleOptions.last)
        #expect(option.source == .local && option.language == "fre")
        #expect(model.subtitleChoice == .external(option.id))
        engines.made[0].simulate(position: 5)
        try await waitUntil { model.cueText == "Second cue" }
        await model.close()
    }

    @Test func languagesAreReadFromFileNames() {
        #expect(PlayerViewModel.language(inFileName: "Movie.2020.en.forced.srt") == "eng")
        #expect(PlayerViewModel.language(inFileName: "Show.S01E02.German.ass") == "ger")
        #expect(PlayerViewModel.language(inFileName: "subtitle.srt") == nil)
    }

    @Test func subtitleOptionsReadForcedAndSDHFromTheirNames() {
        let forced = SubtitleOption(id: "x", language: "eng", title: "English", url: URL(string: "https://s.example.com/Movie.en.forced.srt")!, source: .stream)
        let sdh = SubtitleOption(id: "y", language: "eng", title: "English SDH", url: URL(string: "https://s.example.com/b.ass")!, source: .stream)
        let plain = SubtitleOption(id: "z", language: "eng", title: "English", url: URL(string: "https://s.example.com/history.vtt")!, source: .stream)
        #expect(forced.isForced && !forced.isHearingImpaired && forced.format == .srt)
        #expect(sdh.isHearingImpaired && sdh.format == .ass && sdh.format.prefersEngine)
        #expect(!plain.isForced && !plain.isHearingImpaired && plain.format == .vtt)
        #expect(SubtitleService.defaultOption(in: [forced, sdh, plain], preferredLanguage: "en") == plain)
        #expect(SubtitleService.defaultOption(in: [forced, sdh, plain], preferredLanguage: "en", prefersSDH: true) == sdh)
    }

    // MARK: Chapters and skipping

    @Test func markedIntrosShowASkipButtonAndCanSkipThemselves() async throws {
        let engines = Engines { _ in MockEngine(.plays(duration: 1500)) }
        var preferences = PlayerPreferences()
        preferences.skipsIntrosAutomatically = true
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]),
                                    services: try await services(PlaybackSettings(player: preferences), engines: engines))
        await model.start()
        let engine = engines.made[0]
        engine.simulate(chapters: [Chapter(index: 0, title: "Cold open", start: 0), Chapter(index: 1, title: "Opening", start: 60),
                                   Chapter(index: 2, title: "Part 1", start: 150), Chapter(index: 3, title: "End Credits", start: 1400)])
        engine.simulate(position: 70)
        try await waitUntil { model.activeSkipMarker?.kind == .intro }
        #expect(model.currentChapter?.title == "Opening")
        await model.skipAutomaticallyIfNeeded()
        #expect(engine.seeks.last == 150)
        engine.simulate(position: 1450)
        try await waitUntil { model.activeSkipMarker?.kind == .credits }
        #expect(model.skipEndsMedia(try #require(model.activeSkipMarker)))
        await model.skipAutomaticallyIfNeeded()
        #expect(engine.seeks.last == 150, "credits are never skipped automatically")
        await model.previousChapter()
        #expect(engine.seeks.last == 1400)
        await model.close()
    }

    // MARK: Preferences

    @Test func pictureAndStyleChangesInThePlayerAreSaved() async throws {
        let store = InMemorySettingsStore()
        let engines = Engines { _ in MockEngine() }
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]),
                                    services: try await services(store: store, engines: engines))
        await model.start()
        model.setVideoFit(.fill)
        model.setSubtitleStyle(SubtitleStyle(scale: 1.5, colour: .yellow))
        model.setProcessing(VideoProcessing(toneMapping: .spline, upscaling: .ai))
        #expect(engines.made[0].layouts.last?.fit == .fill)
        #expect(engines.made[0].subtitleStyles.last?.colour == .yellow)
        #expect(model.preferences.processing.upscaling == .ai)
        await model.waitForSavedPreferences()
        let saved = await store.load().player
        #expect(saved.videoLayout.fit == .fill && saved.subtitleStyle.scale == 1.5 && saved.processing.toneMapping == .spline)
        await model.close()
    }

    @Test func fitAndFillDiscardLegacyStretchZoomAspectAndCrop() async throws {
        var settings = PlaybackSettings()
        settings.player.videoLayout = VideoLayout(fit: .stretch, zoom: 2,
                                                  aspect: .ratio4x3, crop: .ratio239)
        let store = InMemorySettingsStore(settings)
        let engines = Engines { _ in MockEngine() }
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]),
                                    services: try await services(store: store, engines: engines))
        await model.start()
        #expect(model.videoLayout == VideoLayout(), "the first frame must not inherit stretched or zoomed settings")

        model.setAspect(.ratio16x9)
        model.setCrop(.ratio239)
        model.setZoom(2)
        model.setVideoFit(.fill)
        #expect(model.videoLayout == VideoLayout(fit: .fill), "fill is a centred, aspect-preserving crop")

        model.setVideoFit(.fit)
        #expect(model.videoLayout == VideoLayout(), "pinching inward restores the original uncropped picture")

        await model.waitForSavedPreferences()
        let saved = await store.load().player.videoLayout
        #expect(saved.fit == .fit)
        await model.close()
    }

    @Test func cropAndZoomKeepEachOtherAndDolbyVisionKeepsTheRestOfThePicture() async throws {
        let store = InMemorySettingsStore()
        let engines = Engines { _ in MockEngine() }
        let model = PlayerViewModel(plan: PlaybackPlan(request: request, candidates: [candidate("a")]),
                                    services: try await services(store: store, engines: engines))
        await model.start()
        model.setAspect(.ratio16x9)
        model.setCrop(.ratio239)
        model.setZoom(1.5)
        #expect(engines.made[0].layouts.last == VideoLayout(fit: .fit, zoom: 1.5, aspect: .ratio16x9, crop: .ratio239))
        model.setProcessing(VideoProcessing(toneMapping: .spline, upscaling: .ai))
        model.setDolbyVision(false)
        #expect(engines.made[0].processings.last == VideoProcessing(toneMapping: .spline, upscaling: .ai, dolbyVision: false))
        await model.waitForSavedPreferences()
        let saved = await store.load().player
        #expect(!saved.processing.dolbyVision && saved.processing.upscaling == .ai)
        #expect(saved.videoLayout.crop == .off, "the crop is for this video")
        await model.close()
    }

    @Test func playerPreferencesSurviveTheDefaultsStore() async throws {
        let defaults = try #require(UserDefaults(suiteName: "player-prefs-\(UUID().uuidString)"))
        let store = DefaultsSettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        var settings = PlaybackSettings()
        settings.player.subtitleMode = .forcedOnly
        settings.player.subtitleStyle = SubtitleStyle(scale: 1.25, background: .box, hdrPeakNits: 150)
        settings.player.processing.deinterlace = .on
        settings.openSubtitlesAPIKey = " key "
        await store.save(settings)
        let loaded = await store.load()
        #expect(loaded.player == settings.player)
        #expect(loaded.openSubtitlesAPIKey == "key")
        defaults.set(Data(#"{"subtitleMode":"forcedOnly","future":1}"#.utf8), forKey: DefaultsSettingsStore.Keys.player)
        #expect(await store.load().player.subtitleMode == .forcedOnly, "unknown and missing fields fall back to defaults")
    }
}
