import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

private actor InFlightCounter {
    private(set) var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

private struct CountingSniffer: ContainerSniffing {
    let counter: InFlightCounter
    func sniff(url: URL, headers: [String: String]) async -> MediaContainer? {
        await counter.enter()
        try? await Task.sleep(for: .milliseconds(40))
        await counter.leave()
        return url.lastPathComponent == "mkv" ? .matroska : .mp4
    }
}

@Suite struct StreamServiceTests {
    private struct Rig {
        let service: StreamService
        let registry: AddonRegistry
        let client: AddonClient
        let server: MockServer
    }

    private func makeRig(sniffer: (any ContainerSniffing)? = nil) throws -> Rig {
        let server = try MockServer.shared()
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: server.slowDelay + 4, maxRetries: 0, retryBackoff: 0.01))
        let registry = AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client)
        return Rig(service: StreamService(registry: registry, client: client, sniffer: sniffer), registry: registry, client: client, server: server)
    }

    private let movie = StreamRequest(type: "movie", id: "mock:movie1", title: "Mock Movie 1")

    @Test func asksOnlyAddonsThatCanAnswerAndYieldsEveryStream() async throws {
        let rig = try makeRig()
        _ = try await rig.registry.install(from: rig.server.catalogManifestURL().absoluteString)      // no stream resource
        let streams = try await rig.registry.install(from: rig.server.streamManifestURL().absoluteString)
        let (asked, responses) = await rig.service.fetch(movie)
        #expect(asked.map(\.id) == [streams.id])
        let all = await responses.collect()
        #expect(all.count == 1)
        #expect(all.first?.value?.count == 10)
    }

    @Test func nothingIsAskedWhenNoAddonSupportsTheId() async throws {
        let rig = try makeRig()
        _ = try await rig.registry.install(from: rig.server.streamManifestURL().absoluteString)
        let (asked, responses) = await rig.service.fetch(StreamRequest(type: "movie", id: "tt1234567", title: "IMDb"))
        #expect(asked.isEmpty)
        #expect(await responses.collect().isEmpty)
    }

    @Test func theFirstResultAppearsBeforeTheSlowestAddonAnswers() async throws {
        let rig = try makeRig()
        _ = try await rig.registry.install(from: rig.server.streamManifestURL(flags: ["slow"], token: "slow").absoluteString)
        _ = try await rig.registry.install(from: rig.server.streamManifestURL(token: "fast").absoluteString)
        let (asked, responses) = await rig.service.fetch(movie)
        var listing = StreamListing(asking: asked)
        let started = Date()
        var firstItemAfter: TimeInterval?
        var visibleWhileSlowPending = 0
        for await response in responses {
            listing.apply(response)
            if firstItemAfter == nil, !listing.isEmpty {
                firstItemAfter = elapsed(since: started)
                visibleWhileSlowPending = listing.isLoading ? listing.items.count : 0
            }
        }
        #expect((firstItemAfter ?? 99) < rig.server.slowDelay * 0.6, "first result after \(firstItemAfter ?? -1)s")
        #expect(visibleWhileSlowPending > 0, "the picker already had streams while the slow addon was pending")
        #expect(!listing.isLoading)
        #expect(listing.groups.count == 2 || listing.items.allSatisfy { $0.alsoProvidedBy.count == 1 }, "identical files from both addons were merged")
    }

    @Test func aFailingAddonBecomesAChipNotAnError() async throws {
        let rig = try makeRig()
        _ = try await rig.registry.install(from: rig.server.streamManifestURL(flags: ["err500"], token: "bad").absoluteString)
        _ = try await rig.registry.install(from: rig.server.streamManifestURL(token: "good").absoluteString)
        let (asked, responses) = await rig.service.fetch(movie)
        var listing = StreamListing(asking: asked)
        for await response in responses { listing.apply(response) }
        #expect(listing.failures.map(\.error) == [.http(status: 500)])
        #expect(!listing.isEmpty)
    }

    @Test func realMockStreamsRouteAsDocumented() async throws {
        let rig = try makeRig()
        _ = try await rig.registry.install(from: rig.server.streamManifestURL().absoluteString)
        let (asked, responses) = await rig.service.fetch(movie)
        var listing = StreamListing(asking: asked)
        for await response in responses { listing.apply(response) }
        // Before sniffing: the extensionless blob is tried natively; mkv files are unsupported without the fallback engine.
        let byTitle = Dictionary(uniqueKeysWithValues: listing.items.map { ($0.title, $0) })
        #expect(byTitle["Mock MP4"]?.route.sortClass == 0)
        #expect(byTitle["Mock HLS"]?.route.sortClass == 0)
        #expect(byTitle["Mock Protected"]?.route.sortClass == 0)
        #expect(byTitle["Mock MKV AC3"]?.route == .unsupported(.matroska))
        #expect(byTitle["Mock MKV DTS"]?.route == .unsupported(.matroska))
        #expect(byTitle["Mock External"]?.route.sortClass == 3, "links to web pages sort after unsupported streams")
        #expect(byTitle["Mock YouTube"]?.route.sortClass == 3)
        #expect(byTitle["Mock Torrent"] == nil && byTitle["Mock NZB"] == nil, "hidden streams are not listed")
        #expect(Set(listing.hidden.map(\.reason)) == [.needsStreamingServer, .usenetOrArchive])
        #expect(listing.best?.title == "Mock MP4", "1080p MP4 outranks the 720p HLS")
        #expect(listing.items.map(\.title).prefix(2) == ["Mock MP4", "Mock HLS"])
        #expect(listing.sniffTargets.map(\.url.lastPathComponent) == ["mp4"], "only the extensionless blob needs probing")
    }

    // MARK: sniffing

    @Test(.enabled(if: MockServer.hasMediaFixtures, "needs generated media: run Tools/MockAddon/make-fixtures.sh (ffmpeg)"))
    func sniffingIdentifiesContainersBehindExtensionlessURLs() async throws {
        let rig = try makeRig()
        let base = rig.server.stream.appendingPathComponent("media/blob")
        let targets = ["mp4", "mkv", "hls"].map { StreamListing.SniffTarget(key: $0, url: base.appendingPathComponent($0), headers: [:]) }
        var results: [String: MediaContainer?] = [:]
        for await result in rig.service.sniff(targets) { results[result.key] = .some(result.container) }
        #expect(results["mp4"] == .some(.mp4))
        #expect(results["mkv"] == .some(.matroska))
        #expect(results["hls"] == .some(.hls))
    }

    @Test(.enabled(if: MockServer.hasMediaFixtures, "needs generated media: run Tools/MockAddon/make-fixtures.sh (ffmpeg)"))
    func sniffingCarriesProxyHeaders() async throws {
        let rig = try makeRig()
        let url = rig.server.stream.appendingPathComponent("media/protected.mp4")
        var withoutHeader: MediaContainer??
        for await result in rig.service.sniff([.init(key: "k", url: url, headers: [:])]) { withoutHeader = .some(result.container) }
        #expect(withoutHeader == .some(nil), "the server answers 403: no verdict, not a crash")
        var withHeader: MediaContainer??
        for await result in rig.service.sniff([.init(key: "k", url: url, headers: ["X-Mock-Token": "abc"])]) { withHeader = .some(result.container) }
        #expect(withHeader == .some(.mp4))
    }

    @Test func unreachableHostsYieldNoVerdict() async throws {
        let rig = try makeRig()
        let target = StreamListing.SniffTarget(key: "k", url: URL(string: "http://127.0.0.1:1/blob")!, headers: [:])
        var seen: [MediaContainer?] = []
        for await result in rig.service.sniff([target]) { seen.append(result.container) }
        #expect(seen.count == 1 && seen[0] == nil)
    }

    @Test func sniffingNeverExceedsItsConcurrencyLimit() async throws {
        let counter = InFlightCounter()
        let rig = try makeRig(sniffer: CountingSniffer(counter: counter))
        let limited = StreamService(registry: rig.registry, client: rig.client, sniffer: CountingSniffer(counter: counter), sniffConcurrency: 3)
        let targets = (0..<12).map { StreamListing.SniffTarget(key: "k\($0)", url: URL(string: "https://e.example.com/\($0 % 2 == 0 ? "mkv" : "mp4")")!, headers: [:]) }
        var count = 0
        for await _ in limited.sniff(targets) { count += 1 }
        #expect(count == 12)
        #expect(await counter.peak <= 3)
        #expect(await counter.peak >= 2, "it did run in parallel")
        #expect(await counter.current == 0)
    }

    @Test func cancellingTheConsumerStopsFurtherProbes() async throws {
        let counter = InFlightCounter()
        let rig = try makeRig(sniffer: CountingSniffer(counter: counter))
        let limited = StreamService(registry: rig.registry, client: rig.client, sniffer: CountingSniffer(counter: counter), sniffConcurrency: 1)
        let targets = (0..<50).map { StreamListing.SniffTarget(key: "k\($0)", url: URL(string: "https://e.example.com/mp4")!, headers: [:]) }
        var seen = 0
        for await _ in limited.sniff(targets) {
            seen += 1
            if seen == 2 { break }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await counter.current == 0)
        #expect(await counter.peak == 1)
    }

    @Test(.enabled(if: MockServer.hasMediaFixtures, "needs generated media: run Tools/MockAddon/make-fixtures.sh (ffmpeg)"))
    func sniffedResultsFlowBackIntoTheListing() async throws {
        let rig = try makeRig()
        _ = try await rig.registry.install(from: rig.server.streamManifestURL().absoluteString)
        let (asked, responses) = await rig.service.fetch(movie)
        var listing = StreamListing(asking: asked)
        for await response in responses { listing.apply(response) }
        for await result in rig.service.sniff(listing.sniffTargets) { listing.setContainer(result.container, forKey: result.key) }
        #expect(listing.sniffTargets.isEmpty)
        #expect(listing.items.first { $0.title == "Mock Blob" }?.container == .mp4)
        #expect(listing.items.first { $0.title == "Mock Blob" }?.route.sortClass == 0)
    }
}
