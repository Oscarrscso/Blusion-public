import Foundation
import StremioKit

public struct MediaTrack: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let language: String?
    public let isDefault: Bool
    /// Subtitles that only translate signs and foreign-language lines.
    public let isForced: Bool
    /// Subtitles for the deaf and hard of hearing (SDH/CC), or audio description.
    public let isHearingImpaired: Bool
    /// The decoder's codec name as the engine reports it (`ass`, `hdmv_pgs_subtitle`, `eac3`, `truehd`), when it does.
    public let codec: String?
    public let channelCount: Int?
    /// Loaded from a separate file into the engine, rather than found in the media.
    public let isExternal: Bool

    public init(id: String, title: String, language: String? = nil, isDefault: Bool = false, isForced: Bool = false,
                isHearingImpaired: Bool = false, codec: String? = nil, channelCount: Int? = nil, isExternal: Bool = false) {
        self.id = id
        self.title = title
        self.language = language
        self.isDefault = isDefault
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.codec = codec
        self.channelCount = channelCount
        self.isExternal = isExternal
    }
}

/// A chapter the media marks. `start` is in seconds of playback.
public struct Chapter: Sendable, Equatable, Hashable, Identifiable {
    public let index: Int
    public let title: String
    public let start: TimeInterval

    public var id: Int { index }

    public init(index: Int, title: String, start: TimeInterval) {
        self.index = index
        self.title = title
        self.start = start
    }
}

/// What an engine can do beyond the core transport. The UI shows a control only when the engine playing has it.
public struct EngineCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Loads subtitle files itself and draws them with full styling (ASS/SSA, PGS, VobSub).
    public static let engineSubtitles = EngineCapabilities(rawValue: 1 << 0)
    /// Shifts the subtitles it draws (embedded and engine-loaded) in time.
    public static let subtitleDelay = EngineCapabilities(rawValue: 1 << 1)
    public static let audioDelay = EngineCapabilities(rawValue: 1 << 2)
    /// Plays a separate audio file in sync with the video.
    public static let externalAudio = EngineCapabilities(rawValue: 1 << 3)
    /// Replaces the file's display aspect ratio and crops the picture (`VideoLayout.aspect`, `.crop`), itself or through the video surface.
    public static let aspectOverride = EngineCapabilities(rawValue: 1 << 4)
    public static let deinterlace = EngineCapabilities(rawValue: 1 << 5)
    /// Its own HDR tone mapping, with a choice of curve and of SDR output.
    public static let toneMapping = EngineCapabilities(rawValue: 1 << 6)
    /// Applies `SubtitleStyle` to the text subtitles it draws.
    public static let subtitleStyling = EngineCapabilities(rawValue: 1 << 7)
    /// Draws its own picture at the fit, fill or zoom asked for (otherwise the video surface does).
    public static let videoLayout = EngineCapabilities(rawValue: 1 << 8)
    /// Upscales through its own renderer (otherwise the app's super-resolution path may do it).
    public static let upscaling = EngineCapabilities(rawValue: 1 << 9)
    /// The stream is Dolby Vision and the engine can play its HDR10 / HLG base layer instead (`VideoProcessing.dolbyVision`).
    public static let dolbyVisionSwitch = EngineCapabilities(rawValue: 1 << 10)
}

/// What is actually playing, for the statistics panel. Fields an engine cannot know stay nil; `notes` say what a value means.
public struct PlaybackStatistics: Sendable, Equatable {
    public var engine: String
    /// The decoder in use: hardware (VideoToolbox) or software, with its name.
    public var decoder: String?
    public var videoCodec: String?
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    /// Bits per second of the video and audio streams, as the engine measures or the file declares them.
    public var videoBitrate: Double?
    public var audioBitrate: Double?
    /// Bits per second the network is delivering.
    public var networkBitrate: Double?
    /// Seconds of media buffered ahead of the playhead.
    public var bufferedAhead: TimeInterval?
    public var droppedFrames: Int?
    /// The colour of the decoded video, from the stream itself (not from the release name): "HDR10 (PQ, BT.2020)", "SDR (BT.709)".
    public var sourceColour: String?
    public var dolbyVision: String?
    /// What reaches the display: HDR passed through, or tone-mapped to SDR. nil when the engine cannot tell.
    public var outputColour: String?
    public var audioCodec: String?
    /// The decoded audio layout: "7.1, 48 kHz".
    public var audioChannels: String?
    /// What the audio output receives: "PCM 7.1" or "Dolby Atmos (passed to the system)".
    public var audioOutput: String?
    public var notes: [String]

    public init(engine: String, decoder: String? = nil, videoCodec: String? = nil, width: Int? = nil, height: Int? = nil, frameRate: Double? = nil,
                videoBitrate: Double? = nil, audioBitrate: Double? = nil, networkBitrate: Double? = nil, bufferedAhead: TimeInterval? = nil,
                droppedFrames: Int? = nil, sourceColour: String? = nil, dolbyVision: String? = nil, outputColour: String? = nil,
                audioCodec: String? = nil, audioChannels: String? = nil, audioOutput: String? = nil, notes: [String] = []) {
        self.engine = engine
        self.decoder = decoder
        self.videoCodec = videoCodec
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.videoBitrate = videoBitrate
        self.audioBitrate = audioBitrate
        self.networkBitrate = networkBitrate
        self.bufferedAhead = bufferedAhead
        self.droppedFrames = droppedFrames
        self.sourceColour = sourceColour
        self.dolbyVision = dolbyVision
        self.outputColour = outputColour
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
        self.audioOutput = audioOutput
        self.notes = notes
    }
}

/// A subtitle file for an engine with `EngineCapabilities.engineSubtitles` to load and draw.
public struct ExternalSubtitle: Sendable, Equatable, Hashable {
    public var url: URL
    public var title: String
    public var language: String?
    public var headers: [String: String]

    public init(url: URL, title: String, language: String? = nil, headers: [String: String] = [:]) {
        self.url = url
        self.title = title
        self.language = language
        self.headers = headers
    }
}

public struct PlaybackFailure: Error, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case network, format, unauthorized, notFound, timeout, noEngine, other
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    /// Safe card text: engine errors can contain signed URLs and request headers.
    public var preparationDescription: String {
        switch kind {
        case .network: "Network connection failed"
        case .format: "Media or decoding failed"
        case .unauthorized: "Stream access denied"
        case .notFound: "Stream is no longer available"
        case .timeout: "Stream preparation timed out"
        case .noEngine: "Player is unavailable"
        case .other: "Stream could not be prepared"
        }
    }
}

/// Only engine-confirmed work and measurements. Buffer progress is towards a startup cushion, never the film's duration.
public struct PlaybackPreparation: Sendable, Equatable {
    public enum Stage: String, Sendable, Equatable {
        case resolvingStream = "Resolving stream"
        case openingConnection = "Opening connection"
        case loadingMedia = "Loading media"
        case buffering = "Buffering"
        case startingPlayback = "Starting playback"
        case ready = "Ready"
        case failed = "Preparation failed"
    }

    public enum StartReason: Sendable, Equatable {
        case fastFill, waitLimit
    }

    public var stage: Stage
    public var engine: String?
    public var bufferedSeconds: TimeInterval?
    public var targetSeconds: TimeInterval?
    public var networkBitrate: Double?
    /// The actual start gate deadline; reaching it starts with the available buffer.
    public var waitDeadline: Date?
    public var startReason: StartReason?
    public var retryingAfter: PlaybackFailure?
    public var failure: PlaybackFailure?

    public init(stage: Stage, engine: String? = nil, targetSeconds: TimeInterval? = nil) {
        self.stage = stage
        self.engine = engine
        self.targetSeconds = targetSeconds
    }
}

public struct PlaybackState: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case idle, loading, ready, playing, paused, buffering, ended
        case failed(PlaybackFailure)
    }

    public var status: Status = .idle
    public var position: TimeInterval = 0
    /// nil while unknown (or for live streams).
    public var duration: TimeInterval?
    public var bufferedUntil: TimeInterval = 0
    public var rate: Float = 1
    public var audioTracks: [MediaTrack] = []
    public var selectedAudioTrackID: String?
    /// Subtitle tracks inside the media. External subtitles are not engine tracks: they are drawn by the app (PLAN §5).
    public var embeddedSubtitleTracks: [MediaTrack] = []
    public var selectedEmbeddedSubtitleID: String?
    /// Latched only by renderer readiness, never by a playing clock or a loaded file.
    public var hasVideoFrame = false
    public var isExternalPlaybackActive = false
    public var chapters: [Chapter] = []
    public var preparation: PlaybackPreparation?

    public init() {}

    public var isPlaying: Bool { status == .playing }
    /// Playing, or stalled waiting for data while meant to play: either way Pause is the transport's next step.
    public var isPlayingOrBuffering: Bool { status == .playing || status == .buffering }

    public var failure: PlaybackFailure? {
        if case .failed(let failure) = status { return failure }
        return nil
    }

    /// Ready and buffering alone do not show that playback has started.
    public var hasStarted: Bool {
        switch status {
        case .playing, .ended: return true
        case .idle, .loading, .ready, .paused, .buffering, .failed: return false
        }
    }
}

public struct PlaybackItem: Sendable, Equatable {
    public var url: URL
    /// Request headers for every media request (`proxyHeaders.request`).
    public var headers: [String: String]
    public var title: String
    public var startPosition: TimeInterval
    public var filename: String?

    public init(url: URL, headers: [String: String] = [:], title: String, startPosition: TimeInterval = 0, filename: String? = nil) {
        self.url = url
        self.headers = headers
        self.title = title
        self.startPosition = startPosition
        self.filename = filename
    }
}

/// AVPlayer and the fallback engine implement the same protocol, so the coordinator and the UI never know which one is playing.
/// Failures are reported through `state.status = .failed`, never thrown, so one observer sees every outcome.
@MainActor
public protocol PlaybackEngine: AnyObject {
    var state: PlaybackState { get }
    /// A fresh stream of every state change (latest value wins if the consumer is slow).
    func makeStateStream() -> AsyncStream<PlaybackState>
    func load(_ item: PlaybackItem)
    func play()
    func pause()
    func seek(to position: TimeInterval) async
    func setRate(_ rate: Float)
    /// 0 (silent) to 1 (full).
    func setVolume(_ volume: Float)
    func setMuted(_ muted: Bool)
    func selectAudioTrack(id: String?)
    func selectEmbeddedSubtitleTrack(id: String?)
    func stop()

    // The rest have defaults that do nothing, so an engine implements only what its `capabilities` claim.
    var capabilities: EngineCapabilities { get }
    /// The fastest `setRate` this engine plays cleanly. Anything above it is clamped or unreliable, so a hold never asks for it.
    var maximumRate: Float { get }
    /// Positive delays the subtitles the engine draws.
    func setSubtitleDelay(_ seconds: TimeInterval)
    /// Positive delays the audio.
    func setAudioDelay(_ seconds: TimeInterval)
    /// Loads, adds and selects a subtitle file; it then appears in `embeddedSubtitleTracks` with `isExternal`.
    func addExternalSubtitle(_ subtitle: ExternalSubtitle)
    /// Loads, adds and selects an audio file; it then appears in `audioTracks` with `isExternal`.
    func addExternalAudio(url: URL, title: String)
    func apply(layout: VideoLayout)
    func apply(processing: VideoProcessing)
    func apply(subtitleStyle: SubtitleStyle)
    func statistics() -> PlaybackStatistics
}

public extension PlaybackEngine {
    var capabilities: EngineCapabilities { [] }
    /// 2×, the speed Settings offers: an engine claims more only after it has shown it plays cleanly.
    var maximumRate: Float { 2 }
    func setSubtitleDelay(_ seconds: TimeInterval) {}
    func setAudioDelay(_ seconds: TimeInterval) {}
    func addExternalSubtitle(_ subtitle: ExternalSubtitle) {}
    func addExternalAudio(url: URL, title: String) {}
    func apply(layout: VideoLayout) {}
    func apply(processing: VideoProcessing) {}
    func apply(subtitleStyle: SubtitleStyle) {}
    func statistics() -> PlaybackStatistics { PlaybackStatistics(engine: String(describing: type(of: self))) }
}

/// Fan-out of state changes to any number of `AsyncStream` consumers. Engines own one.
@MainActor
public final class PlaybackStateBroadcaster {
    private var continuations: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]

    public init() {}

    public func makeStream(current: PlaybackState) -> AsyncStream<PlaybackState> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<PlaybackState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[token] = nil }
        }
        continuation.yield(current)
        return stream
    }

    public func yield(_ state: PlaybackState) {
        for continuation in continuations.values { continuation.yield(state) }
    }

    public func finish() {
        for continuation in continuations.values { continuation.finish() }
        continuations = [:]
    }
}
