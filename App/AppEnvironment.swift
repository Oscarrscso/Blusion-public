import CryptoKit
import Foundation
import PlayerKit
import SwiftData
import StremioKit
import Persistence
import Features
#if BLUSION_FALLBACK_ENGINE
import FallbackPlayer
#endif

/// Builds the app's long-lived services once. UI tests (`BLUSION_UITEST=1`) get in-memory stores, so every test launch starts empty
/// and nothing is written to the Keychain or disk.
@MainActor
final class AppEnvironment {
    let services: AppServices
    let isUITesting: Bool
    /// The screen to open on (`BLUSION_ROUTE`, see `LaunchRoute`). Home unless a test or `scripts/snapshot.sh` asks for another.
    let launchRoute: LaunchRoute
    /// Nil in UI tests, which start with no addons, unless `BLUSION_SEED_DEFAULTS=1` (snapshots set it, so they show real catalogs).
    private let seeder: DefaultAddonSeeder?

    private init(services: AppServices, isUITesting: Bool, launchRoute: LaunchRoute, seeder: DefaultAddonSeeder?) {
        self.services = services
        self.isUITesting = isUITesting
        self.launchRoute = launchRoute
        self.seeder = seeder
    }

    /// Installs the default metadata addon on first launch. Waits at most `limit` so the first screen usually opens with content;
    /// a slower install finishes in the background and Home fills in when the registry publishes the addon.
    func seedDefaultAddons(waitingAtMost limit: Duration = .seconds(3)) async {
        guard let seeder else { return }
        // Not a task group: a group waits for all its children, and the install cannot be cancelled, so the screen would wait for it anyway.
        let install = Task { await seeder.seedIfNeeded() }
        let (finished, signal) = AsyncStream<Void>.makeStream()
        Task {
            _ = await install.value
            signal.yield(())
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            signal.yield(())
        }
        for await _ in finished { break }
        timer.cancel()
        signal.finish()
    }

    static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppEnvironment {
        let uiTesting = environment["BLUSION_UITEST"] == "1"
        let logger = AddonLogger(sink: OSLogSink())
        let client = AddonClient(logger: logger)

        let store: any AddonStore
        let secrets: any SecretStore
        let progress: any ProgressStore
        let library: any LibraryStore
        let settingsDefaults: UserDefaults
        var secretsInKeychain = true
        if uiTesting {
            store = InMemoryAddonStore()
            secrets = InMemorySecretStore()
            progress = InMemoryProgressStore()
            library = InMemoryLibraryStore()
            // A throwaway suite, so UI tests neither read nor leave preferences behind.
            let suite = "app.blusion.uitest.\(UUID().uuidString)"
            settingsDefaults = UserDefaults(suiteName: suite) ?? .standard
            settingsDefaults.removePersistentDomain(forName: suite)
        } else {
            let device = KeychainSecretStore.forThisDevice(onSynchronizedChange: {
                Task { @MainActor in SecretsSyncObserver.shared.secretsDidChangeLocally() }
            })
            secrets = device.store
            secretsInKeychain = device.usesKeychain
            if !secretsInKeychain { logger.log(.error, "Keychain unavailable to this build; secrets are kept in a private file") }
            settingsDefaults = .standard
            // A digest of the synchronized secrets, so a change is noticed without the secrets leaving the Keychain. Memory only.
            let secretStore = device.store
            let synchronizedSecretsFingerprint: @Sendable () async -> String = {
                var lines = ""
                for key in KeychainSecretStore.synchronizedKeys.sorted() {
                    let value = (try? await secretStore.get(key)) ?? ""
                    lines += "\(key)=\(value)\n"
                }
                return SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
            }
            SecretsSyncObserver.shared.start(secretsFingerprint: synchronizedSecretsFingerprint)
            if let container = try? PersistenceContainer.make() {
                // One container, three stores: addons, watch progress and the library share the same file and migration plan.
                store = SwiftDataAddonStore(container: container)
                progress = SwiftDataProgressStore(container: container)
                library = SwiftDataLibraryStore(container: container)
            } else {
                // A store that cannot be opened must not stop the app: run from memory and say so.
                logger.log(.error, "persistent store unavailable; using memory")
                store = InMemoryAddonStore()
                progress = InMemoryProgressStore()
                library = InMemoryLibraryStore()
            }
        }
        let settings = DefaultsSettingsStore(defaults: settingsDefaults, secrets: secrets, logger: logger)
        let registry = AddonRegistry(store: store, secrets: secrets, client: client, logger: logger)
        // AVPlayer for MP4/MOV/M4V/HLS. MKV, AVI, DTS, AV1 and friends go to the fallback engine when it is built in (ADR-006; the iPhone install builds it in).
        let makeEngine: EngineFactory = { candidate in
            switch candidate.route {
            case .native:
                let engine = AVEngine()
                #if DEBUG
                // A snapshot run (scripts/snapshot.sh) plays for a few seconds on the Mac: keep it silent.
                if environment["BLUSION_SNAPSHOT"] != nil { engine.player.isMuted = true }
                #endif
                return engine
            case .fallback(_, let reason):
                #if BLUSION_FALLBACK_ENGINE
                // AetherEngine first (native Dolby Vision, profile 7 FEL, Atmos), unless the listener chose mpv; mpv for full subtitle
                // styling and as the backup when AetherEngine can't start a stream (`.fullFeaturedEngine`, PlaybackCoordinator).
                let player = Self.playerPreferences(settingsDefaults)
                if reason != .fullFeaturedEngine, player.advancedEngine == .aether,
                   let aether = AetherBackend(composesFEL: player.composesDolbyVisionFEL, rendersObjectAudio: player.rendersObjectAudio,
                                              preferredAudioLanguages: player.audioLanguage.map { [$0] } ?? []) {
                    return FallbackEngine(backend: aether)
                }
                return FallbackEngine(backend: MPVBackend())
                #else
                return nil
                #endif
            default:
                return nil
            }
        }
        // The stream a player is opening on starts downloading at once, while its screen animates in. AetherEngine can take such bytes;
        // AVPlayer and mpv fetch their own (and the Mac build has neither AetherEngine nor mpv), so only AetherEngine's streams warm.
        let preloadStream: StreamPreloader = { candidate in
            #if BLUSION_FALLBACK_ENGINE
            guard case .fallback(_, let reason) = candidate.route, reason != .fullFeaturedEngine, let url = candidate.url,
                  Self.playerPreferences(settingsDefaults).advancedEngine == .aether else { return }
            AetherBackend.prewarm(url: url, headers: candidate.headers)
            #endif
        }
        #if BLUSION_FALLBACK_ENGINE
        let fallbackLinked = true
        let aetherLinked = true
        #else
        let fallbackLinked = false
        let aetherLinked = false
        #endif
        // The Home layout is a preference, not a secret: it names addons by manifest id and host, never by URL.
        let widgets: any WidgetStore = uiTesting ? InMemoryWidgetStore() : DefaultsWidgetStore(defaults: settingsDefaults)
        // Streams handed to Infuse and not yet called back, so a stop recorded after a relaunch still counts.
        let handoffs: any HandoffStore = uiTesting ? InMemoryHandoffStore() : DefaultsHandoffStore(defaults: settingsDefaults)
        let addonSpeed: any AddonSpeedStore = uiTesting ? InMemoryAddonSpeedStore() : DefaultsAddonSpeedStore(defaults: settingsDefaults)
        let widgetShuffle: any WidgetShuffleStore = uiTesting ? InMemoryWidgetShuffleStore()
            : DefaultsWidgetShuffleStore(defaults: settingsDefaults)
        // The last items of each Home row, kept on disk so Home shows them at once on the next launch (UI tests start empty).
        var snapshots: (any WidgetSnapshotStore)?
        if !uiTesting, let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            snapshots = FileWidgetSnapshotStore(directory: caches.appendingPathComponent("WidgetSnapshots", isDirectory: true))
        }
        let traktAccount = TraktAccount(settings: settings, secrets: secrets)
        let trakt = TraktClient(client: client, account: traktAccount, cache: TraktBrowseCache())
        // Trakt's sync state (queued changes, and what Trakt last held) is kept across launches. UI tests keep it in memory.
        var traktSyncState: (any TraktSyncStateStore)?
        if !uiTesting, let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            // A Mac app that is not sandboxed shares Application Support with every other such app, so on the Mac the file goes into a
            // folder named after the bundle id, as the SwiftData store does (see `PersistenceContainer.defaultStoreURL`).
            #if targetEnvironment(macCatalyst)
            let folder = Bundle.main.bundleIdentifier.map { support.appendingPathComponent($0, isDirectory: true) } ?? support
            #else
            let folder = support
            #endif
            traktSyncState = FileTraktSyncStateStore(fileURL: folder.appendingPathComponent("trakt-sync.json"))
        }
        // IMDb's ratings dataset, downloaded in the background once a day and read offline. UI tests never touch the network or the disk.
        var imdbDataset: IMDbRatingsService?
        if !uiTesting, let directory = IMDbRatingsService.standardDirectory() { imdbDataset = IMDbRatingsService(directory: directory) }
        let widgetContent = WidgetContentService(registry: registry, client: client, settings: settings, trakt: trakt, account: traktAccount,
                                                 snapshots: snapshots, imdb: imdbDataset)
        let ratingsCache: any RatingsCache
        if !uiTesting, let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            ratingsCache = FileRatingsCache(fileURL: caches.appendingPathComponent("poster-ratings.json"))
        } else {
            ratingsCache = InMemoryRatingsCache()
        }
        let posterRatings = PosterRatingsStore(letterboxd: uiTesting ? nil : LetterboxdRatings(client: client), cache: ratingsCache,
                                               dataset: imdbDataset, logger: logger)
        let searchHistory: any SearchHistoryStore = uiTesting ? InMemorySearchHistoryStore() : DefaultsSearchHistoryStore(defaults: settingsDefaults)
        let services = AppServices(registry: registry, client: client, settings: settings, progress: progress, library: library,
                                   makeEngine: makeEngine, preloadStream: preloadStream, fallbackEngineLinked: fallbackLinked, aetherEngineLinked: aetherLinked,
                                   decodesAV1InHardware: AVHardware.decodesAV1InHardware,
                                   widgets: widgets, widgetContent: widgetContent,
                                   posterRatings: posterRatings, handoffs: handoffs, searchHistory: searchHistory, traktAccount: traktAccount, trakt: trakt,
                                   secretsInKeychain: secretsInKeychain, traktSyncState: traktSyncState, syncSchedulesItself: !uiTesting,
                                   addonSpeed: addonSpeed, widgetShuffle: widgetShuffle)
        if !uiTesting {
            // The first report from the network monitor is also the launch sync.
            Task { await services.traktSync.startMonitoringNetwork() }
        }
        let seedsDefaults = !uiTesting || environment["BLUSION_SEED_DEFAULTS"] == "1"
        let seeder = seedsDefaults ? DefaultAddonSeeder(registry: registry, flags: DefaultsFlagStore(defaults: settingsDefaults)) : nil
        return AppEnvironment(services: services, isUITesting: uiTesting, launchRoute: LaunchRoute.parse(environment["BLUSION_ROUTE"]) ?? .home,
                              seeder: seeder)
    }

    /// The player settings as saved now, read synchronously: an engine is made the moment a stream starts, when the async store can't be awaited.
    private static func playerPreferences(_ defaults: UserDefaults) -> PlayerPreferences {
        defaults.data(forKey: DefaultsSettingsStore.Keys.player).flatMap { try? JSONDecoder().decode(PlayerPreferences.self, from: $0) }
            ?? PlayerPreferences()
    }
}
