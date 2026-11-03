#if canImport(UIKit)
import PlayerKit
import StremioKit
import SwiftUI

/// The built-in player's defaults: subtitles, audio, picture, controls, and the OpenSubtitles account. Changes made in the player land here too.
struct PlayerSettingsPage: View {
    let model: SettingsViewModel

    private var player: PlayerPreferences { model.settings.player }

    private func binding<Value>(_ keyPath: WritableKeyPath<PlayerPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.settings.player[keyPath: keyPath] }, set: { value in
            Haptics.play(.choices)
            Task { await model.updatePlayer { $0[keyPath: keyPath] = value } }
        })
    }

    var body: some View {
        List {
            Section {
                Picker("Language", selection: Binding(get: { model.settings.subtitleLanguage }, set: { value in
                    Haptics.play(.choices)
                    Task { await model.setSubtitleLanguage(value) }
                })) {
                    ForEach(SettingsViewModel.languageOptions) { Text($0.label).tag($0.value) }
                }
                .accessibilityIdentifier("settings.player.subtitleLanguage")
                Picker("Show", selection: binding(\.subtitleMode)) {
                    ForEach(SubtitleMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("settings.player.subtitleMode")
                Toggle("Prefer SDH", isOn: binding(\.prefersSDH))
                    .accessibilityIdentifier("settings.player.sdh")
            } header: {
                Text("Subtitles")
            }

            Section("Subtitle style") {
                LabeledContent("Size") {
                    Slider(value: Binding(get: { player.subtitleStyle.scale }, set: { value in
                        Task { await model.updatePlayer { $0.subtitleStyle.scale = value } }
                    }), in: SubtitleStyle.scaleRange, step: 0.1, onEditingChanged: { editing in
                        if !editing { Haptics.play(.sliders) }
                    })
                        .frame(maxWidth: 220)
                        .accessibilityValue("\(Int(player.subtitleStyle.scale * 100)) percent")
                }
                Picker("Colour", selection: binding(\.subtitleStyle.colour)) {
                    ForEach(SubtitleColour.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Background", selection: binding(\.subtitleStyle.background)) {
                    ForEach(SubtitleBackground.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                LabeledContent("Height") {
                    Slider(value: Binding(get: { player.subtitleStyle.bottomMargin }, set: { value in
                        Task { await model.updatePlayer { $0.subtitleStyle.bottomMargin = value } }
                    }), in: SubtitleStyle.positionRange, step: 1, onEditingChanged: { editing in
                        if !editing { Haptics.play(.sliders) }
                    })
                        .frame(maxWidth: 220)
                        .accessibilityValue("\(Int(player.subtitleStyle.bottomMargin)) percent from the bottom")
                }
                Toggle("Use this style for styled (ASS) subtitles", isOn: binding(\.subtitleStyle.overridesFileStyles))
                Stepper("HDR brightness: \(player.subtitleStyle.hdrPeakNits) nits", value: binding(\.subtitleStyle.hdrPeakNits),
                        in: SubtitleStyle.hdrPeakRange, step: 20)
                    .accessibilityIdentifier("settings.player.subtitleHDR")
            }

            Section {
                // Nothing saved reads as English, the language the player picks then.
                Picker("Language", selection: Binding<String?>(get: { player.audioLanguage ?? PlayerPreferences.defaultAudioLanguage }, set: { value in
                    Haptics.play(.choices)
                    Task { await model.updatePlayer { $0.audioLanguage = value } }
                })) {
                    ForEach(SettingsViewModel.audioLanguageOptions) { Text($0.label).tag($0.value) }
                }
                .accessibilityIdentifier("settings.player.audioLanguage")
            } header: {
                Text("Audio")
            }

            Section {
                Picker("Zoom Mode", selection: Binding(get: { player.zoomMode.onThisDevice }, set: { value in
                    Haptics.play(.choices)
                    Task { await model.updatePlayer { $0.zoomMode = value.onThisDevice } }
                })) {
                    ForEach(VideoZoomMode.available) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("settings.player.zoomMode")
                Toggle("Dolby Vision", isOn: binding(\.processing.dolbyVision))
                    .accessibilityIdentifier("settings.player.dolbyVision")
                Picker("HDR", selection: binding(\.processing.hdrOutput)) {
                    ForEach(HDROutputMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                // Full range on every engine; mpv's in-player slider sets how far it lifts HDR (AVPlayer and AetherEngine have no levels).
                Toggle("Full HDR brightness", isOn: Binding(get: { player.processing.hdrBrightness > 0 }, set: { on in
                    Haptics.play(.choices)
                    Task { await model.updatePlayer { $0.processing.hdrBrightness = on ? 1 : 0 } }
                }))
                .accessibilityIdentifier("settings.player.hdrBrightness")
                Picker("Tone mapping", selection: binding(\.processing.toneMapping)) {
                    ForEach(ToneMappingCurve.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Deinterlacing", selection: binding(\.processing.deinterlace)) {
                    ForEach(DeinterlaceMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Ambient mode", isOn: binding(\.ambientMode))
            } header: {
                Text("Picture")
            }

            upscalingSection

            Section("Controls") {
                Picker("Skip back", selection: binding(\.skipBackSeconds)) {
                    ForEach(PlayerPreferences.skipIntervalOptions, id: \.self) { Text(Self.secondsLabel($0)).tag($0) }
                }
                .accessibilityIdentifier("settings.player.skipBack")
                Picker("Skip forward", selection: binding(\.skipForwardSeconds)) {
                    ForEach(PlayerPreferences.skipIntervalOptions, id: \.self) { Text(Self.secondsLabel($0)).tag($0) }
                }
                .accessibilityIdentifier("settings.player.skipForward")
                Toggle("Double-tap to skip", isOn: binding(\.doubleTapSkips))
                    .accessibilityIdentifier("settings.player.doubleTapSkips")
                Picker("Hide controls", selection: binding(\.controlsHideSeconds)) {
                    ForEach(PlayerPreferences.controlsHideOptions, id: \.self) { seconds in
                        Text(seconds == 0 ? "Never" : "After \(Self.secondsLabel(seconds))").tag(seconds)
                    }
                }
                .accessibilityIdentifier("settings.player.hideControls")
                Picker("Speed", selection: binding(\.playbackSpeed)) {
                    ForEach(PlayerPreferences.playbackSpeedOptions, id: \.self) { Text(Self.speedLabel($0)).tag($0) }
                }
                .accessibilityIdentifier("settings.player.speed")
                Toggle("Skip Intro and Credits buttons", isOn: binding(\.showsSkipButtons))
                Toggle("Skip intros automatically", isOn: binding(\.skipsIntrosAutomatically))
                    .disabled(!player.showsSkipButtons)
                #if !targetEnvironment(macCatalyst)
                // Brightness has no app control on the Mac, and its keyboard already sets the volume.
                Toggle("Swipe for brightness", isOn: binding(\.swipeGestures))
                #endif
            }

            Section {
                SecureField("API key", text: Binding(get: { model.openSubtitlesAPIKeyText }, set: { model.openSubtitlesAPIKeyText = $0 }))
                    .textContentType(.password)
                    .accessibilityIdentifier("settings.opensubtitles.key")
                TextField("Username (optional)", text: Binding(get: { model.openSubtitlesUsernameText }, set: { model.openSubtitlesUsernameText = $0 }))
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password (optional)", text: Binding(get: { model.openSubtitlesPasswordText }, set: { model.openSubtitlesPasswordText = $0 }))
                    .textContentType(.password)
                Button("Save") { Task { await model.commitOpenSubtitles() } }
                    .accessibilityIdentifier("settings.opensubtitles.save")
                if let message = model.lastMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("OpenSubtitles")
            }
        }
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
        .settingsPage("Player")
    }

    /// "10 seconds", "1 minute".
    static func secondsLabel(_ seconds: Int) -> String {
        seconds == 60 ? "1 minute" : "\(seconds) seconds"
    }

    /// "1×", "1.25×", "0.5×".
    static func speedLabel(_ speed: Double) -> String {
        "\(speed.formatted(.number.precision(.fractionLength(0...2))))×"
    }

    /// The upscaling choice, what it does, whether this device can run AI upscaling, and what it did on the last video played with it.
    private var upscalingSection: some View {
        Section {
            Picker("Upscaling", selection: binding(\.processing.upscaling)) {
                ForEach(UpscalingMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("settings.player.upscaling")
            if player.processing.upscaling == .ai {
                LabeledContent(Self.deviceName) {
                    Text(SuperResolutionRenderer.isSupportedOnThisDevice ? "AI scaler available" : "No AI scaler")
                        .foregroundStyle(SuperResolutionRenderer.isSupportedOnThisDevice ? Color.secondary : Color.orange)
                }
                .accessibilityIdentifier("settings.player.upscaling.device")
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Last video")
                        Spacer()
                        if lastReportDate > 0 {
                            Text(Date(timeIntervalSince1970: lastReportDate), format: .relative(presentation: .named))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(lastReport.isEmpty ? "Nothing played with AI upscaling yet." : lastReport)
                        .font(.footnote)
                        .foregroundStyle(lastReport.hasPrefix("Ran") ? Color.green : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.player.upscaling.last")
            }
        } header: {
            Text("Upscaling")
        }
    }

    @AppStorage(UpscalingReport.summaryKey) private var lastReport = ""
    @AppStorage(UpscalingReport.dateKey) private var lastReportDate: Double = 0

    private static var deviceName: String {
        #if targetEnvironment(macCatalyst)
        "This Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"
        #endif
    }
}
#endif
