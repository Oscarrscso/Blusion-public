import Foundation
import PlayerKit
import StremioKit

/// Creates the engine for a candidate: AVPlayer for `.native`, the fallback engine for `.fallback` (when linked), nil when none fits.
public typealias EngineFactory = @MainActor @Sendable (PlaybackCandidate) -> (any PlaybackEngine)?
/// Starts fetching a candidate's stream before the player loads it, where its engine can take the bytes. Does nothing for one it can't.
public typealias StreamPreloader = @MainActor @Sendable (PlaybackCandidate) -> Void

/// The app's long-lived services, handed to view models. Built once at launch (App/) and in tests (with stubs or the mock).
public struct AppServices: Sendable {
    public let registry: AddonRegistry
    public let client: AddonClient
    public let browse: BrowseService
    public let streams: StreamService
    public let subtitles: SubtitleService
    public let settings: any SettingsStore
    /// Watch progress. Every change made through it is reported to `traktSync`.
    public let progress: any ProgressStore
    /// The saved titles. Every change made through it is reported to `traktSync`.
    public let library: any LibraryStore
    /// Two-way Trakt sync: `progress` and `library` report every change to it, and it writes to the plain stores under them.
    public let traktSync: TraktSync
    /// The user's Home layout (nil inside means "automatic").
    public let widgets: any WidgetStore
    /// Loads the items of Home widgets, with an in-memory cache.
    public let widgetContent: WidgetContentService
    /// IMDb and Letterboxd ratings for poster badges.
    public let posterRatings: PosterRatingsStore
    /// The titles' fuller details for the metadata line under a hero, shared by Home's spotlight and the title page.
    public let heroMeta: HeroMetaStore
    /// Finds a film's best Blu-ray edition on bestblurays.com while its streams are loading.
    public let bestBlurays: BestBluraysClient
    public let makeEngine: EngineFactory
    /// Called the moment a player opens, before its screen has appeared, with the stream it will start.
    public let preloadStream: StreamPreloader
    /// True once a fallback engine (M6) is linked into the app.
    public let fallbackEngineLinked: Bool
    /// True when AetherEngine is linked beside mpv (iPhone and iPad builds with the fallback engine): Settings offers the engine choice
    /// and its Dolby Vision and spatial-audio options, and a stream it cannot start is tried once in mpv.
    public let aetherEngineLinked: Bool
    /// This device decodes AV1 in hardware, so AVPlayer plays AV1 and the fallback engine does not need to (ADR-006).
    public let decodesAV1InHardware: Bool
    /// Streams handed to another player app, waiting for its callback to record where the viewer stopped.
    public let handoffs: any HandoffStore
    /// The addon speed test's results, by addon (see `AddonSpeedTester`), and the tester that makes them.
    public let addonSpeed: any AddonSpeedStore
    /// The widgets page's shuffle settings and the seed of every shuffled order (see `WidgetShuffling`).
    public let widgetShuffle: any WidgetShuffleStore
    public let speedTester: AddonSpeedTester
    public let searchHistory: any SearchHistoryStore
    public let traktAccount: TraktAccount
    /// The one Trakt client: public reads with the client ID, signed-in reads through `traktAccount`, browse pages cached.
    public let trakt: TraktClient
    /// False in a Mac build that the system keeps away from the Keychain: addon links and credentials are then in a private file.
    public let secretsInKeychain: Bool

    public init(registry: AddonRegistry, client: AddonClient, browse: BrowseService? = nil, streams: StreamService? = nil,
                subtitles: SubtitleService? = nil, settings: (any SettingsStore)? = nil, progress: (any ProgressStore)? = nil,
                library: (any LibraryStore)? = nil, makeEngine: EngineFactory? = nil, preloadStream: StreamPreloader? = nil, fallbackEngineLinked: Bool = false,
                aetherEngineLinked: Bool = false, decodesAV1InHardware: Bool = false,
                widgets: (any WidgetStore)? = nil, widgetContent: WidgetContentService? = nil, posterRatings: PosterRatingsStore? = nil,
                handoffs: (any HandoffStore)? = nil, searchHistory: (any SearchHistoryStore)? = nil, traktAccount: TraktAccount? = nil,
                trakt: TraktClient? = nil, secretsInKeychain: Bool = true, bestBlurays: BestBluraysClient? = nil,
                traktSyncState: (any TraktSyncStateStore)? = nil, syncSchedulesItself: Bool = false, heroMeta: HeroMetaStore? = nil,
                addonSpeed: (any AddonSpeedStore)? = nil, speedTester: AddonSpeedTester? = nil,
                widgetShuffle: (any WidgetShuffleStore)? = nil) {
        self.registry = registry
        self.client = client
        self.browse = browse ?? BrowseService(registry: registry, client: client)
        let addonSpeed = addonSpeed ?? InMemoryAddonSpeedStore()
        self.addonSpeed = addonSpeed
        self.streams = streams ?? StreamService(registry: registry, client: client, timings: addonSpeed)
        self.subtitles = subtitles ?? SubtitleService(registry: registry, client: client)
        let settings = settings ?? InMemorySettingsStore()
        self.settings = settings
        let plainProgress = progress ?? InMemoryProgressStore()
        let plainLibrary = library ?? InMemoryLibraryStore()
        self.widgets = widgets ?? InMemoryWidgetStore()
        let traktAccount = traktAccount ?? TraktAccount(settings: settings, secrets: InMemorySecretStore())
        let trakt = trakt ?? TraktClient(client: client, account: traktAccount, cache: TraktBrowseCache())
        // Sync gets the plain stores, so what it writes is never taken for a change the user made. The app gets the synced wrappers.
        let traktSync = TraktSync(account: traktAccount, library: plainLibrary, progress: plainProgress,
                                  store: traktSyncState ?? InMemoryTraktSyncStateStore(), schedulesItself: syncSchedulesItself)
        self.progress = SyncedProgressStore(base: plainProgress, sync: traktSync)
        self.library = SyncedLibraryStore(base: plainLibrary, sync: traktSync)
        self.traktSync = traktSync
        self.widgetContent = widgetContent ?? WidgetContentService(registry: registry, client: client, settings: settings, trakt: trakt,
                                                                   account: traktAccount)
        self.posterRatings = posterRatings ?? PosterRatingsStore()
        self.heroMeta = heroMeta ?? HeroMetaStore(browse: self.browse)
        self.bestBlurays = bestBlurays ?? BestBluraysClient(client: client)
        self.handoffs = handoffs ?? InMemoryHandoffStore()
        self.speedTester = speedTester ?? AddonSpeedTester(registry: registry)
        self.widgetShuffle = widgetShuffle ?? InMemoryWidgetShuffleStore()
        self.searchHistory = searchHistory ?? InMemorySearchHistoryStore()
        self.traktAccount = traktAccount
        self.trakt = trakt
        self.makeEngine = makeEngine ?? { _ in nil }
        self.preloadStream = preloadStream ?? { _ in }
        self.fallbackEngineLinked = fallbackEngineLinked
        self.aetherEngineLinked = aetherEngineLinked
        self.decodesAV1InHardware = decodesAV1InHardware
        self.secretsInKeychain = secretsInKeychain
    }
}
