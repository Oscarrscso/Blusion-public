#if canImport(SQLite3) && canImport(Compression)
import Foundation
import SQLite3

/// Local series/season/episode -> IMDb episode ID index, installed separately from the ratings DB.
public actor IMDbEpisodeIndex {
    public static let datasetURL = URL(string: "https://datasets.imdbws.com/title.episode.tsv.gz")!
    public nonisolated let fileURL: URL
    private let directory: URL
    private let transport: any IMDbDatasetTransport
    private let source: URL
    private let now: @Sendable () -> Date
    private let minimumRows: Int
    private var isRunning = false
    private var session: Session?

    public init(directory: URL, transport: any IMDbDatasetTransport = URLSessionIMDbTransport(),
                source: URL = IMDbEpisodeIndex.datasetURL, now: @escaping @Sendable () -> Date = { Date() },
                minimumRows: Int = 500_000) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("title.episode.sqlite")
        self.transport = transport
        self.source = source
        self.now = now
        self.minimumRows = minimumRows
    }

    private final class Session {
        let db: OpaquePointer
        var query: OpaquePointer?
        init(_ db: OpaquePointer) { self.db = db }
        deinit {
            if let query { sqlite3_finalize(query) }
            sqlite3_close(db)
        }
    }

    private func statement() -> OpaquePointer? {
        if session == nil {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            var handle: OpaquePointer?
            guard sqlite3_open_v2(fileURL.absoluteString + "?immutable=1", &handle,
                                  SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nil) == SQLITE_OK,
                  let db = handle else {
                if let handle { sqlite3_close(handle) }
                return nil
            }
            session = Session(db)
        }
        guard let session else { return nil }
        if let query = session.query { return query }
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(session.db,
                                 "SELECT episode, episode_id FROM episodes WHERE parent_id = ?1 AND season = ?2",
                                 -1, &handle, nil) == SQLITE_OK, let query = handle else { return nil }
        session.query = query
        return query
    }

    /// One indexed range query per season; all results are available without any network request.
    public func episodeIDs(for seriesID: String, season: Int) -> [Int: String] {
        guard season >= 0, let parent = Self.idNumber(seriesID), let query = statement() else { return [:] }
        sqlite3_bind_int64(query, 1, parent)
        sqlite3_bind_int64(query, 2, Int64(season))
        defer { sqlite3_reset(query); sqlite3_clear_bindings(query) }
        var ids: [Int: String] = [:]
        while sqlite3_step(query) == SQLITE_ROW {
            let number = Int(sqlite3_column_int64(query, 0))
            ids[number] = String(format: "tt%07lld", sqlite3_column_int64(query, 1))
        }
        return ids
    }

    static func idNumber(_ id: String) -> Int64? {
        guard id.hasPrefix("tt"), id.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int64(id.dropFirst(2)), value > 0 else { return nil }
        return value
    }

    /// Daily conditional update. A failed import cannot replace the previous complete index.
    public func refreshIfNeeded() async -> Bool {
        guard !isRunning else { return false }
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        var state = loadState()
        let current = now()
        if let failed = state.failure == nil ? nil : state.attemptedAt, Self.recent(failed, current) { return false }
        if exists, let checked = state.checkedAt, Self.recent(checked, current, interval: 86_400) { return false }
        isRunning = true
        defer { isRunning = false }
        state.attemptedAt = current
        state.failure = nil
        saveState(state)
        let work = directory.appendingPathComponent("work-episodes", isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            var request = URLRequest(url: source)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            // Large dataset: do not download on cellular or Low Data Mode.
            request.allowsExpensiveNetworkAccess = false
            request.allowsConstrainedNetworkAccess = false
            if exists {
                if let etag = state.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                if let modified = state.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
            }
            switch try await transport.download(request, into: work) {
            case .notModified:
                guard exists else { throw IMDbDatasetError.http(304) }
                state.checkedAt = now()
                saveState(state)
                return false
            case .file(let download, let etag, let modified):
                let built = work.appendingPathComponent("episodes-building.sqlite")
                let previous = exists ? state.rowCount : nil
                let minRows = minimumRows
                let job = Task.detached(priority: .utility) {
                    let rows = try IMDbEpisodeImporter.build(from: download, to: built, minimumRows: minRows)
                    if let previous, rows * 5 < previous * 4 {
                        throw IMDbImportError.smallerThanBefore(new: rows, old: previous)
                    }
                    return rows
                }
                let rows = try await withTaskCancellationHandler {
                    try await job.value
                } onCancel: { job.cancel() }
                try Task.checkCancellation()
                session = nil
                guard rename(built.path, fileURL.path) == 0 else {
                    throw IMDbImportError.database("episode index rename failed: \(String(cString: strerror(errno)))")
                }
                state.rowCount = rows
                state.etag = etag
                state.lastModified = modified
                state.checkedAt = now()
                state.updatedAt = state.checkedAt
                saveState(state)
                return true
            }
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                state.attemptedAt = nil
            } else {
                state.failure = String(describing: error)
            }
            saveState(state)
            return false
        }
    }

    private var stateURL: URL { directory.appendingPathComponent("episodes-state.json") }
    private func loadState() -> IMDbUpdateState {
        guard let bytes = try? Data(contentsOf: stateURL) else { return IMDbUpdateState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(IMDbUpdateState.self, from: bytes)) ?? IMDbUpdateState()
    }
    private func saveState(_ state: IMDbUpdateState) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let bytes = try? encoder.encode(state) { try? bytes.write(to: stateURL, options: .atomic) }
    }
    private static func recent(_ date: Date, _ current: Date, interval: TimeInterval = 3_600) -> Bool {
        let age = current.timeIntervalSince(date)
        return age >= 0 && age < interval
    }
}

/// Streaming TSV -> SQLite importer. Store IDs as integers to save disk space, then reconstruct tt IDs on lookup.
enum IMDbEpisodeImporter {
    static let header = "tconst\tparentTconst\tseasonNumber\tepisodeNumber"

    static func build(from source: URL, to destination: URL, minimumRows: Int) throws -> Int {
        try? FileManager.default.removeItem(at: destination)
        var raw: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db = raw else {
            if let raw { sqlite3_close(raw) }
            throw IMDbImportError.database("cannot create episode index")
        }
        var closed = false
        func close() { if !closed { closed = true; sqlite3_close_v2(db) } }
        do {
            try IMDbRatingsImporter.exec(db, "PRAGMA journal_mode = OFF")
            try IMDbRatingsImporter.exec(db, "PRAGMA synchronous = OFF")
            try IMDbRatingsImporter.exec(db, "CREATE TABLE episodes (parent_id INTEGER NOT NULL, season INTEGER NOT NULL, "
                                         + "episode INTEGER NOT NULL, episode_id INTEGER NOT NULL, PRIMARY KEY(parent_id, season, episode)) WITHOUT ROWID")
            try IMDbRatingsImporter.exec(db, "BEGIN")
            var rawInsert: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO episodes VALUES (?1, ?2, ?3, ?4)", -1, &rawInsert, nil) == SQLITE_OK,
                  let insert = rawInsert else { throw IMDbImportError.database("cannot prepare episode import") }
            var insertFinalized = false
            defer { if !insertFinalized { sqlite3_finalize(insert) } }
            var count = 0
            var hasHeader = false
            var failure: Error?
            var lines = IMDbRatingsImporter.LineSplitter()
            func line(_ bytes: UnsafeBufferPointer<UInt8>) {
                guard failure == nil else { return }
                let fields = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
                if !hasHeader {
                    hasHeader = true
                    if fields != header { failure = IMDbImportError.badHeader }
                    return
                }
                let parts = fields.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count == 4,
                      let id = IMDbEpisodeIndex.idNumber(String(parts[0])),
                      let parent = IMDbEpisodeIndex.idNumber(String(parts[1])),
                      let season = Int64(parts[2]), let episode = Int64(parts[3]),
                      season >= 0, episode >= 0 else { return }
                sqlite3_bind_int64(insert, 1, parent)
                sqlite3_bind_int64(insert, 2, season)
                sqlite3_bind_int64(insert, 3, episode)
                sqlite3_bind_int64(insert, 4, id)
                let status = sqlite3_step(insert)
                if status == SQLITE_DONE {
                    if sqlite3_changes(db) > 0 { count += 1 }
                } else { failure = IMDbImportError.database("episode insert failed") }
                sqlite3_reset(insert)
            }
            try GzipFile.inflate(fileAt: source) { bytes in
                lines.feed(bytes, line)
                if let failure { throw failure }
            }
            lines.finish(line)
            if let failure { throw failure }
            guard hasHeader else { throw IMDbImportError.badHeader }
            guard count >= minimumRows else { throw IMDbImportError.tooFewRows(count) }
            let finalization = sqlite3_finalize(insert)
            insertFinalized = true
            guard finalization == SQLITE_OK else { throw IMDbImportError.database("episode insert finalization failed") }
            try IMDbRatingsImporter.exec(db, "COMMIT")
            // The full, checksummed gzip has been read and the index has a valid SQLite structure.
            var check: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &check, nil) == SQLITE_OK, let query = check else {
                throw IMDbImportError.verificationFailed("episode index check unavailable")
            }
            let okay = sqlite3_step(query) == SQLITE_ROW && sqlite3_column_text(query, 0).map { String(cString: $0) } == "ok"
            sqlite3_finalize(query)
            guard okay else { throw IMDbImportError.verificationFailed("episode index quick_check") }
            close()
            let writer = try FileHandle(forUpdating: destination)
            defer { try? writer.close() }
            try writer.synchronize()
            return count
        } catch {
            close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
#endif
