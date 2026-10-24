import Foundation
import StremioKit

/// An engine that renders into a view of its own (as opposed to AVPlayer's layer). The UI embeds `videoSurface` (a `UIView`) in the player.
/// Typed `AnyObject` so PlayerKit needs no UIKit.
@MainActor
public protocol VideoSurfaceProviding: AnyObject {
    var videoSurface: AnyObject { get }
}

public enum FallbackEvent: Sendable, Equatable {
    case loaded(duration: TimeInterval?, audio: [MediaTrack], subtitles: [MediaTrack], selectedAudio: String?, selectedSubtitle: String?)
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
    var videoSurface: AnyObject { get }
    /// One stream for the backend's lifetime.
    func makeEventStream() -> AsyncStream<FallbackEvent>
    /// Loads paused; the engine calls `setPaused(false)` to start.
    func load(url: URL, headers: [String: String], startPosition: TimeInterval)
    func setPaused(_ paused: Bool)
    func seek(to position: TimeInterval) async
    func setRate(_ rate: Float)
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
}

public extension FallbackBackend {
    var capabilities: EngineCapabilities { [] }
    func setSubtitleDelay(_ seconds: TimeInterval) {}
    func setAudioDelay(_ seconds: TimeInterval) {}
    func addSubtitle(_ subtitle: ExternalSubtitle) {}
    func addAudio(url: URL, title: String) {}
    func apply(layout: VideoLayout) {}
    func apply(processing: VideoProcessing) {}
    func apply(subtitleStyle: SubtitleStyle) {}
    func statistics() -> PlaybackStatistics { PlaybackStatistics(engine: "Fallback") }
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

    public init(backend: any FallbackBackend) {
        self.backend = backend
        let events = backend.makeEventStream()
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
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
        var fresh = PlaybackState()
        fresh.status = .loading
        publish(fresh)
        backend.load(url: item.url, headers: item.headers, startPosition: item.startPosition)
    }

    public func play() {
        if hasEnded {
            hasEnded = false
            Task {
                await self.seek(to: 0)
                self.backend.setPaused(false)
            }
            return
        }
        backend.setPaused(false)
    }

    public func pause() {
        backend.setPaused(true)
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
    public func setSubtitleDelay(_ seconds: TimeInterval) { backend.setSubtitleDelay(seconds) }
    public func setAudioDelay(_ seconds: TimeInterval) { backend.setAudioDelay(seconds) }
    public func addExternalSubtitle(_ subtitle: ExternalSubtitle) { backend.addSubtitle(subtitle) }
    public func addExternalAudio(url: URL, title: String) { backend.addAudio(url: url, title: title) }
    public func apply(layout: VideoLayout) { backend.apply(layout: layout) }
    public func apply(processing: VideoProcessing) { backend.apply(processing: processing) }
    public func apply(subtitleStyle: SubtitleStyle) { backend.apply(subtitleStyle: subtitleStyle) }

    public func statistics() -> PlaybackStatistics {
        var statistics = backend.statistics()
        if statistics.bufferedAhead == nil { statistics.bufferedAhead = max(0, state.bufferedUntil - state.position) }
        return statistics
    }

    public func stop() {
        isStopped = true
        eventTask?.cancel()
        eventTask = nil
        backend.shutdown()
        update { $0.status = .idle }
        broadcaster.finish()
    }

    // MARK: Events

    private func handle(_ event: FallbackEvent) {
        switch event {
        case .loaded(let duration, let audio, let subtitles, let selectedAudio, let selectedSubtitle):
            isLoaded = true
            update {
                $0.duration = duration.flatMap { $0 > 0 ? $0 : nil }
                $0.audioTracks = audio
                $0.embeddedSubtitleTracks = subtitles
                $0.selectedAudioTrackID = selectedAudio
                $0.selectedEmbeddedSubtitleID = selectedSubtitle
            }
        case .videoFrameReady:
            update { $0.hasVideoFrame = true }
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

    /// Derives our status from the backend's flags.
    private func deriveStatus() -> PlaybackState.Status {
        if let failure { return .failed(failure) }
        if hasEnded { return .ended }
        if !isLoaded { return .loading }
        if isPaused { return hasPlayed ? .paused : .ready }
        hasPlayed = true
        return isBuffering ? .buffering : .playing
    }

    private func update(_ change: (inout PlaybackState) -> Void) {
        var next = state
        change(&next)
        next.status = isStopped ? .idle : deriveStatus()
        publish(next)
    }

    private func publish(_ next: PlaybackState) {
        guard next != state else { return }
        state = next
        broadcaster.yield(next)
    }
}
