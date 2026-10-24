import Foundation
import Testing
import PlayerKit
import PlayerKitTestSupport
import StremioKit
import StremioKitTestSupport
@testable import Features

/// PLAN M7 acceptance: a test greps captured logs for the mock's token and finds none. It goes further: it drives a whole session
/// (install, browse, search, streams, playback, subtitles, library, settings) through real view models and checks every log line and
/// every persisted store for the token, then checks that the token IS where it belongs (the secret store).
@MainActor
@Suite struct PrivacyTests {
    private let token = "tok_SECRET_a1b2c3d4"

    @MainActor
    private final class Engines {
        var made: [MockEngine] = []
        func make(_ candidate: PlaybackCandidate) -> (any PlaybackEngine)? {
            let engine = MockEngine(.plays(duration: 60))
            made.append(engine)
            return engine
        }
    }

    @Test func aFullSessionLeavesNoTokenInLogsOrStores() async throws {
        let server = try MockServer.shared()
        let sink = MemoryLogSink()
        let logger = AddonLogger(sink: sink)
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: server.slowDelay + 4, maxRetries: 1, retryBackoff: 0.02), logger: logger)
        let addonStore = InMemoryAddonStore()
        let secrets = InMemorySecretStore()
        let defaultsName = "blusion.privacy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settingsStore = DefaultsSettingsStore(defaults: defaults, secrets: secrets)
        let progress = InMemoryProgressStore()
        let library = InMemoryLibraryStore()
        let engines = Engines()
        let registry = AddonRegistry(store: addonStore, secrets: secrets, client: client, logger: logger)
        let services = AppServices(registry: registry, client: client, settings: settingsStore, progress: progress, library: library,
                                   makeEngine: { engines.make($0) })

        // Install: one good catalog addon, one good stream addon, and some misbehaving ones, all with the token in their URL.
        let addons = AddonsViewModel(services: services)
        for (flags, base) in [([String](), server.catalogManifestURL(token: token)), ([], server.streamManifestURL(token: token)),
                              (["err500"], server.catalogManifestURL(flags: ["err500"], token: token)),
                              (["badjson"], server.streamManifestURL(flags: ["badjson"], token: token)),
                              (["badmanifest"], server.catalogManifestURL(flags: ["badmanifest"], token: token))] {
            _ = flags
            addons.installText = base.absoluteString
            await addons.install()
        }
        #expect(addons.lastInstalledName != nil || addons.errorMessage != nil)

        // Browse, search, detail.
        let home = HomeViewModel(services: services)
        await home.load()
        let discover = DiscoverViewModel(services: services)
        await discover.loadSources()
        await discover.loadMore()
        let search = SearchViewModel(services: services, debounce: .milliseconds(5))
        search.query = "movie 1"
        await search.submit()
        let detail = DetailViewModel(preview: MetaPreview(id: "mock:movie1", type: "movie", name: "Mock Movie 1"), services: services)
        await detail.load()
        await detail.toggleLibrary()
        await detail.setWatched(true, for: StreamRequest(type: "movie", id: "mock:other", title: "Other"))

        // Streams and playback with subtitles.
        let picker = StreamPickerViewModel(request: detail.movieRequest, services: services)
        await picker.load()
        guard case .play(let plan)? = await picker.playBest() else { Issue.record("expected a playable stream"); return }
        let player = PlayerViewModel(plan: plan, services: services)
        await player.start()
        engines.made.last?.simulate(position: 25)
        try await waitUntil { player.position == 25 }
        await player.waitForSubtitles()
        await player.close()

        // Settings, including a server URL that itself carries credentials.
        let settings = SettingsViewModel(services: services)
        await settings.load()
        settings.serverURLText = "http://user:\(token)@192.168.1.9:11470"
        await settings.commitServerURL()
        await settings.setSubtitleLanguage("eng")

        // 1. Logs.
        #expect(sink.lines.count > 20, "the session produced plenty of log lines to inspect (\(sink.lines.count))")
        for line in sink.lines {
            #expect(!line.contains(token), "token leaked into a log line: \(line)")
            #expect(!line.contains("/catalog/") && !line.contains("/stream/") && !line.contains("manifest.json"), "URL path leaked into a log line: \(line)")
        }

        // 2. Every persisted store except the secret store.
        let encoder = JSONEncoder()
        let persisted: [(String, String)] = [
            ("addon records", String(decoding: try encoder.encode(try await addonStore.loadAll()), as: UTF8.self)),
            ("progress", String(decoding: try encoder.encode(await progress.all()), as: UTF8.self)),
            ("library", String(decoding: try encoder.encode(await library.all()), as: UTF8.self)),
            ("user defaults", String(describing: defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("settings.") })),
        ]
        for (name, text) in persisted {
            #expect(!text.contains(token), "token leaked into persisted \(name)")
            // Progress and library keep the poster URL an addon published (so Continue Watching works offline), but never an
            // addon's own endpoints. Addon records and settings keep no hosts at all: those live only in the secret store.
            #expect(!text.contains("manifest.json") && !text.contains("/catalog/") && !text.contains("/stream/") && !text.contains("/subtitles/"),
                    "an addon endpoint leaked into persisted \(name)")
            if name == "addon records" || name == "user defaults" {
                #expect(!text.contains("127.0.0.1"), "a host leaked into persisted \(name)")
            }
        }
        let savedTitles = await library.all()
        let savedProgress = await progress.all()
        #expect(!savedTitles.isEmpty && !savedProgress.isEmpty, "there was real data to check")

        // 3. The token is exactly where it should be.
        let secretValues = await secrets.snapshot.values.joined(separator: "\n")
        #expect(secretValues.contains(token), "addon links and the server URL live in the secret store")
        #expect(await secrets.snapshot.keys.contains(DefaultsSettingsStore.Keys.serverSecret))

        // 4. User-visible text never shows it either.
        let visible = [addons.errorMessage, addons.lastInstalledName, player.failureMessage, player.notice, player.subtitleStatus]
            .compactMap { $0 } + search.failures.map(\.text) + picker.listing.failures.map { "\($0.addon.name): \($0.error.shortDescription)" }
        for text in visible { #expect(!text.contains(token), "token shown to the user: \(text)") }
        for addon in await registry.addons { #expect(!"\(addon)".contains(token) && !addon.displayHost.contains(token)) }
    }
}
