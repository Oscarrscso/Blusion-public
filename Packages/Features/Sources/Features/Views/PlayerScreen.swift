#if canImport(UIKit)
import PlayerKit
import StremioKit
import SwiftUI

/// Full-screen player. Moving on to the next episode swaps the plan, which rebuilds the content with fresh state.
struct PlayerScreen: View {
    let services: AppServices
    @State private var plan: PlaybackPlan

    init(plan: PlaybackPlan, services: AppServices) {
        self.services = services
        _plan = State(initialValue: plan)
    }

    var body: some View {
        PlayerContent(plan: plan, services: services) { plan = $0 }
            .id(plan.id)
    }
}

struct PlayerContent: View {
    @State private var model: PlayerViewModel
    @State private var isPreparingNext = false
    #if canImport(UIKit) && canImport(AVKit)
    @State private var pip = PiPProxy()
    @State private var superResolution = SuperResolutionRenderer()
    @State private var ambient = AmbientSampler()
    #endif
    @State private var importsSubtitle = false
    /// The options panel's open tab; nil when it is closed.
    @State private var panel: PlayerPanelTab?
    @State private var importsAudio = false
    @State private var showsOpenSubtitles = false
    /// The level a brightness or volume swipe is setting, for its indicator.
    @State private var swipeLevel: SwipeLevel?
    @State private var swipeStart: (kind: SwipeLevel.Kind, value: Double)?
    @State private var showingStartupArtwork = true
    @Environment(\.dismiss) private var dismiss
    let services: AppServices
    let onNextPlan: (PlaybackPlan) -> Void

    init(plan: PlaybackPlan, services: AppServices, onNextPlan: @escaping (PlaybackPlan) -> Void) {
        self.services = services
        self.onNextPlan = onNextPlan
        _model = State(initialValue: PlayerViewModel(plan: plan, services: services))
        PlayerPreload.begin(plan, services: services)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            #if canImport(UIKit) && canImport(AVKit)
            if model.preferences.ambientMode { AmbientGlow(colours: ambient.colours) }
            #endif
            // Keep the video at a fixed full-screen size while controls come and go.
            GeometryReader { viewport in
                surface
                    .frame(width: viewport.size.width, height: viewport.size.height)
                    .clipped()
            }
            .ignoresSafeArea()
            if showingStartupArtwork && model.failureMessage == nil {
                startupArtwork.transition(.opacity)
            }
            SubtitleOverlay(cues: model.activeCues, bitmap: model.activeBitmapCue, style: model.subtitleStyle, controlsVisible: model.controlsVisible)
            if model.showsBufferingIndicator {
                Spinner().controlSize(.large)
                    .frame(width: 64, height: 64).glassEffect(.regular, in: .circle)
                    .accessibilityIdentifier("player.buffering")
            }
            gestureLayer
            if model.controlsVisible && panel == nil && model.failureMessage == nil {
                PlayerControls(model: model, onClose: close, onNextEpisode: playNextEpisode, pipToggle: pipToggle, pipAvailable: pipAvailable,
                               openPanel: openPanel)
                    .transition(.opacity)
            }
            if let marker = model.activeSkipMarker, model.failureMessage == nil {
                skipButton(marker)
            }
            if let swipeLevel { SwipeLevelIndicator(level: swipeLevel) }
            if panel != nil && model.failureMessage == nil {
                PlayerOptionsPanel(model: model, tab: $panel, actions: controlActions)
                    .transition(.opacity)
            }
            if let notice = model.notice, model.failureMessage == nil, !model.isPlaying || model.coordinator?.failedAttempts.isEmpty == false {
                VStack {
                    Spacer()
                    Text(notice).font(.footnote.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 10).glassEffect(.regular, in: .capsule)
                        .foregroundStyle(.white).padding(.bottom, 200)
                }
                .accessibilityIdentifier("player.notice")
            }
            if let message = model.failureMessage {
                FailureOverlay(message: message, onClose: close)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.controlsVisible)
        .onChange(of: model.state.status) { _, status in
            // The native engine waits for its layer's first decoded frame; fallback
            // engines use the playing state because they have a separate surface.
            if !(model.coordinator?.engine is AVEngine), status == .playing {
                revealVideo()
            }
        }
        .task { await model.start() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if panel == nil { model.hideControlsIfIdle() }
                await model.skipAutomaticallyIfNeeded()
            }
        }
        .fileImporter(isPresented: $importsSubtitle, allowedContentTypes: SubtitleFileTypes.subtitles) { result in
            if case .success(let url) = result { Task { await model.loadSubtitleFile(at: url) } }
        }
        .background {
            // A second importer on the same view would replace the first; this one sits on its own view.
            Color.clear.fileImporter(isPresented: $importsAudio, allowedContentTypes: SubtitleFileTypes.audio) { result in
                if case .success(let url) = result { Task { await model.loadAudioFile(at: url) } }
            }
        }
        .sheet(isPresented: $showsOpenSubtitles) { OpenSubtitlesSheet(model: model) }
        .onChange(of: model.hasFinished) { _, finished in
            if finished { Task { await handleEnd() } }
        }
        .onDisappear { Task { await model.close() } }
        .modifier(PlayerChrome(model: model))
        #if os(iOS)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        #endif
        .accessibilityIdentifier("player.screen")
        #if targetEnvironment(macCatalyst)
        // Moving the pointer over the player shows its controls again, as they hide when idle while playing.
        .onContinuousHover { phase in
            if case .active = phase { model.showControls() }
        }
        .background { PlayerKeyboard(model: model, onClose: escape) }
        #endif
    }

    private func openPanel(_ tab: PlayerPanelTab) {
        Haptics.tap()
        withAnimation(.easeInOut(duration: 0.17)) { panel = tab }
    }

    private func revealVideo() {
        guard showingStartupArtwork else { return }
        withAnimation(.easeOut(duration: 0.2)) { showingStartupArtwork = false }
    }

    /// Display the title's existing poster rather than an empty black screen
    /// until the video renderer has its actual first frame.
    private var startupArtwork: some View {
        GeometryReader { viewport in
            ZStack {
                Color.black
                if let poster = PosterQuality.smallest(model.plan.request.poster) {
                    // Reuse Blusion's downsampled/cached image instead of downloading
                    // and decoding the original poster again at video startup.
                    ArtworkImage(url: poster, maxPixelSize: 600, contentMode: .fill,
                                 acceptsAnyCachedSize: true)
                        .frame(width: viewport.size.width, height: viewport.size.height)
                        .blur(radius: 34)
                        .overlay(.black.opacity(0.58))
                }
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Preparing video")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityLabel("Preparing video")
    }

    #if targetEnvironment(macCatalyst)
    /// Escape closes the options panel first, then the player.
    private func escape() {
        if panel != nil {
            withAnimation(.snappy(duration: 0.25)) { panel = nil }
            model.showControls()
        } else {
            close()
        }
    }
    #endif

    private var controlActions: PlayerControlActions {
        PlayerControlActions(openSubtitleFile: { importsSubtitle = true }, openAudioFile: { importsAudio = true },
                             searchOpenSubtitles: { showsOpenSubtitles = true }, toggleAmbient: { model.toggleAmbientMode() })
    }

    private func skipButton(_ marker: SkipMarker) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    Haptics.tap()
                    if model.skipEndsMedia(marker) && model.hasNextEpisode {
                        playNextEpisode()
                    } else {
                        Task { await model.skip(marker) }
                    }
                } label: {
                    Label(marker.kind == .credits && model.hasNextEpisode ? "Next Episode" : marker.kind.buttonTitle,
                          systemImage: "forward.fill")
                        .font(.headline)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .pointerInteraction(cornerRadius: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .keyboardShortcut("s", modifiers: [])
                .accessibilityIdentifier("player.skipMarker")
            }
            .padding(.trailing, 24)
            .padding(.bottom, model.controlsVisible ? 190 : 40)
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var surface: some View {
        #if canImport(UIKit) && canImport(AVKit)
        PlayerSurface(engine: model.coordinator?.engine, pip: pip, layout: model.videoLayout, upscaling: model.processing.upscaling,
                      embeddedSubtitlesOn: { if case .embedded = model.subtitleChoice { return true } else { return false } }(),
                      ambientMode: model.preferences.ambientMode, superResolution: superResolution, ambient: ambient,
                      onFirstVideoFrame: revealVideo)
            // The picture stays put: no animation of the controls or anything else carries over to it.
            .transaction { $0.animation = nil }
            .onDisappear {
                superResolution.tearDown()
                ambient.stop()
            }
        #else
        Color.black
        #endif
    }

    private var pipAvailable: Bool {
        #if canImport(UIKit) && canImport(AVKit)
        return model.canPictureInPicture && pip.isPossible
        #else
        return false
        #endif
    }

    private func pipToggle() {
        #if canImport(UIKit) && canImport(AVKit)
        pip.toggle()
        #endif
    }

    /// Tap toggles the controls; double-tap on the left or right third skips back or forward 10 s. On iPhone and iPad a vertical swipe on
    /// the left third sets the brightness, on the right third the volume (Settings can turn that off), a swipe down in the middle closes,
    /// and a pinch zooms.
    private var gestureLayer: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in
                    let third = proxy.size.width / 3
                    if location.x < third {
                        Task { await model.skip(by: -10) }
                    } else if location.x > 2 * third {
                        Task { await model.skip(by: 10) }
                    } else {
                        model.togglePlayPause()
                    }
                }
                .onTapGesture { model.toggleControls() }
                #if !targetEnvironment(macCatalyst)
                .gesture(DragGesture(minimumDistance: 16).onChanged { value in swipeChanged(value, in: proxy.size) }
                    .onEnded { value in swipeEnded(value, in: proxy.size) })
                .simultaneousGesture(MagnifyGesture().onEnded { value in
                    // Pinch out to fill the display with a centred crop, pinch in
                    // to show the whole original frame. Never distort the ratio.
                    if value.magnification > 1.08 {
                        model.setVideoFit(.fill)
                    } else if value.magnification < 0.92 {
                        model.setVideoFit(.fit)
                    }
                })
                #endif
        }
        .accessibilityHidden(true)
    }

    #if !targetEnvironment(macCatalyst)
    private func swipeChanged(_ value: DragGesture.Value, in size: CGSize) {
        guard model.preferences.swipeGestures else { return }
        let third = size.width / 3
        if swipeStart == nil {
            // Vertical swipes only: a sideways one is left alone.
            guard abs(value.translation.height) > abs(value.translation.width) * 1.5 else { return }
            if value.startLocation.x < third {
                swipeStart = (.brightness, Double(ScreenBrightness.value))
            } else if value.startLocation.x > 2 * third {
                swipeStart = (.volume, Double(model.isMuted ? 0 : model.volume))
            } else {
                return
            }
        }
        guard let start = swipeStart else { return }
        let level = min(1, max(0, start.value - value.translation.height / (size.height * 0.7)))
        switch start.kind {
        case .brightness: ScreenBrightness.value = CGFloat(level)
        case .volume: model.setVolume(Float(level))
        }
        swipeLevel = SwipeLevel(kind: start.kind, value: level)
    }

    private func swipeEnded(_ value: DragGesture.Value, in size: CGSize) {
        let wasLevel = swipeStart != nil
        swipeStart = nil
        withAnimation(.easeOut(duration: 0.3).delay(0.4)) { swipeLevel = nil }
        let third = size.width / 3
        let inMiddle = value.startLocation.x >= third && value.startLocation.x <= 2 * third
        if !wasLevel, value.translation.height > 140, inMiddle || !model.preferences.swipeGestures { close() }
    }
    #endif

    private func close() {
        Task {
            await model.close()
            dismiss()
        }
    }

    private func playNextEpisode() {
        guard !isPreparingNext else { return }
        isPreparingNext = true
        Task {
            await model.close()
            if let next = await model.prepareNextEpisode() {
                onNextPlan(next)
            } else {
                dismiss()   // no auto-selectable stream: back to the picker
            }
            isPreparingNext = false
        }
    }

    private func handleEnd() async {
        if model.hasNextEpisode { playNextEpisode() } else { model.showControls() }
    }
}

/// Starts fetching the stream a player opens on as soon as the player is made, before its screen appears. SwiftUI makes a view again
/// and again, so each plan starts it once.
@MainActor
enum PlayerPreload {
    private static var begun: Set<UUID> = []

    static func begin(_ plan: PlaybackPlan, services: AppServices) {
        guard let first = plan.candidates.first, begun.insert(plan.id).inserted else { return }
        services.preloadStream(first)
    }
}

/// Lock-screen / Control Center integration and state mirroring.
private struct PlayerChrome: ViewModifier {
    let model: PlayerViewModel
    #if os(iOS)
    @State private var nowPlaying: NowPlayingController?
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onAppear {
                nowPlaying = NowPlayingController(title: model.plan.request.title, actions: .init(
                    play: { model.coordinator?.play() },
                    pause: { model.coordinator?.pause() },
                    toggle: { model.togglePlayPause() },
                    skip: { seconds in Task { await model.skip(by: seconds) } },
                    seek: { position in Task { await model.coordinator?.seek(to: position) } }))
            }
            .onChange(of: model.state) { _, state in nowPlaying?.update(state) }
            .onDisappear {
                nowPlaying?.tearDown()
                nowPlaying = nil
            }
        #else
        content
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// Mac keyboard shortcuts that work while the controls are hidden. They call the same actions as the buttons in `PlayerControls`,
/// whose own shortcuts are compiled out on Mac so each key has one registration.
private struct PlayerKeyboard: View {
    let model: PlayerViewModel
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Button("Close", action: onClose)
                .keyboardShortcut(.escape, modifiers: [])
            Button("Play or pause") { model.togglePlayPause() }
                .keyboardShortcut(" ", modifiers: [])
            Button("Back 10 seconds") { Task { await model.skip(by: -10) } }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Forward 10 seconds") { Task { await model.skip(by: 10) } }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Subtitles") { Task { await model.cycleSubtitles() } }
                .keyboardShortcut("c", modifiers: [])
            Button("Volume up") { model.adjustVolume(by: 0.1) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("Volume down") { model.adjustVolume(by: -0.1) }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button("Mute") { model.toggleMute() }
                .keyboardShortcut("m", modifiers: [])
            Button("Previous chapter") { Task { await model.previousChapter() } }
                .keyboardShortcut("[", modifiers: [])
            Button("Next chapter") { Task { await model.nextChapter() } }
                .keyboardShortcut("]", modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif

struct FailureOverlay: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
            Text("Can't play this").font(.title2.bold())
            Text(message).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Close", action: onClose).buttonStyle(.primaryActionCompact).accessibilityIdentifier("player.failure.close")
        }
        .padding(24)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(24)
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.failure")
    }
}
#endif
