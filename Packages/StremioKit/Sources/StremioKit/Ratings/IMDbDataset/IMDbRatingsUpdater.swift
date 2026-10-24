#if canImport(SQLite3) && canImport(Compression)
import Foundation

public enum IMDbDownload: Sendable, Equatable {
    /// The server answered 304: the copy we hold is current.
    case notModified
    /// The file now at `file`, with the validators the server sent for it.
    case file(URL, etag: String?, lastModified: String?)
}

public enum IMDbDatasetError: Error, Equatable, CustomStringConvertible {
    case http(Int)
    case notHTTP

    public var description: String {
        switch self {
        case .http(let status): "the server answered \(status)"
        case .notHTTP: "not an HTTP response"
        }
    }
}

/// Fetches the dataset. Replaceable so tests need no network.
public protocol IMDbDatasetTransport: Sendable {
    /// Sends `request` and leaves a 200 answer's body in a file inside `directory`.
    func download(_ request: URLRequest, into directory: URL) async throws -> IMDbDownload
}

/// URLSession with no URL cache of its own: the 8 MB file is not kept twice, and our `If-None-Match` is the only validator in play.
public struct URLSessionIMDbTransport: IMDbDatasetTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 900
            self.session = URLSession(configuration: configuration)
        }
    }

    public func download(_ request: URLRequest, into directory: URL) async throws -> IMDbDownload {
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: temporary)
            throw IMDbDatasetError.notHTTP
        }
        switch http.statusCode {
        case 304:
            try? FileManager.default.removeItem(at: temporary)
            return .notModified
        case 200:
            let destination = directory.appendingPathComponent(request.url?.lastPathComponent ?? "dataset.tsv.gz")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return .file(destination, etag: http.value(forHTTPHeaderField: "ETag"), lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        default:
            try? FileManager.default.removeItem(at: temporary)
            throw IMDbDatasetError.http(http.statusCode)
        }
    }
}

/// What is remembered between launches about the local copy and the last checks. Kept beside the database.
public struct IMDbUpdateState: Codable, Sendable, Equatable {
    public var etag: String?
    public var lastModified: String?
    /// The last time the server confirmed the copy as current: a download that was installed, or a 304.
    public var checkedAt: Date?
    /// The last time a copy was installed.
    public var updatedAt: Date?
    /// The last time a request was started, successful or not.
    public var attemptedAt: Date?
    public var failure: String?
    public var rowCount: Int?

    public init() {}
}

/// Keeps the local copy at most a day old: checks the server once every 24 hours, asks only for a changed file, and replaces the
/// database only with one that has been read, counted and checked. If anything fails the old database stays in use.
public actor IMDbRatingsUpdater {
    public static let datasetURL = URL(string: "https://datasets.imdbws.com/title.ratings.tsv.gz") ?? URL(fileURLWithPath: "/")
    public static let refreshInterval: TimeInterval = 24 * 3600
    /// The real file holds well over a million titles. Anything much smaller is a wrong or damaged file.
    public static let minimumTitles = 100_000
    /// After a failure, the next attempt waits this long, so a bad connection is not retried on every launch.
    public static let retryInterval: TimeInterval = 3600

    private let directory: URL
    private let database: IMDbRatingsDatabase
    private let transport: any IMDbDatasetTransport
    private let source: URL
    private let now: @Sendable () -> Date
    private let minimumRows: Int
    private var isRunning = false

    public init(directory: URL, database: IMDbRatingsDatabase, transport: any IMDbDatasetTransport = URLSessionIMDbTransport(),
                source: URL = IMDbRatingsUpdater.datasetURL, now: @escaping @Sendable () -> Date = { Date() },
                minimumRows: Int = IMDbRatingsUpdater.minimumTitles) {
        self.directory = directory
        self.database = database
        self.transport = transport
        self.source = source
        self.now = now
        self.minimumRows = minimumRows
    }

    public func state() -> IMDbUpdateState { loadState() }

    /// Checks whether a refresh is due and does it. Does nothing when the last check was under a day ago, when an attempt failed under
    /// an hour ago, or when a refresh is already running.
    public func updateIfNeeded() async -> IMDbDatasetRefresh {
        guard !isRunning else { return .skipped }
        let hasDatabase = database.exists
        var state = loadState()
        let current = now()
        if let failedAt = state.failure == nil ? nil : state.attemptedAt, isRecent(failedAt, within: Self.retryInterval, of: current) {
            return .skipped
        }
        if hasDatabase, let checked = state.checkedAt, isRecent(checked, within: Self.refreshInterval, of: current) { return .skipped }

        isRunning = true
        defer { isRunning = false }
        state.attemptedAt = current
        state.failure = nil
        saveState(state)
        do {
            let outcome = try await refresh(&state, hasDatabase: hasDatabase)
            saveState(state)
            return outcome
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                // Not a failure of the dataset: try again at the next opportunity.
                state.attemptedAt = nil
                saveState(state)
                return .skipped
            }
            state.failure = String(describing: error)
            saveState(state)
            return .failed(String(describing: error))
        }
    }

    private func refresh(_ state: inout IMDbUpdateState, hasDatabase: Bool) async throws -> IMDbDatasetRefresh {
        let work = directory.appendingPathComponent("work", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var request = URLRequest(url: source)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if hasDatabase {
            if let etag = state.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = state.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        }
        // Low Data Mode holds back a refresh, but not the first download: without it there are no scores at all.
        request.allowsConstrainedNetworkAccess = !hasDatabase

        switch try await transport.download(request, into: work) {
        case .notModified:
            guard hasDatabase else { throw IMDbDatasetError.http(304) }
            state.checkedAt = now()
            return .notModified
        case .file(let file, let etag, let lastModified):
            let built = work.appendingPathComponent("building.sqlite")
            let previousRows = hasDatabase ? state.rowCount : nil
            let minimumRows = minimumRows
            var metadata: [String: String] = [:]
            metadata["source"] = source.absoluteString
            metadata["etag"] = etag
            metadata["last_modified"] = lastModified
            let job = Task.detached(priority: .utility) { () throws -> IMDbRatingsImporter.Summary in
                let summary = try IMDbRatingsImporter.build(from: file, to: built, minimumRows: minimumRows, metadata: metadata)
                // A copy a fifth smaller than the one in use is more likely a damaged file than a real change.
                if let previousRows, summary.rows * 5 < previousRows * 4 {
                    throw IMDbImportError.smallerThanBefore(new: summary.rows, old: previousRows)
                }
                return summary
            }
            let summary = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            try Task.checkCancellation()
            try await database.install(built)
            let installedAt = now()
            state.etag = etag
            state.lastModified = lastModified
            state.checkedAt = installedAt
            state.updatedAt = installedAt
            state.rowCount = summary.rows
            return .updated(titles: summary.rows)
        }
    }

    /// True when `date` is inside the last `interval`. A date in the future (the clock was set back) counts as old.
    private func isRecent(_ date: Date, within interval: TimeInterval, of current: Date) -> Bool {
        let age = current.timeIntervalSince(date)
        return age >= 0 && age < interval
    }

    private var stateURL: URL { directory.appendingPathComponent("state.json") }

    private func loadState() -> IMDbUpdateState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder.imdbState.decode(IMDbUpdateState.self, from: data) else { return IMDbUpdateState() }
        return state
    }

    private func saveState(_ state: IMDbUpdateState) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.imdbState.encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }
}

private extension JSONEncoder {
    static var imdbState: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

private extension JSONDecoder {
    static var imdbState: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

/// The dataset as the app uses it: lookups from the local database, and the daily refresh.
public struct IMDbRatingsService: IMDbDataset {
    public let database: IMDbRatingsDatabase
    public let updater: IMDbRatingsUpdater
    public let episodeIndex: IMDbEpisodeIndex?
    private let fileURL: URL

    public init(directory: URL, transport: any IMDbDatasetTransport = URLSessionIMDbTransport(),
                source: URL = IMDbRatingsUpdater.datasetURL, now: @escaping @Sendable () -> Date = { Date() },
                minimumRows: Int = IMDbRatingsUpdater.minimumTitles,
                episodeSource: URL? = IMDbEpisodeIndex.datasetURL, minimumEpisodeRows: Int = 500_000) {
        let fileURL = directory.appendingPathComponent("title.ratings.sqlite")
        let database = IMDbRatingsDatabase(fileURL: fileURL)
        self.fileURL = fileURL
        self.database = database
        self.updater = IMDbRatingsUpdater(directory: directory, database: database, transport: transport, source: source, now: now,
                                          minimumRows: minimumRows)
        self.episodeIndex = episodeSource.map {
            IMDbEpisodeIndex(directory: directory, transport: transport, source: $0, now: now, minimumRows: minimumEpisodeRows)
        }
        Self.excludeFromBackup(directory)
    }

    /// The app's own folder for the dataset: Application Support under the app's identifier (a Mac build without a sandbox shares that
    /// folder with other apps), kept out of device backups and iCloud.
    public static func standardDirectory(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(bundleIdentifier ?? "Blusion", isDirectory: true)
            .appendingPathComponent("IMDbRatings", isDirectory: true)
    }

    public func rating(for imdbID: String) async -> IMDbRating? { await database.rating(for: imdbID) }

    public func episodeIDs(for seriesID: String, season: Int) async -> [Int: String] {
        await episodeIndex?.episodeIDs(for: seriesID, season: season) ?? [:]
    }

    public func status() async -> IMDbDatasetStatus? {
        guard let count = await database.titleCount() else { return nil }
        let state = await updater.state()
        return IMDbDatasetStatus(titleCount: count, updatedAt: state.updatedAt, checkedAt: state.checkedAt,
                                 fileSize: (Self.size(ofDatabaseAt: fileURL) ?? 0)
                                    + (episodeIndex.flatMap { Self.size(ofDatabaseAt: $0.fileURL) } ?? 0))
    }

    /// The database file plus its write-ahead log and shared-memory siblings, when present. Nil if the database file can't be read.
    static func size(ofDatabaseAt url: URL) -> Int64? {
        let manager = FileManager.default
        func bytes(_ path: String) -> Int64? { (try? manager.attributesOfItem(atPath: path))?[.size] as? Int64 }
        guard let main = bytes(url.path) else { return nil }
        return main + (bytes(url.path + "-wal") ?? 0) + (bytes(url.path + "-shm") ?? 0)
    }

    public func refreshIfNeeded() async -> IMDbDatasetRefresh {
        let ratings = await updater.updateIfNeeded()
        let episodesChanged = await episodeIndex?.refreshIfNeeded() ?? false
        if episodesChanged {
            if case .updated = ratings { return ratings }
            return .episodeIndexUpdated
        }
        return ratings
    }

    /// The data is a download that can always be fetched again, and IMDb's terms do not let us pass it on.
    private static func excludeFromBackup(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
#endif
