import Foundation
import PlayerKit
import StremioKit

/// A scripted engine. Tests drive it with `simulate…` instead of waiting on a clock.
@MainActor
public final class MockEngine: PlaybackEngine {
    public enum Outcome: Sendable {
        /// Becomes ready after `loadDelay`, with this duration.
        case plays(duration: TimeInterval)
        case failsToLoad(PlaybackFailure)
        /// Never reports ready (exercises the startup timeout).
        case hangs
    }

    public private(set) var state = PlaybackState()
    public private(set) var loadedItems: [PlaybackItem] = []
    public private(set) var seeks: [TimeInterval] = []
    public private(set) var playCalls = 0
    public private(set) var pauseCalls = 0
    public private(set) var rates: [Float] = []
    public private(set) var volumes: [Float] = []
    public private(set) var mutes: [Bool] = []
    public private(set) var selectedAudio: [String?] = []
    public private(set) var selectedEmbeddedSubtitles: [String?] = []
    public private(set) var isStopped = false
    public var capabilities: EngineCapabilities = []
    public private(set) var subtitleDelays: [TimeInterval] = []
    public private(set) var audioDelays: [TimeInterval] = []
    public private(set) var addedSubtitles: [ExternalSubtitle] = []
    public private(set) var addedAudio: [URL] = []
    public private(set) var layouts: [VideoLayout] = []
    public private(set) var processings: [VideoProcessing] = []
    public private(set) var subtitleStyles: [SubtitleStyle] = []

    private let outcome: Outcome
    private let loadDelay: Duration
    private let broadcaster = PlaybackStateBroadcaster()
    private var wantsPlay = false
    private var loadTask: Task<Void, Never>?

    /// Tracks the media reports once loaded.
    private let loadedTracks: (audio: [MediaTrack], subtitles: [MediaTrack])

    public init(_ outcome: Outcome = .plays(duration: 100), loadDelay: Duration = .milliseconds(5), capabilities: EngineCapabilities = [],
                audio: [MediaTrack] = [], subtitles: [MediaTrack] = []) {
        self.outcome = outcome
        self.loadDelay = loadDelay
        self.capabilities = capabilities
        self.loadedTracks = (audio, subtitles)
    }

    public func makeStateStream() -> AsyncStream<PlaybackState> { broadcaster.makeStream(current: state) }

    public func load(_ item: PlaybackItem) {
        loadedItems.append(item)
        update { $0.status = .loading }
        loadTask = Task { [weak self, loadDelay, outcome] in
            try? await Task.sleep(for: loadDelay)
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case .plays(let duration):
                self.update {
                    $0.duration = duration
                    $0.position = item.startPosition
                    $0.audioTracks = self.loadedTracks.audio
                    $0.embeddedSubtitleTracks = self.loadedTracks.subtitles
                    $0.selectedAudioTrackID = self.loadedTracks.audio.first?.id
                    $0.status = self.wantsPlay ? .playing : .ready
                }
            case .failsToLoad(let failure):
                self.update { $0.status = .failed(failure) }
            case .hangs:
                break
            }
        }
    }

    public func play() {
        playCalls += 1
        wantsPlay = true
        if state.status == .ready || state.status == .paused { update { $0.status = .playing } }
    }

    public func pause() {
        pauseCalls += 1
        wantsPlay = false
        if state.status == .playing || state.status == .buffering { update { $0.status = .paused } }
    }

    public func seek(to position: TimeInterval) async {
        seeks.append(position)
        update { $0.position = position }
    }

    public func setRate(_ rate: Float) {
        rates.append(rate)
        update { $0.rate = rate }
    }

    public func setVolume(_ volume: Float) {
        volumes.append(volume)
    }

    public func setMuted(_ muted: Bool) {
        mutes.append(muted)
    }

    public func selectAudioTrack(id: String?) {
        selectedAudio.append(id)
        update { $0.selectedAudioTrackID = id }
    }

    public func selectEmbeddedSubtitleTrack(id: String?) {
        selectedEmbeddedSubtitles.append(id)
        update { $0.selectedEmbeddedSubtitleID = id }
    }

    public func setSubtitleDelay(_ seconds: TimeInterval) { subtitleDelays.append(seconds) }
    public func setAudioDelay(_ seconds: TimeInterval) { audioDelays.append(seconds) }
    public func apply(layout: VideoLayout) { layouts.append(layout) }
    public func apply(processing: VideoProcessing) { processings.append(processing) }
    public func apply(subtitleStyle: SubtitleStyle) { subtitleStyles.append(subtitleStyle) }
    public func statistics() -> PlaybackStatistics { PlaybackStatistics(engine: "Mock", width: 1920, height: 1080) }

    /// The file shows up as an external subtitle track and is selected, as mpv's `sub-add` does.
    public func addExternalSubtitle(_ subtitle: ExternalSubtitle) {
        addedSubtitles.append(subtitle)
        let id = "x\(addedSubtitles.count)"
        update {
            $0.embeddedSubtitleTracks.append(MediaTrack(id: id, title: subtitle.title, language: subtitle.language, isExternal: true))
            $0.selectedEmbeddedSubtitleID = id
        }
    }

    public func addExternalAudio(url: URL, title: String) {
        addedAudio.append(url)
        let id = "xa\(addedAudio.count)"
        update {
            $0.audioTracks.append(MediaTrack(id: id, title: title, isExternal: true))
            $0.selectedAudioTrackID = id
        }
    }

    public func stop() {
        isStopped = true
        loadTask?.cancel()
        update { $0.status = .idle }
        broadcaster.finish()
    }

    // MARK: Test controls

    public func simulate(position: TimeInterval, duration: TimeInterval? = nil) {
        update {
            $0.position = position
            if let duration { $0.duration = duration }
        }
    }

    public func simulate(bufferedUntil: TimeInterval) { update { $0.bufferedUntil = bufferedUntil } }
    public func simulate(chapters: [Chapter]) { update { $0.chapters = chapters } }

    public func simulateFailure(_ failure: PlaybackFailure) { update { $0.status = .failed(failure) } }
    public func simulateEnd() { update { $0.status = .ended } }
    public func simulateBuffering() { update { $0.status = .buffering } }
    public func simulate(tracks audio: [MediaTrack], subtitles: [MediaTrack]) {
        update {
            $0.audioTracks = audio
            $0.embeddedSubtitleTracks = subtitles
        }
    }

    private func update(_ change: (inout PlaybackState) -> Void) {
        change(&state)
        broadcaster.yield(state)
    }
}
