import Foundation
import Testing
import PlayerKit
import StremioKit
import StremioKitTestSupport
@testable import Features

@MainActor
@Suite struct LibraryAndSettingsViewModelTests {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func progress(_ id: String, _ position: Double, duration: Double = 100, watched: Bool = false, age: TimeInterval = 0, type: String = "movie",
                          season: Int? = nil, episode: Int? = nil) -> WatchProgress {
        WatchProgress(id: "\(type)/\(id)", type: type, contentID: id, title: "T \(id)", position: position, duration: duration, isWatched: watched,
                      updatedAt: when.addingTimeInterval(age), season: season, episode: episode)
    }

    private func services(progress: [WatchProgress] = [], library: [LibraryItem] = [], settings: PlaybackSettings = PlaybackSettings()) -> AppServices {
        let client = makeClient(StubTransport(data: Data()))
        let registry = AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client)
        return AppServices(registry: registry, client: client, settings: InMemorySettingsStore(settings),
                           progress: InMemoryProgressStore(progress), library: InMemoryLibraryStore(library))
    }

    // MARK: library

    @Test func resumableItemsKeepOnlyTheNewestFirst() async {
        let items = [
            progress("old", 40, age: 0), progress("new", 60, age: 100), progress("barely", 2, age: 50), progress("nearly", 97, age: 60),
            progress("done", 95, watched: true, age: 70),
        ]
        #expect(LibraryViewModel.continueWatching(from: items.sorted { $0.updatedAt > $1.updatedAt }).map(\.contentID) == ["new", "old"],
                "barely started, nearly finished and watched items don't qualify")
        let model = LibraryViewModel(services: services(progress: items))
        #expect(!model.hasLoaded)
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.watched.map(\.latest.contentID) == ["done"])
        #expect(model.isEmpty == false)
    }

    @Test func onlyTheLatestEpisodePerSeriesResumes() {
        let items = [
            progress("tt9:1:1", 30, age: 0, type: "series", season: 1, episode: 1),
            progress("tt9:1:2", 30, age: 100, type: "series", season: 1, episode: 2),
            progress("tt8:1:1", 30, age: 50, type: "series", season: 1, episode: 1),
        ]
        #expect(LibraryViewModel.continueWatching(from: items.sorted { $0.updatedAt > $1.updatedAt }).map(\.contentID) == ["tt9:1:2", "tt8:1:1"])
    }

    @Test func savedTitlesAndRemoval() async {
        let saved = [LibraryItem(id: "movie/a", type: "movie", contentID: "a", name: "A", addedAt: when),
                     LibraryItem(id: "movie/b", type: "movie", contentID: "b", name: "B", addedAt: when.addingTimeInterval(10))]
        let model = LibraryViewModel(services: services(library: saved))
        await model.load()
        #expect(model.saved.map(\.contentID) == ["b", "a"])
        await model.removeSaved(model.saved[0])
        #expect(model.saved.map(\.contentID) == ["a"])
    }

    @Test func markingAndUnmarking() async {
        let model = LibraryViewModel(services: services(progress: [progress("a", 40), progress("b", 50, age: -10)]))
        await model.load()
        await model.markWatched(progress("a", 40))
        #expect(model.watched.map(\.latest.contentID) == ["a"])
        await model.markUnwatched(model.watched[0])
        #expect(model.watched.isEmpty && model.isEmpty)
    }

    @Test func episodesOfAShowShareOneWatchedCard() async {
        let model = LibraryViewModel(services: services(progress: [
            progress("tt9:1:1", 100, watched: true, age: 0, type: "series", season: 1, episode: 1),
            progress("tt9:1:2", 100, watched: true, age: 100, type: "series", season: 1, episode: 2),
            progress("m", 100, watched: true, age: 50),
        ]))
        await model.load()
        #expect(model.watched.map(\.id) == ["series/tt9", "movie/m"], "the show's card takes the place of its newest episode")
        #expect(model.watched[0].watchedCount == 2 && model.watched[0].latest.contentID == "tt9:1:2")
        await model.markUnwatched(model.watched[0])
        #expect(model.watched.map(\.id) == ["movie/m"], "clearing the show clears each of its episodes and leaves the movie")
    }

    @Test func requestsToResumeCarryEverythingTheyNeed() {
        let p = WatchProgress(id: "series/tt9:2:3", type: "series", contentID: "tt9:2:3", title: "Show · Three", poster: URL(string: "https://e.com/p.jpg"),
                              position: 10, duration: 50, isWatched: false, updatedAt: when, season: 2, episode: 3)
        let request = LibraryViewModel.request(for: p)
        #expect(request.type == "series" && request.id == "tt9:2:3" && request.title == "Show · Three" && request.season == 2 && request.episode == 3)
        #expect(request.identity == p.id, "the player finds the saved position under the same identity")
    }

    @Test func homeShowsContinueWatching() async throws {
        let model = HomeViewModel(services: services(progress: [progress("a", 40), progress("b", 99)]))
        await model.load()
        #expect(model.continueWatching.map(\.contentID) == ["a"])
    }

    @Test func homeRefreshesContinueWatchingWithoutReloadingRows() async {
        let services = services(progress: [progress("a", 40)])
        let model = HomeViewModel(services: services)
        await model.refreshContinueWatching()
        #expect(model.continueWatching.map(\.contentID) == ["a"])
        await services.progress.save(progress("b", 30, age: 10))
        await model.refreshContinueWatching()
        #expect(model.continueWatching.map(\.contentID) == ["b", "a"])
        #expect(model.sections.isEmpty && model.phase == .loading, "rows are untouched")
    }

    // MARK: detail: library and watched

    private func detailModel(_ services: AppServices, preview: MetaPreview) -> DetailViewModel { DetailViewModel(preview: preview, services: services) }

    @Test func detailTogglesTheLibrary() async {
        let services = services()
        let model = detailModel(services, preview: MetaPreview(id: "tt1", type: "movie", name: "Film"))
        await model.refreshUserState()
        #expect(!model.isInLibrary)
        await model.toggleLibrary()
        #expect(model.isInLibrary)
        #expect(await services.library.all().map(\.id) == ["movie/tt1"])
        await model.toggleLibrary()
        let afterRemoval = await services.library.all()
        #expect(!model.isInLibrary && afterRemoval.isEmpty)
    }

    /// The Save and Watched buttons tick only when `loadRevision` stays put: a saved, watched title read in as its page opens moves it, so
    /// the page opens silently, and the user's own Save and Watched taps leave it where it is, so they tick.
    @Test func detailReadsSavedStateQuietlyAndTicksForTheUsersChanges() async {
        let film = MetaPreview(id: "tt1", type: "movie", name: "Film")
        let services = services(progress: [progress("tt1", 0, watched: true)], library: [LibraryItem(preview: film, addedAt: when)])
        let model = detailModel(services, preview: film)
        let opened = model.loadRevision
        await model.refreshUserState()
        #expect(model.isInLibrary && model.isWatched(model.movieRequest))
        #expect(model.loadRevision > opened, "reading the saved state in is not a change the user made")
        let read = model.loadRevision
        await model.toggleLibrary()
        #expect(!model.isInLibrary)
        await model.setWatched(false, for: model.movieRequest)
        #expect(!model.isWatched(model.movieRequest))
        #expect(model.loadRevision == read, "the user's own changes tick")
        await model.refreshUserState()
        #expect(model.loadRevision > read, "reading again, as the page shows again, stays silent")
    }

    @Test func detailMarksMoviesWatched() async {
        let services = services()
        let model = detailModel(services, preview: MetaPreview(id: "tt1", type: "movie", name: "Film"))
        let request = model.movieRequest
        #expect(!model.isWatched(request))
        await model.setWatched(true, for: request)
        #expect(model.isWatched(request))
        let saved = await services.progress.progress(for: request.identity)
        #expect(saved?.isWatched == true)
        #expect(ProgressRecorder.resumePosition(for: saved) == 0, "a watched title starts from the beginning")
        await model.setWatched(false, for: request)
        let afterUnmark = await services.progress.progress(for: request.identity)
        #expect(!model.isWatched(request) && afterUnmark == nil)
    }

    // MARK: settings

    @Test func settingsPersistEachChange() async {
        let services = services()
        let model = SettingsViewModel(services: services)
        await model.load()
        #expect(model.settings == PlaybackSettings())
        await model.setPreferredResolution(1080)
        await model.setSubtitleLanguage("eng")
        await model.setFallbackEngineEnabled(false)
        let stored = await services.settings.load()
        #expect(stored == PlaybackSettings(preferredResolution: 1080, subtitleLanguage: "eng", streamingServerURL: nil, fallbackEngineEnabled: false))
        await model.setSubtitleLanguage(nil)
        #expect(await services.settings.load().subtitleLanguage == nil)
    }

    @Test func theServerURLIsSavedOnlyWhenValidOrEmpty() async {
        let services = services()
        let model = SettingsViewModel(services: services)
        await model.load()
        model.serverURLText = "not a url"
        #expect(model.serverURLMessage?.contains("full address") == true)
        await model.commitServerURL()
        #expect(await services.settings.load().streamingServerURL == nil, "an invalid value is not saved")
        model.serverURLText = " http://192.168.1.9:11470 "
        #expect(model.serverURLMessage == nil)
        await model.commitServerURL()
        #expect(await services.settings.load().streamingServerURL == "http://192.168.1.9:11470")
        model.serverURLText = ""
        await model.commitServerURL()
        #expect(await services.settings.load().streamingServerURL == nil, "clearing the field removes it")
    }

    @Test func settingsLoadExistingValues() async {
        let model = SettingsViewModel(services: services(settings: PlaybackSettings(preferredResolution: 720, subtitleLanguage: "fre", streamingServerURL: "http://nas:11470")))
        await model.load()
        #expect(model.settings.preferredResolution == 720 && model.settings.subtitleLanguage == "fre" && model.serverURLText == "http://nas:11470")
        #expect(!model.fallbackEngineLinked, "no engine linked in tests")
    }

    @Test func optionsListsAreComplete() {
        #expect(SettingsViewModel.resolutionOptions.first?.value == nil && SettingsViewModel.resolutionOptions.count == 5)
        let languages = SettingsViewModel.languageOptions
        #expect(languages.first?.label == "Off" && languages.first?.value == nil)
        #expect(languages.contains { $0.value == "eng" && $0.label == "English" } && languages.count > 30)
        #expect(Set(languages.map(\.id)).count == languages.count, "ids are unique")
        #expect(!SettingsViewModel.appVersion.isEmpty)
    }

    @Test func playerAndAutoPlayChoicesAreSaved() async {
        let services = services()
        let model = SettingsViewModel(services: services)
        await model.load()
        #expect(model.settings.playerPreference == .infuseWhenNeeded && !model.settings.autoPlayBestStream)
        await model.setPlayerPreference(.infuse)
        await model.setAutoPlayBestStream(true)
        #expect(model.settings.playerPreference == .infuse && model.settings.autoPlayBestStream)
        let stored = await services.settings.load()
        #expect(stored.playerPreference == .infuse && stored.autoPlayBestStream)
        await model.setPlayerPreference(.builtIn)
        await model.setAutoPlayBestStream(false)
        let reverted = await services.settings.load()
        #expect(reverted.playerPreference == .builtIn && !reverted.autoPlayBestStream)
    }

    @Test func changingPlaybackWithoutTraktSetupDoesNotInjectAClientID() async {
        let services = services(settings: PlaybackSettings(preferredResolution: 720))
        let settingsModel = SettingsViewModel(services: services)
        await settingsModel.load()
        let accountModel = TraktAccountViewModel(services: services)
        await accountModel.load()
        #expect(accountModel.errorMessage == nil)
        await settingsModel.setPlayerPreference(.infuse)
        let stored = await services.settings.load()
        #expect(stored.traktClientID == nil)
        #expect(stored.playerPreference == .infuse && stored.preferredResolution == 720)
    }

    @Test func posterRatingsSwitchDrivesTheStoreAndIsSaved() async {
        let services = services()
        let model = SettingsViewModel(services: services)
        await model.load()
        #expect(services.posterRatings.isEnabled, "on by default")
        await model.setShowsPosterRatings(false)
        #expect(!services.posterRatings.isEnabled && !model.settings.showsPosterRatings)
        let stored = await services.settings.load()
        #expect(!stored.showsPosterRatings)
        // Loading takes the stored value back into the store the posters read.
        services.posterRatings.isEnabled = true
        await model.load()
        #expect(!services.posterRatings.isEnabled)
    }

    @Test func posterRatingsStartOffWhenTheStoredValueIsOff() async {
        let services = services(settings: PlaybackSettings(showsPosterRatings: false))
        let model = SettingsViewModel(services: services)
        await model.load()
        #expect(!services.posterRatings.isEnabled && !model.settings.showsPosterRatings)
    }

    @Test func tmdbReadTokenIsLoadedAndSavedTrimmed() async {
        let services = services(settings: PlaybackSettings(tmdbReadToken: "tmdb-old"))
        let model = SettingsViewModel(services: services)
        await model.load()
        #expect(model.tmdbReadTokenText == "tmdb-old")
        model.tmdbReadTokenText = "  tmdb-1 \n"
        await model.commitReviewCredentials()
        #expect(await services.settings.load().tmdbReadToken == "tmdb-1")
        model.tmdbReadTokenText = "   "
        await model.commitReviewCredentials()
        #expect(await services.settings.load().tmdbReadToken == nil, "a blank field removes the token")
    }

    @Test func installedAddonCountComesFromTheRegistry() async throws {
        let empty = SettingsViewModel(services: services())
        await empty.load()
        #expect(empty.installedAddonCount == 0)
        let manifests = ["one", "two"].map { name in
            Manifest(id: name, name: name, version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
                     catalogs: [CatalogDescriptor(type: "movie", id: "top")])
        }
        let (registry, client) = try await makeStubbedRegistry(manifests: manifests, transport: StubTransport(data: Data()))
        let model = SettingsViewModel(services: AppServices(registry: registry, client: client))
        await model.load()
        #expect(model.installedAddonCount == 2)
    }

    // MARK: clearing data

    @Test func eachScopeClearsOnlyItsOwnData() async throws {
        let server = try MockServer.shared()
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: 5, maxRetries: 0))
        let secrets = InMemorySecretStore()
        let registry = AddonRegistry(store: InMemoryAddonStore(), secrets: secrets, client: client)
        _ = try await registry.install(from: server.catalogManifestURL(token: "tok").absoluteString)
        let services = AppServices(registry: registry, client: client, settings: InMemorySettingsStore(PlaybackSettings(subtitleLanguage: "eng")),
                                   progress: InMemoryProgressStore([progress("a", 40)]),
                                   library: InMemoryLibraryStore([LibraryItem(id: "movie/a", type: "movie", contentID: "a", name: "A", addedAt: when)]),
                                   widgets: InMemoryWidgetStore([HomeWidget(id: "w", title: "Watching", content: .continueWatching)]))
        let reset = DataResetService(services: services)

        let message = await reset.clear(.history)
        #expect(message == "Watch history cleared.")
        var history = await services.progress.all()
        var saved = await services.library.all()
        #expect(history.isEmpty && !saved.isEmpty)
        await reset.clear(.library)
        saved = await services.library.all()
        var current = await services.settings.load()
        #expect(saved.isEmpty && current.subtitleLanguage == "eng")
        await reset.clear(.settings)
        current = await services.settings.load()
        #expect(current == PlaybackSettings())
        var layout = await services.widgets.load()
        #expect(layout?.count == 1, "the Home layout survives until asked")
        let homeMessage = await reset.clear(.widgets)
        #expect(homeMessage == "Home layout cleared.")
        layout = await services.widgets.load()
        #expect(layout == nil, "clearing the Home layout saves nothing, so Home is automatic again")
        var installed = await registry.addons
        #expect(installed.count == 1, "addons survive until asked")
        await reset.clear(.addons)
        installed = await registry.addons
        let remainingSecrets = await secrets.snapshot
        #expect(installed.isEmpty)
        #expect(remainingSecrets.isEmpty, "removing addons removes their saved links")
        history = await services.progress.all()
        #expect(history.isEmpty)
    }

    @Test func clearingTheHomeLayoutForgetsTheCachedRows() async throws {
        let manifest = Manifest(id: "test.cinemeta", name: "Cinemeta", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
                                catalogs: [CatalogDescriptor(type: "movie", id: "top", name: "Top")])
        let transport = StubTransport(data: Data(#"{"metas":[{"id":"tt1","type":"movie"}]}"#.utf8))
        let (registry, client) = try await makeStubbedRegistry(manifests: [manifest], transport: transport)
        let snapshots = InMemoryWidgetSnapshotStore()
        let content = WidgetContentService(registry: registry, client: client, settings: InMemorySettingsStore(), snapshots: snapshots)
        let layout = [HomeWidget(id: "w", title: "Watching", content: .continueWatching)]
        let services = AppServices(registry: registry, client: client, widgets: InMemoryWidgetStore(layout), widgetContent: content)
        let source = WidgetSource.addonCatalog(AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "movie", catalogID: "top"))
        _ = try await content.items(for: source, limit: 5)
        _ = try await content.items(for: source, limit: 5)
        #expect(transport.callCount == 1, "the second read is served from memory")
        _ = await DataResetService(services: services).clear(.widgets)
        let known = await content.lastKnownItems(for: source, limit: 5)
        #expect(known == nil, "clearing the Home layout forgets the last-known rows too")
        let stored = await snapshots.items(for: source)
        #expect(stored == nil, "and their snapshots")
        _ = try await content.items(for: source, limit: 5)
        #expect(transport.callCount == 2, "clearing the Home layout asks the addons again")
    }

    @Test func clearingAddonsForgetsTheLastKnownRowsSoRemovedAddonsDoNotLinger() async throws {
        let manifest = Manifest(id: "test.cinemeta", name: "Cinemeta", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
                                catalogs: [CatalogDescriptor(type: "movie", id: "top", name: "Top")])
        let transport = StubTransport(data: Data(#"{"metas":[{"id":"tt1","type":"movie"}]}"#.utf8))
        let (registry, client) = try await makeStubbedRegistry(manifests: [manifest], transport: transport)
        let snapshots = InMemoryWidgetSnapshotStore()
        let content = WidgetContentService(registry: registry, client: client, settings: InMemorySettingsStore(), snapshots: snapshots)
        let source = WidgetSource.addonCatalog(AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "movie", catalogID: "top"))
        _ = try await content.items(for: source, limit: 5)
        let services = AppServices(registry: registry, client: client, widgets: InMemoryWidgetStore(), widgetContent: content)
        await DataResetService(services: services).clear(.addons)
        let known = await content.lastKnownItems(for: source, limit: 5)
        #expect(known == nil)
        let stored = await snapshots.items(for: source)
        #expect(stored == nil)
    }

    @Test func everythingClearsEverything() async throws {
        let server = try MockServer.shared()
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: 5, maxRetries: 0))
        let registry = AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client)
        _ = try await registry.install(from: server.catalogManifestURL(token: "tok").absoluteString)
        let services = AppServices(registry: registry, client: client, settings: InMemorySettingsStore(PlaybackSettings(subtitleLanguage: "eng")),
                                   progress: InMemoryProgressStore([progress("a", 40)]),
                                   library: InMemoryLibraryStore([LibraryItem(preview: MetaPreview(id: "a", name: "A"))]),
                                   widgets: InMemoryWidgetStore([HomeWidget(id: "w", title: "Watching", content: .continueWatching)]))
        let model = SettingsViewModel(services: services)
        await model.load()
        await model.clear(.everything)
        #expect(model.lastMessage == "Everything cleared.")
        let history = await services.progress.all()
        let saved = await services.library.all()
        let installed = await registry.addons
        let layout = await services.widgets.load()
        #expect(history.isEmpty && saved.isEmpty && installed.isEmpty)
        #expect(layout == nil, "everything includes the Home layout")
        #expect(model.settings == PlaybackSettings(), "the screen reloads after a reset")
        #expect(DataResetService.Scope.allCases.allSatisfy { !$0.warning.isEmpty && !$0.title.isEmpty })
    }
}
