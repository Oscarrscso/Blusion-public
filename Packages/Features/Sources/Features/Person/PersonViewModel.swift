import Foundation
import Observation
import StremioKit

/// A person's page, opened from a cast or crew card. The card's name and photo show until the page has loaded.
public struct PersonDestination: Hashable, Sendable {
    public let id: Int
    public let name: String
    public let profile: URL?

    public init(id: Int, name: String, profile: URL?) {
        self.id = id
        self.name = name
        self.profile = profile
    }
}

/// A movie or series opened from a TMDb credit. TMDb's credits carry no IMDb id, so the title's page looks it up when it opens.
public struct TMDbTitleDestination: Hashable, Sendable {
    public let tmdbID: Int
    /// "movie" or "tv".
    public let mediaType: String
    public let name: String
    public let poster: URL?
    public let backdrop: URL?
    public let year: Int?
}

/// The media filter of a filmography: everything, movies only, or series only.
public enum PersonMediaFilter: String, CaseIterable, Identifiable, Sendable {
    case all, movies, tv

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All"
        case .movies: "Movies"
        case .tv: "TV Shows"
        }
    }

    public func matches(_ credit: TMDbPersonCredit) -> Bool {
        switch self {
        case .all: true
        case .movies: credit.isMovie
        case .tv: !credit.isMovie
        }
    }
}

/// The credits published in one release year, or in no year when TMDb has no date for them (`year` nil).
public struct CreditYearSection: Identifiable, Equatable, Sendable {
    public let year: Int?
    public let credits: [TMDbPersonCredit]

    public var id: String { year.map(String.init) ?? "unknown" }
}

extension CreditCategory {
    /// The name of the role in the filter menu and on a credit.
    public var title: String {
        switch self {
        case .acting: "Acting"
        case .directing: "Directing"
        case .writing: "Writing"
        case .production: "Production"
        case .other: "Other"
        }
    }
}

extension TMDbPersonCredit {
    /// What the person did on the title, once per distinct job: "Director · Writer", "as Leonard · Director".
    public var roleText: String {
        var parts: [String] = []
        for role in roles {
            switch role {
            case .acting(let character): parts.append(character.map { "as \($0)" } ?? "Actor")
            case .crew(let job, _): parts.append(job)
            }
        }
        var seen: Set<String> = []
        return parts.filter { seen.insert($0).inserted }.joined(separator: " · ")
    }

    /// The card a Known For shelf or a credit opens the title with.
    public var titleDestination: TMDbTitleDestination {
        TMDbTitleDestination(tmdbID: tmdbID, mediaType: mediaType, name: title, poster: poster, backdrop: backdrop, year: year)
    }

    /// The title as the shared media cards draw it. Its id names the title by TMDb id, since no IMDb id is known yet.
    public var preview: MetaPreview {
        MetaPreview(id: "tmdb:\(mediaType):\(tmdbID)", type: isMovie ? "movie" : "series", name: title.isEmpty ? "Untitled" : title,
                    poster: poster, background: backdrop, releaseInfo: year.map(String.init))
    }
}

/// A person's page: who they are, what they are known for, and every movie and series they are credited on.
@MainActor
@Observable
public final class PersonViewModel {
    /// How many credits are laid out at a time. The next page is added as the list scrolls to its end.
    public static let pageSize = 60

    public let destination: PersonDestination
    public private(set) var person: TMDbPerson?
    /// Every credit, merged by title and in TMDb's order. Filters and sorting work on this list.
    public internal(set) var credits: [TMDbPersonCredit] = []
    /// Profile photos, best voted first.
    public private(set) var photos: [URL] = []
    /// The artwork TMDb has for each Known For title, keyed by credit id. A card shows its plain backdrop until its title's artwork arrives.
    public private(set) var knownForArtwork: [String: TMDbArtwork] = [:]
    public private(set) var isLoading = true
    /// Set when the page cannot show anything: no TMDb token, or TMDb refused both requests.
    public private(set) var unavailableReason: String?
    public private(set) var visibleCount = PersonViewModel.pageSize

    public var mediaFilter: PersonMediaFilter = .all {
        didSet {
            guard oldValue != mediaFilter else { return }
            // A role the new kind of title does not have is dropped, so the page never shows a filter that matches nothing.
            if let roleFilter, !availableRoles.contains(roleFilter) { self.roleFilter = nil }
            visibleCount = Self.pageSize
        }
    }

    /// The role to show, or nil for every role.
    public var roleFilter: CreditCategory? {
        didSet { if oldValue != roleFilter { visibleCount = Self.pageSize } }
    }

    private let services: AppServices
    private let today: @Sendable () -> Date

    public init(destination: PersonDestination, services: AppServices, today: @escaping @Sendable () -> Date = { Date() }) {
        self.destination = destination
        self.services = services
        self.today = today
    }

    public func load() async {
        isLoading = true
        let settings = await services.settings.load()
        guard let token = settings.tmdbReadToken, !token.isEmpty else {
            unavailableReason = "Add a TMDb read token in Settings to see this person's photo and credits."
            isLoading = false
            return
        }
        let tmdb = TMDbRatings(client: services.client, readAccessToken: token)
        let id = destination.id
        // The page and the filmography are separate requests, so one failing still shows the other.
        async let details = try? await tmdb.person(id: id)
        async let filmography = try? await tmdb.personCredits(id: id)
        async let profilePhotos = try? await tmdb.personPhotos(id: id)
        person = await details
        let loaded = await filmography
        credits = loaded ?? []
        photos = await profilePhotos ?? []
        unavailableReason = person == nil && loaded == nil ? "TMDb could not load this person." : nil
        isLoading = false
        // The page is up; the Known For cards take their artwork as it arrives. The view's task cancels this when the view goes away.
        await loadKnownForArtwork(using: tmdb)
    }

    /// Fetches the artwork of the Known For titles, four at a time, and fills `knownForArtwork` as each answers. A failed lookup is
    /// ignored, so its card keeps the plain backdrop.
    func loadKnownForArtwork(using tmdb: TMDbRatings) async {
        let limit = 4
        await withTaskGroup(of: (id: String, artwork: TMDbArtwork?).self) { group in
            var pending = knownFor.makeIterator()
            for _ in 0..<limit {
                guard let credit = pending.next() else { break }
                group.addTask { await Self.artwork(for: credit, using: tmdb) }
            }
            for await result in group {
                if let artwork = result.artwork { knownForArtwork[result.id] = artwork }
                if !Task.isCancelled, let credit = pending.next() {
                    group.addTask { await Self.artwork(for: credit, using: tmdb) }
                }
            }
        }
    }

    private nonisolated static func artwork(for credit: TMDbPersonCredit, using tmdb: TMDbRatings) async -> (id: String, artwork: TMDbArtwork?) {
        (credit.id, try? await tmdb.artwork(tmdbID: credit.tmdbID, mediaType: credit.mediaType))
    }

    /// Credits to show, from the credits the page has loaded so far. A title sits in the list once, even when it has several roles.
    public var hasMoreCredits: Bool { filteredCredits.count > visibleCount }

    public func loadMore() {
        guard hasMoreCredits else { return }
        visibleCount += Self.pageSize
    }

    /// The credits that pass both filters, newest first.
    public var filteredCredits: [TMDbPersonCredit] {
        credits
            .filter { credit in mediaFilter.matches(credit) && (roleFilter.map { credit.categories.contains($0) } ?? true) }
            .sorted(by: Self.isNewer)
    }

    /// The photos the page shows as a strip: TMDb's profile photos, or the photo the card already had when TMDb has none.
    public var photoStrip: [URL] {
        photos.isEmpty ? [destination.profile].compactMap { $0 } : photos
    }

    /// The roles this person has an entry for, among the titles the media filter lets through, in the menu's order. The role menu
    /// offers only these.
    public var availableRoles: [CreditCategory] {
        let titles = credits.filter { mediaFilter.matches($0) }
        return CreditCategory.allCases.filter { category in titles.contains { $0.categories.contains(category) } }
    }

    /// The filtered credits shown so far, grouped by release year, newest year first. Undated titles come last.
    public var sections: [CreditYearSection] {
        let shown = filteredCredits.prefix(visibleCount)
        let grouped = Dictionary(grouping: shown, by: \.year)
        return grouped.keys
            .sorted { ($0 ?? Int.min) > ($1 ?? Int.min) }
            .map { CreditYearSection(year: $0, credits: grouped[$0] ?? []) }
    }

    /// Titles to show as Known For: the well-rated ones with artwork, ranked by how many people have rated them. Vote count is the
    /// lasting measure of how well known a title is. TMDb's `popularity` is a trending score that a recent show can top for weeks
    /// while a classic sits lower, so it only breaks ties. When too few titles qualify, every title with a backdrop is considered.
    public var knownFor: [TMDbPersonCredit] {
        let withBackdrop = credits.filter { $0.backdrop != nil }
        let wellRated = withBackdrop.filter { $0.voteCount >= 20 && ($0.voteAverage ?? 0) >= 6.5 }
        let pool = wellRated.count >= 3 ? wellRated : withBackdrop
        return Array(pool.sorted(by: Self.isMoreKnown).prefix(12))
    }

    /// True for a title whose release date is later than today. Such a title has no rating yet.
    public func isUnreleased(_ credit: TMDbPersonCredit) -> Bool {
        guard let releaseDate = credit.releaseDate else { return false }
        return releaseDate > Self.isoDay(today())
    }

    /// Newest first: release year (undated last), then release date, then title.
    static func isNewer(_ lhs: TMDbPersonCredit, _ rhs: TMDbPersonCredit) -> Bool {
        if lhs.year != rhs.year { return (lhs.year ?? Int.min) > (rhs.year ?? Int.min) }
        if lhs.releaseDate != rhs.releaseDate { return (lhs.releaseDate ?? "") > (rhs.releaseDate ?? "") }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    /// Most voted first, then most popular, then title. Vote count is the lasting measure; popularity only breaks ties.
    static func isMoreKnown(_ lhs: TMDbPersonCredit, _ rhs: TMDbPersonCredit) -> Bool {
        if lhs.voteCount != rhs.voteCount { return lhs.voteCount > rhs.voteCount }
        if lhs.popularity != rhs.popularity { return lhs.popularity > rhs.popularity }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    /// "2026-10-09" in the device's calendar, the form TMDb uses for release dates, so the two compare as text.
    static func isoDay(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
