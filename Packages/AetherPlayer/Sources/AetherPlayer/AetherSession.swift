#if canImport(UIKit)
import AetherEngine
import AVFoundation
import Combine
import Foundation
import UIKit

/// One AetherEngine playback session, driven by Blusion's `AetherBackend` (FallbackPlayer). Owns the engine, the view it draws into and
/// the subtitle overlay (AetherEngine publishes subtitle cues; the host draws them). Everything it reports goes out as `AetherEvent`s.
@MainActor
public final class AetherSession {
    /// The optional parts of AetherEngine this build compiled (package traits in Package.swift).
    public static var composesFEL: Bool { AetherEngine.OptionalComponent.dualLayerDolbyVision.isBuiltIn }
    public static var rendersObjectAudio: Bool { AetherEngine.OptionalComponent.trueHDObjectAudio.isBuiltIn }

    private let engine: AetherEngine
    private let host = AetherHostView()
    public let events: AsyncStream<AetherEvent>
    private let continuation: AsyncStream<AetherEvent>.Continuation
    private var subscriptions: Set<AnyCancellable> = []
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var isLoaded = false
    private var options = AetherOptions()
    private var volume: Float = 1
    private var isMuted = false
    private var lastPosition = -1.0
    private var lastBuffered = -1.0
    /// The length last reported, in `loaded` or a later `duration`; 0 while unknown.
    private var lastDuration = 0.0
    private var lastTracks: (audio: [AetherTrack], subtitles: [AetherTrack], audioID: Int?, subtitleID: Int?)?
    private var lastChapters: [AetherChapter] = []
    private var pausedState: Bool?
    private var bufferingState = false
    private var hasEnded = false
    private var subtitleDelay: TimeInterval = 0
    /// The last play or pause Blusion asked for. Blusion says play straight after load, before AetherEngine has a session to play,
    /// and AetherEngine's own play() is a no-op until then; so the word is kept and applied once the load is done.
    private var wantsPlaying = false
    /// A track pick AetherEngine has not reported back yet (a switch rebuilds the session, so it lands later). Reported as selected
    /// meanwhile, so the menu doesn't flick back to the old track. `.some(nil)` is subtitles off.
    private var pendingAudio: Int?
    private var pendingSubtitle: Int??

    public var view: UIView { host }
    /// The AVPlayer AetherEngine plays the picture through now; nil on its software path or before a load. It changes as AetherEngine
    /// rebuilds its session (a track switch, a seam), so readers ask again rather than keep it.
    public var currentPlayer: AVPlayer? { engine.currentAVPlayer }

    /// Shows `layer` over the picture, placed and sized with it (AI super resolution's scaled frames); nil removes it. Subtitles stay
    /// above it.
    public func hostPictureOverlay(_ layer: CALayer?) { host.hostPictureOverlay(layer) }
    /// How the picture is drawn into its frame, for a layer drawn over it.
    public var pictureGravity: AVLayerVideoGravity { host.currentGravity }
    /// The stream is HDR or Dolby Vision (not what reaches the display).
    public var isHDRSource: Bool { isLoaded && engine.sourceVideoFormat != .sdr }
    /// Seconds of the film AetherEngine holds ahead of the playhead on its loopback route, where it repackages the remux for AVPlayer
    /// as it downloads (what AVPlayer has, plus the segments made ahead of it). nil before the load, on its software path and for a
    /// live stream. It moves about once a second while paused.
    public var loopbackBufferedAhead: TimeInterval? {
        guard isLoaded, engine.videoRoute == .loopback, !engine.isLive else { return nil }
        let ahead = engine.clock.bufferedPosition - engine.clock.currentTime
        return ahead.isFinite ? max(0, ahead) : nil
    }
    #if DEBUG
    private let trace = PlaybackTrace()
    #endif

    public init() throws {
        engine = try AetherEngine()
        engine.logTag = "blusion"
        (events, continuation) = AsyncStream<AetherEvent>.makeStream()
        engine.bind(view: host.playerView)
        let engine = engine
        host.onGravity = { gravity in engine.videoGravity = gravity }
        observe()
    }

    // MARK: Loading

    public func load(url: URL, headers: [String: String], startPosition: TimeInterval, options: AetherOptions) {
        generation += 1
        let generation = generation
        self.options = options
        isLoaded = false
        hasEnded = false
        lastDuration = 0
        lastBuffered = -1
        lastTracks = nil
        lastChapters = []
        pausedState = nil
        wantsPlaying = false
        pendingAudio = nil
        pendingSubtitle = nil
        host.overlay.show(cues: [], at: 0)
        Self.activateAudioSession()
        #if DEBUG
        trace.begin(name: url.lastPathComponent, start: startPosition, engine: engine)
        #endif
        var loadOptions = LoadOptions(
            httpHeaders: headers,
            preferDualLayerDolbyVision: options.composesFEL,
            objectAudioRendering: options.rendersObjectAudio ? .apac(.l714) : .off,
            preferredAudioLanguages: options.preferredAudioLanguages,
            autoplay: false
        )
        loadOptions.dolbyVisionHandling = options.dolbyVision ? .automatic : .baseLayerOnly
        // Start on a segment's first fragments instead of waiting for the whole segment: a faster first frame on slow links.
        loadOptions.progressiveSegmentDelivery = true
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            // A warm of this stream already under way (`AetherPrewarm`) hands its bytes and resolved link to the load.
            await AetherPrewarm.waitForWarm(of: url)
            guard !Task.isCancelled, generation == self.generation else { return }
            do {
                try await self.engine.load(url: url, startPosition: startPosition > 0 ? startPosition : nil, options: loadOptions)
                guard !Task.isCancelled, generation == self.generation else { return }
                self.didLoad()
            } catch {
                guard !Task.isCancelled, generation == self.generation else { return }
                self.continuation.yield(.failed(self.failure(thrown: error)))
            }
        }
    }

    private func didLoad() {
        isLoaded = true
        #if DEBUG
        trace.note("loaded route=\(engine.videoRoute.rawValue) \(engine.sourceVideoWidth)x\(engine.sourceVideoHeight) "
                   + "\(engine.sourceVideoCodecName ?? "-") \(engine.sourceVideoBitrate / 1_000_000) Mbit/s wantsPlay=\(wantsPlaying)")
        #endif
        if wantsPlaying { engine.play() }
        let tracks = currentTracks()
        lastTracks = tracks
        let duration = engine.duration.isFinite && engine.duration > 0 ? engine.duration : nil
        lastDuration = duration ?? 0
        continuation.yield(.loaded(duration: duration, audio: tracks.audio, subtitles: tracks.subtitles,
                                   selectedAudio: tracks.audioID, selectedSubtitle: tracks.subtitleID))
        publishChapters()
        publishTransport()
        if engine.hasFirstFrameReadyForDisplay { continuation.yield(.videoFrameReady) }
        host.displaySize = presentedSize()
    }

    /// The picture's presented size: measured on the software path, else the coded size under the pixel aspect.
    private func presentedSize() -> CGSize? {
        if let size = engine.softwareDisplaySize { return size }
        guard engine.sourceVideoWidth > 0, engine.sourceVideoHeight > 0 else { return nil }
        return CGSize(width: Double(engine.sourceVideoWidth) * engine.sourceVideoPixelAspectRatio, height: Double(engine.sourceVideoHeight))
    }

    // MARK: Transport

    public func setPaused(_ paused: Bool) {
        wantsPlaying = !paused
        #if DEBUG
        trace.note(paused ? "pause" : "play ahead=\(loopbackBufferedAhead.map { String(format: "%.1f", $0) } ?? "-")")
        #endif
        guard isLoaded else { return }   // applied in didLoad
        if paused { engine.pause() } else { engine.play() }
    }

    public func seek(to position: TimeInterval) async {
        hasEnded = false
        await engine.seek(to: position)
    }

    public func setRate(_ rate: Float) { engine.setRate(rate) }

    public func setVolume(_ volume: Float) {
        self.volume = volume
        engine.volume = isMuted ? 0 : volume
    }

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        engine.volume = muted ? 0 : volume
    }

    public func setAudioDelay(_ seconds: TimeInterval) { engine.setAudioDelay(seconds) }

    /// Positive delays the subtitles: the overlay and the frames composed for Picture in Picture.
    public func setSubtitleDelay(_ seconds: TimeInterval) {
        subtitleDelay = seconds
        engine.setSoftwareSubtitleDelay(seconds)
        refreshSubtitles()
    }

    // MARK: Tracks

    public func selectAudio(id: Int?) {
        guard let id else { return }   // AetherEngine always plays one audio track
        pendingAudio = id
        engine.selectAudioTrack(index: id)
        publishTracks()
    }

    public func selectSubtitle(id: Int?) {
        pendingSubtitle = .some(id)
        if let id { engine.selectSubtitleTrack(index: id) } else { engine.clearSubtitle() }
        publishTracks()
    }

    /// Adds a subtitle file (downloaded by the engine with these headers) and selects it.
    public func addSubtitle(url: URL, title: String, language: String?, headers: [String: String]) {
        let track = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: url, name: title, language: language,
                                                                          httpHeaders: headers.isEmpty ? nil : headers))
        engine.selectSubtitleTrack(index: track.id)
        publishTracks()
    }

    // MARK: Picture and subtitles

    /// Whether the stream is Dolby Vision with a base layer to switch to, so the switch is worth offering. Not profile 5: it has none.
    public var isDolbyVisionSource: Bool {
        guard isLoaded, engine.sourceDVProfile != 5 else { return false }
        return engine.sourceDVProfile != nil || engine.sourceVideoFormat == .dolbyVision
    }

    /// Off plays the HDR10 / HLG base layer instead (AetherEngine keeps Dolby Vision on a profile 5 stream, which has none). A playing
    /// session is rebuilt where it is; before the load it is part of the load.
    public func setDolbyVision(_ enabled: Bool) {
        guard options.dolbyVision != enabled else { return }
        options.dolbyVision = enabled
        guard isLoaded else { return }
        let generation = generation
        Task { [weak self] in
            guard let self, generation == self.generation else { return }
            _ = try? await self.engine.reloadAtCurrentPosition { $0.dolbyVisionHandling = enabled ? .automatic : .baseLayerOnly }
        }
    }

    /// `aspect` replaces the file's width over height; `crop` keeps a centred part of that shape. nil leaves either alone.
    public func apply(fit: AetherFit, zoom: Double, aspect: Double? = nil, crop: Double? = nil) {
        host.fit = fit
        host.zoom = max(1, zoom)
        host.aspect = aspect
        host.crop = crop
    }

    public func apply(subtitleStyle: AetherSubtitleStyle) {
        host.overlay.style = subtitleStyle
        refreshSubtitles()
    }

    // MARK: Statistics

    public func statistics() -> AetherStatistics {
        var stats = AetherStatistics(engine: "AetherEngine (\(Self.routeName(engine.videoRoute)))")
        stats.decoder = engine.activeVideoDecoder
        stats.videoCodec = engine.sourceVideoCodecName
        if engine.sourceVideoWidth > 0 {
            stats.width = Int(engine.sourceVideoWidth)
            stats.height = Int(engine.sourceVideoHeight)
        }
        stats.frameRate = engine.sourceVideoFrameRate
        stats.videoBitrate = engine.sourceVideoBitrate > 0 ? Double(engine.sourceVideoBitrate) : nil
        stats.bufferedAhead = max(0, engine.clock.bufferedPosition - engine.clock.currentTime)
        let stream = engine.sourceVideoStreamFormat
        let colourDetails = [stream?.transferLabel, stream?.colorPrimariesLabel, stream?.bitDepth.map { "\($0)-bit" }].compactMap { $0 }
        let source = Self.formatName(engine.sourceVideoFormat)
        stats.sourceColour = colourDetails.isEmpty ? source : "\(source) (\(colourDetails.joined(separator: ", ")))"
        stats.outputColour = Self.formatName(engine.videoFormat)
        if let profile = engine.sourceDVProfile {
            var text = "Profile \(profile)"
            if profile == 7 {
                if engine.dolbyVisionConversion == .profile7ToProfile81 {
                    text += ", converted to 8.1 (enhancement layer dropped)"
                } else if engine.videoRoute == .software, options.composesFEL {
                    text += ", both layers composed on the GPU (FEL) with per-frame 8.1 metadata"
                } else {
                    text += ", base layer"
                }
            }
            stats.dolbyVision = text
        }
        if let audio = engine.audioTracks.first(where: { $0.id == engine.activeAudioTrackIndex }) {
            stats.audioCodec = Self.audioName(audio)
            stats.audioChannels = audio.channels > 0 ? Self.channelLayout(audio.channels) + (audio.sampleRate > 0 ? ", \(Double(audio.sampleRate) / 1000) kHz" : "") : nil
            stats.audioBitrate = audio.bitrate > 0 ? Double(audio.bitrate) : nil
        }
        stats.audioOutput = [Self.deliveryName(engine.audioDelivery), engine.activeAudioDecoder].compactMap { $0 }.joined(separator: " · ")
        if let container = engine.sourceContainerFormat { stats.notes.append("Container: \(container).") }
        if engine.airPlayPictureStaysLocal { stats.notes.append("AirPlay plays this title's sound only; the picture stays on this device.") }
        return stats
    }

    public func shutdown() {
        #if DEBUG
        trace.end()
        #endif
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        subscriptions.removeAll()
        engine.stop()
        engine.unbind(view: host.playerView)
        continuation.finish()
    }

    // MARK: Observation

    private func observe() {
        engine.$state.receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.publishTransport() }
        }.store(in: &subscriptions)
        engine.$playbackPhase.receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.publishTransport() }
        }.store(in: &subscriptions)
        engine.clock.$currentTime.receive(on: RunLoop.main).sink { [weak self] time in
            MainActor.assumeIsolated { self?.publishPosition(time) }
        }.store(in: &subscriptions)
        // AetherEngine's player often publishes the length a moment after the load has finished. Reported only at load, the
        // timeline had no length for the whole film: no time left, no scrubbing and no swipe to seek.
        engine.$duration.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] duration in
            MainActor.assumeIsolated { self?.publishDuration(duration) }
        }.store(in: &subscriptions)
        engine.clock.$bufferedPosition.receive(on: RunLoop.main).sink { [weak self] until in
            MainActor.assumeIsolated {
                guard let self, self.isLoaded, abs(until - self.lastBuffered) >= 0.5 else { return }
                self.lastBuffered = until
                self.continuation.yield(.buffered(until))
            }
        }.store(in: &subscriptions)
        for publisher in [engine.$audioTracks.map { _ in () }.eraseToAnyPublisher(),
                          engine.$subtitleTracks.map { _ in () }.eraseToAnyPublisher(),
                          engine.$activeAudioTrackIndex.map { _ in () }.eraseToAnyPublisher(),
                          engine.$activeSubtitleTrackIndex.map { _ in () }.eraseToAnyPublisher(),
                          engine.$isSubtitleActive.map { _ in () }.eraseToAnyPublisher(),
                          engine.$isLoadingSubtitles.map { _ in () }.eraseToAnyPublisher()] {
            publisher.receive(on: RunLoop.main).sink { [weak self] in
                MainActor.assumeIsolated { self?.publishTracks() }
            }.store(in: &subscriptions)
        }
        engine.$mediaChapters.receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.publishChapters() }
        }.store(in: &subscriptions)
        engine.$subtitleCues.receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSubtitles() }
        }.store(in: &subscriptions)
        engine.clock.$sourceTime.receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSubtitles() }
        }.store(in: &subscriptions)
        // This publisher is backed by the native or sample-buffer layer's actual
        // display readiness. Transport .playing can precede it by several seconds.
        engine.$hasFirstFrameReadyForDisplay.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] ready in
            MainActor.assumeIsolated {
                guard let self, self.isLoaded, ready else { return }
                self.continuation.yield(.videoFrameReady)
            }
        }.store(in: &subscriptions)
        engine.$softwareDisplaySize.receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isLoaded else { return }
                self.host.displaySize = self.presentedSize()
            }
        }.store(in: &subscriptions)
    }

    private func publishTransport() {
        guard isLoaded else {
            if case .error = engine.state { continuation.yield(.failed(failure(thrown: nil))) }
            return
        }
        switch engine.state {
        case .error:
            continuation.yield(.failed(failure(thrown: nil)))
            return
        case .ended:
            if !hasEnded {
                hasEnded = true
                continuation.yield(.ended)
            }
            return
        case .playing:
            setPausedState(false)
        case .paused:
            setPausedState(true)
        case .idle, .loading, .seeking:
            break
        }
        let buffering = switch engine.playbackPhase {
        case .rebuffering, .stalled: true
        default: false
        }
        if buffering != bufferingState {
            bufferingState = buffering
            #if DEBUG
            trace.note("buffering=\(buffering) phase=\(engine.playbackPhase)")
            #endif
            continuation.yield(.buffering(buffering))
        }
    }

    private func setPausedState(_ paused: Bool) {
        guard pausedState != paused else { return }
        pausedState = paused
        continuation.yield(.paused(paused))
    }

    private func publishDuration(_ duration: Double) {
        guard isLoaded, duration.isFinite, duration > 0, duration != lastDuration else { return }
        lastDuration = duration
        continuation.yield(.duration(duration))
    }

    private func publishPosition(_ time: Double) {
        guard isLoaded, time.isFinite, abs(time - lastPosition) >= 0.2 else { return }
        lastPosition = time
        continuation.yield(.position(max(0, time)))
    }

    private func currentTracks() -> (audio: [AetherTrack], subtitles: [AetherTrack], audioID: Int?, subtitleID: Int?) {
        var audioID = engine.activeAudioTrackIndex
        if let pending = pendingAudio {
            if pending == audioID || errorStateReached { pendingAudio = nil } else { audioID = pending }
        }
        var subtitleID = engine.isSubtitleActive ? engine.activeSubtitleTrackIndex : nil
        if let pending = pendingSubtitle {
            // Settled once AetherEngine reports the pick, or has stopped loading without taking it.
            if pending == subtitleID || (!engine.isLoadingSubtitles && pending == nil) { pendingSubtitle = nil } else { subtitleID = pending }
        }
        return (engine.audioTracks.map(Self.track), engine.subtitleTracks.map(Self.track), audioID, subtitleID)
    }

    private var errorStateReached: Bool {
        if case .error = engine.state { return true }
        return false
    }

    private func publishTracks() {
        guard isLoaded else { return }
        let next = currentTracks()
        if let last = lastTracks, last.audio == next.audio, last.subtitles == next.subtitles, last.audioID == next.audioID,
           last.subtitleID == next.subtitleID { return }
        lastTracks = next
        continuation.yield(.tracks(audio: next.audio, subtitles: next.subtitles, selectedAudio: next.audioID, selectedSubtitle: next.subtitleID))
    }

    private func publishChapters() {
        guard isLoaded else { return }
        let chapters = engine.mediaChapters.enumerated().map { index, chapter in
            AetherChapter(title: chapter.name.isEmpty ? "Chapter \(index + 1)" : chapter.name, start: max(0, chapter.startSeconds))
        }
        guard chapters != lastChapters else { return }
        lastChapters = chapters
        continuation.yield(.chapters(chapters))
    }

    private func refreshSubtitles() {
        host.overlay.show(cues: engine.subtitleCues, at: engine.clock.sourceTime - subtitleDelay)
    }

    // MARK: Helpers

    /// Multichannel PCM and spatial audio reach the routes that take them; the system downmixes for headphones and the speaker.
    private static func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        try? session.setSupportsMultichannelContent(true)
        try? session.setActive(true)
    }

    private func failure(thrown error: Error?) -> AetherFailure {
        if let info = engine.errorInfo { return Self.failure(info) }
        let message = error?.localizedDescription ?? "AetherEngine could not play this stream."
        if let error = error as? URLError {
            return AetherFailure(kind: error.code == .userAuthenticationRequired ? .unauthorized : .network, message: message)
        }
        return AetherFailure(kind: .other, message: message)
    }

    static func failure(_ info: PlaybackErrorInfo) -> AetherFailure {
        let kind: AetherFailure.Kind
        switch info.kind {
        case .sourceRefused:
            switch info.underlyingCode {
            case 401, 403: kind = .unauthorized
            case 404, 410: kind = .notFound
            default: kind = .network
            }
        case .sourceOpenFailed:
            kind = info.underlyingDomain == NSURLErrorDomain ? .network : .format
        case .sourceCertificateRejected, .sourceRateLimited, .vodSourceFailed, .liveSourceUnavailable, .storageExhausted:
            kind = .network
        case .customSourceProbeFailed, .dolbyVisionRequiresHardware, .nativeItemFailed, .noPlayableTrackWithinBudget,
             .masterPlaylistRejected, .softwarePipelineFailed, .audioBridgeProducedNoOutput, .demuxedAudioLiveUnsupported:
            kind = .format
        default:
            kind = .other
        }
        return AetherFailure(kind: kind, message: info.message)
    }

    static func track(_ info: TrackInfo) -> AetherTrack {
        AetherTrack(id: info.id, name: info.name, codec: info.codec, language: info.language, channels: info.channels,
                    isDefault: info.isDefault, isForced: info.isForced, isHearingImpaired: info.isHearingImpaired,
                    isCommentary: info.isCommentary, isAtmos: info.isAtmos, isDTSX: info.isDTSX, isExternal: info.isExternal)
    }

    private static func routeName(_ route: VideoRoute) -> String {
        switch route {
        case .none: "starting"
        case .remoteBypass: "AVPlayer, direct"
        case .loopback: "AVPlayer, remuxed"
        case .software: "VideoToolbox + Metal"
        case .audio: "audio only"
        }
    }

    private static func formatName(_ format: VideoFormat) -> String {
        switch format {
        case .sdr: "SDR"
        case .hdr10: "HDR10"
        case .hdr10Plus: "HDR10+"
        case .dolbyVision: "Dolby Vision"
        case .hlg: "HLG"
        }
    }

    private static func deliveryName(_ delivery: AudioDelivery) -> String? {
        switch delivery {
        case .none: nil
        case .noAudioInSource: "No audio in the source"
        case .streamCopy: "Passed to the system untouched"
        case .bridged: "Re-encoded for the system"
        case .decoded: "Decoded to PCM"
        case .droppedNoPipeline: "Not playing: no pipeline for this audio"
        case .playerManaged: "Played by AVPlayer"
        }
    }

    static func audioName(_ track: TrackInfo) -> String {
        let base: String = switch track.codec {
        case "ac3": "Dolby Digital"
        case "eac3": "Dolby Digital Plus"
        case "truehd", "mlp": "TrueHD"
        case "dts": track.profile?.contains("MA") == true ? "DTS-HD MA" : "DTS"
        case "aac": "AAC"
        case "flac": "FLAC"
        case "opus": "Opus"
        default: track.codec.uppercased()
        }
        if track.isAtmos { return "\(base) + Atmos" }
        if track.isDTSX { return "\(base) + DTS:X" }
        return base
    }

    static func channelLayout(_ count: Int) -> String {
        switch count {
        case 1: "mono"
        case 2: "stereo"
        case 6: "5.1"
        case 7: "6.1"
        case 8: "7.1"
        default: "\(count) ch"
        }
    }
}

/// The engine's player view, placed for the aspect override, crop, fit and zoom, with the subtitle overlay on the part that shows.
final class AetherHostView: UIView {
    let playerView = AetherPlayerView()
    let overlay = AetherSubtitleOverlay()
    /// Clips the picture to its visible part, so a crop hides the bars.
    private let clipView = UIView()
    /// Over the picture and the same size: carries a layer drawn over it (`hostPictureOverlay`).
    private let pictureOverlayView = UIView()
    private weak var pictureOverlay: CALayer?
    var fit = AetherFit.fit { didSet { if fit != oldValue { setNeedsLayout() } } }
    var zoom = 1.0 { didSet { if zoom != oldValue { setNeedsLayout() } } }
    /// Width over height replacing the file's; nil keeps it.
    var aspect: Double? { didSet { if aspect != oldValue { setNeedsLayout() } } }
    /// Width over height to crop the picture to, centred; nil keeps it whole.
    var crop: Double? { didSet { if crop != oldValue { setNeedsLayout() } } }
    /// The picture's presented size, when the engine says it.
    var displaySize: CGSize? { didSet { if displaySize != oldValue { setNeedsLayout() } } }
    /// Tells the engine how to draw into the player view: stretched into the frame laid out here, or by fit before the size is known.
    var onGravity: (@MainActor (AVLayerVideoGravity) -> Void)?
    private var lastGravity: AVLayerVideoGravity?
    var currentGravity: AVLayerVideoGravity { lastGravity ?? .resizeAspect }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        isAccessibilityElement = false
        clipView.clipsToBounds = true
        clipView.isUserInteractionEnabled = false
        clipView.addSubview(playerView)
        pictureOverlayView.isUserInteractionEnabled = false
        pictureOverlayView.backgroundColor = .clear
        clipView.addSubview(pictureOverlayView)
        addSubview(clipView)
        addSubview(overlay)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The picture never animates into place: a new size or scaling mode would otherwise slide it up or down for a moment, as the
        // engine's layer animates its gravity and bounds by default.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        playerView.transform = .identity
        let gravity: AVLayerVideoGravity
        if let size = displaySize, let layout = Self.geometry(bounds: bounds.size, source: size, aspect: aspect, crop: crop, fit: fit, zoom: zoom) {
            clipView.frame = layout.visible
            playerView.frame = layout.picture.offsetBy(dx: -layout.visible.minX, dy: -layout.visible.minY)
            overlay.frame = bounds
            overlay.videoRect = layout.visible
            gravity = .resize
        } else {
            clipView.frame = bounds
            playerView.frame = bounds
            playerView.transform = CGAffineTransform(scaleX: zoom, y: zoom)
            overlay.frame = bounds
            overlay.videoRect = bounds
            gravity = switch fit {
            case .fit: .resizeAspect
            case .fill: .resizeAspectFill
            case .stretch: .resize
            }
        }
        if gravity != lastGravity {
            lastGravity = gravity
            onGravity?(gravity)
        }
        // The frame the picture shows in, transform included.
        pictureOverlayView.frame = playerView.frame
        pictureOverlay?.frame = pictureOverlayView.bounds
        (pictureOverlay as? AVSampleBufferDisplayLayer)?.videoGravity = gravity
    }

    func hostPictureOverlay(_ layer: CALayer?) {
        if layer == nil && pictureOverlay == nil { return }
        guard layer !== pictureOverlay || layer?.superlayer !== pictureOverlayView.layer else { return }
        if pictureOverlay?.superlayer === pictureOverlayView.layer { pictureOverlay?.removeFromSuperlayer() }
        pictureOverlay = layer
        if let layer { pictureOverlayView.layer.addSublayer(layer) }
        setNeedsLayout()
    }

    /// The whole picture's frame and the part of it that shows. Blusion's `VideoGeometry` (PlayerKit) does the same; this framework
    /// links no Blusion package, so it keeps this copy.
    static func geometry(bounds: CGSize, source: CGSize, aspect: Double?, crop: Double?, fit: AetherFit, zoom: Double)
        -> (picture: CGRect, visible: CGRect)? {
        guard bounds.width > 0, bounds.height > 0, source.width > 0, source.height > 0 else { return nil }
        let ratio = aspect ?? Double(source.width / source.height)
        var keptWidth = 1.0, keptHeight = 1.0
        if let crop, crop > 0 {
            if crop > ratio { keptHeight = ratio / crop } else { keptWidth = crop / ratio }
        }
        let shownRatio = ratio * keptWidth / keptHeight
        let viewRatio = Double(bounds.width / bounds.height)
        var width: Double, height: Double
        switch fit {
        case .fit, .fill:
            if (fit == .fit) == (viewRatio < shownRatio) {
                width = Double(bounds.width)
                height = width / shownRatio
            } else {
                height = Double(bounds.height)
                width = height * shownRatio
            }
        case .stretch:
            width = Double(bounds.width)
            height = Double(bounds.height)
        }
        width *= max(1, zoom)
        height *= max(1, zoom)
        let shown = CGRect(x: (Double(bounds.width) - width) / 2, y: (Double(bounds.height) - height) / 2, width: width, height: height)
        let picture = CGRect(x: shown.midX - width / keptWidth / 2, y: shown.midY - height / keptHeight / 2,
                             width: width / keptWidth, height: height / keptHeight)
        return (picture, shown.intersection(CGRect(origin: .zero, size: bounds)))
    }
}

/// Draws the engine's subtitle cues: text (plain or styled runs) and pictures (PGS, VobSub, DVB).
final class AetherSubtitleOverlay: UIView {
    var style = AetherSubtitleStyle() { didSet { needsRestyle = true } }
    var videoRect: CGRect = .zero { didSet { if videoRect != oldValue { setNeedsLayout() } } }
    private var shown: [SubtitleCue] = []
    private var textViews: [UILabel] = []
    private var imageViews: [UIImageView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(cues: [SubtitleCue], at time: Double) {
        let active = cues.filter { $0.startTime <= time && time < $0.endTime }
        if active.map(\.id) == shown.map(\.id), !needsRestyle { return }
        needsRestyle = false
        shown = active
        rebuild()
    }

    private var needsRestyle = false

    override func layoutSubviews() {
        super.layoutSubviews()
        rebuild()
    }

    private func rebuild() {
        textViews.forEach { $0.removeFromSuperview() }
        imageViews.forEach { $0.removeFromSuperview() }
        textViews = []
        imageViews = []
        let rect = videoRect.isEmpty ? bounds : videoRect
        guard rect.width > 0, rect.height > 0 else { return }
        let fontSize = max(14, rect.height * 0.05 * style.scale)
        var bottom = rect.maxY - rect.height * style.bottomMarginPercent / 100
        // Later cues stack above earlier ones, as players do.
        for cue in shown.reversed() {
            switch cue.body {
            case .image(let image):
                let view = UIImageView(image: UIImage(cgImage: image.cgImage))
                view.frame = Self.imageRect(image, in: rect)
                addSubview(view)
                imageViews.append(view)
            case .text(let text):
                bottom = place(attributed(runs: [SubtitleTextRun(text: text, color: nil)], fontSize: fontSize), placement: cue.placement,
                               in: rect, bottom: bottom, fontSize: fontSize)
            case .richText(let runs):
                bottom = place(attributed(runs: runs, fontSize: fontSize), placement: cue.placement, in: rect, bottom: bottom, fontSize: fontSize)
            }
        }
    }

    /// Positions one text block; returns the new bottom for the default (stacked) placement.
    private func place(_ text: NSAttributedString, placement: SubtitleTextPlacement?, in rect: CGRect, bottom: CGFloat, fontSize: CGFloat) -> CGFloat {
        guard text.length > 0 else { return bottom }
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.attributedText = text
        if style.boxed {
            label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            label.layer.cornerRadius = fontSize * 0.2
            label.layer.masksToBounds = true
        } else {
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.9
            label.layer.shadowRadius = 2
            label.layer.shadowOffset = .zero
        }
        let pad = style.boxed ? fontSize * 0.3 : 0
        let fitted = label.sizeThatFits(CGSize(width: rect.width * 0.9 - pad * 2, height: .greatestFiniteMagnitude))
        let size = CGSize(width: fitted.width + pad * 2, height: fitted.height + pad)
        let origin: CGPoint
        var nextBottom = bottom
        if let placement, placement.alignment.map({ $0 > 3 }) == true || placement.position != nil {
            origin = Self.blockOrigin(placement, size: size, in: rect, margin: rect.height * style.bottomMarginPercent / 100)
        } else {
            origin = CGPoint(x: rect.midX - size.width / 2, y: bottom - size.height)
            nextBottom = origin.y - fontSize * 0.2
        }
        label.frame = CGRect(origin: origin, size: size)
        addSubview(label)
        textViews.append(label)
        return nextBottom
    }

    private func attributed(runs: [SubtitleTextRun], fontSize: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base = UIColor(red: style.red, green: style.green, blue: style.blue, alpha: 1)
        for run in runs {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if run.isBold, !style.overridesFileStyles { traits.insert(.traitBold) }
            if run.isItalic { traits.insert(.traitItalic) }
            var font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: fontSize) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if let colour = run.color, !style.overridesFileStyles {
                attributes[.foregroundColor] = UIColor(red: CGFloat(colour.r) / 255, green: CGFloat(colour.g) / 255, blue: CGFloat(colour.b) / 255, alpha: 1)
            } else {
                attributes[.foregroundColor] = base
            }
            if !style.boxed {
                attributes[.strokeColor] = UIColor.black
                attributes[.strokeWidth] = -3.0
            }
            if run.isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.isStruckThrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// `position` is normalised against the subtitle canvas, which maps onto the picture width-aligned and centred vertically
    /// (AetherEngine's `SubtitleImage` contract; a cropped rip's canvas is taller than the picture).
    static func imageRect(_ image: SubtitleImage, in rect: CGRect) -> CGRect {
        let position = image.position
        let canvas = image.canvasSize
        guard canvas.width > 0, canvas.height > 0 else {
            return CGRect(x: rect.minX + position.minX * rect.width, y: rect.minY + position.minY * rect.height,
                          width: position.width * rect.width, height: position.height * rect.height)
        }
        let scale = rect.width / canvas.width
        return CGRect(x: rect.minX + position.minX * canvas.width * scale,
                      y: rect.midY + (position.minY * canvas.height - canvas.height / 2) * scale,
                      width: position.width * canvas.width * scale, height: position.height * canvas.height * scale)
    }

    /// ASS numpad alignment (1–3 bottom, 4–6 middle, 7–9 top); with a position, the point is the anchor. Top-left coordinates.
    static func blockOrigin(_ placement: SubtitleTextPlacement, size: CGSize, in rect: CGRect, margin: CGFloat) -> CGPoint {
        let alignment = placement.alignment ?? 2
        let column = (alignment - 1) % 3
        let row = (alignment - 1) / 3
        guard let position = placement.position else {
            let x = column == 0 ? rect.minX + margin : column == 1 ? rect.midX - size.width / 2 : rect.maxX - size.width - margin
            let y = row == 0 ? rect.maxY - size.height - margin : row == 1 ? rect.midY - size.height / 2 : rect.minY + margin
            return CGPoint(x: x, y: y)
        }
        let anchorX = rect.minX + position.x * rect.width
        let anchorY = rect.minY + position.y * rect.height
        let x = column == 0 ? anchorX : column == 1 ? anchorX - size.width / 2 : anchorX - size.width
        let y = row == 0 ? anchorY - size.height : row == 1 ? anchorY - size.height / 2 : anchorY
        return CGPoint(x: x, y: y)
    }
}
#endif
