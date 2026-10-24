import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

/// Auto Pick waiting for one addon, the Addon Speed page's model, and the resets that clear the speed test's results.
@MainActor
@Suite struct AddonSpeedFeatureTests {
    private let request = StreamRequest(type: "movie", id: "tt1", title: "Test Movie")

    private func body(_ streams: [String]) -> String { #"{"streams":[\#(streams.joined(separator: ","))]}"# }
    private func direct(_ name: String, _ url: String, _ description: String = "") -> String {
        #"{"name":"\#(name)","description":"\#(description)","url":"\#(url)"}"#
    }

    /// Addon `stubN` answers with `bodies[N]` after `delays[N]`, or fails when it is in `failing`.
    private func services(bodies: [String], delays: [Duration] = [], failing: Set<Int> = [],
                          speed: (any AddonSpeedStore)? = nil) async throws -> AppServices {
        let transport = StubTransport { request, _ in
            let index = Int(request.url?.host?.dropFirst(4).prefix(while: \.isNumber) ?? "0") ?? 0
            if index < delays.count { try await Task.sleep(for: delays[index]) }
            if failing.contains(index) { return StubTransport.response(Data(), status: 500, for: request) }
            return StubTransport.response(Data(bodies[index].utf8), for: request)
        }
        let (registry, client) = try await makeStubbedRegistry(manifests: bodies.indices.map { streamManifest("addon\($0)") }, transport: transport)
        return AppServices(registry: registry, client: client,
                           streams: StreamService(registry: registry, client: client, sniffer: StubSniffer([:])),
                           settings: InMemorySettingsStore(), addonSpeed: speed)
    }

    private func waitFor(_ wait: (AppServices) async -> AutoPickWait, autoPlay: Bool = true, in services: AppServices) async {
        var settings = PlaybackSettings(playerPreference: .infuse, autoPlayBestStream: autoPlay)
        settings.autoPickWait = await wait(services)
        await services.settings.save(settings)
    }

    private func elapsed(_ work: () async -> Void) async -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        await work()
        return start.duration(to: clock.now)
    }

    // MARK: Auto Pick

    @Test func autoPickActsOnceTheAddonItWaitsForHasAStream() async throws {
        let services = try await services(bodies: [body([direct("Fast 1080", "https://a.example.com/1.mkv", "1080p")]),
                                                   body([direct("Slow 2160", "https://b.example.com/1.mkv", "2160p")])],
                                          delays: [.milliseconds(10), .seconds(3)])
        await waitFor({ .addon(await $0.registry.addons[0].id) }, in: services)
        let model = StreamPickerViewModel(request: request, services: services)
        // As the picker does when it opens: streams go to Infuse, which is installed.
        model.setInstalledPlayers([.infuse])
        var choice: StreamPickerViewModel.Choice?
        let time = await elapsed {
            await model.loadForAutomaticSelection()
            choice = await model.autoPickBest()
        }
        #expect(time < .seconds(2), "it does not wait for the slow addon")
        #expect(model.listing.isLoading, "the slow addon is still answering")
        guard case .openInPlayer(.infuse, _)? = choice else { Issue.record("no hand-off"); return }
        #expect(model.autoPickedStream?.title == "Fast 1080", "from what had arrived")
        model.cancelLoading()
    }

    @Test func theFiveSecondWindowEndsOnceTheAddonHasAStream() async throws {
        let services = try await services(bodies: [body([direct("Fast", "https://a.example.com/1.mkv", "1080p")]),
                                                   body([direct("Slow", "https://b.example.com/1.mkv", "2160p")])],
                                          delays: [.milliseconds(10), .seconds(3)])
        await waitFor({ .addon(await $0.registry.addons[0].id) }, in: services)
        let model = StreamPickerViewModel(request: request, services: services)
        model.setInstalledPlayers([.infuse])
        let time = await elapsed { await model.loadForAutomaticSelection() }
        #expect(time < .seconds(2))
        #expect(model.listing.isLoading)
        model.cancelLoading()
    }

    /// The next episode looks for a stream continuing the last one, which may come from a slower addon: it keeps the whole window.
    @Test func theNextEpisodesLoadStillWaitsForEveryAddon() async throws {
        let services = try await services(bodies: [body([direct("Fast", "https://a.example.com/1.mkv", "1080p")]),
                                                   body([direct("Slow", "https://b.example.com/1.mkv", "2160p")])],
                                          delays: [.milliseconds(10), .milliseconds(400)])
        await waitFor({ .addon(await $0.registry.addons[0].id) }, in: services)
        let model = StreamPickerViewModel(request: request, services: services)
        model.setInstalledPlayers([.infuse])
        await model.loadForAutomaticSelection(stopsForWaitTarget: false)
        #expect(!model.listing.isLoading, "every addon answered")
    }

    @Test func turningTheSwitchOffStopsWaitingForOneAddon() async throws {
        let services = try await services(bodies: [body([direct("Fast", "https://a.example.com/1.mkv", "1080p")]),
                                                   body([direct("Slow 2160", "https://b.example.com/1.mkv", "2160p")])],
                                          delays: [.milliseconds(10), .milliseconds(400)])
        await waitFor({ .addon(await $0.registry.addons[0].id) }, in: services)
        let model = StreamPickerViewModel(request: request, services: services)
        model.setInstalledPlayers([.infuse])
        let loading = Task { await model.load() }
        while !model.hasLoaded { try await Task.sleep(for: .milliseconds(10)) }
        await model.setAutoPlaysBestStream(false)
        _ = await model.autoPickBest()
        #expect(model.autoPickedStream?.title == "Slow 2160", "it waited for every addon")
        await loading.value
    }

    @Test func whenTheAddonItWaitsForFailsItWaitsForEveryAddon() async throws {
        let services = try await services(bodies: [body([]), body([direct("Slow 2160", "https://b.example.com/1.mkv", "2160p")])],
                                          delays: [.milliseconds(10), .milliseconds(400)], failing: [0])
        await waitFor({ .addon(await $0.registry.addons[0].id) }, in: services)
        let model = StreamPickerViewModel(request: request, services: services)
        // As the picker does when it opens: streams go to Infuse, which is installed.
        model.setInstalledPlayers([.infuse])
        await model.loadForAutomaticSelection()
        let choice = await model.autoPickBest()
        #expect(!model.listing.isLoading, "it waited for the other addon")
        guard case .openInPlayer(.infuse, _)? = choice else { Issue.record("no hand-off"); return }
        #expect(model.autoPickedStream?.title == "Slow 2160")
    }

    @Test func whenTheAddonItWaitsForHasNothingPlayableItWaitsForEveryAddon() async throws {
        let services = try await services(bodies: [body([]), body([direct("Slow", "https://b.example.com/1.mkv", "1080p")])],
                                          delays: [.milliseconds(10), .milliseconds(300)])
        await waitFor({ .addon(await $0.registry.addons[0].id) }, in: services)
        let model = StreamPickerViewModel(request: request, services: services)
        // As the picker does when it opens: streams go to Infuse, which is installed.
        model.setInstalledPlayers([.infuse])
        await model.loadForAutomaticSelection()
        _ = await model.autoPickBest()
        #expect(!model.listing.isLoading)
        #expect(model.autoPickedStream?.title == "Slow")
    }

    @Test func withAutoPicksSwitchOffItWaitsForEveryAddonAsBefore() async throws {
        let services = try await services(bodies: [body([direct("Fast", "https://a.example.com/1.mkv", "1080p")]),
                                                   body([direct("Slow 2160", "https://b.example.com/1.mkv", "2160p")])],
                                          delays: [.milliseconds(10), .milliseconds(400)])
        await waitFor({ .addon(await $0.registry.addons[0].id) }, autoPlay: false, in: services)
        let model = StreamPickerViewModel(request: request, services: services)
        // As the picker does when it opens: streams go to Infuse, which is installed.
        model.setInstalledPlayers([.infuse])
        await model.load()
        _ = await model.autoPickBest()
        #expect(model.autoPickedStream?.title == "Slow 2160", "every addon answered, and the sharpest won")
    }

    @Test func autoWaitsForTheFastestTestedAddon() async throws {
        let speed = InMemoryAddonSpeedStore()
        let services = try await services(bodies: [body([direct("Slow 2160", "https://a.example.com/1.mkv", "2160p")]),
                                                   body([direct("Fast 2160", "https://b.example.com/1.mkv", "2160p")])],
                                          delays: [.seconds(3), .milliseconds(10)], speed: speed)
        let ids = await services.registry.addons.map(\.id)
        await speed.save([ids[0]: AddonSpeedResult(samples: [3, 3, 3], attempts: 3, bestResolution: 2160),
                          ids[1]: AddonSpeedResult(samples: [0.4, 0.5, 0.6], attempts: 3, bestResolution: 2160)])
        await waitFor({ _ in .fastest }, in: services)
        let model = StreamPickerViewModel(request: request, services: services)
        // As the picker does when it opens: streams go to Infuse, which is installed.
        model.setInstalledPlayers([.infuse])
        let time = await elapsed {
            await model.loadForAutomaticSelection()
            _ = await model.autoPickBest()
        }
        #expect(time < .seconds(2))
        #expect(model.autoPickedStream?.title == "Fast 2160")
        model.cancelLoading()
    }

    // MARK: The page

    @Test func choosingAutoWithNothingTestedStartsATest() async throws {
        let speed = InMemoryAddonSpeedStore()
        let services = try await services(bodies: [body([direct("A", "https://a.example.com/1.mkv", "1080p")])], speed: speed)
        let model = AddonSpeedViewModel(services: services)
        await model.load()
        #expect(model.rows.count == 1 && model.rows[0].result == nil)
        await model.choose(.fastest)
        #expect(await services.settings.load().autoPickWait == .fastest)
        #expect(model.rows[0].result != nil, "the test ran")
        #expect(await speed.results().count == 1)
    }

    @Test func aNamedAddonThatIsGoneShowsAsEveryAddon() async throws {
        let services = try await services(bodies: [body([])])
        var settings = PlaybackSettings()
        settings.autoPickWait = .addon(UUID())
        await services.settings.save(settings)
        let model = AddonSpeedViewModel(services: services)
        await model.load()
        #expect(model.shownWait == .allAddons)
        #expect(AddonSpeedViewModel.summary(for: .addon(UUID()), names: [:]) == "All addons")
    }

    @Test func eachRowSaysHowItDid() {
        #expect(AddonSpeedViewModel.detail(for: nil) == "Not tested yet")
        #expect(AddonSpeedViewModel.detail(for: AddonSpeedResult(isApplicable: false)) == "Has no streams for the test titles")
        #expect(AddonSpeedViewModel.detail(for: AddonSpeedResult(attempts: 6, failures: 6)) == "Failed every request")
        let good = AddonSpeedResult(samples: [1.2, 1.4, 1.6], attempts: 3, bestResolution: 2160)
        #expect(AddonSpeedViewModel.detail(for: good).hasSuffix("s · 3 of 3 · 4K"))
    }

    // MARK: Resets

    @Test(arguments: [DataResetService.Scope.addons, .everything])
    func clearingAddonsForgetsTheSpeedTest(scope: DataResetService.Scope) async throws {
        let speed = InMemoryAddonSpeedStore([UUID(): AddonSpeedResult(samples: [1], attempts: 1)])
        let services = try await services(bodies: [body([])], speed: speed)
        await DataResetService(services: services).clear(scope)
        #expect(await speed.results().isEmpty)
    }

    @Test func theSettingsResetWaitsForEveryAddonAgain() async throws {
        let services = try await services(bodies: [body([])])
        var settings = PlaybackSettings()
        settings.autoPickWait = .fastest
        await services.settings.save(settings)
        await DataResetService(services: services).clear(.settings)
        #expect(await services.settings.load().autoPickWait == .allAddons)
    }
}
