#if canImport(Libmpv) && canImport(UIKit)
import AVFoundation
import Foundation
import Libmpv
import PlayerKit
import QuartzCore
import StremioKit
import UIKit

// The only file in the project that touches the third-party player (ADR-006). If something here does not compile or render, fix this file
// only: the engine, the state mapping and the tests live behind `FallbackBackend` in PlayerKit. Built against MPVKit 0.41 (mpv 0.40 with
// libplacebo, libdovi and libass); every option and property used below is present in that build's libmpv.

/// mpv sets the drawable size itself; ignore the degenerate sizes UIKit layout produces.
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if newValue.width > 1, newValue.height > 1 { super.drawableSize = newValue } }
    }
}

final class MPVHostView: UIView {
    let metalLayer = MPVMetalLayer()
    /// The view has a new width: side margins given in points are worked out again.
    var onResize: (() -> Void)?
    private var laidOutWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        // Lets mpv hand HDR frames to the display as HDR (EDR) when it is asked to (target-colorspace-hint).
        metalLayer.wantsExtendedDynamicRangeContent = true
        layer.addSublayer(metalLayer)
        // A player can be readied before its screen shows (the stream picker holds it on its first frame), so the picture layer has a
        // size of its own from the start: mpv makes its video output on a layer with none and could turn the video off. The screen's
        // layout replaces it.
        metalLayer.frame = bounds
        metalLayer.contentsScale = 2
        metalLayer.drawableSize = CGSize(width: bounds.width * 2, height: bounds.height * 2)
    }

    /// The size the view starts at, before the player screen lays it out.
    static let initialFrame = CGRect(x: 0, y: 0, width: 1280, height: 720)

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The sublayer would otherwise animate to each new size, sliding the picture.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        metalLayer.frame = bounds
        let scale = max(traitCollection.displayScale, 1)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if bounds.width != laidOutWidth {
            laidOutWidth = bounds.width
            onResize?()
        }
    }
}

/// Reads mpv properties. libmpv's property calls are thread-safe, so both the event thread and the main actor use this.
private struct MPVProperties: @unchecked Sendable {
    let handle: OpaquePointer

    func string(_ name: String) -> String? {
        guard let raw = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(raw) }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    func int(_ name: String) -> Int? {
        var value: Int64 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 ? Int(value) : nil
    }

    func double(_ name: String) -> Double? {
        var value = 0.0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 && value.isFinite ? value : nil
    }

    func flag(_ name: String) -> Bool {
        var value: Int32 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 && value != 0
    }

    struct Tracks {
        var audio: [MediaTrack] = []
        var subtitles: [MediaTrack] = []
        var selectedAudio: String?
        var selectedSubtitle: String?
    }

    func tracks() -> Tracks {
        var result = Tracks()
        for index in 0..<(int("track-list/count") ?? 0) {
            let prefix = "track-list/\(index)"
            guard let kind = string("\(prefix)/type"), let id = int("\(prefix)/id") else { continue }
            let language = string("\(prefix)/lang")
            let codec = string("\(prefix)/codec")
            let forced = flag("\(prefix)/forced")
            let hearingImpaired = flag("\(prefix)/hearing-impaired") || flag("\(prefix)/visual-impaired")
            let channels = int("\(prefix)/demux-channel-count")
            let external = flag("\(prefix)/external")
            let named = string("\(prefix)/title")
            let selected = flag("\(prefix)/selected")
            let isDefault = flag("\(prefix)/default")
            switch kind {
            case "audio":
                let title = Self.title(named, language: language, id: id, details: [Self.audioLabel(codec, channels: channels)])
                result.audio.append(MediaTrack(id: "a\(id)", title: title, language: language, isDefault: isDefault, isHearingImpaired: hearingImpaired,
                                               codec: codec, channelCount: channels, isExternal: external))
                if selected { result.selectedAudio = "a\(id)" }
            case "sub":
                let details = [forced && named?.localizedCaseInsensitiveContains("forced") != true ? "Forced" : nil,
                               hearingImpaired && named?.range(of: #"\b(sdh|cc)\b"#, options: [.regularExpression, .caseInsensitive]) == nil ? "SDH" : nil,
                               Self.subtitleLabel(codec)]
                let title = Self.title(named, language: language, id: id, details: details)
                result.subtitles.append(MediaTrack(id: "s\(id)", title: title, language: language, isDefault: isDefault, isForced: forced,
                                                   isHearingImpaired: hearingImpaired, codec: codec, isExternal: external))
                if selected { result.selectedSubtitle = "s\(id)" }
            default:
                break
            }
        }
        return result
    }

    func chapters() -> [Chapter] {
        (0..<(int("chapter-list/count") ?? 0)).compactMap { index in
            guard let time = double("chapter-list/\(index)/time") else { return nil }
            return Chapter(index: index, title: string("chapter-list/\(index)/title") ?? "Chapter \(index + 1)", start: max(0, time))
        }
    }

    /// "English · TrueHD 7.1": the file's own title when it has one, else the language, then what the menu needs to tell tracks apart.
    private static func title(_ named: String?, language: String?, id: Int, details: [String?]) -> String {
        let base = named ?? language.map { LanguageCodes.displayName($0) } ?? "Track \(id)"
        let extra = details.compactMap { $0 }.filter { !base.localizedCaseInsensitiveContains($0) }
        return ([base] + extra).joined(separator: " · ")
    }

    static func audioLabel(_ codec: String?, channels: Int?) -> String? {
        let name: String? = switch codec {
        case "ac3": "Dolby Digital"
        case "eac3": "Dolby Digital Plus"
        case "truehd", "mlp": "TrueHD"
        case "dts": "DTS"
        case "aac": "AAC"
        case "flac": "FLAC"
        case "opus": "Opus"
        case "mp3": "MP3"
        case let codec? where codec.hasPrefix("pcm"): "PCM"
        default: codec?.uppercased()
        }
        guard let name else { return nil }
        return channels.map { "\(name) \(channelLayout($0))" } ?? name
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

    static func subtitleLabel(_ codec: String?) -> String? {
        switch codec {
        case "ass", "ssa": "ASS"
        case "hdmv_pgs_subtitle": "PGS"
        case "dvd_subtitle": "VobSub"
        case "dvb_subtitle": "DVB"
        case "subrip", "srt": "SRT"
        case "webvtt": "WebVTT"
        case "mov_text": "Text"
        default: nil
        }
    }
}

/// Polls mpv's event queue on its own thread and turns events into `FallbackEvent`s.
private final class MPVEventPump: @unchecked Sendable {
    private let handle: OpaquePointer
    private let properties: MPVProperties
    private let continuation: AsyncStream<FallbackEvent>.Continuation
    /// The video's size or format changed (a new file, a filter change): the crop and the Dolby Vision filter depend on it.
    private let onVideoReconfig: @Sendable () -> Void
    private let lock = NSLock()
    private var running = true
    private let exited = DispatchSemaphore(value: 0)

    init(handle: OpaquePointer, continuation: AsyncStream<FallbackEvent>.Continuation, onVideoReconfig: @escaping @Sendable () -> Void) {
        self.handle = handle
        self.properties = MPVProperties(handle: handle)
        self.continuation = continuation
        self.onVideoReconfig = onVideoReconfig
    }

    func start() {
        Thread.detachNewThread { [self] in
            run()
            exited.signal()
        }
    }

    /// Stops the loop and waits for it to leave mpv, so the handle can be destroyed safely.
    func stopAndWait() {
        lock.withLock { running = false }
        mpv_wakeup(handle)
        _ = exited.wait(timeout: .now() + 2)
    }

    private var isRunning: Bool { lock.withLock { running } }

    private func run() {
        var lastPosition = -1.0
        var loaded = false
        while isRunning {
            guard let event = mpv_wait_event(handle, 0.25)?.pointee else { continue }
            switch event.event_id {
            case MPV_EVENT_SHUTDOWN:
                return
            case MPV_EVENT_START_FILE:
                loaded = false
            case MPV_EVENT_FILE_LOADED:
                loaded = true
                let tracks = properties.tracks()
                continuation.yield(.loaded(duration: properties.double("duration"), audio: tracks.audio, subtitles: tracks.subtitles,
                                           selectedAudio: tracks.selectedAudio, selectedSubtitle: tracks.selectedSubtitle))
                continuation.yield(.chapters(properties.chapters()))
            case MPV_EVENT_END_FILE:
                guard let data = event.data else { continue }
                let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end.reason == MPV_END_FILE_REASON_EOF {
                    continuation.yield(.ended)
                } else if end.reason == MPV_END_FILE_REASON_ERROR {
                    continuation.yield(.failed(Self.failure(code: end.error)))
                }
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let data = event.data else { continue }
                let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                let name = String(cString: property.name)
                // Track and chapter changes are re-read in full; their value in the event is not needed.
                if loaded, ["track-list/count", "aid", "sid"].contains(name) {
                    let tracks = properties.tracks()
                    continuation.yield(.tracks(audio: tracks.audio, subtitles: tracks.subtitles, selectedAudio: tracks.selectedAudio,
                                               selectedSubtitle: tracks.selectedSubtitle))
                    continue
                }
                if loaded, name == "chapter-list/count" {
                    continuation.yield(.chapters(properties.chapters()))
                    continue
                }
                guard let value = property.data else { continue }
                switch (name, property.format) {
                case ("time-pos", MPV_FORMAT_DOUBLE):
                    let position = value.assumingMemoryBound(to: Double.self).pointee
                    if abs(position - lastPosition) >= 0.2 {
                        lastPosition = position
                        continuation.yield(.position(position))
                    }
                case ("demuxer-cache-time", MPV_FORMAT_DOUBLE):
                    continuation.yield(.buffered(value.assumingMemoryBound(to: Double.self).pointee))
                case ("pause", MPV_FORMAT_FLAG):
                    continuation.yield(.paused(value.assumingMemoryBound(to: Int32.self).pointee != 0))
                case ("paused-for-cache", MPV_FORMAT_FLAG):
                    continuation.yield(.buffering(value.assumingMemoryBound(to: Int32.self).pointee != 0))
                default:
                    break   // durations of live streams can change later and are ignored
                }
            case MPV_EVENT_PLAYBACK_RESTART:
                // Unlike FILE_LOADED / pause=false, restart follows output preroll.
                // Audio-only files have no picture and must not claim frame readiness.
                if loaded, (properties.int("video-out-params/w") ?? 0) > 0 {
                    continuation.yield(.videoFrameReady)
                }
            case MPV_EVENT_VIDEO_RECONFIG:
                onVideoReconfig()
            default:
                break
            }
        }
    }

    private static func failure(code: Int32) -> PlaybackFailure {
        let text = String(cString: mpv_error_string(code))
        switch code {
        case MPV_ERROR_UNKNOWN_FORMAT.rawValue, MPV_ERROR_UNSUPPORTED.rawValue: return PlaybackFailure(.format, text)
        case MPV_ERROR_LOADING_FAILED.rawValue: return PlaybackFailure(.network, text)
        default: return PlaybackFailure(.other, text)
        }
    }
}

/// `FallbackBackend` on libmpv (MPVKit, LGPL build). Renders through a CAMetalLayer (gpu-next on MoltenVK) with VideoToolbox hardware decoding,
/// libplacebo tone mapping and Dolby Vision (profiles 5 and 8, and 7's base layer with its RPU), and libass for styled subtitles.
@MainActor
public final class MPVBackend: FallbackBackend {
    private let host = MPVHostView(frame: MPVHostView.initialFrame)
    private var handle: OpaquePointer?
    private var pump: MPVEventPump?
    private let events: AsyncStream<FallbackEvent>
    private let continuation: AsyncStream<FallbackEvent>.Continuation
    private var processing = VideoProcessing()
    private var layout = VideoLayout()
    /// What was last set, so a reconfig that follows a change doesn't set it again (setting `vf` reconfigures the video once more).
    private var appliedCrop: String?
    private var appliedMargin: String?
    private var appliedFilter: String?
    /// The playing video's Dolby Vision profile, read at each reconfig; nil when it has none.
    private var dolbyVisionProfile: Int?
    private var downloads: [Task<Void, Never>] = []
    private var temporaryFiles: [URL] = []

    public var videoSurface: AnyObject { host }

    public var capabilities: EngineCapabilities {
        var capabilities: EngineCapabilities = [.engineSubtitles, .subtitleDelay, .audioDelay, .externalAudio, .aspectOverride, .deinterlace,
                                                .toneMapping, .subtitleStyling, .videoLayout, .upscaling]
        // Profile 5 has no HDR10 picture under its Dolby Vision, so there is nothing to switch to.
        if let profile = dolbyVisionProfile, profile != 5 { capabilities.insert(.dolbyVisionSwitch) }
        return capabilities
    }

    public init() {
        let (events, continuation) = AsyncStream<FallbackEvent>.makeStream()
        self.events = events
        self.continuation = continuation
        Self.activateAudioSession()
        setUp()
        host.onResize = { [weak self] in self?.applyMargins() }
    }

    public func makeEventStream() -> AsyncStream<FallbackEvent> { events }

    /// Multichannel PCM reaches HDMI adapters and AirPlay receivers that take it; the system downmixes for headphones and the speaker.
    private static func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setSupportsMultichannelContent(true)
        try? session.setActive(true)
        try? session.setPreferredOutputNumberOfChannels(max(2, session.maximumOutputNumberOfChannels))
    }

    /// Bigger buffers on devices with the memory for them: a 4K remux runs at 60–100 Mbit/s, so 400 MB is about half a minute.
    private static var cacheBytes: String {
        ProcessInfo.processInfo.physicalMemory >= 6 * 1_073_741_824 ? "400MiB" : "150MiB"
    }

    private func setUp() {
        guard let handle = mpv_create() else {
            continuation.yield(.failed(PlaybackFailure(.noEngine, "The fallback player could not start.")))
            return
        }
        self.handle = handle
        let options: [(String, String)] = [
            ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"), ("hwdec", "videotoolbox"),
            ("pause", "yes"), ("keep-open", "no"), ("sub-auto", "no"), ("network-timeout", "30"),
            // Reliability: a deep cache, ffmpeg's own reconnects for dropped HTTP connections, and frame-exact seeks.
            ("cache", "yes"), ("demuxer-max-bytes", Self.cacheBytes), ("demuxer-max-back-bytes", "64MiB"), ("demuxer-readahead-secs", "30"),
            ("cache-pause-wait", "2"), ("stream-buffer-size", "1MiB"),
            ("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=8"),
            ("hr-seek", "yes"), ("hr-seek-framedrop", "yes"),
            // HDR: tell the display what the video is when it can show it, and measure each scene's peak for tone mapping.
            ("target-colorspace-hint", "yes"), ("hdr-compute-peak", "auto"), ("tone-mapping", "auto"),
            // Every channel the output takes (HDMI, AirPlay); `auto-safe` would hold some routes to stereo.
            ("audio-channels", "auto"),
            ("sub-ass-override", "scale"), ("sub-hdr-peak", "203"), ("image-subs-hdr-peak", "203"), ("blend-subtitles", "no"),
            ("deinterlace", "auto"),
        ]
        for (name, value) in options { mpv_set_option_string(handle, name, value) }
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(host.metalLayer).toOpaque()))
        mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)
        guard mpv_initialize(handle) >= 0 else {
            continuation.yield(.failed(PlaybackFailure(.noEngine, "The fallback player could not initialise.")))
            return
        }
        for (name, format) in [("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE), ("demuxer-cache-time", MPV_FORMAT_DOUBLE),
                               ("pause", MPV_FORMAT_FLAG), ("paused-for-cache", MPV_FORMAT_FLAG), ("track-list/count", MPV_FORMAT_INT64),
                               ("chapter-list/count", MPV_FORMAT_INT64), ("aid", MPV_FORMAT_STRING), ("sid", MPV_FORMAT_STRING)] {
            mpv_observe_property(handle, 0, name, format)
        }
        let pump = MPVEventPump(handle: handle, continuation: continuation, onVideoReconfig: { [weak self] in
            Task { @MainActor in self?.applyPicture() }
        })
        self.pump = pump
        pump.start()
    }

    // MARK: FallbackBackend

    public func load(url: URL, headers: [String: String], startPosition: TimeInterval) {
        guard handle != nil else { return }
        set("pause", "yes")
        set("start", startPosition > 0 ? String(startPosition) : "0")
        // List options accept `%length%value` entries so commas inside header values survive.
        let fields = headers.map { name, value -> String in
            let entry = "\(name): \(value)"
            return "%\(entry.utf8.count)%\(entry)"
        }.joined(separator: ",")
        set("http-header-fields", fields)
        command(["loadfile", url.absoluteString, "replace"])
    }

    public func setPaused(_ paused: Bool) { set("pause", paused ? "yes" : "no") }

    public func seek(to position: TimeInterval) async {
        command(["seek", String(position), "absolute+exact"])
    }

    public func setRate(_ rate: Float) { set("speed", String(rate)) }

    /// mpv's volume runs 0 to 100.
    public func setVolume(_ volume: Float) { set("volume", String(volume * 100)) }

    public func setMuted(_ muted: Bool) { set("mute", muted ? "yes" : "no") }

    public func selectAudio(id: String?) {
        set("aid", id.flatMap { Int($0.dropFirst()) }.map(String.init) ?? "no")
    }

    public func selectSubtitle(id: String?) {
        set("sid", id.flatMap { Int($0.dropFirst()) }.map(String.init) ?? "no")
    }

    public func setSubtitleDelay(_ seconds: TimeInterval) { set("sub-delay", String(seconds)) }

    public func setAudioDelay(_ seconds: TimeInterval) { set("audio-delay", String(seconds)) }

    /// Remote files are downloaded first with their own headers: mpv would send the media's request headers (which can carry tokens for
    /// the media host) to the subtitle host too.
    public func addSubtitle(_ subtitle: ExternalSubtitle) {
        let title = subtitle.title
        let language = subtitle.language ?? ""
        if subtitle.url.isFileURL {
            command(["sub-add", subtitle.url.path, "select", title, language])
            return
        }
        let task = Task { [weak self] in
            guard let file = await Self.download(subtitle), !Task.isCancelled, let self else { return }
            self.temporaryFiles.append(file)
            self.command(["sub-add", file.path, "select", title, language])
        }
        downloads.append(task)
    }

    public func addAudio(url: URL, title: String) {
        command(["audio-add", url.isFileURL ? url.path : url.absoluteString, "select", title])
    }

    public func apply(layout: VideoLayout) {
        self.layout = layout
        switch layout.fit {
        case .fit:
            set("keepaspect", "yes")
            set("panscan", "0")
        case .fill:
            set("keepaspect", "yes")
            set("panscan", "1")
        case .stretch:
            set("keepaspect", "no")
            set("panscan", "0")
        }
        // video-zoom is a power of two.
        set("video-zoom", String(log2(layout.zoom)))
        set("video-aspect-override", layout.aspect.ratio.map { String($0) } ?? "no")
        applyMargins()
        applyPicture()
    }

    /// Normal's safe-area inset as mpv's side margins, a share of the view's width. mpv redraws at once: it cannot ease the change in.
    func applyMargins() {
        let width = Double(host.bounds.width)
        let ratio = width > 0 ? min(0.45, layout.inset / width) : 0
        let value = String(format: "%.4f", ratio)
        guard value != appliedMargin else { return }
        if set("video-margin-ratio-left", value), set("video-margin-ratio-right", value) { appliedMargin = value }
    }

    /// The crop (in source pixels, so it needs the video's size) and the Dolby Vision filter. Run again at each video reconfig.
    func applyPicture() {
        guard let handle else { return }
        let read = MPVProperties(handle: handle)
        if let profile = read.int("current-tracks/video/dolby-vision-profile"), profile > 0 { dolbyVisionProfile = profile } else { dolbyVisionProfile = nil }
        var crop = "0x0+0+0"   // no crop
        if let width = read.int("video-params/w"), let height = read.int("video-params/h"), width > 0, height > 0, layout.crop != .off {
            // The whole frame's shape from its pixels and their pixel aspect, never from dw/dh, which can already reflect the crop set
            // here and would undo it on the next reconfig.
            let pixelAspect = read.double("video-params/par").flatMap { $0 > 0 ? $0 : nil } ?? 1
            let shown = layout.aspect.ratio ?? Double(width) * pixelAspect / Double(height)
            let kept = VideoGeometry.keptFraction(aspect: shown, crop: layout.crop.ratio)
            let keptWidth = Int((Double(width) * kept.width).rounded()), keptHeight = Int((Double(height) * kept.height).rounded())
            crop = "\(keptWidth)x\(keptHeight)+\((width - keptWidth) / 2)+\((height - keptHeight) / 2)"
        }
        if crop != appliedCrop, set("video-crop", crop) { appliedCrop = crop }
        // Off strips the Dolby Vision metadata, so libplacebo shows the HDR10 base layer; never for profile 5, which has none.
        let filter = !processing.dolbyVision && dolbyVisionProfile != nil && dolbyVisionProfile != 5 ? "format=dolbyvision=no" : ""
        if filter != (appliedFilter ?? ""), set("vf", filter) { appliedFilter = filter }
    }

    public func apply(processing: VideoProcessing) {
        self.processing = processing
        let deinterlace = switch processing.deinterlace {
        case .auto: "auto"
        case .on: "yes"
        case .off: "no"
        }
        if !set("deinterlace", deinterlace), processing.deinterlace == .auto { set("deinterlace", "no") }
        set("tone-mapping", processing.toneMapping.rawValue)
        let hdr = processing.hdrOutput == .auto
        set("target-colorspace-hint", hdr ? "yes" : "no")
        host.metalLayer.wantsExtendedDynamicRangeContent = hdr
        // mpv's own renderer has no machine-learning scaler in this build, so "AI" uses its sharpest conventional one; the statistics say so.
        switch processing.upscaling {
        case .off:
            set("scale", "lanczos")
        case .quality, .ai:
            set("scale", ProcessInfo.processInfo.isLowPowerModeEnabled ? "spline36" : "ewa_lanczossharp")
        }
        applyPicture()
    }

    public func apply(subtitleStyle style: SubtitleStyle) {
        set("sub-scale", String(style.scale))
        let rgb = style.colour.rgb
        set("sub-color", String(format: "#%02X%02X%02X", Int(rgb.red * 255), Int(rgb.green * 255), Int(rgb.blue * 255)))
        if style.background == .box {
            set("sub-border-style", "background-box")
            set("sub-back-color", "#99000000")
        } else {
            set("sub-border-style", "outline-and-shadow")
        }
        // sub-margin-y counts pixels of a 720-line picture.
        set("sub-margin-y", String(Int((style.bottomMargin / 100 * 720).rounded())))
        set("sub-ass-override", style.overridesFileStyles ? "force" : "scale")
        set("sub-hdr-peak", String(style.hdrPeakNits))
        set("image-subs-hdr-peak", String(style.hdrPeakNits))
    }

    public func statistics() -> PlaybackStatistics {
        guard let handle else { return PlaybackStatistics(engine: "mpv") }
        let read = MPVProperties(handle: handle)
        var stats = PlaybackStatistics(engine: "mpv \(read.string("mpv-version")?.replacingOccurrences(of: "mpv ", with: "") ?? "") (gpu-next)")
        let hwdec = read.string("hwdec-current")
        stats.decoder = hwdec.flatMap { $0 == "no" ? nil : $0 }.map { "Hardware (\($0))" } ?? "Software (FFmpeg)"
        stats.videoCodec = read.string("video-codec") ?? read.string("current-tracks/video/codec")
        stats.width = read.int("video-params/w")
        stats.height = read.int("video-params/h")
        stats.frameRate = read.double("estimated-vf-fps") ?? read.double("container-fps")
        stats.videoBitrate = read.double("video-bitrate")
        stats.audioBitrate = read.double("audio-bitrate")
        stats.networkBitrate = read.double("cache-speed").map { $0 * 8 }
        stats.bufferedAhead = read.double("demuxer-cache-duration")
        stats.droppedFrames = (read.int("frame-drop-count") ?? 0) + (read.int("decoder-frame-drop-count") ?? 0)
        stats.sourceColour = Self.colour(primaries: read.string("video-params/primaries"), gamma: read.string("video-params/gamma"),
                                         peak: read.double("video-params/sig-peak"))
        stats.outputColour = Self.colour(primaries: read.string("video-target-params/primaries"), gamma: read.string("video-target-params/gamma"),
                                         peak: nil).map { output in
            if let nits = read.double("video-target-params/max-luma"), output.hasPrefix("HDR") { return "\(output), \(Int(nits)) nits peak" }
            return output
        }
        if let profile = read.int("current-tracks/video/dolby-vision-profile"), profile > 0 {
            let level = read.int("current-tracks/video/dolby-vision-level").map { ", level \($0)" } ?? ""
            stats.dolbyVision = "Profile \(profile)\(level)"
            if profile == 7 { stats.notes.append("Dolby Vision profile 7: the base layer and its RPU are applied; the enhancement layer (MEL/FEL) is not decoded.") }
            else { stats.notes.append("Dolby Vision RPU metadata is applied by libplacebo (tone-mapped by mpv, not by the display's Dolby Vision decoder).") }
        }
        stats.audioCodec = read.string("audio-codec") ?? read.string("current-tracks/audio/codec")
        if let channels = read.int("audio-params/channel-count") {
            let rate = read.int("audio-params/samplerate").map { ", \(Double($0) / 1000) kHz" } ?? ""
            stats.audioChannels = "\(MPVProperties.channelLayout(channels))\(rate)"
        }
        if let out = read.int("audio-out-params/channel-count") {
            stats.audioOutput = "PCM \(MPVProperties.channelLayout(out)) (\(read.string("current-ao") ?? "audiounit"))"
        }
        let profile = (read.string("current-tracks/audio/codec-profile") ?? "").lowercased()
        // FFmpeg names the object formats in the profile: "Dolby TrueHD + Dolby Atmos", "DTS-HD MA + DTS:X".
        if profile.contains("atmos") || profile.contains("dts:x") {
            stats.notes.append("Object audio (Atmos, DTS:X) is decoded to its PCM channel bed; the objects are not rendered.")
        }
        if processing.upscaling == .ai {
            stats.notes.append("AI super resolution needs the native player or AetherEngine; mpv uses its sharpest conventional scaler (EWA Lanczos) instead.")
        }
        return stats
    }

    public func shutdown() {
        downloads.forEach { $0.cancel() }
        downloads = []
        pump?.stopAndWait()
        pump = nil
        if let handle {
            mpv_terminate_destroy(handle)
            self.handle = nil
        }
        continuation.finish()
        temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryFiles = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Helpers

    /// "HDR10 (PQ, BT.2020, peak 1000 nits)", "HLG (BT.2020)", "SDR (bt.1886, BT.709)". mpv's names: gamma `pq`/`hlg`, primaries `bt.2020`.
    /// HDR10+ dynamic metadata is not reported by mpv, so HDR10+ shows as HDR10.
    private static func colour(primaries: String?, gamma: String?, peak: Double?) -> String? {
        guard let gamma else { return nil }
        var details: [String] = switch gamma {
        case "pq": ["PQ"]
        case "hlg": []
        default: [gamma]
        }
        if let primaries { details.append(primaries.uppercased()) }
        // sig-peak is relative to the 203-nit reference white.
        if let peak, gamma == "pq", peak > 1 { details.append("peak \(Int(peak * 203)) nits") }
        let kind = gamma == "pq" ? "HDR10" : gamma == "hlg" ? "HLG" : "SDR"
        return details.isEmpty ? kind : "\(kind) (\(details.joined(separator: ", ")))"
    }

    private static func download(_ subtitle: ExternalSubtitle) async -> URL? {
        var request = URLRequest(url: subtitle.url, timeoutInterval: 30)
        subtitle.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true, !data.isEmpty else { return nil }
        let name = response.suggestedFilename ?? subtitle.url.lastPathComponent
        let ext = (name as NSString).pathExtension.isEmpty ? "srt" : (name as NSString).pathExtension
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("blusion-sub-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: file)
            return file
        } catch {
            return nil
        }
    }

    /// True when mpv took the value.
    @discardableResult
    private func set(_ name: String, _ value: String) -> Bool {
        guard let handle else { return false }
        return mpv_set_property_string(handle, name, value) >= 0
    }

    private func command(_ arguments: [String]) {
        guard let handle else { return }
        let cStrings: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = cStrings.map { $0.map { UnsafePointer($0) } }
        pointers.append(nil)
        mpv_command(handle, &pointers)
    }
}
#endif
