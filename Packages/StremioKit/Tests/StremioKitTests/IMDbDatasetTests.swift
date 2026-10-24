#if canImport(SQLite3) && canImport(Compression)
import Compression
import Foundation
import Testing
@testable import StremioKit

/// Test files: a real gzip writer, a scratch folder, and a transport that answers from a script.
enum IMDbFixtures {
    static func scratchDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/imdb-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A gzip member made the way `gzip` makes one: header, raw deflate, CRC-32 and length.
    static func gzip(_ plain: Data, name: String? = nil) throws -> Data {
        let deflated = try (plain as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1F, 0x8B, 8, name == nil ? 0 : 8, 0, 0, 0, 0, 0, 3])
        if let name { out.append(Data(name.utf8)); out.append(0) }
        out.append(deflated)
        var crc = CRC32()
        plain.withUnsafeBytes { crc.update($0.bindMemory(to: UInt8.self)) }
        for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8((crc.value >> UInt32(shift)) & 0xFF)) }
        let size = UInt32(truncatingIfNeeded: plain.count)
        for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8((size >> UInt32(shift)) & 0xFF)) }
        return out
    }

    /// `rows` titles: tt0000001, tt0000002, ... with ratings 1.0...9.9 and growing vote counts.
    static func table(rows: Int, header: String = "tconst\taverageRating\tnumVotes", ending: String = "\n",
                      extra: [String] = []) -> Data {
        var lines = [header]
        for index in 1...max(rows, 1) where index <= rows {
            let rating = 1 + Double((index * 7) % 90) / 10
            lines.append(String(format: "tt%07d\t%.1f\t%d", index, rating, index * 3))
        }
        lines += extra
        return Data((lines.joined(separator: "\n") + ending).utf8)
    }

    static func write(_ data: Data, to directory: URL, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

@Suite struct GzipFileTests {
    private func inflate(_ data: Data, bufferSize: Int = 1 << 18) throws -> Data {
        let directory = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try IMDbFixtures.write(data, to: directory, named: "x.gz")
        var out = Data()
        try GzipFile.inflate(fileAt: file, bufferSize: bufferSize) { out.append($0) }
        return out
    }

    @Test func inflatesWhatGzipMade() throws {
        let plain = IMDbFixtures.table(rows: 500)
        #expect(try inflate(IMDbFixtures.gzip(plain)) == plain)
    }

    @Test func smallBuffersGiveTheSameBytes() throws {
        let plain = IMDbFixtures.table(rows: 5_000)
        let gz = try IMDbFixtures.gzip(plain)
        #expect(try inflate(gz, bufferSize: 64) == plain)
        #expect(try inflate(gz, bufferSize: 1_000) == plain)
    }

    @Test func aHeaderWithAFileNameIsSkipped() throws {
        let plain = Data("hello hello hello hello".utf8)
        #expect(try inflate(IMDbFixtures.gzip(plain, name: "title.ratings.tsv")) == plain)
    }

    @Test func plainTextIsNotGzip() {
        #expect(throws: GzipError.notGzip) { try inflate(Data("<html>captive portal</html>".utf8)) }
    }

    @Test func aTruncatedDownloadIsRefused() throws {
        let gz = try IMDbFixtures.gzip(IMDbFixtures.table(rows: 5_000))
        #expect(throws: GzipError.self) { try inflate(gz.prefix(gz.count / 2)) }
        #expect(throws: GzipError.self) { try inflate(gz.dropLast(4)) }
    }

    @Test func aDamagedChecksumIsRefused() throws {
        var gz = try IMDbFixtures.gzip(IMDbFixtures.table(rows: 200))
        gz[gz.count - 8] ^= 0xFF
        #expect(throws: GzipError.checksumMismatch) { try inflate(gz) }
    }

    @Test func aWrongLengthIsRefused() throws {
        var gz = try IMDbFixtures.gzip(IMDbFixtures.table(rows: 200))
        gz[gz.count - 1] ^= 0x01
        #expect(throws: GzipError.sizeMismatch) { try inflate(gz) }
    }

    @Test func bytesAfterTheTrailerAreNotMistakenForOne() throws {
        var gz = try IMDbFixtures.gzip(IMDbFixtures.table(rows: 200))
        gz.append(contentsOf: [1, 2, 3])
        #expect(throws: GzipError.self) { try inflate(gz) }
    }

    @Test func aDamagedStreamIsRefused() throws {
        var gz = try IMDbFixtures.gzip(IMDbFixtures.table(rows: 2_000))
        for index in 40..<60 { gz[index] ^= 0xA5 }
        #expect(throws: GzipError.self) { try inflate(gz) }
    }
}

@Suite struct IMDbRatingsImporterTests {
    private func build(_ text: Data, minimumRows: Int = 10, gz: Bool = true) throws -> (Result<IMDbRatingsImporter.Summary, any Error>, URL, URL) {
        let directory = try IMDbFixtures.scratchDirectory()
        let source = try IMDbFixtures.write(gz ? IMDbFixtures.gzip(text) : text, to: directory, named: "in.gz")
        let destination = directory.appendingPathComponent("out.sqlite")
        let result = Result { try IMDbRatingsImporter.build(from: source, to: destination, minimumRows: minimumRows) }
        return (result, destination, directory)
    }

    @Test func buildsAnIndexedTableOfIDRatingAndVotes() async throws {
        let (result, destination, directory) = try build(IMDbFixtures.table(rows: 2_000))
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try result.get() == IMDbRatingsImporter.Summary(rows: 2_000, skippedRows: 0))
        let database = IMDbRatingsDatabase(fileURL: destination)
        #expect(await database.rating(for: "tt0000001") == IMDbRating(imdbID: "tt0000001", rating: 1.7, votes: 3))
        #expect(await database.rating(for: "tt0002000")?.votes == 6_000)
        #expect(await database.rating(for: "tt0002001") == nil)
        #expect(await database.titleCount() == 2_000)
    }

    @Test func ratingsKeepTheirExactDecimalValue() async throws {
        let rows = (1...12).map { String(format: "tt%07d\t%@\t5", $0, ["8.7", "10.0", "1.0", "9.9", "7", "6.1", "5.5", "4.4", "3.3", "2.2", "8.8", "9.3"][$0 - 1]) }
        let (result, destination, directory) = try build(Data((["tconst\taverageRating\tnumVotes"] + rows).joined(separator: "\n").utf8))
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try result.get()
        let database = IMDbRatingsDatabase(fileURL: destination)
        #expect(await database.rating(for: "tt0000001")?.rating == 8.7)
        #expect(await database.rating(for: "tt0000002")?.rating == 10)
        #expect(await database.rating(for: "tt0000005")?.rating == 7)
        #expect(await database.rating(for: "tt0000012")?.rating == 9.3)
    }

    @Test func windowsLineEndingsAndAMissingFinalNewlineAreFine() throws {
        let text = String(decoding: IMDbFixtures.table(rows: 50, ending: ""), as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n")
        let (result, _, directory) = try build(Data(text.utf8))
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try result.get().rows == 50)
    }

    @Test func aFewBadLinesAreSkippedButManyAreNot() throws {
        let tolerated = build(rows: 3_000, bad: 2)
        let refused = build(rows: 3_000, bad: 100)
        #expect(try tolerated.get() == IMDbRatingsImporter.Summary(rows: 3_000, skippedRows: 2))
        #expect(throws: IMDbImportError.tooManyBadRows(bad: 100, good: 3_000)) { try refused.get() }
    }

    private func build(rows: Int, bad: Int) -> Result<IMDbRatingsImporter.Summary, any Error> {
        let extras = (0..<bad).map { _ in "tt9999999\tnot-a-number\t5" }
        let text = IMDbFixtures.table(rows: rows, extra: extras)
        do {
            let (result, _, directory) = try build(text)
            try? FileManager.default.removeItem(at: directory)
            return result
        } catch { return .failure(error) }
    }

    @Test func rejectsRowsThatAreNotRatings() throws {
        let junk = ["tt1234567\t11.0\t5", "tt1234567\t-1\t5", "xx1234567\t5.0\t5", "tt1234567\t5.0\t-5", "tt1234567\t5.\t5", "tt1234567\t.5\t5",
                    "tt1234567\t5.0", "tt1234567\t5.0\t5\t7x", "\\N\t\\N\t\\N", "tt\t5.0\t5"]
        for line in junk {
            let (result, _, directory) = try build(IMDbFixtures.table(rows: 20, extra: [line]))
            defer { try? FileManager.default.removeItem(at: directory) }
            #expect(try result.get().skippedRows == 1, "\(line)")
        }
    }

    @Test func aRepeatedIDKeepsTheFirstRow() throws {
        let (result, destination, directory) = try build(IMDbFixtures.table(rows: 20, extra: ["tt0000001\t9.0\t1"]))
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try result.get() == IMDbRatingsImporter.Summary(rows: 20, skippedRows: 1))
        _ = destination
    }

    @Test func aFileThatIsNotTheRatingsTableIsRefused() throws {
        let (wrongHeader, _, one) = try build(IMDbFixtures.table(rows: 50, header: "tconst\tcategory\tnumVotes"))
        let (empty, _, two) = try build(Data())
        defer { try? FileManager.default.removeItem(at: one); try? FileManager.default.removeItem(at: two) }
        #expect(throws: IMDbImportError.badHeader) { try wrongHeader.get() }
        #expect(throws: (any Error).self) { try empty.get() }
    }

    @Test func tooFewRowsIsRefusedAndLeavesNoFile() throws {
        let (result, destination, directory) = try build(IMDbFixtures.table(rows: 5), minimumRows: 10)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: IMDbImportError.tooFewRows(5)) { try result.get() }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func aDamagedDownloadLeavesNoFile() throws {
        let directory = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var gz = try IMDbFixtures.gzip(IMDbFixtures.table(rows: 100))
        gz.removeLast(30)
        let source = try IMDbFixtures.write(gz, to: directory, named: "in.gz")
        let destination = directory.appendingPathComponent("out.sqlite")
        #expect(throws: (any Error).self) { try IMDbRatingsImporter.build(from: source, to: destination, minimumRows: 10) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

@Suite struct IMDbEpisodeIndexTests {
    @Test func indexesASeasonWithNoNetworkRequests() async throws {
        let folder = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let rows = [
            "tconst\tparentTconst\tseasonNumber\tepisodeNumber",
            "tt1480055\ttt0944947\t1\t1",
            "tt1668746\ttt0944947\t1\t2",
            "tt0000001\ttt0944947\t\\N\t\\N",
            "tt12345678\ttt0944947\t0\t1",
            "tt1480055\ttt0944947\t1\t1"
        ].joined(separator: "\n") + "\n"
        let archive = try IMDbFixtures.write(IMDbFixtures.gzip(Data(rows.utf8)), to: folder, named: "title.episode.tsv.gz")
        let file = folder.appendingPathComponent("title.episode.sqlite")
        #expect(try IMDbEpisodeImporter.build(from: archive, to: file, minimumRows: 3) == 3)
        let index = IMDbEpisodeIndex(directory: folder, minimumRows: 3)
        #expect(await index.episodeIDs(for: "tt0944947", season: 1) == [1: "tt1480055", 2: "tt1668746"])
        #expect(await index.episodeIDs(for: "tt0944947", season: 0) == [1: "tt12345678"])
        #expect(await index.episodeIDs(for: "tt0944947", season: 8).isEmpty)
    }

    @Test func failedUpdateKeepsPreviousCompleteIndex() async throws {
        let folder = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let rows = "tconst\tparentTconst\tseasonNumber\tepisodeNumber\ntt1480055\ttt0944947\t1\t1\n"
        let archive = try IMDbFixtures.gzip(Data(rows.utf8))
        let transport = ScriptedTransport([
            .file(archive, etag: "v1", lastModified: nil),
            .file(Data([0x00, 0x01]), etag: "v2", lastModified: nil)
        ])
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let index = IMDbEpisodeIndex(directory: folder, transport: transport, now: { clock.now }, minimumRows: 1)
        #expect(await index.refreshIfNeeded())
        #expect(await index.episodeIDs(for: "tt0944947", season: 1)[1] == "tt1480055")
        clock.advance(86_400)
        #expect(!(await index.refreshIfNeeded()))
        #expect(await index.episodeIDs(for: "tt0944947", season: 1)[1] == "tt1480055")
    }
}

@Suite struct IMDbRatingsDatabaseTests {
    private func database(rows: Int, in directory: URL, as name: String = "ratings.sqlite") throws -> IMDbRatingsDatabase {
        let source = try IMDbFixtures.write(IMDbFixtures.gzip(IMDbFixtures.table(rows: rows)), to: directory, named: "src-\(rows).gz")
        let url = directory.appendingPathComponent(name)
        _ = try IMDbRatingsImporter.build(from: source, to: url, minimumRows: 1)
        return IMDbRatingsDatabase(fileURL: url)
    }

    @Test func withoutAFileEveryLookupIsEmpty() async throws {
        let directory = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = IMDbRatingsDatabase(fileURL: directory.appendingPathComponent("none.sqlite"))
        #expect(await database.rating(for: "tt0000001") == nil)
        #expect(await database.titleCount() == nil)
    }

    @Test func onlyRealIDsAreLookedUp() async throws {
        let directory = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try database(rows: 100, in: directory)
        #expect(await database.rating(for: "tt0000010") != nil)
        for bad in ["", "0000010", "kitsu:10", "tt0000010' OR 1=1 --", "tt00000100000000000"] {
            #expect(await database.rating(for: bad) == nil, "\(bad)")
        }
    }

    @Test func installSwapsInTheNewFileAndKeepsAnswering() async throws {
        let directory = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = try database(rows: 100, in: directory)
        #expect(await live.rating(for: "tt0000100") != nil)
        #expect(await live.rating(for: "tt0000200") == nil)

        let replacement = try database(rows: 300, in: directory, as: "next.sqlite")
        try await live.install(replacement.fileURL)
        #expect(await live.rating(for: "tt0000200") != nil)
        #expect(await live.titleCount() == 300)
        #expect(await live.generation == 1)
        #expect(!FileManager.default.fileExists(atPath: replacement.fileURL.path))
    }

    @Test func aFailedInstallLeavesTheOldFileInUse() async throws {
        let directory = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = try database(rows: 100, in: directory)
        #expect(await live.rating(for: "tt0000050") != nil)
        await #expect(throws: (any Error).self) { try await live.install(directory.appendingPathComponent("missing.sqlite")) }
        #expect(await live.rating(for: "tt0000050") != nil)
        #expect(await live.generation == 0)
    }

    @Test func aFileThatIsNotADatabaseIsDiscarded() async throws {
        let directory = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ratings.sqlite")
        try Data(repeating: 0x41, count: 4_096).write(to: url)
        let database = IMDbRatingsDatabase(fileURL: url)
        #expect(await database.rating(for: "tt0000001") == nil)
        #expect(!database.exists)
    }
}

/// Answers each request from a queue and records what was asked.
final class ScriptedTransport: IMDbDatasetTransport, @unchecked Sendable {
    enum Reply {
        case file(Data, etag: String?, lastModified: String?)
        case notModified
        case fail(any Error)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var seen: [URLRequest] = []
    var delay: Duration = .zero

    init(_ replies: [Reply]) { self.replies = replies }

    var requests: [URLRequest] { lock.withLock { seen } }

    func download(_ request: URLRequest, into directory: URL) async throws -> IMDbDownload {
        let reply: Reply = lock.withLock {
            seen.append(request)
            return replies.isEmpty ? .fail(IMDbDatasetError.http(500)) : replies.removeFirst()
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        switch reply {
        case .notModified: return .notModified
        case .fail(let error): throw error
        case .file(let data, let etag, let lastModified):
            let url = directory.appendingPathComponent("title.ratings.tsv.gz")
            try data.write(to: url)
            return .file(url, etag: etag, lastModified: lastModified)
        }
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@Suite struct IMDbRatingsUpdaterTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func service(_ replies: [ScriptedTransport.Reply], clock: Clock, in directory: URL) -> (IMDbRatingsService, ScriptedTransport) {
        let transport = ScriptedTransport(replies)
        return (IMDbRatingsService(directory: directory, transport: transport, now: { clock.now }, minimumRows: 100, episodeSource: nil), transport)
    }

    private func file(rows: Int, etag: String = "\"v1\"", modified: String = "Sat, 10 Oct 2026 12:46:23 GMT") throws -> ScriptedTransport.Reply {
        .file(try IMDbFixtures.gzip(IMDbFixtures.table(rows: rows)), etag: etag, lastModified: modified)
    }

    @Test func theFirstLaunchDownloadsAndInstalls() async throws {
        let directory = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(start)
        let (service, transport) = service([try file(rows: 1_000)], clock: clock, in: directory)

        #expect(await service.rating(for: "tt0000001") == nil)
        #expect(await service.refreshIfNeeded() == .updated(titles: 1_000))
        #expect(await service.rating(for: "tt0000001")?.votes == 3)
        let status = await service.status()
        #expect(status == IMDbDatasetStatus(titleCount: 1_000, updatedAt: start, checkedAt: start, fileSize: status?.fileSize))
        #expect((status?.fileSize ?? 0) > 0, "the database takes space on disk")

        let request = try #require(transport.requests.first)
        #expect(request.url == IMDbRatingsUpdater.datasetURL)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil, "nothing to validate against yet")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("work").path), "no download left behind")
    }

    @Test func itChecksAtMostOnceADay() async throws {
        let directory = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(start)
        let (service, transport) = service([try file(rows: 1_000), .notModified, .notModified], clock: clock, in: directory)
        _ = await service.refreshIfNeeded()

        clock.advance(23 * 3_600 + 59 * 60)
        #expect(await service.refreshIfNeeded() == .skipped)
        #expect(transport.requests.count == 1)

        clock.advance(120)
        #expect(await service.refreshIfNeeded() == .notModified)
        #expect(transport.requests.count == 2)
        #expect(await service.refreshIfNeeded() == .skipped)
    }

    @Test func aRepeatCheckAsksWithTheValidatorsAndKeepsTheDataOn304() async throws {
        let directory = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(start)
        let (service, transport) = service([try file(rows: 1_000), .notModified], clock: clock, in: directory)
        _ = await service.refreshIfNeeded()
        clock.advance(86_400)
        #expect(await service.refreshIfNeeded() == .notModified)

        let request = transport.requests[1]
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == "Sat, 10 Oct 2026 12:46:23 GMT")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(!request.allowsConstrainedNetworkAccess, "a refresh waits out Low Data Mode")
        #expect(await service.rating(for: "tt0000001") != nil)
        let status = await service.status()
        #expect(status?.updatedAt == start && status?.checkedAt == start.addingTimeInterval(86_400))
    }

    @Test func aNewerFileReplacesTheOldOne() async throws {
        let directory = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(start)
        let (service, _) = service([try file(rows: 1_000), try file(rows: 1_200, etag: "\"v2\"")], clock: clock, in: directory)
        _ = await service.refreshIfNeeded()
        #expect(await service.rating(for: "tt0001100") == nil)
        clock.advance(86_400)
        #expect(await service.refreshIfNeeded() == .updated(titles: 1_200))
        #expect(await service.rating(for: "tt0001100") != nil)
        #expect(await service.updater.state().etag == "\"v2\"")
    }

    @Test func aFailureKeepsTheOldDataAndWaitsAnHour() async throws {
        let directory = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(start)
        let (service, transport) = service([try file(rows: 1_000), .fail(URLError(.notConnectedToInternet)), try file(rows: 1_100, etag: "\"v2\"")],
                                           clock: clock, in: directory)
        _ = await service.refreshIfNeeded()
        clock.advance(86_400)
        guard case .failed = await service.refreshIfNeeded() else { Issue.record("expected a failure"); return }
        #expect(await service.rating(for: "tt0000001") != nil)
        #expect(await service.status()?.titleCount == 1_000)

        clock.advance(30 * 60)
        #expect(await service.refreshIfNeeded() == .skipped)
        #expect(transport.requests.count == 2)
        clock.advance(31 * 60)
        #expect(await service.refreshIfNeeded() == .updated(titles: 1_100))
    }

    @Test func aBadHTTPAnswerIsAFailure() async throws {
        let directory = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (service, _) = service([.fail(IMDbDatasetError.http(503))], clock: Clock(start), in: directory)
        #expect(await service.refreshIfNeeded() == .failed("the server answered 503"))
        #expect(await service.status() == nil)
    }

    @Test func aDamagedOrWrongFileNeverReplacesGoodData() async throws {
        let directory = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(start)
        var truncated = try IMDbFixtures.gzip(IMDbFixtures.table(rows: 2_000))
        truncated.removeLast(500)
        let replies: [ScriptedTransport.Reply] = [
            try file(rows: 1_000),
            .file(truncated, etag: nil, lastModified: nil),
            .file(Data("<html>sign in to the wifi</html>".utf8), etag: nil, lastModified: nil),
            try file(rows: 150),                                    // under 80% of the 1,000 titles in use
            .file(try IMDbFixtures.gzip(IMDbFixtures.table(rows: 500, header: "id\trating\tvotes")), etag: nil, lastModified: nil),
        ]
        let (service, transport) = service(replies, clock: clock, in: directory)
        _ = await service.refreshIfNeeded()
        for _ in 1...4 {
            clock.advance(86_400)
            guard case .failed = await service.refreshIfNeeded() else { Issue.record("expected a refusal"); return }
        }
        #expect(transport.requests.count == 5)
        #expect(await service.status()?.titleCount == 1_000)
        #expect(await service.rating(for: "tt0001000") != nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(files == ["state.json", "title.ratings.sqlite"], "\(files)")
    }

    @Test func aSecondCallWhileOneIsRunningDoesNothing() async throws {
        let directory = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (service, transport) = service([try file(rows: 1_000)], clock: Clock(start), in: directory)
        transport.delay = .milliseconds(200)
        async let first = service.refreshIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await service.refreshIfNeeded() == .skipped)
        #expect(await first == .updated(titles: 1_000))
        #expect(transport.requests.count == 1)
    }

    @Test func aCopyDeletedBehindOurBackIsFetchedAgainWithoutValidators() async throws {
        let directory = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(start)
        let (service, transport) = service([try file(rows: 1_000), try file(rows: 1_000)], clock: clock, in: directory)
        _ = await service.refreshIfNeeded()
        try FileManager.default.removeItem(at: service.database.fileURL)
        clock.advance(60)
        #expect(await service.refreshIfNeeded() == .updated(titles: 1_000))
        #expect(transport.requests[1].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(transport.requests[1].allowsConstrainedNetworkAccess)
    }

    @Test func aClockSetBackDoesNotBlockTheNextCheckForever() async throws {
        let directory = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(start)
        let (service, _) = service([try file(rows: 1_000), .notModified], clock: clock, in: directory)
        _ = await service.refreshIfNeeded()
        clock.advance(-10 * 86_400)
        #expect(await service.refreshIfNeeded() == .notModified)
    }

    @Test func theDatasetFolderIsKeptOutOfBackups() throws {
        let directory = try IMDbFixtures.scratchDirectory().appendingPathComponent("IMDbRatings")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        _ = IMDbRatingsService(directory: directory)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func attributionNamesIMDbAndThePersonalUseTerms() {
        #expect(IMDbAttribution.notice.contains("IMDb") && IMDbAttribution.notice.contains("imdb.com"))
        #expect(IMDbAttribution.terms.contains("non-commercial"))
    }
}
#endif

#if canImport(SQLite3) && canImport(Compression)
/// Runs the importer on IMDb's real file when `IMDB_REAL_DATASET` names a downloaded copy. Skipped otherwise: tests use no network.
@Suite struct IMDbRealDatasetTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMDB_REAL_DATASET"] != nil))
    func theRealFileImportsAndAnswers() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["IMDB_REAL_DATASET"])
        let directory = try IMDbFixtures.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("real.sqlite")
        let started = Date()
        let summary = try IMDbRatingsImporter.build(from: URL(fileURLWithPath: path), to: destination)
        print("imported \(summary.rows) rows (\(summary.skippedRows) skipped) in \(Date().timeIntervalSince(started)) s,",
              (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0, "bytes")
        #expect(summary.rows > 1_000_000 && summary.skippedRows == 0)
        let database = IMDbRatingsDatabase(fileURL: destination)
        let shawshank = try #require(await database.rating(for: "tt0111161"))
        #expect(shawshank.rating >= 9.0 && shawshank.votes > 2_000_000)
        let clock = ContinuousClock()
        let elapsed = await clock.measure { for index in 1...2_000 { _ = await database.rating(for: String(format: "tt%07d", index * 700)) } }
        print("2000 lookups in", elapsed)
    }
}
#endif
