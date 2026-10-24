import Foundation

/// Keeps the recent searches. Synchronous on purpose: the Search screen reads them while it is built, before any await.
public protocol SearchHistoryStore: Sendable {
    func load() -> [String]
    func save(_ queries: [String])
}

/// Recent searches for the life of the store: the default when a screen gives none, and what tests use.
public final class InMemorySearchHistoryStore: SearchHistoryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String]

    public init(_ queries: [String] = []) {
        self.queries = queries
    }

    public func load() -> [String] {
        lock.withLock { queries }
    }

    public func save(_ queries: [String]) {
        lock.withLock { self.queries = queries }
    }
}

/// Recent searches in `UserDefaults`, so they survive a relaunch. A list of search words is not a secret, so it is not in the Keychain.
public final class DefaultsSearchHistoryStore: SearchHistoryStore, @unchecked Sendable {
    public static let key = "search.recentQueries"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    public func save(_ queries: [String]) {
        defaults.set(queries, forKey: Self.key)
    }
}
