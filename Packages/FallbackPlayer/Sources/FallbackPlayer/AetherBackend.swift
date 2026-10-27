#if canImport(AetherPlayer) && canImport(UIKit)
import AetherPlayer
import AVFoundation
import Foundation
import PlayerKit
import StremioKit

/// `FallbackBackend` on AetherEngine (LGPL-3.0 with an App Store exception), through the AetherPlayer framework. AetherEngine demuxes with
/// FFmpeg and hands what AVPlayer can play to AVPlayer (Dolby Vision, E-AC-3 Atmos passed to the system), decodes the rest in VideoToolbox,
/// composes Dolby Vision profile 7 FEL on the GPU, and renders TrueHD Atmos and DTS:X objects to spatial audio.
///
/// AetherPlayer is a separate dynamic framework so that its FFmpeg calls bind to its own FFmpeg, not to the static one MPVKit links into
/// the app. This file only translates between AetherPlayer's plain types and PlayerKit's.
@MainActor
public final class AetherBackend: FallbackBackend {
    /// Whether this build carries the optional parts, for the settings screen.
    public static var composesFEL: Bool { AetherSession.composesFEL }
    public static var rendersObjectAudio: Bool { AetherSession.rendersObjectAudio }

    /// Starts fetching a stream AetherEngine is about to play, so its load starts on the bytes (see `AetherPrewarm`).
    public static func prewarm(url: URL, headers: [String: String]) {
        AetherPrewarm.start(url: url, headers: headers)
    }

    private let session: AetherSession
    private var options: AetherOptions
    private let events: AsyncStream<FallbackEvent>
    private let continuation: AsyncStream<FallbackEvent>.Continuation
    private var forwarding: Task<Void, Never>?
    private var processing = VideoProcessing()

    /// nil when AetherEngine cannot start; the caller then uses another engine.
    public init?(composesFEL: Bool, rendersObjectAudio: Bool, preferredAudioLanguages: [String]) {
        guard let session = try? AetherSession() else { return nil }
        self.session = session
        options = AetherOptions(composesFEL: composesFEL, rendersObjectAudio: rendersObjectAudio, preferredAudioLanguages: preferredAudioLanguages)
        (events, continuation) = AsyncStream<FallbackEvent>.makeStream()
        let source = session.events
        let continuation = continuation
        forwarding = Task { @MainActor in
            for await event in source { continuation.yield(Self.translate(event)) }
            continuation.finish()
        }
    }

    public var videoSurface: AnyObject { session.view }

    /// Not `.engineSubtitles`: subtitle files are drawn by the app as on AVPlayer, and "full styling" moves the stream to mpv.
    public var capabilities: EngineCapabilities {
        var capabilities: EngineCapabilities = [.subtitleDelay, .audioDelay, .subtitleStyling, .videoLayout, .aspectOverride]
        if session.isDolbyVisionSource { capabilities.insert(.dolbyVisionSwitch) }
        return capabilities
    }

    public func makeEventStream() -> AsyncStream<FallbackEvent> { events }

    /// AetherEngine repackages a remux into segments as it downloads: the first start waits for a few of them in hand, or a
    /// high-bitrate remux outruns its download and stops and starts.
    public var startCushion: StartCushion? { .standard }
    /// What AetherEngine holds ahead on its loopback route; nil on its software path and for live streams, where the start doesn't wait.
    public var bufferedAhead: TimeInterval? { session.loopbackBufferedAhead }

    public func load(url: URL, headers: [String: String], startPosition: TimeInterval) {
        session.load(url: url, headers: headers, startPosition: startPosition, options: options)
    }

    public func setPaused(_ paused: Bool) { session.setPaused(paused) }
    public func seek(to position: TimeInterval) async { await session.seek(to: position) }
    public func setRate(_ rate: Float) { session.setRate(rate) }
    public func setVolume(_ volume: Float) { session.setVolume(volume) }
    public func setMuted(_ muted: Bool) { session.setMuted(muted) }
    public func selectAudio(id: String?) { session.selectAudio(id: id.flatMap { Int($0.dropFirst()) }) }
    public func selectSubtitle(id: String?) { session.selectSubtitle(id: id.flatMap { Int($0.dropFirst()) }) }
    public func setSubtitleDelay(_ seconds: TimeInterval) { session.setSubtitleDelay(seconds) }
    public func setAudioDelay(_ seconds: TimeInterval) { session.setAudioDelay(seconds) }

    public func apply(layout: VideoLayout) {
        let fit: AetherFit = switch layout.fit {
        case .fit: .fit
        case .fill: .fill
        case .stretch: .stretch
        }
        session.apply(fit: fit, zoom: layout.zoom, aspect: layout.aspect.ratio, crop: layout.crop.ratio, inset: layout.inset)
    }

    public func apply(processing: VideoProcessing) {
        self.processing = processing
        options.dolbyVision = processing.dolbyVision
        session.setDolbyVision(processing.dolbyVision)
    }

    public func apply(subtitleStyle style: SubtitleStyle) {
        let rgb = style.colour.rgb
        session.apply(subtitleStyle: AetherSubtitleStyle(scale: style.scale, red: rgb.red, green: rgb.green, blue: rgb.blue,
                                                         boxed: style.background == .box, bottomMarginPercent: style.bottomMargin,
                                                         overridesFileStyles: style.overridesFileStyles))
    }

    public func statistics() -> PlaybackStatistics {
        let stats = session.statistics()
        var notes = stats.notes
        if processing.upscaling == .quality {
            notes.append("The high-quality scaler runs in mpv only; AetherEngine scales with the system's scaler. AI super resolution runs here.")
        }
        return PlaybackStatistics(engine: stats.engine, decoder: stats.decoder, videoCodec: stats.videoCodec, width: stats.width, height: stats.height,
                                  frameRate: stats.frameRate, videoBitrate: stats.videoBitrate, audioBitrate: stats.audioBitrate,
                                  bufferedAhead: stats.bufferedAhead, sourceColour: stats.sourceColour, dolbyVision: stats.dolbyVision,
                                  outputColour: stats.outputColour, audioCodec: stats.audioCodec, audioChannels: stats.audioChannels,
                                  audioOutput: stats.audioOutput, notes: notes)
    }

    public func shutdown() {
        forwarding?.cancel()
        forwarding = nil
        session.shutdown()
        continuation.finish()
    }

    // MARK: Translation

    static func translate(_ event: AetherEvent) -> FallbackEvent {
        switch event {
        case .loaded(let duration, let audio, let subtitles, let selectedAudio, let selectedSubtitle):
            return .loaded(duration: duration, audio: audio.map(audioTrack), subtitles: subtitles.map(subtitleTrack),
                           selectedAudio: selectedAudio.map { "a\($0)" }, selectedSubtitle: selectedSubtitle.map { "s\($0)" })
        case .duration(let duration): return .duration(duration)
        case .videoFrameReady: return .videoFrameReady
        case .position(let position): return .position(position)
        case .buffered(let until): return .buffered(until)
        case .paused(let paused): return .paused(paused)
        case .buffering(let buffering): return .buffering(buffering)
        case .tracks(let audio, let subtitles, let selectedAudio, let selectedSubtitle):
            return .tracks(audio: audio.map(audioTrack), subtitles: subtitles.map(subtitleTrack),
                           selectedAudio: selectedAudio.map { "a\($0)" }, selectedSubtitle: selectedSubtitle.map { "s\($0)" })
        case .chapters(let chapters):
            return .chapters(chapters.enumerated().map { Chapter(index: $0.offset, title: $0.element.title, start: $0.element.start) })
        case .ended: return .ended
        case .failed(let failure): return .failed(Self.failure(failure))
        }
    }

    static func failure(_ failure: AetherFailure) -> PlaybackFailure {
        let kind: PlaybackFailure.Kind = switch failure.kind {
        case .network: .network
        case .format: .format
        case .unauthorized: .unauthorized
        case .notFound: .notFound
        case .other: .other
        }
        return PlaybackFailure(kind, failure.message)
    }

    static func audioTrack(_ track: AetherTrack) -> MediaTrack {
        let details = [audioLabel(track), track.isCommentary ? "Commentary" : nil]
        return MediaTrack(id: "a\(track.id)", title: title(track, details: details), language: track.language, isDefault: track.isDefault,
                          isHearingImpaired: track.isHearingImpaired, codec: track.codec, channelCount: track.channels > 0 ? track.channels : nil,
                          isExternal: track.isExternal)
    }

    static func subtitleTrack(_ track: AetherTrack) -> MediaTrack {
        let named = track.name.isEmpty ? nil : track.name
        let details = [track.isForced && named?.localizedCaseInsensitiveContains("forced") != true ? "Forced" : nil,
                       track.isHearingImpaired && named?.range(of: #"\b(sdh|cc)\b"#, options: [.regularExpression, .caseInsensitive]) == nil ? "SDH" : nil,
                       subtitleLabel(track.codec)]
        return MediaTrack(id: "s\(track.id)", title: title(track, details: details), language: track.language, isDefault: track.isDefault,
                          isForced: track.isForced, isHearingImpaired: track.isHearingImpaired, codec: track.codec, isExternal: track.isExternal)
    }

    /// "English · TrueHD Atmos 7.1": the file's own title when it has one, else the language, then what tells tracks apart.
    private static func title(_ track: AetherTrack, details: [String?]) -> String {
        let base = !track.name.isEmpty ? track.name : track.language.map { LanguageCodes.displayName($0) } ?? "Track \(track.id)"
        let extra = details.compactMap { $0 }.filter { !base.localizedCaseInsensitiveContains($0) }
        return ([base] + extra).joined(separator: " · ")
    }

    static func audioLabel(_ track: AetherTrack) -> String? {
        var name: String? = switch track.codec {
        case "ac3": "Dolby Digital"
        case "eac3": "Dolby Digital Plus"
        case "truehd", "mlp": "TrueHD"
        case "dts": "DTS"
        case "aac": "AAC"
        case "flac": "FLAC"
        case "opus": "Opus"
        case "mp3": "MP3"
        case let codec where codec.hasPrefix("pcm"): "PCM"
        case "": nil
        default: track.codec.uppercased()
        }
        if track.isAtmos { name = (name ?? "") + " Atmos" }
        if track.isDTSX { name = (name ?? "") + ":X" }
        guard let name else { return nil }
        guard track.channels > 0 else { return name }
        let layout = switch track.channels {
        case 1: "mono"
        case 2: "stereo"
        case 6: "5.1"
        case 7: "6.1"
        case 8: "7.1"
        default: "\(track.channels) ch"
        }
        return "\(name) \(layout)"
    }

    static func subtitleLabel(_ codec: String) -> String? {
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

/// AetherEngine plays most pictures through AVPlayer: Blusion reads small copies of its frames for ambient mode and a film's own bars.
extension AetherBackend: AVPlayerFrameSource {
    public var framePlayer: AVPlayer? { session.currentPlayer }
}

/// AI super resolution draws its scaled frames over AetherEngine's picture, under the subtitles.
extension AetherBackend: PictureOverlayHosting {
    public func hostPictureOverlay(_ layer: CALayer?) { session.hostPictureOverlay(layer) }
    public var pictureGravity: AVLayerVideoGravity { session.pictureGravity }
    public var pictureIsHDR: Bool { session.isHDRSource }
}
#endif
