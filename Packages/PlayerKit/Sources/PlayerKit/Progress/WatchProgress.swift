import Foundation
import StremioKit

public struct WatchProgress: Sendable, Codable, Equatable, Identifiable {
    /// `StreamRequest.identity`: `movie/tt1` or `series/tt1:1:2`.
    public var id: String
    public var type: String
    public var contentID: String
    public var title: String
    public var poster: URL?
    public var position: TimeInterval
    public var duration: TimeInterval
    public var isWatched: Bool
    /// A newly queued episode uses a reserved, non-playable duration (-1). The state survives
    /// SwiftData round trips without changing its schema; regular playback replaces this marker.
    public var isQueuedForContinue: Bool {
        get { !isWatched && position == 0 && duration == -1 }
        set {
            if newValue {
                position = 0
                duration = -1
            } else if duration == -1 {
                duration = 0
            }
        }
    }
    public var updatedAt: Date
    public var season: Int?
    public var episode: Int?

    public init(id: String, type: String, contentID: String, title: String, poster: URL? = nil, position: TimeInterval, duration: TimeInterval,
                isWatched: Bool, updatedAt: Date, season: Int? = nil, episode: Int? = nil,
                isQueuedForContinue: Bool? = nil) {
        self.id = id
        self.type = type
        self.contentID = contentID
        self.title = title
        self.poster = poster
        self.position = position
        self.duration = isQueuedForContinue == true ? -1 : duration
        self.isWatched = isWatched
        self.updatedAt = updatedAt
        self.season = season
        self.episode = episode
    }

    public var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }

    /// The series a watched episode belongs to (`tt1` for `tt1:1:2`).
    public var seriesID: String? { type == "series" ? ContentID(contentID).baseID : nil }
}

public struct ProgressPolicy: Sendable, Equatable {
    public var saveInterval: TimeInterval
    /// Fraction of the runtime at which something counts as watched (PLAN M5: 90%).
    public var watchedThreshold: Double
    /// Don't offer to resume from the first few seconds.
    public var minimumResume: TimeInterval
    /// Nearly finished: start over instead of resuming into the credits.
    public var maximumResumeFraction: Double

    public init(saveInterval: TimeInterval = 10, watchedThreshold: Double = 0.9, minimumResume: TimeInterval = 5, maximumResumeFraction: Double = 0.95) {
        self.saveInterval = saveInterval
        self.watchedThreshold = watchedThreshold
        self.minimumResume = minimumResume
        self.maximumResumeFraction = maximumResumeFraction
    }

    public static let `default` = ProgressPolicy()
}

public protocol ProgressStore: Sendable {
    func progress(for identity: String) async -> WatchProgress?
    func progress(for identities: [String]) async -> [WatchProgress]
    func save(_ progress: WatchProgress) async
    func save(_ records: [WatchProgress]) async
    /// Most recently updated first.
    func all() async -> [WatchProgress]
    func remove(_ identity: String) async
    func remove(_ identities: [String]) async
    func clear() async
}

public extension ProgressStore {
    func progress(for identities: [String]) async -> [WatchProgress] {
        var records: [WatchProgress] = []
        for identity in identities { if let record = await progress(for: identity) { records.append(record) } }
        return records
    }
    func save(_ records: [WatchProgress]) async { for record in records { await save(record) } }
    func remove(_ identities: [String]) async { for identity in identities { await remove(identity) } }
}

public actor InMemoryProgressStore: ProgressStore {
    private var items: [String: WatchProgress] = [:]

    public init(_ initial: [WatchProgress] = []) {
        for item in initial { items[item.id] = item }
    }

    public func progress(for identity: String) async -> WatchProgress? { items[identity] }
    public func progress(for identities: [String]) async -> [WatchProgress] { identities.compactMap { items[$0] } }
    public func save(_ progress: WatchProgress) async { items[progress.id] = progress }
    public func save(_ records: [WatchProgress]) async { for record in records { items[record.id] = record } }
    public func all() async -> [WatchProgress] { items.values.sorted { $0.updatedAt > $1.updatedAt } }
    public func remove(_ identity: String) async { items[identity] = nil }
    public func remove(_ identities: [String]) async { for identity in identities { items[identity] = nil } }
    public func clear() async { items = [:] }
}

/// Decides when to persist progress. Pure and clock-injected: it never reads the time or touches a store itself.
public struct ProgressRecorder: Sendable {
    private let request: StreamRequest
    private let policy: ProgressPolicy
    private var wasWatched: Bool
    private var lastSavedAt: Date?
    private var startedAt: Date?
    private var latest: (position: TimeInterval, duration: TimeInterval)?

    public init(request: StreamRequest, previous: WatchProgress?, policy: ProgressPolicy = .default) {
        self.request = request
        self.policy = policy
        self.wasWatched = previous?.isWatched ?? false
    }

    /// Feed every position update. Returns a record to persist when one is due: every `saveInterval`, and at once when the
    /// watched threshold is crossed.
    public mutating func observe(position: TimeInterval, duration: TimeInterval?, now: Date) -> WatchProgress? {
        guard let duration, duration > 0, position >= 0, position.isFinite, duration.isFinite else { return nil }
        latest = (position, duration)
        if startedAt == nil { startedAt = now }
        let crossedWatched = !wasWatched && position / duration >= policy.watchedThreshold
        let reference = lastSavedAt ?? startedAt ?? now
        guard crossedWatched || now.timeIntervalSince(reference) >= policy.saveInterval else { return nil }
        lastSavedAt = now
        return record(now: now)
    }

    /// The record to write when playback stops. nil if nothing meaningful was observed.
    public mutating func finish(now: Date) -> WatchProgress? {
        guard latest != nil else { return nil }
        lastSavedAt = now
        return record(now: now)
    }

    private mutating func record(now: Date) -> WatchProgress? {
        guard let latest else { return nil }
        let watched = wasWatched || latest.position / latest.duration >= policy.watchedThreshold
        wasWatched = watched
        return WatchProgress(id: request.identity, type: request.type, contentID: request.id, title: request.title, poster: request.poster,
                             position: latest.position, duration: latest.duration, isWatched: watched, updatedAt: now,
                             season: request.season, episode: request.episode)
    }

    /// Where to start playing. 0 for new, watched, barely-started or nearly-finished items. When the length is unknown (a player
    /// reported only where the viewer stopped), the position is the resume point, since there is no end to measure it against.
    public static func resumePosition(for progress: WatchProgress?, policy: ProgressPolicy = .default) -> TimeInterval {
        guard let progress, !progress.isWatched else { return 0 }
        if progress.position < policy.minimumResume { return 0 }
        guard progress.duration > 0 else { return progress.position }
        if progress.position / progress.duration > policy.maximumResumeFraction { return 0 }
        return progress.position
    }
}
