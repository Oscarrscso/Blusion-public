import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

/// Real loads keep the speed results up to date, and Auto keeps its addon until another is clearly faster.
@Suite struct AddonSpeedTimingTests {
    // MARK: A result learning from loads

    @Test func onlyTheNewestSamplesAreKept() {
        var result = AddonSpeedResult()
        for second in 1...25 { result.record(seconds: Double(second), resolution: 1080, at: Date()) }
        #expect(result.samples.count == AddonSpeedResult.window)
        #expect(result.samples.first == 6 && result.samples.last == 25)
        #expect(result.attempts == AddonSpeedResult.window && result.failures == 0)
        #expect(result.isApplicable && result.bestResolution == 1080)
    }

    @Test func reliabilityFollowsRecentRequests() {
        var result = AddonSpeedResult(samples: [1], attempts: 20, failures: 10, bestResolution: 2160)
        for _ in 0..<20 { result.record(seconds: 1, resolution: nil, at: Date()) }
        #expect(result.attempts == AddonSpeedResult.window)
        #expect(result.reliability == 1, "twenty good answers push the old failures out")
        #expect(result.bestResolution == 2160, "a load with no stated resolution keeps the sharpest known")
        result.record(seconds: nil, resolution: nil, at: Date())
        #expect(result.failures == 1 && result.attempts == AddonSpeedResult.window)
    }

    @Test func aStoreRecordsIntoTheSameResults() async throws {
        let suite = "addon-speed-timing-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DefaultsAddonSpeedStore(defaults: defaults)
        let id = UUID()
        await store.save([id: AddonSpeedResult(samples: [2], attempts: 1, bestResolution: 1080)])
        await store.record(id, seconds: 1, resolution: 2160)
        await store.record(id, seconds: nil, resolution: nil)
        let result = try #require(await store.results()[id])
        #expect(result.samples == [2, 1] && result.attempts == 3 && result.failures == 1 && result.bestResolution == 2160)
        await store.setAutoPick(id)
        #expect(await store.autoPick() == id)
        await store.clear()
        let emptied = await store.results().isEmpty
        let pick = await store.autoPick()
        #expect(emptied && pick == nil)
    }

    // MARK: Auto keeps its addon

    private func result(_ median: Double) -> AddonSpeedResult {
        AddonSpeedResult(samples: [median, median, median], attempts: 3, bestResolution: 2160)
    }

    @Test func autoKeepsItsAddonUntilAnotherIsClearlyFaster() {
        let held = UUID(), rival = UUID()
        func pick(_ heldMedian: Double, _ rivalMedian: Double) -> UUID? {
            AddonSpeedChoice.fastest(enabled: [held, rival], results: [held: result(heldMedian), rival: result(rivalMedian)],
                                     preferredResolution: nil, current: held)
        }
        #expect(pick(2.0, 1.8) == held, "10% faster is not enough")
        #expect(pick(1.0, 0.75) == held, "25% faster but only 0.25 s")
        #expect(pick(2.0, 1.5) == rival, "25% and 0.5 s faster")
        #expect(pick(4.0, 1.0) == rival)
    }

    @Test func aTieKeepsTheHeldAddonOrElseTheEarlierOne() {
        let first = UUID(), second = UUID()
        let results = [first: result(1), second: result(1)]
        #expect(AddonSpeedChoice.fastest(enabled: [first, second], results: results, preferredResolution: nil, current: second) == second)
        #expect(AddonSpeedChoice.fastest(enabled: [first, second], results: results, preferredResolution: nil) == first)
    }

    @Test func aHeldAddonThatNoLongerQualifiesIsReplaced() {
        let held = UUID(), rival = UUID()
        var flaky = result(0.5)
        flaky.attempts = 10
        flaky.failures = 5
        #expect(AddonSpeedChoice.fastest(enabled: [held, rival], results: [held: flaky, rival: result(2)], preferredResolution: nil,
                                         current: held) == rival)
        #expect(AddonSpeedChoice.fastest(enabled: [rival], results: [held: result(0.1), rival: result(2)], preferredResolution: nil,
                                         current: held) == rival, "a disabled addon is not kept")
    }

    // MARK: Real loads are timed

    private final class Recorder: StreamTimingRecorder, @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(UUID, Double?)] = []
        var recorded: [(UUID, Double?)] { lock.withLock { entries } }
        func record(_ addon: UUID, seconds: Double?, resolution: Int?) async { lock.withLock { entries.append((addon, seconds)) } }
    }

    private static let answer = #"{"streams":[{"name":"A","description":"1080p","url":"https://a.example.com/1.mkv"}]}"#

    /// Addon `stubN` answers with a stream, or with `statuses[N]`.
    private func service(statuses: [Int], recorder: Recorder) async throws -> (StreamService, AddonRegistry) {
        let transport = StubTransport { request, _ in
            let index = Int(request.url?.host?.dropFirst(4).prefix(while: \.isNumber) ?? "0") ?? 0
            let status = statuses[index]
            return StubTransport.response(status == 200 ? Data(Self.answer.utf8) : Data(), status: status, for: request)
        }
        let (registry, client) = try await makeStubbedRegistry(manifests: statuses.indices.map { streamManifest("addon\($0)") },
                                                               transport: transport)
        return (StreamService(registry: registry, client: client, timings: recorder), registry)
    }

    private func drain(_ service: StreamService, _ request: StreamRequest) async {
        let (_, responses) = await service.fetch(request)
        for await _ in responses {}
    }

    /// Waits for the recordings, which run on tasks of their own.
    private func settle(_ recorder: Recorder, count: Int) async {
        for _ in 0..<200 where recorder.recorded.count < count { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func eachAddonsAnswerIsTimedOnce() async throws {
        let recorder = Recorder()
        let (service, registry) = try await service(statuses: [200, 500, 404], recorder: recorder)
        await drain(service, StreamRequest(type: "movie", id: "tt1", title: "Film"))
        await settle(recorder, count: 2)
        try await Task.sleep(for: .milliseconds(50))
        let ids = await registry.addons.map(\.id)
        let recorded = recorder.recorded
        #expect(recorded.filter { $0.0 == ids[0] }.count == 1 && recorded.first { $0.0 == ids[0] }?.1 != nil, "a timed answer")
        #expect(recorded.filter { $0.0 == ids[1] }.count == 1 && recorded.first { $0.0 == ids[1] }?.1 == nil, "a failure")
        #expect(!recorded.contains { $0.0 == ids[2] }, "an addon with nothing for the title is not counted")
    }

    @Test func aClaimedPrefetchIsNotTimedAgain() async throws {
        let recorder = Recorder()
        let (service, _) = try await service(statuses: [200], recorder: recorder)
        let request = StreamRequest(type: "movie", id: "tt1", title: "Film")
        await service.prefetch(request)
        await drain(service, request)
        await settle(recorder, count: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.recorded.count == 1)
    }

    @Test func anEmptyAnswerIsNotTimed() async throws {
        let recorder = Recorder()
        let transport = StubTransport { request, _ in StubTransport.response(Data(#"{"streams":[]}"#.utf8), for: request) }
        let (registry, client) = try await makeStubbedRegistry(manifests: [streamManifest("addon0")], transport: transport)
        let service = StreamService(registry: registry, client: client, timings: recorder)
        await drain(service, StreamRequest(type: "movie", id: "tt1", title: "Film"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.recorded.isEmpty, "an addon with nothing for the title is not fast, just empty")
    }

    @Test func aCalledOffOrOfflineLoadSaysNothingAboutTheAddon() {
        #expect(!StreamService.countsAsFailure(CancellationError()))
        #expect(!StreamService.countsAsFailure(AddonError.cancelled))
        #expect(!StreamService.countsAsFailure(AddonError.offline))
        #expect(!StreamService.countsAsFailure(AddonError.notFound))
        #expect(StreamService.countsAsFailure(AddonError.timeout))
        #expect(StreamService.countsAsFailure(AddonError.http(status: 500)))
        #expect(StreamService.isCancellation(CancellationError()) && StreamService.isCancellation(AddonError.cancelled))
        #expect(!StreamService.isCancellation(AddonError.timeout))
    }
}
