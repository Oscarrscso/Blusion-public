#if canImport(UIKit)
import StremioKit
import SwiftUI
import UIKit

/// Home: the spotlight, then one section per widget of the user's layout (or the automatic one). Each section fills in as its addon
/// answers, and every state (loading, nothing installed, nothing to browse, an issue, offline) has a look of its own.
struct HomeView: View {
    @State private var model: HomeViewModel
    @State private var isScrolling = false
    /// How far Home has been pulled down past its top; the spotlight stretches by this much (see `HeroCarousel`).
    @State private var heroPull: CGFloat = 0
    /// The status bar's height, the top safe area Home's content starts beneath. The navigation bar sits below it, not included.
    @State private var topInset: CGFloat = 0
    /// The page's own side safe-area inset, as its geometry reports it: the notch's inset on a phone held in landscape, zero elsewhere.
    /// In landscape the page runs under it, so the spotlight reaches the screen's edges, and it is added to the page margin, so the
    /// headings and each shelf's first card stay clear of the notch where they were.
    @State private var sideInset: CGFloat = 0
    @Environment(AppRouter.self) private var router
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLandscape) private var isLandscape
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape
    @Environment(LandscapeTabBarState.self) private var landscapeTabs: LandscapeTabBarState?
    @Environment(TitleActions.self) private var actions: TitleActions?
    /// The widget editor opened from a row's menu.
    @State private var editing: HomeWidget?
    /// What a Continue Watching card's tap does, and the card whose streams are loading on Home.
    @State private var launcher: ContinueWatchingLauncher
    private let services: AppServices
    init(services: AppServices) {
        self.services = services
        _model = State(initialValue: HomeViewModel(services: services))
        _launcher = State(initialValue: ContinueWatchingLauncher(autoPickIsOn: { await services.settings.load().autoPlayBestStream }))
    }

    var body: some View {
        GeometryReader { geometry in
            content
                .environment(\.heroContainerHeight, geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom)
                // In landscape the page runs under its side insets, so the spotlight is that much wider than the safe width.
                .environment(\.heroContainerWidth, geometry.size.width
                    + (isLandscape ? geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing : 0))
                .environment(\.isHomeScrolling, isScrolling)
                .environment(\.layoutMetrics, homeMetrics)
        }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
            .onGeometryChange(for: CGFloat.self) { max($0.safeAreaInsets.leading, $0.safeAreaInsets.trailing) } action: { sideInset = $0 }
            .navigationTitle(heroIsFirst || isPhoneInLandscape ? "" : "Home")
            .navigationBarTitleDisplayMode(.inline)
            .pageTopBar(hidden: heroIsFirst || isPhoneLandscape)
            .toolbar(isPhoneInLandscape && landscapeTabs?.collapsed == true ? .hidden : .automatic, for: .tabBar)
            .task { await model.observeAddons() }
            // Auto Pick's switch is changed away from Home, so a Continue Watching card reads it again whenever Home shows.
            .task(id: scenePhase) { await launcher.refreshAutoPick() }
            .task(id: scenePhase == .active && router.tab == .home) {
                guard scenePhase == .active, router.tab == .home else { return }
                while !Task.isCancelled {
                    await model.refreshContinueWatching()
                    let interval = await model.continueWatchingRefreshInterval()
                    guard interval > 0 else { return }
                    do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                }
            }
            .onChange(of: actions?.watchedIdentities) { Task { await model.refreshContinueWatching() } }
            .onChange(of: router.userStateRevision) { _, _ in Task { await model.refreshContinueWatching() } }
            // Command-R on Mac reloads everything Home shows (see `HomeViewModel.refresh()`).
            .onChange(of: router.homeRefreshRevision) { _, _ in Task { await model.refresh() } }
            // Coming back from Settings or the Widgets tab: addons or widgets may have changed, and Home's own copy of them with them.
            .onChange(of: router.tab) { old, _ in
                if old == .settings || old == .widgets { Task { await model.load() } }
            }
            // The path shrinks when a title opened from the spotlight pops. Such a title opens and closes with no animation (see
            // `instantDestination()`), so the pop starts and ends together, and nothing is left to finish before Home resets. Resetting
            // during a zoom or a swipe that may still be cancelled would move the spotlight under the screen.
            .onChange(of: router.homePath.count) { _, count in
                guard let depth = router.spotlightDepth, count < depth else { return }
                router.spotlightDepth = nil
                router.spotlightRevision += 1
            }
            // The editor saves to the layout Home shows, so Home loads it again when the editor closes.
            .sheet(item: $editing, onDismiss: { Task { await model.load() } }) { widget in
                HomeWidgetEditor(widget: widget, services: services)
            }
            .background { continueStarter }
            // Leaving Home calls off a Continue Watching card's streams still loading, so nothing starts behind another page.
            .onDisappear { launcher.cancel() }
    }

    /// With Auto Pick on, a Continue Watching card's streams load here, in a stream picker that draws nothing and starts the stream Play
    /// would, in Infuse or here. It stays once a stream has started, since the player it opened belongs to it. When it has nothing to
    /// start, the title's page opens with the streams, where Play leaves them in that case.
    @ViewBuilder
    private var continueStarter: some View {
        if let launch = launcher.launch {
            StreamPickerView(request: launch.request, services: services, isEmbedded: true, isRevealed: false, isHeadless: true,
                             onAutomaticStart: { started in
                                 guard launcher.finish(launch.id, started: started) else { return }
                                 router.open(.home)
                                 router.homePath.append(TitleDestination(preview: launch.preview, sourceID: launch.sourceID,
                                                                         streams: launch.request))
                             })
                .id(launch.id)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// Home's page margin is the title page's content margin, so its headings, the Continue selector and the shelves line up with it.
    /// Shelves still scroll edge to edge; only their first and last cards are inset. In landscape the page runs under its side insets
    /// (see `ignoredEdges`), so the margin grows by that inset and everything but the spotlight's picture stays where it was.
    private var homeMetrics: LayoutMetrics {
        var homeMetrics = metrics
        homeMetrics.pageMargin = metrics.contentMargin + (isLandscape ? sideInset : 0)
        return homeMetrics
    }

    /// The edges the page runs under: the top when the spotlight leads, and in landscape the sides, so the spotlight's picture reaches
    /// the screen's edges instead of stopping at the notch's inset with a black bar beside it.
    private var ignoredEdges: Edge.Set {
        heroIsFirst ? sideEdges.union(.top) : sideEdges
    }

    /// The sides, in landscape: every state of Home runs under them, since the page margin already keeps its content clear of the notch.
    private var sideEdges: Edge.Set { isLandscape ? .horizontal : [] }

    /// A spotlight without a heading extends beneath the navigation bar, which is then clear and has no title; a visible heading stays
    /// below it, under an ordinary bar. This used to follow the scroll position too (the bar took a background and a title once the
    /// content moved past 160 pt), but changing the bar changes the insets the offset is measured against, so the offset crossed the
    /// threshold again and the bar changed again, without end: the Home freeze. Nothing about the bar depends on scrolling now.
    private var heroIsFirst: Bool {
        guard let first = model.sections.first, case .hero = first.widget.content else { return false }
        return first.widget.hideTitle
    }

    /// `isPhoneLandscape` is also true on an iPad turned sideways, so the device is checked as well. A phone in landscape has no room for
    /// a title over the shelves.
    private var isPhoneInLandscape: Bool { isPhoneLandscape && UIDevice.current.userInterfaceIdiom == .phone }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ScrollView { VStack(spacing: Theme.rowSpacing) { continueRow; Spinner() }.padding(.top, Theme.Spacing.m) }
                .screenBackground()
                .ignoresSafeArea(.container, edges: sideEdges)
        case .noAddons:
            ScrollView { VStack(spacing: Theme.rowSpacing) { continueRow; EmptyAddonsView(onOpenAddons: { router.showAddons() }) } }
                .screenBackground()
                .ignoresSafeArea(.container, edges: sideEdges)
        case .noCatalogs:
            ScrollView { VStack(spacing: Theme.rowSpacing) {
                continueRow
                EmptyStateView("Nothing to browse", systemImage: "rectangle.stack",
                           message: "None of your addons offers catalogs. Install one that does, or search by title.",
                           actionTitle: "Open Addons", action: { router.showAddons() })
                .accessibilityIdentifier("board.noCatalogs")
            } }
                .screenBackground()
                .ignoresSafeArea(.container, edges: sideEdges)
        case .ready:
            ready
        }
    }

    /// The id of Home's content, which its scroll goes back to when a title opened from the spotlight is popped.
    private static let topID = "home.top"

    private var ready: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: metrics.shelfSpacing) {
                    if !model.sections.contains(where: { if case .continueWatching = $0.widget.content { true } else { false } }) {
                        continueRow
                    }
                    if model.isOffline {
                        ForEach(Array(model.sections.enumerated()), id: \.element.id) { index, section in
                            if case .continueWatching = section.widget.content {
                                sectionView(section).prioritizesArtwork(order: index)
                            }
                        }
                        OfflineBanner()
                    } else {
                        ForEach(Array(model.sections.enumerated()), id: \.element.id) { index, section in
                            if model.isCustomised || !isEmptyRow(section) {
                                sectionView(section).prioritizesArtwork(order: index)
                            }
                        }
                    }
                }
                .padding(.bottom, Theme.Spacing.xxl)
                // In the content, not the navigation bar: it scrolls away with the page instead of staying pinned, and it is one glass
                // circle instead of a glass button inside the bar's own glass.
                #if !targetEnvironment(macCatalyst)
                // The Mac has Widgets in its sidebar, so Home carries no button for it there.
                .overlay(alignment: .topTrailing) { customizeButton }
                #endif
                .id(Self.topID)
            }
            .accessibilityIdentifier("board.rows")
            .onScrollGeometryChange(for: CGFloat.self) { max(0, -($0.contentOffset.y + $0.contentInsets.top)) } action: { _, value in
                heroPull = value
            }
            .environment(\.heroPull, heroIsFirst ? heroPull : 0)
            .trackLandscapeTabScroll()
            .onScrollPhaseChange { _, phase in isScrolling = phase.isScrolling }
            .onDisappear { isScrolling = false }
            .contentMargins(.top, 0, for: .scrollContent)
            .screenBackground()
            .scrollEdgeEffectHidden(heroIsFirst || isPhoneLandscape || HeroCarousel.isMacCatalyst, for: .top)
            .scrollEdgeEffectHidden(isPhoneInLandscape, for: .bottom)
            .ignoresSafeArea(.container, edges: ignoredEdges)
            .onChange(of: router.spotlightRevision) { _, _ in
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo(Self.topID, anchor: .top) }
            }
            // A tap on Home's tab item goes back to its first page, and scrolls it to the top.
            .onChange(of: router.tabTapRevisions[.home, default: 0]) { _, _ in
                withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo(Self.topID, anchor: .top) }
            }
        }
    }

    /// One round glass button that opens the widgets page, where widgets are added and edited: the navigation bar's button, in the
    /// page so that it scrolls away with it. It shows the app's icon, filling the circle.
    private var customizeButton: some View {
        Button {
            router.showWidgets()
        } label: {
            Image("BlusionIcon")
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: Theme.barButtonDiameter, height: Theme.barButtonDiameter)
                // A little larger than the circle, so the icon's own bevelled rim falls outside it; every point of the star stays inside.
                .scaleEffect(1.1)
                .clipShape(.circle)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(.circle)
                .pointerFeedback()
        }
        .buttonStyle(.plain)
        .padding(.trailing, homeMetrics.pageMargin)
        // With the spotlight first, the content starts at the top of the screen, so `topInset` (the status bar's height, which the navigation
        // bar starts beneath) puts the button's top where the title page's back button's top sits. Otherwise the bar is above the content.
        .padding(.top, heroIsFirst ? topInset : Theme.Spacing.s)
        .accessibilityLabel("Widgets")
        .help("Widgets")
        .accessibilityIdentifier("home.customize")
    }

    private func isEmptyRow(_ section: HomeViewModel.Section) -> Bool {
        guard case .row = section.widget.content, case .loaded(let items) = section.state else { return false }
        return items.isEmpty && section.issue == nil
    }

    @ViewBuilder
    private func sectionView(_ section: HomeViewModel.Section) -> some View {
        switch section.widget.content {
        case .hero:
            withWidgetMenu(HeroSection(section: section, onRetry: { retry(section) }), section)
                // The next shelf starts 20 pt below the hero: the shelf spacing that follows it, less the 20 pt gap wanted here.
                .padding(.bottom, 20 - metrics.shelfSpacing)
        case .banner(let row):
            // On iPhone a held card plays it, so the banner's menu is kept off its cards; the Mac's cards have their own menu.
            #if targetEnvironment(macCatalyst)
            withWidgetMenu(HeroBannerSection(section: section, row: row, onRetry: { retry(section) }), section)
            #else
            HeroBannerSection(section: section, row: row, onRetry: { retry(section) }, menu: AnyView(widgetMenu(section)))
            #endif
        case .row(let row):
            WidgetRow(section: section, row: row, onRetry: { retry(section) }, onSetBetterPosters: betterPostersSetter(for: section),
                      onRemove: { removeWidget(section) }, onEdit: { editing = section.widget }, onDuplicate: duplicateAction(for: section),
                      exportText: exportText(for: section))
        case .collection(let items):
            withWidgetMenu(CollectionRow(widget: section.widget, items: items, photos: model.tilePhotos), section)
        case .continueWatching:
            // Continue Watching is always shown at the top of Home when the layout leaves it out, so removing it would only move it: it is
            // edited here, not removed. A card's own menu (removing it from Continue Watching) opens where it is.
            withWidgetMenu(ContinueWatchingRow(items: model.continueEntries, state: model.continueState, retry: refreshPlayback,
                                               onRemove: removeContinue, onMarkWatched: markContinueWatched, title: section.widget.title, hideTitle: section.widget.hideTitle,
                                               launcher: launcher),
                           section, removable: false)
        case .unsupported:
            withWidgetMenu(UnsupportedWidgetRow(widget: section.widget), section)
        }
    }

    private var continueRow: some View {
        ContinueWatchingRow(items: model.continueEntries, state: model.continueState, retry: refreshPlayback, onRemove: removeContinue, onMarkWatched: markContinueWatched,
                            launcher: launcher)
    }

    /// The Better Posters menu of a row, offered only once the layout is saved: the automatic layout is not saved by a change.
    private func betterPostersSetter(for section: HomeViewModel.Section) -> ((Bool) -> Void)? {
        guard model.isCustomised else { return nil }
        return { on in Task { await model.setBetterPosters(on, sectionID: section.id) } }
    }

    private func refreshPlayback() { Task { await model.refreshContinueWatching(force: true) } }

    private func removeContinue(_ item: ContinueWatchingEntry) { Task { await model.removeFromContinueWatching(item) } }

    private func markContinueWatched(_ item: ContinueWatchingEntry) {
        Task {
            await model.markWatched(item)
            await actions?.refresh()
        }
    }

    private func removeWidget(_ section: HomeViewModel.Section) { Task { await model.removeWidget(sectionID: section.id) } }

    /// The widget as saved, as text for Import Widgets: its own settings, not the order or source Home picked for it today. Nil for
    /// Continue Watching, which every layout has.
    private func exportText(for section: HomeViewModel.Section) -> String? {
        guard !HomeLayout.isContinueWatching(section.widget) else { return nil }
        return WidgetsManagerViewModel.exportJSON(of: model.layoutWidgets[section.id] ?? section.widget)
    }

    /// Duplicates a widget from its menu, with a light tap, or nil for Continue Watching and the showcase, which are one of a kind.
    private func duplicateAction(for section: HomeViewModel.Section) -> (() -> Void)? {
        guard WidgetsManagerViewModel.isDuplicable(section.widget) else { return nil }
        return {
            Haptics.tap()
            Task { await model.duplicateWidget(sectionID: section.id) }
        }
    }

    /// The long-press menu every widget shares, on a widget whose own menus are on its cards or none. A card's menu opens where it is.
    private func withWidgetMenu<Content: View>(_ content: Content, _ section: HomeViewModel.Section, removable: Bool = true) -> some View {
        content.contextMenu { widgetMenu(section, removable: removable) }
    }

    /// What every widget's menu offers, for `section`.
    private func widgetMenu(_ section: HomeViewModel.Section, removable: Bool = true) -> some View {
        let onRemove: (() -> Void)? = removable ? { removeWidget(section) } : nil
        return widgetActions(for: section.widget, onEdit: { editing = section.widget }, onDuplicate: duplicateAction(for: section),
                             exportText: exportText(for: section), onRemove: onRemove)
    }

    private func retry(_ section: HomeViewModel.Section) {
        Task { await model.retry(sectionID: section.id) }
    }
}

/// The widget editor for one Home row, opened from the row's menu. It is the widgets page's editor, with its own widgets model. The model
/// loads first, since the editor reads the addons and catalogs that loading finds.
private struct HomeWidgetEditor: View {
    let widget: HomeWidget
    let services: AppServices
    @State private var model: WidgetsManagerViewModel
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss

    init(widget: HomeWidget, services: AppServices) {
        self.widget = widget
        self.services = services
        _model = State(initialValue: WidgetsManagerViewModel(services: services))
    }

    var body: some View {
        NavigationStack {
            Group {
                if loaded {
                    // The saved copy of the row, in case the layout changed since Home loaded.
                    WidgetEditorView(widget: model.widgets.first(where: { $0.id == widget.id }) ?? widget, model: model, services: services)
                } else {
                    Spinner()
                }
            }
            // The title shows while the editor loads, matching the editor's own title once it loads.
            .navigationTitle("Edit Widget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task {
            await model.load()
            loaded = true
        }
    }
}

#endif
