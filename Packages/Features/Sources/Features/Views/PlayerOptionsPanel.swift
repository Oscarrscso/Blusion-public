#if canImport(UIKit)
import PlayerKit
import StremioKit
import SwiftUI
import UIKit

/// The player's options, one menu per kind, chosen on the bar under the timeline (`PlayerMenuBar`).
enum PlayerPanelTab: String, CaseIterable, Identifiable {
    case subtitles, audio, picture, speed, chapters, info

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subtitles: "Subtitles"
        case .audio: "Audio"
        case .picture: "Video"
        case .speed: "Speed"
        case .chapters: "Chapters"
        case .info: "Info"
        }
    }

    var symbol: String {
        switch self {
        case .subtitles: "captions.bubble"
        case .audio: "waveform"
        case .picture: "sparkles.tv"
        case .speed: "gauge.with.dots.needle.67percent"
        case .chapters: "list.bullet.rectangle"
        case .info: "info.circle"
        }
    }
}

/// The open menu: a glass card with its title and close button over the menu's own scrolling content. It sits on the bar whose
/// segments choose it (`PlayerControls`); a tap outside the card and the bar closes it.
struct PlayerOptionsPanel: View {
    let model: PlayerViewModel
    let infoModel: PlayerInfoModel
    @Binding var tab: PlayerPanelTab?
    var actions = PlayerControlActions()
    /// AI super resolution, for Info: what it is doing or why not, and the frames it scales. Only Info reads it, so its frame count
    /// redraws nothing else.
    var upscaling: SuperResolutionRenderer?
    @State private var scrollPosition = ScrollPosition()
    /// Video's submenu that is open in place of its page: Zoom Mode or Aspect Ratio.
    @State private var videoMenu: VideoMenu?
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape

    private var reviewHeightLimit: CGFloat {
        #if targetEnvironment(macCatalyst)
        540
        #else
        isPhoneLandscape ? 540 : 300
        #endif
    }

    private enum VideoMenu {
        case zoomMode, aspectRatio

        var title: String { self == .zoomMode ? "Zoom Mode" : "Aspect Ratio" }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text((tab ?? .subtitles).title)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Button { Haptics.tap(); close() } label: {
                    Image(systemName: "xmark").frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                #if !targetEnvironment(macCatalyst)
                .keyboardShortcut(.escape, modifiers: [])
                #endif
                .accessibilityLabel("Close")
                .accessibilityIdentifier("player.panel.close")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            Divider()
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        content(reviewHeight: max(60, min(reviewHeightLimit, viewport.size.height - 62)))
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                    }
                    .scrollPosition($scrollPosition)
                    .scrollIndicators(.visible)
                    .scrollBounceBehavior(.basedOnSize)
                    .onChange(of: tab) { _, _ in
                        videoMenu = nil
                        scrollPosition.scrollTo(edge: .top)
                    }
                    .onChange(of: videoMenu) { _, _ in scrollPosition.scrollTo(edge: .top) }
                    .task(id: infoModel.openedReviews) {
                        guard tab == .info else { return }
                        // Wait for the expanded panel to be laid out before scrolling to it.
                        try? await Task.sleep(for: .milliseconds(50))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(infoModel.openedReviews == nil ? PlayerInfoMedia.ratingsScrollID : DetailReviewsPanel.scrollID,
                                           anchor: .top)
                        }
                    }
                    // Keep the other menus' rows still; Info's synopsis and reviews animate in place.
                    .transaction { if tab != .info { $0.animation = nil } }
                }
            }
        }
        .clipShape(.rect(cornerRadius: 24))
        .glassEffect(.regular.tint(.black.opacity(0.32)), in: .rect(cornerRadius: 24))
        .foregroundStyle(.white)
        .tint(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.panel")
    }

    @ViewBuilder
    private func content(reviewHeight: CGFloat) -> some View {
        switch tab ?? .subtitles {
        case .subtitles: subtitles
        case .audio: audio
        case .picture:
            if let videoMenu { videoSubmenu(videoMenu) } else { picture }
        case .speed: speed
        case .chapters: chapters
        case .info:
            VStack(alignment: .leading, spacing: 18) {
                PlayerInfoMedia(infoModel: infoModel, reviewHeight: reviewHeight)
                info
            }
            .accessibilityIdentifier("player.panel.info")
        }
    }

    private func close() {
        tab = nil
        model.showControls()
    }

    /// For what opens over the player (a file picker, a search): the panel makes way for it.
    private func closeThen(_ action: () -> Void) {
        close()
        action()
    }

    // MARK: Subtitles

    private var subtitles: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                if let status = model.subtitleStatus {
                    Text(status).font(.footnote).foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 4)
                }
                PanelGroup {
                    PanelOptionRow(title: "Off", symbol: "captions.bubble", selected: model.subtitleChoice == .off) { pickSubtitle(.off) }
                    ForEach(model.embeddedSubtitleRows) { row in
                        PanelOptionRow(title: row.title, subtitle: row.subtitle, tags: row.tags,
                                       selected: model.subtitleChoice == .embedded(row.id)) { pickSubtitle(.embedded(row.id)) }
                            .accessibilityIdentifier("player.subtitle.embedded.\(row.id)")
                    }
                }
            }
            if !model.externalSubtitleRows.isEmpty {
                PanelSection(model.plan.isOffline ? "Downloaded" : "Online") {
                    PanelGroup {
                        ForEach(Array(model.externalSubtitleRows.enumerated()), id: \.element.id) { index, row in
                            PanelOptionRow(title: row.title, subtitle: row.subtitle, tags: row.tags,
                                           selected: model.subtitleChoice == .external(row.id)) { pickSubtitle(.external(row.id)) }
                                .accessibilityIdentifier("player.subtitle.external.\(index)")
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                PanelButton("Add File", symbol: "doc.badge.plus") { closeThen(actions.openSubtitleFile) }
                if !model.plan.isOffline {
                    PanelButton("OpenSubtitles", symbol: "magnifyingglass") { closeThen(actions.searchOpenSubtitles) }
                }
            }
            if model.hasSimplifiedStyling {
                PanelButton("Show Full Styling", symbol: "textformat") { Task { await model.openInAdvancedPlayer() } }
            }
            if model.canShiftSubtitles {
                PanelStepper(title: "Timing", value: model.subtitleOffset, step: 0.1, digits: 1,
                           change: { model.adjustSubtitleOffset(by: $0) }, reset: { model.resetSubtitleOffset() })
                    .accessibilityIdentifier("player.panel.subtitleTiming")
            }
            subtitleStyle
        }
    }

    private var subtitleStyle: some View {
        let style = model.subtitleStyle
        return PanelSection("Style") {
            VStack(alignment: .leading, spacing: 14) {
                PanelChips(title: "Size", options: [0.75, 1.0, 1.25, 1.5, 2.0], selection: style.scale, label: { "\(Int($0 * 100))%" }) { value in
                    restyle { $0.scale = value }
                }
                VStack(alignment: .leading, spacing: 8) {
                    PanelRowTitle("Colour")
                    HStack(spacing: 12) {
                        ForEach(SubtitleColour.allCases, id: \.self) { colour in
                            let rgb = colour.rgb
                            let selected = style.colour == colour
                            Button {
                                if !selected { Haptics.selection() }
                                restyle { $0.colour = colour }
                            } label: {
                                Circle().fill(Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
                                    .frame(width: 30, height: 30)
                                    .padding(4)
                                    .overlay { Circle().strokeBorder(.white, lineWidth: selected ? 2 : 0) }
                                    .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(colour.label)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }
                PanelChips(title: "Background", options: SubtitleBackground.allCases, selection: style.background, label: \.label) { value in
                    restyle { $0.background = value }
                }
                PanelChips(title: "Position", options: [0.0, 4, 8, 12, 20], selection: style.bottomMargin, label: { "\(Int($0))%" }) { value in
                    restyle { $0.bottomMargin = value }
                }
                if model.capabilities.contains(.toneMapping) {
                    PanelChips(title: "HDR Brightness", options: [100, 150, 203, 300, 500], selection: style.hdrPeakNits, label: { "\($0) nits" }) { value in
                        restyle { $0.hdrPeakNits = value }
                    }
                }
                PanelToggle(title: "Override File Styles", isOn: style.overridesFileStyles) { value in restyle { $0.overridesFileStyles = value } }
            }
        }
    }

    private func pickSubtitle(_ choice: PlayerViewModel.SubtitleChoice) {
        Task { await model.selectSubtitle(choice) }
        close()
    }

    private func restyle(_ change: (inout SubtitleStyle) -> Void) {
        var style = model.subtitleStyle
        change(&style)
        model.setSubtitleStyle(SubtitleStyle(scale: style.scale, colour: style.colour, background: style.background,
                                             bottomMargin: style.bottomMargin, overridesFileStyles: style.overridesFileStyles,
                                             hdrPeakNits: style.hdrPeakNits))
    }

    // MARK: Audio

    private var audio: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.audioTrackRows.isEmpty {
                PanelGroup {
                    ForEach(model.audioTrackRows) { row in
                        PanelOptionRow(title: row.title, subtitle: row.subtitle, tags: row.tags,
                                       selected: model.audioTrackSelectionID == row.id) {
                            model.selectAudioTrack(id: row.id)
                            close()
                        }
                        .accessibilityIdentifier("player.audio.\(row.id)")
                    }
                }
            } else {
                Text("No alternate audio tracks").font(.subheadline).foregroundStyle(.secondary)
            }
            if model.capabilities.contains(.externalAudio) {
                PanelButton("Add File", symbol: "doc.badge.plus") { closeThen(actions.openAudioFile) }
            }
            if model.capabilities.contains(.audioDelay) {
                PanelStepper(title: "Sync", value: model.audioDelay, step: 0.05, digits: 2,
                           change: { model.adjustAudioDelay(by: $0) }, reset: { model.resetAudioDelay() })
                    .accessibilityIdentifier("player.panel.audioSync")
            }
        }
    }

    // MARK: Picture

    private var picture: some View {
        let processing = model.processing
        return VStack(alignment: .leading, spacing: 18) {
            PanelSection("Frame") {
                PanelGroup {
                    PanelMenuRow(title: VideoMenu.zoomMode.title, value: model.zoomMode.label) { videoMenu = .zoomMode }
                        .accessibilityIdentifier("player.panel.zoomMode")
                    PanelMenuRow(title: VideoMenu.aspectRatio.title, value: model.aspectRatio.label) { videoMenu = .aspectRatio }
                        .accessibilityIdentifier("player.panel.aspectRatio")
                }
            }
            if model.capabilities.contains(.dolbyVisionSwitch) || model.capabilities.contains(.toneMapping) {
                PanelSection("Colour") {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.capabilities.contains(.dolbyVisionSwitch) {
                            PanelToggle(title: "Dolby Vision", isOn: processing.dolbyVision) { model.setDolbyVision($0) }
                                .accessibilityIdentifier("player.panel.dolbyVision")
                        }
                        if model.capabilities.contains(.toneMapping) {
                            PanelChips(title: "Output", options: HDROutputMode.allCases, selection: processing.hdrOutput,
                                    label: { $0 == .auto ? "HDR" : "SDR" }) { value in changeProcessing { $0.hdrOutput = value } }
                            PanelChips(title: "Tone Mapping", options: ToneMappingCurve.allCases, selection: processing.toneMapping,
                                    label: { $0 == .hable ? "Hable" : $0.label }) { value in changeProcessing { $0.toneMapping = value } }
                        }
                    }
                }
            }
            PanelSection("Quality") {
                VStack(alignment: .leading, spacing: 14) {
                    PanelChips(title: "Upscaling", options: UpscalingMode.allCases, selection: processing.upscaling,
                            label: upscalingLabel) { value in changeProcessing { $0.upscaling = value } }
                    if model.capabilities.contains(.deinterlace) {
                        PanelChips(title: "Deinterlacing", options: DeinterlaceMode.allCases, selection: processing.deinterlace, label: \.label) { value in
                            changeProcessing { $0.deinterlace = value }
                        }
                    }
                    PanelToggle(title: "Ambient Mode", isOn: model.preferences.ambientMode) { _ in actions.toggleAmbient() }
                }
            }
            if model.canOpenInAdvancedPlayer {
                PanelButton("Play in Advanced Player", symbol: "arrow.triangle.swap") { Task { await model.openInAdvancedPlayer() } }
            }
        }
    }

    /// Zoom Mode or Aspect Ratio, opened from Video › Frame: a Back row to Video, then every choice, the one in use checked. A choice
    /// applies at once and the list stays, so its effect shows behind the panel.
    private func videoSubmenu(_ menu: VideoMenu) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { Haptics.tap(); videoMenu = nil } label: {
                Label(PlayerPanelTab.picture.title, systemImage: "chevron.backward")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
                    .frame(minHeight: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("player.panel.videoMenu.back")
            PanelSection(menu.title) {
                PanelGroup {
                    switch menu {
                    case .zoomMode:
                        ForEach(PlayerViewModel.ZoomMode.available) { mode in
                            PanelOptionRow(title: mode.label, selected: model.zoomMode == mode) { model.setZoomMode(mode) }
                                .accessibilityIdentifier("player.panel.zoomMode.\(mode.rawValue)")
                        }
                    case .aspectRatio:
                        ForEach(PlayerViewModel.AspectRatioChoice.allCases) { choice in
                            PanelOptionRow(title: choice.label, selected: model.aspectRatio == choice) { model.setAspectRatio(choice) }
                                .accessibilityIdentifier("player.panel.aspectRatio.\(choice.rawValue)")
                        }
                    }
                }
            }
        }
    }

    private func upscalingLabel(_ mode: UpscalingMode) -> String {
        switch mode {
        case .off: "Standard"
        case .quality: "Sharp"
        case .ai: "AI"
        }
    }

    /// Changes one picture setting and keeps the others, Dolby Vision included.
    private func changeProcessing(_ change: (inout VideoProcessing) -> Void) {
        var processing = model.processing
        change(&processing)
        model.setProcessing(processing)
    }

    // MARK: Speed

    private var speed: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                let selected = model.state.rate == rate
                Button {
                    if !selected { Haptics.selection() }
                    model.setRate(rate)
                } label: {
                    Text(rate == 1 ? "1×" : "\(rate.formatted())×")
                        .font(.body.weight(selected ? .semibold : .medium).monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .foregroundStyle(.white)
                        .background(selected ? .white.opacity(0.18) : .white.opacity(0.07), in: .rect(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(.white.opacity(selected ? 0.30 : 0.07), lineWidth: 0.75)
                        }
                        .contentShape(.rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(rate == 1 ? "Normal speed" : "\(rate.formatted()) times")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    // MARK: Chapters

    @ViewBuilder
    private var chapters: some View {
        if model.chapters.isEmpty {
            Text("This video has no chapter markers.").font(.subheadline).foregroundStyle(.secondary)
        } else {
            let current = model.currentChapter
            PanelGroup {
                ForEach(model.chapters) { chapter in
                    PanelOptionRow(title: chapter.title, detail: PlayerTime.format(chapter.start), selected: chapter == current) {
                        Task { await model.seek(toChapter: chapter) }
                        close()
                    }
                    .accessibilityIdentifier("player.chapter.\(chapter.index)")
                }
            }
        }
    }

    // MARK: Info

    /// Only technical information refreshes every second. Metadata and WebKit are outside this timeline.
    private var info: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let stats = model.statistics()
            VStack(alignment: .leading, spacing: 18) {
                if let stream = model.currentCandidate {
                    PanelSection("Stream") {
                        PanelGroup {
                            PanelInfoRow("Name", stream.title)
                            if !stream.addonName.isEmpty { PanelInfoRow("Addon", stream.addonName) }
                            if let filename = stream.filename, !filename.isEmpty { PanelInfoRow("File", filename) }
                            if let size = stream.videoSize, size > 0 { PanelInfoRow("Size", size.formatted(.byteCount(style: .file))) }
                        }
                    }
                }
                if let stats {
                    infoSection("Video", rows: Self.videoRows(stats) + upscalingRows)
                    infoSection("Audio", rows: audioRows(stats))
                    infoSection("Playback", rows: Self.playbackRows(stats))
                    ForEach(stats.notes, id: \.self) { note in
                        Text(note).font(.footnote).foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Nothing is playing yet.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func infoSection(_ title: String, rows: [(label: String, value: String)]) -> some View {
        if !rows.isEmpty {
            PanelSection(title) {
                PanelGroup {
                    ForEach(rows, id: \.label) { row in PanelInfoRow(row.label, row.value) }
                }
            }
        }
    }

    private static func videoRows(_ stats: PlaybackStatistics) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let width = stats.width, let height = stats.height, width > 0, height > 0 { rows.append(("Resolution", "\(width) × \(height)")) }
        if let codec = stats.videoCodec { rows.append(("Codec", codec)) }
        if let rate = stats.frameRate, rate > 0 { rows.append(("Frame Rate", "\(rate.formatted(.number.precision(.fractionLength(0...3)))) fps")) }
        if let colour = stats.sourceColour { rows.append(("Colour", colour)) }
        if let dolbyVision = stats.dolbyVision { rows.append(("Dolby Vision", dolbyVision)) }
        if let output = stats.outputColour { rows.append(("Output", output)) }
        if let bitrate = stats.videoBitrate, bitrate > 0 { rows.append(("Bitrate", Self.bitrate(bitrate))) }
        if let decoder = stats.decoder { rows.append(("Decoder", decoder)) }
        return rows
    }

    /// Only while AI upscaling is chosen: whether it runs, at what scale, or why it stepped aside, and while it runs, the scaled frames
    /// it shows each second, which proves it is working.
    private var upscalingRows: [(label: String, value: String)] {
        guard model.processing.upscaling == .ai else { return [] }
        var rows = [(label: "AI Upscaling", value: upscaling?.status ?? "Off")]
        if let rate = upscaling?.framesPerSecond { rows.append((label: "Upscaled Frames", value: "\(rate) a second")) }
        return rows
    }

    private func audioRows(_ stats: PlaybackStatistics) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let track = model.audioTrackRows.first(where: { $0.id == model.audioTrackSelectionID }) { rows.append(("Track", track.title)) }
        if let codec = stats.audioCodec { rows.append(("Codec", codec)) }
        if let channels = stats.audioChannels { rows.append(("Channels", channels)) }
        if let output = stats.audioOutput { rows.append(("Output", output)) }
        if let bitrate = stats.audioBitrate, bitrate > 0 { rows.append(("Bitrate", Self.bitrate(bitrate))) }
        let subtitles: String? = switch model.subtitleChoice {
        case .off: nil
        case .embedded(let id): model.embeddedSubtitleRows.first { $0.id == id }?.title
        case .external(let id): model.externalSubtitleRows.first { $0.id == id }?.title
        }
        if let subtitles { rows.append(("Subtitles", subtitles)) }
        return rows
    }

    private static func playbackRows(_ stats: PlaybackStatistics) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = [("Player", stats.engine)]
        if let network = stats.networkBitrate, network > 0 { rows.append(("Network", Self.bitrate(network))) }
        if let ahead = stats.bufferedAhead, ahead.isFinite, ahead >= 0 { rows.append(("Buffered", "\(Int(ahead.rounded())) s ahead")) }
        if let dropped = stats.droppedFrames { rows.append(("Dropped Frames", "\(dropped)")) }
        return rows
    }

    private static func bitrate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000 ? String(format: "%.1f Mb/s", bitsPerSecond / 1_000_000) : String(format: "%.0f kb/s", bitsPerSecond / 1_000)
    }
}

/// Reuses the detail page's media controls without putting metadata or WebKit on the statistics timer.
private struct PlayerInfoMedia: View {
    @Bindable var infoModel: PlayerInfoModel
    let reviewHeight: CGFloat
    static let ratingsScrollID = "player.info.ratings"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(infoModel.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("player.info.title")
            DetailSynopsis(description: infoModel.synopsis, isExpanded: $infoModel.isSynopsisExpanded,
                           isTruncated: $infoModel.isSynopsisTruncated, isLoading: infoModel.isLoading)
                .accessibilityIdentifier("player.info.synopsis")
            Group {
                if infoModel.isLoading || (infoModel.isLoadingEpisode && infoModel.episodeItem == nil) {
                    Spinner().frame(height: 28).accessibilityLabel("Loading ratings")
                } else if infoModel.isEpisode {
                    if let item = infoModel.episodeItem, let url = ReviewSite.imdb.reviewsURL(for: item) {
                        RatingButton(site: .imdb, score: infoModel.episodeRatings.shortText(for: .imdb),
                                     isSearch: false, title: item.name, isOpen: infoModel.openedReviews?.site == .imdb,
                                     isLoading: infoModel.reviewsLoading, showsLinkIcon: true) {
                            infoModel.toggleReviews(.imdb, url: url, isSearch: false)
                        }
                        .frame(width: 120)
                    }
                } else {
                    RatingButtonsRow(item: infoModel.item, openSite: infoModel.openedReviews?.site,
                                     isLoading: infoModel.reviewsLoading, onOpen: infoModel.toggleReviews)
                }
            }
            .id(Self.ratingsScrollID)

            if let reviews = infoModel.openedReviews,
               let item = infoModel.isEpisode ? infoModel.episodeItem : infoModel.item {
                DetailReviewsPanel(reviews: reviews, shown: infoModel.shownReviews, item: item,
                                   isLoading: infoModel.reviewsLoading,
                                   onLoaded: { infoModel.reviewsDidLoad(reviews) }, onClose: infoModel.closeReviews,
                                   viewportHeight: reviewHeight)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: infoModel.openedReviews)
        .task(id: infoModel.openedReviews) {
            guard let reviews = infoModel.openedReviews, infoModel.reviewsLoading else { return }
            // Match the detail page's timeout so a stalled webpage cannot leave its rating spinning forever.
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, infoModel.reviewsLoading else { return }
            infoModel.reviewsDidLoad(reviews)
        }
        .onDisappear { infoModel.closeReviews() }
        .accessibilityIdentifier("player.info.media")
    }
}

// MARK: Building blocks

/// A small heading over a group of rows.
private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    private var symbol: String? {
        switch title {
        case "Frame": "rectangle.expand.vertical"
        case "Colour": "paintpalette"
        case "Quality": "sparkles.tv"
        case "Style": "textformat"
        case "Online": "globe"
        case "Stream": "play.rectangle"
        case "Video": "film"
        case "Audio": "waveform"
        case "Playback": "gauge.with.dots.needle.33percent"
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Text(title)
                    .font(.headline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.horizontal, 4)
            content
        }
    }
}

private struct PanelRowTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 4)
    }
}

/// Rows on one rounded card, with hairlines between them.
private struct PanelGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    row
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(.white.opacity(0.065), in: .rect(cornerRadius: 18))
    }
}

/// A fact on one row: its label, then its value, which wraps under itself when it is long (a release name, a file name).
private struct PanelInfoRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 104, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

/// A choice in a list: its name, small tags beside it, a check when it is the one in use.
private struct PanelOptionRow: View {
    let title: String
    var subtitle: String?
    var detail: String?
    var tags: [String] = []
    var symbol: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            if !selected { Haptics.selection() }
            action()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.56))
                        .frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !tags.isEmpty {
                        Text(tags.joined(separator: " · "))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let detail {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize()
                }
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 18)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(([title] + [subtitle, detail].compactMap { $0 } + tags).joined(separator: " · "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A row that opens a submenu: its name, the choice in use, and a chevron.
private struct PanelMenuRow: View {
    let title: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button { Haptics.tap(); action() } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(value)")
    }
}

/// Values side by side as capsules, the one in use filled. Scrolls sideways when they don't fit.
private struct PanelChips<Value: Hashable>: View {
    let title: String
    let options: [Value]
    let selection: Value
    let label: (Value) -> String
    let choose: (Value) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelRowTitle(title)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(options, id: \.self) { option in
                        let selected = option == selection
                        Button {
                            if !selected { Haptics.selection() }
                            choose(option)
                        } label: {
                            Text(label(option)).font(.subheadline.weight(.semibold)).lineLimit(1)
                                .padding(.horizontal, 14).frame(minHeight: 36)
                                .foregroundStyle(.white)
                                .background(.white.opacity(selected ? 0.20 : 0.08), in: .capsule)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(title) \(label(option))")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 2, for: .scrollContent)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A delay set in steps: − and + hold to repeat, the value resets to zero when tapped.
private struct PanelStepper: View {
    let title: String
    let value: TimeInterval
    let step: TimeInterval
    let digits: Int
    let change: (TimeInterval) -> Void
    let reset: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.body.weight(.semibold))
            Spacer()
            HStack(spacing: 0) {
                stepButton("minus", -step, label: "Earlier")
                Button {
                    if value != 0 { Haptics.selection() }
                    reset()
                } label: {
                    Text("\(String(format: "%+.\(digits)f", value)) s").font(.subheadline.weight(.semibold).monospacedDigit())
                        .frame(minWidth: 72, minHeight: 40)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title) \(String(format: "%+.\(digits)f", value)) seconds")
                .accessibilityHint("Resets to zero")
                stepButton("plus", step, label: "Later")
            }
            .background(.white.opacity(0.1), in: .capsule)
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 18))
    }

    private func stepButton(_ symbol: String, _ delta: TimeInterval, label: String) -> some View {
        Button { Haptics.selection(); change(delta) } label: {
            Image(systemName: symbol).font(.subheadline.weight(.bold)).frame(width: 44, height: 40).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
    }
}

private struct PanelToggle: View {
    let title: String
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { value in
            if value != isOn { Haptics.selection() }
            set(value)
        }))
            .font(.body.weight(.semibold))
            .tint(.green)
            .padding(.horizontal, 16).frame(minHeight: 52)
            .background(.white.opacity(0.08), in: .rect(cornerRadius: 18))
    }
}

private struct PanelButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button { Haptics.tap(); action() } label: {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(.white.opacity(0.1), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}
#endif
