import Foundation
import Testing
@testable import StremioKit

@Suite struct WidgetSnapshotStoreTests {
    private let top = WidgetSource.addonCatalog(AddonCatalogReference(manifestID: "test.catalog", host: "example.com", catalogType: "movie", catalogID: "top"))
    private let trending = WidgetSource.addonCatalog(AddonCatalogReference(manifestID: "test.catalog", host: "example.com", catalogType: "series",
                                                                           catalogID: "trending"))

    private func items(_ count: Int) -> [MetaPreview] {
        (0..<count).map { MetaPreview(id: "tt\($0)", type: "movie", name: "Movie \($0)") }
    }

    /// A directory that does not exist yet, so the store has to create it.
    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("blusion-widget-snapshots-\(UUID().uuidString)/nested", isDirectory: true)
    }

    private func jsonFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    }

    @Test func theInMemoryStoreRoundTripsAndClears() async {
        let store = InMemoryWidgetSnapshotStore()
        #expect(await store.items(for: top) == nil)
        await store.save(items(3), for: top)
        #expect(await store.items(for: top) == items(3))
        #expect(await store.items(for: trending) == nil, "a different source reads nil")
        await store.clear()
        #expect(await store.items(for: top) == nil)
    }

    @Test func aFileStoreRoundTripsAndANewInstanceReadsTheSameItems() async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = FileWidgetSnapshotStore(directory: directory)
        await store.save(items(5), for: top)
        #expect(await store.items(for: top) == items(5))
        #expect(await FileWidgetSnapshotStore(directory: directory).items(for: top) == items(5), "survives a new instance, as after a relaunch")
    }

    @Test func aDifferentSourceReadsNil() async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = FileWidgetSnapshotStore(directory: directory)
        await store.save(items(2), for: top)
        #expect(await store.items(for: trending) == nil)
        #expect(await store.items(for: top) == items(2))
    }

    @Test func fileNamesAreStableHexNames() {
        let name = FileWidgetSnapshotStore.fileName(for: top)
        #expect(name == "91d415c4801eeb75.json", "FNV-1a of the sorted-key JSON: the same name in every launch")
        #expect(FileWidgetSnapshotStore.fileName(for: top) == name)
        let hex = name.dropLast(".json".count)
        #expect(hex.count == 16 && hex.allSatisfy { $0.isHexDigit })
        #expect(FileWidgetSnapshotStore.fileName(for: trending) != name)
    }

    @Test func onlyFortyItemsArePersistedPerSource() async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = FileWidgetSnapshotStore(directory: directory)
        await store.save(items(50), for: top)
        let kept = try #require(await store.items(for: top))
        #expect(kept == Array(items(50).prefix(40)))
    }

    @Test func theLeastRecentlyWrittenFilesGoFirstWhenTheCapIsReached() async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = FileWidgetSnapshotStore(directory: directory, maxFiles: 3)
        let sources = (0..<4).map { index in
            WidgetSource.addonCatalog(AddonCatalogReference(manifestID: "test.catalog", catalogType: "movie", catalogID: "list\(index)"))
        }
        // Modification times decide the order, so each write waits a moment to get its own timestamp.
        for source in sources[0...2] {
            await store.save(items(1), for: source)
            try await Task.sleep(for: .milliseconds(20))
        }
        await store.save(items(2), for: sources[0])
        try await Task.sleep(for: .milliseconds(20))
        #expect(try jsonFiles(in: directory).count == 3)

        await store.save(items(1), for: sources[3])
        #expect(try jsonFiles(in: directory).count == 3, "the cap holds")
        #expect(await store.items(for: sources[1]) == nil, "the least recently written source went first")
        #expect(await store.items(for: sources[0]) == items(2), "rewriting a source made it recent")
        #expect(await store.items(for: sources[2]) == items(1))
        #expect(await store.items(for: sources[3]) == items(1), "the file just written is never the one removed")
    }

    @Test func clearRemovesEverySnapshot() async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = FileWidgetSnapshotStore(directory: directory)
        await store.save(items(2), for: top)
        await store.save(items(2), for: trending)
        await store.clear()
        let topAfterClear = await store.items(for: top)
        let trendingAfterClear = await store.items(for: trending)
        #expect(topAfterClear == nil && trendingAfterClear == nil)
        #expect(try jsonFiles(in: directory).isEmpty)
        await store.save(items(1), for: top)
        #expect(await store.items(for: top) == items(1), "the store still works after a clear")
    }

    @Test func aCorruptFileReadsNil() async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = FileWidgetSnapshotStore(directory: directory)
        await store.save(items(2), for: top)
        let file = try #require(try jsonFiles(in: directory).first)
        try Data("not json at all".utf8).write(to: file)
        #expect(await store.items(for: top) == nil)
        try Data(#"{"source": "wrong shape"}"#.utf8).write(to: file)
        #expect(await store.items(for: top) == nil)
    }

    @Test func twoStoresOnOneDirectorySeeEachOthersData() async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let first = FileWidgetSnapshotStore(directory: directory)
        let second = FileWidgetSnapshotStore(directory: directory)
        await first.save(items(2), for: top)
        #expect(await second.items(for: top) == items(2))
        await second.save(items(4), for: trending)
        #expect(await first.items(for: trending) == items(4))
    }
}
