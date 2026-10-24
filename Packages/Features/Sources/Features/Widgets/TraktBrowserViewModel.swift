import Foundation
import Observation
import StremioKit

/// The Trakt list browser of the New Widget screen: popular, trending, searched, own and liked lists, and users with their lists.
/// Pages load 20 at a time; the client keeps what it loaded for a few minutes, so switching tabs and searching again is cheap.
@MainActor
@Observable
public final class TraktBrowserViewModel {
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case lists = "Lists", users = "Users"
        public var id: String { rawValue }
    }

    /// Which lists the Lists tab shows while the search field is empty.
    public enum ListScope: String, CaseIterable, Identifiable, Sendable {
        case popular = "Popular", trending = "Trending", mine = "My Lists", liked = "Liked Lists"
        public var id: String { rawValue }

        /// True when Trakt only answers a signed-in user.
        public var needsSignIn: Bool { self == .mine || self == .liked }
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case needsSignIn(String)
        case failed(String)
    }

    /// Everything that changes what is listed. The view reloads when it changes.
    public struct Request: Hashable, Sendable {
        public var tab: Tab
        public var scope: ListScope
        public var query: String
        public var user: String?
    }

    public var tab: Tab = .lists
    public var scope: ListScope = .popular
    public var query = ""
    /// The user whose lists are shown on the Users tab, once picked from a search.
    public private(set) var browsedUser: TraktUserSummary?
    public private(set) var lists: [TraktListSummary] = []
    public private(set) var users: [TraktUserSummary] = []
    public private(set) var phase: Phase = .idle
    public private(set) var isLoadingMore = false
    public private(set) var canLoadMore = false

    static let pageSize = 20

    private let services: AppServices
    private var generation = 0
    private var page = 1

    public init(services: AppServices) {
        self.services = services
    }

    public var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var request: Request {
        Request(tab: tab, scope: scope, query: trimmedQuery, user: browsedUser?.username)
    }

    /// Lists to show, or users to show. Used by the view to pick the right empty text.
    public var isEmpty: Bool {
        guard phase == .loaded else { return false }
        return showsUsers ? users.isEmpty : lists.isEmpty
    }

    /// True while the Users tab lists users rather than a user's lists.
    public var showsUsers: Bool { tab == .users && browsedUser == nil }

    /// What the empty state says.
    public var emptyMessage: String {
        if tab == .users && browsedUser == nil { return "No users found for “\(trimmedQuery)”." }
        if browsedUser != nil { return "This user has no public lists." }
        if !trimmedQuery.isEmpty { return "No lists found for “\(trimmedQuery)”." }
        switch scope {
        case .mine: return "You haven't made any Trakt lists yet."
        case .liked: return "You haven't liked any Trakt lists yet."
        case .popular, .trending: return "Trakt has no lists to show right now."
        }
    }

    /// Shows one user's public lists. The request changes, so the view reloads.
    public func browse(user: TraktUserSummary) {
        browsedUser = user
    }

    /// Goes back from a user's lists to the user search.
    public func leaveUser() {
        browsedUser = nil
    }

    /// Loads the first page for the current request. `refresh` asks Trakt again instead of using what was kept.
    public func load(refresh: Bool = false) async {
        generation += 1
        let current = generation
        page = 1
        canLoadMore = false
        isLoadingMore = false
        let request = self.request
        if request.tab == .users && request.user == nil && request.query.isEmpty {
            users = []
            phase = .idle
            return
        }
        phase = .loading
        do {
            let result = try await fetch(request, page: 1, refresh: refresh)
            guard current == generation else { return }
            lists = result.lists
            users = result.users
            canLoadMore = result.hasMore
            phase = .loaded
        } catch {
            guard current == generation else { return }
            if (error as? CancellationError) != nil || Task.isCancelled { return }
            lists = []
            users = []
            phase = Self.phase(for: error)
        }
    }

    /// Call when the last row scrolls into view.
    public func loadMore() async {
        guard canLoadMore, phase == .loaded, !isLoadingMore else { return }
        let current = generation
        let request = self.request
        isLoadingMore = true
        defer { if current == generation { isLoadingMore = false } }
        do {
            let result = try await fetch(request, page: page + 1, refresh: false)
            guard current == generation else { return }
            page += 1
            lists = Self.appending(result.lists, to: lists)
            users = Self.appending(result.users, to: users)
            canLoadMore = result.hasMore && !(result.lists.isEmpty && result.users.isEmpty)
        } catch {
            // Keeps what is there; scrolling to the end again tries the page once more.
        }
    }

    // MARK: Fetching

    private struct Loaded {
        var lists: [TraktListSummary] = []
        var users: [TraktUserSummary] = []
        var hasMore = false
    }

    private func fetch(_ request: Request, page: Int, refresh: Bool) async throws -> Loaded {
        let clientID = await TraktClient.clientID(in: services.settings)
        guard !clientID.isEmpty else { throw WidgetSourceError.needsTraktClientID }
        let trakt = services.trakt
        let limit = Self.pageSize
        switch request.tab {
        case .lists:
            let result: TraktPage<TraktListSummary>
            if !request.query.isEmpty {
                result = try await trakt.searchLists(query: request.query, clientID: clientID, page: page, limit: limit, refresh: refresh)
            } else {
                switch request.scope {
                case .popular: result = try await trakt.lists(.popular, clientID: clientID, page: page, limit: limit, refresh: refresh)
                case .trending: result = try await trakt.lists(.trending, clientID: clientID, page: page, limit: limit, refresh: refresh)
                case .mine: result = try await trakt.myLists(clientID: clientID, refresh: refresh)
                case .liked: result = try await trakt.likedLists(clientID: clientID, page: page, limit: limit, refresh: refresh)
                }
            }
            return Loaded(lists: result.items, hasMore: result.hasMore)
        case .users:
            if let user = request.user {
                let result = try await trakt.userLists(username: user, clientID: clientID, refresh: refresh)
                return Loaded(lists: result.items, hasMore: false)
            }
            let result = try await trakt.searchUsers(query: request.query, clientID: clientID, page: page, limit: limit, refresh: refresh)
            return Loaded(users: result.items, hasMore: result.hasMore)
        }
    }

    private static func appending<Item: Identifiable>(_ page: [Item], to list: [Item]) -> [Item] {
        var seen = Set(list.map(\.id))
        return list + page.filter { seen.insert($0.id).inserted }
    }

    /// One plain sentence for a failure, and whether it is a sign-in problem the screen can offer to fix.
    static func phase(for error: Error) -> Phase {
        if let source = error as? WidgetSourceError { return .failed(source.message) }
        if let account = error as? TraktAccountError {
            switch account {
            case .needsSignIn, .needsCredentials, .credentialsChanged:
                return .needsSignIn("Sign in to Trakt in Settings to use this.")
            case .network(.http(status: 401)), .network(.http(status: 403)):
                return .needsSignIn("Sign in to Trakt in Settings to use this.")
            default:
                return .failed(account.message)
            }
        }
        let short = AddonError.from(error).shortDescription.lowercased()
        return .failed("Trakt couldn't load this (\(short)).")
    }
}
