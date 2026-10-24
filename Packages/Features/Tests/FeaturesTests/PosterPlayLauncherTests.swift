import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
import PlayerKit
@testable import Features

/// Holding a poster to play it: what starts, and what letting go calls off.
@MainActor
@Suite struct PosterPlayLauncherTests {
    private let movie = MetaPreview(id: "tt0111161", type: "movie", name: "Film")
    private let other = MetaPreview(id: "tt0068646", type: "movie", name: "Other")

    /// What a launcher was asked for, and how many holds failed.
    @MainActor
    private final class Probe {
        var failures = 0
        var asked: [String] = []
    }

    private func launcher(_ probe: Probe, answer: StreamRequest? = nil, delay: Duration = .zero) -> PosterPlayLauncher {
        PosterPlayLauncher(nextRequest: { item in
            probe.asked.append(item.id)
            if delay > .zero { try? await Task.sleep(for: delay) }
            return answer ?? StreamRequest(movie: item)
        }, failed: { probe.failures += 1 })
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func aHeldPosterSpinsAndItsStreamsLoad() async {
        let probe = Probe()
        let launcher = launcher(probe)
        launcher.begin(movie)
        #expect(launcher.isLoading(movie) && !launcher.isLoading(other), "only the held poster spins")
        await settle()
        #expect(launcher.launch?.request.id == movie.id)
        #expect(probe.asked == [movie.id])
    }

    @Test func lettingGoBeforeAStreamStartsCallsEverythingOff() async {
        let probe = Probe()
        let launcher = launcher(probe)
        launcher.begin(movie)
        await settle()
        #expect(launcher.launch != nil)
        launcher.end(movie)
        #expect(launcher.launch == nil && !launcher.isLoading(movie), "the picker goes, so its loads are cancelled and nothing opens")
        #expect(probe.failures == 0, "letting go is not a failure")
    }

    @Test func lettingGoWhileTheEpisodeIsStillBeingFoundStartsNothing() async throws {
        let probe = Probe()
        let launcher = launcher(probe, delay: .milliseconds(200))
        launcher.begin(movie)
        launcher.end(movie)
        try await Task.sleep(for: .milliseconds(300))
        #expect(launcher.launch == nil, "the lookup's answer arrives after the finger lifted, and is dropped")
    }

    @Test func aStartedStreamStaysWhenTheFingerLifts() async {
        let probe = Probe()
        let launcher = launcher(probe)
        launcher.begin(movie)
        await settle()
        let id = try? #require(launcher.launch?.id)
        launcher.finish(id ?? UUID(), started: true)
        #expect(!launcher.isLoading(movie), "the spinner stops once the stream has started")
        launcher.end(movie)
        #expect(launcher.launch?.id == id, "the player it opened belongs to its picker, which stays")
    }

    @Test func nothingToPlayStopsTheSpinnerAndFails() async {
        let probe = Probe()
        let launcher = launcher(probe)
        launcher.begin(movie)
        await settle()
        launcher.finish(launcher.launch?.id ?? UUID(), started: false)
        #expect(launcher.launch == nil && !launcher.isLoading(movie))
        #expect(probe.failures == 1)
        let empty = PosterPlayLauncher(nextRequest: { _ in nil }, failed: { probe.failures += 1 })
        empty.begin(movie)
        await settle()
        #expect(empty.launch == nil && probe.failures == 2, "a series with nothing to play fails the same way")
    }

    @Test func theLiftThatEndsAHoldIsNotATap() async throws {
        let launcher = launcher(Probe())
        #expect(!launcher.isHeldPress(movie))
        launcher.pressBecameHold(movie)
        #expect(launcher.isHeldPress(movie) && !launcher.isHeldPress(other))
        launcher.holdLifted(movie)
        #expect(launcher.isHeldPress(movie), "a tap the lift ends, just after it, is still the hold's")
        // A busy test run can be slow to give the release its turn, so it is waited for, up to five seconds.
        for _ in 0..<100 where launcher.isHeldPress(movie) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!launcher.isHeldPress(movie), "a later tap is a tap again")
        launcher.holdLifted(movie)
        #expect(!launcher.isHeldPress(movie))
    }

    @Test func aSecondPosterHeldMeanwhileIsIgnored() async {
        let probe = Probe()
        let launcher = launcher(probe)
        launcher.begin(movie)
        launcher.begin(other)
        await settle()
        #expect(launcher.launch?.preview == movie && probe.asked == [movie.id])
        launcher.end(other)
        #expect(launcher.launch != nil, "letting go of another poster changes nothing")
    }

    @Test func aSeriesPlaysTheEpisodeItsPagesPlayWould() async throws {
        let server = try MockServer.shared()
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: 5, maxRetries: 0))
        let services = AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client),
                                   client: client)
        _ = try await services.registry.install(from: server.catalogManifestURL().absoluteString)
        await services.progress.save(WatchProgress(id: "series/mock:series1:2:2", type: "series", contentID: "mock:series1:2:2", title: "E",
                                                   position: 300, duration: 1200, isWatched: false, updatedAt: Date(), season: 2, episode: 2))
        let request = await PosterPlayLauncher.request(for: MetaPreview(id: "mock:series1", type: "series", name: "S"), services: services)
        #expect(request?.id == "mock:series1:2:2")
        let film = await PosterPlayLauncher.request(for: movie, services: services)
        #expect(film?.id == movie.id && film?.type == "movie")
    }
}
