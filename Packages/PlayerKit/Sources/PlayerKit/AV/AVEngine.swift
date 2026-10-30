#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import Foundation
import StremioKit

/// `PlaybackEngine` backed by AVPlayer: MP4/MOV/M4V and HLS (PLAN §4). The video surface attaches to `player`.
///
/// UNVERIFIED on this build host (no Xcode): compiled and run only by macOS CI and on device. Kept deliberately plain.
@MainActor
public final class AVEngine: PlaybackEngine {
    public let player = AVPlayer()
    public private(set) var state = PlaybackState()

    private let broadcaster = PlaybackStateBroadcaster()
    private var playerItem: AVPlayerItem?
    private var headerLoader: HeaderResourceLoader?
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var tokens: [NSObjectProtocol] = []
    private var itemTokens: [NSObjectProtocol] = []
    private var audioGroup: AVMediaSelectionGroup?
    private var audioOptions: [String: AVMediaSelectionOption] = [:]
    private var subtitleGroup: AVMediaSelectionGroup?
    private var subtitleOptions: [String: AVMediaSelectionOption] = [:]
    private var wantsPlay = false
    private var wasPlayingBeforeInterruption = false
    private var isItemReady = false
    /// Distinguishes "ready, never played" (.ready) from "paused by the user" (.paused).
    private var hasPlayed = false
    private var pendingStart: TimeInterval = 0
    private var generation = 0
    /// What the tracks' format descriptions say, read once per item for the statistics panel.
    private var mediaInfo = MediaInfo()

    struct MediaInfo {
        var videoCodec: String?
        var frameRate: Double?
        var sourceColour: String?
        var dolbyVision: String?
        var dolbyVisionNote: String?
        var audioCodec: String?
        var audioChannels: String?
        var isSpatialAudioFormat = false
    }

    public init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true
        observePlayer()
        observeAudioSession()
    }

    public func makeStateStream() -> AsyncStream<PlaybackState> {
        broadcaster.makeStream(current: state)
    }

    // MARK: PlaybackEngine

    public func load(_ item: PlaybackItem) {
        teardownItem()
        generation += 1
        isItemReady = false
        hasPlayed = false
        pendingStart = item.startPosition
        var fresh = PlaybackState()
        fresh.status = .loading
        publish(fresh)

        let made = AVAssetFactory.make(url: item.url, headers: item.headers)
        headerLoader = made.loader
        let playerItem = AVPlayerItem(asset: made.asset)
        self.playerItem = playerItem
        mediaInfo = MediaInfo()
        observeItem(playerItem)
        player.replaceCurrentItem(with: playerItem)
    }

    public func play() {
        wantsPlay = true
        activateAudioSession()
        if state.status == .ended {
            // Replay from the start.
            update { $0.status = .paused }
            Task {
                await self.seek(to: 0)
                self.player.play()
                self.refreshStatus()
            }
            return
        }
        player.play()
        if player.rate != 0, state.rate != 1 { player.rate = state.rate }
        refreshStatus()
    }

    public func pause() {
        wantsPlay = false
        player.pause()
        refreshStatus()
    }

    public func seek(to position: TimeInterval) async {
        let time = CMTime(seconds: max(0, position), preferredTimescale: 600)
        _ = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        update { $0.position = max(0, position) }
    }

    public func setRate(_ rate: Float) {
        player.defaultRate = rate
        // A rate set while the player waits for data is the one it resumes at, so it is set whenever playback is wanted, not only
        // while it is running. Paused, it stays paused.
        if wantsPlay || player.timeControlStatus == .playing { player.rate = rate }
        update { $0.rate = rate }
    }

    public func setVolume(_ volume: Float) {
        player.volume = volume
    }

    public func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    public func selectAudioTrack(id: String?) {
        guard let id, let option = audioOptions[id], let group = audioGroup else { return }
        playerItem?.select(option, in: group)
        update { $0.selectedAudioTrackID = id }
    }

    public func selectEmbeddedSubtitleTrack(id: String?) {
        guard let group = subtitleGroup else { return }
        if let id, let option = subtitleOptions[id] {
            playerItem?.select(option, in: group)
        } else {
            playerItem?.select(nil, in: group)
        }
        update { $0.selectedEmbeddedSubtitleID = id }
    }

    // MARK: Extras

    /// AVPlayer reports whether the loaded item supports rates above 2×. Keep the temporary gesture capped at 4×.
    public var maximumRate: Float { playerItem?.canPlayFastForward == true ? 4 : 2 }

    /// The aspect override and the crop are applied by the video surface (`VideoGeometry`).
    public var capabilities: EngineCapabilities { [.subtitleStyling, .aspectOverride] }

    /// Embedded text subtitles (WebVTT in HLS, tx3g in MP4) take the style through text style rules. Bitmap subtitles ignore them.
    public func apply(subtitleStyle style: SubtitleStyle) {
        let rgb = style.colour.rgb
        var attributes: [String: Any] = [
            kCMTextMarkupAttribute_RelativeFontSize as String: style.scale * 100,
            kCMTextMarkupAttribute_ForegroundColorARGB as String: [1, rgb.red, rgb.green, rgb.blue],
            kCMTextMarkupAttribute_CharacterEdgeStyle as String: style.background == .box
                ? kCMTextMarkupCharacterEdgeStyle_None as String : kCMTextMarkupCharacterEdgeStyle_DropShadow as String,
        ]
        if style.background == .box { attributes[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] = [0.6, 0, 0, 0] }
        playerItem?.textStyleRules = AVTextStyleRule(textMarkupAttributes: attributes).map { [$0] }
        subtitleStyle = style
    }

    private var subtitleStyle: SubtitleStyle?

    public func statistics() -> PlaybackStatistics {
        var stats = PlaybackStatistics(engine: "AVPlayer", decoder: "Hardware (VideoToolbox, system)")
        if let item = playerItem {
            let size = item.presentationSize
            if size.width > 0 { stats.width = Int(size.width); stats.height = Int(size.height) }
            if let event = item.accessLog()?.events.last {
                if event.indicatedBitrate > 0 { stats.videoBitrate = event.indicatedBitrate }
                if event.observedBitrate > 0 { stats.networkBitrate = event.observedBitrate }
                stats.droppedFrames = max(0, event.numberOfDroppedVideoFrames)
                if event.numberOfStalls > 0 { stats.notes.append("Stalled \(event.numberOfStalls)× while buffering.") }
            }
            stats.bufferedAhead = max(0, state.bufferedUntil - state.position)
        }
        stats.videoCodec = mediaInfo.videoCodec
        stats.frameRate = mediaInfo.frameRate
        stats.sourceColour = mediaInfo.sourceColour
        stats.dolbyVision = mediaInfo.dolbyVision
        if let note = mediaInfo.dolbyVisionNote { stats.notes.append(note) }
        stats.audioCodec = mediaInfo.audioCodec
        stats.audioChannels = mediaInfo.audioChannels
        if mediaInfo.sourceColour?.hasPrefix("SDR") == false {
            stats.outputColour = AVPlayer.eligibleForHDRPlayback ? "HDR (display eligible; shown as HDR by the system)" : "Tone-mapped to SDR by the system"
        } else if mediaInfo.sourceColour != nil {
            stats.outputColour = "SDR"
        }
        #if os(iOS)
        if let output = AVAudioSession.sharedInstance().currentRoute.outputs.first {
            let channels = output.channels?.count ?? 0
            var text = "\(output.portName)\(channels > 0 ? ", \(channels) ch" : "")"
            if output.isSpatialAudioEnabled { text += ", Spatial Audio" }
            stats.audioOutput = text
            if mediaInfo.isSpatialAudioFormat {
                stats.notes.append(output.isSpatialAudioEnabled
                    ? "Dolby Atmos goes to the system's spatial renderer."
                    : "This output has no spatial rendering: Atmos plays as its channel bed.")
            }
        }
        #endif
        return stats
    }

    public func stop() {
        generation += 1
        teardownItem()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.forEach { $0.invalidate() }
        observations = []
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens = []
        deactivateAudioSession()
        update { $0.status = .idle }
        broadcaster.finish()
    }

    // MARK: State

    private func update(_ change: (inout PlaybackState) -> Void) {
        var next = state
        change(&next)
        publish(next)
    }

    private func publish(_ next: PlaybackState) {
        guard next != state else { return }
        state = next
        broadcaster.yield(next)
    }

    /// Maps AVPlayer's time-control status onto ours, but only once the item is ready (before that we are `.loading`).
    private func refreshStatus() {
        guard playerItem != nil, isItemReady else { return }
        if case .failed = state.status { return }
        if state.status == .ended { return }
        switch player.timeControlStatus {
        case .playing:
            hasPlayed = true
            update { $0.status = .playing }
        case .waitingToPlayAtSpecifiedRate:
            update { $0.status = wantsPlay ? .buffering : .ready }
        case .paused:
            if wantsPlay {
                update { $0.status = .buffering }
            } else {
                update { $0.status = hasPlayed ? .paused : .ready }
            }
        @unknown default:
            break
        }
        update { $0.isExternalPlaybackActive = player.isExternalPlaybackActive }
    }

    private func fail(_ error: Error?) {
        update { $0.status = .failed(AVEngine.failure(from: error)) }
    }

    static func failure(from error: Error?) -> PlaybackFailure {
        guard let error = error as NSError? else { return PlaybackFailure(.other, "Playback failed.") }
        let message = Redactor.redact(text: error.localizedDescription)   // error text can contain the media URL
        if error.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: error.code) {
            case .timedOut: return PlaybackFailure(.timeout, message)
            case .appTransportSecurityRequiresSecureConnection:
                return PlaybackFailure(.network, "This stream uses an insecure connection that iOS blocks.")
            default: return PlaybackFailure(.network, message)
            }
        }
        if error.domain == AVFoundationErrorDomain {
            switch AVError.Code(rawValue: error.code) {
            case .fileFormatNotRecognized, .decoderNotFound, .failedToLoadMediaData: return PlaybackFailure(.format, message)
            default: break
            }
        }
        return PlaybackFailure(.other, message)
    }

    // MARK: Observation

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshStatus() }
        })
        observations.append(player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshStatus() }
        })
    }

    private func observeItem(_ item: AVPlayerItem) {
        itemObservations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error
            Task { @MainActor in self?.itemStatusChanged(status, error: error) }
        })
        let center = NotificationCenter.default
        itemTokens.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didPlayToEnd() }
        })
        itemTokens.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            MainActor.assumeIsolated { self?.fail(error) }
        })
        itemTokens.append(center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update { $0.status = .buffering } }
        })
    }

    private func teardownItem() {
        itemObservations.forEach { $0.invalidate() }
        itemObservations = []
        itemTokens.forEach { NotificationCenter.default.removeObserver($0) }
        itemTokens = []
        playerItem = nil
        headerLoader?.invalidate()
        headerLoader = nil
        audioGroup = nil
        audioOptions = [:]
        subtitleGroup = nil
        subtitleOptions = [:]
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, error: Error?) {
        switch status {
        case .readyToPlay:
            guard let item = playerItem, !isItemReady else { return }
            isItemReady = true
            let seconds = item.duration.seconds
            update { $0.duration = (seconds.isFinite && seconds > 0) ? seconds : nil }
            if pendingStart > 0 {
                let start = pendingStart
                pendingStart = 0
                Task { await self.seek(to: start) }
            }
            loadTracks(of: item.asset)
            loadDetails(of: item.asset)
            if let subtitleStyle { apply(subtitleStyle: subtitleStyle) }
            refreshStatus()
        case .failed:
            fail(error)
        default:
            break
        }
    }

    private func tick(_ time: CMTime) {
        guard let item = playerItem, isItemReady else { return }
        let position = time.seconds
        guard position.isFinite else { return }
        let buffered = item.loadedTimeRanges.last.map { $0.timeRangeValue.end.seconds } ?? 0
        update {
            $0.position = max(0, position)
            if buffered.isFinite { $0.bufferedUntil = buffered }
            // AVPlayer can refuse a rate its item cannot play: report the rate it is running at, not only the one asked for.
            if player.timeControlStatus == .playing, player.rate > 0 { $0.rate = player.rate }
        }
    }

    private func didPlayToEnd() {
        update {
            if let duration = $0.duration { $0.position = duration }
            $0.status = .ended
        }
    }

    // MARK: Tracks

    private func loadTracks(of asset: AVAsset) {
        let current = generation
        Task { @MainActor [weak self] in
            let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self, self.generation == current, let item = self.playerItem else { return }
            let selection = item.currentMediaSelection
            self.audioGroup = audio ?? nil
            self.subtitleGroup = legible ?? nil
            let audioTracks = Self.tracks(from: self.audioGroup, prefix: "audio", selection: selection, into: &self.audioOptions)
            let subtitleTracks = Self.tracks(from: self.subtitleGroup, prefix: "subtitle", selection: selection, into: &self.subtitleOptions)
            self.update {
                $0.audioTracks = audioTracks.tracks
                $0.selectedAudioTrackID = audioTracks.selected
                $0.embeddedSubtitleTracks = subtitleTracks.tracks
                $0.selectedEmbeddedSubtitleID = subtitleTracks.selected
            }
        }
    }

    /// Chapters, and the codec, frame rate and colour the tracks declare.
    private func loadDetails(of asset: AVAsset) {
        let current = generation
        Task { @MainActor [weak self] in
            let languages = Locale.preferredLanguages
            let groups = (try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: languages)) ?? []
            var chapters: [Chapter] = []
            for (index, group) in groups.enumerated() {
                let title = try? await AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first?.load(.stringValue)
                let start = group.timeRange.start.seconds
                if start.isFinite { chapters.append(Chapter(index: index, title: title ?? "Chapter \(index + 1)", start: max(0, start))) }
            }
            let info = await Self.mediaInfo(of: asset)
            guard let self, self.generation == current else { return }
            self.mediaInfo = info
            self.update { $0.chapters = chapters }
        }
    }

    private static func mediaInfo(of asset: AVAsset) async -> MediaInfo {
        var info = MediaInfo()
        if let video = try? await asset.loadTracks(withMediaType: .video).first {
            info.frameRate = (try? await video.load(.nominalFrameRate)).map(Double.init).flatMap { $0 > 0 ? $0 : nil }
            if let format = (try? await video.load(.formatDescriptions))?.first {
                let codec = CMFormatDescriptionGetMediaSubType(format)
                info.videoCodec = videoCodecName(codec)
                if codec == kCMVideoCodecType_DolbyVisionHEVC || fourCC(codec) == "dvav" || fourCC(codec) == "dva1" {
                    info.dolbyVision = "Dolby Vision (\(fourCC(codec)))"
                }
                // AVFoundation exposes the Dolby Vision configuration under the sample-description
                // atoms. Inspect its record even for an hvc1 HEVC tag (Profiles 8.1/8.4 can use it).
                if let configuration = dolbyVisionConfiguration(of: format) {
                    info.dolbyVision = configuration.label
                    info.videoCodec = "HEVC (Dolby Vision)"
                    #if targetEnvironment(macCatalyst)
                    info.dolbyVisionNote = configuration.macPlaybackNote
                    #endif
                }
                let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
                info.sourceColour = colourName(transfer: transfer, primaries: primaries)
            }
        }
        if let audio = try? await asset.loadTracks(withMediaType: .audio).first,
           let format = (try? await audio.load(.formatDescriptions))?.first {
            let codec = CMFormatDescriptionGetMediaSubType(format)
            info.audioCodec = audioCodecName(codec)
            info.isSpatialAudioFormat = codec == kAudioFormatEnhancedAC3
            if let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                let channels = Int(description.mChannelsPerFrame)
                info.audioChannels = "\(channels == 6 ? "5.1" : channels == 8 ? "7.1" : "\(channels) ch"), \(description.mSampleRate / 1000) kHz"
            }
        }
        return info
    }

    private static func dolbyVisionConfiguration(of format: CMFormatDescription) -> DolbyVisionConfiguration? {
        guard let atoms = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any] else { return nil }
        var payloads: [String: Data] = [:]
        for key in ["dvcC", "dvvC"] {
            if let bytes = atoms[key] as? Data { payloads[key] = bytes }
        }
        return DolbyVisionConfiguration.parse(atomPayloads: payloads)
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }

    private static func videoCodecName(_ code: FourCharCode) -> String {
        switch fourCC(code) {
        case "avc1", "avc3": "H.264"
        case "hvc1", "hev1": "HEVC"
        case "dvh1", "dvhe": "HEVC (Dolby Vision)"
        case "av01": "AV1"
        case "vp09": "VP9"
        case "apcn", "apch", "apcs", "apco", "ap4h", "ap4x": "ProRes"
        case let other: other
        }
    }

    private static func audioCodecName(_ code: FourCharCode) -> String {
        switch code {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: "AAC"
        case kAudioFormatAC3: "Dolby Digital"
        case kAudioFormatEnhancedAC3: "Dolby Digital Plus"
        case kAudioFormatAppleLossless: "ALAC"
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatOpus: "Opus"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatLinearPCM: "PCM"
        default: fourCC(code)
        }
    }

    /// From the format description's own tags, not the release name.
    private static func colourName(transfer: String?, primaries: String?) -> String? {
        let space = primaries.map { $0 == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) ? "BT.2020"
            : $0 == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String) ? "BT.709" : $0 == (kCMFormatDescriptionColorPrimaries_P3_D65 as String) ? "P3" : $0 }
        let pq = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
        let hlg = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
        if transfer == pq { return "HDR10 (PQ\(space.map { ", \($0)" } ?? ""))" }
        if transfer == hlg { return "HLG\(space.map { " (\($0))" } ?? "")" }
        if transfer == nil { return space.map { "SDR (\($0))" } }
        return "SDR\(space.map { " (\($0))" } ?? "")"
    }

    private static func tracks(from group: AVMediaSelectionGroup?, prefix: String, selection: AVMediaSelection,
                               into table: inout [String: AVMediaSelectionOption]) -> (tracks: [MediaTrack], selected: String?) {
        table = [:]
        guard let group else { return ([], nil) }
        let selectedOption = selection.selectedMediaOption(in: group)
        var tracks: [MediaTrack] = []
        var selectedID: String?
        for (index, option) in group.options.enumerated() {
            let id = "\(prefix)-\(index)"
            table[id] = option
            let forced = option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
            let accessible = option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility)
                || option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
                || option.hasMediaCharacteristic(.describesVideoForAccessibility)
            tracks.append(MediaTrack(id: id, title: option.displayName, language: option.extendedLanguageTag ?? option.locale?.identifier,
                                     isDefault: option == group.defaultOption, isForced: forced, isHearingImpaired: accessible))
            if option == selectedOption { selectedID = id }
        }
        return (tracks, selectedID)
    }

    // MARK: Audio session (iOS)

    private func activateAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)   // ADR-005: playback category, activated when playback starts
        try? session.setActive(true)
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func observeAudioSession() {
        #if os(iOS)
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:))
            MainActor.assumeIsolated { self?.handleInterruption(type: type, options: options) }
        })
        tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated { if reason == .oldDeviceUnavailable { self?.pause() } }   // headphones unplugged
        })
        #endif
    }

    #if os(iOS)
    private func handleInterruption(type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions?) {
        switch type {
        case .began:
            wasPlayingBeforeInterruption = wantsPlay
            update { if $0.status == .playing || $0.status == .buffering { $0.status = .paused } }
        case .ended:
            if wasPlayingBeforeInterruption, options?.contains(.shouldResume) == true { play() }
            wasPlayingBeforeInterruption = false
        default:
            break
        }
    }
    #endif
}

#endif
