import Foundation
import PlayerKit
import StremioKit

/// A scripted `FallbackBackend`. Tests push events with `emit` and read what the engine asked of it.
@MainActor
public final class MockBackend: FallbackBackend {
    public final class Surface {}

    public let videoSurface: AnyObject = Surface()
    public private(set) var loads: [(url: URL, headers: [String: String], start: TimeInterval)] = []
    public private(set) var pausedCalls: [Bool] = []
    public private(set) var seeks: [TimeInterval] = []
    public private(set) var rates: [Float] = []
    public private(set) var volumes: [Float] = []
    public private(set) var mutes: [Bool] = []
    public private(set) var audioSelections: [String?] = []
    public private(set) var subtitleSelections: [String?] = []
    public private(set) var isShutDown = false
    public var capabilities: EngineCapabilities = [.engineSubtitles, .subtitleDelay, .audioDelay, .externalAudio, .aspectOverride,
                                                   .deinterlace, .toneMapping, .subtitleStyling, .videoLayout, .upscaling]
    public private(set) var subtitleDelays: [TimeInterval] = []
    public private(set) var audioDelays: [TimeInterval] = []
    public private(set) var addedSubtitles: [ExternalSubtitle] = []
    public private(set) var addedAudio: [(url: URL, title: String)] = []
    public private(set) var layouts: [VideoLayout] = []
    public private(set) var processings: [VideoProcessing] = []
    public private(set) var subtitleStyles: [SubtitleStyle] = []

    private var continuation: AsyncStream<FallbackEvent>.Continuation?
    private let stream: AsyncStream<FallbackEvent>
    private let autoLoad: (duration: TimeInterval, audio: [MediaTrack], subtitles: [MediaTrack])?
    private let failOnLoad: PlaybackFailure?

    /// With `autoLoad`, a `.loaded` event follows every `load`; with `failOnLoad`, a `.failed` event does.
    public init(autoLoad: (duration: TimeInterval, audio: [MediaTrack], subtitles: [MediaTrack])? = (100, [], []), failOnLoad: PlaybackFailure? = nil) {
        let (stream, continuation) = AsyncStream<FallbackEvent>.makeStream()
        self.stream = stream
        self.continuation = continuation
        self.autoLoad = autoLoad
        self.failOnLoad = failOnLoad
    }

    public func makeEventStream() -> AsyncStream<FallbackEvent> { stream }

    public func emit(_ event: FallbackEvent) { continuation?.yield(event) }

    public func load(url: URL, headers: [String: String], startPosition: TimeInterval) {
        loads.append((url, headers, startPosition))
        if let failOnLoad {
            emit(.failed(failOnLoad))
        } else if let autoLoad {
            emit(.loaded(duration: autoLoad.duration, audio: autoLoad.audio, subtitles: autoLoad.subtitles,
                selectedAudio: autoLoad.audio.first?.id, selectedSubtitle: nil))
            emit(.paused(true))
        }
    }

    public func setPaused(_ paused: Bool) {
        pausedCalls.append(paused)
        emit(.paused(paused))
    }

    public func seek(to position: TimeInterval) async {
        seeks.append(position)
        emit(.position(position))
    }

    public func setRate(_ rate: Float) { rates.append(rate) }
    public func setVolume(_ volume: Float) { volumes.append(volume) }
    public func setMuted(_ muted: Bool) { mutes.append(muted) }
    public func selectAudio(id: String?) { audioSelections.append(id) }
    public func selectSubtitle(id: String?) { subtitleSelections.append(id) }

    public func setSubtitleDelay(_ seconds: TimeInterval) { subtitleDelays.append(seconds) }
    public func setAudioDelay(_ seconds: TimeInterval) { audioDelays.append(seconds) }
    public func addSubtitle(_ subtitle: ExternalSubtitle) { addedSubtitles.append(subtitle) }
    public func addAudio(url: URL, title: String) { addedAudio.append((url, title)) }
    public func apply(layout: VideoLayout) { layouts.append(layout) }
    public func apply(processing: VideoProcessing) { processings.append(processing) }
    public func apply(subtitleStyle: SubtitleStyle) { subtitleStyles.append(subtitleStyle) }
    public func statistics() -> PlaybackStatistics { PlaybackStatistics(engine: "MockBackend", decoder: "hardware") }

    public func shutdown() {
        isShutDown = true
        continuation?.finish()
        continuation = nil
    }
}
