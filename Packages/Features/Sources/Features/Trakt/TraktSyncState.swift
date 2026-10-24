import Foundation
import StremioKit

/// One change waiting to reach Trakt. The queue holds at most one per title and slot (saved, watched, playback): a later change to the
/// same title replaces the earlier one, so it holds what Trakt should end up with, not every step on the way.
public struct TraktSyncOperation: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// On, or off, the Trakt watchlist. The collection is never written.
        case save, unsave
        /// In, or out of, the watched history.
        case watched, unwatched
        /// A paused position, or the removal of Trakt's paused record.
        case progress, removePlayback
    }

    /// The three things kept in step with Trakt. A title has one pending operation in each at most.
    public enum Slot: String, Sendable {
        case saved, watched, playback
    }

    public var kind: Kind
    /// The local identity the change is about: `movie/tt1`, `series/tt1`, or `series/tt1:1:2` for an episode.
    public var identity: String
    /// When the user did it.
    public var at: Date
    /// The paused position as a percentage, for `.progress`.
    public var progress: Double?
    /// Requests this went out in that may have reached Trakt: counted as the request leaves, and taken back only when Trakt refused it
    /// outright. Zero means Trakt has certainly not seen it.
    public var attempts = 0
    /// The earliest time to send it. A playing title's position waits here until playback has been still for a moment.
    public var notBefore: Date

    /// Nil when Trakt cannot take the change: only IMDb movies, shows and episodes sync. Saving is about a whole title; the watched
    /// mark and the paused position are about a movie or one episode.
    public init?(kind: Kind, identity: String, at: Date, progress: Double? = nil, notBefore: Date? = nil) {
        guard let target = Self.target(of: identity) else { return nil }
        switch kind {
        case .save, .unsave:
            guard target.season == nil else { return nil }
        case .watched, .unwatched, .progress, .removePlayback:
            guard target.type == "movie" || target.season != nil else { return nil }
        }
        self.kind = kind
        self.identity = identity
        self.at = at
        self.progress = progress
        self.notBefore = notBefore ?? at
    }

    public var slot: Slot {
        switch kind {
        case .save, .unsave: return .saved
        case .watched, .unwatched: return .watched
        case .progress, .removePlayback: return .playback
        }
    }

    public var id: String { "\(slot.rawValue)|\(identity)" }

    /// The change that undoes this one, for the kinds that have one.
    var inverse: Kind? {
        switch kind {
        case .save: return .unsave
        case .unsave: return .save
        case .watched: return .unwatched
        case .unwatched: return .watched
        case .progress, .removePlayback: return nil
        }
    }

    /// True when the change puts something on Trakt rather than taking it off.
    var isAddition: Bool { kind == .save || kind == .watched }

    /// The title as Trakt's watchlist calls take it.
    var preview: MetaPreview {
        let target = Self.target(of: identity)
        return MetaPreview(id: target?.imdbID ?? "", type: target?.type ?? "")
    }

    /// The movie or episode as Trakt's history and scrobble calls take it.
    var watchedItem: TraktWatchedItem {
        let target = Self.target(of: identity)
        return TraktWatchedItem(preview: preview, watchedAt: at, season: target?.season, episode: target?.episode)
    }

    /// The parts of a local identity Trakt needs, or nil when it is not an IMDb movie, show or episode.
    private static func target(of identity: String) -> (type: String, imdbID: String, season: Int?, episode: Int?)? {
        guard let slash = identity.firstIndex(of: "/") else { return nil }
        let type = String(identity[..<slash])
        let content = ContentID(String(identity[identity.index(after: slash)...]))
        guard type == "movie" || type == "series", TraktAccount.isIMDb(content.baseID) else { return nil }
        switch content.kind {
        case .imdb: return (type, content.baseID, nil, nil)
        case .imdbEpisode(let season, let episode): return type == "series" ? (type, content.baseID, season, episode) : nil
        case .other: return nil
        }
    }
}

/// What two-way sync remembers between launches: the changes still to send, the deletions made here, and what Trakt held when it was
/// last read.
public struct TraktSyncState: Codable, Sendable, Equatable {
    /// The retry queue.
    public var operations: [TraktSyncOperation] = []
    /// Deletion events: when a saved title was removed here, by library identity. An import does not bring such a title back unless
    /// Trakt listed it after that.
    public var removedSaved: [String: Date] = [:]
    /// When a watched mark was cleared here, by progress identity. Trakt's older watch does not bring the mark back.
    public var unwatched: [String: Date] = [:]
    /// When a title was taken off Continue Watching here. Trakt's older paused record stays hidden.
    public var removedPlayback: [String: Date] = [:]
    /// The watchlist as Trakt last sent it. A title in here that Trakt no longer lists was removed somewhere else.
    public var syncedSaved: Set<String> = []
    /// The watched history as Trakt last sent it, by progress identity.
    public var syncedWatched: Set<String> = []
    /// Saved titles that are here only because Trakt's collection holds them. They are never put on the watchlist, and removing one
    /// here leaves the collection alone.
    public var collected: Set<String> = []
    /// Trakt's change dates when it was last read, so only what changed is fetched again.
    public var activities: TraktLastActivities?
    /// When everything was last read whatever the change dates said.
    public var lastFullPull: Date?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case operations, removedSaved, unwatched, removedPlayback, syncedSaved, syncedWatched, collected, activities, lastFullPull
    }

    /// A file written by an earlier build decodes with what it has; anything missing starts empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operations = try container.decodeIfPresent([TraktSyncOperation].self, forKey: .operations) ?? []
        removedSaved = try container.decodeIfPresent([String: Date].self, forKey: .removedSaved) ?? [:]
        unwatched = try container.decodeIfPresent([String: Date].self, forKey: .unwatched) ?? [:]
        removedPlayback = try container.decodeIfPresent([String: Date].self, forKey: .removedPlayback) ?? [:]
        syncedSaved = try container.decodeIfPresent(Set<String>.self, forKey: .syncedSaved) ?? []
        syncedWatched = try container.decodeIfPresent(Set<String>.self, forKey: .syncedWatched) ?? []
        collected = try container.decodeIfPresent(Set<String>.self, forKey: .collected) ?? []
        activities = try container.decodeIfPresent(TraktLastActivities.self, forKey: .activities)
        lastFullPull = try container.decodeIfPresent(Date.self, forKey: .lastFullPull)
    }
}

public protocol TraktSyncStateStore: Sendable {
    func load() async -> TraktSyncState
    func save(_ state: TraktSyncState) async
}

public actor InMemoryTraktSyncStateStore: TraktSyncStateStore {
    private var state: TraktSyncState

    public init(_ initial: TraktSyncState = TraktSyncState()) { state = initial }

    public func load() async -> TraktSyncState { state }
    public func save(_ state: TraktSyncState) async { self.state = state }
}

/// The sync state in one JSON file, replaced whole on each save so a crash never leaves half of it. A file that cannot be read starts
/// the state empty: nothing is then removed anywhere, and the next sync fills it in again.
public actor FileTraktSyncStateStore: TraktSyncStateStore {
    private let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() async -> TraktSyncState {
        guard let data = try? Data(contentsOf: fileURL), let state = try? JSONDecoder().decode(TraktSyncState.self, from: data) else {
            return TraktSyncState()
        }
        return state
    }

    public func save(_ state: TraktSyncState) async {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
