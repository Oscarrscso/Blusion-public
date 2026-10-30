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
    let infoModel: PlayerInfoModel
    let onClose: () -> Void
    let onNextEpisode: () -> Void
    let pipToggle: () -> Void
    let pipAvailable: Bool
    /// Opens or closes the episode picker, for a series.
    var onShowEpisodes: () -> Void = {}
    /// The episodes' panel hangs from the top bar: the transport and the bottom panel step back behind it.
    var episodesOpen = false
    /// The open menu, shown on the bar that chooses it; nil while none is open.
    @Binding var panel: PlayerPanelTab?
    var actions = PlayerControlActions()
    /// AI upscaling, for the Info menu: what it is doing, and how many frames a second it scales.
    var upscaling: SuperResolutionRenderer?
    var onShowStreams: () -> Void = {}
    /// The streams' panel hangs from the top bar alongside the episode picker.
    var streamsOpen = false
    /// The picture is on screen (`PlayerContent.isVideoReady`). Until then only the startup spinner and Close show.
    var isVideoReady = true
    /// Playback has been waiting for data for a moment: the play button shows a spinner (and still pauses).
    var isStalled = false

    /// No play button, skip buttons or scrubber until the film is playing on screen.
    private var showsPlayback: Bool { model.hasStartedPlayback && isVideoReady }
    /// A menu is open: only the bar and the menu sitting on it show.
    private var menuOpen: Bool { panel != nil }
    private var topPanelOpen: Bool { episodesOpen || streamsOpen }
    /// An episode of a series: the player offers the other episodes. A film's request names no series.
    private var hasEpisodes: Bool {
        guard !model.plan.isOffline else { return false }
        let request = model.plan.request
        return request.episode != nil || request.season != nil || request.seriesName != nil
    }

    var body: some View {
        // Overlay content must never contribute a minimum size to the player.
        // In landscape the old 150 + 280 pt scrims made the whole video taller.
        GeometryReader { viewport in
            ZStack {
                // Keep transport centered in the *viewport*, independent of the height of the
                // title, timeline or toolbar at the bottom.
                transport
                    .opacity(showsPlayback && !menuOpen && !topPanelOpen ? 1 : 0)
                    .allowsHitTesting(showsPlayback && !menuOpen && !topPanelOpen)
                    .accessibilityHidden(!showsPlayback || menuOpen || topPanelOpen)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 0) {
                    if !menuOpen { topBar }
                    Spacer(minLength: 12)
                    bottomPanel
                        .opacity(showsPlayback && !topPanelOpen ? 1 : 0)
                        .allowsHitTesting(showsPlayback && !topPanelOpen)
                        .accessibilityHidden(!showsPlayback || topPanelOpen)
                        // An open menu takes the height above the bar before the space over it does.
                        .layoutPriority(menuOpen ? 1 : 0)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .animation(.easeInOut(duration: 0.2), value: menuOpen)
            .animation(.easeInOut(duration: 0.2), value: topPanelOpen)
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
            if showsPlayback { zoomButton }
            Spacer(minLength: 0)
            if pipAvailable || canAirPlay || model.plan.candidates.count > 1 || hasEpisodes {
                HStack(spacing: 0) {
                    if hasEpisodes {
                        Button {
                            Haptics.tap()
                            onShowEpisodes()
                        } label: {
                            Image(systemName: "list.bullet").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                                .contentShape(.rect)
                                .pointerInteraction(cornerRadius: 22)
                        }
                        .help("Episodes")
                        .accessibilityLabel("Episodes")
                        .accessibilityIdentifier("player.episodes")
                    }
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
                    if model.plan.candidates.count > 1 {
                        Button {
                            Haptics.tap()
                            onShowStreams()
                        } label: {
                            Image(systemName: "arrow.trianglehead.2.clockwise")
                                .font(.body.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                                .pointerInteraction(cornerRadius: 22)
                        }
                        .help("Choose another stream")
                        .accessibilityLabel("Choose stream")
                        .accessibilityIdentifier("player.nextStream")
                    }
                }
                .padding(.horizontal, 2)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .buttonStyle(.plain)
    }

    /// Infuse's zoom button: each tap moves to the next Zoom Mode, and its symbol shows the one in use.
    private var zoomButton: some View {
        Button {
            Haptics.tap()
            model.cycleZoomMode()
        } label: {
            Image(systemName: Self.zoomSymbol(model.zoomMode)).font(.body.weight(.semibold)).frame(width: 44, height: 44)
                .contentTransition(.symbolEffect(.replace))
                .glassEffect(.regular.interactive(), in: .circle)
                .pointerInteraction(cornerRadius: 22)
        }
        .help("Zoom Mode: \(model.zoomMode.label)")
        .accessibilityLabel("Zoom Mode")
        .accessibilityValue(model.zoomMode.label)
        .accessibilityIdentifier("player.zoomMode")
    }

    static func zoomSymbol(_ mode: VideoZoomMode) -> String {
        switch mode {
        case .normal: "rectangle.arrowtriangle.2.inward"
        case .aspectFit: "arrow.left.and.right"
        case .crop: "crop"
        case .fill: "arrow.up.left.and.arrow.down.right"
        case .stretch: "arrow.up.and.down.and.arrow.left.and.right"
        }
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
                    ZStack {
                        if isStalled {
                            Spinner().controlSize(.large).transition(.opacity)
                        } else {
                            Image(systemName: model.wantsPlayback ? "pause.fill" : "play.fill")
                                .font(.system(size: 34, weight: .semibold))
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: isStalled)
                    .frame(width: 80, height: 80).glassEffect(.regular.interactive(), in: .circle)
                    .pointerInteraction(cornerRadius: 40)
                }
                #if !targetEnvironment(macCatalyst)
                .keyboardShortcut(" ", modifiers: [])
                #endif
                .help(model.wantsPlayback ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(model.wantsPlayback ? "Pause" : "Play")
                .accessibilityValue(isStalled ? "Loading" : "")
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

    /// The title over the timeline, as in the TV app, and the menu bar under them. With a menu open, the menu stands on the bar in
    /// the title's and timeline's place, its left edge on the bar's.
    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if menuOpen {
                PlayerOptionsPanel(model: model, infoModel: infoModel, tab: $panel, actions: actions, upscaling: upscaling)
                    .frame(maxWidth: 510, maxHeight: panel == .info ? .infinity : 510)
                    .layoutPriority(1)
                    .transition(.opacity)
            } else {
                titleRow
                timelineRow
            }
            menuBar
        }
    }

    private var titleRow: some View {
        HStack(alignment: .bottom, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(headline).font(.title3.weight(.bold)).lineLimit(1)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("player.title")
                if let episodeLine {
                    Text(episodeLine).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
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
    }

    private var timelineRow: some View {
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
            .overlay {
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(.rect)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { drag in
                                    if !model.isScrubbing { model.beginScrub() }
                                    model.updateScrub(fraction: drag.location.x / max(1, geometry.size.width))
                                }
                                .onEnded { drag in
                                    model.updateScrub(fraction: drag.location.x / max(1, geometry.size.width))
                                    Task { await model.endScrub() }
                                }
                        )
                        .accessibilityHidden(true)
                }
            }
            // Keep the system's percentage value for native slider adjustment.
            // Speak the useful clock information in its label instead.
            .accessibilityLabel(Text("Position, \(model.positionText) of \(model.duration.map(PlayerTime.format) ?? "unknown")"))
            .accessibilityIdentifier("player.scrubber")
            Text(model.remainingText).font(.footnote.monospacedDigit().weight(.medium)).foregroundStyle(.white.opacity(0.75))
                .frame(width: 68, alignment: .trailing)
                .accessibilityLabel("Remaining time")
        }
    }

    /// The menus in one glass bar: the system segmented control picks the menu shown above it (`PlayerMenuBar`).
    private var menuBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
            PlayerMenuBar(tabs: menuTabs, selection: $panel, speedLabel: speedLabel, subtitlesOn: model.subtitleChoice != .off)
                .fixedSize()
            #if targetEnvironment(macCatalyst)
            volumeButton
            #endif
            }
        }
        .font(.body.weight(.semibold))
        .padding(4)
        .glassEffect(.regular, in: .capsule)
    }

    /// The menus this film has: Audio only with a choice to make in it, Chapters only with chapter markers.
    private var menuTabs: [PlayerPanelTab] {
        var tabs: [PlayerPanelTab] = [.subtitles]
        if model.audioTracks.count > 1 || !model.capabilities.isDisjoint(with: [.audioDelay, .externalAudio]) { tabs.append(.audio) }
        tabs.append(.speed)
        if !model.chapters.isEmpty { tabs.append(.chapters) }
        tabs += [.picture, .info]
        return tabs
    }

    /// The speed segment shows the rate while it is not normal.
    private var speedLabel: String? {
        model.state.rate == 1 ? nil : "\(model.state.rate.formatted())×"
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
