#if canImport(UIKit)
import PlayerKit
import StremioKit
import SwiftUI

/// The player's options, one tab per kind, opened from the bar under the timeline.
enum PlayerPanelTab: String, CaseIterable, Identifiable {
    case subtitles, audio, picture, speed, chapters

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subtitles: "Subtitles"
        case .audio: "Audio"
        case .picture: "Picture"
        case .speed: "Speed"
        case .chapters: "Chapters"
        }
    }

    var symbol: String {
        switch self {
        case .subtitles: "captions.bubble"
        case .audio: "waveform"
        case .picture: "sparkles.tv"
        case .speed: "gauge.with.dots.needle.67percent"
        case .chapters: "list.bullet.rectangle"
        }
    }
}

/// A glass panel over the picture: at the side when the screen is wide, at the bottom when it is tall. A tap outside closes it.
struct PlayerOptionsPanel: View {
    let model: PlayerViewModel
    @Binding var tab: PlayerPanelTab?
    var actions = PlayerControlActions()

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > proxy.size.height
            ZStack(alignment: wide ? .trailing : .bottom) {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture { close() }
                    .accessibilityHidden(true)
                panel
                    .frame(width: wide ? min(400, proxy.size.width * 0.5) : nil)
                    .frame(maxHeight: wide ? .infinity : proxy.size.height * 0.66)
                    .padding(wide ? 12 : 10)
                    .transition(.move(edge: wide ? .trailing : .bottom).combined(with: .opacity))
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
    }

    private var tabs: [PlayerPanelTab] {
        PlayerPanelTab.allCases.filter { $0 != .chapters || !model.chapters.isEmpty }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                tabBar
                Button(action: close) {
                    Image(systemName: "xmark").font(.subheadline.weight(.bold)).frame(width: 36, height: 36)
                        .background(.white.opacity(0.12), in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                #if !targetEnvironment(macCatalyst)
                .keyboardShortcut(.escape, modifiers: [])   // the Mac's Escape goes through PlayerKeyboard
                #endif
                .accessibilityLabel("Close")
                .accessibilityIdentifier("player.panel.close")
            }
            .padding(10)
            ScrollView {
                content
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .glassEffect(.regular.tint(.black.opacity(0.4)), in: .rect(cornerRadius: 30))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.panel")
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { item in
                let selected = item == tab
                Button {
                    withAnimation(.snappy(duration: 0.22)) { tab = item }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol).font(.system(size: 16, weight: .semibold)).frame(height: 18)
                        Text(item.title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .foregroundStyle(selected ? .black : .white.opacity(0.8))
                    .background { if selected { Capsule().fill(.white) } }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("player.panel.tab.\(item.rawValue)")
            }
        }
        .padding(3)
        .background(.white.opacity(0.1), in: .capsule)
    }

    @ViewBuilder
    private var content: some View {
        switch tab ?? .subtitles {
        case .subtitles: subtitles
        case .audio: audio
        case .picture: picture
        case .speed: speed
        case .chapters: chapters
        }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.25)) { tab = nil }
        model.showControls()
    }

    /// For what opens over the player (a file picker, a search): the panel makes way for it.
    private func closeThen(_ action: () -> Void) {
        close()
        action()
    }

    // MARK: Subtitles

    private var subtitles: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                if let status = model.subtitleStatus {
                    Text(status).font(.footnote).foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 4)
                }
                PanelGroup {
                    PanelOptionRow(title: "Off", selected: model.subtitleChoice == .off) { pickSubtitle(.off) }
                    ForEach(model.embeddedSubtitleTracks) { track in
                        PanelOptionRow(title: track.title, tags: tags(forced: track.isForced, sdh: track.isHearingImpaired, title: track.title),
                                  selected: model.subtitleChoice == .embedded(track.id)) { pickSubtitle(.embedded(track.id)) }
                    }
                }
            }
            if !model.subtitleOptions.isEmpty {
                PanelSection("Online") {
                    PanelGroup {
                        ForEach(model.subtitleOptions) { option in
                            PanelOptionRow(title: option.title, tags: tags(for: option), selected: model.subtitleChoice == .external(option.id)) {
                                pickSubtitle(.external(option.id))
                            }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                PanelButton("Add File", symbol: "doc.badge.plus") { closeThen(actions.openSubtitleFile) }
                PanelButton("OpenSubtitles", symbol: "magnifyingglass") { closeThen(actions.searchOpenSubtitles) }
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
            VStack(alignment: .leading, spacing: 16) {
                PanelChips(title: "Size", options: [0.75, 1.0, 1.25, 1.5, 2.0], selection: style.scale, label: { "\(Int($0 * 100))%" }) { value in
                    restyle { $0.scale = value }
                }
                VStack(alignment: .leading, spacing: 8) {
                    PanelRowTitle("Colour")
                    HStack(spacing: 12) {
                        ForEach(SubtitleColour.allCases, id: \.self) { colour in
                            let rgb = colour.rgb
                            let selected = style.colour == colour
                            Button { restyle { $0.colour = colour } } label: {
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

    private func tags(forced: Bool, sdh: Bool, title: String) -> [String] {
        var tags: [String] = []
        if forced, !title.localizedCaseInsensitiveContains("forced") { tags.append("Forced") }
        if sdh, !title.localizedCaseInsensitiveContains("SDH") { tags.append("SDH") }
        return tags
    }

    private func tags(for option: SubtitleOption) -> [String] {
        var tags = tags(forced: option.isForced, sdh: option.isHearingImpaired, title: option.title)
        if option.format == .ass { tags.append("Styled") }
        if option.format == .pgs || option.format == .vobsub { tags.append("Image") }
        return tags
    }

    // MARK: Audio

    private var audio: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !model.audioTracks.isEmpty {
                PanelGroup {
                    ForEach(model.audioTracks) { track in
                        PanelOptionRow(title: track.title, tags: tags(forced: track.isForced, sdh: track.isHearingImpaired, title: track.title),
                                  selected: model.selectedAudioTrackID == track.id) {
                            model.selectAudioTrack(id: track.id)
                            close()
                        }
                    }
                }
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
        let layout = model.videoLayout
        let processing = model.processing
        return VStack(alignment: .leading, spacing: 22) {
            PanelSection("Frame") {
                VStack(alignment: .leading, spacing: 16) {
                    PanelChips(title: "Fit", options: VideoFit.allCases, selection: layout.fit, label: \.label) { model.setVideoFit($0) }
                    PanelChips(title: "Zoom", options: [1.0, 1.15, 1.33, 1.5, 2.0], selection: layout.zoom,
                            label: { $0 == 1 ? "Off" : "\($0.formatted())×" }) { model.setZoom($0) }
                    if model.capabilities.contains(.aspectOverride) {
                        PanelChips(title: "Aspect Ratio", options: AspectOverride.allCases, selection: layout.aspect, label: \.label) { model.setAspect($0) }
                        PanelChips(title: "Crop", options: VideoCrop.allCases, selection: layout.crop,
                                label: { $0 == .off ? "Off" : $0.rawValue }) { model.setCrop($0) }
                    }
                }
            }
            PanelSection("Colour") {
                VStack(alignment: .leading, spacing: 16) {
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
            PanelSection("Quality") {
                VStack(alignment: .leading, spacing: 16) {
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
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                let selected = model.state.rate == rate
                Button { model.setRate(rate) } label: {
                    Text(rate == 1 ? "1×" : "\(rate.formatted())×")
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .foregroundStyle(selected ? .black : .white)
                        .background(selected ? .white : .white.opacity(0.1), in: .rect(cornerRadius: 18))
                        .contentShape(.rect(cornerRadius: 18))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(rate == 1 ? "Normal speed" : "\(rate.formatted()) times")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    // MARK: Chapters

    private var chapters: some View {
        let current = model.currentChapter
        return PanelGroup {
            ForEach(model.chapters) { chapter in
                PanelOptionRow(title: chapter.title, detail: PlayerTime.format(chapter.start), selected: chapter == current) {
                    Task { await model.seek(toChapter: chapter) }
                    close()
                }
            }
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.bold)).padding(.horizontal, 4).accessibilityAddTraits(.isHeader)
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
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().overlay(.white.opacity(0.08)).padding(.leading, 16) }
                    row
                }
            }
        }
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 18))
    }
}

/// A choice in a list: its name, small tags beside it, a check when it is the one in use.
private struct PanelOptionRow: View {
    let title: String
    var detail: String?
    var tags: [String] = []
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title).font(.body.weight(selected ? .semibold : .regular)).lineLimit(2).multilineTextAlignment(.leading)
                ForEach(tags, id: \.self) { tag in
                    Text(tag).font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.15), in: .capsule)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: 8)
                if let detail {
                    Text(detail).font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                }
                Image(systemName: "checkmark").font(.subheadline.weight(.bold)).opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(([title] + tags).joined(separator: " · "))
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                        Button { choose(option) } label: {
                            Text(label(option)).font(.subheadline.weight(.semibold)).lineLimit(1)
                                .padding(.horizontal, 14).frame(minHeight: 36)
                                .foregroundStyle(selected ? .black : .white)
                                .background(selected ? .white : .white.opacity(0.1), in: .capsule)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(title) \(label(option))")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
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
                Button(action: reset) {
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
        Button { change(delta) } label: {
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
        Toggle(title, isOn: Binding(get: { isOn }, set: set))
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
        Button(action: action) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(.white.opacity(0.1), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}
#endif
