import Foundation
import Observation
import StremioKit

/// Plays a `PlaybackPlan`: creates the right engine for each candidate, and moves to the next candidate when one fails to start,
/// stalls at startup, or fails mid-stream (resuming where it stopped). Engine-agnostic: it only sees `PlaybackEngine`.
@MainActor
@Observable
public final class PlaybackCoordinator {
    public enum Phase: Equatable {
        case idle
        /// Waiting for the current candidate to start.
        case starting
        case playing
        /// Every candidate failed.
        case exhausted
        case finished
    }

    public struct FailedAttempt: Equatable, Identifiable {
        public let id: String
        public let title: String
        public let failure: PlaybackFailure
    }

    public private(set) var phase: Phase = .idle
    public private(set) var state = PlaybackState()
    public private(set) var current: PlaybackCandidate?
    public private(set) var candidateIndex = 0
    public private(set) var failedAttempts: [FailedAttempt] = []
    /// A short, human-readable line about what just happened ("…didn't work. Trying the next stream.").
    public private(set) var notice: String?
    /// The engine currently in use; the video surface attaches to it.
    public private(set) var engine: (any PlaybackEngine)?
    public private(set) var engineGeneration = 0
    /// The listener's volume and mute, for the UI to show.
    public private(set) var volume: Float = 1
    public private(set) var isMuted = false
    /// What the listener has chosen, once they have chosen it. Only these carry over to a new engine, so an engine keeps its own
    /// defaults until then (a snapshot run mutes its AVEngine, for example).
    private var chosenVolume: Float?
    private var chosenMuted: Bool?
    /// Everything else the listener sets during playback. It all carries over to a replacement engine (a fallback retry, the next
    /// candidate, a reconnect), so moving engines keeps what they were watching the way they had it.
    public private(set) var rate: Float = 1
    public private(set) var videoLayout: VideoLayout
    public private(set) var processing: VideoProcessing
    public private(set) var subtitleStyle: SubtitleStyle
    public private(set) var audioDelay: TimeInterval = 0
    /// Delay of the subtitles the engine draws. The app's own subtitles have their own offset (PlayerViewModel).
    public private(set) var subtitleDelay: TimeInterval = 0
    private var audioPick: TrackPick?
    private var subtitlePick: SubtitlePick = .unset
    /// Files loaded into the engine, loaded again into the next one when it can take them.
    private var engineSubtitles: [ExternalSubtitle] = []
    /// The files this engine has been given, listed or not yet.
    private var loadedIntoEngine: Set<ExternalSubtitle> = []
    private var externalAudio: [(url: URL, title: String)] = []
    /// Per engine: the loaded files went back in, and the track choices were made again once the tracks appeared.
    private var restoredFiles = false
    private var restoredTracks = false
    /// The candidate index that has already been reloaded in place after a mid-stream drop (once per candidate).
    private var reconnectedIndex: Int?

    public let plan: PlaybackPlan
    public var onEnded: (@MainActor () -> Void)?
    /// Called when another candidate (another stream) starts loading, so stream-specific extras such as subtitles can be looked up again.
    public var onCandidateChange: (@MainActor (PlaybackCandidate) -> Void)?
    /// Called when a new engine takes over (another stream, a fallback retry, a reconnect), before it loads.
    public var onEngineChange: (@MainActor () -> Void)?
    /// Called when the engine's audio or subtitle track list changes.
    public var onTracksChange: (@MainActor () -> Void)?

    private let makeEngine: @MainActor (PlaybackCandidate) -> (any PlaybackEngine)?
    private let resumeFrom: TimeInterval
    private let startupTimeout: Duration
    private let stallTimeout: Duration
    private let progress: ProgressSession?
    private var observer: Task<Void, Never>?
    private var stallTimer: Task<Void, Never>?
    private var startContinuation: CheckedContinuation<Bool, Never>?
    private var hasStartedCurrent = false
    /// How the current candidate failed before it started, if it did. `tryCandidate` decides what happens next.
    private var startFailure: PlaybackFailure?
    private var lastPosition: TimeInterval = 0
    private var stopped = false

    public init(plan: PlaybackPlan, resumeFrom: TimeInterval = 0, startupTimeout: Duration = .seconds(20),
                stallTimeout: Duration = .seconds(20), progress: ProgressSession? = nil, layout: VideoLayout = VideoLayout(),
                processing: VideoProcessing = VideoProcessing(), subtitleStyle: SubtitleStyle = SubtitleStyle(),
                makeEngine: @escaping @MainActor (PlaybackCandidate) -> (any PlaybackEngine)?) {
        self.plan = plan
        self.videoLayout = layout
        self.processing = processing
        self.subtitleStyle = subtitleStyle
        self.resumeFrom = resumeFrom
        self.startupTimeout = startupTimeout
        self.stallTimeout = stallTimeout
        self.progress = progress
        self.makeEngine = makeEngine
    }

    // MARK: Lifecycle

    /// Starts the first candidate and returns when something is playing, or when every candidate has failed.
    public func start() async {
        guard phase == .idle else { return }
        stopped = false
        phase = .starting
        await tryCandidate(at: 0, startPosition: resumeFrom)
    }

    /// "Try the next stream" from the UI.
    public func advance() async {
        guard !stopped else { return }
        guard candidateIndex + 1 < plan.candidates.count else {
            notice = "There are no other streams to try."   // keep what is playing
            return
        }
        await moveOn(startPosition: lastPosition)
    }

    /// A stream explicitly chosen from the player menu. Opening the menu has no playback side effects.
    public func selectCandidate(at index: Int) async {
        guard !stopped, plan.candidates.indices.contains(index), index != candidateIndex else { return }
        notice = nil
        await tryCandidate(at: index, startPosition: lastPosition)
    }

    public func stop() async {
        stopped = true
        observer?.cancel()
        stallTimer?.cancel()
        resolveStart(false)
        engine?.stop()
        await progress?.finish()
        if phase != .exhausted { phase = .finished }
    }

    // MARK: Transport

    public func play() { engine?.play() }
    public func pause() { engine?.pause() }
    /// A stall is still playing as far as the viewer is concerned, so the button pauses it rather than asking to play again.
    public func togglePlayPause() { state.isPlayingOrBuffering ? pause() : play() }
    public func seek(to position: TimeInterval) async { await engine?.seek(to: max(0, position)) }
    public func skip(by seconds: TimeInterval) async {
        let target = state.position + seconds
        await seek(to: state.duration.map { min(target, max(0, $0 - 1)) } ?? target)
    }
    public func setRate(_ rate: Float) {
        self.rate = rate
        engine?.setRate(rate)
    }
    public func setVolume(_ volume: Float) {
        self.volume = min(1, max(0, volume))
        chosenVolume = self.volume
        engine?.setVolume(self.volume)
    }
    public func setMuted(_ muted: Bool) {
        isMuted = muted
        chosenMuted = muted
        engine?.setMuted(muted)
    }
    public func selectAudioTrack(id: String?) {
        if let id, let track = state.audioTracks.first(where: { $0.id == id }) { audioPick = TrackPick(track) }
        engine?.selectAudioTrack(id: id)
    }

    public func selectEmbeddedSubtitleTrack(id: String?) {
        if let id {
            if let track = state.embeddedSubtitleTracks.first(where: { $0.id == id }) { subtitlePick = .track(TrackPick(track)) }
        } else {
            subtitlePick = .off
        }
        engine?.selectEmbeddedSubtitleTrack(id: id)
    }

    // MARK: Engine extras (see `EngineCapabilities`)

    public var capabilities: EngineCapabilities { engine?.capabilities ?? [] }
    public func statistics() -> PlaybackStatistics? { engine?.statistics() }

    public func setVideoLayout(_ layout: VideoLayout) {
        videoLayout = layout
        engine?.apply(layout: layout)
    }

    public func setProcessing(_ processing: VideoProcessing) {
        self.processing = processing
        engine?.apply(processing: processing)
    }

    public func setSubtitleStyle(_ style: SubtitleStyle) {
        subtitleStyle = style
        engine?.apply(subtitleStyle: style)
    }

    public func setAudioDelay(_ seconds: TimeInterval) {
        audioDelay = seconds
        engine?.setAudioDelay(seconds)
    }

    public func setSubtitleDelay(_ seconds: TimeInterval) {
        subtitleDelay = seconds
        engine?.setSubtitleDelay(seconds)
    }

    /// Loads a subtitle file into the engine, which draws it with its full styling. Only for engines with `.engineSubtitles`.
    public func addEngineSubtitle(_ subtitle: ExternalSubtitle) {
        guard capabilities.contains(.engineSubtitles) else { return }
        subtitlePick = .track(TrackPick(title: subtitle.title, language: subtitle.language, isExternal: true))
        // Loaded already: select it again rather than loading a second copy.
        if let loaded = state.embeddedSubtitleTracks.first(where: { $0.isExternal && $0.title == subtitle.title }) {
            engine?.selectEmbeddedSubtitleTrack(id: loaded.id)
            return
        }
        // Given to the engine but not listed yet: the choice is made when its track appears.
        if loadedIntoEngine.contains(subtitle) {
            restoredTracks = false
            return
        }
        if !engineSubtitles.contains(subtitle) { engineSubtitles.append(subtitle) }
        // Before the media has loaded, `restoreChoices` adds it with the rest.
        if restoredFiles {
            loadedIntoEngine.insert(subtitle)
            engine?.addExternalSubtitle(subtitle)
        }
    }

    /// Plays an audio file alongside the video. Only for engines with `.externalAudio`.
    public func addExternalAudio(url: URL, title: String) {
        guard capabilities.contains(.externalAudio) else { return }
        externalAudio.append((url, title))
        audioPick = TrackPick(title: title, language: nil, isExternal: true)
        if restoredFiles { engine?.addExternalAudio(url: url, title: title) }
    }

    /// Plays the current stream again in the full-featured fallback engine (mpv), from where it is now: for what only that engine can do,
    /// such as styled or picture subtitles. A stream on AVPlayer moves there, and so does one on the first fallback engine. Does nothing
    /// when the stream already plays there, when the current engine draws subtitles itself, or when no fallback engine is available.
    public func reopenInFallbackEngine() async {
        guard !stopped, plan.retriesInFallbackEngine, let candidate = current, let url = candidate.url,
              !capabilities.contains(.engineSubtitles) else { return }
        let target = PlaybackRoute.fallback(url, .fullFeaturedEngine)
        guard candidate.route != target else { return }
        notice = "Switching to the advanced player…"
        await tryCandidate(at: candidateIndex, startPosition: lastPosition, routeOverride: target)
    }

    // MARK: Candidates

    /// `failure` is set when this is a retry: the previous engine could not start the stream, so it plays on `routeOverride` (see
    /// `retryRoute`). If no engine can be made for the retry, the failure given before is reported, as the first attempt would.
    /// `routeOverride` plays the candidate on another route than the plan's: a reconnect keeps the route it had, a retry or a switch to
    /// the full-featured engine asks for that one.
    private func tryCandidate(at index: Int, startPosition: TimeInterval, retryingAfter failure: PlaybackFailure? = nil,
                              routeOverride: PlaybackRoute? = nil) async {
        guard !stopped else { return }
        engineGeneration += 1
        resolveStart(false)
        stallTimer?.cancel()
        stallTimer = nil
        guard index < plan.candidates.count else {
            observer?.cancel()
            engine?.stop()
            phase = .exhausted
            notice = plan.candidates.isEmpty ? "There is nothing to play." : "None of the streams could be played."
            return
        }
        if index != candidateIndex { reconnectedIndex = nil }
        candidateIndex = index
        var candidate = plan.candidates[index]
        if let routeOverride {
            candidate = candidate.rerouted(to: routeOverride)
        }
        let changedStream = current?.id != candidate.id
        current = candidate
        if changedStream { onCandidateChange?(candidate) }

        guard let engine = makeEngine(candidate), let url = candidate.url else {
            let reported = failure ?? PlaybackFailure(.noEngine, "No player is available for this stream.")
            // The first fallback engine cannot be made: the full-featured one gets the stream, once.
            if let backup = backupRoute(for: candidate) {
                await tryCandidate(at: index, startPosition: startPosition, retryingAfter: reported, routeOverride: backup)
                return
            }
            recordFailure(candidate, reported)
            await moveOn(startPosition: startPosition)
            return
        }
        observer?.cancel()
        self.engine?.stop()
        self.engine = engine
        if let chosenVolume { engine.setVolume(chosenVolume) }
        if let chosenMuted { engine.setMuted(chosenMuted) }
        applySession(to: engine)
        onEngineChange?()
        phase = .starting
        state = engine.state
        hasStartedCurrent = false
        startFailure = nil
        lastPosition = startPosition

        let stream = engine.makeStateStream()
        let generation = engineGeneration
        observer = Task { [weak self] in
            for await next in stream {
                guard let self, !Task.isCancelled, self.engineGeneration == generation else { return }
                self.handle(next)
            }
        }
        engine.load(PlaybackItem(url: url, headers: candidate.headers, title: candidate.title, startPosition: startPosition, filename: candidate.filename))
        engine.play()

        let started = await waitForStart()
        guard !stopped, generation == engineGeneration else { return }
        if started {
            if phase != .finished { phase = .playing }
            notice = failedAttempts.isEmpty ? nil : notice
        } else if !hasStartedCurrent {
            // AVPlayer cannot open a codec it lacks (DTS in MP4, AV1 on older chips): the same stream goes to the fallback engine. Each
            // engine gets one try at the stream, down the ladder in `retryRoute`.
            if let pending = startFailure, let retry = retryRoute(for: candidate, after: pending) {
                await tryCandidate(at: index, startPosition: startPosition, retryingAfter: pending, routeOverride: retry)
                return
            }
            // A start failure was recorded in handle(); only a timeout is left to record here.
            if startFailure == nil { recordFailure(candidate, PlaybackFailure(.timeout, "The stream took too long to start.")) }
            await moveOn(startPosition: startPosition)
        }
    }

    private func moveOn(startPosition: TimeInterval) async {
        let next = candidateIndex + 1
        if next < plan.candidates.count {
            notice = "“\(current?.title ?? "That stream")” didn't work. Trying “\(plan.candidates[next].title)”…"
        }
        await tryCandidate(at: next, startPosition: startPosition)
    }

    private func recordFailure(_ candidate: PlaybackCandidate, _ failure: PlaybackFailure) {
        failedAttempts.append(FailedAttempt(id: candidate.id, title: candidate.title, failure: failure))
    }

    /// Resolves true on playback, false on failure or timeout.
    private func waitForStart() async -> Bool {
        let timeout = startupTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.resolveStart(false)
        }
        let started = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if hasStartedCurrent { continuation.resume(returning: true) } else { startContinuation = continuation }
        }
        timer.cancel()
        return started
    }

    private func resolveStart(_ started: Bool) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(returning: started)
    }

    private func handle(_ next: PlaybackState) {
        let previous = state
        state = next
        if next.audioTracks != previous.audioTracks || next.embeddedSubtitleTracks != previous.embeddedSubtitleTracks
            || next.selectedAudioTrackID != previous.selectedAudioTrackID {
            onTracksChange?()
        }
        if next.hasStarted, !hasStartedCurrent {
            hasStartedCurrent = true
            resolveStart(true)
        }
        if hasStartedCurrent, next.status == .playing || next.status == .paused || next.status == .buffering {
            lastPosition = next.position
        }
        if hasStartedCurrent { progress?.observe(position: next.position, duration: next.duration) }
        restoreChoices(in: next)
        if hasStartedCurrent, next.status == .playing || next.status == .buffering {
            // A buffer still filling is progress too: a high-bitrate remux can wait a long time for data without being stuck.
            if stallTimer == nil || next.position != previous.position || next.bufferedUntil > previous.bufferedUntil { watchForStall() }
        } else {
            stallTimer?.cancel()
            stallTimer = nil
        }

        switch next.status {
        case .failed(let failure):
            guard let candidate = current else { return }
            if hasStartedCurrent {
                // Failed mid-stream: reload it where it stopped once, as a dropped connection often recovers; then the next stream.
                if canReconnect(after: failure) {
                    reconnect()
                    return
                }
                recordFailure(candidate, failure)
                Task { [weak self] in await self?.moveOn(startPosition: self?.lastPosition ?? 0) }
            } else {
                // Recorded now, unless tryCandidate retries the stream in another engine: then the retry decides what is recorded.
                if retryRoute(for: candidate, after: failure) == nil { recordFailure(candidate, failure) }
                startFailure = failure
                resolveStart(false)
            }
        case .ended:
            phase = .finished
            Task { [weak self] in
                await self?.progress?.finish()
                self?.onEnded?()
            }
        default:
            break
        }
    }

    /// The route a stream that could not start is retried on, or nil when it is not retried. AVPlayer's format failure goes to the first
    /// fallback engine. A format, other or no-engine failure in the first fallback engine goes to the full-featured one. Anything else is
    /// final: another engine would fail the same way for a network, timeout, unauthorized or not-found stream, and the full-featured
    /// engine is never retried.
    private func retryRoute(for candidate: PlaybackCandidate, after failure: PlaybackFailure) -> PlaybackRoute? {
        switch candidate.route {
        case .native(let url):
            guard plan.retriesInFallbackEngine, failure.kind == .format else { return nil }
            return .fallback(url, .unknownFormat)
        case .fallback:
            guard let backup = backupRoute(for: candidate) else { return nil }
            switch failure.kind {
            case .format, .other, .noEngine: return backup
            case .network, .timeout, .unauthorized, .notFound: return nil
            }
        case .handoff, .external, .unsupported, .hidden:
            return nil
        }
    }

    /// The full-featured engine for a stream on the first fallback engine, when the plan has a backup engine. nil otherwise.
    private func backupRoute(for candidate: PlaybackCandidate) -> PlaybackRoute? {
        guard plan.retriesInBackupEngine, case .fallback(let url, let reason) = candidate.route, reason != .fullFeaturedEngine else { return nil }
        return .fallback(url, .fullFeaturedEngine)
    }

    private func watchForStall() {
        stallTimer?.cancel()
        let generation = engineGeneration
        let timeout = stallTimeout
        stallTimer = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, !self.stopped, self.engineGeneration == generation,
                  let candidate = self.current else { return }
            let failure = PlaybackFailure(.timeout, "Playback stopped making progress.")
            if self.canReconnect(after: failure) {
                self.reconnect()
                return
            }
            self.recordFailure(candidate, failure)
            await self.moveOn(startPosition: self.lastPosition)
        }
    }

    // MARK: Continuity

    private func canReconnect(after failure: PlaybackFailure) -> Bool {
        guard reconnectedIndex != candidateIndex else { return false }
        switch failure.kind {
        case .network, .timeout, .other: return true
        case .format, .unauthorized, .notFound, .noEngine: return false
        }
    }

    /// The same stream on the same route, from where it stopped.
    private func reconnect() {
        reconnectedIndex = candidateIndex
        notice = "The connection dropped. Reconnecting…"
        let route = current?.route
        let index = candidateIndex
        let position = lastPosition
        Task { [weak self] in await self?.tryCandidate(at: index, startPosition: position, routeOverride: route) }
    }

    /// What can be set before the media loads.
    private func applySession(to engine: any PlaybackEngine) {
        restoredFiles = false
        restoredTracks = false
        loadedIntoEngine = []
        if rate != 1 { engine.setRate(rate) }
        engine.apply(layout: videoLayout)
        engine.apply(processing: processing)
        engine.apply(subtitleStyle: subtitleStyle)
        if audioDelay != 0 { engine.setAudioDelay(audioDelay) }
        if subtitleDelay != 0 { engine.setSubtitleDelay(subtitleDelay) }
    }

    /// What needs the loaded media: the files loaded into the last engine, then the track choices, matched by language and name
    /// because each engine numbers its tracks its own way.
    private func restoreChoices(in next: PlaybackState) {
        guard let engine else { return }
        if !restoredFiles, next.status == .ready || next.status == .playing || next.status == .paused || next.status == .buffering {
            restoredFiles = true
            if engine.capabilities.contains(.engineSubtitles) {
                loadedIntoEngine.formUnion(engineSubtitles)
                engineSubtitles.forEach(engine.addExternalSubtitle)
            }
            if engine.capabilities.contains(.externalAudio) { externalAudio.forEach { engine.addExternalAudio(url: $0.url, title: $0.title) } }
        }
        guard restoredFiles, !restoredTracks, !next.audioTracks.isEmpty || !next.embeddedSubtitleTracks.isEmpty else { return }
        // Files re-added a moment ago may not be listed yet; wait for them before choosing.
        let expectsFiles = engine.capabilities.contains(.engineSubtitles) && !engineSubtitles.isEmpty
        if expectsFiles, !next.embeddedSubtitleTracks.contains(where: \.isExternal) { return }
        restoredTracks = true
        if let audioPick, let track = audioPick.match(in: next.audioTracks), track.id != next.selectedAudioTrackID {
            engine.selectAudioTrack(id: track.id)
        }
        switch subtitlePick {
        case .unset:
            break
        case .off:
            if next.selectedEmbeddedSubtitleID != nil { engine.selectEmbeddedSubtitleTrack(id: nil) }
        case .track(let pick):
            if let track = pick.match(in: next.embeddedSubtitleTracks), track.id != next.selectedEmbeddedSubtitleID {
                engine.selectEmbeddedSubtitleTrack(id: track.id)
            }
        }
    }
}

/// A track choice that survives a change of engine: engines number tracks differently, so it is matched by what the track is.
struct TrackPick: Equatable {
    let title: String
    let language: String?
    let isForced: Bool
    let isHearingImpaired: Bool
    let isExternal: Bool

    init(_ track: MediaTrack) {
        self.init(title: track.title, language: track.language, isForced: track.isForced, isHearingImpaired: track.isHearingImpaired,
                  isExternal: track.isExternal)
    }

    init(title: String, language: String?, isForced: Bool = false, isHearingImpaired: Bool = false, isExternal: Bool = false) {
        self.title = title
        self.language = language
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.isExternal = isExternal
    }

    /// The same title and language, else the same language and kind (forced, SDH), else the same language.
    func match(in tracks: [MediaTrack]) -> MediaTrack? {
        let language = language.map(LanguageCodes.normalise)
        let sameLanguage = tracks.filter { track in
            guard let language else { return track.language == nil }
            return track.language.map(LanguageCodes.normalise) == language
        }
        return tracks.first { $0.title == title && $0.language.map(LanguageCodes.normalise) == language }
            ?? (isExternal ? tracks.first { $0.isExternal && $0.title == title } : nil)
            ?? sameLanguage.first { $0.isForced == isForced && $0.isHearingImpaired == isHearingImpaired }
            ?? (language == nil ? nil : sameLanguage.first)
    }
}

enum SubtitlePick: Equatable {
    case unset, off
    case track(TrackPick)
}
