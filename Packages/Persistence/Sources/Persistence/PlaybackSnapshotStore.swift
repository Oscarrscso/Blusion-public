import Foundation

/// Saves, loads and clears the one previous viewing session. Actors only: one call at a time, and the app or tests wire whichever
/// conforms.
public protocol PlaybackSnapshotStore: Sendable {
    /// Replaces whatever is saved: there is one live viewing session at a time.
    func save(_ snapshot: PlaybackSnapshot) async throws
    /// The saved session, or nil when there is none, the file is unreadable and corrupt beyond use, or the data does not decode.
    func load() async -> PlaybackSnapshot?
    /// Removes the session: an explicit close or a completion sets it aside (never a mere backgrounding, where the live session goes on).
    func clear() async
}

/// The snapshot store in memory: previews and tests.
public actor InMemoryPlaybackSnapshotStore: PlaybackSnapshotStore {
    private var snapshot: PlaybackSnapshot?

    public init(_ snapshot: PlaybackSnapshot? = nil) {
        self.snapshot = snapshot
    }

    public func save(_ snapshot: PlaybackSnapshot) async throws { self.snapshot = snapshot }
    public func load() async -> PlaybackSnapshot? { snapshot }
    public func clear() async { snapshot = nil }
}

#if canImport(Darwin)
/// The snapshot store in the app's own Application Support, one file replaced atomically. It holds only what a listing can find
/// again (identities, positions, choices) and never a link or a header, so no credential ever touches the file.
public actor FilePlaybackSnapshotStore: PlaybackSnapshotStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The store the app uses.
    public static let shared = FilePlaybackSnapshotStore(fileURL: defaultURL())

    /// Next to the SwiftData store (`defaultStoreURL`), under the bundle id's folder on the Mac.
    public static func defaultURL(bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                                  support: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) -> URL {
        var folder = support ?? FileManager.default.temporaryDirectory
        if let bundleIdentifier { folder = folder.appendingPathComponent(bundleIdentifier, isDirectory: true) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("BlusionPlaybackSnapshot.json")
    }

    public func save(_ snapshot: PlaybackSnapshot) async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written in one step at the final name, so a kill mid-write never leaves a half file behind.
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: [.atomic])
    }

    public func load() async -> PlaybackSnapshot? {
        // Read fresh each time: the file is the truth another launch (and this test's hand-editing) may have changed.
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(PlaybackSnapshot.self, from: data) else {
            // A file that cannot be read or decoded is not a session to walk into; it is simply in the way.
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        // Rewrite legacy URL identities into their one-way fingerprints when first opened.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let stream = object["stream"] as? [String: Any], let path = stream["urlPath"] as? String,
           !path.hasPrefix("sha256:") { try? await save(snapshot) }
        return snapshot
    }

    public func clear() async {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
#endif

/// The snapshot store of the app as it is running, and the calls the player and the picker make on it. The file store by default;
/// the launch code and tests set `store` to another one (a preview lens, a test's memory).
public enum PlaybackSession {
    nonisolated(unsafe) public static var store: any PlaybackSnapshotStore = {
        #if canImport(Darwin)
        FilePlaybackSnapshotStore.shared
        #else
        InMemoryPlaybackSnapshotStore()
        #endif
    }()

    /// Saves the whole session, replacing whatever was there.
    public static func save(_ snapshot: PlaybackSnapshot) async {
        try? await store.save(snapshot)
    }

    /// The saved session, used by the picker's restore.
    public static func load() async -> PlaybackSnapshot? {
        await store.load()
    }

    /// Refreshes the saved session with the live player's current state, keeping its stream identity. `identity` guards against a
    /// player for another title writing over the one session: only the session's own player refreshes it.
    public static func refresh(_ saveState: PlaybackSaveState, for identity: String? = nil) async {
        guard var snapshot = await store.load() else { return }
        if let identity, snapshot.request.identity != identity { return }
        snapshot.apply(saveState)
        try? await store.save(snapshot)
    }

    /// Sets the session aside: an explicit close, or a sensible completion. Never a backgrounding, where the session goes on.
    public static func clear() async {
        await store.clear()
    }
}
