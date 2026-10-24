#if canImport(SQLite3) && canImport(Compression)
import Foundation
import SQLite3

/// The local copy of IMDb's ratings, opened read-only. A lookup is one indexed read and never waits for the network.
///
/// The file is never changed in place: a newer copy is built beside it and renamed over it (`install`), so a reader sees the old file
/// or the new one, never a half-written one. Lookups go through one actor, which also closes its connection around the rename.
public actor IMDbRatingsDatabase {
    public nonisolated let fileURL: URL
    private var session: Session?
    /// Counts installs, so a caller can tell that answers it kept may be out of date.
    public private(set) var generation = 0

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public nonisolated var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// The rating and vote count of a title, or nil when the dataset has no such title (or there is no dataset yet).
    public func rating(for imdbID: String) -> IMDbRating? {
        guard LetterboxdRatings.isIMDbID(imdbID), let statement = lookupStatement() else { return nil }
        defer { sqlite3_reset(statement) }
        sqlite3_bind_text(statement, 1, imdbID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return IMDbRating(imdbID: imdbID, rating: sqlite3_column_double(statement, 0), votes: Int(sqlite3_column_int64(statement, 1)))
        case SQLITE_DONE:
            return nil
        case let code:
            discardIfDamaged(code)
            return nil
        }
    }

    /// Value stored beside the ratings when the file was built, e.g. `row_count`.
    public func metadata(_ key: String) -> String? {
        guard let db = open()?.db else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?1", -1, &handle, nil) == SQLITE_OK, let statement = handle else {
            discardIfDamaged(sqlite3_errcode(db))
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    public func titleCount() -> Int? { metadata("row_count").flatMap { Int($0) } }

    /// Moves a finished database over the one in use. The rename is atomic: on any failure the old file is untouched.
    func install(_ built: URL) throws {
        closeConnection()
        guard rename(built.path, fileURL.path) == 0 else {
            throw IMDbImportError.database("rename failed: \(String(cString: strerror(errno)))")
        }
        generation += 1
    }

    /// Deletes the local copy.
    public func remove() {
        closeConnection()
        try? FileManager.default.removeItem(at: fileURL)
        generation += 1
    }

    // MARK: Connection

    /// An open connection and its prepared lookup. Closed when released, so the actor needs no deinit of its own.
    private final class Session: @unchecked Sendable {
        let db: OpaquePointer
        var lookup: OpaquePointer?

        init(db: OpaquePointer) { self.db = db }

        deinit {
            if let lookup { sqlite3_finalize(lookup) }
            sqlite3_close(db)
        }
    }

    private func lookupStatement() -> OpaquePointer? {
        guard let session = open() else { return nil }
        if let lookup = session.lookup { return lookup }
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(session.db, "SELECT rating, votes FROM ratings WHERE tconst = ?1", -1, &handle, nil) == SQLITE_OK else {
            discardIfDamaged(sqlite3_errcode(session.db))
            return nil
        }
        session.lookup = handle
        return handle
    }

    private func open() -> Session? {
        if let session { return session }
        guard exists else { return nil }
        // `immutable` is true of this file: it is replaced by rename and never written, so SQLite can skip locking and journals.
        let uri = fileURL.absoluteString + "?immutable=1"
        var handle: OpaquePointer?
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db = handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        let opened = Session(db: db)
        session = opened
        return opened
    }

    private func closeConnection() { session = nil }

    /// A file that is not a database any more is removed, so the next refresh downloads a fresh one. Other errors leave it alone.
    private func discardIfDamaged(_ code: Int32) {
        let primary = code & 0xFF
        guard primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB else { return }
        remove()
    }
}
#endif
