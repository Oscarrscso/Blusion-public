import Foundation

/// A Letterboxd answer as it is kept between launches. A nil `rating` is a lookup that found nothing, and it is kept too.
public struct CachedRating: Sendable, Codable, Equatable {
    public var rating: Double?
    public var fetchedAt: Date
    /// Optional extra scores allow the same bounded file cache to hold other providers; old files still decode.
    public var reviews: ReviewRatings?
    /// One season's episode scores by episode number, for the OMDb season lookups. Absent in files written before they existed.
    public var episodes: [Int: Double]?
    /// Episode number to IMDb title ID, including episodes OMDb returned with `N/A` scores.
    public var episodeIDs: [Int: String]?
    /// All episode numbers in the season response, so a partially filled season expires sooner.
    public var episodeNumbers: Set<Int>?

    public init(rating: Double?, fetchedAt: Date, reviews: ReviewRatings? = nil, episodes: [Int: Double]? = nil,
                episodeIDs: [Int: String]? = nil, episodeNumbers: Set<Int>? = nil) {
        self.rating = rating
        self.fetchedAt = fetchedAt
        self.reviews = reviews
        self.episodes = episodes
        self.episodeIDs = episodeIDs
        self.episodeNumbers = episodeNumbers
    }
}

/// Remembers answers by IMDb id, so a film is not asked for again while its answer is fresh.
public protocol RatingsCache: Sendable {
    func value(for key: String) async -> CachedRating?
    func store(_ value: CachedRating, for key: String) async
    func clear() async
}

/// Kept in memory only: nothing survives a launch.
public actor InMemoryRatingsCache: RatingsCache {
    private var entries: [String: CachedRating] = [:]

    public init() {}

    public func value(for key: String) -> CachedRating? { entries[key] }

    public func store(_ value: CachedRating, for key: String) { entries[key] = value }

    public func clear() { entries.removeAll() }
}

/// One JSON file holding every answer, loaded on first use. Writes are coalesced: at most one per `flushInterval`, however many
/// answers arrive, and the last ones are written when the interval ends. Holds at most `maxEntries`; the oldest by `fetchedAt`
/// go first. A file that cannot be read starts the cache empty, and the next write replaces it.
public actor FileRatingsCache: RatingsCache {
    private let fileURL: URL
    private let maxEntries: Int
    private let flushInterval: Duration
    private var entries: [String: CachedRating] = [:]
    private var isLoaded = false
    private var isDirty = false
    private var lastWrite: ContinuousClock.Instant?
    private var pendingWrite: Task<Void, Never>?
    /// Writes attempted so far. The tests use it to check that stores are coalesced.
    private(set) var writeCount = 0

    public init(fileURL: URL) {
        self.init(fileURL: fileURL, maxEntries: 5_000, flushInterval: .seconds(2))
    }

    init(fileURL: URL, maxEntries: Int, flushInterval: Duration) {
        self.fileURL = fileURL
        self.maxEntries = max(1, maxEntries)
        self.flushInterval = flushInterval
    }

    public func value(for key: String) -> CachedRating? {
        loadIfNeeded()
        return entries[key]
    }

    public func store(_ value: CachedRating, for key: String) {
        loadIfNeeded()
        entries[key] = value
        trimToCapacity()
        isDirty = true
        scheduleWrite()
    }

    /// Removes the file at once: "Clear data" must not leave ratings behind.
    public func clear() {
        isLoaded = true
        entries.removeAll()
        isDirty = false
        pendingWrite?.cancel()
        pendingWrite = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([String: CachedRating].self, from: data) else { return }
        entries = stored
        trimToCapacity()
    }

    private func trimToCapacity() {
        let excess = entries.count - maxEntries
        guard excess > 0 else { return }
        for (key, _) in entries.sorted(by: { $0.value.fetchedAt < $1.value.fetchedAt }).prefix(excess) {
            entries[key] = nil
        }
    }

    /// The first store writes at once; later ones wait until `flushInterval` after the last write.
    private func scheduleWrite() {
        guard pendingWrite == nil else { return }
        var wait = Duration.zero
        if let lastWrite {
            wait = max(Duration.zero, lastWrite.advanced(by: flushInterval) - ContinuousClock.now)
        }
        pendingWrite = Task {
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self.writeIfDirty()
        }
    }

    private func writeIfDirty() {
        pendingWrite = nil
        guard isDirty else { return }
        lastWrite = ContinuousClock.now
        writeCount += 1
        if save() { isDirty = false }
    }

    private func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
