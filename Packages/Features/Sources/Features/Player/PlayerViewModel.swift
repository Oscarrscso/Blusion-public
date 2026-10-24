import Foundation
import Observation
import PlayerKit
import StremioKit

public enum PlayerTime {
    /// `2:03` or `1:02:03`.
    public static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Everything the player screen shows and does, on top of `PlaybackCoordinator`. Contains no SwiftUI, so it is tested on the host.
@MainActor
@Observable
public final class PlayerViewModel {
    public enum SubtitleChoice: Hashable, Sendable {
        case off
        case external(String)
        case embedded(String)
    }

    public static let controlsHideDelay: TimeInterval = 3
    public static let maximumSubtitleOffset: TimeInterval = 60
    public static let maximumAudioDelay: TimeInterval = 10

    public let plan: PlaybackPlan
    public private(set) var coordinator: PlaybackCoordinator?
    public private(set) var subtitleOptions: [SubtitleOption] = [] {
        didSet { externalSubtitleRows = PlayerTrackPresentation.external(subtitleOptions) }
    }
    public private(set) var externalSubtitleRows: [PlayerTrackRow] = []
    public private(set) var embeddedSubtitleRows: [PlayerTrackRow] = []
    public private(set) var audioTrackRows: [PlayerTrackRow] = []
    public private(set) var audioTrackSelectionID: String?
    public private(set) var subtitleChoice: SubtitleChoice = .off
    public private(set) var subtitleStatus: String?
    /// Positive delays the subtitles. Applies to whichever draws them: the app's overlay, or the engine for its own tracks and files.
    public private(set) var subtitleOffset: TimeInterval = 0
    public private(set) var controlsVisible = true
    public private(set) var isScrubbing = false
    public private(set) var scrubFraction = 0.0
    public private(set) var settings = PlaybackSettings()
    public private(set) var hasFinished = false
    /// A styled (ASS) file the overlay draws simplified; the advanced player would draw its effects.
    public private(set) var hasSimplifiedStyling = false
    public private(set) var openSubtitlesResults: [OpenSubtitlesResult] = []
    public private(set) var openSubtitlesStatus: String?
    public private(set) var isSearchingOpenSubtitles = false

    private let services: AppServices
    private let now: @Sendable () -> Date
    private var timeline: SubtitleTimeline?
    private var bitmapTimeline: BitmapSubtitleTimeline?
    private var lastInteraction: Date
    private var userChoseSubtitle = false
    private var userChoseAudio = false
    /// The choice the defaults made, while the listener has not made one: a better default (an embedded track) may still replace it.
    private var automaticChoice: SubtitleChoice?
    /// The external option the engine draws (loaded into it), rather than the overlay.
    private var engineDrawnOptionID: String?
    private var subtitleGeneration = 0
    /// The subtitle choice a load in flight is working towards, so presses during it, and a repeat of the same default, see it as chosen.
    private var pendingChoice: SubtitleChoice?
    private var subtitleTask: Task<Void, Never>?
    private var lookupTasks: [Task<Void, Never>] = []
    private var lookedUpCandidates: Set<String> = []
    private var skippedMarkers: Set<SkipMarker> = []
    private var temporaryFiles: [URL] = []
    private var saveTask: Task<Void, Never>?

    public init(plan: PlaybackPlan, services: AppServices, now: @escaping @Sendable () -> Date = Date.init) {
        self.plan = plan
        self.services = services
        self.now = now
        self.lastInteraction = now()
    }

    // MARK: Lifecycle

    /// Loads settings and resume position, starts playback (returns when playing or every stream failed), and fetches subtitles alongside.
    public func start() async {
        // Both at once: the stream starts loading only after them.
        async let loadedSettings = services.settings.load()
        async let savedProgress = services.progress.progress(for: plan.request.identity)
        settings = await loadedSettings
        let previous = await savedProgress
        let resume = ProgressRecorder.resumePosition(for: previous)
        let session = ProgressSession(request: plan.request, previous: previous, store: services.progress)
        let player = settings.player
        // Older builds could save stretch or arbitrary display ratios. Start with
        // an undistorted picture, retaining only the preferred Fit/Fill mode.
        var safeLayout = player.videoLayout
        if safeLayout.fit == .stretch { safeLayout.fit = .fit }
        safeLayout.zoom = 1
        safeLayout.aspect = .source
        safeLayout.crop = .off
        let coordinator = PlaybackCoordinator(plan: plan, resumeFrom: resume, progress: session, layout: safeLayout,
                                              processing: player.processing, subtitleStyle: player.subtitleStyle, makeEngine: services.makeEngine)
        coordinator.onEnded = { [weak self] in self?.hasFinished = true }
        coordinator.onCandidateChange = { [weak self] candidate in self?.lookUpSubtitles(for: candidate) }
        coordinator.onEngineChange = { [weak self] in self?.engineChanged() }
        coordinator.onTracksChange = { [weak self] in self?.tracksChanged() }
        self.coordinator = coordinator
        startSubtitles()
        await coordinator.start()
    }

    public func close() async {
        subtitleTask?.cancel()
        lookupTasks.forEach { $0.cancel() }
        await coordinator?.stop()
        temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryFiles = []
    }

    // MARK: Playback state (read-through)

    public var state: PlaybackState { coordinator?.state ?? PlaybackState() }
    public var title: String { coordinator?.current?.title ?? plan.request.title }
    public var isPlaying: Bool { state.isPlaying }
    public var isBuffering: Bool {
        switch state.status {
        case .loading, .buffering: return true
        default: return coordinator?.phase == .starting
        }
    }
    /// The spinner shows only for a stall after playback has begun, with the controls hidden. While the stream starts, and whenever the
    /// controls show, the play button sits where it would.
    public var showsBufferingIndicator: Bool {
        isBuffering && !controlsVisible && failureMessage == nil && coordinator?.phase == .playing
    }
    public var position: TimeInterval { isScrubbing ? scrubFraction * (state.duration ?? 0) : state.position }
    public var duration: TimeInterval? { state.duration }
    public var fraction: Double { isScrubbing ? scrubFraction : (state.duration.map { $0 > 0 ? min(1, state.position / $0) : 0 } ?? 0) }
    public var positionText: String { PlayerTime.format(position) }
    public var remainingText: String { state.duration.map { "-" + PlayerTime.format(max(0, $0 - position)) } ?? "" }
    public var notice: String? { coordinator?.notice }
    public var hasNextStream: Bool { (coordinator?.candidateIndex ?? 0) + 1 < plan.candidates.count }
    public var hasNextEpisode: Bool { plan.request.nextRequest != nil }
    public var canPictureInPicture: Bool { coordinator?.current?.route.isNative == true }
    public var volume: Float { coordinator?.volume ?? 1 }
    public var isMuted: Bool { coordinator?.isMuted ?? false }
    public var capabilities: EngineCapabilities { coordinator?.capabilities ?? [] }
    public var preferences: PlayerPreferences { settings.player }
    /// A fallback engine is there to take the stream over, and the current engine cannot draw subtitles with full styling itself.
    public var canOpenInAdvancedPlayer: Bool {
        plan.retriesInFallbackEngine && coordinator?.current?.url != nil && !capabilities.contains(.engineSubtitles)
    }

    /// Set once every stream failed.
    public var failureMessage: String? {
        guard coordinator?.phase == .exhausted else { return nil }
        let reasons = Array(Set(coordinator?.failedAttempts.map(\.failure.message) ?? [])).sorted().prefix(2).joined(separator: " ")
        return reasons.isEmpty ? "This couldn't be played." : "None of the streams could be played. \(reasons)"
    }

    public func statistics() -> PlaybackStatistics? { coordinator?.statistics() }

    // MARK: Transport

    public func togglePlayPause() {
        coordinator?.togglePlayPause()
        showControls()
    }

    public func skip(by seconds: TimeInterval) async {
        showControls()
        await coordinator?.skip(by: seconds)
    }

    public func seek(to position: TimeInterval) async {
        showControls()
        await coordinator?.seek(to: position)
    }

    public func nextStream() async {
        showControls()
        await coordinator?.advance()
    }

    public func setRate(_ rate: Float) {
        coordinator?.setRate(rate)
        showControls()
    }

    /// The Mac's ↑ and ↓ keys, in tenths of the full level.
    public func adjustVolume(by delta: Float) {
        coordinator?.setVolume(((volume + delta) * 10).rounded() / 10)
        showControls()
    }

    /// The swipe on the right of the picture.
    public func setVolume(_ level: Float) {
        coordinator?.setVolume(level)
        if isMuted, level > 0 { coordinator?.setMuted(false) }
    }

    public func toggleMute() {
        coordinator?.setMuted(!isMuted)
        showControls()
    }

    public func beginScrub() {
        // Capture the live position before fraction starts reading scrubFraction.
        // Otherwise touching the timeline jumps its thumb to the previous drag.
        let currentFraction = fraction
        scrubFraction = currentFraction
        isScrubbing = true
        showControls()
    }

    public func updateScrub(fraction: Double) {
        scrubFraction = min(1, max(0, fraction))
        showControls()
    }

    public func endScrub() async {
        guard isScrubbing else { return }
        let target = scrubFraction * (state.duration ?? 0)
        await coordinator?.seek(to: target)
        isScrubbing = false
    }

    /// Plays this stream in the fallback engine from here, for what only it draws (full ASS styling, picture subtitles).
    public func openInAdvancedPlayer() async {
        showControls()
        await coordinator?.reopenInFallbackEngine()
    }

    // MARK: Controls visibility

    public func showControls() {
        // The pointer hover calls this on every move, so the observed flag is written only when it changes.
        if !controlsVisible { controlsVisible = true }
        lastInteraction = now()
    }

    public func toggleControls() {
        if controlsVisible { controlsVisible = false } else { showControls() }
    }

    /// Call periodically. Hides the controls after a few idle seconds, but only while playing and not scrubbing.
    public func hideControlsIfIdle() {
        guard controlsVisible, isPlaying, !isScrubbing, now().timeIntervalSince(lastInteraction) >= Self.controlsHideDelay else { return }
        controlsVisible = false
    }

    // MARK: Chapters and skipping

    public var chapters: [Chapter] { state.chapters }

    /// The chapter playing now.
    public var currentChapter: Chapter? { chapters.last { $0.start <= state.position + 0.5 } }

    public func seek(toChapter chapter: Chapter) async {
        await seek(to: chapter.start)
    }

    public func previousChapter() async {
        // Within the first seconds of a chapter, back goes to the one before, as on a disc player.
        guard let current = currentChapter, let index = chapters.firstIndex(of: current) else { return }
        let target = state.position - current.start < 3 && index > 0 ? chapters[index - 1] : current
        await seek(toChapter: target)
    }

    public func nextChapter() async {
        guard let next = chapters.first(where: { $0.start > state.position + 0.5 }) else { return }
        await seek(toChapter: next)
    }

    public var skipMarkers: [SkipMarker] { SkipMarkers.markers(chapters: chapters, duration: duration) }

    /// The marked intro, recap or credits playing now, for the Skip button. Hidden in its last second, where skipping does nothing.
    public var activeSkipMarker: SkipMarker? {
        guard settings.player.showsSkipButtons else { return nil }
        let position = state.position
        return skipMarkers.first { $0.contains(position) && $0.end - position > 1 }
    }

    /// True when skipping it ends the media: the caller then moves to the next episode instead.
    public func skipEndsMedia(_ marker: SkipMarker) -> Bool {
        guard let duration else { return false }
        return marker.end >= duration - 2
    }

    public func skip(_ marker: SkipMarker) async {
        skippedMarkers.insert(marker)
        await seek(to: marker.end)
    }

    /// Call periodically: skips marked intros and recaps once each when Settings asks for it.
    public func skipAutomaticallyIfNeeded() async {
        guard settings.player.skipsIntrosAutomatically, isPlaying, let marker = activeSkipMarker,
              marker.kind == .intro || marker.kind == .recap, !skippedMarkers.contains(marker) else { return }
        await skip(marker)
    }

    // MARK: Audio

    public var audioTracks: [MediaTrack] { state.audioTracks }
    public var selectedAudioTrackID: String? { state.selectedAudioTrackID }
    public var audioDelay: TimeInterval { coordinator?.audioDelay ?? 0 }

    public func selectAudioTrack(id: String) {
        userChoseAudio = true
        audioTrackSelectionID = id
        coordinator?.selectAudioTrack(id: id)
        showControls()
    }

    public func adjustAudioDelay(by delta: TimeInterval) {
        let limit = Self.maximumAudioDelay
        coordinator?.setAudioDelay(min(limit, max(-limit, ((audioDelay + delta) * 20).rounded() / 20)))
        showControls()
    }

    public func resetAudioDelay() {
        coordinator?.setAudioDelay(0)
    }

    /// An audio file the user opened (a commentary, another dub), played in sync. Needs an engine with `.externalAudio`.
    public func loadAudioFile(at url: URL) async {
        guard capabilities.contains(.externalAudio), let copy = copyIn(url) else { return }
        userChoseAudio = true
        coordinator?.addExternalAudio(url: copy, title: url.deletingPathExtension().lastPathComponent)
        showControls()
    }

    // MARK: Picture

    public var videoLayout: VideoLayout { coordinator?.videoLayout ?? settings.player.videoLayout }
    public var processing: VideoProcessing { coordinator?.processing ?? settings.player.processing }

    /// Fit preserves the full frame; Fill crops centrally to screen, never stretching.
    /// Changing modes also discards legacy aspect, crop and arbitrary zoom overrides.
    public func setVideoFit(_ fit: VideoFit) {
        let safeFit: VideoFit = fit == .fill ? .fill : .fit
        var layout = videoLayout
        layout.fit = safeFit
        layout.zoom = 1
        layout.aspect = .source
        layout.crop = .off
        coordinator?.setVideoLayout(layout)
        savePreferences { $0.videoLayout.fit = safeFit }
        showControls()
    }

    public func setZoom(_ zoom: Double) {
        let layout = videoLayout
        coordinator?.setVideoLayout(VideoLayout(fit: layout.fit, zoom: zoom, aspect: layout.aspect, crop: layout.crop))
    }

    public func setAspect(_ aspect: AspectOverride) {
        var layout = videoLayout
        layout.aspect = aspect
        coordinator?.setVideoLayout(layout)
        showControls()
    }

    public func setCrop(_ crop: VideoCrop) {
        var layout = videoLayout
        layout.crop = crop
        coordinator?.setVideoLayout(layout)
        showControls()
    }

    /// Kept for next time, like the rest of the picture processing.
    public func setDolbyVision(_ enabled: Bool) {
        var processing = processing
        processing.dolbyVision = enabled
        setProcessing(processing)
    }

    public func toggleAmbientMode() {
        savePreferences { $0.ambientMode.toggle() }
        showControls()
    }

    public func setProcessing(_ processing: VideoProcessing) {
        coordinator?.setProcessing(processing)
        savePreferences { $0.processing = processing }
        showControls()
    }

    // MARK: Subtitles

    /// The media's own tracks, without files loaded into the engine (those are listed with the other files).
    public var embeddedSubtitleTracks: [MediaTrack] { state.embeddedSubtitleTracks.filter { !$0.isExternal } }
    public var subtitleStyle: SubtitleStyle { coordinator?.subtitleStyle ?? settings.player.subtitleStyle }

    /// The line to draw, or nil. Reads the engine clock through `state.position`, so it updates with playback.
    public var cueText: String? {
        guard case .external = subtitleChoice, engineDrawnOptionID == nil else { return nil }
        return timeline?.text(at: state.position, offset: subtitleOffset)
    }

    /// The styled cues to draw now (empty when the engine draws them, or for picture subtitles).
    public var activeCues: [SubtitleCue] {
        guard case .external = subtitleChoice, engineDrawnOptionID == nil else { return [] }
        return timeline?.cues(at: state.position, offset: subtitleOffset) ?? []
    }

    /// The picture subtitle (PGS) to draw now.
    public var activeBitmapCue: BitmapSubtitleCue? {
        guard case .external = subtitleChoice, engineDrawnOptionID == nil else { return nil }
        return bitmapTimeline?.cue(at: state.position, offset: subtitleOffset)
    }

    /// Whether timing can be shifted for the current choice: the overlay always can; the engine only for what it draws.
    public var canShiftSubtitles: Bool {
        switch subtitleChoice {
        case .off: return false
        case .embedded: return capabilities.contains(.subtitleDelay)
        case .external: return engineDrawnOptionID == nil || capabilities.contains(.subtitleDelay)
        }
    }

    public func selectSubtitle(_ choice: SubtitleChoice) async {
        userChoseSubtitle = true
        automaticChoice = nil
        showControls()
        await apply(choice)
    }

    /// The Mac's C key: the next subtitle choice in the menu's order, Off first, then the embedded tracks, then the external ones, and
    /// back to Off. A load still in flight counts as the choice, so presses during it keep advancing.
    public func cycleSubtitles() async {
        let choices: [SubtitleChoice] = [.off]
            + embeddedSubtitleTracks.map { SubtitleChoice.embedded($0.id) }
            + subtitleOptions.map { SubtitleChoice.external($0.id) }
        guard choices.count > 1 else { return }
        let current = choices.firstIndex(of: pendingChoice ?? subtitleChoice) ?? 0
        await selectSubtitle(choices[(current + 1) % choices.count])
    }

    public func adjustSubtitleOffset(by delta: TimeInterval) {
        let limit = Self.maximumSubtitleOffset
        subtitleOffset = min(limit, max(-limit, ((subtitleOffset + delta) * 10).rounded() / 10))
        syncEngineSubtitleDelay()
        showControls()
    }

    public func resetSubtitleOffset() {
        subtitleOffset = 0
        syncEngineSubtitleDelay()
    }

    public func setSubtitleStyle(_ style: SubtitleStyle) {
        coordinator?.setSubtitleStyle(style)
        savePreferences { $0.subtitleStyle = style }
    }

    /// A subtitle file the user opened (SRT, VTT, ASS/SSA, SUP). It joins the list and is selected.
    public func loadSubtitleFile(at url: URL) async {
        guard let copy = copyIn(url) else {
            subtitleStatus = "Couldn't open that file."
            return
        }
        let name = url.lastPathComponent
        let language = Self.language(inFileName: name)
        let option = SubtitleOption(id: "local|\(copy.path)", language: language ?? "und",
                                    title: "\(language.map(LanguageCodes.displayName) ?? url.deletingPathExtension().lastPathComponent) · File",
                                    url: copy, source: .local, format: .detect(copy, name: name))
        subtitleOptions = SubtitleService.merge(subtitleOptions, [option])
        await selectSubtitle(.external(option.id))
    }

    /// The engine's own delay follows the offset while the engine draws the current choice, and is zero otherwise.
    private func syncEngineSubtitleDelay() {
        guard capabilities.contains(.subtitleDelay) else { return }
        let engineDraws: Bool = switch subtitleChoice {
        case .embedded: true
        case .external: engineDrawnOptionID != nil
        case .off: false
        }
        let delay = engineDraws ? subtitleOffset : 0
        if coordinator?.subtitleDelay != delay { coordinator?.setSubtitleDelay(delay) }
    }

    private func apply(_ choice: SubtitleChoice) async {
        // An option the list does not have is ignored, before it can supersede a load in flight.
        if case .external(let id) = choice, !subtitleOptions.contains(where: { $0.id == id }) { return }
        // Each choice supersedes a subtitle load still in flight, so a load that returns late is dropped instead of overwriting the choice made since.
        subtitleGeneration += 1
        let generation = subtitleGeneration
        pendingChoice = nil
        hasSimplifiedStyling = false
        switch choice {
        case .off:
            clearOverlay()
            coordinator?.selectEmbeddedSubtitleTrack(id: nil)
            subtitleStatus = nil
            subtitleChoice = .off
        case .embedded(let id):
            clearOverlay()
            coordinator?.selectEmbeddedSubtitleTrack(id: id)
            subtitleStatus = nil
            subtitleChoice = .embedded(id)
        case .external(let id):
            guard let option = subtitleOptions.first(where: { $0.id == id }) else { return }
            // An engine that draws subtitle files draws them all: full ASS styling, pictures, its HDR brightness and its timing.
            if capabilities.contains(.engineSubtitles) {
                clearOverlay()
                engineDrawnOptionID = id
                coordinator?.addEngineSubtitle(engineSubtitle(for: option))
                subtitleStatus = nil
                subtitleChoice = .external(id)
                syncEngineSubtitleDelay()
                return
            }
            pendingChoice = choice
            coordinator?.selectEmbeddedSubtitleTrack(id: nil)
            subtitleStatus = "Loading subtitles…"
            do {
                let loaded = try await loadOverlay(option)
                guard generation == subtitleGeneration else { return }
                pendingChoice = nil
                guard !Task.isCancelled else { return }
                // The engine that started while this loaded draws files itself: it gets the file instead.
                if capabilities.contains(.engineSubtitles) {
                    await apply(choice)
                    return
                }
                engineDrawnOptionID = nil
                timeline = loaded.text
                bitmapTimeline = loaded.bitmap
                hasSimplifiedStyling = loaded.simplified && plan.retriesInFallbackEngine
                subtitleStatus = nil
                subtitleChoice = .external(id)
                syncEngineSubtitleDelay()
            } catch {
                guard generation == subtitleGeneration else { return }
                pendingChoice = nil
                clearOverlay()
                if case SubtitleError.bitmap = error, plan.retriesInFallbackEngine {
                    // VobSub has no decoder in the app: the advanced player draws it, from where the stream is now.
                    subtitleStatus = "Switching to the advanced player for picture subtitles…"
                    subtitleChoice = .external(id)
                    engineDrawnOptionID = id
                    await coordinator?.reopenInFallbackEngine()
                    if capabilities.contains(.engineSubtitles) {
                        coordinator?.addEngineSubtitle(engineSubtitle(for: option))
                        subtitleStatus = nil
                    } else {
                        engineDrawnOptionID = nil
                        subtitleStatus = "Couldn't show these subtitles."
                        subtitleChoice = .off
                    }
                    return
                }
                subtitleStatus = (error as? SubtitleError).map(Self.message) ?? "Couldn't load these subtitles."
                subtitleChoice = .off
            }
        }
    }

    private func clearOverlay() {
        timeline = nil
        bitmapTimeline = nil
        engineDrawnOptionID = nil
    }

    private static func message(_ error: SubtitleError) -> String {
        switch error {
        case .bitmap: "These are picture subtitles (VobSub), which need the advanced player."
        case .tooLarge: "This subtitle file is too large."
        case .empty, .unreadable: "Couldn't load these subtitles."
        }
    }

    /// Text files parse to cues; PGS files decode to pictures.
    private func loadOverlay(_ option: SubtitleOption) async throws -> (text: SubtitleTimeline?, bitmap: BitmapSubtitleTimeline?, simplified: Bool) {
        let data = try await services.subtitles.data(for: option, maxBytes: option.format == .pgs ? PGSDecoder.maximumBytes : SubtitleParser.largestAcceptedBytes)
        if option.format == .pgs || data.starts(with: Array("PG".utf8)) {
            let cues = try await Task.detached(priority: .userInitiated) { try PGSDecoder.decode(data) }.value
            guard !cues.isEmpty else { throw SubtitleError.empty }
            return (nil, BitmapSubtitleTimeline(cues: cues), false)
        }
        let parsed = try SubtitleParser.parse(data: data)
        return (SubtitleTimeline(cues: parsed.cues), nil, SubtitleParser.needsEngineRendering(parsed.cues, format: parsed.format))
    }

    /// Engines match their tracks by title, so two files with the same title get distinct ones.
    private func engineSubtitle(for option: SubtitleOption) -> ExternalSubtitle {
        let same = subtitleOptions.filter { $0.title == option.title }
        let title = same.count > 1 ? "\(option.title) (\((same.firstIndex(of: option) ?? 0) + 1))" : option.title
        let language = option.language == "und" ? nil : LanguageCodes.iso639_1(option.language) ?? option.language
        return ExternalSubtitle(url: option.url, title: title, language: language, headers: [:])
    }

    private func startSubtitles() {
        guard let first = plan.candidates.first else { return }
        lookedUpCandidates.insert(first.id)
        subtitleTask = Task { [weak self] in
            guard let self else { return }
            subtitleOptions = SubtitleService.merge(subtitleOptions, SubtitleService.options(from: first.subtitles))
            await applyDefaultSubtitle()
            await collect(services.subtitles.fetch(for: first, request: plan.request))
        }
    }

    private func collect(_ responses: AsyncStream<AddonResponse<[SubtitleItem]>>) async {
        for await response in responses {
            if let items = response.value {
                subtitleOptions = SubtitleService.merge(subtitleOptions, SubtitleService.options(from: items, addon: response.addon.name))
            }
            await applyDefaultSubtitle()
        }
    }

    /// Another stream took over: its own subtitles (bundled, and those addons match to its hash and file name) join the list.
    /// The list keeps what it had, so a choice already made stays available.
    private func lookUpSubtitles(for candidate: PlaybackCandidate) {
        guard lookedUpCandidates.insert(candidate.id).inserted else { return }
        lookupTasks.append(Task { [weak self] in
            guard let self else { return }
            subtitleOptions = SubtitleService.merge(subtitleOptions, SubtitleService.options(from: candidate.subtitles))
            await applyDefaultSubtitle()
            await collect(services.subtitles.fetch(for: candidate, request: plan.request))
        })
    }

    /// The new engine either draws files itself (the coordinator loads the current one into it again) or does not: then an engine-drawn
    /// file moves to the overlay. An overlay file moves into an engine that draws files, for its styling and HDR brightness.
    private func engineChanged() {
        guard case .external(let id) = subtitleChoice else { return }
        let engineDraws = capabilities.contains(.engineSubtitles)
        if (engineDrawnOptionID != nil) != engineDraws {
            let choice = subtitleChoice
            Task { [weak self] in await self?.apply(choice) }
        } else if engineDraws {
            engineDrawnOptionID = id
        }
    }

    private func tracksChanged() {
        // These snapshots change only with the track list, so a paused menu is
        // not re-laid out on every playback-clock tick.
        let audioRows = PlayerTrackPresentation.embedded(state.audioTracks, audio: true)
        let subtitleRows = PlayerTrackPresentation.embedded(embeddedSubtitleTracks)
        if audioTrackRows != audioRows { audioTrackRows = audioRows }
        if embeddedSubtitleRows != subtitleRows { embeddedSubtitleRows = subtitleRows }
        if audioTrackSelectionID != state.selectedAudioTrackID { audioTrackSelectionID = state.selectedAudioTrackID }
        if !userChoseAudio, let track = SubtitleDefaults.audioTrack(in: state.audioTracks, selected: state.selectedAudioTrackID,
                                                                    language: settings.player.audioLanguage) {
            coordinator?.selectAudioTrack(id: track.id)
        }
        Task { [weak self] in await self?.applyDefaultSubtitle() }
    }

    /// Picks subtitles from the Settings preferences until the listener chooses: language, Always or Forced only, SDH. An embedded track
    /// that turns up after a file was picked replaces it. A load already in flight for the pick is not repeated.
    private func applyDefaultSubtitle() async {
        guard !userChoseSubtitle, pendingChoice == nil || pendingChoice == automaticChoice else { return }
        let audioLanguage = state.audioTracks.first { $0.id == state.selectedAudioTrackID }?.language
        guard let pick = SubtitleDefaults.choice(embedded: embeddedSubtitleTracks, external: subtitleOptions, language: settings.subtitleLanguage,
                                                 audioLanguage: audioLanguage, mode: settings.player.subtitleMode, prefersSDH: settings.player.prefersSDH),
              pick != automaticChoice, subtitleChoice == automaticChoice ?? .off else { return }
        // A file picked first gives way only to an embedded track.
        if automaticChoice != nil, case .external = pick { return }
        automaticChoice = pick
        await apply(pick)
    }

    /// Waits for the subtitle lookup (used by tests).
    public func waitForSubtitles() async {
        await subtitleTask?.value
        for task in lookupTasks { await task.value }
    }

    // MARK: OpenSubtitles

    public var hasOpenSubtitlesKey: Bool { !(settings.openSubtitlesAPIKey ?? "").isEmpty }

    /// Searches OpenSubtitles.com for this title (and episode) in the preferred subtitle language, matched to the stream's hash when known.
    public func searchOpenSubtitles() async {
        guard let client = openSubtitles() else {
            openSubtitlesStatus = "Add an OpenSubtitles API key in Settings to search."
            return
        }
        guard let imdb = plan.request.id.split(separator: ":").first.map(String.init), imdb.hasPrefix("tt") else {
            openSubtitlesStatus = "OpenSubtitles needs an IMDb title, which this one doesn't have."
            return
        }
        isSearchingOpenSubtitles = true
        openSubtitlesStatus = nil
        defer { isSearchingOpenSubtitles = false }
        let languages = [settings.subtitleLanguage, settings.player.audioLanguage, "eng"].compactMap { $0 }.compactMap(LanguageCodes.iso639_1)
        let hash = await currentMovieHash()
        do {
            openSubtitlesResults = try await client.search(imdbID: imdb, season: plan.request.season, episode: plan.request.episode,
                                                           languages: Array(Set(languages)), movieHash: hash)
            if openSubtitlesResults.isEmpty { openSubtitlesStatus = "No subtitles found on OpenSubtitles." }
        } catch {
            openSubtitlesResults = []
            openSubtitlesStatus = Self.message(error as? OpenSubtitlesError)
        }
    }

    /// Downloads one result; it joins the list and is selected.
    public func downloadOpenSubtitle(_ result: OpenSubtitlesResult) async {
        guard let client = openSubtitles() else { return }
        openSubtitlesStatus = "Downloading…"
        do {
            let download = try await client.download(result)
            let language = LanguageCodes.normalise(result.language)
            let flags = [result.isForeignPartsOnly ? "Forced" : nil, result.isHearingImpaired ? "SDH" : nil, result.matchesHash ? "Matched" : nil]
            let title = ([LanguageCodes.displayName(language)] + flags.compactMap { $0 } + ["OpenSubtitles"]).joined(separator: " · ")
            let option = SubtitleOption(id: "opensubtitles|\(result.fileID)", language: language, title: title, url: download.url,
                                        source: .openSubtitles, format: .detect(download.url, name: download.fileName ?? result.fileName),
                                        isForced: result.isForeignPartsOnly, isHearingImpaired: result.isHearingImpaired)
            subtitleOptions = SubtitleService.merge(subtitleOptions, [option])
            openSubtitlesStatus = download.remaining.map { "\($0) downloads left today." }
            await selectSubtitle(.external(option.id))
        } catch {
            openSubtitlesStatus = Self.message(error as? OpenSubtitlesError)
        }
    }

    private func openSubtitles() -> OpenSubtitlesClient? {
        guard let key = settings.openSubtitlesAPIKey, !key.isEmpty else { return nil }
        return OpenSubtitlesClient(client: services.client, credentials: OpenSubtitlesCredentials(
            apiKey: key, username: settings.openSubtitlesUsername, password: settings.openSubtitlesPassword))
    }

    private func currentMovieHash() async -> String? {
        guard let candidate = coordinator?.current ?? plan.candidates.first else { return nil }
        if let hash = candidate.videoHash { return hash }
        guard let url = candidate.url, !url.isFileURL else { return nil }
        return await MovieHash.compute(url: url, headers: candidate.headers, size: candidate.videoSize, client: services.client)
    }

    private static func message(_ error: OpenSubtitlesError?) -> String {
        switch error {
        case .missingAPIKey: "Add an OpenSubtitles API key in Settings."
        case .unauthorized: "OpenSubtitles didn't accept the API key or login in Settings."
        case .quotaExceeded(let reset): "The OpenSubtitles download limit is used up\(reset.map { " until \($0)" } ?? " for today")."
        case .notFound: "OpenSubtitles doesn't have that file any more."
        case .server, .decoding, nil: "OpenSubtitles couldn't be reached. Try again."
        }
    }

    // MARK: Files and preferences

    /// A copy the player can read for as long as it plays: files from the document picker are security-scoped.
    private func copyIn(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("blusion-\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            temporaryFiles.append(copy)
            return copy
        } catch {
            return nil
        }
    }

    /// "Movie.2020.en.srt", "Movie.English.forced.ass" → the language they name.
    static func language(inFileName name: String) -> String? {
        let parts = (name as NSString).deletingPathExtension.split(whereSeparator: { ".-_ ".contains($0) }).map(String.init)
        for part in parts.reversed().prefix(3) where part.count >= 2 {
            let code = LanguageCodes.normalise(part)
            if LanguageCodes.iso639_1(code) != nil { return code }
        }
        return nil
    }

    /// Player changes the listener makes are their new defaults (Settings shows them too).
    /// Saves run one after another, so quick changes in a row cannot overwrite each other.
    private func savePreferences(_ change: @escaping (inout PlayerPreferences) -> Void) {
        change(&settings.player)
        let store = services.settings
        let previous = saveTask
        saveTask = Task {
            await previous?.value
            var saved = await store.load()
            change(&saved.player)
            await store.save(saved)
        }
    }

    /// Waits for preference saves (used by tests).
    public func waitForSavedPreferences() async {
        await saveTask?.value
    }

    // MARK: Next episode

    /// Streams for the next episode, auto-selecting one in the same bingeGroup as the current stream (PLAN M4).
    /// nil when there is no next episode or no matching stream: the caller then shows the picker for it.
    public func prepareNextEpisode() async -> PlaybackPlan? {
        guard let next = plan.request.nextRequest else { return nil }
        let picker = StreamPickerViewModel(request: next, services: services)
        defer { picker.cancelLoading() }
        // Every addon's answers within the window, as before: the stream continuing this one may come from a slower addon.
        await picker.loadForAutomaticSelection(stopsForWaitTarget: false)
        let context = plan.candidates.indices.contains(coordinator?.candidateIndex ?? 0) ? plan.candidates[coordinator?.candidateIndex ?? 0].bingeContext : nil
        if case .play(let nextPlan)? = await picker.bingeChoice(continuing: context) { return nextPlan }
        return nil
    }
}

extension PlaybackRoute {
    var isNative: Bool {
        if case .native = self { return true }
        return false
    }
}
