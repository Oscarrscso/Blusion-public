#if canImport(AVFoundation)
import AVFoundation
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
    private var isLoaded = false
    private var isPaused = true
    private var isBuffering = false
    private var hasEnded = false
    private var hasPlayed = false
    private var isStopped = false
    private var failure: PlaybackFailure?
    /// The first start of a load (`FallbackBackend.startCushion`): not decided yet, waiting for data in hand, or let through.
    private enum StartGate { case closed, holding, open }
    private var startGate = StartGate.open
    private var startHold: Task<Void, Never>?
    /// Play was asked for and pause has not been since: what the start does once it is let through.
    private var wantsPlay = false
    /// The first frame came while the start was held. It is shown when playback starts, so the startup spinner covers the wait.
    private var heldFirstFrame = false
    private var loadBegan = ContinuousClock.now

    public init(backend: any FallbackBackend) {
        self.backend = backend
        let events = backend.makeEventStream()
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled, !self.isStopped else { return }
                self.handle(event)
            }
        }
    }

    public var videoSurface: AnyObject { backend.videoSurface }

    public func makeStateStream() -> AsyncStream<PlaybackState> { broadcaster.makeStream(current: state) }

    // MARK: PlaybackEngine

    public func load(_ item: PlaybackItem) {
        isLoaded = false
        isPaused = true
        isBuffering = false
        hasEnded = false
        hasPlayed = false
        failure = nil
        startHold?.cancel()
        startHold = nil
        startGate = backend.startCushion == nil ? .open : .closed
        wantsPlay = false
        heldFirstFrame = false
        loadBegan = .now
        var fresh = PlaybackState()
        fresh.status = .loading
        fresh.preparation = PlaybackPreparation(stage: .loadingMedia, engine: backend.name, targetSeconds: backend.startCushion?.seconds)
        publish(fresh)
        backend.load(url: item.url, headers: item.headers, startPosition: item.startPosition)
    }

    public func play() {
        wantsPlay = true
        if hasEnded {
            hasEnded = false
            Task {
                await self.seek(to: 0)
                self.backend.setPaused(false)
            }
            return
        }
        switch startGate {
        case .open: backend.setPaused(false)
        case .holding: update { _ in }
        case .closed: if isLoaded { beginStart() }   // otherwise decided once it has loaded
        }
    }

    public func pause() {
        wantsPlay = false
        backend.setPaused(true)
        if startGate == .holding { update { _ in } }
    }

    public func seek(to position: TimeInterval) async {
        let target = max(0, position)
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
        isStopped = true
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
            isLoaded = true
            update {
                $0.duration = duration.flatMap { $0 > 0 ? $0 : nil }
                $0.audioTracks = audio
                $0.embeddedSubtitleTracks = subtitles
                $0.selectedAudioTrackID = selectedAudio
                $0.selectedEmbeddedSubtitleID = selectedSubtitle
            }
            if startGate == .closed, wantsPlay { beginStart() }
        case .duration(let duration):
            if isLoaded, duration.isFinite, duration > 0 { update { $0.duration = duration } }
        case .videoFrameReady:
            if startGate == .holding { heldFirstFrame = true } else { update { $0.hasVideoFrame = true } }
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
            hasEnded = true
        case .failed(let reason):
            failure = reason
        }
        update { _ in }   // re-derive status
    }

    // MARK: Start cushion

    /// Decides the first start of the load: at once, or once the backend holds its `startCushion` (or the wait for it runs out).
    private func beginStart() {
        guard startGate == .closed, let cushion = backend.startCushion else { return openStart() }
        let loadTook = Self.seconds(loadBegan.duration(to: .now))
        let ahead = backend.bufferedAhead
        let wait = cushion.wait(ahead: ahead, loadTook: loadTook)
        guard wait > 0 else {
            let reason: PlaybackPreparation.StartReason? = if let ahead, ahead < cushion.seconds { .waitLimit } else { nil }
            return openStart(reason: reason)
        }
        startGate = .holding
        update { $0.preparation?.waitDeadline = Date().addingTimeInterval(wait) }
        let startAhead = backend.bufferedAhead ?? 0
        startHold = Task { [weak self] in
            let began = ContinuousClock.now
            let deadline = began + .seconds(wait)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, self.failure == nil else { return }
                let waited = Self.seconds(began.duration(to: .now))
                let ahead = self.backend.bufferedAhead
                if cushion.isMet(ahead: ahead, startAhead: startAhead, waited: waited) {
                    let reason: PlaybackPreparation.StartReason? = if let ahead, ahead < cushion.seconds { .fastFill } else { nil }
                    self.openStart(reason: reason)
                    return
                }
            }
            guard let self, !Task.isCancelled, self.failure == nil else { return }
            self.openStart(reason: .waitLimit)
        }
    }

    /// Lets the first start through: playback starts if it is still wanted, and a first frame held back is shown.
    private func openStart(reason: PlaybackPreparation.StartReason? = nil) {
        startHold = nil
        startGate = .open
        if wantsPlay { backend.setPaused(false) }
        let frame = heldFirstFrame
        heldFirstFrame = false
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

    /// Derives our status from the backend's flags.
    private func deriveStatus() -> PlaybackState.Status {
        if let failure { return .failed(failure) }
        if hasEnded { return .ended }
        if !isLoaded { return .loading }
        if startGate == .holding { return wantsPlay ? .buffering : .ready }
        if isPaused { return hasPlayed ? .paused : .ready }
        hasPlayed = true
        return isBuffering ? .buffering : .playing
    }

    private func update(_ change: (inout PlaybackState) -> Void) {
        var next = state
        change(&next)
        next.status = isStopped ? .idle : deriveStatus()
        if var preparation = next.preparation {
            if let failure {
                preparation.stage = .failed
                preparation.failure = failure
                preparation.waitDeadline = nil
            } else if next.hasVideoFrame, startGate == .open {
                preparation.stage = .ready
            } else if startGate == .holding || isBuffering {
                preparation.stage = .buffering
            } else if isLoaded {
                preparation.stage = .startingPlayback
            }
            if isLoaded, state.preparation?.stage != .ready {
                preparation.bufferedSeconds = backend.preparationBufferedAhead.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            }
            next.preparation = isStopped ? nil : preparation
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
#endif
