import Foundation

/// Asks every addon that can answer for streams, and probes ambiguous URLs, without ever blocking on the slowest addon.
public final class StreamService: Sendable {
    public let registry: AddonRegistry
    public let client: AddonClient
    private let sniffer: any ContainerSniffing
    /// How many ranged sniff requests run at once.
    private let sniffConcurrency: Int
    /// Lookups started ahead of the picker (see `prefetch`).
    private let prefetches = StreamPrefetchCache()
    /// Told how long each addon took to answer, so the speed results learn from real loads (see `AddonSpeedStore`).
    private let timings: (any StreamTimingRecorder)?

    public init(registry: AddonRegistry, client: AddonClient, sniffer: (any ContainerSniffing)? = nil, sniffConcurrency: Int = 4,
                timings: (any StreamTimingRecorder)? = nil) {
        self.registry = registry
        self.client = client
        self.sniffer = sniffer ?? RangedContainerSniffer(client: client)
        self.sniffConcurrency = max(1, sniffConcurrency)
        self.timings = timings
    }

    /// Addons that will be asked, in the user's order, and the stream of their answers as each arrives. A lookup started by `prefetch` for
    /// this title is used when it is still live; otherwise the addons are asked now.
    public func fetch(_ request: StreamRequest) async -> (asked: [AddonSummary], responses: AsyncStream<AddonResponse<[AddonStream]>>) {
        if let cached = await prefetches.claim(key: Self.prefetchKey(request)) { return cached }
        return await fetchFresh(request)
    }

    /// Expired credentials must come from a new addon response, never a previously prefetched listing.
    public func fetchUncached(_ request: StreamRequest) async -> (asked: [AddonSummary], responses: AsyncStream<AddonResponse<[AddonStream]>>) {
        await fetchFresh(request)
    }

    /// Starts the addons' stream lookup for a title now, so the picker finds it loaded. One lookup per title while it lives. Never sniffs, never plays.
    public func prefetch(_ request: StreamRequest) async {
        let key = Self.prefetchKey(request)
        await prefetches.prefetch(key: key) { [self] in await fetchFresh(request) }
    }

    /// Returns once the lookup `prefetch` started for this title has every answer, or at once when none is running.
    public func waitForPrefetch(_ request: StreamRequest) async {
        await prefetches.waitUntilFinished(key: Self.prefetchKey(request))
    }

    /// The title's page was left: an unclaimed lookup is cancelled after a short grace period.
    public func releasePrefetch(_ request: StreamRequest) {
        let key = Self.prefetchKey(request)
        Task { await prefetches.release(key: key) }
    }

    private static func prefetchKey(_ request: StreamRequest) -> String { "\(request.type)/\(request.id)" }

    private func fetchFresh(_ request: StreamRequest) async -> (asked: [AddonSummary], responses: AsyncStream<AddonResponse<[AddonStream]>>) {
        let addons = await registry.addons(for: .stream, type: request.type, id: request.id)
        let client = self.client
        let timings = self.timings
        // Each answer is timed here, once, as it arrives: a prefetched lookup that the picker claims later is not timed again. The time is
        // recorded on a task of its own, so no answer waits on it. An answer with no streams says nothing about the addon's speed for
        // titles it has, and is not counted, nor is a load made while offline. A load called off after `cutOffSample` counts with the
        // time it had run: the addon took at least that long, and leaving it out would make a slow addon look fast.
        let responses = FanOut.run(over: addons) { addon in
            let clock = ContinuousClock()
            let started = clock.now
            do {
                let streams = try await client.streams(base: addon.baseURL, type: request.type, id: request.id)
                if let timings, !streams.isEmpty {
                    let elapsed = started.duration(to: clock.now)
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    Task.detached(priority: .utility) {
                        let sharpest = streams.compactMap { StreamQuality.parse($0).resolution }.max()
                        await timings.record(addon.id, seconds: seconds, resolution: sharpest)
                    }
                }
                return streams
            } catch {
                if let timings {
                    let elapsed = started.duration(to: clock.now)
                    if Task.isCancelled || StreamService.isCancellation(error) {
                        if elapsed >= StreamService.cutOffSample {
                            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                            Task.detached(priority: .utility) { await timings.record(addon.id, seconds: seconds, resolution: nil) }
                        }
                    } else if StreamService.countsAsFailure(error) {
                        Task.detached(priority: .utility) { await timings.record(addon.id, seconds: nil, resolution: nil) }
                    }
                }
                throw error
            }
        }
        return (addons.map(\.summary), responses)
    }

    /// A load called off after running this long is counted with the time it ran (see `fetchFresh`).
    static let cutOffSample: Duration = .seconds(1)

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || AddonError.from(error) == .cancelled
    }

    /// Whether a failed answer counts against the addon: not when the load was called off, the device is offline, or the addon simply has
    /// nothing for this title.
    static func countsAsFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        switch AddonError.from(error) {
        case .cancelled, .offline, .notFound: return false
        default: return true
        }
    }

    /// Probes `targets` with at most `sniffConcurrency` requests in flight and yields each result as it completes.
    public func sniff(_ targets: [StreamListing.SniffTarget]) -> AsyncStream<(key: String, container: MediaContainer?)> {
        let sniffer = self.sniffer
        let limit = sniffConcurrency
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: (String, MediaContainer?).self) { group in
                    var iterator = targets.makeIterator()
                    var running = 0
                    func startNext(_ group: inout TaskGroup<(String, MediaContainer?)>) -> Bool {
                        guard let target = iterator.next() else { return false }
                        group.addTask { (target.key, await sniffer.sniff(url: target.url, headers: target.headers)) }
                        return true
                    }
                    while running < limit, startNext(&group) { running += 1 }
                    while let result = await group.next() {
                        continuation.yield((key: result.0, container: result.1))
                        if !Task.isCancelled, startNext(&group) { continue }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
