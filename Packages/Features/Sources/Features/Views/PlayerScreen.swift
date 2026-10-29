#if canImport(UIKit)
import Persistence
import PlayerKit
import StremioKit
import SwiftUI

/// Full-screen player. Moving on to the next episode swaps the plan, which rebuilds the content with fresh state.
struct PlayerScreen: View {
    let services: AppServices
    @State private var plan: PlaybackPlan
    @Environment(LivePlaybackSession.self) private var livePlayback
    /// A player readied before its plan's screen showed (see `PlayerViewModel.prepare`): by the stream picker for the plan this screen
    /// opened on, by Up Next for the next episode. Used only for its own plan.
    @State private var prepared: PlayerViewModel?

    init(plan: PlaybackPlan, services: AppServices, prepared: PlayerViewModel? = nil) {
        self.services = services
        _prepared = State(initialValue: prepared?.plan.id == plan.id ? prepared : nil)
        _plan = State(initialValue: plan)
    }

    var body: some View {
        // A screen starting over for a plan it already plays rejoins the live session for it, keeping the engine, stream, position and
        // tracks the session holds rather than starting a second player.
        let readied = (prepared?.plan.id == plan.id ? prepared : nil) ?? livePlayback.session(for: plan)
        PlayerContent(plan: plan, services: services, prepared: readied) { next, readiedNext in
            prepared = readiedNext
            plan = next
        }
        .id(plan.id)
    }
}

/// The next episode and the player readied for it off screen, muted and paused on its first frame.
private struct UpNextEpisode {
    let plan: PlaybackPlan
    let model: PlayerViewModel
}

struct PlayerContent: View {
    @State private var model: PlayerViewModel
    @State private var isPreparingNext = false
    @Environment(\.windowSafeArea) private var windowSafeArea
    #if canImport(UIKit) && canImport(AVKit)
    @State private var pip = PiPProxy()
    @State private var superResolution = SuperResolutionRenderer()
    /// Original picture samples: encoded bars and ambient mode's colours.
    @State private var picture = PictureSampler()
    #endif
    @State private var importsSubtitle = false
    /// The open menu (it sits on the controls' menu bar); nil when none is open.
    @State private var panel: PlayerPanelTab?
    @State private var noticeVisible = false
    /// The current chapter marker after its three-second Skip prompt has elapsed.
    @State private var hiddenSkipMarker: SkipMarker?
    @State private var importsAudio = false
    @State private var showsOpenSubtitles = false
    /// The episode picker's panel is open, dropped from the Episodes button.
    @State private var showsEpisodes = false
    @State private var showsStreams = false
    /// The level a brightness or volume swipe is setting, for its indicator.
    @State private var swipeLevel: SwipeLevel?
    @State private var swipeStart: (kind: SwipeLevel.Kind, value: Double)?
    /// The accumulated timeline fraction of a sideways drag; nil while no drag seeks.
    @State private var seekSwipeFraction: Double?
    @State private var seekSwipeTranslation: Double = 0
    /// A pinch is under way. A drag that is part of one neither seeks nor sets a level.
    @GestureState private var isPinching = false
    @State private var isDragging = false
    @State private var dragDirection: Axis?
    @State private var dragIsPinch = false
    /// Resets when the drag ends or when the system takes the touch, which skips the drag's `onEnded`.
    @GestureState private var isDragGestureActive = false
    /// Ignore release taps from a pinch or swipe, including when one finger lifts before the other.
    @State private var pictureGestureEndedAt: Date?
    /// The picture is being pressed and held: double speed until the finger lifts.
    @GestureState private var isHoldingFast = false
    /// When the last hold ended: the tap its release makes does not toggle the controls.
    @State private var holdEndedAt: Date?
    /// The drag under way began as a hold: it neither seeks nor closes the player.
    @State private var dragIsHold = false
    @State private var nativeFrameEngineID: ObjectIdentifier?
    /// The next episode, readied during this one's last minute (`UpNextTiming`).
    @State private var upNext: UpNextEpisode?
    @State private var upNextTask: Task<Void, Never>?
    /// How far Next Episode's countdown has run, 0...1; nil while the button is not up.
    @State private var upNextProgress: Double?
    @State private var upNextCountdown: Task<Void, Never>?
    /// Watch Credits was chosen: the button stays away until the end comes up again. The episode still moves on when it ends.
    @State private var watchesCredits = false
    /// The readied player went to the next episode's screen: leaving this one must not close it.
    @State private var handedOverUpNext = false
    /// This screen handed its plan to another player screen (Up Next or a chosen episode): leaving it must not set the new
    /// session aside.
    @State private var handedOverPlan = false
    /// A stall has lasted half a second (`stallSpinnerDelay`): only then does a spinner show, so a momentary wait never flashes one.
    @State private var showsStall = false
    #if DEBUG
    @State private var testVideoGeometry = ""
    #endif
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LivePlaybackSession.self) private var livePlayback
    let services: AppServices
    /// Moves to the next episode's plan, with the player readied for it when there is one.
    let onNextPlan: (PlaybackPlan, PlayerViewModel?) -> Void

    init(plan: PlaybackPlan, services: AppServices, prepared: PlayerViewModel? = nil,
         onNextPlan: @escaping (PlaybackPlan, PlayerViewModel?) -> Void) {
        self.services = services
        self.onNextPlan = onNextPlan
        _model = State(initialValue: prepared ?? Self.makeModel(plan: plan, services: services))
        PlayerPreload.begin(plan, services: services)
    }

    /// The player's model, made here or by the stream picker that readies a player before opening this screen.
    static func makeModel(plan: PlaybackPlan, services: AppServices) -> PlayerViewModel {
        #if DEBUG
        // Automation round trips can exceed the normal controls idle window.
        // Freeze only its injected interaction clock; playback and gestures stay live.
        let isUITesting = ProcessInfo.processInfo.environment["BLUSION_UITEST"] == "1"
        return PlayerViewModel(plan: plan, services: services, now: { isUITesting ? Date.distantPast : Date() })
        #else
        return PlayerViewModel(plan: plan, services: services)
        #endif
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            #if canImport(UIKit) && canImport(AVKit)
            if model.preferences.ambientMode { AmbientGlow(colours: picture.colours) }
            #endif
            // Keep the video at a fixed full-screen size while controls come and go.
            GeometryReader { viewport in
                surface
                    .frame(width: viewport.size.width, height: viewport.size.height)
                    .clipped()
            }
            .ignoresSafeArea()
            ZStack {
                if !isVideoReady && model.failureMessage == nil {
                    startupSpinner.transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isVideoReady)
            SubtitleOverlay(cues: model.activeCues, bitmap: model.activeBitmapCue, style: model.subtitleStyle,
                            controlsVisible: model.controlsVisible, layout: model.videoLayout)
                .opacity(isVideoReady ? 1 : 0)
            ZStack {
                if showsStall && model.showsBufferingIndicator && isVideoReady {
                    spinner.accessibilityIdentifier("player.buffering").transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: showsStall && model.showsBufferingIndicator)
            .allowsHitTesting(false)
            gestureLayer
            // With a menu or the episodes open, a tap anywhere but them and the controls closes them.
            ZStack {
                if (panel != nil || showsEpisodes) && model.failureMessage == nil {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .contentShape(.rect)
                        .onTapGesture { closeMenus() }
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: panel != nil || showsEpisodes)
            // Retain the controls (and native scrubber) while hidden. Their local
            // fade cannot change the video viewport or animate the renderer.
            PlayerControls(model: model, onClose: close, onNextEpisode: playNextEpisode, pipToggle: pipToggle, pipAvailable: pipAvailable,
                           onShowEpisodes: toggleEpisodes, episodesOpen: showsEpisodes,
                           panel: $panel, actions: controlActions, upscaling: upscalingRenderer,
                           onShowStreams: { closeMenus(); model.showControls(); showsStreams = true },
                           isVideoReady: isVideoReady, isStalled: showsStall && model.isStalled)
                .opacity(controlsAreVisible ? 1 : 0)
                .allowsHitTesting(controlsAreVisible)
                .accessibilityHidden(!controlsAreVisible)
                .disabled(!controlsAreVisible)
                .animation(.easeInOut(duration: 0.18), value: controlsAreVisible)
            episodePanel
            ZStack {
                if let progress = upNextProgress, upNext != nil, model.failureMessage == nil {
                    upNextPrompt(progress: progress)
                } else if let marker = model.activeSkipMarker, marker != hiddenSkipMarker,
                          model.failureMessage == nil, isVideoReady {
                    skipButton(marker)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: upNextProgress != nil)
            if let swipeLevel { SwipeLevelIndicator(level: swipeLevel) }
            ZStack {
                if model.heldRate != nil { doubleSpeedBadge.transition(.opacity) }
            }
            .animation(.easeInOut(duration: 0.15), value: model.heldRate != nil)
            if let notice = model.notice, noticeVisible, model.failureMessage == nil {
                VStack {
                    Spacer()
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.65))
                        Text(notice.contains("didn't work") ? "Stream unavailable · Trying another…" : notice)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.84))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: .capsule)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .frame(maxWidth: 320)
                    .padding(.bottom, 150)
                }
                .allowsHitTesting(false)
                .accessibilityIdentifier("player.notice")
            }
            if let message = model.failureMessage {
                FailureOverlay(message: message, onClose: close)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Zoom Mode's Normal keeps the picture inside the safe area beside a notch or Dynamic Island, centred, as Infuse does.
        .onChange(of: max(windowSafeArea.leading, windowSafeArea.trailing), initial: true) { _, inset in
            model.setSafeAreaInset(inset)
        }
        .sheet(isPresented: $showsStreams, onDismiss: { model.showControls() }) {
            NavigationStack {
                List(Array(model.plan.candidates.enumerated()), id: \.element.id) { entry in
                    Button {
                        showsStreams = false
                        Task { await model.selectStream(at: entry.offset) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.element.title)
                                Text(entry.element.addonName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if entry.offset == model.currentStreamIndex { Image(systemName: "checkmark") }
                        }
                    }
                    .disabled(entry.offset == model.currentStreamIndex)
                    .accessibilityIdentifier("player.stream.\(entry.element.id)")
                }
                .navigationTitle("Choose stream")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showsStreams = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .onChange(of: panel) { old, new in
            // A closed menu leaves the controls up, with a fresh idle delay, whichever way it was closed.
            if old != nil && new == nil { model.showControls() }
            // One pop-out at a time: a menu opened from the bar closes the episodes.
            if new != nil { showsEpisodes = false }
        }
        .onChange(of: isHoldingFast) { _, holding in
            if !holding { holdEndedAt = Date() }
            model.holdDoubleSpeed(holding)
            if holding && model.heldRate != nil { Haptics.tap() }
        }
        #if !targetEnvironment(macCatalyst)
        .onChange(of: isPinching) { _, pinching in
            if pinching { pinchBegan() } else { pictureGestureEndedAt = Date() }
        }
        .onChange(of: isDragGestureActive) { _, active in
            if !active {
                pictureGestureEndedAt = Date()
                Task { dragFinished() }
            }
        }
        #endif
        .onChange(of: model.notice, initial: true) { _, notice in
            withAnimation(.easeInOut(duration: 0.2)) { noticeVisible = notice != nil }
        }
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { noticeVisible = false }
        }
        .task(id: model.activeSkipMarker) {
            guard let marker = model.activeSkipMarker else {
                hiddenSkipMarker = nil
                return
            }
            hiddenSkipMarker = nil
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, model.activeSkipMarker == marker else { return }
            withAnimation(.easeInOut(duration: 0.2)) { hiddenSkipMarker = marker }
        }
        .task { await model.start() }
        .task(id: model.isStalled) {
            guard model.isStalled else {
                showsStall = false
                return
            }
            try? await Task.sleep(for: Self.stallSpinnerDelay)
            if !Task.isCancelled { showsStall = true }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if panel == nil { model.hideControlsIfIdle() }
                await model.skipAutomaticallyIfNeeded()
                await model.recordSessionSnapshot()
                updateUpNext()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the front keeps the session on the air, but its snapshot should already say where it is if the app is killed.
            if phase != .active { Task { await model.recordSessionSnapshot(force: true) } }
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
        .onAppear {
            // The screen is up: its session is the app's live one. A session the screen itself handed over and rebuilt (Up Next) sits
            // in `prepared`, so what presents here is already this plan's player.
            livePlayback.present(model)
        }
        .onDisappear {
            leaveUpNext()
            // An actual dismissal releases the session (a closed one forgets itself idempotently). A disappearance that comes with
            // the app leaving the front — backgrounding, a lock — does not: the session stays on the air at the app level, and this
            // screen or a rebuilt one reattaches to it when it comes back.
            if LivePlaybackSession.closesOnDisappear(scenePhase: scenePhase) {
                Task {
                    await model.close()
                    livePlayback.forget(model)
                    // A dismissal sets the session aside; a hand-over has already saved the next one.
                    if !handedOverPlan { await PlaybackSession.clear() }
                }
            }
        }
        .modifier(PlayerChrome(model: model))
        #if os(iOS)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.screen")
        #if targetEnvironment(macCatalyst)
        // Moving the pointer over the player shows its controls again, as they hide when idle while playing.
        .onContinuousHover { phase in
            if case .active = phase { model.showControls() }
        }
        .background { PlayerKeyboard(model: model, onClose: escape) }
        #endif
    }

    /// AI upscaling, for the Info menu. Passed as the object, so its status and frame count redraw Info alone.
    private var upscalingRenderer: SuperResolutionRenderer? {
        #if canImport(UIKit) && canImport(AVKit)
        superResolution
        #else
        nil
        #endif
    }

    /// An open menu keeps the controls up: the menu stands on their bar. The episodes' panel hangs from their top bar.
    private var controlsAreVisible: Bool {
        (model.controlsVisible || panel != nil || showsEpisodes || showsStreams) && model.failureMessage == nil
    }

    /// The episodes, in a glass panel like the options menu, hanging from the Episodes button at the top trailing corner. It sits under
    /// the top bar and takes the height down to the screen's bottom margin, with the transport and timeline hidden behind it.
    private var episodePanel: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                if showsEpisodes && model.failureMessage == nil {
                    PlayerEpisodePicker(current: model.plan.request, services: services,
                                        prepare: { await model.prepareEpisode($0) }, onPlay: playChosenEpisode,
                                        onClose: closeEpisodes)
                        .frame(width: min(Self.episodePanelWidth, max(0, proxy.size.width - 40)))
                        .frame(maxHeight: min(Self.episodePanelHeight, max(0, proxy.size.height - Self.episodePanelTop - 12)))
                        .padding(.top, Self.episodePanelTop)
                        .padding(.trailing, 20)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .topTrailing)))
                }
            }
            #if targetEnvironment(macCatalyst)
            // The controls are at most 900 wide on Mac, so the panel lines up with their trailing edge.
            .frame(maxWidth: 900, maxHeight: .infinity, alignment: .topTrailing)
            #endif
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topTrailing)
        }
        .animation(.snappy(duration: 0.24), value: showsEpisodes)
    }

    private static let episodePanelWidth: CGFloat = 360
    private static let episodePanelHeight: CGFloat = 560
    /// Below the top bar: its 12 pt margin, the 44 pt buttons and a small gap.
    private static let episodePanelTop: CGFloat = 12 + 44 + 8

    private func toggleEpisodes() {
        if showsEpisodes {
            closeEpisodes()
        } else {
            panel = nil
            showsEpisodes = true
        }
    }

    private func closeEpisodes() {
        guard showsEpisodes else { return }
        showsEpisodes = false
        model.showControls()
    }

    private func closeMenus() {
        panel = nil
        closeEpisodes()
    }

    private var hasVideoFrame: Bool {
        guard let engine = model.coordinator?.engine else { return false }
        #if canImport(AVKit)
        if engine is AVEngine { return nativeFrameEngineID == ObjectIdentifier(engine) }
        #endif
        return model.state.hasVideoFrame
    }

    /// The picture is on screen, or the film plays on another screen over AirPlay. Until then the player shows only its spinner and Close:
    /// no poster, no play button, no timeline. A new stream (next episode, another stream) waits for its own first frame the same way.
    private var isVideoReady: Bool {
        hasVideoFrame || model.state.isExternalPlaybackActive
    }

    /// How long a stall lasts before a spinner shows.
    static let stallSpinnerDelay = Duration.milliseconds(500)

    /// The player's spinner, at start-up and for a stall.
    private var spinner: some View {
        Spinner().controlSize(.large)
            .frame(width: 64, height: 64).glassEffect(.regular, in: .circle)
    }

    /// At the top while a hold plays at double speed.
    private var doubleSpeedBadge: some View {
        VStack {
            Label("2×", systemImage: "forward.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 16)
            Spacer()
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playing at double speed")
        .accessibilityIdentifier("player.doubleSpeed")
    }

    /// Covers the renderer with black until its first frame, with the spinner in the middle.
    private var startupSpinner: some View {
        ZStack {
            Color.black
            spinner
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading video")
        .accessibilityIdentifier("player.preparing")
    }

    #if targetEnvironment(macCatalyst)
    /// Escape closes the options panel or the episodes first, then the player.
    private func escape() {
        if showsEpisodes {
            closeEpisodes()
        } else if panel != nil {
            panel = nil
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
        configuredSurface
            .equatable()
            #if DEBUG
            .modifier(PlayerSurfaceTestAccessibility(geometry: testVideoGeometry))
            #endif
            // The picture stays put: no animation of the controls or anything else carries over to it.
            .transaction { $0.animation = nil }
            .onDisappear {
                superResolution.tearDown()
                picture.stop()
            }
        #else
        Color.black
        #endif
    }

    #if canImport(UIKit) && canImport(AVKit)
    private var configuredSurface: PlayerSurface {
        let engine = model.coordinator?.engine
        var picture = PlayerSurface(engine: engine, pip: pip, layout: model.videoLayout, upscaling: model.processing.upscaling,
                      embeddedSubtitlesOn: { if case .embedded = model.subtitleChoice { return true } else { return false } }(),
                      ambientMode: model.preferences.ambientMode, superResolution: superResolution, sampler: picture,
                      onFirstVideoFrame: {
                          guard let engine, model.coordinator?.engine === engine else { return }
                          nativeFrameEngineID = ObjectIdentifier(engine)
                      }, onPictureAspect: { ratio in
                          guard let engine, model.coordinator?.engine === engine else { return }
                          model.setDetectedPictureAspect(ratio)
                      })
        #if DEBUG
        picture.onTestGeometry = { testVideoGeometry = $0 }
        #endif
        return picture
    }
    #endif

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

    private var acceptsPictureTap: Bool {
        !isPinching && !isDragGestureActive && !isDragging
            && (pictureGestureEndedAt.map { Date().timeIntervalSince($0) >= 0.25 } ?? true)
    }

    /// Tap toggles the controls; double-tap on the left or right third skips back or forward 10 s; press and hold plays at double speed
    /// until the finger lifts (the Mac: click and hold). On iPhone and iPad a sideways drag anywhere on the picture seeks live,
    /// coarsely at the top and finely at the bottom (`SwipeSeek`); a vertical swipe on the left third sets the brightness
    /// and on the right third the volume (Settings can turn those two off), a swipe down in the middle closes, and a pinch zooms.
    /// The layer covers the whole screen, edges included, under the controls: a drag that starts on a control (the timeline, the menu
    /// bar, a button) stays that control's own, so the system slider and segmented control keep their native touch handling.
    private var gestureLayer: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in
                    guard acceptsPictureTap else { return }
                    let third = proxy.size.width / 3
                    if location.x < third {
                        Task { await model.skip(by: -10) }
                    } else if location.x > 2 * third {
                        Task { await model.skip(by: 10) }
                    } else {
                        model.togglePlayPause()
                    }
                }
                .onTapGesture {
                    guard acceptsPictureTap else { return }
                    // The release that ends a hold at double speed is not a tap.
                    if model.heldRate != nil || holdEndedAt.map({ Date().timeIntervalSince($0) < 0.5 }) == true { return }
                    model.toggleControls()
                }
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.4, maximumDistance: 10)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($isHoldingFast) { value, holding, _ in
                        if case .second(true, _) = value { holding = true }
                    })
                #if !targetEnvironment(macCatalyst)
                .simultaneousGesture(DragGesture(minimumDistance: 12)
                    .updating($isDragGestureActive) { _, active, _ in active = true }
                    .onChanged { swipeChanged($0, in: proxy.size) }
                    .onEnded { swipeEnded($0, in: proxy.size) })
                #endif
                .simultaneousGesture(MagnifyGesture()
                    .updating($isPinching) { _, pinching, _ in pinching = true }
                    .onEnded { value in
                        pictureGestureEndedAt = Date()
                        // A shortcut for Zoom Mode: a pinch out trims bars and enlarges proportionally (Crop), a pinch in restores Normal.
                        if value.magnification > 1.08 {
                            model.pinchZoom(in: true)
                        } else if value.magnification < 0.92 {
                            model.pinchZoom(in: false)
                        }
                    })
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // Picture drag seeking is intentionally touch-only; Mac keeps its timeline and keyboard controls, as requested.
    #if !targetEnvironment(macCatalyst)
    /// A sideways swipe seeks once the film plays on screen and has a length, with no panel open.
    private var canSwipeSeek: Bool {
        model.hasStartedPlayback && isVideoReady && (model.duration ?? 0) > 0 && model.failureMessage == nil && panel == nil
    }

    private func swipeChanged(_ value: DragGesture.Value, in size: CGSize) {
        // An open menu owns its own scrolling.
        guard panel == nil else { return }
        // A finger that moves on after a hold at double speed is still holding.
        if model.heldRate != nil { dragIsHold = true }
        guard !dragIsHold else { return }
        if !isDragging {
            isDragging = true
            if isPinching { dragIsPinch = true }
        }
        guard !dragIsPinch else { return }
        if dragDirection == nil {
            // Wait for a clear axis instead of permanently classifying a slightly
            // diagonal first movement as vertical. The user's starting point can
            // be anywhere, even over the visible transport controls.
            let dx = abs(value.translation.width)
            let dy = abs(value.translation.height)
            if dx >= 14 && dx > dy * 1.2 {
                dragDirection = .horizontal
                if canSwipeSeek {
                    let startingFraction = model.fraction
                    model.beginScrub()
                    seekSwipeFraction = startingFraction
                    seekSwipeTranslation = 0
                }
            } else if dy >= 14 && dy > dx * 1.2 {
                dragDirection = .vertical
            } else {
                return
            }
        }
        if let start = seekSwipeFraction {
            let fraction = SwipeSeek.fraction(from: start, translation: value.translation.width - seekSwipeTranslation,
                                              width: size.width, duration: model.duration ?? 0,
                                              heightFraction: value.location.y / max(1, size.height))
            seekSwipeFraction = fraction
            seekSwipeTranslation = value.translation.width
            guard fraction != start else { return }
            model.updateScrub(fraction: fraction, seekImmediately: true)
            return
        }
        guard dragDirection == .vertical, model.preferences.swipeGestures else { return }
        let third = size.width / 3
        if swipeStart == nil {
            // Up or down at the sides: brightness or volume.
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
        pictureGestureEndedAt = Date()
        guard panel == nil else { return }
        if dragIsHold {
            dragIsHold = false
            return
        }
        // Use the existing seek state to include the final movement before clearing the gesture.
        if seekSwipeFraction != nil { swipeChanged(value, in: size) }
        let wasPinch = dragIsPinch
        isDragging = false
        dragIsPinch = false
        dragDirection = nil
        if seekSwipeFraction != nil {
            // Finish at the live drag's final target.
            seekSwipeFraction = nil
            Task { await model.endScrub() }
            return
        }
        guard !wasPinch else { return }
        let wasLevel = swipeStart != nil
        swipeStart = nil
        withAnimation(.easeOut(duration: 0.3).delay(0.4)) { swipeLevel = nil }
        let third = size.width / 3
        let inMiddle = value.startLocation.x >= third && value.startLocation.x <= 2 * third
        if !wasLevel, value.translation.height > 140, inMiddle || !model.preferences.swipeGestures { close() }
    }

    /// A pinch takes over a drag: keep the last live position and stop issuing seeks.
    private func pinchBegan() {
        guard isDragging else { return }
        dragIsPinch = true
        if seekSwipeFraction != nil {
            seekSwipeFraction = nil
            model.cancelScrub()
        }
    }

    /// The drag is over, ended or cancelled (the system can take the touch and skip `onEnded`). After a normal end there is nothing left
    /// to do. Otherwise a seek still open is made where the swipe left the timeline, whichever of the two runs first, and a level indicator
    /// fades, so the next drag starts clean.
    private func dragFinished() {
        if seekSwipeFraction != nil {
            seekSwipeFraction = nil
            Task { await model.endScrub() }
        }
        if swipeStart != nil {
            swipeStart = nil
            withAnimation(.easeOut(duration: 0.3).delay(0.4)) { swipeLevel = nil }
        }
        isDragging = false
        dragIsPinch = false
        dragDirection = nil
        dragIsHold = false
    }
    #endif

    private func close() {
        Task {
            await model.close()
            await PlaybackSession.clear()
            livePlayback.forget(model)
            dismiss()
        }
    }

    /// Moves to the next episode: with the player Up Next readied, which then plays at once, or else by finding its stream now.
    private func playNextEpisode() {
        guard !isPreparingNext else { return }
        isPreparingNext = true
        stopCountdown()
        Task {
            await model.close()
            livePlayback.forget(model)
            if upNext == nil { await upNextTask?.value }   // a readying under way finishes first: it is the quicker start
            handedOverPlan = true
            if let ready = upNext {
                handedOverUpNext = true
                await model.saveSessionSnapshot(for: ready.plan, candidateIndex: ready.model.currentStreamIndex)
                onNextPlan(ready.plan, ready.model)
            } else if let next = await model.prepareNextEpisode() {
                await model.saveSessionSnapshot(for: next)
                onNextPlan(next, nil)
            } else {
                // No auto-selectable stream: back to the picker, with no session for the episode that just ended.
                await PlaybackSession.clear()
                dismiss()
            }
            isPreparingNext = false
        }
    }

    private func handleEnd() async {
        if model.hasNextEpisode {
            playNextEpisode()
        } else {
            // Watched through: there is nothing to walk back into.
            await PlaybackSession.clear()
            model.showControls()
        }
    }

    /// Moves to the episode chosen in the picker, whose plan is ready: its panel closes first, then this player gives way to the new one,
    /// so the panel is never left over a player that is being replaced.
    private func playChosenEpisode(_ plan: PlaybackPlan) {
        leaveUpNext()
        showsEpisodes = false
        handedOverPlan = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await model.close()
            await model.saveSessionSnapshot(for: plan)
            livePlayback.forget(model)
            onNextPlan(plan, nil)
        }
    }

    // MARK: Up Next

    /// Called every half second. When the end comes up (`UpNextTiming`) the next episode starts loading off screen; once it is ready,
    /// Next Episode shows and counts down. Seeking back out of the end takes the button away again.
    private func updateUpNext() {
        guard model.hasNextEpisode, model.failureMessage == nil, !isPreparingNext else { return }
        let creditsToEnd = model.activeSkipMarker.map { $0.kind == .credits && model.skipEndsMedia($0) } ?? false
        let nearEnd = UpNextTiming.isNearEnd(position: model.state.position, duration: model.duration, creditsToEnd: creditsToEnd)
        if !nearEnd { watchesCredits = false }
        if nearEnd, upNext == nil, upNextTask == nil { readyNextEpisode() }
        let shows = nearEnd && upNext != nil && !watchesCredits
        if shows && upNextCountdown == nil {
            startCountdown()
        } else if !shows && upNextCountdown != nil {
            stopCountdown()
        }
    }

    /// The next episode's stream, chosen as the end of an episode chooses it, starts muted and holds on its first frame.
    private func readyNextEpisode() {
        upNextTask = Task {
            guard let plan = await model.prepareNextEpisode(), !Task.isCancelled else { return }
            let next = Self.makeModel(plan: plan, services: services)
            PlayerPreload.begin(plan, services: services)
            await next.prepare()
            guard !Task.isCancelled, !handedOverUpNext, next.coordinator?.phase == .playing else {
                await next.close()   // nothing to play in it, or this screen has gone
                return
            }
            upNext = UpNextEpisode(plan: plan, model: next)
        }
    }

    /// Counts five seconds of playback (a pause holds the count), then plays the next episode.
    private func startCountdown() {
        upNextProgress = 0
        upNextCountdown = Task {
            let clock = ContinuousClock()
            var last = clock.now
            var elapsed = Duration.zero
            while elapsed < UpNextTiming.countdown {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled else { return }
                let now = clock.now
                if model.isPlaying { elapsed += now - last }
                last = now
                upNextProgress = min(1, elapsed / UpNextTiming.countdown)
            }
            playNextEpisode()
        }
    }

    private func stopCountdown() {
        upNextCountdown?.cancel()
        upNextCountdown = nil
        upNextProgress = nil
    }

    /// This screen is going: a readied next episode it did not hand on is closed, so its stream stops.
    private func leaveUpNext() {
        upNextTask?.cancel()
        stopCountdown()
        if !handedOverUpNext, let next = upNext?.model {
            upNext = nil
            Task { await next.close() }
        }
    }

    /// Netflix's choice at the end of an episode, in the player's glass: Watch Credits, and Next Episode filling as its five seconds run.
    private func upNextPrompt(progress: Double) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Spacer()
                Button {
                    Haptics.tap()
                    watchesCredits = true
                    stopCountdown()
                } label: {
                    Text("Watch Credits")
                        .font(.headline)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .pointerInteraction(cornerRadius: 22)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("player.upNext.credits")
                Button {
                    Haptics.tap()
                    playNextEpisode()
                } label: {
                    Label("Next Episode", systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(alignment: .leading) {
                            GeometryReader { proxy in
                                Rectangle().fill(.white.opacity(0.3)).frame(width: proxy.size.width * progress)
                            }
                        }
                        .clipShape(.capsule)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .pointerInteraction(cornerRadius: 22)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: [])
                .accessibilityIdentifier("player.upNext.play")
                .accessibilityValue("Plays in \(Int((5 * (1 - progress)).rounded(.up))) seconds")
            }
            .foregroundStyle(.white)
            .padding(.trailing, 24)
            .padding(.bottom, model.controlsVisible ? 190 : 40)
        }
        .transition(.opacity)
    }
}

#if DEBUG
/// The value comes from the renderer's real layout, with its identity, viewport,
/// clipping rectangle and picture frame. It is exposed only to UI automation.
private struct PlayerSurfaceTestAccessibility: ViewModifier {
    let geometry: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if ProcessInfo.processInfo.environment["BLUSION_UITEST"] == "1" {
            content.accessibilityElement(children: .ignore)
                .accessibilityLabel("Video surface")
                .accessibilityValue(geometry)
                .accessibilityIdentifier("player.videoSurface")
        } else {
            content
        }
    }
}
#endif

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
    @Environment(\.scenePhase) private var scenePhase
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
                // Backgrounding can report the surface as gone without a dismissal: lock-screen controls stay then, as playback does.
                if LivePlaybackSession.closesOnDisappear(scenePhase: scenePhase) {
                    nowPlaying?.tearDown()
                    nowPlaying = nil
                }
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
