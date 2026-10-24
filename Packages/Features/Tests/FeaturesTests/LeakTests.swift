import Foundation
import Testing
import PlayerKit
import PlayerKitTestSupport
import StremioKit
import StremioKitTestSupport
@testable import Features

/// PLAN M8 leak pass, host half: every view model (and what it started) is released once its screen is gone, including its tasks.
/// The simulator half is `scripts/leaks.sh` (docs/DEVICE_CHECKLIST.md).
@MainActor
@Suite struct LeakTests {
    private let srt = "1\n00:00:01,000 --> 00:00:03,000\nFirst cue\n"

    private func mockServices() async throws -> AppServices {
        let server = try MockServer.shared()
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: 5, maxRetries: 0))
        let registry = AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client)
        _ = try await registry.install(from: server.catalogManifestURL(token: "leak").absoluteString)
        _ = try await registry.install(from: server.streamManifestURL(token: "leak").absoluteString)
        return AppServices(registry: registry, client: client, makeEngine: { _ in MockEngine(.plays(duration: 60)) })
    }

    private func expectNoLeaks(_ leaked: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(leaked.isEmpty, "still alive after the screen went away: \(leaked)", sourceLocation: sourceLocation)
    }

    @Test func homeIsReleasedAfterItsObservationIsCancelled() async throws {
        expectNoLeaks(try await survivors {
            let services = try await mockServices()
            let model = HomeViewModel(services: services)
            let observing = Task { await model.observeAddons() }
            try await waitUntil { model.phase == .ready }
            observing.cancel()
            await observing.value
            return [("HomeViewModel", model), ("AddonRegistry", services.registry)]
        })
    }

    @Test func discoverIsReleased() async throws {
        expectNoLeaks(try await survivors {
            let services = try await mockServices()
            let model = DiscoverViewModel(services: services)
            await model.loadSources()
            await model.loadMore()
            return [("DiscoverViewModel", model)]
        })
    }

    @Test func searchIsReleasedEvenWithADebouncedSearchPending() async throws {
        expectNoLeaks(try await survivors {
            let services = try await mockServices()
            let model = SearchViewModel(services: services, debounce: .milliseconds(30))
            model.query = "movie"
            model.queryDidChange()   // leaves a debounced task running when the screen goes away
            return [("SearchViewModel", model)]
        })
        expectNoLeaks(try await survivors {
            let model = SearchViewModel(services: try await mockServices(), debounce: .milliseconds(1))
            model.query = "movie 1"
            await model.submit()
            return [("SearchViewModel (after a search)", model)]
        })
    }

    @Test func detailIsReleased() async throws {
        expectNoLeaks(try await survivors {
            let model = DetailViewModel(preview: MetaPreview(id: "mock:movie1", type: "movie", name: "Mock Movie 1"), services: try await mockServices())
            await model.load()
            await model.toggleLibrary()
            return [("DetailViewModel", model)]
        })
    }

    @Test func theStreamPickerIsReleased() async throws {
        expectNoLeaks(try await survivors {
            let model = StreamPickerViewModel(request: StreamRequest(type: "movie", id: "mock:movie1", title: "Mock Movie 1"), services: try await mockServices())
            await model.load()
            _ = await model.playBest()
            return [("StreamPickerViewModel", model)]
        })
    }

    private func playerModel(_ services: AppServices) -> PlayerViewModel {
        let candidate = PlaybackCandidate(id: "a", title: "A", addonName: "X", route: .native(URL(string: "https://e.example.com/a.mp4")!))
        return PlayerViewModel(plan: PlaybackPlan(request: StreamRequest(type: "movie", id: "tt1", title: "Movie"), candidates: [candidate]), services: services)
    }

    @Test func thePlayerAndItsEngineAreReleasedAfterClose() async throws {
        expectNoLeaks(try await survivors {
            let services = try await mockServices()
            let model = playerModel(services)
            await model.start()
            try await waitUntil { model.isPlaying }
            await model.close()
            return [("PlayerViewModel", model)]
        })
    }

    /// The screen always calls close() when it disappears; this documents that nothing is kept alive if it were ever skipped.
    @Test func aPlayerThatIsDroppedWithoutCloseStillGoesAway() async throws {
        expectNoLeaks(try await survivors {
            let model = playerModel(try await mockServices())
            await model.start()
            try await waitUntil { model.isPlaying }
            return [("PlayerViewModel", model)]
        })
    }

    @Test func theHelperReallyCatchesALeak() async throws {
        final class Cycle {
            var me: Cycle?
            init() { me = self }
        }
        let leaked = try await survivors(timeout: .milliseconds(100)) { [("cycle", Cycle())] }
        #expect(leaked == ["cycle"], "a retain cycle must be reported, or the other tests prove nothing")
    }

    @Test func libraryAndSettingsAreReleased() async throws {
        expectNoLeaks(try await survivors {
            let services = try await mockServices()
            let library = LibraryViewModel(services: services)
            await library.load()
            let settings = SettingsViewModel(services: services)
            await settings.load()
            await settings.setSubtitleLanguage("eng")
            await settings.clear(.history)
            let addons = AddonsViewModel(services: services)
            let observing = Task { await addons.observe() }
            try await Task.sleep(for: .milliseconds(50))
            observing.cancel()
            await observing.value
            return [("LibraryViewModel", library), ("SettingsViewModel", settings), ("AddonsViewModel", addons)]
        })
    }
}
