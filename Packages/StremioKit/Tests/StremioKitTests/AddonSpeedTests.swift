import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

/// The addon speed test, its results and what Auto picks from them.
@Suite struct AddonSpeedTests {
    /// Stream answers: a 4K and a 1080p stream, or a 1080p one only.
    private static let fourK = #"{"streams":[{"name":"A","description":"2160p","url":"https://a.example.com/1.mkv"},{"name":"B","description":"1080p","url":"https://a.example.com/2.mkv"}]}"#
    private static let hd = #"{"streams":[{"name":"C","description":"1080p","url":"https://b.example.com/1.mkv"}]}"#

    /// Addon `stubN` answers after `delays[N]`, with `bodies[N]`, or fails with 500 when it is in `failing`.
    private func tester(bodies: [String], delays: [Duration] = [], failing: Set<Int> = [], manifests: [Manifest]? = nil,
                        rounds: [AddonSpeedTester.Round] = AddonSpeedTester.rounds)
        async throws -> (tester: AddonSpeedTester, registry: AddonRegistry, transport: StubTransport) {
        let transport = StubTransport { request, _ in
            let index = Int(request.url?.host?.dropFirst(4).prefix(while: \.isNumber) ?? "0") ?? 0
            if index < delays.count { try await Task.sleep(for: delays[index]) }
            if failing.contains(index) { return StubTransport.response(Data(), status: 500, for: request) }
            return StubTransport.response(Data(bodies[index].utf8), for: request)
        }
        let (registry, _) = try await makeStubbedRegistry(manifests: manifests ?? bodies.indices.map { streamManifest("addon\($0)") },
                                                         transport: transport)
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: 15, streamTimeout: 15, maxRetries: 0), transport: transport)
        return (AddonSpeedTester(registry: registry, client: client, rounds: rounds), registry, transport)
    }

    @Test func eachAddonIsTimedOnEveryTitleItCovers() async throws {
        let (tester, registry, transport) = try await tester(bodies: [Self.fourK, Self.hd], delays: [.milliseconds(5), .milliseconds(60)])
        let results = await tester.run()
        let ids = await registry.addons.map(\.id)
        let fast = try #require(results[ids[0]])
        let slow = try #require(results[ids[1]])
        #expect(fast.attempts == 6 && fast.successes == 6, "three films and three episodes each")
        #expect(fast.samples.count == 6)
        let fastMedian = try #require(fast.median)
        let slowMedian = try #require(slow.median)
        #expect(fastMedian < slowMedian)
        #expect(fast.bestResolution == 2160 && slow.bestResolution == 1080)
        #expect(fast.isApplicable && slow.isApplicable)
        #expect(transport.requests.count == 12, "one request per title per addon: no retries")
    }

    @Test func failuresCountAndAreNotTimed() async throws {
        let (tester, registry, _) = try await tester(bodies: [Self.fourK], failing: [0])
        let results = await tester.run()
        let result = try #require(results[await registry.addons[0].id])
        #expect(result.attempts == 6 && result.failures == 6 && result.successes == 0)
        #expect(result.median == nil && result.samples.isEmpty)
        #expect(result.reliability == 0)
    }

    @Test func anAddonThatCoversNoneOfTheTitlesIsNotApplicable() async throws {
        let animeOnly = Manifest(id: "stream.kitsu", name: "Anime", version: "1",
                                          resources: [ResourceDescriptor(name: "stream", types: ["series"], idPrefixes: ["kitsu:"])],
                                          types: ["series"])
        let (tester, registry, transport) = try await tester(bodies: [Self.hd], manifests: [animeOnly])
        let result = try #require(await tester.run()[await registry.addons[0].id])
        #expect(!result.isApplicable)
        #expect(result.attempts == 0)
        #expect(transport.requests.isEmpty)
    }

    @Test func everyRunAsksAgain() async throws {
        let (tester, _, transport) = try await tester(bodies: [Self.hd], rounds: [AddonSpeedTester.Round(movie: "tt1375666", episode: nil)])
        _ = await tester.run()
        _ = await tester.run()
        #expect(transport.requests.count == 2, "nothing is served from a cache")
        #expect(transport.requests.allSatisfy { $0.cachePolicy != .returnCacheDataElseLoad && $0.cachePolicy != .returnCacheDataDontLoad })
    }

    @Test func theTestersOwnClientHasNoRetriesAndNoCache() {
        let client = AddonSpeedTester.makeClient()
        #expect(client.configuration.maxRetries == 0)
        #expect(client.configuration.streamTimeout == 15 && client.configuration.timeout == 15)
    }

    // MARK: Auto's choice

    private func result(_ samples: [Double], attempts: Int? = nil, failures: Int = 0, best: Int? = 2160) -> AddonSpeedResult {
        AddonSpeedResult(samples: samples, attempts: attempts ?? samples.count + failures, failures: failures, bestResolution: best)
    }

    @Test func autoPicksTheFastestReliableAddonWithTheSharpestStreams() {
        let a = UUID(), b = UUID(), c = UUID()
        let results = [a: result([2.0, 2.2, 2.4]), b: result([0.5, 0.6, 0.7], best: 1080), c: result([1.0, 1.1, 1.2])]
        #expect(AddonSpeedChoice.fastest(enabled: [a, b, c], results: results, preferredResolution: nil) == c,
                "b is fastest but never found 4K")
        #expect(AddonSpeedChoice.fastest(enabled: [a, b, c], results: results, preferredResolution: 1080) == b,
                "with 1080p preferred, 1080p is sharp enough")
    }

    @Test func anUnreliableAddonIsPassedOver() {
        let a = UUID(), b = UUID()
        let results = [a: result([0.2, 0.2, 0.2], attempts: 6, failures: 3), b: result([1.0, 1.0, 1.0, 1.0, 1.0], attempts: 6, failures: 1)]
        #expect(AddonSpeedChoice.fastest(enabled: [a, b], results: results, preferredResolution: nil) == b, "a failed half the time; b 5 of 6")
    }

    @Test func aTieGoesToTheAddonEarlierInTheList() {
        let a = UUID(), b = UUID()
        let results = [a: result([1.0]), b: result([1.0])]
        #expect(AddonSpeedChoice.fastest(enabled: [b, a], results: results, preferredResolution: nil) == b)
    }

    @Test func withNothingTestedOrNoneQualifyingAutoWaitsForEveryAddon() {
        let a = UUID()
        #expect(AddonSpeedChoice.target(for: .fastest, enabled: [a], results: [:], preferredResolution: nil) == nil)
        let failed = [a: result([], attempts: 6, failures: 6, best: nil)]
        #expect(AddonSpeedChoice.target(for: .fastest, enabled: [a], results: failed, preferredResolution: nil) == nil)
    }

    @Test func aNamedAddonThatIsGoneMeansEveryAddon() {
        let a = UUID(), gone = UUID()
        #expect(AddonSpeedChoice.target(for: .addon(a), enabled: [a], results: [:], preferredResolution: nil) == a)
        #expect(AddonSpeedChoice.target(for: .addon(gone), enabled: [a], results: [:], preferredResolution: nil) == nil)
        #expect(AddonSpeedChoice.target(for: .allAddons, enabled: [a], results: [a: result([0.1])], preferredResolution: nil) == nil)
    }

    @Test func theChoiceIsSavedAsText() {
        let id = UUID()
        for wait in [AutoPickWait.allAddons, .fastest, .addon(id)] {
            #expect(AutoPickWait(storedValue: wait.storedValue) == wait)
        }
        #expect(AutoPickWait(storedValue: nil) == .allAddons)
        #expect(AutoPickWait(storedValue: "garbage") == .allAddons)
    }

    @Test func theMedianIsTheMiddleSample() {
        #expect(result([3, 1, 2]).median == 2)
        #expect(result([4, 1, 3, 2]).median == 2.5)
        #expect(result([]).median == nil)
    }

    // MARK: Store

    @Test func theStoreKeepsResultsByAddonAndClears() async throws {
        let suite = "addon-speed-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DefaultsAddonSpeedStore(defaults: defaults)
        let id = UUID()
        let saved = [id: AddonSpeedResult(samples: [1.25], attempts: 1, bestResolution: 1080, testedAt: Date(timeIntervalSince1970: 1_000))]
        await store.save(saved)
        #expect(await DefaultsAddonSpeedStore(defaults: defaults).results() == saved)
        await store.clear()
        #expect(await store.results().isEmpty)
    }

    /// An addon's address can carry its token. The results are numbers and ids only.
    @Test func noAddressReachesTheStore() async throws {
        let suite = "addon-speed-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (tester, _, _) = try await tester(bodies: [Self.fourK])
        let store = DefaultsAddonSpeedStore(defaults: defaults)
        await store.save(await tester.run())
        let text = String(decoding: try #require(defaults.data(forKey: DefaultsAddonSpeedStore.key)), as: UTF8.self)
        #expect(!text.contains("example.com") && !text.contains("TOKEN") && !text.contains("http"))
    }

    // MARK: Against the mock addon

    /// The mock addon with flag-slow answers after its slow delay: the test sees it as the slower one.
    @Test func theMockAddonsSlowFlagIsSlower() async throws {
        let server = try MockServer.shared()
        let store = InMemoryAddonStore()
        let secrets = InMemorySecretStore()
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: 15, streamTimeout: 15, maxRetries: 0))
        let registry = AddonRegistry(store: store, secrets: secrets, client: client)
        let fast = try await registry.install(from: server.streamManifestURL().absoluteString)
        let slow = try await registry.install(from: server.streamManifestURL(flags: ["slow"]).absoluteString)
        let tester = AddonSpeedTester(registry: registry, client: client, rounds: [AddonSpeedTester.Round(movie: "mock:movie1", episode: nil)])
        let results = await tester.run()
        let fastMedian = try #require(results[fast.id]?.median)
        let slowMedian = try #require(results[slow.id]?.median)
        #expect(slowMedian >= server.slowDelay * 0.9)
        #expect(fastMedian < slowMedian)
    }
}
