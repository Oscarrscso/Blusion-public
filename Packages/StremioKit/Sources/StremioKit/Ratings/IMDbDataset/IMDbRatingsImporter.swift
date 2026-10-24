#if canImport(SQLite3) && canImport(Compression)
import Foundation
import SQLite3

public enum IMDbImportError: Error, Equatable, CustomStringConvertible {
    case badHeader
    case tooFewRows(Int)
    case tooManyBadRows(bad: Int, good: Int)
    case smallerThanBefore(new: Int, old: Int)
    case verificationFailed(String)
    case database(String)

    public var description: String {
        switch self {
        case .badHeader: "the file is not IMDb's ratings table"
        case .tooFewRows(let count): "only \(count) rows"
        case .tooManyBadRows(let bad, let good): "\(bad) unreadable rows next to \(good) good ones"
        case .smallerThanBefore(let new, let old): "\(new) rows where the current copy has \(old)"
        case .verificationFailed(let why): "the new database failed its check: \(why)"
        case .database(let message): "database error: \(message)"
        }
    }
}

/// Turns `title.ratings.tsv.gz` into an indexed SQLite file: one row per title with its IMDb ID, rating and vote count.
///
/// The file is built beside the real one and checked before it is returned; it is the caller's job to move it into place.
/// Nothing here touches the database in use, so a failure at any point leaves it alone.
enum IMDbRatingsImporter {
    static let expectedHeader = Array("tconst\taverageRating\tnumVotes".utf8)
    static let schemaVersion = 1
    struct Summary: Equatable {
        var rows: Int
        var skippedRows: Int
    }

    /// Reads `source` (gzip) and writes the database at `destination`, replacing anything already there.
    /// - Parameters:
    ///   - minimumRows: fewer rows than this is an error.
    ///   - metadata: stored in the `meta` table, e.g. the ETag the file came with.
    static func build(from source: URL, to destination: URL, minimumRows: Int = IMDbRatingsUpdater.minimumTitles,
                      metadata: [String: String] = [:]) throws -> Summary {
        try? FileManager.default.removeItem(at: destination)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let handle { sqlite3_close(handle) }
            throw IMDbImportError.database(message)
        }
        var closed = false
        func close() { if !closed { closed = true; sqlite3_close(db) } }
        do {
            let summary = try fill(db, from: source, minimumRows: minimumRows, metadata: metadata)
            close()
            try syncToDisk(destination)
            return summary
        } catch {
            close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func fill(_ db: OpaquePointer, from source: URL, minimumRows: Int, metadata: [String: String]) throws -> Summary {
        // Disposable until it is verified and renamed, so speed beats crash safety while it is written.
        try exec(db, "PRAGMA journal_mode = OFF")
        try exec(db, "PRAGMA synchronous = OFF")
        try exec(db, "PRAGMA locking_mode = EXCLUSIVE")
        try exec(db, "CREATE TABLE ratings (tconst TEXT NOT NULL PRIMARY KEY, rating REAL NOT NULL, votes INTEGER NOT NULL) WITHOUT ROWID")
        try exec(db, "CREATE TABLE meta (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID")
        try exec(db, "BEGIN")
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO ratings (tconst, rating, votes) VALUES (?1, ?2, ?3)", -1, &insert, nil) == SQLITE_OK,
              let statement = insert else { throw IMDbImportError.database(message(db)) }
        defer { sqlite3_finalize(statement) }

        var lines = LineSplitter()
        var sawHeader = false
        var rows = 0
        var skipped = 0
        var failure: Error?
        func handle(line: UnsafeBufferPointer<UInt8>) {
            guard failure == nil else { return }
            if !sawHeader {
                sawHeader = true
                let trimmed = line.last == 0x0D ? UnsafeBufferPointer(rebasing: line.dropLast()) : line
                if !trimmed.elementsEqual(expectedHeader) { failure = IMDbImportError.badHeader }
                return
            }
            guard !line.isEmpty else { return }
            guard let row = Row(line) else { skipped += 1; return }
            sqlite3_bind_text(statement, 1, row.id.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                              Int32(row.id.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(statement, 2, row.rating)
            sqlite3_bind_int64(statement, 3, row.votes)
            switch sqlite3_step(statement) {
            case SQLITE_DONE: rows += 1
            case SQLITE_CONSTRAINT: skipped += 1   // a repeated ID: keep the first
            default: failure = IMDbImportError.database(message(db))
            }
            sqlite3_reset(statement)
        }

        try GzipFile.inflate(fileAt: source) { piece in
            lines.feed(piece, handle)
            if let failure { throw failure }
        }
        lines.finish(handle)
        if let failure { throw failure }
        if !sawHeader { throw IMDbImportError.badHeader }

        guard rows >= minimumRows else { throw IMDbImportError.tooFewRows(rows) }
        // A few odd lines are tolerated; a file where more than one in a thousand is bad is not the file we think it is.
        guard skipped <= max(5, rows / 1_000) else { throw IMDbImportError.tooManyBadRows(bad: skipped, good: rows) }

        var meta = metadata
        meta["schema_version"] = String(schemaVersion)
        meta["row_count"] = String(rows)
        meta["built_at"] = String(Int(Date().timeIntervalSince1970))
        try writeMeta(db, meta)
        try exec(db, "COMMIT")
        try verify(db, expectedRows: rows)
        return Summary(rows: rows, skippedRows: skipped)
    }

    /// Reads the finished file back: the structure is sound, the count matches what was written, and lookups work.
    private static func verify(_ db: OpaquePointer, expectedRows: Int) throws {
        guard try scalarText(db, "PRAGMA quick_check") == "ok" else { throw IMDbImportError.verificationFailed("quick_check") }
        guard try scalarInt(db, "SELECT count(*) FROM ratings") == expectedRows else {
            throw IMDbImportError.verificationFailed("row count")
        }
        guard try scalarInt(db, "SELECT count(*) FROM ratings WHERE rating < 0 OR rating > 10 OR votes < 0") == 0 else {
            throw IMDbImportError.verificationFailed("values out of range")
        }
        guard try scalarInt(db, "SELECT count(*) FROM (SELECT tconst FROM ratings ORDER BY tconst LIMIT 1)") == 1 else {
            throw IMDbImportError.verificationFailed("index")
        }
    }

    private static func writeMeta(_ db: OpaquePointer, _ values: [String: String]) throws {
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO meta (key, value) VALUES (?1, ?2)", -1, &insert, nil) == SQLITE_OK, let statement = insert else {
            throw IMDbImportError.database(message(db))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (key, value) in values {
            sqlite3_bind_text(statement, 1, key, -1, transient)
            sqlite3_bind_text(statement, 2, value, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw IMDbImportError.database(message(db)) }
            sqlite3_reset(statement)
        }
    }

    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw IMDbImportError.database(message(db)) }
    }

    static func message(_ db: OpaquePointer) -> String { String(cString: sqlite3_errmsg(db)) }

    private static func scalarText(_ db: OpaquePointer, _ sql: String) throws -> String {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let statement = handle else { throw IMDbImportError.database(message(db)) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw IMDbImportError.database(message(db)) }
        return String(cString: text)
    }

    private static func scalarInt(_ db: OpaquePointer, _ sql: String) throws -> Int {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let statement = handle else { throw IMDbImportError.database(message(db)) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw IMDbImportError.database(message(db)) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Flushes the finished file to disk before it is renamed over the old one.
    private static func syncToDisk(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    /// One data line: `tt0111161<TAB>9.3<TAB>3156085`.
    struct Row {
        let id: UnsafeBufferPointer<UInt8>
        let rating: Double
        let votes: Int64

        init?(_ line: UnsafeBufferPointer<UInt8>) {
            var end = line.count
            if end > 0, line[end - 1] == 0x0D { end -= 1 }
            guard let first = line[..<end].firstIndex(of: 0x09),
                  let second = line[(first + 1)..<end].firstIndex(of: 0x09) else { return nil }
            let id = UnsafeBufferPointer(rebasing: line[..<first])
            // "tt" and one to twelve digits.
            guard (3...14).contains(id.count), id[0] == 0x74, id[1] == 0x74, id.dropFirst(2).allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
            guard let rating = Self.decimal(UnsafeBufferPointer(rebasing: line[(first + 1)..<second])), (0...10).contains(rating),
                  let votes = Self.integer(UnsafeBufferPointer(rebasing: line[(second + 1)..<end])) else { return nil }
            self.id = id
            self.rating = rating
            self.votes = votes
        }

        /// "8", "8.7" or "10.0": digits with at most one point and a digit on each side of it. Built as mantissa over a power of ten,
        /// so 8.7 is stored as the double nearest 8.7.
        private static func decimal(_ field: UnsafeBufferPointer<UInt8>) -> Double? {
            guard !field.isEmpty, field.count <= 6 else { return nil }
            var mantissa = 0
            var pointAt: Int?
            for (index, byte) in field.enumerated() {
                if byte == 0x2E {
                    guard pointAt == nil, index > 0, index < field.count - 1 else { return nil }
                    pointAt = index
                } else if (0x30...0x39).contains(byte) {
                    mantissa = mantissa * 10 + Int(byte - 0x30)
                } else {
                    return nil
                }
            }
            let fractionDigits = pointAt.map { field.count - $0 - 1 } ?? 0
            return Double(mantissa) / (0..<fractionDigits).reduce(1.0) { value, _ in value * 10 }
        }

        private static func integer(_ field: UnsafeBufferPointer<UInt8>) -> Int64? {
            guard !field.isEmpty, field.count <= 12 else { return nil }
            var value: Int64 = 0
            for byte in field {
                guard (0x30...0x39).contains(byte) else { return nil }
                value = value * 10 + Int64(byte - 0x30)
            }
            return value
        }
    }

    /// Cuts a stream of bytes into lines without copying them, carrying a partial last line into the next piece.
    struct LineSplitter {
        private var carry: [UInt8] = []

        mutating func feed(_ piece: UnsafeBufferPointer<UInt8>, _ handle: (UnsafeBufferPointer<UInt8>) -> Void) {
            var start = 0
            let count = piece.count
            while start < count {
                guard let newline = piece[start...].firstIndex(of: 0x0A) else { break }
                if carry.isEmpty {
                    handle(UnsafeBufferPointer(rebasing: piece[start..<newline]))
                } else {
                    carry.append(contentsOf: piece[start..<newline])
                    carry.withUnsafeBufferPointer { handle($0) }
                    carry.removeAll(keepingCapacity: true)
                }
                start = newline + 1
            }
            if start < count { carry.append(contentsOf: piece[start...]) }
        }

        mutating func finish(_ handle: (UnsafeBufferPointer<UInt8>) -> Void) {
            guard !carry.isEmpty else { return }
            carry.withUnsafeBufferPointer { handle($0) }
            carry.removeAll()
        }
    }
}
#endif
