import Foundation

/// Remembers the last items each widget source loaded, so Home can show them at once on the next launch.
public protocol WidgetSnapshotStore: Sendable {
    func items(for source: WidgetSource) async -> [MetaPreview]?
    func save(_ items: [MetaPreview], for source: WidgetSource) async
    func clear() async
}

/// Snapshots that last as long as the process. Tests use it; the app uses `FileWidgetSnapshotStore`.
public actor InMemoryWidgetSnapshotStore: WidgetSnapshotStore {
    private var snapshots: [WidgetSource: [MetaPreview]] = [:]

    public init() {}

    public func items(for source: WidgetSource) async -> [MetaPreview]? { snapshots[source] }

    public func save(_ items: [MetaPreview], for source: WidgetSource) async { snapshots[source] = items }

    public func clear() async { snapshots = [:] }
}

/// One small JSON file per source in `directory` (created on demand), named by a stable hash of the source.
/// Keeps at most 60 files (the least recently written go first) and at most 40 items per file. Unreadable files read as nil.
public actor FileWidgetSnapshotStore: WidgetSnapshotStore {
    /// Home shows a row's first page at most, so more items per file would only cost disk and memory.
    static let itemsPerFile = 40
    static let filesKept = 60

    /// What one file holds. The source is stored with the items, so a file can never answer for a different source.
    private struct Snapshot: Codable {
        var source: WidgetSource
        var items: [MetaPreview]
    }

    private let directory: URL
    private let maxFiles: Int

    public init(directory: URL) {
        self.directory = directory
        self.maxFiles = Self.filesKept
    }

    /// `maxFiles` is injectable so a test can exercise the cap without writing sixty files.
    init(directory: URL, maxFiles: Int) {
        self.directory = directory
        self.maxFiles = maxFiles
    }

    public func items(for source: WidgetSource) async -> [MetaPreview]? {
        guard let data = try? Data(contentsOf: fileURL(for: source)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.source == source else { return nil }
        return snapshot.items
    }

    public func save(_ items: [MetaPreview], for source: WidgetSource) async {
        let snapshot = Snapshot(source: source, items: Array(items.prefix(Self.itemsPerFile)))
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = fileURL(for: source)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        prune(keeping: url)
    }

    public func clear() async {
        for url in snapshotFiles() { try? FileManager.default.removeItem(at: url) }
    }

    /// The file for a source. FNV-1a over the source's sorted-key JSON: unlike `Hasher`, it is the same in every launch.
    static func fileName(for source: WidgetSource) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = (try? encoder.encode(source)) ?? Data()
        let hash = bytes.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex + ".json"
    }

    private func fileURL(for source: WidgetSource) -> URL {
        directory.appendingPathComponent(Self.fileName(for: source))
    }

    private func snapshotFiles() -> [URL] {
        let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                               options: [.skipsHiddenFiles])
        return (urls ?? []).filter { $0.pathExtension == "json" }
    }

    /// Removes the least recently written files beyond `maxFiles`. The file just written is never the one removed.
    private func prune(keeping current: URL) {
        let files = snapshotFiles()
        let excess = files.count - maxFiles
        guard excess > 0 else { return }
        let oldestFirst = files.filter { $0 != current }.map { (url: $0, written: Self.modified($0)) }.sorted { $0.written < $1.written }
        for entry in oldestFirst.prefix(excess) { try? FileManager.default.removeItem(at: entry.url) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
