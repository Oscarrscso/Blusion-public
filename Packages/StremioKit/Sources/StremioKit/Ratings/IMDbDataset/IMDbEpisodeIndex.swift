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
                // Background, not utility: a daily rebuild of eight million rows must never compete with the screen.
                let job = Task.detached(priority: .background) {
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
            // Rows arrive in episode order but are keyed by series, so inserts land all over the table: a larger page cache (32 MB)
            // keeps them from rereading and rewriting the same pages.
            try IMDbRatingsImporter.exec(db, "PRAGMA cache_size = -32768")
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
            let expectedHeader = Array(header.utf8)
            func line(_ bytes: UnsafeBufferPointer<UInt8>) {
                guard failure == nil else { return }
                // Read straight from the bytes: about eight million lines go through here, so no String is made for any of them.
                var end = bytes.count
                if end > 0, bytes[end - 1] == 0x0D { end -= 1 }
                let fields = UnsafeBufferPointer(rebasing: bytes[..<end])
                if !hasHeader {
                    hasHeader = true
                    if !fields.elementsEqual(expectedHeader) { failure = IMDbImportError.badHeader }
                    return
                }
                guard let row = Row(fields) else { return }
                sqlite3_bind_int64(insert, 1, row.parent)
                sqlite3_bind_int64(insert, 2, row.season)
                sqlite3_bind_int64(insert, 3, row.episode)
                sqlite3_bind_int64(insert, 4, row.id)
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

    /// One data line, `tt0000001<TAB>tt0000002<TAB>1<TAB>3`, read from its bytes. Nil for a line to skip: a missing season or episode
    /// (`\N`) or anything else malformed.
    struct Row {
        let id: Int64
        let parent: Int64
        let season: Int64
        let episode: Int64

        init?(_ line: UnsafeBufferPointer<UInt8>) {
            var fields: (Int64, Int64, Int64, Int64) = (0, 0, 0, 0)
            var start = 0
            for index in 0..<4 {
                var end = start
                while end < line.count, line[end] != 0x09 { end += 1 }
                // Exactly four fields: the last runs to the end of the line, the others stop at a tab.
                guard (index == 3) == (end == line.count) else { return nil }
                let field = UnsafeBufferPointer(rebasing: line[start..<end])
                let value: Int64?
                if index < 2 {
                    guard field.count > 2, field[0] == 0x74, field[1] == 0x74 else { return nil }
                    value = Self.integer(UnsafeBufferPointer(rebasing: field[2...])).flatMap { $0 > 0 ? $0 : nil }
                } else {
                    value = Self.integer(field)
                }
                guard let value else { return nil }
                switch index {
                case 0: fields.0 = value
                case 1: fields.1 = value
                case 2: fields.2 = value
                default: fields.3 = value
                }
                start = end + 1
            }
            id = fields.0
            parent = fields.1
            season = fields.2
            episode = fields.3
        }

        /// One to eighteen ASCII digits.
        private static func integer(_ field: UnsafeBufferPointer<UInt8>) -> Int64? {
            guard !field.isEmpty, field.count <= 18 else { return nil }
            var value: Int64 = 0
            for byte in field {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int64(byte - 0x30)
            }
            return value
        }
    }
}
#endif
