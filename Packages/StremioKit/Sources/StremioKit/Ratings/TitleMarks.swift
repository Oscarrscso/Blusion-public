import Foundation

/// What is known of a title's mark: its best disc by Best Blurays, and the first service it streams on in the viewer's region, each
/// with the day it was asked. A nil date means never asked; a nil value with a date means asked, and there was none.
public struct TitleMarkRecord: Sendable, Equatable {
    public var disc: BestDiscFormat?
    public var discCheckedAt: Date?
    public var streamer: TMDbWatchService?
    public var streamerCheckedAt: Date?

    public init(disc: BestDiscFormat? = nil, discCheckedAt: Date? = nil, streamer: TMDbWatchService? = nil, streamerCheckedAt: Date? = nil) {
        self.disc = disc
        self.discCheckedAt = discCheckedAt
        self.streamer = streamer
        self.streamerCheckedAt = streamerCheckedAt
    }
}

/// Every title's mark in one small binary file, 12 bytes a title: 100,000 titles take 1.2 MB. A title is its IMDb number, a day is
/// counted from 2020, and a service is TMDb's number for it; each service's name and logo are kept once, in a table at the head of the
/// file. Streaming answers belong to one region, so a file written for another keeps its discs and drops its services. Writes are
/// coalesced, at most one per `flushInterval`. Over capacity, the titles asked least recently go first, a tenth at a time. A file that
/// cannot be read starts it empty. With no file, it is kept in memory only.
public actor TitleMarksCache {
    public nonisolated let region: String
    private let fileURL: URL?
    private let capacity: Int
    private let flushInterval: Duration
    private var entries: [UInt32: Entry] = [:]
    private var services: [UInt16: TMDbWatchService] = [:]
    private var isLoaded = false
    private var isDirty = false
    private var lastWrite: ContinuousClock.Instant?
    private var pendingWrite: Task<Void, Never>?

    struct Entry: Equatable {
        /// Days since 1 January 2020, plus one; 0 means never asked.
        var discDay: UInt16 = 0
        var streamerDay: UInt16 = 0
        /// TMDb's number for the service; 0 means none.
        var streamer: UInt16 = 0
        /// 0 none, 1 Blu-ray, 2 4K Blu-ray.
        var disc: UInt8 = 0

        var lastDay: UInt16 { max(discDay, streamerDay) }
    }

    public init(fileURL: URL?, region: String, capacity: Int = 100_000) {
        self.init(fileURL: fileURL, region: region, capacity: capacity, flushInterval: .seconds(2))
    }

    init(fileURL: URL?, region: String, capacity: Int, flushInterval: Duration) {
        self.fileURL = fileURL
        self.region = region
        self.capacity = max(10, capacity)
        self.flushInterval = flushInterval
    }

    public func record(for imdbID: String) -> TitleMarkRecord? {
        loadIfNeeded()
        guard let key = Self.key(imdbID), let entry = entries[key] else { return nil }
        return TitleMarkRecord(disc: Self.disc(entry.disc), discCheckedAt: Self.date(entry.discDay),
                               streamer: entry.streamer == 0 ? nil : services[entry.streamer], streamerCheckedAt: Self.date(entry.streamerDay))
    }

    public func storeDisc(_ disc: BestDiscFormat?, for imdbID: String, checkedAt: Date) {
        update(imdbID) { entry in
            entry.disc = switch disc { case .bluRay: 1; case .uhdBluRay: 2; case nil: 0 }
            entry.discDay = Self.day(checkedAt)
        }
    }

    /// A service whose number does not fit is kept as none.
    public func storeStreamer(_ service: TMDbWatchService?, for imdbID: String, checkedAt: Date) {
        let number = service.flatMap { UInt16(exactly: $0.id) } ?? 0
        if number != 0, let service { services[number] = service }
        update(imdbID) { entry in
            entry.streamer = number
            entry.streamerDay = Self.day(checkedAt)
        }
    }

    /// Removes the file at once, so "Clear data" leaves nothing behind.
    public func clear() {
        isLoaded = true
        entries.removeAll()
        services.removeAll()
        isDirty = false
        pendingWrite?.cancel()
        pendingWrite = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func update(_ imdbID: String, _ change: (inout Entry) -> Void) {
        loadIfNeeded()
        guard let key = Self.key(imdbID) else { return }
        var entry = entries[key] ?? Entry()
        change(&entry)
        guard entries[key] != entry else { return }
        entries[key] = entry
        trimToCapacity()
        isDirty = true
        scheduleWrite()
    }

    private func trimToCapacity() {
        guard entries.count > capacity else { return }
        let excess = entries.count - capacity * 9 / 10
        for (key, _) in entries.sorted(by: { $0.value.lastDay < $1.value.lastDay }).prefix(excess) {
            entries[key] = nil
        }
    }

    // MARK: - Keys and days

    /// "tt0468569" is 468569.
    static func key(_ imdbID: String) -> UInt32? {
        guard imdbID.hasPrefix("tt") else { return nil }
        return UInt32(imdbID.dropFirst(2))
    }

    private static let epoch = Date(timeIntervalSince1970: 1_577_836_800)

    static func day(_ date: Date) -> UInt16 {
        let days = Int((date.timeIntervalSince(epoch) / 86_400).rounded(.down)) + 1
        return UInt16(clamping: max(1, days))
    }

    static func date(_ day: UInt16) -> Date? {
        day == 0 ? nil : epoch.addingTimeInterval(TimeInterval(Int(day) - 1) * 86_400)
    }

    private static func disc(_ code: UInt8) -> BestDiscFormat? {
        switch code {
        case 1: .bluRay
        case 2: .uhdBluRay
        default: nil
        }
    }

    // MARK: - The file

    /// "BMRK", a version, the region, the services (number, name, logo), then the titles at 12 bytes each.
    private static let magic: [UInt8] = Array("BMRK".utf8)
    private static let version: UInt8 = 1

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL), let decoded = Self.decode(data, region: region) else { return }
        (entries, services) = decoded
        trimToCapacity()
    }

    static func encode(entries: [UInt32: Entry], services: [UInt16: TMDbWatchService], region: String) -> Data {
        var data = Data(magic)
        data.append(version)
        data.appendShortText(region)
        // Only the services a title still names.
        let used = Set(entries.values.map(\.streamer)).subtracting([0])
        let kept = services.filter { used.contains($0.key) }
        data.appendInteger(UInt16(kept.count))
        for (number, service) in kept {
            data.appendInteger(number)
            data.appendShortText(service.name)
            data.appendShortText(service.logo?.absoluteString ?? "")
        }
        data.appendInteger(UInt32(entries.count))
        data.reserveCapacity(data.count + entries.count * 12)
        for (key, entry) in entries {
            data.appendInteger(key)
            data.appendInteger(entry.discDay)
            data.appendInteger(entry.streamerDay)
            data.appendInteger(entry.streamer)
            data.append(entry.disc)
            data.append(0)
        }
        return data
    }

    static func decode(_ data: Data, region: String) -> (entries: [UInt32: Entry], services: [UInt16: TMDbWatchService])? {
        var reader = ByteReader(bytes: [UInt8](data))
        guard reader.bytes(4) == magic, reader.byte() == version, let fileRegion = reader.shortText(),
              let serviceCount: UInt16 = reader.integer() else { return nil }
        let sameRegion = fileRegion == region
        var services: [UInt16: TMDbWatchService] = [:]
        for _ in 0..<serviceCount {
            guard let number: UInt16 = reader.integer(), let name = reader.shortText(), let logo = reader.shortText() else { return nil }
            services[number] = TMDbWatchService(id: Int(number), name: name, logo: logo.isEmpty ? nil : URL(string: logo))
        }
        guard let count: UInt32 = reader.integer() else { return nil }
        var entries: [UInt32: Entry] = [:]
        entries.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let key: UInt32 = reader.integer(), let discDay: UInt16 = reader.integer(), let streamerDay: UInt16 = reader.integer(),
                  let streamer: UInt16 = reader.integer(), let disc = reader.byte(), reader.byte() != nil else { return nil }
            var entry = Entry(discDay: discDay, streamerDay: streamerDay, streamer: streamer, disc: disc)
            if !sameRegion { entry.streamerDay = 0; entry.streamer = 0 }
            if entry.lastDay != 0 { entries[key] = entry }
        }
        return (entries, sameRegion ? services : [:])
    }

    /// The first store writes at once; later ones wait until `flushInterval` after the last write.
    private func scheduleWrite() {
        guard fileURL != nil, pendingWrite == nil else { return }
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
        guard isDirty, let fileURL else { return }
        lastWrite = ContinuousClock.now
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encode(entries: entries, services: services, region: region).write(to: fileURL, options: .atomic)
            isDirty = false
        } catch {}
    }
}

private struct ByteReader {
    let bytes: [UInt8]
    var offset = 0

    mutating func byte() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func bytes(_ count: Int) -> [UInt8]? {
        guard offset + count <= bytes.count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    /// Little-endian.
    mutating func integer<T: FixedWidthInteger & UnsignedInteger>() -> T? {
        guard let raw = bytes(MemoryLayout<T>.size) else { return nil }
        return raw.enumerated().reduce(T(0)) { $0 | T($1.element) << (8 * $1.offset) }
    }

    mutating func shortText() -> String? {
        guard let length = byte(), let raw = bytes(Int(length)) else { return nil }
        return String(decoding: raw, as: UTF8.self)
    }
}

private extension Data {
    /// Little-endian.
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    /// One length byte, then at most 255 bytes of UTF-8, cut at a character boundary.
    mutating func appendShortText(_ text: String) {
        var cut = Substring(text)
        while cut.utf8.count > 255 { cut = cut.dropLast() }
        append(UInt8(cut.utf8.count))
        append(contentsOf: Array(cut.utf8))
    }
}
