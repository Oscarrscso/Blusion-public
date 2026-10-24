import Foundation

/// How a Trakt list widget orders its items. A widget without a sort keeps the list's own order ("List Default").
public enum TraktListSort: String, Sendable, Codable, CaseIterable, Hashable, Identifiable {
    case customRank, dateAdded, title, releaseDate, runtime, popularity, rating, votes

    public var id: String { rawValue }

    /// The pill label.
    public var title: String {
        switch self {
        case .customRank: return "Custom Rank"
        case .dateAdded: return "Date Added"
        case .title: return "Title"
        case .releaseDate: return "Release Date"
        case .runtime: return "Runtime"
        case .popularity: return "Popularity"
        case .rating: return "Rating"
        case .votes: return "Votes"
        }
    }

    /// Trakt's `sort_by` and `sort_how` path segments: `…/items/movie,show/<by>/<how>`.
    var apiValue: (by: String, how: String) {
        switch self {
        case .customRank: return ("rank", "asc")
        case .dateAdded: return ("added", "desc")
        case .title: return ("title", "asc")
        case .releaseDate: return ("released", "desc")
        case .runtime: return ("runtime", "desc")
        case .popularity: return ("popularity", "desc")
        case .rating: return ("percentage", "desc")
        case .votes: return ("votes", "desc")
        }
    }
}

/// Public list rankings Trakt offers without a sign-in.
public enum TraktListFeed: String, Sendable, CaseIterable, Hashable {
    case popular, trending

    var path: String { "lists/\(rawValue)" }
}

/// One page of a browse result, with how many pages Trakt says there are (`X-Pagination-Page-Count`).
public struct TraktPage<Item: Sendable & Equatable>: Sendable, Equatable {
    public var items: [Item]
    public var page: Int
    public var pageCount: Int

    public init(items: [Item], page: Int, pageCount: Int) {
        self.items = items
        self.page = page
        self.pageCount = pageCount
    }

    public var hasMore: Bool { page < pageCount }
}

/// A Trakt list as the browser shows it: who made it, how big it is and how liked.
public struct TraktListSummary: Sendable, Equatable, Hashable, Identifiable {
    public let traktID: Int
    public let slug: String
    public let name: String
    public let description: String
    /// The owner's slug, which the API takes in `users/<username>/lists/<slug>`.
    public let username: String
    public let itemCount: Int
    public let likes: Int
    public let isPrivate: Bool

    public init(traktID: Int, slug: String, name: String, description: String = "", username: String, itemCount: Int = 0, likes: Int = 0,
                isPrivate: Bool = false) {
        self.traktID = traktID
        self.slug = slug
        self.name = name
        self.description = description
        self.username = username
        self.itemCount = itemCount
        self.likes = likes
        self.isPrivate = isPrivate
    }

    public var id: Int { traktID }

    /// What a widget stores for this list. `sort` stays nil so the list keeps its own order unless the user picks one.
    public func reference(sort: TraktListSort? = nil) -> TraktListReference {
        TraktListReference(username: username, listSlug: slug, listName: name, traktID: traktID, sort: sort, isPrivate: isPrivate ? true : nil)
    }
}

/// A Trakt user from a search.
public struct TraktUserSummary: Sendable, Equatable, Hashable, Identifiable {
    public let username: String
    public let displayName: String?
    public let isVIP: Bool

    public init(username: String, displayName: String? = nil, isVIP: Bool = false) {
        self.username = username
        self.displayName = displayName
        self.isVIP = isVIP
    }

    public var id: String { username }
}

/// Browse responses kept for a few minutes, by request. Search, paging back and re-opening the browser then cost no request.
public actor TraktBrowseCache {
    private struct Entry {
        let result: HTTPResult
        let expiresAt: Date
    }

    private let ttl: TimeInterval
    private let capacity: Int
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]

    public init(ttl: TimeInterval = 300, capacity: Int = 120, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.capacity = capacity
        self.now = now
    }

    func value(for key: String) -> HTTPResult? {
        guard let entry = entries[key] else { return nil }
        guard entry.expiresAt > now() else {
            entries[key] = nil
            return nil
        }
        return entry.result
    }

    func store(_ result: HTTPResult, for key: String) {
        guard (200...299).contains(result.response.statusCode), ttl > 0 else { return }
        entries[key] = Entry(result: result, expiresAt: now().addingTimeInterval(ttl))
        guard entries.count > capacity else { return }
        for (evicted, _) in entries.filter({ $0.key != key }).sorted(by: { $0.value.expiresAt < $1.value.expiresAt }).prefix(entries.count - capacity) {
            entries[evicted] = nil
        }
    }

    /// Forgets every saved response, for a pull to refresh or a sign-out.
    public func removeAll() {
        entries = [:]
    }
}

// MARK: Decoding

/// A list inside `{"list": {…}}` (popular, trending, search, likes) or bare (a user's lists). One that cannot be read becomes nil.
struct LossyListEntry: Decodable {
    let list: TraktListSummary?

    private enum Keys: String, CodingKey { case list, likeCount = "like_count" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let outerLikes = container.int(.likeCount)
        if let wrapped: ListDTO = container.object(.list) {
            list = wrapped.summary(fallbackLikes: outerLikes)
        } else {
            list = (try? ListDTO(from: decoder))?.summary(fallbackLikes: outerLikes)
        }
    }
}

/// A user inside `{"type": "user", "user": {…}}`.
struct LossyUserEntry: Decodable {
    let user: TraktUserSummary?

    private enum Keys: String, CodingKey { case user }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        user = (container.object(.user) as UserDTO?)?.summary
    }
}

private struct ListDTO: Decodable {
    let name: String?
    let description: String?
    let privacy: String?
    let itemCount: Int?
    let likes: Int?
    let traktID: Int?
    let slug: String?
    let user: UserDTO?

    private enum Keys: String, CodingKey { case name, description, privacy, itemCount = "item_count", likes, ids, user }
    private enum IDKeys: String, CodingKey { case trakt, slug }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        name = container.string(.name)
        description = container.string(.description)
        privacy = container.string(.privacy)
        itemCount = container.int(.itemCount)
        likes = container.int(.likes)
        if container.contains(.ids), let ids = try? container.nestedContainer(keyedBy: IDKeys.self, forKey: .ids) {
            traktID = ids.int(.trakt)
            slug = ids.string(.slug)
        } else {
            traktID = nil
            slug = nil
        }
        user = container.object(.user)
    }

    func summary(fallbackLikes: Int?) -> TraktListSummary? {
        guard let traktID, let slug, !slug.isEmpty, let name, !name.isEmpty else { return nil }
        return TraktListSummary(traktID: traktID, slug: slug, name: name, description: description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                                username: user?.slug ?? "me", itemCount: itemCount ?? 0, likes: likes ?? fallbackLikes ?? 0,
                                isPrivate: privacy.map { $0 != "public" } ?? false)
    }
}

private struct UserDTO: Decodable {
    let username: String?
    let name: String?
    let slug: String?
    let vip: Bool

    private enum Keys: String, CodingKey { case username, name, ids, vip }
    private enum IDKeys: String, CodingKey { case slug }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        username = container.string(.username)
        name = container.string(.name)
        vip = container.bool(.vip)
        if container.contains(.ids), let ids = try? container.nestedContainer(keyedBy: IDKeys.self, forKey: .ids) {
            slug = ids.string(.slug) ?? username
        } else {
            slug = username
        }
    }

    var summary: TraktUserSummary? {
        guard let slug, !slug.isEmpty else { return nil }
        let display = name.flatMap { $0.isEmpty || $0 == username ? nil : $0 }
        return TraktUserSummary(username: slug, displayName: display, isVIP: vip)
    }
}
