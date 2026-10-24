#if canImport(UIKit)
import PlayerKit
import StremioKit
import SwiftUI

/// What the menus open that lives on the player screen (file pickers, sheets, panels).
struct PlayerControlActions {
    var openSubtitleFile: () -> Void = {}
    var openAudioFile: () -> Void = {}
    var searchOpenSubtitles: () -> Void = {}
    var toggleAmbient: () -> Void = {}
}

struct PlayerControls: View {
    let model: PlayerViewModel
    let onClose: () -> Void
    let onNextEpisode: () -> Void
    let pipToggle: () -> Void
    let pipAvailable: Bool
    var openPanel: (PlayerPanelTab) -> Void = { _ in }

    var body: some View {
        // Overlay content must never contribute a minimum size to the player.
        // In landscape the old 150 + 280 pt scrims made the whole video taller.
        GeometryReader { viewport in
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)
                transport
                Spacer(minLength: 12)
                bottomPanel
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            #if targetEnvironment(macCatalyst)
            .frame(maxWidth: 900)
            #endif
            .frame(width: viewport.size.width, height: viewport.size.height)
            .background { scrims(in: viewport.size) }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.controls")
    }

    /// Contrast at the edges, sized within the viewport even in compact landscape.
    private func scrims(in size: CGSize) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.2), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: min(150, size.height * 0.35))
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .frame(height: min(280, size.height * 0.55))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.tap()
                onClose()
            } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .pointerInteraction(cornerRadius: 22)
            }
            #if !targetEnvironment(macCatalyst)
            .keyboardShortcut(.escape, modifiers: [])
            #endif
            .help("Close (Esc)")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("player.close")
            Spacer(minLength: 0)
            if pipAvailable || canAirPlay {
                HStack(spacing: 0) {
                    if pipAvailable {
                        Button(action: pipToggle) {
                            Image(systemName: "pip.enter").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                                .contentShape(.rect)
                                .pointerInteraction(cornerRadius: 22)
                        }
                        .help("Picture in Picture")
                        .accessibilityLabel("Picture in Picture")
                        .accessibilityIdentifier("player.pip")
                    }
                    #if canImport(AVKit)
                    AirPlayButton().frame(width: 44, height: 44)
                        .pointerInteraction(cornerRadius: 22)
                        .help("AirPlay")
                        .accessibilityLabel("AirPlay").accessibilityIdentifier("player.airplay")
                    #endif
                }
                .padding(.horizontal, 2)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .buttonStyle(.plain)
    }

    /// The film or series, not the stream's release name. An episode's title is "Series · Episode".
    private var headline: String {
        let request = model.plan.request
        if let series = request.seriesName, !series.isEmpty { return series }
        guard request.episode != nil else { return request.title }
        return request.title.components(separatedBy: " · ").first ?? request.title
    }

    /// "S2, E5 · The Episode".
    private var episodeLine: String? {
        let request = model.plan.request
        guard let season = request.season, let episode = request.episode else { return nil }
        var line = "S\(season), E\(episode)"
        let prefix = headline + " · "
        if request.title.hasPrefix(prefix), request.title.count > prefix.count { line += " · \(request.title.dropFirst(prefix.count))" }
        return line
    }

    private var canAirPlay: Bool {
        #if canImport(AVKit)
        return true
        #else
        return false
        #endif
    }

    private var transport: some View {
        GlassEffectContainer(spacing: 36) {
            HStack(spacing: 36) {
                Button { Task { await model.skip(by: -10) } } label: {
                    Image(systemName: "gobackward.10").font(.title2.weight(.medium)).frame(width: 58, height: 58)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .pointerInteraction(cornerRadius: 29)
                }
                #if !targetEnvironment(macCatalyst)
                .keyboardShortcut(.leftArrow, modifiers: [])
                #endif
                .help("Back 10 seconds (←)")
                .accessibilityLabel("Back 10 seconds")
                .accessibilityIdentifier("player.skipBack")
                Button { model.togglePlayPause() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .frame(width: 80, height: 80).glassEffect(.regular.interactive(), in: .circle)
                        .pointerInteraction(cornerRadius: 40)
                }
                #if !targetEnvironment(macCatalyst)
                .keyboardShortcut(" ", modifiers: [])
                #endif
                .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("player.playPause")
                Button { Task { await model.skip(by: 10) } } label: {
                    Image(systemName: "goforward.10").font(.title2.weight(.medium)).frame(width: 58, height: 58)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .pointerInteraction(cornerRadius: 29)
                }
                #if !targetEnvironment(macCatalyst)
                .keyboardShortcut(.rightArrow, modifiers: [])
                #endif
                .help("Forward 10 seconds (→)")
                .accessibilityLabel("Forward 10 seconds")
                .accessibilityIdentifier("player.skipForward")
            }
            .buttonStyle(.plain)
        }
    }

    /// The title over the timeline, as in the TV app; the menus in one glass bar under it.
    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if let episodeLine {
                        Text(episodeLine).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    Text(headline).font(.title3.weight(.bold)).lineLimit(1)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("player.title")
                }
                Spacer(minLength: 0)
                if model.hasNextEpisode && model.hasFinished {
                    Button(action: onNextEpisode) {
                        Label("Next Episode", systemImage: "forward.end.fill").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).frame(height: 40)
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .pointerInteraction(cornerRadius: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Next episode")
                    .accessibilityIdentifier("player.nextEpisode")
                }
            }
            HStack(spacing: 12) {
                Text(model.positionText)
                    .font(.footnote.monospacedDigit().weight(.medium))
                    .frame(width: 62, alignment: .leading)
                    .accessibilityIdentifier("player.time")
                    .accessibilityLabel("Elapsed time")
                    .accessibilityValue(model.positionText)
                Slider(value: Binding(get: { model.fraction }, set: { model.updateScrub(fraction: $0) }), in: 0...1) { editing in
                    if editing { model.beginScrub() } else { Task { await model.endScrub() } }
                }
                // Keep the system's percentage value for native slider adjustment.
                // Speak the useful clock information in its label instead.
                .accessibilityLabel(Text("Position, \(model.positionText) of \(model.duration.map(PlayerTime.format) ?? "unknown")"))
                .accessibilityIdentifier("player.scrubber")
                Text(model.remainingText).font(.footnote.monospacedDigit().weight(.medium)).foregroundStyle(.white.opacity(0.75))
                    .frame(width: 68, alignment: .trailing)
                    .accessibilityLabel("Remaining time")
            }
            HStack(spacing: 2) {
                barButton(.subtitles, symbol: model.subtitleChoice == .off ? "captions.bubble" : "captions.bubble.fill",
                          id: "player.subtitlesMenu")
                if model.audioTracks.count > 1 || !model.capabilities.isDisjoint(with: [.audioDelay, .externalAudio]) {
                    barButton(.audio, symbol: "waveform", id: "player.audioMenu")
                }
                speedButton
                if !model.chapters.isEmpty { barButton(.chapters, symbol: "list.bullet.rectangle", id: "player.chaptersMenu") }
                barButton(.picture, symbol: "sparkles.tv", id: "player.pictureMenu")
                #if targetEnvironment(macCatalyst)
                volumeButton
                #endif
                if model.hasNextStream {
                    Button { Task { await model.nextStream() } } label: {
                        Label("Next stream", systemImage: "arrow.trianglehead.2.clockwise").frame(width: 44, height: 44)
                            .contentShape(.rect)
                            .pointerInteraction(cornerRadius: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Try the next stream")
                    .accessibilityIdentifier("player.nextStream")
                }
            }
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .padding(.horizontal, 6)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }

    /// Opens the options panel on `tab`.
    private func barButton(_ tab: PlayerPanelTab, symbol: String, id: String) -> some View {
        Button { openPanel(tab) } label: {
            Image(systemName: symbol).frame(width: 44, height: 44)
                .contentShape(.rect)
                .pointerInteraction(cornerRadius: 22)
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityIdentifier(id)
    }

    /// The speed button shows the rate while it is not normal.
    private var speedButton: some View {
        Button { openPanel(.speed) } label: {
            Group {
                if model.state.rate == 1 {
                    Image(systemName: PlayerPanelTab.speed.symbol)
                } else {
                    Text("\(model.state.rate.formatted())×").font(.subheadline.weight(.semibold))
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
            .pointerInteraction(cornerRadius: 22)
        }
        .buttonStyle(.plain)
        .help("Playback speed")
        .accessibilityLabel("Speed")
        .accessibilityIdentifier("player.speedMenu")
    }

    #if targetEnvironment(macCatalyst)
    /// The player's own level, not the system's: iPhone's hardware buttons already change the system level, so iPhone has no
    /// control of its own here.
    private var volumeButton: some View {
        Button { model.toggleMute() } label: {
            Image(systemName: volumeSymbol).frame(width: 44, height: 44)
                .contentShape(.rect)
                .pointerInteraction(cornerRadius: 22)
        }
        .help(model.isMuted ? "Unmute (M)" : "Mute (M)")
        .accessibilityLabel(model.isMuted ? "Unmute" : "Mute")
        .accessibilityValue("\(Int((model.volume * 100).rounded())) percent")
        .accessibilityIdentifier("player.mute")
    }

    private var volumeSymbol: String {
        if model.isMuted || model.volume == 0 { return "speaker.slash.fill" }
        return model.volume < 0.5 ? "speaker.fill" : "speaker.wave.2"
    }
    #endif
}
#endif
