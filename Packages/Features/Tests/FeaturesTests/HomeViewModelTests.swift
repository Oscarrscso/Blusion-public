import Foundation
import Testing
import PlayerKit
import StremioKit
import StremioKitTestSupport
@testable import Features

/// `{"metas": [...]}` with two movies: what every catalog answers in these tests.
private let twoMovies = Data(#"{"metas":[{"id":"tt1","type":"movie","name":"One"},{"id":"tt2","type":"movie","name":"Two"}]}"#.utf8)

/// What a catalog answered yesterday: one movie, so a test can tell the last-known items from the fresh ones.
private let oneOldMovie = Data(#"{"metas":[{"id":"old","type":"movie","name":"Old"}]}"#.utf8)

/// Holds every request until `open()`, so a test can look at Home before any addon has answered.
private actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// A flag a test flips while a stub transport is answering.
private final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) {
        self.value = value
    }

    var isOn: Bool { lock.withLock { value } }

    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
}

/// Two catalogs: `top` (movies, four genres) and `trending` (series).
private let cinemeta = Manifest(
    id: "test.cinemeta", name: "Cinemeta", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie", "series"],
    catalogs: [CatalogDescriptor(type: "movie", id: "top", name: "Popular", extra: [ExtraDescriptor(name: "genre", options: ["Action", "Drama", "Comedy", "Horror"]),
                                                                                   ExtraDescriptor(name: "skip")]),
               CatalogDescriptor(type: "series", id: "trending", name: "Trending")])

/// Two catalogs that a test can make slow: `slow` and `fast`, both movies.
private let slowAndFast = Manifest(
    id: "test.slow", name: "Slow", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
    catalogs: [CatalogDescriptor(type: "movie", id: "slow", name: "Slow"), CatalogDescriptor(type: "movie", id: "fast", name: "Fast")])

/// A saved row of a catalog of the Cinemeta-style test addon.
private func catalogRow(_ id: String, manifestID: String = "test.cinemeta", type: String = "movie", catalog: String) -> HomeWidget {
    HomeWidget(id: id, title: id, content: .row(RowConfiguration(source: .addonCatalog(AddonCatalogReference(manifestID: manifestID, catalogType: type,
                                                                                                            catalogID: catalog)))))
}

/// Continue Watching as a saved layout has it, last.
private let savedContinueWatching = HomeWidget(id: "cw", title: "Continue", content: .continueWatching)

@MainActor
@Suite struct HomeViewModelTests {
    /// A saved layout gets Continue Watching last, as every saved layout has it (`HomeLayout`), unless `addsContinueWatching` is false.
    private func services(_ manifests: [Manifest], transport: StubTransport, widgets: [HomeWidget]? = nil, addsContinueWatching: Bool = true,
                          progress: [WatchProgress] = [], snapshots: (any WidgetSnapshotStore)? = nil) async throws -> AppServices {
        let (registry, client) = try await makeStubbedRegistry(manifests: manifests, transport: transport)
        let settings = InMemorySettingsStore()
        let content = WidgetContentService(registry: registry, client: client, settings: settings, snapshots: snapshots)
        let layout = widgets.map { list in
            addsContinueWatching && !list.contains(where: HomeLayout.isContinueWatching) ? list + [savedContinueWatching] : list
        }
        return AppServices(registry: registry, client: client, settings: settings, progress: InMemoryProgressStore(progress),
                           widgets: InMemoryWidgetStore(layout), widgetContent: content)
    }

    /// Every catalog answers with two movies. A path containing a key of `failing` answers with that status instead.
    private func answering(failing: [String: Int] = [:]) -> StubTransport {
        StubTransport { request, _ in
            let path = request.url?.path ?? ""
            if let status = failing.first(where: { path.contains($0.key) })?.value {
                return StubTransport.response(Data(), status: status, for: request)
            }
            return StubTransport.response(twoMovies, for: request)
        }
    }

    // MARK: Phases and the automatic layout

    /// The phone's layout on 14 October: Continue Watching was deleted from the widgets page, so Home drew it above the showcase. Home puts
    /// it back right after the showcase, saves that once, and leaves every other row where it was.
    @Test func aSavedLayoutWithoutContinueWatchingGetsItBackAfterTheShowcase() async throws {
        let hero = HomeWidget(id: "hero", title: "Spotlight", hideTitle: true, content: .hero(RowConfiguration(source: .addonCatalog(
            AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "movie", catalogID: "top")))))
        let rows = [catalogRow("a", catalog: "top"), catalogRow("b", type: "series", catalog: "trending")]
        let services = try await services([cinemeta], transport: answering(), widgets: [hero] + rows, addsContinueWatching: false)
        let model = HomeViewModel(services: services)
        await model.load()
        let expected = ["hero", HomeLayout.continueWatchingID, "a", "b"]
        #expect(model.sections.map(\.id) == expected)
        #expect(model.sections[1].widget.content == .continueWatching)
        let stored = try #require(await services.widgets.load())
        #expect(stored.map(\.id) == expected)
        await model.load()
        #expect(model.sections.map(\.id) == expected, "a second load changes nothing")
        #expect(await services.widgets.load() == stored)
    }

    @Test func aSavedBannerLoadsItsItemsLikeAHero() async throws {
        let banner = HomeWidget(id: "banner", title: "Featured", content: .banner(RowConfiguration(source: .addonCatalog(AddonCatalogReference(
            manifestID: "test.cinemeta", catalogType: "movie", catalogID: "top")))))
        let model = HomeViewModel(services: try await services([cinemeta], transport: answering(), widgets: [banner]))
        await model.load()
        #expect(model.isCustomised && model.phase == .ready)
        #expect(model.sections.map(\.id) == ["banner", "cw"])
        #expect(model.sections[0].state.value?.count == 2)
    }

    @Test func noAddonsMeansTheEmptyStateAndNoSections() async throws {
        let model = HomeViewModel(services: try await services([], transport: answering()))
        #expect(model.phase == .loading)
        await model.load()
        #expect(model.phase == .noAddons)
        #expect(model.sections.isEmpty && !model.isCustomised)
    }

    @Test func aStreamOnlyAddonLeavesNoCatalogsToShow() async throws {
        let model = HomeViewModel(services: try await services([streamManifest("Streams")], transport: answering()))
        await model.load()
        #expect(model.phase == .noCatalogs)
        #expect(model.sections.isEmpty)
    }

    @Test func theAutomaticLayoutFollowsDefaultWidgetsAndLoadsEveryRow() async throws {
        let services = try await services([cinemeta], transport: answering())
        let model = HomeViewModel(services: services)
        await model.load()
        #expect(model.phase == .ready && !model.isCustomised)
        let expected = DefaultWidgets.make(for: await services.registry.addons).map(\.id)
        #expect(model.sections.map(\.id) == expected)
        #expect(model.sections.map(\.id) == ["auto.hero", "auto.continue", "auto.row.test.cinemeta.movie.top", "auto.row.test.cinemeta.series.trending",
                                             "auto.genres"])
        #expect(model.sections[0].state.value?.map(\.id) == ["tt1", "tt2"], "the spotlight loads")
        #expect(model.sections[1].state == .loaded([]), "Continue Watching has nothing to load")
        #expect(model.sections[2].state.value?.count == 2 && model.sections[3].state.value?.count == 2)
        #expect(model.sections[4].state == .loaded([]), "a genre collection has nothing to load")
        #expect(model.sections.allSatisfy { $0.issue == nil })
    }

    @Test func savedWidgetsWinOverTheAutomaticLayout() async throws {
        let saved = [catalogRow("mine", type: "series", catalog: "trending")]
        let model = HomeViewModel(services: try await services([cinemeta], transport: answering(), widgets: saved))
        await model.load()
        #expect(model.isCustomised && model.phase == .ready)
        #expect(model.sections.map(\.id) == ["mine", "cw"])
        #expect(model.sections[0].state.value?.count == 2)
    }

    @Test func betterPostersTurnOnForAPosterRowAndKeepItsItemsAndSaveIt() async throws {
        let appServices = try await services([cinemeta], transport: answering(), widgets: [catalogRow("top", catalog: "top")])
        let model = HomeViewModel(services: appServices)
        await model.load()
        let items = model.sections[0].state.value

        await model.setBetterPosters(true, sectionID: "top")

        guard case .row(let row) = model.sections[0].widget.content else {
            Issue.record("the row stays a row")
            return
        }
        #expect(row.presentation.usesBetterPosters)
        #expect(model.sections[0].state.value == items, "the row keeps the items it has")
        #expect(model.isCustomised)
        let saved = await appServices.widgets.load()
        #expect(saved?.first?.content == model.sections[0].widget.content, "the change is saved")
    }

    @Test func betterPostersDoNotSaveTheAutomaticLayout() async throws {
        let appServices = try await services([cinemeta], transport: answering())
        let model = HomeViewModel(services: appServices)
        await model.load()
        let row = try #require(model.sections.first(where: { $0.id == "auto.row.test.cinemeta.movie.top" }))

        await model.setBetterPosters(true, sectionID: row.id)

        #expect(!model.isCustomised, "the automatic layout stays automatic")
        let saved = await appServices.widgets.load()
        #expect(saved == nil, "nothing is saved, so the layout keeps following the addons")
    }

    @Test func aSavedListWithNothingInItShowsOnlyContinueWatching() async throws {
        let model = HomeViewModel(services: try await services([cinemeta], transport: answering(), widgets: [], addsContinueWatching: false))
        await model.load()
        #expect(model.phase == .ready && model.isCustomised)
        #expect(model.sections.map(\.id) == [HomeLayout.continueWatchingID])
    }

    @Test func continueWatchingComesFromSavedProgress() async throws {
        let progress = [WatchProgress(id: "movie/tt9", type: "movie", contentID: "tt9", title: "Nine", position: 40, duration: 100, isWatched: false,
                                      updatedAt: Date())]
        let model = HomeViewModel(services: try await services([cinemeta], transport: answering(), progress: progress))
        await model.load()
        #expect(model.continueWatching.map(\.contentID) == ["tt9"])
    }

    @Test func removingAContinueWatchingTitleClearsItsLocalProgress() async throws {
        let progress = [WatchProgress(id: "movie/tt9", type: "movie", contentID: "tt9", title: "Nine", position: 40, duration: 100, isWatched: false,
                                      updatedAt: Date())]
        let model = HomeViewModel(services: try await services([cinemeta], transport: answering(), progress: progress))
        await model.load()
        let entry = try #require(model.continueEntries.first)
        await model.removeFromContinueWatching(entry)
        #expect(model.continueEntries.isEmpty && model.continueWatching.isEmpty)
    }

    @Test func removingAContinueWatchingTitleWhileSignedInQueuesTheTraktRemoval() async throws {
        let progress = [WatchProgress(id: "movie/tt9", type: "movie", contentID: "tt9", title: "Nine", position: 40, duration: 100, isWatched: false,
                                      updatedAt: Date())]
        let transport = StubTransport { request, _ in
            if request.url?.path == "/oauth/device/token" {
                return StubTransport.response(Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":604800,"created_at":1700000000}"#.utf8),
                                              for: request)
            }
            return StubTransport.response(Data("[]".utf8), for: request)
        }
        let settings = InMemorySettingsStore(PlaybackSettings(traktClientID: "test-client"))
        let account = TraktAccount(settings: settings, secrets: InMemorySecretStore(), transport: transport,
                                   now: { Date(timeIntervalSince1970: 1700000001) })
        try await account.saveClientSecret("secret")
        let code = try JSONDecoder().decode(TraktDeviceCode.self, from: Data(
            #"{"device_code":"device","user_code":"ABCD1234","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":5}"#.utf8))
        _ = try await account.checkAuthorization(code)
        let client = makeClient(StubTransport(data: Data()))
        let registry = AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client)
        let services = AppServices(registry: registry, client: client, settings: settings, progress: InMemoryProgressStore(progress), traktAccount: account)
        let model = HomeViewModel(services: services)
        await model.load()
        let entry = try #require(model.continueEntries.first)
        await model.removeFromContinueWatching(entry)
        #expect(model.continueEntries.isEmpty && model.continueWatching.isEmpty)
        #expect(await services.progress.all().isEmpty)
        #expect(await services.traktSync.pendingCount() == 1, "Trakt's paused record is removed by a queued change")
        #expect(transport.callCount == 1, "nothing is sent to Trakt until a sync runs")
    }

    // MARK: Rows that cannot load

    @Test func aRowWhoseAddonIsMissingSaysWhyWithoutAskingForAnything() async throws {
        let transport = answering()
        // No installed addon has this catalog id, so nothing can stand in for the missing addon.
        let saved = [HomeWidget(id: "gone", title: "Gone", content: .row(RowConfiguration(source: .addonCatalog(
            AddonCatalogReference(manifestID: "missing.addon", host: "gone.example.com", catalogType: "movie", catalogID: "gone-catalog")))))]
        let model = HomeViewModel(services: try await services([cinemeta], transport: transport, widgets: saved))
        await model.load()
        let section = try #require(model.sections.first)
        #expect(section.issue == .addonMissing(host: "gone.example.com"))
        #expect(section.state == .loaded([]))
        #expect(transport.callCount == 0)
        #expect(!model.isOffline)
    }

    @Test func rowsThatCannotLoadForOtherReasonsSayWhy() async throws {
        let transport = answering()
        let saved = [
            HomeWidget(id: "trakt", title: "Trakt", content: .row(RowConfiguration(source: .traktList(
                TraktListReference(username: "me", listSlug: "s", listName: "S", isPrivate: true))))),
            HomeWidget(id: "anilist", title: "AniList", content: .row(RowConfiguration(source: .unsupported(kind: "anilistCatalog")))),
        ]
        let model = HomeViewModel(services: try await services([cinemeta], transport: transport, widgets: saved))
        await model.load()
        #expect(model.sections.map(\.issue) == [.needsTraktSignIn, .unsupported(kind: "anilistCatalog"), nil])
        #expect(model.sections.allSatisfy { $0.state == .loaded([]) })
        #expect(transport.callCount == 0)
    }

    @Test func aFailingCatalogIsFailedWithItsStatus() async throws {
        let model = HomeViewModel(services: try await services([cinemeta], transport: answering(failing: ["/catalog/movie/top": 500]),
                                                               widgets: [catalogRow("a", catalog: "top")]))
        await model.load()
        #expect(model.sections[0].state == .failed(.http(status: 500)))
        #expect(model.sections[0].issue == nil)
        #expect(!model.isOffline, "a server error is not the device being offline")
    }

    @Test func anOfflineDeviceIsOneBannerNotOneErrorPerRow() async throws {
        let transport = StubTransport { _, _ in throw URLError(.notConnectedToInternet) }
        let model = HomeViewModel(services: try await services([cinemeta], transport: transport))
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.sections.map { $0.state.error } == [.offline, nil, .offline, .offline, nil])
        #expect(model.isOffline)
    }

    @Test func oneReachableRowMeansTheNetworkIsUp() async throws {
        let transport = StubTransport { request, _ in
            if request.url?.path.contains("trending") == true { throw URLError(.notConnectedToInternet) }
            return StubTransport.response(twoMovies, for: request)
        }
        let model = HomeViewModel(services: try await services([cinemeta], transport: transport))
        await model.load()
        #expect(model.sections.contains { $0.state.error == .offline })
        #expect(!model.isOffline)
    }

    // MARK: Retry, refresh and caching

    @Test func retryReloadsOnlyThatRow() async throws {
        let broken = Switch(true)
        let transport = StubTransport { request, _ in
            if broken.isOn && request.url?.path.contains("/catalog/movie/top") == true {
                return StubTransport.response(Data(), status: 500, for: request)
            }
            return StubTransport.response(twoMovies, for: request)
        }
        let saved = [catalogRow("a", catalog: "top"), catalogRow("b", type: "series", catalog: "trending")]
        let model = HomeViewModel(services: try await services([cinemeta], transport: transport, widgets: saved))
        await model.load()
        #expect(model.sections[0].state.error == .http(status: 500))
        #expect(model.sections[1].state.value?.count == 2)

        broken.set(false)
        let before = transport.callCount
        await model.retry(sectionID: "a")
        #expect(model.sections[0].state.value?.count == 2)
        #expect(transport.callCount == before + 1, "only the failed row asks again")
        await model.retry(sectionID: "no-such-row")
        #expect(transport.callCount == before + 1)
    }

    @Test func aPlainLoadUsesTheCacheAndRefreshAsksAgain() async throws {
        let transport = answering()
        let model = HomeViewModel(services: try await services([cinemeta], transport: transport))
        await model.load()
        let first = transport.callCount
        #expect(first == 6, "the spotlight shares its catalog request with the matching row, and each of the four genre tiles asks once for its photo")
        await model.load()
        #expect(transport.callCount == first, "a second load within the cache TTL is served from memory")
        await model.refresh()
        #expect(transport.callCount == first * 2, "pull to refresh forgets the cached pages and asks again")
    }

    @Test func refreshContinueWatchingPicksUpSavedProgressWithoutReloadingRows() async throws {
        let transport = answering()
        let services = try await services([cinemeta], transport: transport)
        let model = HomeViewModel(services: services)
        await model.load()
        let requests = transport.callCount
        #expect(model.continueWatching.isEmpty)
        await services.progress.save(WatchProgress(id: "movie/tt9", type: "movie", contentID: "tt9", title: "Nine", position: 40, duration: 100,
                                                   isWatched: false, updatedAt: Date()))
        await model.refreshContinueWatching()
        #expect(model.continueWatching.map(\.contentID) == ["tt9"])
        #expect(transport.callCount == requests, "rows are untouched")
    }

    @Test func aReloadKeepsWhatIsOnScreenUntilTheNewItemsArrive() async throws {
        let slow = Switch(false)
        let transport = StubTransport { request, _ in
            if slow.isOn { try await Task.sleep(for: .milliseconds(400)) }
            return StubTransport.response(twoMovies, for: request)
        }
        let model = HomeViewModel(services: try await services([cinemeta], transport: transport, widgets: [catalogRow("a", catalog: "top")]))
        await model.load()
        #expect(model.sections[0].state.value?.count == 2)

        slow.set(true)
        let reload = Task { await model.refresh() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.sections[0].state.value?.count == 2, "the row still shows its items while it reloads")
        await reload.value
        #expect(model.sections[0].state.value?.count == 2)
    }

    @Test func anOlderLoadNeverOverwritesANewerOne() async throws {
        let transport = StubTransport { request, _ in
            if request.url?.path.contains("/catalog/movie/slow") == true { try await Task.sleep(for: .milliseconds(400)) }
            return StubTransport.response(twoMovies, for: request)
        }
        let services = try await services([slowAndFast], transport: transport, widgets: [catalogRow("slow", manifestID: "test.slow", catalog: "slow")])
        let model = HomeViewModel(services: services)
        let first = Task { await model.load() }
        try await waitUntil { model.sections.first?.state.isLoading == true }

        await services.widgets.save([catalogRow("fast", manifestID: "test.slow", catalog: "fast"), savedContinueWatching])
        await model.load()
        #expect(model.sections.map(\.id) == ["fast", "cw"])
        #expect(model.sections[0].state.value?.count == 2)

        await first.value
        #expect(model.sections.map(\.id) == ["fast", "cw"], "the slow load finished last and changed nothing")
        #expect(model.sections[0].state.value?.count == 2)
    }

    // MARK: Last-known items

    @Test func aRelaunchShowsTheLastKnownItemsBeforeAnyAddonAnswers() async throws {
        let snapshots = InMemoryWidgetSnapshotStore()
        let row = [catalogRow("a", catalog: "top")]
        let lastLaunch = StubTransport { request, _ in StubTransport.response(oneOldMovie, for: request) }
        let before = HomeViewModel(services: try await services([cinemeta], transport: lastLaunch, widgets: row, snapshots: snapshots))
        await before.load()
        #expect(before.sections[0].state.value?.map(\.id) == ["old"])

        let gate = Gate()
        let transport = StubTransport { request, _ in
            await gate.wait()
            return StubTransport.response(twoMovies, for: request)
        }
        let relaunch = HomeViewModel(services: try await services([cinemeta], transport: transport, widgets: row, snapshots: snapshots))
        let loading = Task { await relaunch.load() }
        try await waitUntil { relaunch.sections.first?.state.value != nil }
        #expect(relaunch.sections[0].state.value?.map(\.id) == ["old"], "the last-known items show at once")
        #expect(relaunch.sections[0].isRefreshing)
        #expect(relaunch.phase == .ready)

        await gate.open()
        await loading.value
        #expect(relaunch.sections[0].state.value?.map(\.id) == ["tt1", "tt2"], "the fresh items replace them")
        #expect(relaunch.sections[0].isRefreshing == false)
    }

    @Test func aFailedRefreshKeepsTheLastKnownItemsAndIsNotOffline() async throws {
        let snapshots = InMemoryWidgetSnapshotStore()
        let row = [catalogRow("a", catalog: "top")]
        let firstLaunch = HomeViewModel(services: try await services([cinemeta], transport: answering(), widgets: row, snapshots: snapshots))
        await firstLaunch.load()

        let offline = StubTransport { _, _ in throw URLError(.notConnectedToInternet) }
        let offlineLaunch = HomeViewModel(services: try await services([cinemeta], transport: offline, widgets: row, snapshots: snapshots))
        await offlineLaunch.load()
        #expect(offlineLaunch.sections[0].state.value?.map(\.id) == ["tt1", "tt2"], "the failed refresh keeps what is known")
        #expect(offlineLaunch.sections[0].isRefreshing == false)
        #expect(offlineLaunch.isOffline == false, "stale items are shown, so there is no offline banner")

        let serverDown = HomeViewModel(services: try await services([cinemeta], transport: answering(failing: ["/catalog/movie/top": 500]),
                                                                   widgets: row, snapshots: snapshots))
        await serverDown.load()
        #expect(serverDown.sections[0].state.value?.map(\.id) == ["tt1", "tt2"])
        #expect(serverDown.sections[0].state.error == nil, "a server error does not replace known items either")
    }

    @Test func aFailureWithNothingKnownIsFailedAsBefore() async throws {
        let model = HomeViewModel(services: try await services([cinemeta], transport: answering(failing: ["/catalog/movie/top": 500]),
                                                               widgets: [catalogRow("a", catalog: "top")], snapshots: InMemoryWidgetSnapshotStore()))
        await model.load()
        #expect(model.sections[0].state == .failed(.http(status: 500)))
        #expect(model.sections[0].isRefreshing == false)
    }

    @Test func refreshDoesNotBlankALoadedRowEvenWhenItFails() async throws {
        let broken = Switch(false)
        let transport = StubTransport { request, _ in
            if broken.isOn { return StubTransport.response(Data(), status: 500, for: request) }
            return StubTransport.response(twoMovies, for: request)
        }
        let model = HomeViewModel(services: try await services([cinemeta], transport: transport, widgets: [catalogRow("a", catalog: "top")]))
        await model.load()
        let loaded = model.sections[0].state
        broken.set(true)
        await model.refresh()
        #expect(model.sections[0].state == loaded, "the row keeps its items through a refresh that fails")
        #expect(model.sections[0].isRefreshing == false)
    }

    @Test func aRowWhoseAddonIsGoneShowsNothingFromBefore() async throws {
        let snapshots = InMemoryWidgetSnapshotStore()
        let row = [catalogRow("a", catalog: "top")]
        let firstLaunch = HomeViewModel(services: try await services([cinemeta], transport: answering(), widgets: row, snapshots: snapshots))
        await firstLaunch.load()
        #expect(firstLaunch.sections[0].state.value?.count == 2)

        let disabled = try await services([cinemeta], transport: answering(), widgets: row, snapshots: snapshots)
        let addon = try #require(await disabled.registry.addons.first)
        try await disabled.registry.setEnabled(false, id: addon.id)
        let model = HomeViewModel(services: disabled)
        await model.load()
        #expect(model.sections[0].issue == .addonMissing(host: nil))
        #expect(model.sections[0].state == .loaded([]), "the addon is off, so its old items are not shown")
        #expect(model.sections[0].isRefreshing == false)
    }

    // MARK: Observing addons

    @Test func observingAddonsReloadsWhenTheyChange() async throws {
        let services = try await services([cinemeta], transport: answering())
        let model = HomeViewModel(services: services)
        let observing = Task { await model.observeAddons() }
        try await waitUntil { model.phase == .ready && model.sections.allSatisfy { !$0.state.isLoading } }
        let addons = await services.registry.addons
        let addon = try #require(addons.first)
        try await services.registry.setEnabled(false, id: addon.id)
        try await waitUntil { model.phase == .noCatalogs && model.sections.isEmpty }
        try await services.registry.setEnabled(true, id: addon.id)
        try await waitUntil { model.phase == .ready && model.sections.allSatisfy { !$0.state.isLoading } }
        observing.cancel()
    }

    @Test func returningToLoadedHomeKeepsItsShelvesWithoutReloading() async throws {
        let transport = answering()
        let row = HomeWidget(id: "a", title: "Popular", content: .row(RowConfiguration(
            source: .addonCatalog(AddonCatalogReference(manifestID: cinemeta.id, catalogType: "movie", catalogID: "top")), cacheTTL: 0)))
        let model = HomeViewModel(services: try await services([cinemeta], transport: transport, widgets: [row]))
        let firstObservation = Task { await model.observeAddons() }
        try await waitUntil { model.sections.first?.state.value?.count == 2 && model.sections.first?.isRefreshing == false }
        try await Task.sleep(for: .milliseconds(20))
        firstObservation.cancel()
        await firstObservation.value
        let previous = model.sections

        let returningObservation = Task { await model.observeAddons() }
        defer { returningObservation.cancel() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(transport.callCount == 1, "a completed Home must not refetch catalogs during the back transition")
        #expect(model.sections == previous)
        returningObservation.cancel()
        await returningObservation.value
    }

    @Test func returningToHomeReloadsAfterItsObservationWasCancelled() async throws {
        let gate = Gate()
        let transport = StubTransport { request, call in
            if call == 1 {
                await gate.wait()
                try Task.checkCancellation()
            }
            return StubTransport.response(twoMovies, for: request)
        }
        let model = HomeViewModel(services: try await services([cinemeta], transport: transport, widgets: [catalogRow("a", catalog: "top")]))
        let firstObservation = Task { await model.observeAddons() }
        try await waitUntil { transport.callCount == 1 }
        firstObservation.cancel()
        await gate.open()
        await firstObservation.value
        #expect(model.sections[0].state.isLoading, "leaving Home does not turn an unfinished row into a cancellation error")
        #expect(model.sections[0].state.error == nil)

        let returningObservation = Task { await model.observeAddons() }
        defer { returningObservation.cancel() }
        try await waitUntil { model.sections.first?.state.value?.count == 2 }
        #expect(model.sections[0].state.value?.map(\.id) == ["tt1", "tt2"])
        #expect(transport.callCount == 2, "the unchanged addon is asked again when Home returns")
        returningObservation.cancel()
        await returningObservation.value
    }

    @Test func aCancelledRetryDoesNotShowACancellationErrorAndCanBeRetriedAgain() async throws {
        let gate = Gate()
        let transport = StubTransport { request, call in
            if call == 1 { return StubTransport.response(Data(), status: 404, for: request) }
            if call == 2 {
                await gate.wait()
                try Task.checkCancellation()
            }
            return StubTransport.response(twoMovies, for: request)
        }
        let model = HomeViewModel(services: try await services([cinemeta], transport: transport, widgets: [catalogRow("a", catalog: "top")]))
        await model.load()
        #expect(model.sections[0].state.error == .notFound)
        let retrying = Task { await model.retry(sectionID: "a") }
        try await waitUntil { transport.callCount == 2 }
        retrying.cancel()
        await gate.open()
        await retrying.value
        #expect(model.sections[0].state.error == nil)

        await model.retry(sectionID: "a")
        #expect(model.sections[0].state.value?.map(\.id) == ["tt1", "tt2"])
        #expect(transport.callCount == 3)
    }
}
