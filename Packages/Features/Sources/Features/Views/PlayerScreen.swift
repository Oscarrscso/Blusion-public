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

/// The next episode's player, readied off screen during this one's last minute (`UpNextTiming`).
private enum NextEpisodeState {
    case notStarted
    case readying(Task<Void, Never>)
    case ready(UpNextEpisode)
    /// Nothing to ready (no stream started for it), or this screen let it go: it is not tried again.
    case unavailable
    /// The readied player went to the next episode's screen: leaving this one must not close it.
    case handedOver
}

/// Next Episode's button at the end of an episode.
private enum UpNextPrompt: Equatable {
    case hidden
    /// Up and counting down: how far its countdown has run, 0...1.
    case counting(Double)
    /// Watch Credits was chosen: the button stays away until the end comes up again. The episode still moves on when it ends.
    case creditsChosen
}

/// Whether this player screen is giving way to another one.
private enum Departure {
    case staying
    /// Moving on to the next episode: its stream is being found, or the readied one handed over.
    case movingOn
    /// This screen handed its plan to another player screen (Up Next or a chosen episode): leaving it must not set the new
    /// session aside.
    case handedOver
}

/// The press-and-hold on the picture: whether a hold is under way, the height it began at, and whether the press rested long enough to
/// be no tap when it lifts. A reference type, so following the finger changes nothing the view draws.
@MainActor
private final class PictureHoldTrack {
    /// The hold under way, nil while none is: the height it began at, and whether its press is on a locked hold, so dragged down it
    /// releases the lock rather than starting a hold (`SpeedHoldRules.unlocks`).
    var hold: (baselineY: CGFloat, unlocking: Bool)?
    /// Stays latched after release/cancellation until the next touch starts, regardless of callback order.
    var ownsTouch = false
    /// The press rested for the hold delay, so it is not a tap when it lifts, whether or not a hold began.
    var restedLong = false
}

/// The one pop-out over the player: a menu from the controls' bar, the episode picker, or the streams.
private enum PlayerPopOut: Equatable {
    case closed
    case menu(PlayerPanelTab)
    case episodes
    case streams
}

/// A drag on the picture, from its first movement to its release.
private enum PictureDrag: Equatable {
    case idle
    /// Moving, with no clear axis yet.
    case undecided
    /// Part of a pinch: it neither seeks nor sets a level.
    case pinch
    /// Sideways, seeking: the timeline fraction it has reached, and the drag's width when it got there.
    case seeking(fraction: Double, translation: Double)
    /// Sideways where it cannot seek.
    case horizontal
    /// Up or down, before it has picked brightness or volume, or where it sets neither.
    case vertical
    /// Up or down at a side, setting brightness or volume from the level it started at.
    case level(kind: SwipeLevel.Kind, start: Double)
}

/// How far the held finger has dragged toward the next lock change (`SpeedHoldRules.lockProgress`, `unlockProgress`). Its own observable
/// object, read only by the badge, so following the finger redraws the badge and not the player.
@MainActor
@Observable
private final class HoldDragProgress {
    var fraction = 0.0

    func update(_ value: Double) {
        if fraction != value { fraction = value }
    }
}

/// The speed a hold plays at, at the top of the picture. Beside it sits the lock as it stands; while a drag moves toward a lock change, the
/// lock that change would leave, and a bar for how far the drag has got. Its own view, so following the finger redraws only this.
private struct PlayerHoldBadge: View {
    @Environment(\.layoutMetrics) private var metrics
    let model: PlayerViewModel
    let progress: HoldDragProgress

    var body: some View {
        let rate = model.state.rate.formatted()
        let locked = model.heldSpeed?.isLocked == true
        let fraction = progress.fraction
        VStack {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: lockSymbol(locked: locked, fraction: fraction))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: locked)
                    Text("\(rate)×")
                }
                if fraction > 0 {
                    ProgressView(value: fraction)
                        .tint(.white)
                        .frame(width: 64)
                        .transition(.opacity)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect(.regular, in: ScaledCapsule(scale: metrics.cornerScale(for: .playerControls)))
            .padding(.top, 16)
            .animation(.easeInOut(duration: 0.15), value: fraction > 0)
            Spacer()
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playing at \(rate) times speed")
        .accessibilityIdentifier("player.doubleSpeed")
    }

    /// The lock as it stands. While a drag moves toward a change, the lock that change would leave: an open lock on a locked hold, a closed
    /// one on an open hold.
    private func lockSymbol(locked: Bool, fraction: Double) -> String {
        if locked {
            return fraction > 0 ? "lock.open.fill" : "lock.fill"
        }
        return fraction > 0 ? "lock.fill" : "forward.fill"
    }
}

struct PlayerContent: View {
    @Environment(\.layoutMetrics) private var metrics
    @State private var model: PlayerViewModel
    @State private var infoModel: PlayerInfoModel
    @State private var departure = Departure.staying
    @Environment(\.windowSafeArea) private var windowSafeArea
    #if canImport(UIKit) && canImport(AVKit)
    @State private var pip = PiPProxy()
    @State private var superResolution = SuperResolutionRenderer()
    /// Samples the picture for ambient mode's colours.
    @State private var picture = PictureSampler()
    #endif
    @State private var importsSubtitle = false
    @State private var popOut = PlayerPopOut.closed
    /// The open menu (it sits on the controls' menu bar); nil when none is open. Opening one closes the other pop-outs.
    private var panel: PlayerPanelTab? {
        get {
            if case .menu(let tab) = popOut { return tab }
            return nil
        }
        nonmutating set {
            if let newValue { popOut = .menu(newValue) } else if case .menu = popOut { popOut = .closed }
        }
    }
    private var panelBinding: Binding<PlayerPanelTab?> { Binding(get: { panel }, set: { panel = $0 }) }
    @State private var noticeVisible = false
    /// The current chapter marker after its three-second Skip prompt has elapsed.
    @State private var hiddenSkipMarker: SkipMarker?
    @State private var importsAudio = false
    @State private var showsOpenSubtitles = false
    /// The episode picker's panel is open, dropped from the Episodes button.
    private var showsEpisodes: Bool { popOut == .episodes }
    private var showsStreams: Bool { popOut == .streams }
    /// The level a brightness or volume swipe is setting, for its indicator.
    @State private var swipeLevel: SwipeLevel?
    #if os(iOS) && !targetEnvironment(macCatalyst)
    @State private var systemVolume = SystemVolume()
    #endif
    @State private var drag = PictureDrag.idle
    private var isDragging: Bool { drag != .idle }
    /// The accumulated timeline fraction of a sideways drag; nil while no drag seeks.
    private var seekSwipeFraction: Double? {
        if case .seeking(let fraction, _) = drag { return fraction }
        return nil
    }
    /// A pinch is under way. A drag that is part of one neither seeks nor sets a level.
    @GestureState private var isPinching = false
    /// Resets when the drag ends or when the system takes the touch, which skips the drag's `onEnded`.
    @GestureState private var isDragGestureActive = false
    /// Ignore release taps from a pinch or swipe, including when one finger lifts before the other.
    @State private var pictureGestureEndedAt: Date?
    /// When the last hold ended: the tap its release makes does not toggle the controls.
    @State private var holdEndedAt: Date?
    /// The press-and-hold on the picture (`PictureHoldGesture`). Kept out of state: following the finger must not redraw the player.
    @State private var holdTrack = PictureHoldTrack()
    @State private var holdProgress = HoldDragProgress()
    @State private var nativeFrameEngineID: ObjectIdentifier?
    @State private var nextEpisode = NextEpisodeState.notStarted
    @State private var nextPrompt = UpNextPrompt.hidden
    /// The running countdown of `nextPrompt`, called off with `stopCountdown`.
    @State private var upNextCountdown: Task<Void, Never>?
    /// How far Next Episode's countdown has run, 0...1; nil while the button is not up.
    private var upNextProgress: Double? {
        if case .counting(let progress) = nextPrompt { return progress }
        return nil
    }
    /// A stall has lasted half a second (`stallSpinnerDelay`): only then does a spinner show, so a momentary wait never flashes one.
    @State private var showsStall = false
    /// Some engines still report 'playing' while their clock has stopped: monitor progress as a fallback.
    @State private var lastPlaybackPosition: TimeInterval?
    @State private var playbackAdvancedAt: Date?
    @State private var playbackClockStalled = false
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
        _infoModel = State(initialValue: PlayerInfoModel(request: plan.request, services: services))
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
            #if os(iOS) && !targetEnvironment(macCatalyst)
            SystemVolumeControl(volume: systemVolume)
                .frame(width: 150, height: 32)
                .opacity(0.001)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            #endif
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
                if showsStandaloneSpinner {
                    spinner.accessibilityIdentifier("player.buffering").transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: showsStandaloneSpinner)
            .allowsHitTesting(false)
            gestureLayer
            // With a menu or the episodes open, a tap anywhere but them and the controls closes them.
            ZStack {
                if (panel != nil || showsEpisodes || showsStreams) && model.failureMessage == nil {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .contentShape(.rect)
                        .onTapGesture { closeMenus() }
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: panel != nil || showsEpisodes || showsStreams)
            // Retain the controls (and native scrubber) while hidden. Their local
            // fade cannot change the video viewport or animate the renderer.
            PlayerControls(model: model, infoModel: infoModel, onClose: close, onNextEpisode: playNextEpisode, pipToggle: pipToggle, pipAvailable: pipAvailable,
                           onShowEpisodes: toggleEpisodes, episodesOpen: showsEpisodes,
                           panel: panelBinding, actions: controlActions, upscaling: upscalingRenderer,
                           onShowStreams: { guard !model.plan.isOffline else { return }; closeMenus(); model.showControls(); popOut = .streams },
                           streamsOpen: showsStreams, isVideoReady: isVideoReady, isStalled: showsStall && waitingForPlayback)
                .opacity(controlsAreVisible ? 1 : 0)
                .allowsHitTesting(controlsAreVisible)
                .accessibilityHidden(!controlsAreVisible)
                .disabled(!controlsAreVisible)
                .animation(controlsAreVisible ? nil : .easeInOut(duration: 0.18), value: controlsAreVisible)
            episodePanel
            streamPanel
            ZStack {
                if let progress = upNextProgress, model.failureMessage == nil {
                    upNextPrompt(progress: progress)
                } else if let marker = model.activeSkipMarker, marker != hiddenSkipMarker,
                          model.failureMessage == nil, isVideoReady {
                    skipButton(marker)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: upNextProgress != nil)
            if let swipeLevel { SwipeLevelIndicator(level: swipeLevel) }
            ZStack {
                if let fraction = seekSwipeFraction {
                    VStack {
                        Text(PlayerTime.format(fraction * (model.duration ?? 0)))
                            .monospacedDigit()
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .glassEffect(.regular, in: ScaledCapsule(scale: metrics.cornerScale(for: .playerControls)))
                            .padding(.top, 16)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .accessibilityLabel("Seek position")
                    .accessibilityValue(PlayerTime.format(fraction * (model.duration ?? 0)))
                    .accessibilityIdentifier("player.seekPosition")
                } else if model.heldSpeed != nil { PlayerHoldBadge(model: model, progress: holdProgress).transition(.opacity) }
            }
            .animation(.easeInOut(duration: 0.15), value: model.heldSpeed != nil)
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
                    .background(.ultraThinMaterial, in: ScaledCapsule(scale: metrics.cornerScale(for: .playerControls)))
                    .overlay(ScaledCapsule(scale: metrics.cornerScale(for: .playerControls)).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
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
        .onChange(of: panel) { old, new in
            if new != .info { infoModel.closeReviews() }
            // A closed menu leaves the controls up, with a fresh idle delay, whichever way it was closed.
            if old != nil && new == nil { model.showControls() }
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
        .task(id: infoModel.ratingsRevision) {
            await infoModel.load()
            guard !Task.isCancelled, infoModel.openedReviews == nil,
                  let item = infoModel.reviewItem, let url = infoModel.imdbReviewsURL else { return }
            ReviewPreloader.shared.preload(site: .imdb, url: url, item: item, width: 360)
        }
        .task(id: waitingForPlayback) {
            guard waitingForPlayback else {
                showsStall = false
                return
            }
            try? await Task.sleep(for: Self.stallSpinnerDelay)
            if !Task.isCancelled { showsStall = true }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                refreshPlaybackClock()
                if panel == nil { model.hideControlsIfIdle() }
                await model.skipAutomaticallyIfNeeded()
                await model.recordSessionSnapshot()
                updateUpNext()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the front keeps the session on the air, but its snapshot should already say where it is if the app is killed.
            if phase != .active { Task { await model.recordSessionSnapshot(force: true) } }
            // A hold, locked or not, must not carry on in the background or through a lock: the speed comes back now.
            if phase != .active {
                endPictureHold()
                model.endHeldSpeed()
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
        // Timeline and picture swipes share feedback, including one step per ten seconds crossed.
        .onChange(of: model.isScrubbing) { _, scrubbing in
            Haptics.play(.playerGestures)
        }
        .onChange(of: Int(model.position / 10)) { _, _ in
            if model.isScrubbing { Haptics.play(.playerGestures) }
        }
        .onChange(of: model.heldSpeed) { old, new in
            if let old, let new, old.rate != new.rate { Haptics.play(.playerOptions) }
            if old != nil, new == nil { endPictureHold() }
        }
        .onAppear {
            // The screen is up: its session is the app's live one. A session the screen itself handed over and rebuilt (Up Next) sits
            // in `prepared`, so what presents here is already this plan's player.
            livePlayback.present(model)
        }
        .onDisappear {
            if let url = infoModel.imdbReviewsURL { ReviewPreloader.shared.discard(url: url) }
            endPictureHold()
            leaveUpNext()
            // An actual dismissal releases the session (a closed one forgets itself idempotently). A disappearance that comes with
            // the app leaving the front — backgrounding, a lock — does not: the session stays on the air at the app level, and this
            // screen or a rebuilt one reattaches to it when it comes back.
            if LivePlaybackSession.closesOnDisappear(scenePhase: scenePhase) {
                Task {
                    await model.close()
                    livePlayback.forget(model)
                    // A dismissal sets the session aside; a hand-over has already saved the next one.
                    if departure != .handedOver { await PlaybackSession.clear() }
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

    private var streamPanel: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                if showsStreams && model.failureMessage == nil {
                    PlayerStreamPicker(candidates: model.plan.candidates, currentIndex: model.currentStreamIndex,
                                       onSelect: { index in
                                           closeMenus()
                                           Task { await model.selectStream(at: index) }
                                       }, onClose: closeMenus)
                        .frame(width: min(Self.episodePanelWidth, max(0, proxy.size.width - 40)))
                        .frame(height: min(Self.episodePanelHeight, max(0, proxy.size.height - Self.episodePanelTop - 12)))
                        .padding(.top, Self.episodePanelTop)
                        .padding(.trailing, 20)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .topTrailing)))
                }
            }
            #if targetEnvironment(macCatalyst)
            .frame(maxWidth: 900, maxHeight: .infinity, alignment: .topTrailing)
            #endif
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topTrailing)
        }
        .animation(.snappy(duration: 0.24), value: showsStreams)
    }

    private static let episodePanelWidth: CGFloat = 360
    private static let episodePanelHeight: CGFloat = 560
    /// Below the top bar: its 12 pt margin, the 44 pt buttons and a small gap.
    private static let episodePanelTop: CGFloat = 12 + 44 + 8

    private func toggleEpisodes() {
        guard !model.plan.isOffline else { return }
        if showsEpisodes {
            closeEpisodes()
        } else {
            popOut = .episodes
        }
    }

    private func closeEpisodes() {
        guard showsEpisodes else { return }
        popOut = .closed
        model.showControls()
    }

    private func closeMenus() {
        popOut = .closed
        model.showControls()
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

    /// A single buffering indication: in the play button when controls are up, otherwise over the video.
    private var waitingForPlayback: Bool { model.isStalled || playbackClockStalled }

    private var showsStandaloneSpinner: Bool {
        showsStall && waitingForPlayback && isVideoReady &&
            (!controlsAreVisible || panel != nil || showsEpisodes || showsStreams || !model.hasStartedPlayback)
    }

    /// Detect an engine whose status stays at 'playing' even though its clock has stopped.
    /// Reset on pauses, seeks, backgrounding and the end of a title; never mistake those for buffering.
    private func refreshPlaybackClock() {
        let state = model.state
        guard model.wantsPlayback, state.isPlaying, isVideoReady, model.failureMessage == nil,
              !model.hasFinished, !model.isScrubbing, seekSwipeFraction == nil, !isPinching,
              scenePhase == .active, state.position.isFinite,
              !(state.duration.map { $0.isFinite && $0 - state.position < 1 } ?? false) else {
            lastPlaybackPosition = nil
            playbackAdvancedAt = nil
            playbackClockStalled = false
            return
        }
        let now = Date()
        if let lastPlaybackPosition, abs(state.position - lastPlaybackPosition) < 0.05 {
            if let playbackAdvancedAt, now.timeIntervalSince(playbackAdvancedAt) >= 1.5 {
                playbackClockStalled = true
            }
        } else {
            playbackAdvancedAt = now
            playbackClockStalled = false
        }
        lastPlaybackPosition = state.position
    }

    /// How long a stall lasts before a spinner shows.
    static let stallSpinnerDelay = Duration.milliseconds(500)

    /// The player's spinner, at start-up and for a stall.
    private var spinner: some View {
        Spinner().controlSize(.large)
            .frame(width: 64, height: 64).glassEffect(.regular, in: ScaledCapsule(scale: metrics.circularButtonScale(for: .playerControls)))
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
        if showsStreams {
            closeMenus()
        } else if showsEpisodes {
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
                             searchOpenSubtitles: { if !model.plan.isOffline { showsOpenSubtitles = true } }, toggleAmbient: { model.toggleAmbientMode() })
    }

    private func skipButton(_ marker: SkipMarker) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    Haptics.play(.playerControls)
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
                        .buttonSurface(.regular.interactive(), in: ScaledCapsule(scale: metrics.cornerScale(for: .playerControls)))
                        .pointerInteraction(cornerRadius: 22 * metrics.cornerScale(for: .playerControls))
                }
                .buttonStyle(.hoverPlain)
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
                      hdrBrightness: model.processing.hdrBrightness,
                      embeddedSubtitlesOn: { if case .embedded = model.subtitleChoice { return true } else { return false } }(),
                      ambientMode: model.preferences.ambientMode, superResolution: superResolution, sampler: picture,
                      pictureReady: isVideoReady, paused: !model.isPlaying,
                      onFirstVideoFrame: {
                          guard let engine, model.coordinator?.engine === engine else { return }
                          (engine as? AVEngine)?.markVideoFrameReady()
                          nativeFrameEngineID = ObjectIdentifier(engine)
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
        !holdTrack.ownsTouch && !isPinching && !isDragGestureActive && !isDragging
            && (pictureGestureEndedAt.map { Date().timeIntervalSince($0) >= 0.25 } ?? true)
    }

    /// Tap toggles the controls; double-tap on the left or right third skips back or forward 10 s; press and hold plays at double speed
    /// until the finger lifts (the Mac: click and hold). While held, dragging up steps the speed 1× per 40 points, to 4× where the
    /// engine allows it, and dragging down 40 points locks the hold at its speed, which stays after the finger lifts until a hold dragged
    /// down returns the film to the speed before (`SpeedHoldRules`). A hold owns the finger: nothing else acts on its movement until it lifts. On iPhone and iPad a sideways drag anywhere on the picture seeks live,
    /// coarsely at the top and finely at the bottom (`SwipeSeek`); a vertical swipe on the left third sets the brightness
    /// (Settings can turn it off), a swipe down in the middle closes, and a pinch zooms. a vertical swipe on the right third sets system volume.
    /// The layer covers the whole screen, edges included, under the controls: a drag that starts on a control (the timeline, the menu
    /// bar, a button) stays that control's own, so the system slider and segmented control keep their native touch handling.
    private var gestureLayer: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .gesture(PictureTapGesture { location, tapCount in
                    guard acceptsPictureTap else { return }
                    if tapCount == 1 {
                        // The release that ends a hold (or a press that rested as one) is not a tap. A lock does not swallow taps.
                        if model.heldSpeed?.isLocked == false || holdTrack.restedLong || holdEndedAt.map({ Date().timeIntervalSince($0) < 0.5 }) == true { return }
                        model.toggleControls()
                    } else if tapCount == 2 {
                        Haptics.play(.playerControls)
                        // Settings → Player can turn the skips off: the whole picture then plays and pauses, as its middle does.
                        let third = proxy.size.width / 3
                        if model.preferences.doubleTapSkips && location.x < third {
                            Task { await model.skipBack() }
                        } else if model.preferences.doubleTapSkips && location.x > 2 * third {
                            Task { await model.skipForward() }
                        } else {
                            model.togglePlayPause()
                        }
                    }
                })
                // The UIKit delegate lets both recognizers track the finger. Ownership lasts through the final swipe callback.
                .gesture(PictureHoldGesture(minimumDuration: SpeedHoldRules.holdDelay,
                                                        touchBegan: {
                                                            endPictureHold()
                                                            holdTrack.ownsTouch = false
                                                        },
                                                        began: { pictureHoldBegan($0) },
                                                        moved: { pictureHoldMoved($0) },
                                                        ended: {
                                                            if holdTrack.hold != nil { Haptics.play(.playerGestures) }
                                                            endPictureHold()
                                                        }))
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
                        // A hold owns the picture while it lasts: a pinch during it changes no zoom.
                        guard !holdTrack.ownsTouch else { return }
                        let previousZoom = model.zoomMode
                        // A shortcut for the saved Zoom Mode: pinch out for Fill, pinch in for Normal.
                        if value.magnification > 1.08 {
                            model.pinchZoom(in: true)
                        } else if value.magnification < 0.92 {
                            model.pinchZoom(in: false)
                        }
                        if model.zoomMode != previousZoom { Haptics.play(.playerOptions) }
                    })
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: Press and hold

    /// The press rested for `SpeedHoldRules.holdDelay`. It is a hold if the film is playing and no menu is open; otherwise it keeps its
    /// ordinary handling, so a drag from a paused film still seeks. Either way it is no tap when it lifts.
    private func pictureHoldBegan(_ point: CGPoint) {
        holdTrack.restedLong = true
        guard panel == nil, !showsEpisodes, !showsStreams, !isDragging, !isPinching else { return }
        let locked = model.heldSpeed?.isLocked == true
        // A press on a locked hold starts no hold of its own: dragged down, it releases the lock (`pictureHoldMoved`).
        guard locked || model.beginHeldSpeed() else { return }
        holdTrack.ownsTouch = true
        holdTrack.hold = (baselineY: point.y, unlocking: locked)
        // Confirms the hold has taken. A hold the film cannot take stays silent.
        if !locked { Haptics.play(.playerControls) }
    }

    /// The held finger moved: its height from where the hold began steps the speed up, and a drag down far enough locks it
    /// (`SpeedHoldRules`). Nothing else reads the movement.
    private func pictureHoldMoved(_ point: CGPoint) {
        guard let hold = holdTrack.hold else { return }
        let displacement = Double(point.y - hold.baselineY)
        if hold.unlocking {
            // A drag down from a locked hold's press returns the film to the speed it was at: the lock is released.
            guard SpeedHoldRules.unlocks(displacement: displacement) else {
                holdProgress.update(SpeedHoldRules.unlockProgress(displacement: displacement))
                return
            }
            holdTrack.hold?.unlocking = false
            holdProgress.update(0)
            model.endHeldSpeed()
            Haptics.play(.playerGestures)
            return
        }
        guard let held = model.heldSpeed, !held.isLocked else { return }
        if SpeedHoldRules.locks(displacement: displacement, at: held.rate) {
            holdProgress.update(0)
            model.lockHeldSpeed()
            Haptics.play(.playerControls)
            return
        }
        holdProgress.update(SpeedHoldRules.lockProgress(displacement: displacement, at: held.rate))
        model.setHeldSpeed(SpeedHoldRules.rate(displacement: displacement, maximum: model.heldSpeedMaximum, current: held.rate))
    }

    /// The press ended: it lifted, the system took it, or it moved too far before the hold began. A hold returns the film to the speed it
    /// was at, unless it is locked: a locked hold stays until a hold dragged down, a pause, or the film ending returns it. Idempotent, so
    /// leaving the app, the screen going and the film ending may call it too.
    private func endPictureHold() {
        holdProgress.update(0)
        if holdTrack.hold != nil {
            holdTrack.hold = nil
            pictureGestureEndedAt = Date()
            if model.heldSpeed?.isLocked != true { model.endHeldSpeed() }
        }
        if holdTrack.restedLong {
            holdTrack.restedLong = false
            holdEndedAt = Date()
        }
    }

    // Picture drag seeking is intentionally touch-only; Mac keeps its timeline and keyboard controls, as requested.
    #if !targetEnvironment(macCatalyst)
    /// A sideways swipe seeks once the film plays on screen and has a length, with no panel open.
    private var canSwipeSeek: Bool {
        model.hasStartedPlayback && isVideoReady && (model.duration ?? 0) > 0 && model.failureMessage == nil && panel == nil
    }

    private func swipeChanged(_ value: DragGesture.Value, in size: CGSize) {
        // An open menu owns its own scrolling.
        guard panel == nil, !showsEpisodes, !showsStreams else { return }
        // A hold owns its finger: a drag that follows it neither seeks nor sets a level.
        guard !holdTrack.ownsTouch else { return }
        if drag == .idle { drag = isPinching ? .pinch : .undecided }
        if drag == .pinch { return }
        if drag == .undecided {
            // Wait for a clear axis instead of permanently classifying a slightly
            // diagonal first movement as vertical. The user's starting point can
            // be anywhere, even over the visible transport controls.
            let dx = abs(value.translation.width)
            let dy = abs(value.translation.height)
            if dx >= 14 && dx > dy * 1.2 {
                drag = canSwipeSeek ? seekSwipe(from: 0) : .horizontal
            } else if dy >= 14 && dy > dx * 1.2 {
                drag = .vertical
            } else {
                return
            }
        }
        // A centre swipe may start upwards, then turn sideways to seek.
        // Side-origin vertical drags remain brightness/volume gestures.
        let third = size.width / 3
        if drag == .vertical,
           value.startLocation.x >= third, value.startLocation.x <= 2 * third,
           value.translation.height < 0, abs(value.translation.width) >= 14, canSwipeSeek {
            drag = seekSwipe(from: value.translation.width)
        }
        if case .seeking(let start, let translation) = drag {
            let fraction = SwipeSeek.fraction(from: start, translation: value.translation.width - translation,
                                              width: size.width, duration: model.duration ?? 0,
                                              heightFraction: value.location.y / max(1, size.height))
            drag = .seeking(fraction: fraction, translation: value.translation.width)
            guard fraction != start else { return }
            model.updateScrub(fraction: fraction, seekImmediately: true)
            return
        }
        guard model.preferences.swipeGestures else { return }
        if drag == .vertical {
            // Up or down on the left: brightness; on the right: device volume.
            guard abs(value.translation.height) > abs(value.translation.width) * 1.5 else { return }
            if value.startLocation.x < third {
                drag = .level(kind: .brightness, start: Double(ScreenBrightness.value))
            } else if value.startLocation.x > 2 * third {
                #if os(iOS) && !targetEnvironment(macCatalyst)
                drag = .level(kind: .volume, start: systemVolume.value)
                #else
                drag = .level(kind: .volume, start: Double(model.volume))
                #endif
            } else {
                return
            }
        }
        guard case .level(let kind, let startValue) = drag else { return }
        let start = (kind: kind, value: startValue)
        let level = min(1, max(0, start.value - value.translation.height / (size.height * 0.7)))
        switch start.kind {
        case .brightness: ScreenBrightness.value = CGFloat(level)
        case .volume:
            #if os(iOS) && !targetEnvironment(macCatalyst)
            systemVolume.value = level
            #else
            model.setVolume(Float(level))
            #endif
        }
        // A step at each 10% boundary, rather than a buzz on every finger movement.
        if Int((swipeLevel?.value ?? start.value) * 10) != Int(level * 10) {
            Haptics.play(.playerGestures)
        }
        swipeLevel = SwipeLevel(kind: start.kind, value: level)
    }

    private func swipeEnded(_ value: DragGesture.Value, in size: CGSize) {
        pictureGestureEndedAt = Date()
        guard !holdTrack.ownsTouch else { dragFinished(); return }
        guard panel == nil, !showsEpisodes, !showsStreams else { return }
        // Use the existing seek state to include the final movement before clearing the gesture.
        if seekSwipeFraction != nil { swipeChanged(value, in: size) }
        let ended = drag
        drag = .idle
        // Only a drag that classified as a swipe can dismiss: a release after a hold (which never classified) must not close the player.
        let wasSwiping: Bool
        let wasLevel: Bool
        switch ended {
        case .seeking:
            // Finish at the live drag's final target.
            Task { await model.endScrub() }
            return
        case .pinch:
            return
        case .idle, .undecided:
            wasSwiping = false
            wasLevel = false
        case .horizontal, .vertical:
            wasSwiping = true
            wasLevel = false
        case .level:
            wasSwiping = true
            wasLevel = true
        }
        withAnimation(.easeOut(duration: 0.3).delay(0.4)) { swipeLevel = nil }
        let third = size.width / 3
        let inMiddle = value.startLocation.x >= third && value.startLocation.x <= 2 * third
        if wasSwiping, !wasLevel, value.translation.height > 140, inMiddle || !model.preferences.swipeGestures {
            Haptics.play(.playerControls)
            close()
        }
    }

    /// A pinch takes over a drag: keep the last live position and stop issuing seeks.
    private func pinchBegan() {
        switch drag {
        case .idle, .pinch: return
        case .seeking: model.cancelScrub()
        // The level it was setting stays where it is, and its indicator fades.
        case .level: withAnimation(.easeOut(duration: 0.3).delay(0.4)) { swipeLevel = nil }
        case .undecided, .horizontal, .vertical: break
        }
        drag = .pinch
    }

    /// A sideways drag starts seeking from where playback is now.
    private func seekSwipe(from translation: Double) -> PictureDrag {
        let startingFraction = model.fraction
        model.beginScrub()
        return .seeking(fraction: startingFraction, translation: translation)
    }

    /// The drag is over, ended or cancelled (the system can take the touch and skip `onEnded`). After a normal end there is nothing left
    /// to do. Otherwise a seek still open is made where the swipe left the timeline, whichever of the two runs first, and a level indicator
    /// fades, so the next drag starts clean.
    private func dragFinished() {
        switch drag {
        case .seeking: Task { await model.endScrub() }
        case .level: withAnimation(.easeOut(duration: 0.3).delay(0.4)) { swipeLevel = nil }
        case .idle, .undecided, .pinch, .horizontal, .vertical: break
        }
        drag = .idle
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
        guard departure == .staying else { return }
        departure = .movingOn
        stopCountdown()
        Task {
            await model.close()
            livePlayback.forget(model)
            // A readying under way finishes first: it is the quicker start.
            if case .readying(let task) = nextEpisode { await task.value }
            departure = .handedOver
            if case .ready(let ready) = nextEpisode {
                nextEpisode = .handedOver
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
        if showsEpisodes { popOut = .closed }
        departure = .handedOver
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
        guard model.hasNextEpisode, model.failureMessage == nil, departure == .staying else { return }
        let creditsToEnd = model.activeSkipMarker.map { $0.kind == .credits && model.skipEndsMedia($0) } ?? false
        let nearEnd = UpNextTiming.isNearEnd(position: model.state.position, duration: model.duration, creditsToEnd: creditsToEnd)
        if !nearEnd && !(model.duration.map { $0 > 0 && $0 - model.state.position <= 45 } ?? false), nextPrompt == .creditsChosen {
            nextPrompt = .hidden
        }
        if nearEnd, case .notStarted = nextEpisode { readyNextEpisode() }
        let inLast45Seconds = model.duration.map { $0.isFinite && $0 > 0 && $0 - model.state.position <= 45 } ?? false
        // Show the action even if preload is slow; keep it up once its countdown starts.
        let isReady = if case .ready = nextEpisode { true } else { false }
        let isCounting = upNextProgress != nil
        let shows = (nearEnd || inLast45Seconds) &&
            (isReady || inLast45Seconds || isCounting) && nextPrompt != .creditsChosen
        if shows && !isCounting {
            startCountdown()
        } else if !shows && isCounting {
            stopCountdown()
        }
    }

    /// The next episode's stream, chosen as the end of an episode chooses it, starts muted and holds on its first frame.
    private func readyNextEpisode() {
        let task = Task {
            guard let plan = await model.prepareNextEpisode(), !Task.isCancelled else {
                if case .readying = nextEpisode { nextEpisode = .unavailable }
                return
            }
            let next = Self.makeModel(plan: plan, services: services)
            PlayerPreload.begin(plan, services: services)
            await next.prepare()
            guard !Task.isCancelled, case .readying = nextEpisode, next.coordinator?.phase == .playing else {
                await next.close()   // nothing to play in it, or this screen has gone
                if case .readying = nextEpisode { nextEpisode = .unavailable }
                return
            }
            nextEpisode = .ready(UpNextEpisode(plan: plan, model: next))
        }
        nextEpisode = .readying(task)
    }

    /// Counts eight seconds of playback (a pause holds the count), then plays the next episode.
    private func startCountdown() {
        nextPrompt = .counting(0)
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
                nextPrompt = .counting(min(1, elapsed / UpNextTiming.countdown))
            }
            playNextEpisode()
        }
    }

    private func stopCountdown() {
        upNextCountdown?.cancel()
        upNextCountdown = nil
        if case .counting = nextPrompt { nextPrompt = .hidden }
    }

    /// This screen is going: a readied next episode it did not hand on is closed, so its stream stops.
    private func leaveUpNext() {
        stopCountdown()
        switch nextEpisode {
        case .readying(let task):
            task.cancel()
            nextEpisode = .unavailable
        case .ready(let next):
            nextEpisode = .unavailable
            Task { await next.model.close() }
        case .notStarted, .unavailable, .handedOver:
            break
        }
    }

    /// Netflix's choice at the end of an episode, in the player's glass: Watch Credits, and Next Episode filling as its eight seconds run.
    private func upNextPrompt(progress: Double) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Spacer()
                Button {
                    Haptics.play(.playerControls)
                    stopCountdown()
                    nextPrompt = .creditsChosen
                } label: {
                    Text("Watch Credits")
                        .font(.headline)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .buttonSurface(.regular.interactive(), in: ScaledCapsule(scale: metrics.cornerScale(for: .playerControls)))
                        .pointerInteraction(cornerRadius: 22 * metrics.cornerScale(for: .playerControls))
                }
                .buttonStyle(.hoverPlain)
                .accessibilityIdentifier("player.upNext.credits")
                Button {
                    Haptics.play(.playerControls)
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
                        .clipShape(ScaledCapsule(scale: metrics.cornerScale(for: .playerControls)))
                        .buttonSurface(.regular.interactive(), in: ScaledCapsule(scale: metrics.cornerScale(for: .playerControls)))
                        .pointerInteraction(cornerRadius: 22 * metrics.cornerScale(for: .playerControls))
                }
                .buttonStyle(.hoverPlain)
                .keyboardShortcut("n", modifiers: [])
                .accessibilityIdentifier("player.upNext.play")
                .accessibilityValue("Plays in \(Int((8 * (1 - progress)).rounded(.up))) seconds")
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
        guard !plan.isOffline, let first = plan.candidates.first, begun.insert(plan.id).inserted else { return }
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
                // A return from the background finds the last one kept: its lock-screen commands are removed before new ones are added.
                nowPlaying?.tearDown()
                nowPlaying = NowPlayingController(title: model.plan.request.title, actions: .init(
                    play: { model.coordinator?.play() },
                    pause: { model.coordinator?.pause() },
                    toggle: { model.togglePlayPause() },
                    skip: { seconds in Task { await model.skip(by: seconds) } },
                    seek: { position in Task { await model.coordinator?.seek(to: position) } }))
                nowPlaying?.setSkipIntervals(backward: model.skipBackSeconds, forward: model.skipForwardSeconds)
            }
            .onChange(of: model.state) { _, state in nowPlaying?.update(state) }
            // The settings load after the screen appears: the lock screen takes the player's skip amounts when they arrive.
            .onChange(of: model.skipBackSeconds + 1000 * model.skipForwardSeconds) { _, _ in
                nowPlaying?.setSkipIntervals(backward: model.skipBackSeconds, forward: model.skipForwardSeconds)
            }
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
            Button("Back \(Int(model.skipBackSeconds)) seconds") { Task { await model.skipBack() } }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Forward \(Int(model.skipForwardSeconds)) seconds") { Task { await model.skipForward() } }
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
    @Environment(\.layoutMetrics) private var metrics
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
        .glassEffect(.regular, in: .rect(cornerRadius: 28 * metrics.cornerScale(for: .playerControls)))
        .padding(24)
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.failure")
    }
}
#endif
