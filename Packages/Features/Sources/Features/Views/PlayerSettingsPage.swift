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
            Haptics.selection()
            Task { await model.updatePlayer { $0[keyPath: keyPath] = value } }
        })
    }

    var body: some View {
        List {
            Section {
                Picker("Language", selection: Binding(get: { model.settings.subtitleLanguage }, set: { value in
                    Haptics.selection()
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
            } footer: {
                Text("Forced only shows the subtitles that translate signs and foreign-language lines. SDH subtitles also describe sounds.")
            }

            Section("Subtitle style") {
                LabeledContent("Size") {
                    Slider(value: binding(\.subtitleStyle.scale), in: SubtitleStyle.scaleRange, step: 0.1)
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
                    Slider(value: binding(\.subtitleStyle.bottomMargin), in: SubtitleStyle.positionRange, step: 1)
                        .frame(maxWidth: 220)
                        .accessibilityValue("\(Int(player.subtitleStyle.bottomMargin)) percent from the bottom")
                }
                Toggle("Use this style for styled (ASS) subtitles", isOn: binding(\.subtitleStyle.overridesFileStyles))
                Stepper("HDR brightness: \(player.subtitleStyle.hdrPeakNits) nits", value: binding(\.subtitleStyle.hdrPeakNits),
                        in: SubtitleStyle.hdrPeakRange, step: 20)
                    .accessibilityIdentifier("settings.player.subtitleHDR")
            }

            Section {
                Picker("Language", selection: binding(\.audioLanguage)) {
                    ForEach(SettingsViewModel.audioLanguageOptions) { Text($0.label).tag($0.value) }
                }
                .accessibilityIdentifier("settings.player.audioLanguage")
            } header: {
                Text("Audio")
            }

            Section {
                Picker("Picture", selection: binding(\.videoLayout.fit)) {
                    ForEach([VideoFit.fit, .fill], id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Dolby Vision", isOn: binding(\.processing.dolbyVision))
                    .accessibilityIdentifier("settings.player.dolbyVision")
                Picker("HDR", selection: binding(\.processing.hdrOutput)) {
                    ForEach(HDROutputMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Tone mapping", selection: binding(\.processing.toneMapping)) {
                    ForEach(ToneMappingCurve.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Deinterlacing", selection: binding(\.processing.deinterlace)) {
                    ForEach(DeinterlaceMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Upscaling", selection: binding(\.processing.upscaling)) {
                    ForEach(UpscalingMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("settings.player.upscaling")
                Toggle("Ambient mode", isOn: binding(\.ambientMode))
            } header: {
                Text("Picture")
            } footer: {
                Text("""
                    Dolby Vision off plays the HDR10 picture underneath instead, for a release whose Dolby Vision looks wrong; it applies \
                    to MKV files (AetherEngine and the advanced player), and profile 5 always keeps its Dolby Vision. Fit keeps the full \
                    original picture; Fill crops centrally without stretching. Tone mapping, HDR and deinterlacing apply in the advanced player; the \
                    system handles them for MP4 and HLS. AI super \
                    resolution uses this device's machine-learning video scaler for SDR video below the screen's resolution, where the chip \
                    supports it, and a sharp conventional scaler otherwise.
                    """)
            }

            Section("Controls") {
                Toggle("Skip Intro and Credits buttons", isOn: binding(\.showsSkipButtons))
                Toggle("Skip intros automatically", isOn: binding(\.skipsIntrosAutomatically))
                    .disabled(!player.showsSkipButtons)
                #if !targetEnvironment(macCatalyst)
                // Brightness has no app control on the Mac, and its keyboard already sets the volume.
                Toggle("Swipe for brightness and volume", isOn: binding(\.swipeGestures))
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
            } footer: {
                Text("""
                    Search and download subtitles from OpenSubtitles.com in the player. Create a free API consumer at \
                    opensubtitles.com/consumers for the key; signing in raises the daily download limit. Kept in the Keychain.
                    """)
            }
        }
        .settingsPage("Player")
    }
}
#endif
