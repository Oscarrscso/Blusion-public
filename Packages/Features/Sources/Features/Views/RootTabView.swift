#if canImport(UIKit)
import Persistence
import SwiftUI
import StremioKit

/// Screens reachable from the Settings tab's stack.
enum SettingsDestination: Hashable {
    case addons
    case widgets
}

/// App-level navigation state, shared through the environment so any screen can switch tab or open Settings.
@MainActor
@Observable
public final class AppRouter {
    public var tab: LaunchRoute.Tab
    public var homePath = NavigationPath()
    var searchPath = NavigationPath()
    var discoverPath = NavigationPath()
    var libraryPath = NavigationPath()
    var searchBrowseRevision = 0
    var searchFocusRevision = 0
    /// Counts the titles opened from Search, so the Search screen reads its recent searches again.
    var recentSearchRevision = 0
    /// Untyped, because screens inside Settings push values of their own (an addon's id, a widget).
    var settingsPath = NavigationPath()
    /// The Mac Widgets tab's stack. The widgets manager registers its own editor destinations, so the stack holds nothing else.
    var widgetsPath = NavigationPath()
    var demoPlan: PlaybackPlan?
    var addonInstallText: String?
    var userStateRevision = 0
    /// The depth of `homePath` once a title opened from Home's spotlight is on it. When the path falls below that depth, the spotlight's
    /// title has been popped and Home is back, see `HomeView`.
    var spotlightDepth: Int?
    /// Counts the returns to Home from a spotlight title. The spotlight and Home's scroll reset to their first page and top on each.
    var spotlightRevision = 0
    /// Counts the taps on each tab's item, the selected tab's included. The tab's first page scrolls to its top on each, see `tapTab(_:)`.
    private(set) var tabTapRevisions: [LaunchRoute.Tab: Int] = [:]
    /// The depths at which a title's page sits in each stack, by its path. A title's page has no tab bar and no Continue Watching bar
    /// while it is on top, and both start coming back the moment it is left, as its path shrinks (see `titlePage(on:)`).
    var titlePageDepths: [ReferenceWritableKeyPath<AppRouter, NavigationPath>: Set<Int>] = [:]

    /// The stack each tab shows.
    func pathKey(for tab: LaunchRoute.Tab) -> ReferenceWritableKeyPath<AppRouter, NavigationPath> {
        switch tab {
        case .home: \.homePath
        case .search: \.searchPath
        case .discover: \.discoverPath
        case .library: \.libraryPath
        case .settings: \.settingsPath
        case .widgets: \.widgetsPath
        }
    }

    /// True while the selected tab has a title's page on top.
    var showsTitlePage: Bool {
        let path = pathKey(for: tab)
        return titlePageDepths[path]?.contains(self[keyPath: path].count) ?? false
    }
    /// Navigation values must wait until their stacks and destinations have appeared.
    private var pendingLaunchRoute: LaunchRoute?

    public init(route: LaunchRoute = .home) {
        tab = route.tab
        pendingLaunchRoute = route
    }

    /// The root selects the launch tab; Home consumes its navigation values only after its stack appears.
    func presentLaunchRoute(includeHomeDestinations: Bool = true) {
        guard let route = pendingLaunchRoute else { return }
        guard !includeHomeDestinations || route.tab == .home else { return }
        guard !includeHomeDestinations || route.detail != nil || route.streams != nil || route.showsGallery else { return }
        tab = route.tab
        guard includeHomeDestinations || (route.detail == nil && route.streams == nil && !route.showsGallery) else { return }
        pendingLaunchRoute = nil
        if let detail = route.detail { homePath.append(detail) }
        if let streams = route.streams { homePath.append(streams) }
        if route.showsGallery { homePath.append(GalleryDestination(section: route.gallerySection)) }
        if route.showsPlayerDemo { demoPlan = .demo }
        if let screen = route.sheet { showSettings(screen) }
    }

    public func open(_ tab: LaunchRoute.Tab) { self.tab = tab }

    /// A tap on a tab's item. Every tap scrolls that tab's first page to its top (see `tabTapRevisions`), except Widgets, which has no
    /// scroll to reset and restarts its stack instead. Tapping the tab that is showing
    /// also takes it back to its first page; switching to another tab keeps its stack, so a title or a draft on it is still there when
    /// it returns. Widgets is the exception: its stack restarts on each selection, so a draft on it does not survive a return. Search starts afresh on every tap: its browse page, or with its field focused when it was already showing.
    func tapTab(_ tab: LaunchRoute.Tab) {
        let isShowing = self.tab == tab
        switch tab {
        // A title opened from the spotlight closes with no animation, as its own back button closes it (see `goBack`).
        case .home: if isShowing { popToRoot(\.homePath, instantly: spotlightDepth != nil) }
        case .discover: if isShowing { popToRoot(\.discoverPath) }
        case .library: if isShowing { popToRoot(\.libraryPath) }
        case .settings: if isShowing { popToRoot(\.settingsPath) }
        // Widgets restarts on each selection, not only on a tap of the showing tab: an editor parked on its stack can hold a copy from
        // before a change made on another tab, so it is not kept.
        case .widgets: popToRoot(\.widgetsPath, instantly: true)
        case .search:
            // Every tap on Search brings the keyboard up. Coming from another tab it also starts afresh, on an empty field.
            popToRoot(\.searchPath)
            if !isShowing { searchBrowseRevision += 1 }
            searchFocusRevision += 1
        }
        tabTapRevisions[tab, default: 0] += 1
        self.tab = tab
    }

    private func popToRoot(_ path: ReferenceWritableKeyPath<AppRouter, NavigationPath>, instantly: Bool = false) {
        guard !self[keyPath: path].isEmpty else { return }
        guard instantly else {
            self[keyPath: path] = NavigationPath()
            return
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { self[keyPath: path] = NavigationPath() }
    }

    /// The one way back in a stack: the back swipe and the spotlight title's own back button both pop here, so one gesture never pops
    /// twice. A title opened from Home's spotlight with no animation closes with none (see `instantDestination()`); every other screen
    /// closes with its own transition. True when a screen was popped, so the caller knows that screen is on its way out; false when
    /// there was nothing to pop.
    @discardableResult
    func goBack(in path: ReferenceWritableKeyPath<AppRouter, NavigationPath>) -> Bool {
        guard !self[keyPath: path].isEmpty else { return false }
        guard path == \AppRouter.homePath, spotlightDepth == homePath.count else {
            self[keyPath: path].removeLast()
            return true
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { homePath.removeLast() }
        return true
    }

    /// Back on the tab that is showing: pops its stack by one screen, as the back swipe does. False when there was nothing to pop.
    @discardableResult
    func goBackOnTab() -> Bool {
        switch tab {
        case .home: return goBack(in: \.homePath)
        case .discover: return goBack(in: \.discoverPath)
        case .library: return goBack(in: \.libraryPath)
        case .settings: return goBack(in: \.settingsPath)
        case .widgets: return goBack(in: \.widgetsPath)
        case .search: return goBack(in: \.searchPath)
        }
    }

    /// Home reloads everything it shows, as a pull from the top would (see `HomeView`).
    var homeRefreshRevision = 0

    func refreshHome() { homeRefreshRevision += 1 }

    /// The Search tab on its category browser, as if the tab had been tapped from another tab.
    func showSearchBrowse() {
        searchPath = NavigationPath()
        searchBrowseRevision += 1
        tab = .search
    }

    /// The Settings tab, on its first screen.
    public func showSettings() { showSettings(.settings) }

    /// The Settings tab, opened on the addons list.
    public func showAddons() { showSettings(.addons) }

    /// The Settings tab, opened on the Home widgets manager.
    public func showWidgets() { showSettings(.widgets) }

    private func showSettings(_ screen: LaunchRoute.Sheet) {
        switch screen {
        case .settings: settingsPath = NavigationPath()
        case .addons: settingsPath = NavigationPath([SettingsDestination.addons])
        case .widgets: settingsPath = NavigationPath([SettingsDestination.widgets])
        }
        tab = .settings
    }
}

/// The component gallery's place in a navigation stack (debug aid, see `DesignGalleryView`).
struct GalleryDestination: Hashable {
    var section: String?
}

/// The tab bar collapses to Home after scrolling down on a landscape iPhone.
@MainActor
@Observable
final class LandscapeTabBarState {
    var collapsed = false
    /// The current pushed browse/picker page, shown on top of the landscape panel.
    var pageTitle: String?
    /// The browse-page title hidden while a title detail is on top of it.
    private var suspendedPageTitle: String?
    /// A detail page stays tucked away through its initial downward scroll and expands only when the user reverses upward.
    private var waitsForUpwardScroll = false
    private var previousOffset: CGFloat?
    private var distanceDown: CGFloat = 0
    private var distanceUp: CGFloat = 0

    func showPageTitle(_ title: String) {
        pageTitle = title
        suspendedPageTitle = nil
    }

    func clearPageTitle() {
        pageTitle = nil
        suspendedPageTitle = nil
    }

    func reset() {
        collapsed = false
        waitsForUpwardScroll = false
        previousOffset = nil
        distanceDown = 0
        distanceUp = 0
    }

    func prepareForDetailPage() {
        collapsed = true
        waitsForUpwardScroll = true
        if let pageTitle { suspendedPageTitle = pageTitle }
        pageTitle = nil
        previousOffset = nil
        distanceDown = 0
        distanceUp = 0
    }

    func restoreAfterDetailPage() {
        reset()
        pageTitle = suspendedPageTitle
        suspendedPageTitle = nil
    }

    func update(offset: CGFloat) {
        let offset = max(0, offset)
        guard offset > 8 else {
            if waitsForUpwardScroll {
                previousOffset = offset
                distanceDown = 0
                distanceUp = 0
            } else {
                reset()
            }
            return
        }
        guard let previousOffset else { self.previousOffset = offset; return }
        self.previousOffset = offset
        let difference = offset - previousOffset
        // A tab-bar visibility change can relayout the scroll view. Ignore jumps instead of treating them as scrolling.
        guard abs(difference) < 100 else { return }
        if difference > 1 {
            distanceDown += difference
            distanceUp = 0
            if distanceDown >= 35 { collapsed = true; distanceDown = 0 }
        } else if difference < -1 {
            distanceUp -= difference
            distanceDown = 0
            // Scrolling back up brings the icons back almost at once.
            if distanceUp >= 12 {
                collapsed = false
                waitsForUpwardScroll = false
                distanceUp = 0
            }
        }
    }

    /// How far the landscape buttons (Back, Home and its panel, Search) sit from the screen's two edges at their corner: a 44-point
    /// round button whose edge keeps an even 6-point gap from the curve of an iPhone's roughly 55-point screen corner. They sit out in the
    /// corners, past the safe area at the sides, rather than over the page.
    static let cornerInset: CGFloat = 14
    /// The landscape Back button's corner gap and 44-point height. A page whose navigation bar is hidden in phone landscape starts its
    /// content below this, so the button sits clear of the artwork at rest.
    static let backClearance: CGFloat = cornerInset + 44
}

private struct LandscapeTabScrollModifier: ViewModifier {
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape
    @Environment(LandscapeTabBarState.self) private var landscapeTabs: LandscapeTabBarState?

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self) {
            max(0, $0.contentOffset.y + $0.contentInsets.top)
        } action: { _, offset in
            guard isPhoneLandscape, UIDevice.current.userInterfaceIdiom == .phone else { return }
            landscapeTabs?.update(offset: offset)
        }
    }
}

extension View {
    func trackLandscapeTabScroll() -> some View {
        modifier(LandscapeTabScrollModifier())
    }
}

/// A phone gets the plain tab bar, where Search always stands apart from the other tabs as a button of its own. The sidebar style, which
/// an iPad and the Mac need, drew Search inside the bar with the rest on a phone whenever the bar was at full size.
private struct TabBarStyle: ViewModifier {
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            content.tabViewStyle(.tabBarOnly)
        } else {
            content.tabViewStyle(.sidebarAdaptable)
        }
    }
}

/// Landscape controls: one glass panel with the page's title on top, a hairline, and Home with the tab icons below. Scrolling down fades
/// the panel, title and icons away and leaves Home alone in the corner; scrolling up brings them straight back. Home is mounted at one
/// size and position for the whole scroll, and the panel grows upward from the bottom row, so Home never moves and no native tab-bar
/// relayout occurs.
private struct LandscapeTabControls: View {
    let router: AppRouter
    let collapsed: Bool
    let title: String
    let hidesPageHeader: Bool
    let onHome: () -> Void

    /// Home and three tab icons, 44 points each, 12 apart.
    private static let panelContentWidth: CGFloat = 44 * 4 + 12 * 3
    /// The panel's corners match Home's round end in the bottom-leading corner.
    private static let panelShape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    /// Collapsing shrinks the panel smoothly back into Home; expanding pops it out of Home on a soft spring.
    static func fade(collapsed: Bool) -> Animation {
        collapsed ? .smooth(duration: 0.3) : .spring(duration: 0.38, bounce: 0.18)
    }
    /// How small the panel (and Search) are while tucked away, grown from their corner.
    static let tuckedScale: CGFloat = 0.6

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 0) {
                if !hidesPageHeader {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 6)
                        .padding(.top, 11)
                        .padding(.bottom, 9)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("landscape.pageTitle")
                    Rectangle()
                        .fill(.white.opacity(0.3))
                        .frame(height: 0.5)
                        // A little gap so the line clears the round buttons below it.
                        .padding(.bottom, 6)
                }
                HStack(spacing: 12) {
                    Color.clear.frame(width: 44, height: 44)
                    tabButton(.discover, symbol: "square.grid.2x2", selectedSymbol: "square.grid.2x2.fill", title: "Discover")
                    tabButton(.library, symbol: "books.vertical", selectedSymbol: "books.vertical.fill", title: "Library")
                    tabButton(.settings, symbol: "gearshape", selectedSymbol: "gearshape.fill", title: "Settings")
                }
            }
            .frame(width: Self.panelContentWidth)
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .opacity(collapsed ? 0 : 1)
            // The clearer, more see-through variant of Liquid Glass; it clears away with the rest when scrolled.
            .glassEffect(collapsed ? .identity : .clear, in: Self.panelShape)
            .scaleEffect(collapsed ? Self.tuckedScale : 1, anchor: .bottomLeading)
            .allowsHitTesting(!collapsed)
            .accessibilityHidden(collapsed)
            .animation(Self.fade(collapsed: collapsed), value: collapsed)

            // This is the same instance in both states: it never moves, scales or changes glass.
            Button {
                Haptics.tap()
                onHome()
            } label: {
                Image(systemName: router.tab == .home ? "play.house.fill" : "play.house")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(router.tab == .home ? Color(red: 0.50, green: 0.59, blue: 1) : .white)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Home")
            .accessibilityIdentifier("landscape.home")
        }
    }

    private func tabButton(_ tab: LaunchRoute.Tab, symbol: String, selectedSymbol: String, title: String) -> some View {
        Button {
            Haptics.tap()
            router.tapTab(tab)
        } label: {
            Image(systemName: router.tab == tab ? selectedSymbol : symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(router.tab == tab ? Color(red: 0.50, green: 0.59, blue: 1) : .white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("landscape.\(title.lowercased())")
    }
}

public struct RootTabView: View {
    private let services: AppServices
    private let initialQuery: String?
    private let initialRoute: LaunchRoute
    private let userStateRevision: Int
    @Binding private var addonLink: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var router: AppRouter
    /// The app-level holder of the playback session on the air, so backgrounding or a rebuild of the player's screen never ends
    /// playback (see `LivePlaybackSession`).
    @State private var livePlayback = LivePlaybackSession()
    @State private var landscapeTabs = LandscapeTabBarState()
    @State private var resume: ContinueWatchingModel
    @State private var titleActions: TitleActions
    @State private var failedHandoff: PlaybackHandoffReceipt?
    /// A poster held for a second plays: its streams load in `posterStarter`, which draws nothing.
    @State private var posterPlay: PosterPlayLauncher
    @State private var isLandscape = false
    @State private var windowSafeArea = EdgeInsets()
    @State private var windowWidth: CGFloat = 0
    /// A phone turned sideways. A Mac window is never a phone, so `isPhoneLandscape` never governs its navigation bar, at any window shape.
    private var isPhoneLandscape: Bool { isLandscape && !Self.isMacCatalyst }
    private var isPhoneInLandscape: Bool { isPhoneLandscape && UIDevice.current.userInterfaceIdiom == .phone }
    private static var isMacCatalyst: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }
    /// Home, the landscape panel, Search and Back keep this distance from the screen's sides: the corner gap plus 1.5% of the width, so
    /// they sit a little in from the far edges rather than against them. Their distance from the top and bottom stays the corner gap.
    private var landscapeEdgeInset: CGFloat { LandscapeTabBarState.cornerInset + (windowWidth * 0.015).rounded() }
    /// Only category pages put a heading above the landscape controls. Root tabs and other pushed pages need no repeated context label.
    private var landscapeTitle: String { landscapeTabs.pageTitle ?? "" }
    /// A page pushed on a browsing tab's stack, other than a title's page, in phone landscape: its navigation bar is hidden there and
    /// Back is drawn above Home instead.
    private var showsLandscapeBack: Bool {
        guard isPhoneInLandscape else { return false }
        switch router.tab {
        case .home, .discover, .library, .search: return !router[keyPath: router.pathKey(for: router.tab)].isEmpty
        case .settings, .widgets: return false
        }
    }
    /// Phones show each tab's icon alone (see `tabItem`). The iPad and the Mac keep the titles, as their sidebar rows need them.
    private var showsTabTitles: Bool { UIDevice.current.userInterfaceIdiom != .phone }

    public init(services: AppServices, route: LaunchRoute = .home, addonLink: Binding<String?> = .constant(nil), userStateRevision: Int = 0) {
        self.services = services
        self.userStateRevision = userStateRevision
        _addonLink = addonLink
        initialQuery = route.searchQuery
        initialRoute = route
        _router = State(initialValue: AppRouter(route: route))
        _resume = State(initialValue: ContinueWatchingModel(services: services))
        _titleActions = State(initialValue: TitleActions(services: services))
        _posterPlay = State(initialValue: PosterPlayLauncher(services: services, failed: {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }))
    }

    /// A held poster's streams load here, in a picker that draws nothing and starts the stream Play would, in Infuse or here, whatever
    /// Auto Pick's switch says. It stays once a stream has started, since the player it opened belongs to it.
    @ViewBuilder
    private var posterStarter: some View {
        if let launch = posterPlay.launch {
            StreamPickerView(request: launch.request, services: services, isEmbedded: true, isRevealed: false, isHeadless: true,
                             forcesAutomaticStart: true, onAutomaticStart: { started in posterPlay.finish(launch.id, started: started) })
                .id(launch.id)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    public var body: some View {
        @Bindable var router = router
        TabView(selection: Binding(get: { router.tab }, set: {
            Haptics.selection()
            router.tapTab($0)
        })) {
            Tab(value: LaunchRoute.Tab.home) {
                NavigationStack(path: $router.homePath) {
                    HomeView(services: services)
                        .appDestinations(services: services, path: \.homePath)
                        .navigationDestination(for: GalleryDestination.self) { DesignGalleryView(section: $0.section) }
                        .navigationDestination(for: PlayerRecovery.self) { recovery in
                            StreamPickerView(request: recovery.request, services: services,
                                             forcesAutomaticStart: recovery.resumesSession,
                                             allowsAutomaticStart: recovery.resumesSession)
                        }
                }
                .zoomTransitions()
                .task {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    router.presentLaunchRoute()
                }
            } label: {
                tabItem("Home", router.tab == .home ? "play.house.fill" : "play.house")
            }
            Tab(value: LaunchRoute.Tab.discover) {
                NavigationStack(path: $router.discoverPath) {
                    DiscoverView(services: services) { router.showAddons() }
                        .appDestinations(services: services, path: \.discoverPath)
                }
                .zoomTransitions()
            } label: {
                tabItem("Discover", router.tab == .discover ? "square.grid.2x2.fill" : "square.grid.2x2")
            }
            TabSection("Library") {
                Tab(value: LaunchRoute.Tab.library) {
                    NavigationStack(path: $router.libraryPath) {
                        LibraryView(services: services) { router.open(.discover) }
                            .appDestinations(services: services, path: \.libraryPath)
                    }
                    .zoomTransitions()
                } label: {
                    tabItem("Library", router.tab == .library ? "books.vertical.fill" : "books.vertical")
                }
            }
            // Settings is a tab like the rest, so there is no sheet to dismiss and no Done button.
            Tab(value: LaunchRoute.Tab.settings) {
                NavigationStack(path: $router.settingsPath) {
                    SettingsView(services: services)
                        .navigationDestination(for: SettingsDestination.self) { destination in
                            Group {
                                switch destination {
                                case .addons: AddonsView(services: services)
                                case .widgets: WidgetsManagerView(services: services)
                                }
                            }
                        }
                }
            } label: {
                tabItem("Settings", router.tab == .settings ? "gearshape.fill" : "gearshape")
            }
            #if targetEnvironment(macCatalyst)
            // The Mac sidebar's Widgets item, at its bottom. On iPhone the widgets manager stays in Settings and behind Home's button.
            Tab(value: LaunchRoute.Tab.widgets) {
                NavigationStack(path: $router.widgetsPath) {
                    // Selecting the tab rebuilds the manager, so it loads what is saved now, not a copy from before a Settings edit.
                    WidgetsManagerView(services: services)
                        .id(router.tabTapRevisions[.widgets, default: 0])
                }
                .zoomTransitions()
            } label: {
                Label {
                    Text("Widgets")
                } icon: {
                    Image(systemName: router.tab == .widgets ? "rectangle.3.group.fill" : "rectangle.3.group")
                        .environment(\.symbolVariants, .none)
                }
            }
            #endif
            Tab(value: LaunchRoute.Tab.search, role: .search) {
                NavigationStack(path: $router.searchPath) {
                    SearchView(services: services, initialQuery: initialQuery)
                        .appDestinations(services: services, path: \.searchPath)
                }
                .zoomTransitions()
            }
        }
        .modifier(TabBarStyle())
        // Choosing Search goes straight to its field, with the keyboard up.
        .tabViewSearchActivation(.searchTabSelection)
        .scrollEdgeEffectHidden(isPhoneLandscape || Self.isMacCatalyst, for: .top)
        .scrollEdgeEffectHidden(isPhoneInLandscape, for: .bottom)
        .pageTopBar(hidden: isPhoneLandscape)
        .tabBarMinimizeBehavior(isPhoneInLandscape ? .never : .onScrollDown)
        .toolbar(isPhoneInLandscape ? .hidden : .automatic, for: .tabBar)
        .modifier(ResumeAccessoryModifier(model: resume, hidden: router.showsTitlePage, isPhoneLandscape: isPhoneInLandscape))
        // The native bar stays hidden for *all* landscape scroll states. Replacing it mid-scroll
        // changes safe-area geometry and is what made the old detached Home button jump.
        .overlay(alignment: .bottom) {
            // Category pages add their heading above the panel; root tabs and other pushed pages show the controls alone.
            if isPhoneInLandscape {
                HStack(alignment: .bottom) {
                    LandscapeTabControls(router: router, collapsed: landscapeTabs.collapsed, title: landscapeTitle,
                                         hidesPageHeader: landscapeTabs.pageTitle?.isEmpty != false,
                                         onHome: { landscapeTabs.reset(); router.tapTab(.home) })
                    Spacer(minLength: 0)
                    Button {
                        Haptics.tap()
                        router.tapTab(.search)
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 21, weight: .medium))
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .accessibilityLabel("Search")
                    .accessibilityIdentifier("landscape.search")
                    .opacity(landscapeTabs.collapsed ? 0 : 1)
                    .scaleEffect(landscapeTabs.collapsed ? LandscapeTabControls.tuckedScale : 1, anchor: .bottomTrailing)
                    .allowsHitTesting(!landscapeTabs.collapsed)
                    .accessibilityHidden(landscapeTabs.collapsed)
                    .animation(LandscapeTabControls.fade(collapsed: landscapeTabs.collapsed), value: landscapeTabs.collapsed)
                }
                .padding(.horizontal, landscapeEdgeInset)
                // Measured from the screen's bottom edge, not the home indicator's safe area, so Home and Search sit in the corners.
                .padding(.bottom, LandscapeTabBarState.cornerInset)
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        // Back sits in the top corner, in the same column as Home in the bottom one, on every pushed page in phone landscape (title pages,
        // See All grids, categories and the stream picker), whose navigation bars are hidden there, so it is the same button everywhere.
        .overlay(alignment: .topLeading) {
            if showsLandscapeBack {
                Button {
                    Haptics.tap()
                    router.goBackOnTab()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("landscape.back")
                .padding(.top, LandscapeTabBarState.cornerInset)
                .padding(.leading, landscapeEdgeInset)
                .ignoresSafeArea(.container, edges: .top)
                .transition(.opacity)
            }
        }
        .onChange(of: router.tab) { _, _ in
            landscapeTabs.reset()
            landscapeTabs.clearPageTitle()
        }
        .onChange(of: router.showsTitlePage) { _, showsTitlePage in
            if showsTitlePage {
                landscapeTabs.prepareForDetailPage()
            } else {
                landscapeTabs.restoreAfterDetailPage()
            }
        }
        .onChange(of: isPhoneInLandscape) { _, landscape in
            if landscape, router.showsTitlePage {
                landscapeTabs.prepareForDetailPage()
            } else {
                landscapeTabs.reset()
            }
        }
        .task(id: "\(router.tab)-\(userStateRevision)") {
            router.userStateRevision = userStateRevision
            await refreshUserState()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshUserState() } }
        }
        .onChange(of: titleActions.watchedIdentities) { _, _ in
            Task { await resume.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackHandoffDidFinish)) { notification in
            guard let receipt = notification.object as? PlaybackHandoffReceipt else { return }
            if case .failed = receipt.result { failedHandoff = receipt }
        }
        .alert(failedHandoff?.handoff.action == .download ? "Couldn’t start download in Infuse"
               : failedHandoff?.handoff.action == .save ? "Couldn’t save to Infuse" : "Infuse couldn’t play this stream",
               isPresented: Binding(get: { failedHandoff != nil }, set: { if !$0 { failedHandoff = nil } }),
               presenting: failedHandoff) { receipt in
            if receipt.handoff.isPlayback {
                Button("Choose another stream") {
                    router.tab = .home
                    router.homePath.append(PlayerRecovery(request: receipt.handoff.request))
                }
            }
            Button("OK", role: .cancel) {}
        } message: { receipt in
            if case .failed(_, let message) = receipt.result {
                Text(message ?? "Infuse reported an error. Try another stream.")
            }
        }
        .onChange(of: addonLink, initial: true) { _, link in
            guard let link else { return }
            router.addonInstallText = link
            router.showAddons()
            addonLink = nil
        }
        .fullScreenCover(item: $router.demoPlan) { PlayerScreen(plan: $0, services: services) }
        .background { posterStarter }
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            router.presentLaunchRoute(includeHomeDestinations: false)
            await reopenPreviousSession()
            #if canImport(UIKit)
            // The reviews page's rules and WebKit's process start now, after the first frame, so the first reviews page waits for neither.
            ReviewPageRules.prewarm()
            #endif
        }
        .environment(router)
        .environment(livePlayback)
        .environment(landscapeTabs)
        .environment(services.posterRatings)
        .environment(services.heroMeta)
        .environment(titleActions)
        .environment(posterPlay)
        .environment(\.isLandscape, isLandscape)
        .environment(\.isPhoneLandscape, isPhoneLandscape)
        .environment(\.windowSafeArea, windowSafeArea)
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isLandscape = $0 }
        // The full screen width (this sits inside the edge-to-edge line below), for the landscape buttons' side gap.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .focusedSceneValue(router)
        .preferredColorScheme(.dark)
        // Screens run edge to edge, including the sides of a landscape iPhone. Only the navigation bar and tab bar keep their safe area.
        .ignoresSafeArea(.container, edges: .horizontal)
        // Read outside the line above: inside it, the sides are no longer a safe area to report. Screens that run under the notch or the
        // status bar take these from the environment (see `windowSafeArea`).
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { windowSafeArea = $0 }
    }

    /// A tab's item. On a phone the tab bar shows the icon alone, and the title stays the item's accessibility label, which the UI tests
    /// find by. The sidebar shows the title beside the icon.
    private func tabItem(_ title: LocalizedStringKey, _ symbol: String) -> some View {
        Group {
            if showsTabTitles {
                Label { Text(title) } icon: { Image(systemName: symbol) }
            } else {
                Image(systemName: symbol).accessibilityLabel(title)
            }
        }
        .environment(\.symbolVariants, .none)
    }

    /// The app was killed with a stream playing: opening it again walks back into that stream, at its position and choices. The picker
    /// resolves the same file from a fresh listing; when it cannot, it shows the list and the position stays in progress. A launch route
    /// (a deep link, a title, the gallery) is what the person asked for, so it is never displaced.
    private func reopenPreviousSession() async {
        #if DEBUG
        // UI tests drive their own launches and must not inherit the device's saved session.
        if ProcessInfo.processInfo.environment["BLUSION_UITEST"] == "1" { return }
        #endif
        guard initialRoute == .home, let snapshot = await PlaybackSession.load() else { return }
        guard !snapshot.isEffectivelyFinished() else {
            await PlaybackSession.clear()
            return
        }
        router.tab = .home
        router.homePath.append(PlayerRecovery(request: snapshot.request, resumesSession: true))
    }

    private func refreshUserState() async {
        let progress = await services.progress.all()
        resume.update(from: progress)
        await titleActions.refresh(progress: progress)
        let settings = await services.settings.load()
        services.posterRatings.isEnabled = settings.showsPosterRatings
        services.posterRatings.showsColouredLogos = settings.showsColouredRatingLogos
        // Trakt may hold newer saved titles and watched marks, from the other device or from the web. Whatever it changed here is read
        // again, and Home is told.
        if let summary = try? await services.traktSync.sync(), summary.changedLocalData {
            let progress = await services.progress.all()
            resume.update(from: progress)
            await titleActions.refresh(progress: progress)
            router.userStateRevision += 1
        }
    }
}

private struct PlayerRecovery: Hashable {
    let request: StreamRequest
    /// True when reopening the app's saved session: the picker starts that session's own stream again, as a held poster does.
    var resumesSession = false
}

private extension PlaybackPlan {
    /// Apple's public HLS test stream as an episode, for the launch route `player`.
    static var demo: PlaybackPlan? {
        guard let url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8") else { return nil }
        return PlaybackPlan(request: StreamRequest(type: "series", id: "demo:1:2", title: "Sample Show · Test Pattern", season: 1, episode: 2),
                            candidates: [PlaybackCandidate(id: "demo", title: "Sample stream", addonName: "Demo", route: .native(url))])
    }
}
#endif
