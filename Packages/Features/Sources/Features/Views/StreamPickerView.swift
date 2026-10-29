#if canImport(UIKit)
import Persistence
import StremioKit
import SwiftUI
import UIKit

/// One title's streams. The header says what is being picked. The best stream is
/// the one main action, and each addon's streams follow as rows of their own. Links to web pages come last. A stream plays in Blusion or,
/// when the viewer chose that player, opens in another app.
struct StreamPickerView: View {
    @State private var model: StreamPickerViewModel
    @State private var plan: PlaybackPlan?
    @State private var expandedDetails: RankedStream?
    @State private var isNotesExpanded = false
    @State private var autoPickTask: Task<Void, Never>?
    @State private var hasSelectedManually = false
    @State private var isOpeningPlayer = false
    /// The player readied for a stream before its screen opens (see `PlayerViewModel.prepare`), and which stream it is for. The first
    /// stream listed starts loading here in the background as soon as it arrives, so playing it is quick; another stream tapped
    /// replaces it.
    @State private var prepared: PlayerViewModel?
    @State private var preparedItemID: RankedStream.ID?
    /// The stream whose play button is a spinner: Blusion is readying it, and its player opens once the film is ready to play.
    @State private var preparingItemID: RankedStream.ID?
    /// True while the stream Auto Pick chose is being readied, so Auto Pick's button spins until the player opens.
    @State private var preparingViaAutoPick = false
    /// The ready player the open player screen took over.
    @State private var presentedPlayer: PlayerViewModel?
    /// The first stream's background load has been started, once per picker.
    @State private var hasStartedBackgroundLoad = false
    /// The Auto Pick button's height and the switch's own size, as laid out: the switch is scaled to the button's height.
    @State private var autoPickButtonHeight: CGFloat = 0
    /// The Auto Pick height last measured by any picker, for a picker that has not measured its own yet (see `episodeStepButton`).
    private static var lastAutoPickHeight: CGFloat?
    /// Keep the last recommendation text and collapsed card heights while the next picker loads.
    private static var lastAutoPickInfo: String?
    private static var lastStreamCardHeights: [Int: CGFloat] = [:]
    @State private var autoPickSwitchSize: CGSize = .zero
    /// The heading's natural size, so its title, rating and logo can shrink together between the fixed chevrons.
    /// The sharpness the chips narrow the list to; nil shows every stream.
    @State private var resolutionFilter: Band?
    /// Keep the last visible resolution bar while the next picker's streams load.
    private static var lastResolutionBands: [Band] = [.uhd, .fullHD, .hd]
    /// The one addon whose streams are listed, or nil for every addon's.
    @State private var addonFilter: UUID?
    /// A stream whose format Blusion can't play: the alert offers another player, or the next stream.
    @State private var unsupported: RankedStream?
    /// A hand-off whose player app is not installed: the alert offers its App Store page, or playing the stream in Blusion.
    @State private var missing: MissingPlayer?
    /// The streams saved to another player's library from this picker, whose bookmarks are filled.
    @State private var savedStreams: Set<RankedStream.ID> = []
    @State private var pendingSaves: [String: RankedStream.ID] = [:]
    #if targetEnvironment(macCatalyst)
    /// The Mac cards whose technical details are open.
    @State private var openDetails: Set<RankedStream.ID> = []
    #endif
    /// True when ghost mode stopped a stream that only opens in another app.
    @State private var ghostBlocked = false
    /// The stream cards that have already come in, so a card scrolled away and back does not animate again.
    @State private var entranceLog = StreamCardEntranceLog()
    private let services: AppServices
    /// True when the title page shows these streams in place of its details: no scroll view, backdrop, title or header of its own, since
    /// the page above it has them.
    private let isEmbedded: Bool
    /// The episode's score, shown right after its season and episode in the heading, with the IMDb mark as its card has it. Nil for a
    /// film, or while the score is not known.
    private let episodeScore: DetailViewModel.EpisodeScore?
    /// Embedded on a series' page: the episodes before and after this one, which the header's switcher steps to. Nil keeps the heading text.
    private let episodeSwitcher: EpisodeSwitcher?
    /// The title page's tint, shared by Play and the episode arrows.
    private let playColourHex: String?
    /// False draws nothing yet: the picker is on the page and loading, and the page shows it once `onReady` has been called.
    private let isRevealed: Bool
    /// Embedded only: takes the streams away and shows the title's details again, as Escape does on Mac. Back leaves the title's page, so
    /// it is not a way back to the details.
    private let onClose: (() -> Void)?
    /// Called once every addon has answered, with whether any actual stream cards can be shown.
    private let onReady: ((Bool) -> Void)?
    /// Embedded on Mac: scrolls the title page to a row the keyboard is on. The page's scroll view holds the rows, not the picker.
    private let scrollToRow: ((AnyHashable) -> Void)?
    /// True for a picker that is never shown: Home's Continue Watching starts a card's stream through one.
    private let isHeadless: Bool
    /// Told once the automatic start on opening (Auto Pick's switch on) has started a stream (true), or has nothing to start (false).
    private let onAutomaticStart: ((Bool) -> Void)?
    /// True for a picker that starts the best stream on opening whatever Auto Pick's switch says: a poster held to play it.
    private let forcesAutomaticStart: Bool
    /// Recovery shows the choices without immediately retrying the stream that just failed.
    private let allowsAutomaticStart: Bool
    /// True from the moment the streams open with Auto Pick's switch on until it has had nothing to start. Meanwhile `onReady` waits, so
    /// a title's page keeps its details and its spinner instead of showing the list; once a stream has started it is never called.
    @State private var awaitsAutomaticStart = false
    @Environment(\.openURL) private var openURL
    @Environment(AppRouter.self) private var router
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.isLandscape) private var isLandscape
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape
    #if targetEnvironment(macCatalyst)
    /// Closes a pushed picker, for Escape: the same as its back button.
    @Environment(\.dismiss) private var dismiss
    /// The row the arrow keys are on. Nil until the list takes the keyboard.
    @State private var keyboardRow: KeyboardRow?
    /// The list holds the keyboard from the moment it shows, so the arrow keys work without a click first.
    @FocusState private var listHasFocus: Bool
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// `isPhoneLandscape` is also true on an iPad turned sideways, so the device is checked as well.
    private var isPhoneInLandscapeOnPhone: Bool { isPhoneLandscape && UIDevice.current.userInterfaceIdiom == .phone }
    /// A slight inset from each edge. The screens' page margin is zero, so the stream rows would otherwise run to the screen's edge.
    private var streamMargin: CGFloat { Theme.Spacing.l }

    init(request: StreamRequest, services: AppServices, isEmbedded: Bool = false, isRevealed: Bool = true, onClose: (() -> Void)? = nil,
         onReady: ((Bool) -> Void)? = nil, scrollToRow: ((AnyHashable) -> Void)? = nil, episodeScore: DetailViewModel.EpisodeScore? = nil,
         episodeSwitcher: EpisodeSwitcher? = nil, isHeadless: Bool = false, forcesAutomaticStart: Bool = false,
         onAutomaticStart: ((Bool) -> Void)? = nil, playColourHex: String? = nil, allowsAutomaticStart: Bool = true) {
        self.episodeScore = episodeScore
        self.episodeSwitcher = episodeSwitcher
        self.playColourHex = playColourHex
        self.isHeadless = isHeadless
        self.forcesAutomaticStart = forcesAutomaticStart
        self.allowsAutomaticStart = allowsAutomaticStart
        self.onAutomaticStart = onAutomaticStart
        self.services = services
        self.isEmbedded = isEmbedded
        self.isRevealed = isRevealed
        self.onClose = onClose
        self.onReady = onReady
        self.scrollToRow = scrollToRow
        _model = State(initialValue: StreamPickerViewModel(request: request, services: services))
    }

    var body: some View {
        if isEmbedded {
            behaviour(list(scrollTo: scrollToRow).accessibilityIdentifier("streams.list"))
        } else {
            #if targetEnvironment(macCatalyst)
            // The reader wraps the picker's own scroll view, which holds the rows, so the keyboard can scroll them.
            ScrollViewReader { proxy in
                behaviour(page(scrollTo: { proxy.scrollTo($0, anchor: .center) }))
            }
            #else
            behaviour(page(scrollTo: nil))
            #endif
        }
    }

    /// The pushed picker's page: its own scroll view, with the list in it.
    private func page(scrollTo: ((AnyHashable) -> Void)?) -> some View {
        ScrollView {
            list(scrollTo: scrollTo)
        }
        // The last card scrolls clear of the tab bar and the mini player: the scroll content's bottom margin, not padding
        // inside it.
        .contentMargins(.bottom, Theme.Spacing.xxl, for: .scrollContent)
        // A phone in landscape has no navigation bar here: the list starts below the glass Back drawn above Home (see `RootTabView`).
        .contentMargins(.top, isPhoneInLandscapeOnPhone ? LandscapeTabBarState.backClearance : 0, for: .scrollContent)
        .trackLandscapeTabScroll()
        // The glow is a layer of the page, not of the list: it stays put under the navigation bar while the streams scroll over it.
        .background(alignment: .top) { ambientBackdrop }
        .screenBackground()
        // The title is the header's; the navigation title stays set for VoiceOver and the screen's name, but is not drawn twice.
        .downloadErrors(services.downloads)
        .navigationTitle(model.request.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbarVisibility(isPhoneInLandscapeOnPhone ? .hidden : .automatic, for: .navigationBar)
        .accessibilityIdentifier("streams.list")
    }

    /// The list the page shows. On Mac it also takes the keyboard (see `keyboardNavigated`), unless it is a picker that is never shown;
    /// on iPhone it is the rows alone.
    @ViewBuilder
    private func list(scrollTo: ((AnyHashable) -> Void)?) -> some View {
        #if targetEnvironment(macCatalyst)
        if !isHeadless {
            keyboardNavigated(content, scrollTo: scrollTo)
        } else {
            content
        }
        #else
        content
        #endif
    }

    /// A row of the list, by the addon section it sits in and its stream. Two addons can offer the same stream, so it can appear in two
    /// sections; the stream alone would not say which row the keyboard is on.
    private struct KeyboardRow: Hashable {
        let addon: UUID
        let stream: RankedStream.ID
    }

    /// Mac: marks the row the arrow keys are on, and gives it the id the list scrolls to. iPhone: the row as it is. A card that has an
    /// edge of its own (`hasEdge`: Best match, a service or a disc) gets no ring: its edge is drawn bolder instead (see `streamButton`),
    /// so a card never has two outlines.
    @ViewBuilder
    private func keyboardMarked(_ row: some View, in addon: UUID, stream: RankedStream.ID, hasEdge: Bool) -> some View {
        #if targetEnvironment(macCatalyst)
        row
            .overlay {
                if !hasEdge, keyboardRow == KeyboardRow(addon: addon, stream: stream) {
                    RoundedRectangle(cornerRadius: StreamCardMetrics.cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.8), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .id(KeyboardRow(addon: addon, stream: stream))
        #else
        row
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// Mac: the list takes the keyboard. Down and up move a highlight through the streams and scroll it into view, Return chooses the
    /// highlighted stream, and Escape closes the picker. Left and right step to the episode before or after, as the switcher's chevrons
    /// do. Only the highlight changes, so a click works as it did.
    private func keyboardNavigated<Rows: View>(_ rows: Rows, scrollTo: ((AnyHashable) -> Void)?) -> some View {
        rows
            .focusable()
            .focused($listHasFocus)
            .focusEffectDisabled()
            // A pushed picker takes the keyboard as it shows. An embedded one waits until its streams are shown, so the title page does not
            // move while it is still an empty placeholder under Play.
            .onAppear { if !isEmbedded || isRevealed { listHasFocus = true } }
            .onChange(of: isRevealed) { _, revealed in
                if revealed { listHasFocus = true }
            }
            .onKeyPress(.downArrow) { moveKeyboardSelection(by: 1) }
            .onKeyPress(.upArrow) { moveKeyboardSelection(by: -1) }
            .onKeyPress(.return) { chooseKeyboardStream() }
            .onKeyPress(.escape) { closeFromKeyboard() }
            .onKeyPress(.leftArrow) { stepEpisodeFromKeyboard(to: episodeSwitcher?.previous) }
            .onKeyPress(.rightArrow) { stepEpisodeFromKeyboard(to: episodeSwitcher?.next) }
            .onChange(of: keyboardRow) { _, row in
                guard let row, let scrollTo else { return }
                withAnimation(.snappy(duration: 0.25)) { scrollTo(AnyHashable(row)) }
            }
    }

    /// The rows in the order the list shows them, each with its stream.
    private var keyboardOrder: [(row: KeyboardRow, stream: RankedStream)] {
        visibleSections.flatMap { section in
            section.streams.map { (KeyboardRow(addon: section.addon.id, stream: $0.id), $0) }
        }
    }

    /// Moves the highlight one row up or down, in the order the list shows them. From nothing, Down takes the first row and Up the last.
    private func moveKeyboardSelection(by step: Int) -> KeyPress.Result {
        let rows = keyboardOrder
        guard !rows.isEmpty else { return .ignored }
        let current = rows.firstIndex { $0.row == keyboardRow } ?? (step > 0 ? -1 : rows.count)
        keyboardRow = rows[min(max(current + step, 0), rows.count - 1)].row
        return .handled
    }

    /// Chooses the highlighted stream, as a tap on its row does.
    private func chooseKeyboardStream() -> KeyPress.Result {
        guard let row = keyboardRow, let item = keyboardOrder.first(where: { $0.row == row })?.stream else { return .ignored }
        select(item)
        return .handled
    }

    /// Steps to the episode before or after, as a chevron does. Ignored without a switcher, or with no episode there.
    private func stepEpisodeFromKeyboard(to request: StreamRequest?) -> KeyPress.Result {
        guard let episodeSwitcher, let request else { return .ignored }
        episodeSwitcher.step(request)
        return .handled
    }

    /// Closes the embedded picker through its own close, or a pushed picker by popping it.
    private func closeFromKeyboard() -> KeyPress.Result {
        if let onClose { onClose() } else { dismiss() }
        return .handled
    }
    #endif

    /// The picker's rows. Pushed, the first row is the picker's own header; embedded, it is the lighter header, since the page above
    /// already has the poster and the title.
    private var content: some View {
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if isRevealed {
                // The text and Auto Pick sit one step apart, as the title's text and its Play button do, not a stack gap apart.
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    // A film's embedded header is empty until the streams load, so it takes no step above Auto Pick.
                    if isEmbedded {
                        if embeddedHeaderShowsText { embeddedHeader }
                    } else {
                        header
                    }
                    playBestButton
                }
                BestEditionView(model: model, rowHeight: autoPickButtonHeight)
                    .padding(.horizontal, streamMargin)
                addonChips
                    .padding(.horizontal, streamMargin)
                #if !targetEnvironment(macCatalyst)
                // On a Mac the filter sits in Auto Pick's row instead (see `playBestButton`).
                resolutionChips
                    .padding(.horizontal, streamMargin)
                #endif
                failures
                emptyState
                loadingRows
                groups(recommended: model.recommendedStream)
                links
                hiddenHint
            }
        }
        .frame(maxWidth: columnWidth)
        #if targetEnvironment(macCatalyst)
        // Embedded in a title page the picker keeps the page's leading edge, so its rows line up with the page's text. Pushed, it centres.
        .frame(maxWidth: .infinity, alignment: isEmbedded ? .leading : .center)
        #else
        .frame(maxWidth: .infinity)
        #endif
    }

    /// What the picker does once it is on screen: loading, the sheets and the alerts, and cleaning up when it leaves. The same whether
    /// it is pushed or embedded.
    private func behaviour(_ view: some View) -> some View {
        view
            // A picker that is never shown has no edition to show.
            .task { if !isHeadless { await model.findBestEdition() } }
            .task {
                // Asked once, here: routing hands streams to these players only, and the menus offer only these.
                model.setInstalledPlayers(Set(ExternalPlayer.allCases.filter(isInstalled)))
                await model.loadAutoPlayPreference()
                // The previous viewing session for this title, when the app was left or killed: its own stream resumes
                // (`automaticStartCandidate`), and a stream another player played is handed its position and choices.
                await model.loadSessionResume()
                // A picker that is never shown is done once it has started a stream: shown again after the player closes, it does not load.
                if !model.hasLoaded, !isHeadless || !hasSelectedManually {
                    let settings = await services.settings.load()
                    let startsAutomatically = allowsAutomaticStart && (settings.autoPlayBestStream || forcesAutomaticStart)
                    model.startsAutomaticallyAnyway = forcesAutomaticStart
                    if startsAutomatically, !hasSelectedManually { awaitsAutomaticStart = true }
                    if startsAutomatically { await model.loadForAutomaticSelection() } else { await model.load() }
                    // The picker was left while it loaded: nothing starts, and no Auto Pick is left waiting on a load that was called off.
                    guard !Task.isCancelled else { return }
                    if startsAutomatically, !hasSelectedManually {
                        // All automatic launches take the same ranked route as normal Play:
                        // Blusion by default, Infuse only when the saved preference calls for it.
                        if let candidate = model.automaticStartCandidate {
                            select(candidate, automatically: true)
                        } else {
                            finishAutomaticStart(started: false)
                        }
                    } else {
                        finishAutomaticStart(started: false)
                    }
                } else if awaitsAutomaticStart, !isHeadless {
                    // Left while Auto Pick was still choosing, after every addon had answered: its choice was called off, so the
                    // list shows on return rather than Play spinning on.
                    finishAutomaticStart(started: false)
                }
            }
            .onChange(of: isReady && !awaitsAutomaticStart, initial: true) { _, ready in
                guard ready else { return }
                onReady?(!model.addonSections.isEmpty)
            }
            .onDisappear {
                autoPickTask?.cancel()
                model.cancelLoading()
                isOpeningPlayer = false
                preparingItemID = nil
                preparingViaAutoPick = false
                // A player readied for a stream nobody played goes with the picker. One the player screen took is no longer held here.
                discardPrepared()
            }
            // The first stream listed starts loading in the background the moment it arrives, in case it is the one played.
            .onChange(of: model.addonSections.first?.streams.first?.id) { startBackgroundLoad() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { isOpeningPlayer = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playbackHandoffDidFinish)) { notification in
                guard let receipt = notification.object as? PlaybackHandoffReceipt,
                      receipt.handoff.request.identity == model.request.identity else { return }
                isOpeningPlayer = false
                if let itemID = pendingSaves.removeValue(forKey: receipt.handoff.id), case .finished = receipt.result {
                    savedStreams.insert(itemID)
                }
            }
            .sheet(item: $expandedDetails) { item in
                NavigationStack {
                    ScrollView {
                        Text(item.stream.description ?? item.title)
                            .font(.footnote)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle("Stream Details")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { expandedDetails = nil } } }
                }
                .preferredColorScheme(.dark)
            }
            .fullScreenCover(item: $plan, onDismiss: { presentedPlayer = nil }) {
                PlayerScreen(plan: $0, services: services, prepared: presentedPlayer)
            }
            .alert("Ghost mode is on", isPresented: $ghostBlocked) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This stream only opens in another app, which keeps its own history. Pick another stream, or turn ghost mode off in Settings.")
            }
            .alert("This format isn't supported yet", isPresented: isShowingUnsupported, presenting: unsupported) { item in
                if let player = model.alternativePlayers(for: item).first {
                    Button("Open in \(player.displayName)") { openIn(player, item) }
                }
                if let next = model.nextPlayable(after: item), next.id != item.id {
                    Button("Try the next stream") { select(next) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text(unsupportedMessage(for: item))
            }
            .alert("\(missing?.player.displayName ?? "Player") isn't installed", isPresented: isShowingMissing,
                   presenting: missing) { pending in
                if let url = pending.player.appStoreURL {
                    Button("Get \(pending.player.displayName)") { openURL(url) }
                }
                if model.inAppChoice(for: pending.item) != nil {
                    Button("Play in Blusion") { playInBlusion(pending.item) }
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    /// Every addon has answered (with streams, with nothing, or with a failure). Until then the title page keeps its details and Play
    /// spins. A movie's first addon often answers with many streams at once, so revealing at a stream count dropped a movie's details
    /// at once while its other addons were still loading; waiting for every addon treats movies and episodes alike.
    private var isReady: Bool { model.hasLoaded && !model.listing.isLoading }

    // MARK: header

    /// The title's own artwork, stretched, blurred and faded into the page behind the header: the picker belongs to the title it opened
    /// from, the way the TV app tints a screen with its poster. It runs up under the navigation bar.
    @ViewBuilder
    private var ambientBackdrop: some View {
        if !isLandscape, let poster = model.request.poster {
            ArtworkImage(url: poster, maxPixelSize: 240)
                .frame(height: 520)
                .scaleEffect(1.4)
                .blur(radius: 46)
                .saturation(1.25)
                .opacity(0.5)
                .overlay { BottomFade(length: 0.85) }
                .clipped()
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Poster, then what is being picked: for an episode "Time · S1E3", for a film its year over its name. On a phone it is centred, as
    /// the title page is; in a wide window it reads from the left.
    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            if let poster = model.request.poster {
                PosterImage(url: poster, title: model.request.title)
                    .frame(width: 44, height: 66)
            }
            VStack(alignment: .leading, spacing: 2) {
                if episodeHeading == nil, let year = model.request.year {
                    Text(year)
                        .font(Theme.Typography.eyebrow)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                }
                if let episodeHeading {
                    episodeLine(episodeHeading, lineLimit: 2)
                } else {
                    Text(model.request.title)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, streamMargin)
        .padding(.top, Theme.Spacing.xs)
    }

    /// The widest the list runs. Embedded under a Mac title page's hero, its rows are as wide as the synopsis and the trailer's panel
    /// there, from the same leading edge, so the page has one column; elsewhere 760 points.
    private var columnWidth: CGFloat {
        #if targetEnvironment(macCatalyst)
        isEmbedded ? TitleHero.macDetailsWidth + streamMargin * 2 : 760
        #else
        760
        #endif
    }

    /// Whether the embedded header has an episode to show. A film's is empty.
    private var embeddedHeaderShowsText: Bool { episodeHeading != nil }

    /// The header of a title page that shows these streams in place of its details: which episode. The page above
    /// already has the poster, the title and the picture, so there is no poster here. A series' page has the episode switcher, centred,
    /// in place of the heading text.
    private var embeddedHeader: some View {
        let switches = episodeSwitcher != nil && episodeHeading != nil
        return HStack(alignment: .center, spacing: Theme.Spacing.m) {
            VStack(alignment: switches ? .center : .leading, spacing: 2) {
                if let episodeSwitcher, let season = model.request.season, let episode = model.request.episode {
                    episodeSwitcherRow(episodeSwitcher, season: season, episode: episode)
                } else if let episodeHeading {
                    // Under the title page's hero, so this is one line: a longer text is cut short rather than wrapped.
                    episodeLine(episodeHeading, lineLimit: 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: switches ? .center : .leading)
        }
        .padding(.horizontal, streamMargin)
    }

    /// "‹ Episode title · S1E1 [IMDb] 89 ›": the episode, its score right before the next chevron, and a small round glass chevron each
    /// side that loads the episode before or after in place, as its card would. A chevron with no episode to go to (the first episode,
    /// the last, or one that has not aired) is dimmed. A score that arrives later fades in.
    private func episodeSwitcherRow(_ switcher: EpisodeSwitcher, season: Int, episode: Int) -> some View {
        let episodeNumber = "S\(season)E\(episode)"
        let heading = episodeTitle.map { "\($0) · \(episodeNumber)" } ?? episodeNumber
        return HStack(alignment: .center, spacing: Theme.Spacing.m) {
            episodeStepButton(systemImage: "chevron.left", label: "Previous episode", to: switcher.previous, step: switcher.step)
                .accessibilityIdentifier("stream.previousEpisode")
            HStack(alignment: .center, spacing: Theme.Spacing.s) {
                Text(heading)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let episodeScore {
                    scoreLabel(episodeScore)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            // The middle fills the row, keeping both chevrons at the stream controls' outer edges.
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.2), value: episodeScore)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(episodeAccessibilityLabel(heading))
            .accessibilityAddTraits(.isHeader)
            episodeStepButton(systemImage: "chevron.right", label: "Next episode", to: switcher.next, step: switcher.step)
                .accessibilityIdentifier("stream.nextEpisode")
        }
    }

    /// One of the switcher's chevrons: about two thirds as tall as Auto Pick, in Play's tinted glass, with the app's light tap.
    private func episodeStepButton(systemImage: String, label: String, to request: StreamRequest?,
                                   step: @escaping (StreamRequest) -> Void) -> some View {
        // A new episode's picker has not measured Auto Pick yet, so it starts from the last height measured, and the chevrons keep their size.
        let side = (autoPickButtonHeight > 0 ? autoPickButtonHeight : Self.lastAutoPickHeight ?? 34) * 0.68
        return Button {
            guard let request else { return }
            Haptics.tap()
            step(request)
        } label: {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .glassCircleButton(.small, glass: .regular.interactive().tint((Theme.playControlColour(hex: playColourHex) ?? .clear)))
        .frame(width: side, height: side)
        .animation(.smooth(duration: 0.3), value: playColourHex)
        .disabled(request == nil)
        .opacity(request == nil ? 0.4 : 1)
        .accessibilityLabel(label)
        .help(label)
    }

    /// The episode's name and number, falling back to the series name. Nothing for a film.
    private var episodeHeading: String? {
        guard let season = model.request.season, let episode = model.request.episode else { return nil }
        // A request without the series' name has it at the front of its title, which is "Series · Episode".
        let series = model.request.seriesName ?? model.request.title.components(separatedBy: " · ").first ?? model.request.title
        return "\(episodeTitle ?? series) · S\(season)E\(episode)"
    }

    /// The episode portion of “Series · Episode”, shown between the switcher's chevrons.
    private var episodeTitle: String? {
        let parts = model.request.title.components(separatedBy: " · ")
        guard parts.count > 1 else { return nil }
        let title = parts.dropFirst().joined(separator: " · ")
        return title.isEmpty ? nil : title
    }

    /// The episode's heading, then its score right after the season and episode: the IMDb mark and a whole number, as its card shows it
    /// (a star when the score is not IMDb's). A long series name is cut short, never the score. A score that arrives later fades in at
    /// the end of the line, so nothing before it moves.
    private func episodeLine(_ heading: String, lineLimit: Int) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.s) {
            Text(heading)
                .font(.headline)
                .multilineTextAlignment(.leading)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
            if let episodeScore {
                scoreLabel(episodeScore)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: episodeScore)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(episodeAccessibilityLabel(heading))
        .accessibilityAddTraits(.isHeader)
    }

    /// IMDb's episode rating is an actionable link to that episode's reviews.
    @ViewBuilder
    private func scoreLabel(_ score: DetailViewModel.EpisodeScore) -> some View {
        if score.isIMDb, model.request.season != nil, model.request.episode != nil {
            Button {
                let request = model.request
                Task { await EpisodeIMDbReviews.open(request, ratings: services.posterRatings) }
            } label: {
                scoreContent(score)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open IMDb episode reviews")
            .accessibilityIdentifier("streams.episodeIMDbReviews")
        } else {
            scoreContent(score)
        }
    }

    private func scoreContent(_ score: DetailViewModel.EpisodeScore) -> some View {
        HStack(spacing: 4) {
            if score.isIMDb {
                ReviewSiteIcon(site: .imdb, size: 16)
            } else {
                Image(systemName: "star.fill").font(.system(size: 11, weight: .bold))
            }
            Text(score.text)
                .font(.headline)
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    /// What VoiceOver reads for the episode: its heading, then its score.
    private func episodeAccessibilityLabel(_ heading: String) -> String {
        [heading, episodeScore.map { "\($0.isIMDb ? "IMDb rating" : "Rating") \($0.text)" }].compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: the main action

    /// How much the switch is scaled so it is as tall as the Auto Pick button. 1 until both have been measured.
    private var autoPickSwitchScale: CGFloat {
        #if targetEnvironment(macCatalyst)
        // A Mac's switch keeps the Mac's own size.
        return 1
        #else
        guard autoPickButtonHeight > 0, autoPickSwitchSize.height > 0 else { return 1 }
        return autoPickButtonHeight / autoPickSwitchSize.height
        #endif
    }

    /// Embedded in a title page: a small round X, as tall as Auto Pick, that takes the streams away and puts the details back.
    @ViewBuilder
    private var closeButton: some View {
        if isEmbedded, let onClose {
            let side = autoPickButtonHeight > 0 ? autoPickButtonHeight : 34
            Button {
                Haptics.tap()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .glassCircleButton(.small)
            .frame(width: side, height: side)
            .accessibilityLabel("Back to details")
            .help("Back to details")
            .accessibilityIdentifier("streams.close")
        }
    }

    @ViewBuilder
    private var playBestButton: some View {
        let autoPickInfo = model.recommendedStreamLabel ?? (model.isLoading ? Self.lastAutoPickInfo : nil)
        if model.listing.items.isEmpty && !model.isLoading {
            // With no stream to pick, the X still stands where the row would, so the details are one tap away.
            closeButton.padding(.horizontal, streamMargin)
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.m) {
                    closeButton
                    Button {
                        // The same swipe check as a stream card: a swipe that ends on Auto Pick plays nothing.
                        guard !SwipeRecord.latest.isSwipe(at: ContinuousClock.now) else { return }
                        autoPick()
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            if model.isAutoPicking || preparingViaAutoPick {
                                Spinner()
                            } else {
                                Image(systemName: "sparkles").foregroundStyle(.secondary)
                            }
                            Text("Auto Pick")
                            // Keep the previous recommendation until the new streams have loaded.
                            if let kind = autoPickInfo {
                                Text("- \(kind)")
                                    .fontWeight(.regular)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        #if !targetEnvironment(macCatalyst)
                        // On a Mac it is as wide as its label, so the row is one compact line of controls.
                        .frame(maxWidth: .infinity)
                        #endif
                    }
                    .buttonStyle(.primaryActionCompact)
                    .controlSize(.small)
                    .disabled(model.isAutoPicking || preparingViaAutoPick)
                    .accessibilityLabel(autoPickInfo.map { "Auto Pick, \($0)" } ?? "Auto Pick")
                    .accessibilityIdentifier("streams.playBest")
                    .onChange(of: model.recommendedStreamLabel, initial: true) { _, info in
                        if let info { Self.lastAutoPickInfo = info }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        autoPickButtonHeight = $0
                        Self.lastAutoPickHeight = $0
                    }
                    // Saves the choice to start the best stream at once next time; it starts nothing itself.
                    Toggle("Always pick the best stream", isOn: Binding(get: { model.autoPlaysBestStream }, set: { value in
                        Task { await model.setAutoPlaysBestStream(value) }
                        // Turning it on picks now, as Auto Pick does, so the switch does what it says the moment it is tapped.
                        if value { autoPick() }
                    }))
                    .labelsHidden()
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { autoPickSwitchSize = $0 }
                    // The switch has one size of its own, so it is scaled to stand exactly as tall as the button beside it.
                    .scaleEffect(autoPickSwitchScale)
                    .frame(width: autoPickSwitchSize.width > 0 ? autoPickSwitchSize.width * autoPickSwitchScale : nil,
                           height: autoPickSwitchSize.height > 0 ? autoPickSwitchSize.height * autoPickSwitchScale : nil)
                    .accessibilityLabel("Always pick the best stream")
                    .accessibilityHint("Starts the best stream at once whenever you open a title's streams")
                    .accessibilityIdentifier("streams.autoPickAlways")
                    #if targetEnvironment(macCatalyst)
                    // The filter joins the row on a Mac, at its own width, rather than a full-width bar of its own under Best Blu-ray.
                    resolutionChips
                        .fixedSize()
                    #endif
                }
                if let message = model.autoPickMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, streamMargin)
        }
    }

    // MARK: filtering

    /// Sharpness bands the chips filter by. Anything under 720 lines is one band, "SD".
    private enum Band: Int, CaseIterable {
        case uhd = 2160, fullHD = 1080, hd = 720, sd = 480

        init(_ resolution: Int) {
            self = resolution >= 2160 ? .uhd : resolution >= 1080 ? .fullHD : resolution >= 720 ? .hd : .sd
        }

        var title: String {
            switch self {
            case .uhd: "4K"
            case .fullHD: "1080p"
            case .hd: "720p"
            case .sd: "SD"
            }
        }
    }

    private func band(of item: RankedStream) -> Band? { item.quality.resolution.map(Band.init) }

    /// The addons with streams listed so far, in the list's order, each once.
    private var availableAddons: [AddonSummary] {
        var seen = Set<UUID>()
        return model.addonSections.map(\.addon).filter { seen.insert($0.id).inserted }
    }

    /// The chosen addon, while it still has streams listed. One that has gone falls back to all.
    private var chosenAddon: UUID? {
        guard let addonFilter, availableAddons.contains(where: { $0.id == addonFilter }) else { return nil }
        return addonFilter
    }

    /// The sections of the chosen addon, or every section.
    private var addonSections: [StreamPickerViewModel.AddonSection] {
        guard let chosenAddon else { return model.addonSections }
        return model.addonSections.filter { $0.addon.id == chosenAddon }
    }

    /// Keep the previous bar while waiting for streams, then use the resolutions actually returned.
    private var availableBands: [Band] {
        let present = Set(addonSections.flatMap(\.streams).compactMap(band(of:)))
        if present.isEmpty && model.isLoading { return Self.lastResolutionBands }
        return Band.allCases.filter(present.contains)
    }

    /// The sections with only the chosen addon's and band's streams. A band that has gone (a refresh found fewer streams, or another
    /// addon was chosen) falls back to all.
    private var visibleSections: [StreamPickerViewModel.AddonSection] {
        guard let band = resolutionFilter, availableBands.contains(band) else { return addonSections }
        return addonSections.compactMap { section in
            let streams = section.streams.filter { self.band(of: $0) == band }
            return streams.isEmpty ? nil : StreamPickerViewModel.AddonSection(addon: section.addon, streams: streams)
        }
    }

    /// "All  4K  1080p  720p": visible immediately, then adjusted as stream resolutions arrive.
    @ViewBuilder
    private var resolutionChips: some View {
        if !availableBands.isEmpty {
            QualitySelector(titles: ["All"] + availableBands.map(\.title), selection: Binding {
                resolutionFilter.flatMap { availableBands.firstIndex(of: $0).map { $0 + 1 } } ?? 0
            } set: { index in
                resolutionFilter = index > 0 && index <= availableBands.count ? availableBands[index - 1] : nil
            })
            .onChange(of: availableBands, initial: true) { _, bands in
                if !bands.isEmpty { Self.lastResolutionBands = bands }
            }
        }
    }

    /// "All  Torrentio  Comet": shown once more than one addon has streams, so one addon's streams can be listed on their own.
    @ViewBuilder
    private var addonChips: some View {
        let addons = availableAddons
        if addons.count > 1 {
            QualitySelector(titles: ["All"] + addons.map(\.name), selection: Binding {
                chosenAddon.flatMap { id in addons.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
            } set: { index in
                addonFilter = index > 0 && index <= addons.count ? addons[index - 1].id : nil
            }, accessibilityID: "streams.addonFilter")
            #if targetEnvironment(macCatalyst)
            // On a Mac it keeps its own width at the leading edge, as the sharpness filter does in Auto Pick's row.
            .fixedSize()
            #endif
        }
    }

    // MARK: failures and empty states

    @ViewBuilder
    private var failures: some View {
        if !model.listing.failures.isEmpty {
            InlineErrorView(failureText) { Task { await model.retry() } }
                .accessibilityIdentifier("streams.failures")
                .padding(.horizontal, streamMargin)
        }
    }

    private var failureText: String {
        model.listing.failures.map { "\($0.addon.name): \($0.error.shortDescription)" }.joined(separator: "\n")
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.nobodyCanAnswer {
            EmptyStateView("No stream addons", systemImage: "puzzlepiece.extension",
                           message: "Add a stream addon in Settings to watch this title.",
                           actionTitle: "Open Addons", action: { router.showAddons() })
                .padding(.horizontal, streamMargin)
                .accessibilityIdentifier("streams.nobody")
        } else if model.isOffline {
            OfflineBanner()
                .padding(.horizontal, streamMargin)
        } else if model.showsNothingFound {
            EmptyStateView("No streams found", systemImage: "film.stack", message: "Your addons have nothing for this title.")
                .padding(.horizontal, streamMargin)
                .accessibilityIdentifier("streams.none")
        }
    }

    @ViewBuilder
    private var loadingRows: some View {
        if model.isLoading && model.listing.isEmpty {
            StreamRowsSkeleton(heights: Self.lastStreamCardHeights)
                .padding(.horizontal, streamMargin)
        }
    }

    // MARK: streams

    /// `recommended` is the stream Auto Pick would start; it alone carries the Best match mark.
    private func groups(recommended: RankedStream?) -> some View {
        // Each card's place counted across every visible section from the top, so the entrance runs down the whole list. A stream id
        // repeated in a later section keeps its first place.
        let order = Dictionary(visibleSections.flatMap(\.streams).enumerated().map { ($1.id, $0) },
                               uniquingKeysWith: { first, _ in first })
        return ForEach(visibleSections) { section in
            Section {
                ForEach(section.streams) { item in
                    let isRecommended = item.id == recommended?.id
                    keyboardMarked(streamButton(item, isRecommended: isRecommended, order: order[item.id] ?? 0,
                                                isKeyboardFocused: isKeyboardRow(section.addon.id, item.id)),
                                   in: section.addon.id, stream: item.id, hasEdge: isRecommended || StreamLook(item.quality) != .plain)
                        .padding(.horizontal, streamMargin)
                }
            } header: {
                // One addon chosen: the filter above already names it.
                if chosenAddon == nil, model.addonSections.count > 1 { sectionTitle(section).padding(.horizontal, streamMargin) }
            }
        }
    }

    /// Whether the arrow keys are on this row. Never on iPhone, which has none.
    private func isKeyboardRow(_ addon: UUID, _ stream: RankedStream.ID) -> Bool {
        #if targetEnvironment(macCatalyst)
        keyboardRow == KeyboardRow(addon: addon, stream: stream)
        #else
        false
        #endif
    }

    /// The addon's name over its streams, with how many it gave: "Torrentio · 12".
    private func sectionTitle(_ section: StreamPickerViewModel.AddonSection) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(section.addon.name)
                .font(.headline)
            Text("\(section.streams.count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Theme.surfaceStrong, in: Capsule())
        }
        .padding(.top, Theme.Spacing.s)
        .padding(.leading, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Links to web pages: a quiet group at the bottom, since they leave the app rather than play. Its cards are the stream cards, so the
    /// group has no background of its own.
    @ViewBuilder
    private var links: some View {
        if !model.links.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { isNotesExpanded.toggle() }
                } label: {
                    Text("Notes from your addons")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(isNotesExpanded ? "Expanded" : "Collapsed")
                if isNotesExpanded {
                    VStack(spacing: Theme.Spacing.m) {
                        ForEach(model.links) { item in streamButton(item, isRecommended: false, order: 8) }
                    }
                    .padding(.top, Theme.Spacing.s)
                }
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, streamMargin)
        }
    }

    /// One stream as a card on the title page's surface: the top plays it, the technical details fold away underneath. `order` is the
    /// card's place in the list, which sets when its entrance animation starts. `isKeyboardFocused` (Mac) draws its edge bolder.
    private func streamButton(_ item: RankedStream, isRecommended: Bool, order: Int, isKeyboardFocused: Bool = false) -> some View {
        let look = StreamLook(item.quality)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                // A swipe that travelled across the card ends as a touch-up here too. It plays nothing.
                guard !SwipeRecord.latest.isSwipe(at: ContinuousClock.now) else { return }
                select(item)
            } label: {
                // A stream Blusion plays has its one play button; saving it to another player is in its menu. A stream another app
                // plays keeps the bookmark and download under its mark.
                StreamRow(item: item, isBest: isRecommended, isRemux: item.quality.isRemux,
                          savesToPlayer: savesUnderMark(item),
                          downloadsToPlayer: savesUnderMark(item),
                          downloadsNatively: true,
                          isPreparing: preparingItemID == item.id)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        guard order < 3, height > 0 else { return }
                        #if targetEnvironment(macCatalyst)
                        Self.lastStreamCardHeights[order] = height
                        #else
                        // Include the collapsed footer, regardless of whether this card's details are currently expanded.
                        Self.lastStreamCardHeights[order] = height + 1 + Theme.Spacing.m * 2
                            + UIFont.preferredFont(forTextStyle: .footnote).lineHeight.rounded(.up)
                        #endif
                    }
            }
            // On a Mac one hover effect: the card's own highlight, without the system's on top of it. iPad keeps both, as before.
            .buttonStyle(PressableCardStyle(lifts: false, addsSystemHighlight: StreamCardMetrics.addsSystemHighlight))
            .contextMenu { contextActions(for: item) }
            .overlayPreferenceValue(StreamNativeDownloadSlotKey.self) { slot in
                if let slot {
                    GeometryReader { proxy in
                        NativeDownloadButton(manager: services.downloads, item: services.downloads?.item(forStream: item.id),
                                             isLoading: services.downloads?.enqueueing.contains(item.id) == true,
                                             isAvailable: services.downloads?.item(forStream: item.id) != nil
                                                 || DownloadEligibility.container(for: item, config: model.listing.config) != nil,
                                             size: item.route.isPlayable ? StreamCardMetrics.playButtonSize : StreamCardMetrics.markSize,
                                             matchesStream: true) {
                            Task { await services.downloads?.enqueue(item, request: model.request) }
                        }
                        .position(x: proxy[slot].midX, y: proxy[slot].midY)
                        .accessibilityIdentifier("stream.nativeDownload.button")
                    }
                }
            }
            .task { await services.downloads?.bindStream(item, request: model.request) }
            .accessibilityIdentifier("stream.row.\(item.title)")
            .accessibilityHint(hint(for: item))
            // A card that opens in another player has a bookmark under its mark, set in the room the card keeps for it.
            .overlayPreferenceValue(StreamSaveSlotKey.self) { slot in
                if let slot, savesUnderMark(item), let player = model.savingPlayer(for: item) {
                    GeometryReader { proxy in
                        StreamSaveButton(player: player, isSaved: savedStreams.contains(item.id)) { save(item, to: player) }
                            .position(x: proxy[slot].midX, y: proxy[slot].midY)
                            .accessibilityIdentifier("stream.save.\(item.title)")
                    }
                }
            }
            .overlayPreferenceValue(StreamDownloadSlotKey.self) { slot in
                if let slot, savesUnderMark(item), let player = model.savingPlayer(for: item) {
                    GeometryReader { proxy in
                        StreamSaveButton(player: player, isSaved: false, isDownload: true) {
                            save(item, to: player, download: true)
                        }
                        .position(x: proxy[slot].midX, y: proxy[slot].midY)
                        .accessibilityIdentifier("stream.download.\(item.title)")
                    }
                }
            }
            #if targetEnvironment(macCatalyst)
            // A Mac card opens its technical details from a chevron at the end of its facts line, set in the room the card keeps there.
            .overlayPreferenceValue(StreamDetailsSlotKey.self) { slot in
                if let slot {
                    GeometryReader { proxy in
                        StreamDetailsDisclosure(isExpanded: openDetails.contains(item.id)) { toggleDetails(of: item) }
                            .position(x: proxy[slot].midX, y: proxy[slot].midY)
                            .accessibilityIdentifier("stream.details.\(item.title)")
                    }
                }
            }
            #endif
            #if targetEnvironment(macCatalyst)
            StreamTechnicalDetails(item: item, openedOutside: openDetails.contains(item.id))
            #else
            StreamTechnicalDetails(item: item)
            #endif
        }
        .cardSurface(cornerRadius: StreamCardMetrics.cornerRadius)
        .streamLookGlow(look)
        .clipShape(RoundedRectangle(cornerRadius: StreamCardMetrics.cornerRadius, style: .continuous))
        .overlay {
            if isRecommended {
                RoundedRectangle(cornerRadius: StreamCardMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.brandGradient, lineWidth: isKeyboardFocused ? 3 : 1.5)
                    .brightness(isKeyboardFocused ? 0.3 : 0)
                    .allowsHitTesting(false)
            }
        }
        // The Best match keeps its brand edge; the card's service or disc edge shows on every other stream.
        .streamLookEdge(isRecommended ? .plain : look, isEmphasised: isKeyboardFocused)
        .streamCardEntrance(id: AnyHashable(item.id), order: order, log: entranceLog)
    }

    @ViewBuilder
    private func contextActions(for item: RankedStream) -> some View {
        if DownloadEligibility.container(for: item, config: model.listing.config) != nil, services.downloads != nil {
            Button("Download", systemImage: "arrow.down.circle") {
                Haptics.tap()
                Task { await services.downloads?.enqueue(item, request: model.request) }
            }.accessibilityIdentifier("stream.nativeDownload")
        }
        if item.stream.description != nil {
            Button("Show Details", systemImage: "info.circle") { expandedDetails = item }
        }
        ForEach(model.alternativePlayers(for: item), id: \.self) { player in
            Button("Open in \(player.displayName)", systemImage: "arrow.up.forward.app") { openIn(player, item) }
        }
        if item.route.handoffTarget != nil, model.inAppChoice(for: item) != nil {
            Button("Play in Blusion", systemImage: "play.circle") { playInBlusion(item) }
        }
        // The bookmark and download a stream Blusion plays no longer carry on its card.
        if item.route.isPlayable, let player = model.savingPlayer(for: item) {
            Button(savedStreams.contains(item.id) ? "Saved to \(player.displayName)" : "Save to \(player.displayName)",
                   systemImage: savedStreams.contains(item.id) ? "bookmark.fill" : "bookmark") { save(item, to: player) }
                .disabled(savedStreams.contains(item.id))
            Button("Download in \(player.displayName)", systemImage: "arrow.down") { save(item, to: player, download: true) }
        }
    }

    /// Whether the card carries the bookmark and download under its mark: only a stream another player app plays.
    private func savesUnderMark(_ item: RankedStream) -> Bool {
        !item.route.isPlayable && model.savingPlayer(for: item) != nil
    }

    @ViewBuilder
    private var hiddenHint: some View {
        if !model.listing.hidden.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(model.listing.hidden) { note in
                    Label(note.text, systemImage: "eye.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, streamMargin)
            .accessibilityIdentifier("streams.hidden")
        }
    }

    private func hint(for item: RankedStream) -> String {
        switch item.route {
        case .native, .fallback: return "Plays in Blusion"
        case .handoff(let player, _): return "Opens in \(player.displayName)"
        case .external: return "Opens outside Blusion"
        case .unsupported: return "This format isn't supported yet"
        case .hidden: return ""
        }
    }

    // MARK: choosing

    /// Starts `item`. `automatically` is set for the start made when the streams open (see `finishAutomaticStart`). Tapping the stream
    /// Blusion is readying again calls that off; tapping another stream moves to it.
    private func select(_ item: RankedStream, automatically: Bool = false) {
        if preparingItemID != nil {
            let isSame = preparingItemID == item.id
            cancelPreparation()
            if isSame, !automatically { return }
        }
        guard !isOpeningPlayer else { return }
        isOpeningPlayer = true
        hasSelectedManually = true
        autoPickTask?.cancel()
        autoPickTask = Task {
            guard let choice = await model.choose(item) else {
                isOpeningPlayer = false
                if automatically { finishAutomaticStart(started: false) }
                return
            }
            guard !Task.isCancelled else { isOpeningPlayer = false; return }
            let started = await present(choice, for: item)
            // Called off while the film was readied: whoever called it off has already reset the picker.
            guard !Task.isCancelled else { return }
            if automatically { finishAutomaticStart(started: started) }
        }
    }

    /// Calls off readying a stream: its play button and Auto Pick stop spinning. The player keeps loading in the background, so playing
    /// that stream after all is still quick.
    private func cancelPreparation() {
        autoPickTask?.cancel()
        preparingItemID = nil
        preparingViaAutoPick = false
        isOpeningPlayer = false
    }

    /// Readies `next` (the plan for `item`) and opens the player once the film is ready to play: its first frame is in, held paused, and
    /// it plays the moment the screen is up. The stream's play button spins meanwhile. A player already readied for this stream (the
    /// first stream's background load) is used as it is. False when it was called off.
    private func openWhenReady(_ next: PlaybackPlan, for item: RankedStream) async -> Bool {
        let player = preparedPlayer(for: next, item: item)
        // Walking back into the previous session (the app was left or killed, and this is its stream): the player takes its
        // position, track choices and picture over, before it is readied to play.
        if let snapshot = model.resumeHandoff(for: item), let resuming = player as? any PlaybackSnapshotResuming {
            resuming.resumePlayback(from: snapshot)
        }
        preparingItemID = item.id
        await player.prepare()
        guard !Task.isCancelled, prepared === player else { return false }
        preparingItemID = nil
        preparingViaAutoPick = false
        isOpeningPlayer = false
        // The screen takes the player over. Every stream failing still opens it, to say why.
        prepared = nil
        preparedItemID = nil
        presentedPlayer = player
        plan = player.plan
        return true
    }

    /// The player readied for `item`: the one already loading for it, or a new one, which replaces a player readied for another stream.
    private func preparedPlayer(for next: PlaybackPlan, item: RankedStream) -> PlayerViewModel {
        if let prepared, preparedItemID == item.id { return prepared }
        discardPrepared()
        let player = PlayerContent.makeModel(plan: next, services: services)
        // The stream's opening bytes start downloading at once, where its engine can take them.
        PlayerPreload.begin(next, services: services)
        prepared = player
        preparedItemID = item.id
        return player
    }

    /// Closes a readied player nobody is going to watch.
    private func discardPrepared() {
        guard let player = prepared else { return }
        prepared = nil
        preparedItemID = nil
        Task { await player.close() }
    }

    /// Starts loading the first stream listed in the background, once it is there, in case it is the one played: muted, held paused
    /// on its first frame, with no progress saved. Only a stream Blusion plays, and not when a stream is starting by itself anyway.
    private func startBackgroundLoad() {
        guard !hasStartedBackgroundLoad, !hasSelectedManually, !awaitsAutomaticStart, !isHeadless, prepared == nil, plan == nil,
              let first = model.automaticStartCandidate, first.route.isPlayable else { return }
        hasStartedBackgroundLoad = true
        Task {
            guard case .play(let next)? = await model.choose(first), prepared == nil, plan == nil, !hasSelectedManually,
                  !awaitsAutomaticStart else { return }
            await preparedPlayer(for: next, item: first).prepare()
        }
    }

    /// The automatic start made when the streams open is over. Started, the list is never shown; with nothing started, it shows once
    /// every addon has answered, as it does with Auto Pick off.
    private func finishAutomaticStart(started: Bool) {
        if !started { awaitsAutomaticStart = false }
        onAutomaticStart?(started)
    }

    /// Manual Auto Pick uses the same ranked, preference-aware player route as Play.
    private func autoPick() {
        guard !isOpeningPlayer else { return }
        isOpeningPlayer = true
        hasSelectedManually = true
        autoPickTask?.cancel()
        autoPickTask = Task {
            guard let choice = await model.autoPickBest(), !Task.isCancelled, let item = model.autoPickedStream else {
                isOpeningPlayer = false
                return
            }
            if case .play = choice { preparingViaAutoPick = true }
            _ = await present(choice, for: item)
        }
    }

    private func openIn(_ player: ExternalPlayer, _ item: RankedStream) {
        guard !isOpeningPlayer else { return }
        isOpeningPlayer = true
        hasSelectedManually = true
        autoPickTask?.cancel()
        autoPickTask = Task {
            guard let choice = await model.handoffChoice(for: item, player: player), !Task.isCancelled else {
                isOpeningPlayer = false
                return
            }
            await present(choice, for: item)
        }
    }

    private func playInBlusion(_ item: RankedStream) {
        if preparingItemID != nil { cancelPreparation() }
        guard !isOpeningPlayer else { return }
        hasSelectedManually = true
        autoPickTask?.cancel()
        guard let choice = model.inAppChoice(for: item) else { return }
        isOpeningPlayer = true
        autoPickTask = Task { await present(choice, for: item) }
    }

    /// Starts `choice`. True when a stream started here or went to another app; false when an alert asks the viewer to pick again, or
    /// when readying the film was called off. A stream Blusion plays opens only once it is ready to play (see `openWhenReady`).
    @discardableResult
    private func present(_ choice: StreamPickerViewModel.Choice, for item: RankedStream) async -> Bool {
        // In ghost mode nothing is handed to another player except Infuse, which the viewer allows: Infuse keeps its own history and its own
        // Trakt. Anything else that would leave Blusion plays here when Blusion can play it, and otherwise does not start.
        if GhostMode.isOn {
            switch choice {
            case .openInPlayer(.infuse, _):
                break
            case .openInPlayer, .openExternal:
                if case .play(let next)? = model.inAppChoice(for: item) {
                    return await openWhenReady(next, for: item)
                }
                ghostBlocked = true
                isOpeningPlayer = false
                return false
            case .play, .unsupported:
                break
            }
        }
        switch choice {
        case .play(let next):
            isOpeningPlayer = true
            // The session this start becomes: where the app is left or killed from now until it is closed.
            await model.saveResumeSnapshot(for: item)
            return await openWhenReady(next, for: item)
        case .openExternal(let url):
            isOpeningPlayer = false
            openURL(url)
        case .openInPlayer(let player, let link):
            isOpeningPlayer = true
            openURL(link) { accepted in
                if !accepted {
                    isOpeningPlayer = false
                    Task { await model.discardHandoff(for: link) }
                    missing = MissingPlayer(player: player, item: item)
                }
            }
        case .unsupported:
            isOpeningPlayer = false
            unsupported = item   // the alert offers the next playable stream, or another player
            return false
        }
        return true
    }

    #if targetEnvironment(macCatalyst)
    /// Opens or folds a Mac card's technical details, with the motion the row on iPhone has, or none with Reduce Motion on.
    private func toggleDetails(of item: RankedStream) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            if openDetails.contains(item.id) { openDetails.remove(item.id) } else { openDetails.insert(item.id) }
        }
    }
    #endif

    /// Bookmark saves return to Blusion on confirmation. Downloads stay in Infuse unless
    /// Infuse reports an error; neither action claims the video has finished downloading.
    private func save(_ item: RankedStream, to player: ExternalPlayer, download: Bool = false) {
        guard !isOpeningPlayer, download || !savedStreams.contains(item.id) else { return }
        isOpeningPlayer = true
        autoPickTask?.cancel()
        autoPickTask = Task {
            guard let link = await model.saveLink(for: item, download: download),
                  !Task.isCancelled else { isOpeningPlayer = false; return }
            if download {
                openURL(link) { accepted in
                    isOpeningPlayer = false
                    if !accepted {
                        Task { await model.discardHandoff(for: link) }
                        missing = MissingPlayer(player: player, item: item)
                    }
                }
                return
            }
            guard let token = StreamPickerViewModel.handoffToken(in: link) else { isOpeningPlayer = false; return }
            pendingSaves[token] = item.id
            openURL(link) { accepted in
                if !accepted {
                    isOpeningPlayer = false
                    pendingSaves[token] = nil
                    Task { await model.discardHandoff(for: link) }
                    missing = MissingPlayer(player: player, item: item)
                }
            }
        }
    }

    // MARK: players and alerts

    /// Whether the player app is on this device. Its scheme is listed in LSApplicationQueriesSchemes, which is what lets the system answer.
    /// Only asked once per opening of the picker, never while a row or a menu is drawn.
    private func isInstalled(_ player: ExternalPlayer) -> Bool {
        guard let url = URL(string: "\(player.scheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    private func unsupportedMessage(for item: RankedStream) -> String {
        if let player = model.alternativePlayers(for: item).first {
            return "Blusion can't play this container or audio yet. \(player.displayName) can."
        }
        return "Blusion can't play this container or audio yet. Pick another stream."
    }

    private var isShowingUnsupported: Binding<Bool> {
        Binding(get: { unsupported != nil }, set: { if !$0 { unsupported = nil } })
    }

    private var isShowingMissing: Binding<Bool> {
        Binding(get: { missing != nil }, set: { if !$0 { missing = nil } })
    }
}

/// The episodes either side of a picker's own, for the switcher in its header, and what a step does: the page loads that episode's
/// streams in place. Each is nil when there is no episode to go to.
struct EpisodeSwitcher {
    let previous: StreamRequest?
    let next: StreamRequest?
    let step: (StreamRequest) -> Void
}

/// A hand-off that could not start because its player app is not installed.
private struct MissingPlayer {
    let player: ExternalPlayer
    let item: RankedStream
}
#endif
