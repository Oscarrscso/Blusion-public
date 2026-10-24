import Foundation
import PlayerKit
import StremioKit

/// The library the app reads and writes. It is the plain store, and it tells `TraktSync` of every change made through it, so a title
/// saved or removed anywhere in the app reaches Trakt without each screen having to say so. Sync itself writes to the plain store.
public struct SyncedLibraryStore: LibraryStore {
    private let base: any LibraryStore
    private let sync: TraktSync

    public init(base: any LibraryStore, sync: TraktSync) {
        self.base = base
        self.sync = sync
    }

    public func all() async -> [LibraryItem] { await base.all() }
    public func contains(_ id: String) async -> Bool { await base.contains(id) }
    public func add(_ item: LibraryItem) async { await add([item]) }

    public func add(_ items: [LibraryItem]) async {
        // A title that is already saved is not saved again, so it is not a change.
        var fresh: [LibraryItem] = []
        for item in items {
            if await !base.contains(item.id) { fresh.append(item) }
        }
        await base.add(items)
        await sync.titlesSaved(fresh)
    }

    public func remove(_ id: String) async {
        // The removal is recorded before the title goes, so a read of Trakt running at this moment cannot put it back.
        if await base.contains(id) { await sync.titleUnsaved(id) }
        await base.remove(id)
    }

    public func clear() async {
        await base.clear()
        await sync.libraryCleared()
    }
}

/// The watch progress the app reads and writes: the plain store, telling `TraktSync` what each write replaced, so it can tell a new
/// watched mark, a cleared one and a new paused position apart.
public struct SyncedProgressStore: ProgressStore {
    private let base: any ProgressStore
    private let sync: TraktSync

    public init(base: any ProgressStore, sync: TraktSync) {
        self.base = base
        self.sync = sync
    }

    public func progress(for identity: String) async -> WatchProgress? { await base.progress(for: identity) }
    public func progress(for identities: [String]) async -> [WatchProgress] { await base.progress(for: identities) }
    public func all() async -> [WatchProgress] { await base.all() }
    public func save(_ progress: WatchProgress) async { await save([progress]) }

    public func save(_ records: [WatchProgress]) async {
        // In ghost mode nothing watched is recorded: no position, no watched mark, so nothing joins Continue Watching.
        guard !records.isEmpty, !GhostMode.isOn else { return }
        let previous = await base.progress(for: records.map(\.id))
        await base.save(records)
        await sync.progressSaved(records, previous: previous)
    }

    public func remove(_ identity: String) async { await remove([identity]) }

    public func remove(_ identities: [String]) async {
        guard !identities.isEmpty else { return }
        // Recorded before the records go, for the same reason as a removed title (see `SyncedLibraryStore.remove`).
        await sync.progressRemoved(await base.progress(for: identities))
        await base.remove(identities)
    }

    public func clear() async {
        await base.clear()
        await sync.historyCleared()
    }
}
