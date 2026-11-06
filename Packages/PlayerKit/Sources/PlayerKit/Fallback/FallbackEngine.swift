#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
#endif
import Foundation
import StremioKit

/// An engine that renders into a view of its own (as opposed to AVPlayer's layer). The UI embeds `videoSurface` (a `UIView`) in the player.
/// Typed `AnyObject` so PlayerKit needs no UIKit.
@MainActor
public protocol VideoSurfaceProviding: AnyObject {
    var videoSurface: AnyObject { get }
}

public enum FallbackEvent: Sendable, Equatable {
    case preparing(PlaybackPreparation.Stage)
    /// Bits per second from the source, nil when unavailable (never a local loopback transfer rate).
    case networkBitrate(Double?)
    case loaded(duration: TimeInterval?, audio: [MediaTrack], subtitles: [MediaTrack], selectedAudio: String?, selectedSubtitle: String?)
    /// The length became known (or changed) after `loaded`. A player can learn it a moment after the load finishes.
    case duration(TimeInterval)
    /// The video output has presented its first frame for this load.
    case videoFrameReady
    case position(TimeInterval)
    case buffered(TimeInterval)
    case paused(Bool)
    /// The demuxer is waiting for data.
    case buffering(Bool)
    /// The track list changed after loading (a subtitle or audio file was added, or the selection changed).
    case tracks(audio: [MediaTrack], subtitles: [MediaTrack], selectedAudio: String?, selectedSubtitle: String?)
    case chapters([Chapter])
    case ended
    case failed(PlaybackFailure)
}

/// The small surface a third-party player (MPVKit, ADR-006) must provide. Everything library-specific lives behind this protocol,
/// so the engine, its state mapping and its tests need no third-party code.
@MainActor
public protocol FallbackBackend: AnyObject {
    var name: String { get }
    var videoSurface: AnyObject { get }
    /// One stream for the backend's lifetime.
    func makeEventStream() -> AsyncStream<FallbackEvent>
    /// Loads paused; the engine calls `setPaused(false)` to start.
    func load(url: URL, headers: [String: String], startPosition: TimeInterval)
    func setPaused(_ paused: Bool)
    func seek(to position: TimeInterval) async
    func setRate(_ rate: Float)
    /// The fastest rate the backend plays cleanly (`PlaybackEngine.maximumRate`).
    var maximumRate: Float { get }
    /// 0 (silent) to 1 (full).
    func setVolume(_ volume: Float)
    func setMuted(_ muted: Bool)
    func selectAudio(id: String?)
    func selectSubtitle(id: String?)
    func shutdown()

    var capabilities: EngineCapabilities { get }
    func setSubtitleDelay(_ seconds: TimeInterval)
    func setAudioDelay(_ seconds: TimeInterval)
    /// Loads and selects the file; the backend then reports `.tracks` with it.
    func addSubtitle(_ subtitle: ExternalSubtitle)
    func addAudio(url: URL, title: String)
    func apply(layout: VideoLayout)
    func apply(processing: VideoProcessing)
    func apply(subtitleStyle: SubtitleStyle)
    func statistics() -> PlaybackStatistics
    /// The first start of each load waits for this much in hand (`StartCushion`), measured by `bufferedAhead`. nil starts at once.
    var startCushion: StartCushion? { get }
    /// Seconds buffered ahead of the playhead, for the start cushion; nil when the backend cannot say, and then the start does not wait.
    var bufferedAhead: TimeInterval? { get }
    /// The raw measurement for UI, including fully downloaded remaining media. Missing values must stay nil.
    var preparationBufferedAhead: TimeInterval? { get }
}

public extension FallbackBackend {
    var name: String { "Advanced player" }
    var capabilities: EngineCapabilities { [] }
    var maximumRate: Float { 2 }
    func setSubtitleDelay(_ seconds: TimeInterval) {}
    func setAudioDelay(_ seconds: TimeInterval) {}
    func addSubtitle(_ subtitle: ExternalSubtitle) {}
    func addAudio(url: URL, title: String) {}
    func apply(layout: VideoLayout) {}
    func apply(processing: VideoProcessing) {}
    func apply(subtitleStyle: SubtitleStyle) {}
    func statistics() -> PlaybackStatistics { PlaybackStatistics(engine: "Fallback") }
    var startCushion: StartCushion? { nil }
    var bufferedAhead: TimeInterval? { nil }
    var preparationBufferedAhead: TimeInterval? { bufferedAhead }
}

/// `PlaybackEngine` for MKV, AVI, DTS and everything else AVPlayer cannot open (PLAN §4, M6).
@MainActor
public final class FallbackEngine: PlaybackEngine, VideoSurfaceProviding {
    public private(set) var state = PlaybackState()

    private let backend: any FallbackBackend
    private let broadcaster = PlaybackStateBroadcaster()
    private var eventTask: Task<Void, Never>?

    /// Where the current load stands. A failure holds until the next load; a stop is final.
    private enum Phase: Equatable {
        /// Sent to the backend and not loaded yet. A cushioned start (`FallbackBackend.startCushion`) is decided once it has loaded.
        case loading(cushioned: Bool)
        /// Loaded, with the cushioned start not decided yet: it is once Play is asked for.
        case awaitingStart
        /// Loaded, with the start held until the backend has its cushion in hand or the wait runs out. `firstFrame`: the first frame
        /// came meanwhile; it is shown when playback starts, so the startup spinner covers the wait.
        case holding(firstFrame: Bool)
        /// Let through: playing, paused or buffering, as the backend reports.
        case started
        /// Played to the end. Play, or a seek back from the end, leaves it.
        case ended
        case failed(PlaybackFailure)
        case stopped
    }
    private var phase = Phase.loading(cushioned: false)
    /// What the backend last reported.
    private var isPaused = true
    private var isBuffering = false
    /// Playback has run since the load, so a pause reads as paused rather than ready.
    private var hasPlayed = false
    private var startHold: Task<Void, Never>?
    /// Play was asked for and pause has not been since: what the start does once it is let through.
    private var wantsPlay = false
    private var loadBegan = ContinuousClock.now

    /// The backend has reported the load (and it has not failed or stopped since).
    private var isLoaded: Bool {
        switch phase {
        case .awaitingStart, .holding, .started, .ended: true
        case .loading, .failed, .stopped: false
        }
    }

    private var isHolding: Bool {
        if case .holding = phase { return true }
        return false
    }

    /// The start is let through: no cushion to wait for, or its wait is over.
    private var isStartOpen: Bool {
        switch phase {
        case .loading(cushioned: false), .started, .ended: true
        default: false
        }
    }

    public init(backend: any FallbackBackend) {
        self.backend = backend
        let events = backend.makeEventStream()
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled, self.phase != .stopped else { return }
                self.handle(event)
            }
        }
    }

    public var videoSurface: AnyObject { backend.videoSurface }

    public func makeStateStream() -> AsyncStream<PlaybackState> { broadcaster.makeStream(current: state) }

    // MARK: PlaybackEngine

    public func load(_ item: PlaybackItem) {
        // A stopped engine has shut its backend down: the coordinator makes a new engine for every stream.
        guard phase != .stopped else { return }
        phase = .loading(cushioned: backend.startCushion != nil)
        isPaused = true
        isBuffering = false
        hasPlayed = false
        startHold?.cancel()
        startHold = nil
        wantsPlay = false
        loadBegan = .now
        var fresh = PlaybackState()
        fresh.status = .loading
        fresh.preparation = PlaybackPreparation(stage: .loadingMedia, engine: backend.name, targetSeconds: backend.startCushion?.seconds)
        publish(fresh)
        backend.load(url: item.url, headers: item.headers, startPosition: item.startPosition)
    }

    public func play() {
        wantsPlay = true
        switch phase {
        case .ended:
            phase = .started
            Task {
                await self.seek(to: 0)
                self.backend.setPaused(false)
            }
        case .loading(cushioned: false), .started: backend.setPaused(false)
        case .holding: update { _ in }
        case .awaitingStart: beginStart()
        case .loading(cushioned: true): break   // decided once it has loaded
        case .failed, .stopped: break
        }
    }

    public func pause() {
        wantsPlay = false
        backend.setPaused(true)
        if isHolding { update { _ in } }
    }

    public func seek(to position: TimeInterval) async {
        let target = max(0, position)
        // A seek back from the end leaves it, so Play continues from there instead of replaying from the start.
        if phase == .ended, target < (state.duration ?? .infinity) { phase = .started }
        update { $0.position = target }
        await backend.seek(to: target)
    }

    public func setRate(_ rate: Float) {
        backend.setRate(rate)
        update { $0.rate = rate }
    }

    public func setVolume(_ volume: Float) {
        backend.setVolume(volume)
    }

    public func setMuted(_ muted: Bool) {
        backend.setMuted(muted)
    }

    public func selectAudioTrack(id: String?) {
        backend.selectAudio(id: id)
        update { $0.selectedAudioTrackID = id }
    }

    public func selectEmbeddedSubtitleTrack(id: String?) {
        backend.selectSubtitle(id: id)
        update { $0.selectedEmbeddedSubtitleID = id }
    }

    public var capabilities: EngineCapabilities { backend.capabilities }
    public var maximumRate: Float { backend.maximumRate }
    public func setSubtitleDelay(_ seconds: TimeInterval) { backend.setSubtitleDelay(seconds) }
    public func setAudioDelay(_ seconds: TimeInterval) { backend.setAudioDelay(seconds) }
    public func addExternalSubtitle(_ subtitle: ExternalSubtitle) { backend.addSubtitle(subtitle) }
    public func addExternalAudio(url: URL, title: String) { backend.addAudio(url: url, title: title) }
    public func apply(layout: VideoLayout) { backend.apply(layout: layout) }
    public func apply(processing: VideoProcessing) { backend.apply(processing: processing) }
    public func apply(subtitleStyle: SubtitleStyle) { backend.apply(subtitleStyle: subtitleStyle) }

    public func statistics() -> PlaybackStatistics {
        var statistics = backend.statistics()
        if statistics.bufferedAhead == nil { statistics.bufferedAhead = backend.preparationBufferedAhead }
        return statistics
    }

    public func stop() {
        phase = .stopped
        startHold?.cancel()
        startHold = nil
        eventTask?.cancel()
        eventTask = nil
        backend.shutdown()
        update { $0.status = .idle }
        broadcaster.finish()
    }

    // MARK: Events

    private func handle(_ event: FallbackEvent) {
        switch event {
        case .preparing(let stage):
            update { $0.preparation?.stage = stage }
        case .networkBitrate(let bitrate):
            update { $0.preparation?.networkBitrate = bitrate.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        case .loaded(let duration, let audio, let subtitles, let selectedAudio, let selectedSubtitle):
            if case .loading(let cushioned) = phase { phase = cushioned ? .awaitingStart : .started }
            update {
                $0.duration = duration.flatMap { $0 > 0 ? $0 : nil }
                $0.audioTracks = audio
                $0.embeddedSubtitleTracks = subtitles
                $0.selectedAudioTrackID = selectedAudio
                $0.selectedEmbeddedSubtitleID = selectedSubtitle
            }
            if phase == .awaitingStart, wantsPlay { beginStart() }
        case .duration(let duration):
            if isLoaded, duration.isFinite, duration > 0 { update { $0.duration = duration } }
        case .videoFrameReady:
            if isHolding { phase = .holding(firstFrame: true) } else { update { $0.hasVideoFrame = true } }
        case .position(let position):
            update { $0.position = max(0, position) }
        case .buffered(let until):
            update { $0.bufferedUntil = max(0, until) }
        case .paused(let paused):
            isPaused = paused
        case .buffering(let buffering):
            isBuffering = buffering
        case .tracks(let audio, let subtitles, let selectedAudio, let selectedSubtitle):
            update {
                $0.audioTracks = audio
                $0.embeddedSubtitleTracks = subtitles
                $0.selectedAudioTrackID = selectedAudio
                $0.selectedEmbeddedSubtitleID = selectedSubtitle
            }
        case .chapters(let chapters):
            update { $0.chapters = chapters }
        case .ended:
            switch phase {
            case .failed, .stopped: break
            default: phase = .ended
            }
        case .failed(let reason):
            phase = .failed(reason)
        }
        update { _ in }   // re-derive status
    }

    // MARK: Start cushion

    /// Decides the first start of the load: at once, or once the backend holds its `startCushion` (or the wait for it runs out).
    private func beginStart() {
        guard phase == .awaitingStart, let cushion = backend.startCushion else { return openStart() }
        let loadTook = Self.seconds(loadBegan.duration(to: .now))
        let ahead = backend.bufferedAhead
        let wait = cushion.wait(ahead: ahead, loadTook: loadTook)
        guard wait > 0 else {
            let reason: PlaybackPreparation.StartReason? = if let ahead, ahead < cushion.seconds { .waitLimit } else { nil }
            return openStart(reason: reason)
        }
        phase = .holding(firstFrame: false)
        update { $0.preparation?.waitDeadline = Date().addingTimeInterval(wait) }
        let startAhead = backend.bufferedAhead ?? 0
        startHold = Task { [weak self] in
            let began = ContinuousClock.now
            let deadline = began + .seconds(wait)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, self.isHolding else { return }
                let waited = Self.seconds(began.duration(to: .now))
                let ahead = self.backend.bufferedAhead
                if cushion.isMet(ahead: ahead, startAhead: startAhead, waited: waited) {
                    let reason: PlaybackPreparation.StartReason? = if let ahead, ahead < cushion.seconds { .fastFill } else { nil }
                    self.openStart(reason: reason)
                    return
                }
            }
            guard let self, !Task.isCancelled, self.isHolding else { return }
            self.openStart(reason: .waitLimit)
        }
    }

    /// Lets the first start through: playback starts if it is still wanted, and a first frame held back is shown.
    private func openStart(reason: PlaybackPreparation.StartReason? = nil) {
        startHold = nil
        var frame = false
        switch phase {
        case .holding(let firstFrame):
            frame = firstFrame
            phase = .started
        case .awaitingStart:
            phase = .started
        default:
            break
        }
        if wantsPlay { backend.setPaused(false) }
        let hasTarget = backend.bufferedAhead != nil
        update {
            if frame { $0.hasVideoFrame = true }
            $0.preparation?.waitDeadline = nil
            $0.preparation?.startReason = reason
            if !hasTarget { $0.preparation?.targetSeconds = nil }
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    /// Our status: the phase, with the backend's pause and buffering once the start is through.
    private var derivedStatus: PlaybackState.Status {
        switch phase {
        case .stopped: .idle
        case .failed(let failure): .failed(failure)
        case .ended: .ended
        case .loading: .loading
        case .holding: wantsPlay ? .buffering : .ready
        case .awaitingStart, .started: isPaused ? (hasPlayed ? .paused : .ready) : (isBuffering ? .buffering : .playing)
        }
    }

    private func update(_ change: (inout PlaybackState) -> Void) {
        var next = state
        change(&next)
        next.status = derivedStatus
        if next.status == .playing { hasPlayed = true }
        if var preparation = next.preparation {
            if case .failed(let failure) = phase {
                preparation.stage = .failed
                preparation.failure = failure
                preparation.waitDeadline = nil
            } else if next.hasVideoFrame, isStartOpen {
                preparation.stage = .ready
            } else if isHolding || isBuffering {
                preparation.stage = .buffering
            } else if isLoaded {
                preparation.stage = .startingPlayback
            }
            if isLoaded, state.preparation?.stage != .ready {
                preparation.bufferedSeconds = backend.preparationBufferedAhead.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            }
            next.preparation = phase == .stopped ? nil : preparation
        }
        publish(next)
    }

    private func publish(_ next: PlaybackState) {
        guard next != state else { return }
        state = next
        broadcaster.yield(next)
    }
}

#if canImport(AVFoundation)
/// The backend's AVPlayer, when its picture plays through one (AetherEngine's usual path; mpv draws its own).
extension FallbackEngine: AVPlayerFrameSource {
    public var framePlayer: AVPlayer? { (backend as? AVPlayerFrameSource)?.framePlayer }
}

/// The backend's room for a layer over its picture (AetherEngine); mpv has none and ignores it.
extension FallbackEngine: PictureOverlayHosting {
    public func hostPictureOverlay(_ layer: CALayer?) { (backend as? PictureOverlayHosting)?.hostPictureOverlay(layer) }
    public var pictureGravity: AVLayerVideoGravity { (backend as? PictureOverlayHosting)?.pictureGravity ?? .resizeAspect }
    public var pictureIsHDR: Bool { (backend as? PictureOverlayHosting)?.pictureIsHDR ?? false }
}

/// Picture in Picture for a backend that has a layer to give (AetherEngine). The transport is the engine's own, so its state stays right
/// when the window plays, pauses or skips. mpv has no layer, so its window stays unavailable.
extension FallbackEngine: PictureInPictureProviding {
    public var pictureInPictureLayer: CALayer? { (backend as? PictureInPictureBacking)?.pictureInPictureLayer }
    public func pictureInPictureTimeRange() -> CMTimeRange { (backend as? PictureInPictureBacking)?.pictureInPictureTimeRange() ?? .invalid }
    public var isPictureInPicturePaused: Bool { !state.isPlaying }
    public func setPictureInPicturePlaying(_ playing: Bool) { if playing { play() } else { pause() } }
    public func skipPictureInPicture(by seconds: Double) async { await seek(to: max(0, state.position + seconds)) }
    public func setPictureInPictureActive(_ active: Bool) { (backend as? PictureInPictureBacking)?.setPictureInPictureActive(active) }
}
#endif
