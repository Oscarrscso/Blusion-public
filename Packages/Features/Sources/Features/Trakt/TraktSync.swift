import Foundation
import PlayerKit
import StremioKit
#if canImport(Network)
import Network
#endif

/// Two-way sync with Trakt, which is also how the iPhone and the Mac keep each other's saved titles, watched marks and paused positions.
///
/// Every change the user makes reaches here through the synced stores (see `SyncedLibraryStore`) and becomes one queued operation, kept
/// on disk until Trakt has taken it. Reading Trakt back is a merge, not an import: a title Trakt no longer lists leaves here too, and a
/// title removed here does not come back from an older Trakt entry, because the removal is recorded with its time. The watchlist and
/// the collection stay apart: saving and removing write the watchlist only, and the collection is only read.
///
/// The stores given here are the plain ones, so what sync writes is never taken for a change the user made.
public actor TraktSync {
    /// What one sync changed.
    public struct Summary: Sendable, Equatable {
        /// Saved titles and watched marks brought in from Trakt.
        public var savedAdded = 0
        public var watchedAdded = 0
        /// Saved titles and watched marks removed here because they left Trakt.
        public var savedRemoved = 0
        public var watchedRemoved = 0
        /// Saved titles and watched items Trakt added or removed for the changes sent.
        public var savedSent = 0
        public var watchedSent = 0

        public init() {}

        /// True when the library or the watch history here is not what it was.
        public var changedLocalData: Bool { savedAdded + watchedAdded + savedRemoved + watchedRemoved > 0 }
    }

    /// How long changes wait for more of the same before they are sent, so marking a season is one request.
    static let batchDelay: TimeInterval = 2
    /// How long a playing title's position waits. Each newer position starts the wait again, so one goes out when playback has stopped.
    static let playbackSettle: TimeInterval = 20
    /// Trakt's change dates are not asked for more often than this, unless a sync is forced.
    static let checkInterval: TimeInterval = 60
    /// Everything is read again this often whatever the change dates say.
    static let fullPullInterval: TimeInterval = 6 * 3600
    /// A paused record this much newer than the removal that should clear it is still taken for the same one: the clocks differ.
    static let clockSlack: TimeInterval = 5
    /// An unforced sync removes at most this many titles at once, or half of what Trakt held when that is more. An answer that asks for
    /// more (a list cut short by a failing server reads the same as a cleared account) is left for a sync the user asks for. A smaller
    /// mistake mends itself: what was removed for it is still on Trakt, and the next read brings it back.
    static let largestQuietRemoval = 20

    private let account: TraktAccount
    private let library: any LibraryStore
    private let progress: any ProgressStore
    private let store: any TraktSyncStateStore
    private let now: @Sendable () -> Date
    /// Off in tests, which sync when they choose.
    private let schedulesItself: Bool

    private var state = TraktSyncState()
    /// The state as the store last got it, so a change that changed nothing (a position saved while signed out) writes nothing.
    private var stored = TraktSyncState()
    private var isLoaded = false
    /// The sync that is running or was last asked for. Each new one waits for it, so two never run at once.
    private var running: Task<Summary, Error>?
    private var scheduled: Task<Void, Never>?
    private var lastCheck = Date.distantPast
    /// Failed syncs in a row, for the growing pause between retries.
    private var failures = 0
    /// No scheduled sync before this: the pause after a failure, or for ever while Trakt wants a new sign-in.
    private var pausedUntil = Date.distantPast
    #if canImport(Network)
    private var monitor: NWPathMonitor?
    #endif

    public init(account: TraktAccount, library: any LibraryStore, progress: any ProgressStore,
                store: any TraktSyncStateStore = InMemoryTraktSyncStateStore(), schedulesItself: Bool = false,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.account = account
        self.library = library
        self.progress = progress
        self.store = store
        self.schedulesItself = schedulesItself
        self.now = now
    }

    // MARK: - Changes made here

    /// Titles the user saved. Each goes on the Trakt watchlist, and is no longer a title removed here.
    func titlesSaved(_ items: [LibraryItem]) async {
        guard !items.isEmpty else { return }
        await load()
        let signedIn = await account.isSignedIn()
        for item in items {
            state.removedSaved[item.id] = nil
            state.collected.remove(item.id)
            if signedIn, let operation = TraktSyncOperation(kind: .save, identity: item.id, at: item.addedAt) { enqueue(operation) }
        }
        await changed()
    }

    /// A saved title the user removed. The removal is recorded with its time, so an older Trakt entry cannot bring it back, and it comes
    /// off the watchlist. A title that was here only for the collection is not on the watchlist, so nothing is sent for it.
    func titleUnsaved(_ id: String) async {
        await load()
        let date = now()
        state.removedSaved[id] = date
        let wasCollected = state.collected.remove(id) != nil
        if !wasCollected, await account.isSignedIn(), let operation = TraktSyncOperation(kind: .unsave, identity: id, at: date) {
            enqueue(operation)
        }
        await changed()
    }

    /// Progress records the user's playback or marks wrote, with what each replaced. A new watched mark goes to the history, a cleared
    /// one comes out of it, and a new paused position is sent once playback has been still for a moment.
    func progressSaved(_ records: [WatchProgress], previous: [WatchProgress]) async {
        guard !records.isEmpty else { return }
        await load()
        let signedIn = await account.isSignedIn()
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let date = now()
        for record in records {
            let old = before[record.id]
            if record.isWatched {
                guard old?.isWatched != true else { continue }
                state.unwatched[record.id] = nil
                guard signedIn else { continue }
                if let operation = TraktSyncOperation(kind: .watched, identity: record.id, at: record.updatedAt) { enqueue(operation) }
                // A position sent for it earlier is finished with: Trakt keeps paused records apart from the history.
                state.operations.removeAll { $0.kind == .progress && $0.identity == record.id }
                if let old, Self.isResumable(old), let operation = TraktSyncOperation(kind: .removePlayback, identity: record.id, at: record.updatedAt) {
                    enqueue(operation)
                }
                continue
            }
            if old?.isWatched == true {
                state.unwatched[record.id] = date
                if signedIn, let operation = TraktSyncOperation(kind: .unwatched, identity: record.id, at: date) { enqueue(operation) }
            }
            guard Self.isResumable(record), record.duration > 0, old?.position != record.position else { continue }
            state.removedPlayback[record.id] = nil
            if signedIn, let operation = TraktSyncOperation(kind: .progress, identity: record.id, at: record.updatedAt,
                                                           progress: record.fraction * 100,
                                                           notBefore: date.addingTimeInterval(Self.playbackSettle)) {
                enqueue(operation)
            }
        }
        await changed()
    }

    /// Progress records the user removed. Clearing a watched mark is recorded with its time and taken out of Trakt's history; dropping
    /// a paused title takes Trakt's paused record with it.
    func progressRemoved(_ records: [WatchProgress]) async {
        guard !records.isEmpty else { return }
        await load()
        let signedIn = await account.isSignedIn()
        let date = now()
        for record in records {
            if record.isWatched {
                state.unwatched[record.id] = date
                if signedIn, let operation = TraktSyncOperation(kind: .unwatched, identity: record.id, at: date) { enqueue(operation) }
            } else if Self.isResumable(record) {
                recordPlaybackRemoval(record.id, at: date, signedIn: signedIn)
            }
        }
        await changed()
    }

    /// A title taken off Continue Watching, whether or not this device holds a position for it: Trakt's paused record is removed, and
    /// until it is, it stays hidden (see `visiblePlayback`).
    public func playbackRemoved(_ identity: String) async {
        await load()
        recordPlaybackRemoval(identity, at: now(), signedIn: await account.isSignedIn())
        await changed()
    }

    private func recordPlaybackRemoval(_ identity: String, at date: Date, signedIn: Bool) {
        state.removedPlayback[identity] = date
        if signedIn, let operation = TraktSyncOperation(kind: .removePlayback, identity: identity, at: date) { enqueue(operation) }
    }

    /// The whole library was cleared here. Nothing is removed from Trakt for that, so the next sync brings Trakt's titles back.
    func libraryCleared() async {
        await load()
        state.operations.removeAll { $0.slot == .saved }
        state.removedSaved = [:]
        state.syncedSaved = []
        state.collected = []
        readEverythingNext()
        await persist()
    }

    /// The whole watch history was cleared here. Nothing is removed from Trakt for that.
    func historyCleared() async {
        await load()
        state.operations.removeAll { $0.slot != .saved }
        state.unwatched = [:]
        state.removedPlayback = [:]
        state.syncedWatched = []
        readEverythingNext()
        await persist()
    }

    /// What was known of Trakt's lists has been dropped, so the next sync reads them all again whatever Trakt's change dates say.
    /// Until it has, nothing here can tell which watches Trakt already holds.
    private func readEverythingNext() {
        state.activities = nil
        state.lastFullPull = nil
        lastCheck = .distantPast
    }

    private static func isResumable(_ record: WatchProgress) -> Bool {
        !record.isWatched && ProgressRecorder.resumePosition(for: record) > 0
    }

    /// Puts a change on the queue in place of the one waiting for the same title and slot. A change that undoes one Trakt has
    /// certainly not seen needs nothing sent when Trakt already holds the result: saving a title and removing it again before either
    /// left is no request at all.
    private func enqueue(_ operation: TraktSyncOperation) {
        // In ghost mode nothing is queued for Trakt, so nothing done meanwhile is sent once it is switched off.
        guard !GhostMode.isOn else { return }
        if let index = state.operations.firstIndex(where: { $0.id == operation.id }) {
            let waiting = state.operations.remove(at: index)
            let traktHasIt = operation.slot == .saved ? state.syncedSaved.contains(operation.identity)
                                                      : state.syncedWatched.contains(operation.identity)
            if waiting.attempts == 0, waiting.kind == operation.inverse, traktHasIt == operation.isAddition { return }
        }
        state.operations.append(operation)
    }

    /// After a change made here: the state is saved, and the queue is sent shortly.
    private func changed() async {
        await persist()
        schedule()
    }

    // MARK: - Trakt's paused records

    /// Trakt's paused records without the ones taken off Continue Watching here since they were paused.
    public func visiblePlayback(_ items: [TraktPlaybackItem]) async -> [TraktPlaybackItem] {
        await load()
        return items.filter { item in
            guard let removed = state.removedPlayback[item.id] else { return true }
            return item.pausedAt > removed.addingTimeInterval(Self.clockSlack)
        }
    }

    /// Keeps Trakt's newer paused positions here, so a title paused on another device resumes from there. Only a real runtime can turn
    /// Trakt's percentage into a position. A record that is already at the same place is left alone: Trakt's runtime is only an estimate
    /// of this file's length, and the position sent from here comes back with a later date.
    /// A local runtime takes precedence, and a pause cannot clear a watched mark; only history sync does that.
    public func storeRemotePlayback(_ items: [TraktPlaybackItem]) async {
        for item in items {
            let previous = await progress.progress(for: item.id)
            guard let duration = [previous?.duration, item.duration].compactMap({ $0 }).first(where: { $0.isFinite && $0 > 0 }) else { continue }
            if let previous, previous.updatedAt >= item.pausedAt { continue }
            if let previous, !previous.isWatched, previous.duration > 0, abs(previous.fraction * 100 - item.progress) < 0.5 { continue }
            await progress.save(WatchProgress(id: item.id, type: item.preview.type, contentID: item.contentID,
                title: item.request.title, poster: item.preview.poster, position: duration * item.progress / 100,
                duration: duration, isWatched: previous?.isWatched ?? false, updatedAt: item.pausedAt, season: item.season, episode: item.episode))
        }
    }

    // MARK: - Syncing

    /// Changes still waiting to reach Trakt.
    public func pendingCount() async -> Int {
        await load()
        return state.operations.count
    }

    /// Reads what changed on Trakt, merges it in, then sends what is waiting. Unforced, it asks Trakt for its change dates at most once
    /// a minute and fetches only what they say changed. Forced (the Trakt screen's buttons, a fresh sign-in), it reads everything and
    /// applies every removal. `sendingLocalOnly` also queues the saved titles and watched marks here that Trakt has never had.
    /// Signed out, it does nothing. Throws what stopped it; whatever was not sent stays queued.
    @discardableResult
    public func sync(force: Bool = false, sendingLocalOnly: Bool = false) async throws -> Summary {
        let previous = running
        let task = Task { [weak self] () throws -> Summary in
            _ = await previous?.result
            // In ghost mode Trakt is left alone: nothing is read from it and nothing is sent.
            guard let self, !GhostMode.isOn else { return Summary() }
            return try await self.runSync(force: force, sendingLocalOnly: sendingLocalOnly)
        }
        running = task
        return try await task.value
    }

    private func runSync(force: Bool, sendingLocalOnly: Bool) async throws -> Summary {
        await load()
        guard await account.isSignedIn() else { return Summary() }
        var summary = Summary()
        do {
            if force || now().timeIntervalSince(lastCheck) >= Self.checkInterval {
                try await pull(force: force, sendingLocalOnly: sendingLocalOnly, into: &summary)
            }
            let sent = try await send(into: &summary)
            failures = 0
            pausedUntil = .distantPast
            // What was just sent is in Trakt's lists now. They are read again shortly, so a later removal elsewhere is recognised.
            if sent { lastCheck = .distantPast }
            await persist()
            schedule(refreshing: sent)
        } catch {
            if let error = error as? TraktAccountError, Self.needsSignIn(error) {
                pausedUntil = .distantFuture
            } else {
                failures += 1
                pausedUntil = now().addingTimeInterval(min(3600, 30 * pow(2, Double(failures - 1))))
            }
            // A request that failed may still have reached Trakt. The retry reads Trakt first, so a watch that did arrive is not sent again.
            lastCheck = .distantPast
            await persist()
            schedule()
            throw error
        }
        return summary
    }

    /// The errors that mean Trakt will refuse everything until the user signs in again. The queue is kept as it is for then.
    private static func needsSignIn(_ error: TraktAccountError) -> Bool {
        switch error {
        case .needsCredentials, .needsSignIn, .credentialsChanged, .network(.http(status: 401)): return true
        default: return false
        }
    }

    // MARK: Reading Trakt

    private func pull(force: Bool, sendingLocalOnly: Bool, into summary: inout Summary) async throws {
        let activities = try await account.lastActivities()
        lastCheck = now()
        let known = state.activities
        let full = force || state.lastFullPull.map { now().timeIntervalSince($0) >= Self.fullPullInterval } ?? true
        if full || known?.watchlist != activities.watchlist || known?.collection != activities.collection {
            async let listed = account.watchlistEntries()
            async let owned = account.collectionEntries()
            let (watchlist, collection) = try await (listed, owned)
            guard await account.isSignedIn() else { throw TraktAccountError.needsSignIn }
            await mergeSaved(watchlist: watchlist, collection: collection, force: force, sendingLocalOnly: sendingLocalOnly, into: &summary)
            var seen = state.activities ?? TraktLastActivities()
            seen.watchlist = activities.watchlist
            seen.collection = activities.collection
            state.activities = seen
            await persist()
        }
        if full || known?.watched != activities.watched {
            let watched = try await account.watched()
            guard await account.isSignedIn() else { throw TraktAccountError.needsSignIn }
            await mergeWatched(watched, force: force, sendingLocalOnly: sendingLocalOnly, into: &summary)
        }
        state.activities = activities
        if full { state.lastFullPull = now() }
        await persist()
    }

    /// A title Trakt holds comes back here unless it was removed here at or after Trakt's date for it. Without a date from Trakt, the
    /// removal stands.
    private static func revives(_ remoteDate: Date?, removedAt: Date?) -> Bool {
        guard let removedAt else { return true }
        guard let remoteDate else { return false }
        return remoteDate > removedAt
    }

    /// Whether an unforced sync may apply this many removals, see `largestQuietRemoval`.
    private static func isPlausible(removals: Int, knownCount: Int, force: Bool) -> Bool {
        force || removals <= max(largestQuietRemoval, knownCount / 2)
    }

    private func mergeSaved(watchlist: [TraktSavedItem], collection: [TraktSavedItem], force: Bool, sendingLocalOnly: Bool,
                            into summary: inout Summary) async {
        let local = await library.all()
        var here = Set(local.map(\.id))
        let waiting = Set(state.operations.filter { $0.slot == .saved }.map(\.identity))
        let listed = Set(watchlist.map(\.identity))
        let owned = Set(collection.map(\.identity))

        // Titles Trakt has and this device does not.
        var additions: [LibraryItem] = []
        for item in watchlist where !waiting.contains(item.identity) {
            if here.contains(item.identity) {
                state.collected.remove(item.identity)
            } else if Self.revives(item.addedAt, removedAt: state.removedSaved[item.identity]) {
                additions.append(LibraryItem(preview: item.preview, addedAt: item.addedAt ?? now()))
                here.insert(item.identity)
                state.removedSaved[item.identity] = nil
                state.collected.remove(item.identity)
            }
        }
        for item in collection where !listed.contains(item.identity) && !waiting.contains(item.identity) && !here.contains(item.identity) {
            guard Self.revives(item.addedAt, removedAt: state.removedSaved[item.identity]) else { continue }
            additions.append(LibraryItem(preview: item.preview, addedAt: item.addedAt ?? now()))
            here.insert(item.identity)
            state.removedSaved[item.identity] = nil
            state.collected.insert(item.identity)
        }
        await library.add(additions)
        summary.savedAdded += additions.count

        // Titles this device has and Trakt's watchlist does not.
        var removals: [String] = []
        for item in local where !listed.contains(item.id) && !waiting.contains(item.id) {
            if state.syncedSaved.contains(item.id) {
                // It was on the watchlist when Trakt was last read: it was removed somewhere else. The collection may still hold it.
                if owned.contains(item.id) { state.collected.insert(item.id) } else { removals.append(item.id) }
            } else if owned.contains(item.id) {
                // Here because the collection holds it. It is not sent to the watchlist.
                state.collected.insert(item.id)
            } else if state.collected.contains(item.id) {
                removals.append(item.id)
            } else if sendingLocalOnly, let operation = TraktSyncOperation(kind: .save, identity: item.id, at: item.addedAt) {
                enqueue(operation)
            }
        }
        if Self.isPlausible(removals: removals.count, knownCount: state.syncedSaved.count + state.collected.count, force: force) {
            for id in removals { await library.remove(id) }
            summary.savedRemoved += removals.count
            state.syncedSaved = listed
            state.collected = state.collected.intersection(owned).subtracting(listed)
        } else {
            // Not believed this time: nothing is removed, and what Trakt held before is still remembered for the next read.
            state.syncedSaved.formUnion(listed)
        }
    }

    private func mergeWatched(_ remote: [TraktWatchedItem], force: Bool, sendingLocalOnly: Bool, into summary: inout Summary) async {
        let waiting = Set(state.operations.filter { $0.slot == .watched }.map(\.identity))
        let watchedOnTrakt = Set(remote.map(\.identity))
        let existing = await progress.progress(for: remote.map(\.identity))
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Watches Trakt has and this device does not.
        var updates: [WatchProgress] = []
        for item in remote where !waiting.contains(item.identity) {
            let current = byID[item.identity]
            guard current?.isWatched != true else { continue }
            if let cleared = state.unwatched[item.identity], cleared >= item.watchedAt { continue }
            let record = WatchProgress(id: item.identity, type: item.preview.type, contentID: item.contentID,
                title: current?.title ?? item.preview.name, poster: current?.poster ?? item.preview.poster,
                position: current?.position ?? 0, duration: current?.duration ?? 0, isWatched: true,
                updatedAt: max(current?.updatedAt ?? .distantPast, item.watchedAt), season: item.season, episode: item.episode)
            updates.append(record)
            byID[item.identity] = record
            state.unwatched[item.identity] = nil
        }
        await progress.save(updates)
        summary.watchedAdded += updates.count

        // Marks this device has and Trakt does not.
        var cleared: [String] = []
        for record in await progress.all() where record.isWatched && !watchedOnTrakt.contains(record.id) && !waiting.contains(record.id) {
            if state.syncedWatched.contains(record.id) {
                // Trakt had it when it was last read: the mark was cleared somewhere else.
                cleared.append(record.id)
            } else if sendingLocalOnly, let operation = TraktSyncOperation(kind: .watched, identity: record.id, at: record.updatedAt) {
                enqueue(operation)
            }
        }
        if Self.isPlausible(removals: cleared.count, knownCount: state.syncedWatched.count, force: force) {
            await progress.remove(cleared)
            summary.watchedRemoved += cleared.count
            state.syncedWatched = watchedOnTrakt
        } else {
            state.syncedWatched.formUnion(watchedOnTrakt)
        }
    }

    // MARK: Sending

    /// Sends every operation that is due, one kind at a time. True when Trakt took at least one. Stops at the first failure that is
    /// worth trying again, leaving the rest queued.
    private func send(into summary: inout Summary) async throws -> Bool {
        let date = now()
        let due = state.operations.filter { $0.notBefore <= date }
        guard !due.isEmpty else { return false }
        var sent = false

        let saves = due.filter { $0.kind == .save }
        if let count = try await deliver(saves, { try await self.account.addToWatchlist(saves.map(\.preview)) }) {
            summary.savedSent += count
            sent = true
        }
        let unsaves = due.filter { $0.kind == .unsave }
        if let count = try await deliver(unsaves, { try await self.account.removeFromWatchlist(unsaves.map(\.preview)) }) {
            summary.savedSent += count
            state.syncedSaved.subtract(unsaves.map(\.identity))
            sent = true
        }
        // A watch Trakt already has is not sent again: each one sent counts as another play.
        let watches = due.filter { $0.kind == .watched }
        let fresh = watches.filter { !state.syncedWatched.contains($0.identity) }
        finish(watches.filter { state.syncedWatched.contains($0.identity) })
        if let count = try await deliver(fresh, { try await self.account.addToHistory(fresh.map(\.watchedItem)) }) {
            summary.watchedSent += count
            sent = true
        }
        let unwatches = due.filter { $0.kind == .unwatched }
        if let count = try await deliver(unwatches, { try await self.account.removeFromHistory(unwatches.map(\.watchedItem)) }) {
            summary.watchedSent += count
            state.syncedWatched.subtract(unwatches.map(\.identity))
            sent = true
        }
        for operation in due where operation.kind == .progress {
            let delivered = try await deliver([operation]) {
                try await self.account.savePlayback(operation.watchedItem, progress: operation.progress ?? 0)
                return 1
            }
            if delivered != nil { sent = true }
        }
        let removals = due.filter { $0.kind == .removePlayback }
        let cleared = try await deliver(removals) {
            // Trakt removes a paused record by its own id, which only its list gives.
            var count = 0
            for item in try await self.account.playback() {
                guard let id = item.playbackID, let removal = removals.first(where: { $0.identity == item.id }),
                      item.pausedAt <= removal.at.addingTimeInterval(Self.clockSlack) else { continue }
                try await self.account.removePlayback(id: id)
                count += 1
            }
            return count
        }
        if cleared != nil { sent = true }
        return sent
    }

    /// Sends one batch and takes its operations off the queue. Returns what the request returned, or nil when there was nothing to
    /// send or Trakt refused it for good (the batch is then dropped: sending it again would be refused again). A failure worth another
    /// try marks the batch as possibly received and is thrown, as is anything that needs a new sign-in.
    private func deliver(_ operations: [TraktSyncOperation], _ request: () async throws -> Int) async throws -> Int? {
        guard !operations.isEmpty else { return nil }
        // Counted before the request leaves: from here on Trakt may have it, so a change that undoes one of these while the request is
        // out is queued and sent rather than cancelled against it (see `enqueue`).
        countAttempt(operations, by: 1)
        await persist()
        do {
            let count = try await request()
            finish(operations)
            await persist()
            return count
        } catch let error as TraktAccountError where Self.needsSignIn(error) {
            // Refused before anything was done: Trakt has certainly not seen these.
            countAttempt(operations, by: -1)
            await persist()
            throw error
        } catch let error as TraktAccountError where !error.isTransient {
            finish(operations)
            await persist()
            return nil
        }
    }

    private func countAttempt(_ operations: [TraktSyncOperation], by change: Int) {
        for index in state.operations.indices where operations.contains(where: { Self.isSame($0, state.operations[index]) }) {
            state.operations[index].attempts = max(0, state.operations[index].attempts + change)
        }
    }

    /// Takes sent operations off the queue. A change made to the same title while the request was out is a different operation and stays.
    private func finish(_ operations: [TraktSyncOperation]) {
        guard !operations.isEmpty else { return }
        state.operations.removeAll { waiting in operations.contains { Self.isSame($0, waiting) } }
    }

    private static func isSame(_ one: TraktSyncOperation, _ other: TraktSyncOperation) -> Bool {
        one.id == other.id && one.kind == other.kind && one.at == other.at && one.progress == other.progress
    }

    // MARK: - Running by itself

    /// Sends the queue when it is next due: after the short wait that gathers a burst of changes, or after the pause a failure set.
    /// `refreshing` asks for one more sync although nothing is waiting.
    private func schedule(refreshing: Bool = false) {
        guard schedulesItself else { return }
        scheduled?.cancel()
        scheduled = nil
        guard pausedUntil != .distantFuture else { return }
        guard let next = state.operations.map(\.notBefore).min() ?? (refreshing ? now() : nil) else { return }
        let delay = max(Self.batchDelay, max(next, pausedUntil).timeIntervalSince(now()))
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            _ = try? await self?.sync()
        }
    }

    /// The app came to the front, or the network came back: whatever waited on either is tried now.
    public func resume() async {
        if pausedUntil != .distantFuture { pausedUntil = .distantPast }
        _ = try? await sync()
    }

    /// A fresh sign-in: any pause is over, and everything is read.
    @discardableResult
    public func signedIn() async throws -> Summary {
        pausedUntil = .distantPast
        failures = 0
        return try await sync(force: true)
    }

    /// Signed out: the queue and what was known of Trakt's lists and collection go, so nothing is sent to, or removed because of,
    /// another account. The deletions recorded here stay, so signing in again does not bring removed titles back.
    public func signedOut() async {
        await load()
        scheduled?.cancel()
        scheduled = nil
        // A sync still running finishes first (its next request is refused), so it cannot write the old account's lists back afterwards.
        _ = await running?.result
        state.operations = []
        state.syncedSaved = []
        state.syncedWatched = []
        state.collected = []
        state.activities = nil
        state.lastFullPull = nil
        lastCheck = .distantPast
        pausedUntil = .distantPast
        failures = 0
        await persist()
    }

    /// Forgets everything, for a full data reset.
    public func reset() async {
        await signedOut()
        state = TraktSyncState()
        await persist()
    }

    #if canImport(Network)
    /// Starts sending the queue whenever the network comes back. The app calls this once at launch; the first report arrives at once,
    /// so it is also the launch sync.
    public func startMonitoringNetwork() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { await self?.resume() }
        }
        monitor.start(queue: DispatchQueue(label: "app.blusion.trakt-sync.network"))
        self.monitor = monitor
    }
    #endif

    // MARK: - State

    private func load() async {
        guard !isLoaded else { return }
        let stored = await store.load()
        // Another caller may have loaded while this one waited.
        guard !isLoaded else { return }
        state = stored
        self.stored = stored
        isLoaded = true
    }

    private func persist() async {
        guard state != stored else { return }
        stored = state
        await store.save(state)
    }
}
