import Foundation

/// What Auto Pick waits for before it chooses a stream: every addon (as it always has), the fastest addon by the speed test, or one
/// addon the user named. With an addon to wait for, Auto Pick acts as soon as that addon has answered with a stream it can start,
/// ranking everything that has arrived by then. When that addon fails, has nothing it can start or does not cover the title, Auto Pick
/// waits for every addon as before.
public enum AutoPickWait: Sendable, Equatable, Hashable, Codable {
    case allAddons
    /// The fastest addon by the speed test (`AddonSpeedChoice.fastest`).
    case fastest
    case addon(UUID)

    /// How it is saved: "all", "auto", or the addon's id.
    public var storedValue: String {
        switch self {
        case .allAddons: "all"
        case .fastest: "auto"
        case .addon(let id): id.uuidString
        }
    }

    /// A saved value read back. Nothing saved, or anything unreadable, is every addon.
    public init(storedValue: String?) {
        switch storedValue {
        case "auto": self = .fastest
        case let text?: self = UUID(uuidString: text).map(AutoPickWait.addon) ?? .allAddons
        case nil: self = .allAddons
        }
    }
}

/// One addon's showing in the speed test. Only numbers and the time it was tested: never an address, which can carry a token.
public struct AddonSpeedResult: Sendable, Equatable, Codable {
    /// Seconds each successful answer took, in the order they came.
    public var samples: [Double]
    /// Requests made, and how many of them timed out or failed.
    public var attempts: Int
    public var failures: Int
    /// The sharpest stream any answer offered, as a vertical resolution (2160 for 4K). Nil when none said.
    public var bestResolution: Int?
    /// False when the addon offers streams for none of the test's titles: it is not slow, it simply has nothing to say.
    public var isApplicable: Bool
    public var testedAt: Date
    /// Whether each of the newest requests from real loads succeeded, oldest first, at most `window` of them: what `attempts` and
    /// `failures` count once loads have been timed. Nil for a result that only the test has made.
    public var recent: [Bool]?

    public init(samples: [Double] = [], attempts: Int = 0, failures: Int = 0, bestResolution: Int? = nil, isApplicable: Bool = true,
                testedAt: Date = Date()) {
        self.samples = samples
        self.attempts = attempts
        self.failures = failures
        self.bestResolution = bestResolution
        self.isApplicable = isApplicable
        self.testedAt = testedAt
    }

    public var successes: Int { attempts - failures }

    /// The middle of the successful samples, in seconds. Nil before any succeeded.
    public var median: Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// The share of requests that succeeded, from 0 to 1. Zero before any was made.
    public var reliability: Double { attempts == 0 ? 0 : Double(successes) / Double(attempts) }

    /// How many recent samples are kept, and how many recent requests reliability is reckoned over.
    public static let window = 20

    /// Adds one real load's answer: its time in seconds, or nil when it failed, and the sharpest stream it offered. Only the newest
    /// `window` samples are kept, and the counts cover the newest `window` requests (`recent`), so recent answers decide.
    public mutating func record(seconds: Double?, resolution: Int?, at date: Date) {
        isApplicable = true
        if let seconds {
            samples.append(seconds)
            if samples.count > Self.window { samples.removeFirst(samples.count - Self.window) }
        }
        // A result from the test has counts but no list yet: its requests start the list.
        var outcomes = recent ?? Array(repeating: true, count: max(0, successes)) + Array(repeating: false, count: failures)
        outcomes.append(seconds != nil)
        if outcomes.count > Self.window { outcomes.removeFirst(outcomes.count - Self.window) }
        recent = outcomes
        attempts = outcomes.count
        failures = outcomes.filter { !$0 }.count
        if let resolution { bestResolution = max(bestResolution ?? 0, resolution) }
        testedAt = date
    }
}

/// Told how long each addon's stream answer took in a real load (see `StreamService`).
public protocol StreamTimingRecorder: Sendable {
    /// `seconds` is nil for a request that failed; `resolution` is the sharpest stream the answer offered.
    func record(_ addon: UUID, seconds: Double?, resolution: Int?) async
}

/// Where the speed test's results are kept, by addon id, with what real loads add to them and the addon Auto waits for now.
public protocol AddonSpeedStore: StreamTimingRecorder {
    func results() async -> [UUID: AddonSpeedResult]
    func save(_ results: [UUID: AddonSpeedResult]) async
    /// The addon Auto waits for now, kept so Auto only moves to another one that is clearly faster (see `AddonSpeedChoice.fastest`).
    func autoPick() async -> UUID?
    func setAutoPick(_ id: UUID?) async
    func clear() async
}

public actor InMemoryAddonSpeedStore: AddonSpeedStore {
    private var stored: [UUID: AddonSpeedResult]
    private var pick: UUID?

    public init(_ results: [UUID: AddonSpeedResult] = [:]) {
        stored = results
    }

    public func results() async -> [UUID: AddonSpeedResult] { stored }
    public func save(_ results: [UUID: AddonSpeedResult]) async { stored = results }
    public func autoPick() async -> UUID? { pick }
    public func setAutoPick(_ id: UUID?) async { pick = id }

    public func record(_ addon: UUID, seconds: Double?, resolution: Int?) async {
        var result = stored[addon] ?? AddonSpeedResult()
        result.record(seconds: seconds, resolution: resolution, at: Date())
        stored[addon] = result
    }

    public func clear() async {
        stored = [:]
        pick = nil
    }
}

/// JSON in UserDefaults under "addons.speed.v1", keyed by addon id, and Auto's current pick under "addons.speed.auto.v1".
public final class DefaultsAddonSpeedStore: AddonSpeedStore, @unchecked Sendable {
    public static let key = "addons.speed.v1"
    public static let autoPickKey = "addons.speed.auto.v1"

    private let defaults: UserDefaults
    /// Each operation reads or writes the whole table, so two of them must not interleave.
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func results() async -> [UUID: AddonSpeedResult] {
        lock.withLock { load() }
    }

    public func save(_ results: [UUID: AddonSpeedResult]) async {
        lock.withLock { store(results) }
    }

    public func record(_ addon: UUID, seconds: Double?, resolution: Int?) async {
        lock.withLock {
            var all = load()
            var result = all[addon] ?? AddonSpeedResult()
            result.record(seconds: seconds, resolution: resolution, at: Date())
            all[addon] = result
            store(all)
        }
    }

    public func autoPick() async -> UUID? {
        lock.withLock { defaults.string(forKey: Self.autoPickKey).flatMap(UUID.init(uuidString:)) }
    }

    public func setAutoPick(_ id: UUID?) async {
        lock.withLock {
            if let id { defaults.set(id.uuidString, forKey: Self.autoPickKey) } else { defaults.removeObject(forKey: Self.autoPickKey) }
        }
    }

    public func clear() async {
        lock.withLock {
            defaults.removeObject(forKey: Self.key)
            defaults.removeObject(forKey: Self.autoPickKey)
        }
    }

    /// Unreadable data loads as nothing: the test can be run again.
    private func load() -> [UUID: AddonSpeedResult] {
        guard let data = defaults.data(forKey: Self.key),
              let table = try? JSONDecoder().decode([String: AddonSpeedResult].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: table.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private func store(_ results: [UUID: AddonSpeedResult]) {
        let table = Dictionary(uniqueKeysWithValues: results.map { ($0.key.uuidString, $0.value) })
        guard !table.isEmpty, let data = try? JSONEncoder().encode(table) else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        defaults.set(data, forKey: Self.key)
    }
}

/// Which addon Auto Pick waits for.
public enum AddonSpeedChoice {
    /// An addon counts as reliable when at least this share of its requests succeeded.
    public static let minimumReliability = 0.8
    /// Auto moves from its current addon only to one whose median is at least this much smaller, both as a share and in seconds, so a
    /// few lucky answers do not make it hop between two addons that are about as fast.
    public static let switchShare = 0.25
    public static let switchSeconds = 0.3

    /// The addon Auto Pick waits for under `wait`, among the enabled addons `enabled` (in the user's order). Nil means every addon: the
    /// choice is every addon, the named addon is removed or disabled, or no addon qualifies for Auto.
    public static func target(for wait: AutoPickWait, enabled: [UUID], results: [UUID: AddonSpeedResult],
                              preferredResolution: Int?, current: UUID? = nil) -> UUID? {
        switch wait {
        case .allAddons: nil
        case .addon(let id): enabled.contains(id) ? id : nil
        case .fastest: fastest(enabled: enabled, results: results, preferredResolution: preferredResolution, current: current)
        }
    }

    /// Auto's pick: the lowest median among addons that took part, succeeded at least `minimumReliability` of the time, and found streams
    /// as sharp as the sharpest any addon found (no sharper than the preferred resolution, when one is set). A tie goes to the addon
    /// earlier in the user's order. Nil when none qualifies or nothing has been tested.
    ///
    /// `current` is the addon Auto waits for now. While it still qualifies it stays, unless the fastest is clearly faster: its median at
    /// least `switchShare` smaller and `switchSeconds` shorter.
    public static func fastest(enabled: [UUID], results: [UUID: AddonSpeedResult], preferredResolution: Int?,
                               current: UUID? = nil) -> UUID? {
        let tested = enabled.compactMap { id in results[id].map { (id, $0) } }.filter { $0.1.isApplicable && $0.1.attempts > 0 }
        guard let sharpest = tested.compactMap(\.1.bestResolution).max() else { return nil }
        let wanted = preferredResolution.map { min($0, sharpest) } ?? sharpest
        var qualifying: [(id: UUID, median: Double)] = []
        for (id, result) in tested {
            guard result.reliability >= minimumReliability, let median = result.median, (result.bestResolution ?? 0) >= wanted else { continue }
            qualifying.append((id, median))
        }
        // The lowest median; a tie goes to the addon earlier in the user's order, which `qualifying` keeps.
        guard let best = qualifying.min(by: { $0.median < $1.median }) else { return nil }
        guard let current, let held = qualifying.first(where: { $0.id == current }), held.id != best.id else { return best.id }
        let clearlyFaster = best.median <= held.median * (1 - switchShare) && best.median <= held.median - switchSeconds
        return clearlyFaster ? best.id : held.id
    }
}

/// Times every enabled addon's stream answers for a few well-known titles, so the user can see which is fastest and Auto Pick can
/// wait for it. Every request does a real lookup (debrid addons check their caches), so it runs only when asked. It has its own client:
/// no retries and no cache, so each sample is a real answer, and it never uses or claims the stream service's prefetches.
public final class AddonSpeedTester: Sendable {
    /// A film and an episode to ask for, by IMDb id. An addon is asked for each one its manifest covers.
    public struct Round: Sendable, Equatable {
        public let movie: String?
        public let episode: String?

        public init(movie: String?, episode: String?) {
            self.movie = movie
            self.episode = episode
        }
    }

    /// Three rounds, each a different film and episode, all titles every stream addon knows.
    public static let rounds = [
        Round(movie: "tt1375666", episode: "tt0903747:1:1"),
        Round(movie: "tt0468569", episode: "tt0944947:1:1"),
        Round(movie: "tt0111161", episode: "tt0903747:2:5"),
    ]

    private let registry: AddonRegistry
    /// A client given for tests. Nil makes a fresh one for each run (`makeClient`), so nothing is set up until a test is asked for.
    private let client: AddonClient?
    private let rounds: [Round]

    public init(registry: AddonRegistry, client: AddonClient? = nil, rounds: [Round] = AddonSpeedTester.rounds) {
        self.registry = registry
        self.client = client
        self.rounds = rounds
    }

    /// No retries, a 15 s deadline, and no cache: an answer served from a cache, or a retry after a timeout, would not be the addon's speed.
    public static func makeClient() -> AddonClient {
        let configuration = URLSessionTransport.defaultConfiguration()
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return AddonClient(configuration: AddonClientConfiguration(timeout: 15, streamTimeout: 15, maxRetries: 0),
                           transport: URLSessionTransport(configuration: configuration))
    }

    /// Runs the test. Every enabled addon is asked at once, as a real load does, and each asks for its titles one after another.
    public func run(now: @escaping @Sendable () -> Date = { Date() }) async -> [UUID: AddonSpeedResult] {
        let addons = await registry.addons.filter(\.isEnabled)
        let client = client ?? Self.makeClient()
        let rounds = rounds
        return await withTaskGroup(of: (UUID, AddonSpeedResult).self) { group in
            for addon in addons {
                group.addTask { (addon.id, await Self.test(addon, rounds: rounds, client: client, now: now)) }
            }
            var results: [UUID: AddonSpeedResult] = [:]
            for await (id, result) in group { results[id] = result }
            return results
        }
    }

    private static func test(_ addon: InstalledAddon, rounds: [Round], client: AddonClient,
                             now: @Sendable () -> Date) async -> AddonSpeedResult {
        var result = AddonSpeedResult(isApplicable: false)
        let probes = rounds.flatMap { round in [("movie", round.movie), ("series", round.episode)] }
        for case let (type, id?) in probes where addon.manifest.supports(.stream, type: type, id: id) {
            guard !Task.isCancelled else { break }
            result.isApplicable = true
            result.attempts += 1
            let clock = ContinuousClock()
            let started = clock.now
            do {
                let streams = try await client.streams(base: addon.baseURL, type: type, id: id)
                let elapsed = started.duration(to: clock.now)
                result.samples.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                let sharpest = streams.compactMap { StreamQuality.parse($0).resolution }.max()
                if let sharpest { result.bestResolution = max(result.bestResolution ?? 0, sharpest) }
            } catch {
                result.failures += 1
            }
        }
        result.testedAt = now()
        return result
    }
}
