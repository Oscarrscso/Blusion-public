import Foundation

/// A stream handed to another player, remembered until that player calls back, so where the viewer stopped can be recorded even
/// if Blusion was closed in between. It holds no stream URL, since those can carry secrets.
public struct PlaybackHandoff: Sendable, Codable, Equatable, Identifiable {
    public enum Action: String, Sendable, Codable { case play, save, download }

    /// The token in the callback URLs.
    public var id: String
    public var request: StreamRequest
    public var player: ExternalPlayer
    public var startedAt: Date
    /// Missing in older records, which are playback hand-offs.
    public var action: Action?

    public var isPlayback: Bool { action == nil || action == .play }

    public init(id: String = UUID().uuidString, request: StreamRequest, player: ExternalPlayer, startedAt: Date = Date(), action: Action? = nil) {
        self.id = id
        self.request = request
        self.player = player
        self.startedAt = startedAt
        self.action = action
    }

    fileprivate func replaces(_ other: PlaybackHandoff) -> Bool {
        id == other.id || (isPlayback && other.isPlayback && request.identity == other.request.identity)
    }
}

public protocol HandoffStore: Sendable {
    func save(_ handoff: PlaybackHandoff) async
    /// Returns and removes the hand-off with this token.
    func take(id: String) async -> PlaybackHandoff?
    func clear() async
}

/// What both stores keep: the 20 newest hand-offs, and none older than 7 days.
enum HandoffRetention {
    static let maximumCount = 20
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    static func kept(_ handoffs: [PlaybackHandoff], now: Date = Date()) -> [PlaybackHandoff] {
        let fresh = handoffs.filter { now.timeIntervalSince($0.startedAt) <= maximumAge }
        return Array(fresh.sorted { $0.startedAt > $1.startedAt }.prefix(maximumCount))
    }
}

public actor InMemoryHandoffStore: HandoffStore {
    private var handoffs: [PlaybackHandoff] = []

    public init() {}

    public func save(_ handoff: PlaybackHandoff) async {
        // A new play supersedes the previous launch's callback; saving a bookmark never supersedes playback.
        handoffs.removeAll { handoff.replaces($0) }
        handoffs = HandoffRetention.kept(handoffs + [handoff])
    }

    public func take(id: String) async -> PlaybackHandoff? {
        guard let index = handoffs.firstIndex(where: { $0.id == id }) else { return nil }
        return handoffs.remove(at: index)
    }

    public func clear() async {
        handoffs = []
    }
}

/// JSON in UserDefaults under "playback.handoffs.v1". Keeps only the 20 newest; hand-offs older than 7 days are dropped on save.
public final class DefaultsHandoffStore: HandoffStore, @unchecked Sendable {
    public static let key = "playback.handoffs.v1"

    private let defaults: UserDefaults
    /// Each operation reads and writes the whole list, so two of them must not interleave.
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(_ handoff: PlaybackHandoff) async {
        lock.withLock {
            var all = load().filter { !handoff.replaces($0) }
            all.append(handoff)
            store(HandoffRetention.kept(all))
        }
    }

    public func take(id: String) async -> PlaybackHandoff? {
        lock.withLock { () -> PlaybackHandoff? in
            var all = load()
            guard let index = all.firstIndex(where: { $0.id == id }) else { return nil }
            let found = all.remove(at: index)
            store(all)
            return found
        }
    }

    public func clear() async {
        lock.withLock { defaults.removeObject(forKey: Self.key) }
    }

    /// Unreadable data loads as nothing: a hand-off that cannot be read is no worse than one that was never saved.
    private func load() -> [PlaybackHandoff] {
        guard let data = defaults.data(forKey: Self.key), let all = try? JSONDecoder().decode([PlaybackHandoff].self, from: data) else {
            return []
        }
        return all
    }

    private func store(_ handoffs: [PlaybackHandoff]) {
        guard !handoffs.isEmpty, let data = try? JSONEncoder().encode(handoffs) else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        defaults.set(data, forKey: Self.key)
    }
}
