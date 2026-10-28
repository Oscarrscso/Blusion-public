#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

/// The title page, drawn the way Apple's TV app draws one: artwork under the navigation bar with the logo low on it, one quiet
/// metadata line, the main action, round secondary actions, the synopsis, then for a series its seasons and episodes, and last
/// the credits.
struct DetailView: View {
    @State private var model: DetailViewModel
    @State private var isDescriptionExpanded = false
    @State private var isDescriptionTruncated = false
    @State private var isConfirmingUnmarkShow = false
    /// True while an episode's context menu is open. The page blurs behind it.
    @State private var isHoldingEpisode = false
    /// The streams the page shows in place of its details after Play, what asked for them, and whether Auto Pick started one of them.
    @State private var streams = TitleStreams()
    /// Empty results apply to this visit and this movie or episode only.
    @State private var unavailableStreams: Set<String> = []
    /// The item a Continue Watching card opens the page with. It is picked once the hero has settled (see the lookup task below), so the
    /// picker never loads ahead of the hero's images.
    @State private var pendingStreams: StreamRequest?
    /// Only the artwork transform observes the changing offset.
    @State private var heroScroll = DetailHeroScrollState()
    /// Loads the hero picture and logo together, and reveals them together. Starts with what the spotlight showed, when it opened this title.
    @State private var hero: HeroLoader
    /// The page's own side safe-area inset, as its geometry reports it: the notch side of a phone held in landscape, zero elsewhere. The
    /// window's share is added in `contentMargin`.
    @State private var sideInset: CGFloat = 0
    /// The least space kept clear above the logo, as the page's own geometry reports the top safe area. The page runs under the status bar,
    /// so the window's share is added where the hero uses it (see `windowSafeArea`).
    @State private var topInset: CGFloat = 0
    /// The largest bottom safe-area inset reported while the page has been this width (home indicator, tab bar, bottom accessory). The tab
    /// bar shrinks when it minimises during a scroll, so the end of the page clears the larger size, not the current one.
    @State private var bottomPeak: CGFloat = 0
    /// The width the page was last laid out at. A change (a rotation, a resized window) starts `bottomPeak` again.
    @State private var layoutWidth: CGFloat = 0
    /// The bottom inset the page's scroll view actually applies to its content, including the extra margin added below.
    @State private var scrollBottom: CGFloat = 0
    /// True when Home's spotlight opened the page (the only caller that passes a handoff). Only such a page plays the settle.
    private let opensFromSpotlight: Bool
    /// The stream picker shown in place of the details needs the services.
    private let services: AppServices
    /// Turns true when the page first appears, so the settle plays once for a page opened from the spotlight and not again when the user
    /// returns to it from a deeper page.
    @State private var hasSettled = false
    @State private var hasAppeared = false
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.isLandscape) private var isLandscape
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape
    @Environment(AppRouter.self) private var router
    @Environment(\.windowSafeArea) private var windowSafeArea
    @Environment(LandscapeTabBarState.self) private var landscapeTabs: LandscapeTabBarState?
    /// True while a trailer that started on a phone turned sideways is shown full screen. The cover belongs to the page, so it lives as
    /// long as the page does, and the trailer's panel is not what presents it.
    @State private var showsTrailerCover = false
    /// True until the trailer's cover has gone and its landscape playback is closed. The inline panel stays hidden meanwhile.
    @State private var playerIsCovered = false
    /// A phone held sideways, not an iPad or a Mac window: the trailer that starts here plays full screen. Intentionally iOS-only, and
    /// phone-only, since iPad landscape keeps the panel.
    private var isPhoneInLandscape: Bool { isPhoneLandscape && UIDevice.current.userInterfaceIdiom == .phone }

    /// How far the page's scroll indicator is kept from the top and bottom of the screen.
    private static let scrollIndicatorInset: CGFloat = 260
    /// The Mac title page's margin from the sidebar. The rows below follow it.
    private static let desktopMargin: CGFloat = 60
    /// How far the page blurs while an episode's menu is open.
    private static let heldBlur: CGFloat = 4
    /// The streams replace the details, or the details come back, in this swap.
    private static let swapAnimation = Animation.easeInOut(duration: 0.22)

    /// In portrait the artwork runs under the bar, so the page margin is enough. In landscape on iPhone the page keeps the device's side
    /// safe-area inset plus a small gap, never less than a slim margin. On Mac the back button floats above the picture's top leading
    /// corner, clear of the text, so the text sits a fixed distance from the sidebar and the rows below line up with it.
    private var contentMargin: CGFloat {
        guard showsBackdrop else { return metrics.contentMargin }
        #if targetEnvironment(macCatalyst)
        return Self.desktopMargin
        #else
        // Just clear of the notch and rounded corners: the side inset plus a small gap, never less than a slim margin.
        return max(max(sideInset, windowSideInset) + Theme.Spacing.xs, Theme.Spacing.m)
        #endif
    }

    /// The window's own side insets, from the root (see `windowSafeArea`). The root lets screens run under them, so the page's geometry
    /// may not report them.
    private var windowSideInset: CGFloat {
        max(windowSafeArea.leading, windowSafeArea.trailing)
    }

    /// What the scroll view lacks of the bottom safe area. The page is a scroll view inside a geometry reader, so it may not apply the
    /// tab bar and accessory inset to its content itself. The inset it applies, less the extra margin added here, is what the system
    /// gives; only the rest of the peak safe area is added, so it is never counted twice.
    @State private var bottomExtra: CGFloat = 0

    private func refreshBottomExtra() {
        let fromSystem = max(0, scrollBottom - bottomExtra)
        let next = max(0, bottomPeak - fromSystem)
        if abs(next - bottomExtra) > 0.5 { bottomExtra = next }
    }

    /// `streams` opens the page with its stream picker already on it, as if Play had been tapped for that request, once the hero has
    /// settled. A Continue Watching card opens its title this way, with the item it resumes. The picker reveals once its streams are
    /// ready, as it does after Play.
    init(preview: MetaPreview, services: AppServices, artwork: TMDbArtwork? = nil, artworkChecked: Bool = false, handoff: HeroHandoff? = nil,
         streams: StreamRequest? = nil) {
        _model = State(initialValue: DetailViewModel(preview: preview, services: services, artwork: artwork, artworkChecked: artworkChecked,
                                                     trailerPreparer: AVTrailerPreparer()))
        _hero = State(initialValue: HeroLoader(seeding: handoff))
        _pendingStreams = State(initialValue: streams)
        self.services = services
        opensFromSpotlight = handoff != nil
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        #if targetEnvironment(macCatalyst)
                        DesktopDetailHero(model: model, size: geometry.size, contentMargin: contentMargin, pictureSlot: pictureSlot,
                                          logoSlot: logoSlot, isRevealed: isHeroRevealed, showsDetails: !showsStreams) {
                            DetailActions(model: model, isConfirmingUnmarkShow: $isConfirmingUnmarkShow,
                                          showsActions: !showsStreams, isLoadingStreams: loadingTrigger == .play,
                                          hasNoStreams: unavailableStreams.contains(model.primaryRequest?.identity ?? ""),
                                          blocksPlay: loadingTrigger != nil && loadingTrigger != .play,
                                          showsMetaLine: false, play: { showStreams($0, from: .play) })
                        } trailer: { width in
                            DetailTrailerPanel(model: model, width: width, playerIsCovered: playerIsCovered)
                        } synopsis: {
                            DetailSynopsis(description: model.detail.preview.description, isExpanded: $isDescriptionExpanded,
                                           isTruncated: $isDescriptionTruncated, foldedLines: 5, isLoading: model.isLoading)
                        } information: {
                            // The information follows the cast, as on iPhone (see DetailCredits), not at the top of the page.
                            EmptyView()
                        }
                        #else
                        DetailHero(model: model, scroll: heroScroll, size: geometry.size, contentMargin: contentMargin,
                                   topInset: max(topInset, windowSafeArea.top), pictureSlot: pictureSlot,
                                   logoSlot: logoSlot, isRevealed: isHeroRevealed, hidesLogo: hidesLogo,
                                   showsDetails: !showsStreams) {
                            DetailActions(model: model, isConfirmingUnmarkShow: $isConfirmingUnmarkShow,
                                          showsActions: !showsStreams, isLoadingStreams: loadingTrigger == .play,
                                          hasNoStreams: unavailableStreams.contains(model.primaryRequest?.identity ?? ""),
                                          blocksPlay: loadingTrigger != nil && loadingTrigger != .play,
                                          play: { showStreams($0, from: .play) })
                        } trailer: {
                            DetailTrailerPanel(model: model, width: trailerWidth(in: geometry.size), playerIsCovered: playerIsCovered)
                        } synopsis: {
                            DetailSynopsis(description: model.detail.preview.description, isExpanded: $isDescriptionExpanded,
                                           isTruncated: $isDescriptionTruncated, isLoading: model.isLoading)
                        }
                        #endif
                        if let request = streams.request {
                            // The page scrolls to here once the streams are ready, so the picker's top sits a seventh of the way down the screen, and more rows show.
                            Color.clear.frame(height: 0).id(Self.streamsScrollID)
                            // The streams take the place of everything below the metadata line. The picture, the logo and the line stay.
                            // The picker is on the page from the tap, so it loads, but it draws nothing and takes no room until its
                            // streams are ready.
                            // With Auto Pick on, the stream it chooses starts without the list ever showing: Play's spinner stops, and
                            // the details stay.
                            StreamPickerView(request: request, services: services, isEmbedded: true, isRevealed: streams.isReady,
                                             onClose: closeStreams, onReady: { revealStreams(hasStreams: $0, for: request) },
                                             scrollToRow: { proxy.scrollTo($0, anchor: .center) },
                                             episodeScore: model.episodeScore(for: request),
                                             episodeSwitcher: episodeSwitcher(for: request),
                                             onAutomaticStart: { started in if started { streams.startedAutomatically() } },
                                             playColourHex: model.playColourHex)
                                .id(streams.pickerID)
                                #if targetEnvironment(macCatalyst)
                                // The picker's rows are inset by its own margin, so the picker starts that much short of the page's margin.
                                .padding(.horizontal, max(0, contentMargin - Theme.Spacing.l))
                                #endif
                                // Under the meta line the streams start one Play-button step down, where Play sits. Mac's meta line sits
                                // apart from its Play button, so Mac keeps its own gap.
                                #if targetEnvironment(macCatalyst)
                                .padding(.top, showsStreams ? metrics.titleRatingsGap : 0)
                                #else
                                .padding(.top, showsStreams ? (isLandscape ? Theme.Spacing.s : TitleHero.playRowGap) : 0)
                                #endif
                                // At least a screen tall, so the page is never shorter than where it was scrolled to when Play was
                                // tapped: a page that became too short would jump back to its top.
                                .frame(minHeight: showsStreams ? geometry.size.height : nil, alignment: .top)
                                .transition(.opacity)
                        }
                        if !showsStreams {
                            Group {
                                Rectangle()
                                    .fill(Theme.separator)
                                    .frame(height: 1)
                                    .padding(.horizontal, contentMargin)
                                    // The hero already reserves space below its rating pills. Account for that inset, then use the
                                    // same section gap on both sides so the divider actually sits between the two sections.
                                    .padding(.top, isLandscape
                                        ? metrics.titleRatingsGap - TitleHero.landscapeContentBottomInset
                                        : metrics.titleRatingsGap)
                                    .accessibilityHidden(true)
                                if model.isSeries {
                                    DetailEpisodes(model: model, pageWidth: geometry.size.width, pageHeight: geometry.size.height,
                                                   contentMargin: contentMargin,
                                                   isHoldingEpisode: $isHoldingEpisode, play: { showStreams($0, from: $1) },
                                                   loadingRequest: streams.loadingRequest, loadingTrigger: loadingTrigger,
                                                   unavailableStreams: unavailableStreams)
                                        .padding(.top, isLandscape ? Theme.Spacing.s : metrics.titleRatingsGap)
                                }
                                VStack(alignment: .leading, spacing: metrics.titleSectionSpacing) {
                                    if model.isLoadingReviews || !model.reviews.isEmpty {
                                        DetailReviews(reviews: model.reviews, isLoading: model.isLoadingReviews && model.reviews.isEmpty,
                                                      consensus: model.reviewConsensus,
                                                      isSummarizing: model.isSummarizingReviews, reviewedCount: model.reviewedCount,
                                                      summaryError: model.reviewSummaryError,
                                                      onRequestSummary: { await model.loadReviewConsensus() },
                                                      playColourHex: model.playColourHex,
                                                      width: geometry.size.width,
                                                      contentMargin: contentMargin)
                                            // A changed review corpus resets the panel and cancels its in-flight AI task.
                                            .id(ReviewConsensusReader.key(for: model.reviews))
                                    }
                                    DetailCredits(model: model, contentMargin: contentMargin, pageWidth: geometry.size.width)
                                }
                                .padding(.top, model.isSeries ? metrics.titleSectionSpacing
                                    : isLandscape ? Theme.Spacing.s : metrics.titleRatingsGap)
                                if model.isLoadingRelated || !model.relatedTitles.isEmpty {
                                    related
                                        .padding(.top, metrics.titleSectionSpacing)
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                    .padding(.bottom, Theme.Spacing.xxl)
                    .detailLoadingTransition(model.isLoadingReviews)
                    .detailLoadingTransition(model.isLoadingRelated)
                    // The panel's appearance and disappearance moves the content below it, rather than jumping.
                    .animation(.snappy(duration: 0.35), value: model.trailer.showsPanel)
                    // The reviews' consensus line arrives seconds after them: it fades in and the content below moves down with it.
                    .animation(.smooth(duration: 0.35), value: model.reviewConsensus)
                    // The system draws the held episode and its menu above the page, so they stay sharp.
                    .blur(radius: isHoldingEpisode ? Self.heldBlur : 0)
                    .animation(.easeOut(duration: 0.2), value: isHoldingEpisode)
                }
                // The track of the page's own scroll indicator is inset, so the bar is a short line rather than the whole screen height.
                .contentMargins(.vertical, Self.scrollIndicatorInset, for: .scrollIndicators)
                .contentMargins(.bottom, bottomExtra, for: .scrollContent)
                // Phone landscape: scrolling down tucks the landscape bar away to Home, as on every other page.
                .trackLandscapeTabScroll()
                // Track the vertical page itself, not a background descendant or a nested horizontal shelf.
                // The page passes the reference without reading its offset, so only the artwork observes each tick.
                .onScrollGeometryChange(for: CGFloat.self) { scroll in
                    let offset = scroll.contentOffset.y + scroll.contentInsets.top
                    let hero = isLandscape ? TitleHero.landscapeHeroHeight(pageHeight: geometry.size.height)
                                           : TitleHero.height(width: geometry.size.width, metrics: metrics)
                    return min(offset, hero + scroll.containerSize.height)
                } action: { _, value in
                    heroScroll.offset = value
                }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.bottom } action: { _, value in
                    scrollBottom = value
                    refreshBottomExtra()
                }
                // A panel that appears may be below the fold. The page moves only as far as it needs to, and not at all when the panel is
                // already in view. The short wait lets the panel's own appearance start first, so the page moves to where it ends up.
                .onChange(of: model.trailer.showsPanel) { _, shows in
                    guard shows else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(50))
                        withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo(DetailTrailerPanel.scrollID) }
                    }
                }
                // Reviews opened from a rating appear under the ratings, which may be below the fold. The page moves to them only once they have
                // loaded and open, so nothing on the page moves while the rating's spinner runs.
                .onChange(of: model.reviewsLoading) { _, loading in
                    guard !loading, model.openedReviews != nil else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(50))
                        withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo(DetailReviewsPanel.scrollID, anchor: .center) }
                    }
                }
                // Once the streams are ready they take the details' place, so the page moves down to bring the stream list into view.
                // The short wait lets them lay out first.
                .onChange(of: streams.isReady) { _, ready in
                    guard ready else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(50))
                        withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo(Self.streamsScrollID, anchor: UnitPoint(x: 0.5, y: 0.15)) }
                    }
                }
            }
        }
        .onGeometryChange(for: [CGFloat].self) {
            [$0.size.width, $0.safeAreaInsets.leading, $0.safeAreaInsets.trailing, $0.size.height, $0.safeAreaInsets.bottom,
             $0.safeAreaInsets.top]
        } action: { values in
            // Kept in state so a rotation lays the page out again with the new insets.
            sideInset = max(values[1], values[2])
            topInset = values[5]
            if abs(values[0] - layoutWidth) > 0.5 {
                layoutWidth = values[0]
                bottomPeak = 0
            }
            bottomPeak = max(bottomPeak, values[4])
            refreshBottomExtra()
        }
        // The settle scales the whole visible page about the screen's centre; the background behind it stays put.
        .heroSettle(trigger: hasSettled)
        .screenBackground()
        #if targetEnvironment(macCatalyst)
        // The artwork runs under the top bar, so the bar's material blurs the picture rather than sitting over a strip of its own.
        .ignoresSafeArea(.container, edges: .top)
        #else
        // The picture runs to the top of the screen in both orientations; the back button floats over it.
        .ignoresSafeArea(.container, edges: .top)
        #endif
        .scrollEdgeEffectHidden(true, for: .top)
        .pageTopBar(hidden: true)
        // Phone landscape uses the shared corner Back (RootTabView), the same size and place as on See All and category pages.
        .toolbarVisibility(isPhoneInLandscape ? .hidden : .automatic, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        // A detail page's landscape controls start tucked away and omit the title and divider already represented by its hero.
        .onAppear { landscapeTabs?.prepareForDetailPage() }
        .onChange(of: isPhoneInLandscape) { _, landscape in
            if landscape { landscapeTabs?.prepareForDetailPage() }
        }
        .onDisappear {
            landscapeTabs?.reset()
        }
        .task { await model.load(afterHero: { await loadHero() }, priorityStream: pendingStreams, prefetchOnOpen: true) }
        .task(id: "\(heroURL?.absoluteString ?? "-")|\(logoURL?.absoluteString ?? "-")|\(model.isLoadingArtwork)|\(showsBackdrop)") {
            await loadHero()
        }
        // The primary stream lookup is registered by the title loader only after the hero picture and logo.
        // Continue Watching gets its selected episode, not an unrelated prefetch. This task handles
        // picker presentation and later changes to the primary request without duplicating a live lookup.
        .task(id: "\(model.hasSettledHero)|\(model.primaryRequest?.id ?? "-")") {
            guard model.hasSettledHero else { return }
            if let request = pendingStreams {
                pendingStreams = nil
                // As if Play had been tapped: Play shows the spinner.
                streams.open(request)
                return
            }
            guard streams.request == nil else { return }
            await model.prefetchStreams(for: model.primaryRequest)
            // Shuffle's first episode is looked up next, so its first tap starts at once.
            if model.canShuffle { model.prepareShuffle() }
        }
        // IMDb's reviews load in the background once the hero has settled, so a tap on the IMDb rating shows them at once.
        .task(id: model.hasSettledHero) { preloadReviews() }
        // The picker's episode gets its season's scores asked for, since its card may never have come on screen, so the heading shows its score.
        .task(id: streams.request?.id) {
            guard let request = streams.request else { return }
            await model.prepareEpisodeScore(for: request)
        }
        .onAppear {
            // The initial load already reads progress after metadata arrives. Refresh only when returning
            // from another screen, rather than racing a second initial read against that load.
            if hasAppeared {
                Task { await model.refreshUserState() }
            } else {
                hasAppeared = true
            }
            if opensFromSpotlight { hasSettled = true }
            // Back on the page from a title opened from it: its IMDb reviews load again.
            preloadReviews()
        }
        .onDisappear {
            model.releaseStreamPrefetch()
            if let url = imdbReviewsURL { ReviewPreloader.shared.discard(url: url) }
            // A full-screen trailer covers the page without leaving it, so its player and source lookup stay.
            // Otherwise release unstructured season/trailer work as well as the player's load.
            if !model.trailer.isFullScreen {
                model.cancelOffscreenWork()
                model.trailer.cancel()
            }
        }
        .accessibilityIdentifier("detail.scroll")
        .youTubeTrailer(Bindable(model.trailer).youTubeHandoff)
        // A trailer that starts on a phone held sideways plays full screen, decided when it starts, so turning the phone later does not
        // move it. A YouTube trailer that ends or fails closes its cover. AVKit's player keeps its own end state until the cover is closed.
        .onChange(of: model.trailer.isPlaying) { _, playing in
            let fullScreen = playing && isPhoneInLandscape && model.trailer.playback != nil
            if fullScreen {
                // Set before the cover appears: the page is covered then, not left, so its trailer must not be closed.
                model.trailer.isFullScreen = true
                playerIsCovered = true
            }
            showsTrailerCover = fullScreen
        }
        // A trailer already playing inline goes full screen when the phone turns sideways, as one that starts then does.
        .onChange(of: isPhoneInLandscape) { _, landscape in
            guard landscape, model.trailer.isPlaying, model.trailer.playback != nil else { return }
            model.trailer.isFullScreen = true
            playerIsCovered = true
            showsTrailerCover = true
        }
        .fullScreenCover(isPresented: $showsTrailerCover, onDismiss: {
            // Remove the stopped panel without animating its empty frame onto the page.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.trailer.isFullScreen = false
                // The X gave its haptic, so the Trailer button does not tick as well.
                if isPhoneInLandscape { model.closeTrailerQuietly() }
                playerIsCovered = false
            }
        }) {
            TrailerFullScreenView(trailer: model.trailer) { showsTrailerCover = false }
        }
        // The app can switch tab while a trailer plays, for example when an addon link opens Settings. The page is then off screen, and
        // the disappear guard above has kept a covered trailer going, so it is stopped here. Keyed on the trailer, not the cover, since
        // the cover may already be gone in the same update. An inline trailer was cancelled by that disappear, so this does nothing there.
        .onChange(of: router.tab) { _, _ in
            guard model.trailer.isPlaying else { return }
            showsTrailerCover = false
            model.trailer.cancel()
        }
    }

    // MARK: - Reviews

    /// IMDb's reviews page for this title, which its IMDb rating opens. Nil for a title without an IMDb id.
    private var imdbReviewsURL: URL? {
        let item = model.detail.preview
        guard LetterboxdRatings.isIMDbID(item.id) else { return nil }
        return ReviewSite.imdb.reviewsURL(for: item)
    }

    /// Loads IMDb's reviews in the background, once the hero has settled and while the reviews are not already open.
    private func preloadReviews() {
        guard model.hasSettledHero, model.openedReviews == nil, let url = imdbReviewsURL else { return }
        ReviewPreloader.shared.preload(site: .imdb, url: url, item: model.detail.preview,
                                       width: max(0, (layoutWidth > 0 ? layoutWidth : 390) - contentMargin * 2))
    }

    // MARK: - Streams

    /// The id the page scrolls to once the streams are ready: an empty row just above the picker.
    private static let streamsScrollID = "detail.streams"

    /// True once the streams have taken the details' place.
    private var showsStreams: Bool { streams.showsStreams }

    /// What asked for the streams that are still loading, or nil when none are.
    private var loadingTrigger: StreamTrigger? { streams.loadingTrigger }

    /// Play starts loading this title's streams, and the trailer stops, since it would play behind them. The details stay, with a
    /// spinner in Play, until the streams are ready (`revealStreams`); a second tap while it spins calls the streams off. With Auto Pick
    /// on, the stream it chooses starts instead and the list never shows; the next tap picks again. The page does not scroll, and back
    /// still leaves the page, by the button or the swipe: the streams are part of the title's page, not a screen of their own.
    private func showStreams(_ request: StreamRequest, from trigger: StreamTrigger) {
        guard !unavailableStreams.contains(request.identity) else { return }
        model.trailer.cancel()
        // Play is the user's own choice, so it replaces a Continue Watching item still waiting for the hero to settle.
        pendingStreams = nil
        streams.show(request, from: trigger)
    }

    /// A series' episodes either side of the picker's, for its switcher. A step loads that episode's streams in place, as its card would,
    /// and the season list follows it, so closing the streams shows that episode's season. Nil for a film.
    private func episodeSwitcher(for request: StreamRequest) -> EpisodeSwitcher? {
        guard model.isSeries, request.season != nil, request.episode != nil else { return nil }
        let neighbours = model.neighbouringEpisodes(of: request)
        return EpisodeSwitcher(previous: neighbours.previous, next: neighbours.next) { episode in
            if let season = episode.season { model.selectedSeason = season }
            streams.switchEpisode(to: episode)
        }
    }

    /// Only a result with stream cards replaces the details. Empty movie and episode results stop the spinner in place.
    private func revealStreams(hasStreams: Bool, for request: StreamRequest) {
        guard streams.request?.identity == request.identity else { return }
        guard hasStreams else {
            unavailableStreams.insert(request.identity)
            streams.close()
            return
        }
        var revealed = streams
        guard revealed.reveal() else { return }
        withAnimation(Self.swapAnimation) { streams = revealed }
    }

    /// Takes the streams away and shows the details again. On Mac, Escape in the picker does this; on iPhone and iPad the streams are left by leaving
    /// the page.
    private func closeStreams() {
        withAnimation(Self.swapAnimation) { streams.close() }
    }

    // MARK: - Header

    /// The trailer's panel is the page's width less its margins. In landscape it is also kept to the screen's height at 16:9, so the panel
    /// never runs off the bottom of a short screen.
    private func trailerWidth(in size: CGSize) -> CGFloat {
        let fitting = max(0, size.width - contentMargin * 2)
        guard isLandscape else { return fitting }
        return min(fitting, max(160, size.height * 0.78) * 16 / 9)
    }

    /// Whether the page shows the wide backdrop rather than the tall poster. The Mac page always lays out full width, so it always uses the
    /// backdrop, whatever the window's shape; iPhone and iPad choose by orientation.
    private var showsBackdrop: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return isLandscape
        #endif
    }

    /// The main picture: the backdrop or the tall artwork, per `showsBackdrop`. Nil until the artwork lookup answers.
    private var heroURL: URL? { showsBackdrop ? model.backdropURL : model.portraitArtworkURL }

    /// The longest edge the hero is decoded to: full screen for the backdrop, the smaller size shared with Home in portrait.
    private var heroPixelSize: CGFloat { showsBackdrop ? TitleHero.landscapePixelSize : TitleHero.portraitPixelSize }

    /// Portrait only, and only when the picture carries the title: the logo is neither loaded nor drawn, its space is kept.
    private var hidesLogo: Bool { !showsBackdrop && model.portraitHidesLogo }
    private var logoURL: URL? { hidesLogo ? nil : model.logoURL }
    private var pictureSlot: HeroSlot { hero.slot(url: heroURL, maxPixelSize: heroPixelSize, lookupFinished: !model.isLoadingArtwork) }
    private var logoSlot: HeroSlot { hero.slot(url: logoURL, maxPixelSize: HeroLoader.logoPixelSize, lookupFinished: !model.isLoadingArtwork) }
    /// The picture and the logo are revealed together, once neither is still pending.
    private var isHeroRevealed: Bool { HeroLoader.isRevealed(pictureSlot, logoSlot) }

    /// The title page's own picture and logo are urgent: they skip the queue behind Home's posters, since the user is waiting on them.
    private func loadHero() async {
        await hero.load(urgent: true, picture: heroURL, pictureSize: heroPixelSize, logo: logoURL, logoSize: HeroLoader.logoPixelSize)
    }

    /// Titles TMDb recommends for this one, at the bottom of the page. Each opens its own page.
    private var related: some View {
        VStack(alignment: .leading, spacing: metrics.headerSpacing) {
            SectionHeader("More Like This")
                .padding(.horizontal, contentMargin)
            ShelfScroll(margin: contentMargin, spacing: metrics.cardSpacing) {
                if model.isLoadingRelated && model.relatedTitles.isEmpty {
                    ForEach(0..<6, id: \.self) { index in
                        RoundedRectangle(cornerRadius: Theme.Radius.poster)
                            .fill(Theme.placeholder)
                            .frame(width: metrics.posterWidth, height: metrics.posterWidth / CardAspect.poster.ratio)
                            .loadingCardSpinner()
                            .reportsShelfEdge(id: index)
                            .accessibilityLabel("Loading related title")
                    }
                }
                ForEach(model.relatedTitles) { title in
                    NavigationLink(value: title.titleDestination) {
                        MediaCard(item: title.preview, aspect: .poster, showsRating: false)
                    }
                    .buttonStyle(PressableCardStyle())
                    .titleTapHaptic()
                    .reportsShelfEdge(id: title.id)
                    .accessibilityIdentifier("detail.related.\(title.id)")
                }
            }
            .accessibilityIdentifier("detail.related")
            .environment(\.showsArtworkLoadingSpinner, true)
        }
    }
}

#endif
