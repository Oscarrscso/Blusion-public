import Foundation

/// Where the Home layout shared between the user's devices is kept. Both calls block, so they run off the main thread.
public protocol SharedLayoutCopy: Sendable {
    /// The shared copy, or nil when there is none yet. Throws when it cannot be reached, for example when no folder is chosen.
    func read() throws -> Data?
    func write(_ data: Data) throws
}

/// The Home layout, shared with the user's other devices through `shared`. This device keeps its own copy in a `DefaultsWidgetStore`
/// and always works from it, so Home never waits for the shared copy. The last layout saved on any device wins.
///
/// Every write of the shared copy gives it a new stamp. The stamp this device last wrote or took in is kept beside its layout, so
/// another stamp means another device saved since. A device without a stamp yet takes in the shared layout; when there is none, a
/// device with its own layout starts it. A device on the automatic layout never starts it, so it cannot reset another's layout.
public final class SyncedWidgetStore: WidgetStore, @unchecked Sendable {
    /// The key, in this device's defaults, of the stamp of the shared layout this device last wrote or took in.
    public static let stampKey = "home.widgets.sharedStamp"

    private struct Shared: Codable {
        var stamp: String
        /// The layout as `DefaultsWidgetStore` stores it, as JSON text; nil is the automatic layout.
        var layout: String?

        var layoutData: Data? { layout.map { Data($0.utf8) } }
    }

    private let local: DefaultsWidgetStore
    private let defaults: UserDefaults
    private let shared: any SharedLayoutCopy
    /// Reads and writes of the shared copy, one at a time and in order.
    private let queue = DispatchQueue(label: "app.blusion.sharedHomeLayout", qos: .utility)

    public init(defaults: UserDefaults = .standard, shared: any SharedLayoutCopy) {
        local = DefaultsWidgetStore(defaults: defaults)
        self.defaults = defaults
        self.shared = shared
    }

    public func load() async -> [HomeWidget]? {
        await local.load()
    }

    public func save(_ widgets: [HomeWidget]?) async {
        await local.save(widgets)
        queue.async { self.share() }
    }

    public func takeInSharedLayout() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.takeIn()) }
        }
    }

    private func takeIn() -> Bool {
        let copy: Shared?
        do { copy = try readShared() } catch { return false }
        guard let copy else {
            if local.storedData != nil { share() }
            return false
        }
        guard copy.stamp != defaults.string(forKey: Self.stampKey) else { return false }
        defaults.set(copy.stamp, forKey: Self.stampKey)
        let theirs = copy.layoutData
        guard theirs != local.storedData else { return false }
        local.replaceStoredData(theirs)
        return true
    }

    /// Writes this device's layout to the shared copy with a new stamp, unless the shared copy holds it already.
    private func share() {
        let mine = local.storedData
        let current: Shared?
        do { current = try readShared() } catch { return }
        if let current, current.layoutData == mine {
            defaults.set(current.stamp, forKey: Self.stampKey)
            return
        }
        var layout: String?
        if let mine {
            guard let text = String(data: mine, encoding: .utf8) else { return }
            layout = text
        }
        let next = Shared(stamp: UUID().uuidString, layout: layout)
        guard let data = try? JSONEncoder().encode(next) else { return }
        do { try shared.write(data) } catch { return }
        defaults.set(next.stamp, forKey: Self.stampKey)
    }

    /// The shared copy, or nil when there is none. One this build cannot read counts as none, so the next save replaces it.
    private func readShared() throws -> Shared? {
        guard let data = try shared.read() else { return nil }
        return try? JSONDecoder().decode(Shared.self, from: data)
    }
}

/// The folder the user chose to share the Home layout through, such as one in iCloud Drive, so their other devices read the same file.
/// The choice is kept as a bookmark in this device's defaults. With no folder chosen, nothing is shared.
public final class SharedFolder: SharedLayoutCopy, @unchecked Sendable {
    public static let bookmarkKey = "sync.folderBookmark"
    static let fileName = "Blusion Home.json"

    public enum Failure: Error {
        case noFolder
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The chosen folder's name as the Files app shows it, or nil when none is chosen or it is gone.
    public var folderName: String? {
        try? withFolder { FileManager.default.displayName(atPath: $0.path) }
    }

    /// Shares through `url`, a folder from the system's folder picker, from now on. The new folder is met as a first time.
    public func choose(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: SyncedWidgetStore.stampKey)
    }

    /// Stops sharing. The layout here stays as it is.
    public func forget() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: SyncedWidgetStore.stampKey)
    }

    public func read() throws -> Data? {
        try withFolder { (folder: URL) -> Data? in
            var result: Result<Data?, Error> = .success(nil)
            var coordinationError: NSError?
            // A coordinated read also fetches a copy iCloud Drive has not downloaded to this device yet.
            NSFileCoordinator().coordinate(readingItemAt: folder.appendingPathComponent(Self.fileName), options: [],
                                           error: &coordinationError) { url in
                do {
                    result = .success(try Data(contentsOf: url))
                } catch {
                    result = Self.isMissingFile(error) ? .success(nil) : .failure(error)
                }
            }
            if let coordinationError {
                guard Self.isMissingFile(coordinationError) else { throw coordinationError }
                return nil
            }
            return try result.get()
        }
    }

    public func write(_ data: Data) throws {
        try withFolder { (folder: URL) -> Void in
            var writeError: Error?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: folder.appendingPathComponent(Self.fileName), options: .forReplacing,
                                           error: &coordinationError) { url in
                do { try data.write(to: url, options: .atomic) } catch { writeError = error }
            }
            if let coordinationError { throw coordinationError }
            if let writeError { throw writeError }
        }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && [CocoaError.Code.fileNoSuchFile.rawValue, CocoaError.Code.fileReadNoSuchFile.rawValue].contains(error.code)
    }

    /// Runs `body` with the chosen folder open to this app, renewing a bookmark the system says is stale.
    private func withFolder<T>(_ body: (URL) throws -> T) throws -> T {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else { throw Failure.noFolder }
        var isStale = false
        let folder = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        if isStale, let fresh = try? folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: Self.bookmarkKey)
        }
        return try body(folder)
    }
}
