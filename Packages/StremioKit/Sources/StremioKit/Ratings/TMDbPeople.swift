import Foundation

// MARK: - Cast and crew of a movie or series

/// A cast or crew member of one title. `roles` is what they did on it: the characters an actor played, or the jobs of a crew
/// member ("Director", "Writer"). The same person is listed once, with every role.
public struct TMDbTitlePerson: Sendable, Equatable, Hashable, Identifiable {
    /// TMDb's person id; what a tap opens the person's page with.
    public let id: Int
    public let name: String
    public let roles: [String]
    public let isCast: Bool
    /// The headshot, 342 pt wide. Nil when TMDb has none.
    public let profile: URL?

    public init(id: Int, name: String, roles: [String], isCast: Bool, profile: URL?) {
        self.id = id
        self.name = name
        self.roles = roles
        self.isCast = isCast
        self.profile = profile
    }

    /// "Director · Writer", "Jon Snow · Lord Commander". Nil when TMDb gave no role.
    public var roleText: String? { roles.isEmpty ? nil : roles.joined(separator: " · ") }
}

/// The parts of a title's cast and crew its page can show, in the order of its menu: the cast, then TMDb's crew departments, each named
/// as TMDb names it. TMDb's Lighting crew, which has no part of its own, is under Crew.
public enum TitleCreditGroup: String, CaseIterable, Sendable, Hashable, Identifiable {
    case cast, directing, writing, production, art, camera, editing, sound, visualEffects, costumeAndMakeUp, crew

    public var id: String { rawValue }

    /// The name the menu and the section's heading show.
    public var title: String {
        switch self {
        case .cast: "Cast"
        case .directing: "Directing"
        case .writing: "Writing"
        case .production: "Production"
        case .art: "Art"
        case .camera: "Camera"
        case .editing: "Editing"
        case .sound: "Sound"
        case .visualEffects: "Visual Effects"
        case .costumeAndMakeUp: "Costume & Make-Up"
        case .crew: "Crew"
        }
    }

    /// The part of a crew member's TMDb department. A department with no part of its own, or none at all, is Crew.
    init(crewDepartment: String?) {
        let department = crewDepartment?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        self = Self.allCases.first { $0 != .cast && $0.title.lowercased() == department } ?? .crew
    }
}

/// The cast and crew of a title, as TMDb lists them: the cast in billing order, the crew by the part of the page they show in.
public struct TMDbTitleCredits: Sendable, Equatable {
    public let cast: [TMDbTitlePerson]
    /// Each part's crew, each person once with only their jobs in that part. Whoever holds one of `keyJobs` leads, by the most important
    /// one; everyone else keeps TMDb's order.
    public let crew: [TitleCreditGroup: [TMDbTitlePerson]]

    public init(cast: [TMDbTitlePerson], crew: [TitleCreditGroup: [TMDbTitlePerson]]) {
        self.cast = cast
        self.crew = crew
    }

    public static let empty = TMDbTitleCredits(cast: [], crew: [:])

    /// The jobs that lead their part of the crew, most important first.
    static let keyJobs = ["Director", "Creator", "Screenplay", "Writer", "Director of Photography", "Original Music Composer", "Editor", "Producer"]

    /// The people of one part: the cast, or one department's crew.
    public func people(in group: TitleCreditGroup) -> [TMDbTitlePerson] {
        group == .cast ? cast : crew[group] ?? []
    }

    /// The parts with anyone in them, in the menu's order.
    public var groups: [TitleCreditGroup] {
        TitleCreditGroup.allCases.filter { !people(in: $0).isEmpty }
    }

    /// The part shown when `picked` is asked for: that one, or the first part there is when nobody is in it. Nil when TMDb lists nobody.
    public func group(showing picked: TitleCreditGroup) -> TitleCreditGroup? {
        people(in: picked).isEmpty ? groups.first : picked
    }

    /// Parses a movie's `/credits` or a series' `/aggregate_credits`. The series answer keeps each person's roles in `roles` and
    /// `jobs`, the movie answer one role per entry; both are merged so a person who has several roles is listed once in each part.
    public static func parse(_ data: Data) throws -> TMDbTitleCredits {
        let response: RawCreditsResponse
        do { response = try JSONDecoder().decode(RawCreditsResponse.self, from: data) } catch { throw AddonError.invalidJSON }
        // TMDb lists a crew member once for each department they worked in, so each entry goes to its department's part.
        var departments: [TitleCreditGroup: [RawPerson]] = [:]
        for person in response.crew ?? [] {
            departments[TitleCreditGroup(crewDepartment: person.department), default: []].append(person)
        }
        return TMDbTitleCredits(cast: merge(response.cast ?? [], isCast: true),
                                crew: departments.mapValues { keyJobsFirst(merge($0, isCast: false)) })
    }

    /// Whoever holds one of `keyJobs` first, by the most important one each holds; everyone else after them, in TMDb's order.
    private static func keyJobsFirst(_ people: [TMDbTitlePerson]) -> [TMDbTitlePerson] {
        func rank(_ person: TMDbTitlePerson) -> Int {
            person.roles.compactMap { keyJobs.firstIndex(of: $0) }.min() ?? Int.max
        }
        return people.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    private static func merge(_ people: [RawPerson], isCast: Bool) -> [TMDbTitlePerson] {
        var order: [Int] = []
        var merged: [Int: TMDbTitlePerson] = [:]
        for person in people {
            let name = person.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { continue }
            let found = isCast
                ? [person.character] + (person.roles ?? []).map(\.character)
                : [person.job] + (person.jobs ?? []).map(\.job)
            let roles = found.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if let existing = merged[person.id] {
                let extra = roles.filter { !existing.roles.contains($0) }
                merged[person.id] = TMDbTitlePerson(id: existing.id, name: existing.name, roles: existing.roles + extra,
                                                    isCast: existing.isCast, profile: existing.profile)
            } else {
                order.append(person.id)
                merged[person.id] = TMDbTitlePerson(id: person.id, name: name, roles: uniqued(roles), isCast: isCast,
                                                    profile: TMDbImage.url(person.profilePath, size: "w342"))
            }
        }
        return order.compactMap { merged[$0] }
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

// MARK: - A person

/// A cast or crew member's own page: who they are and what they do.
public struct TMDbPerson: Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    /// The biography, trimmed. Nil when TMDb has none.
    public let biography: String?
    /// TMDb's department for the person: "Acting", "Directing", "Writing", "Production" and so on.
    public let department: String?
    /// A portrait, 632 pt tall. Nil when TMDb has none.
    public let profile: URL?

    public init(id: Int, name: String, biography: String?, department: String?, profile: URL?) {
        self.id = id
        self.name = name
        self.biography = biography
        self.department = department
        self.profile = profile
    }

    public static func parse(_ data: Data) throws -> TMDbPerson {
        let raw: RawPersonResponse
        do { raw = try JSONDecoder().decode(RawPersonResponse.self, from: data) } catch { throw AddonError.invalidJSON }
        let biography = raw.biography?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TMDbPerson(id: raw.id, name: raw.name ?? "", biography: biography?.isEmpty == false ? biography : nil,
                          department: raw.knownForDepartment?.isEmpty == false ? raw.knownForDepartment : nil,
                          profile: TMDbImage.url(raw.profilePath, size: "h632"))
    }
}

// MARK: - A person's filmography

/// What a person did on a movie or series. A title they worked on in several ways is one credit with every role.
public struct TMDbPersonCredit: Sendable, Equatable, Identifiable {
    /// "movie" or "tv".
    public let mediaType: String
    public let tmdbID: Int
    /// The title, or the series' name. Empty when TMDb has neither.
    public let title: String
    /// The release date as TMDb sends it ("2008-07-18"). Nil for titles without one.
    public let releaseDate: String?
    /// A 342 pt wide poster. Nil when TMDb has none.
    public let poster: URL?
    /// A 780 pt wide backdrop. Nil when TMDb has none.
    public let backdrop: URL?
    /// TMDb's average on a 0...10 scale. Nil while nobody has voted.
    public let voteAverage: Double?
    public let voteCount: Int
    public let popularity: Double
    public var roles: [TMDbCreditRole]
    /// The episodes a series credit covers, when TMDb counts them.
    public let episodeCount: Int?

    public var id: String { "\(mediaType)/\(tmdbID)" }
    public var isMovie: Bool { mediaType == "movie" }

    /// The release year. Nil when the date is missing or has no year in it.
    public var year: Int? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return Int(releaseDate.prefix(4))
    }

    /// The categories of every role, for the filters.
    public var categories: Set<CreditCategory> { Set(roles.map(\.category)) }

    public init(mediaType: String, tmdbID: Int, title: String, releaseDate: String?, poster: URL?, backdrop: URL?,
                voteAverage: Double?, voteCount: Int, popularity: Double, roles: [TMDbCreditRole], episodeCount: Int?) {
        self.mediaType = mediaType
        self.tmdbID = tmdbID
        self.title = title
        self.releaseDate = releaseDate
        self.poster = poster
        self.backdrop = backdrop
        self.voteAverage = voteAverage
        self.voteCount = voteCount
        self.popularity = popularity
        self.roles = roles
        self.episodeCount = episodeCount
    }

    /// Parses `/person/{id}/combined_credits`. Entries for one title are merged, so a writer who also acted in the film is one card.
    public static func parseCombined(_ data: Data) throws -> [TMDbPersonCredit] {
        let response: RawCombinedResponse
        do { response = try JSONDecoder().decode(RawCombinedResponse.self, from: data) } catch { throw AddonError.invalidJSON }
        var order: [String] = []
        var merged: [String: TMDbPersonCredit] = [:]
        for entry in (response.cast ?? []) + (response.crew ?? []) {
            guard entry.mediaType == "movie" || entry.mediaType == "tv" else { continue }
            let role = entry.role
            let credit = TMDbPersonCredit(entry: entry, roles: [role])
            // The first entry for a title supplies its details (TMDb repeats them on every entry); later ones only add roles.
            if var existing = merged[credit.id] {
                if !existing.roles.contains(role) { existing.roles.append(role) }
                merged[credit.id] = existing
            } else {
                order.append(credit.id)
                merged[credit.id] = credit
            }
        }
        return order.compactMap { merged[$0] }
    }

    private init(entry: RawCredit, roles: [TMDbCreditRole]) {
        let title = [entry.title, entry.name].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        let date = [entry.releaseDate, entry.firstAirDate].compactMap { $0 }.first { !$0.isEmpty }
        let votes = entry.voteCount ?? 0
        // An average with no votes behind it is not a rating.
        let average = votes > 0 ? entry.voteAverage.flatMap { (0...10).contains($0) ? $0 : nil } : nil
        self.init(mediaType: entry.mediaType ?? "", tmdbID: entry.id, title: title ?? "", releaseDate: date,
                  poster: TMDbImage.url(entry.posterPath, size: "w342"), backdrop: TMDbImage.url(entry.backdropPath, size: "w780"),
                  voteAverage: average, voteCount: votes, popularity: entry.popularity ?? 0, roles: roles, episodeCount: entry.episodeCount)
    }
}

/// One way of working on a title: an actor's character, or a crew job and the department it belongs to.
public enum TMDbCreditRole: Sendable, Hashable {
    case acting(character: String?)
    case crew(job: String, department: String)

    public var category: CreditCategory {
        switch self {
        case .acting: .acting
        case .crew(_, let department): CreditCategory(department: department)
        }
    }
}

/// The filter groups of a filmography: what someone did, not the job's exact title.
public enum CreditCategory: String, CaseIterable, Sendable, Hashable {
    case acting, directing, writing, production, other

    init(department: String) {
        switch department.lowercased() {
        case "acting": self = .acting
        case "directing": self = .directing
        case "writing": self = .writing
        case "production": self = .production
        default: self = .other
        }
    }
}

// MARK: - Client

extension TMDbRatings {
    /// The cast and crew of an IMDb title. Empty when TMDb does not know the title. Throws `AddonError` for refusals and failures.
    public func titleCredits(imdbID: String, type: String) async throws -> TMDbTitleCredits {
        guard let id = try await tmdbID(imdbID: imdbID, type: type) else { return .empty }
        let (url, headers) = try request(path: type == "movie" ? ["movie", String(id), "credits"] : ["tv", String(id), "aggregate_credits"])
        let result = try await client.get(url, headers: headers, limits: FetchLimits(maxBytes: 2 * 1024 * 1024), timeout: 8)
        return try TMDbTitleCredits.parse(result.data)
    }

}

// MARK: - Related titles

/// A movie or series TMDb recommends alongside another one.
public struct TMDbRelatedTitle: Sendable, Equatable, Identifiable {
    /// "movie" or "tv".
    public let mediaType: String
    public let tmdbID: Int
    public let title: String
    public let releaseDate: String?
    /// TMDb supplies this synopsis in the recommendation response, so no extra request is needed.
    public let overview: String?
    /// A 342 pt wide poster. Nil when TMDb has none.
    public let poster: URL?
    /// A 780 pt wide backdrop. Nil when TMDb has none.
    public let backdrop: URL?

    public var id: String { "\(mediaType)/\(tmdbID)" }

    public init(mediaType: String, tmdbID: Int, title: String, releaseDate: String?, poster: URL?, backdrop: URL?,
                overview: String? = nil) {
        self.mediaType = mediaType
        self.tmdbID = tmdbID
        self.title = title
        self.releaseDate = releaseDate
        self.overview = overview
        self.poster = poster
        self.backdrop = backdrop
    }

    static func parse(_ data: Data) throws -> [TMDbRelatedTitle] {
        let response: RawRecommendations
        do { response = try JSONDecoder().decode(RawRecommendations.self, from: data) } catch { throw AddonError.invalidJSON }
        return (response.results ?? []).compactMap { entry in
            let title = [entry.title, entry.name].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            guard let title else { return nil }
            let date = [entry.releaseDate, entry.firstAirDate].compactMap { $0 }.first { !$0.isEmpty }
            return TMDbRelatedTitle(mediaType: entry.mediaType ?? "movie", tmdbID: entry.id, title: title, releaseDate: date,
                                    poster: TMDbImage.url(entry.posterPath, size: "w342"),
                                    backdrop: TMDbImage.url(entry.backdropPath, size: "w780"), overview: entry.overview)
        }
    }
}

extension TMDbRatings {
    /// A person's page. Throws `AddonError` for refusals (a 404 when TMDb has no such person) and failures.
    public func person(id: Int) async throws -> TMDbPerson {
        let (url, headers) = try request(path: ["person", String(id)])
        let result = try await client.get(url, headers: headers, limits: FetchLimits(maxBytes: 256 * 1024), timeout: 8)
        return try TMDbPerson.parse(result.data)
    }

    /// Everything a person is credited on, acting and crew alike, in TMDb's order. Throws `AddonError` for refusals and failures.
    public func personCredits(id: Int) async throws -> [TMDbPersonCredit] {
        let (url, headers) = try request(path: ["person", String(id), "combined_credits"])
        let result = try await client.get(url, headers: headers, limits: FetchLimits(maxBytes: 4 * 1024 * 1024), timeout: 10)
        return try TMDbPersonCredit.parseCombined(result.data)
    }

    /// Every profile photo TMDb has for a person, best voted first, each 342 pt wide. Empty when there are none. Throws `AddonError` for
    /// refusals and failures.
    public func personPhotos(id: Int) async throws -> [URL] {
        let (url, headers) = try request(path: ["person", String(id), "images"])
        let result = try await client.get(url, headers: headers, limits: FetchLimits(maxBytes: 512 * 1024), timeout: 8)
        let response: RawPersonImages
        do { response = try JSONDecoder().decode(RawPersonImages.self, from: result.data) } catch { throw AddonError.invalidJSON }
        return (response.profiles ?? [])
            .sorted { ($0.voteAverage ?? 0, $0.voteCount ?? 0) > ($1.voteAverage ?? 0, $1.voteCount ?? 0) }
            .compactMap { TMDbImage.url($0.filePath, size: "w342") }
    }

    /// Titles TMDb recommends alongside the given one, in TMDb's order. Empty when TMDb does not know the title. Throws `AddonError`
    /// for refusals and failures.
    public func relatedTitles(imdbID: String, type: String) async throws -> [TMDbRelatedTitle] {
        guard let id = try await tmdbID(imdbID: imdbID, type: type) else { return [] }
        let (url, headers) = try request(path: [type == "movie" ? "movie" : "tv", String(id), "recommendations"])
        let result = try await client.get(url, headers: headers, limits: FetchLimits(maxBytes: 1024 * 1024), timeout: 8)
        return try TMDbRelatedTitle.parse(result.data)
    }

    /// The IMDb id of a TMDb movie or series, so a credit can open the title's page. Nil when TMDb has none.
    public func imdbID(tmdbID: Int, mediaType: String) async throws -> String? {
        guard ["movie", "tv"].contains(mediaType), tmdbID > 0, credential != nil else { return nil }
        let (url, headers) = try request(path: [mediaType, String(tmdbID), "external_ids"])
        let result = try await client.get(url, headers: headers, limits: FetchLimits(maxBytes: 64 * 1024), timeout: 6)
        let ids: RawExternalIDs
        do { ids = try JSONDecoder().decode(RawExternalIDs.self, from: result.data) } catch { throw AddonError.invalidJSON }
        guard let imdb = ids.imdbID, LetterboxdRatings.isIMDbID(imdb) else { return nil }
        return imdb
    }
}

// MARK: - Images

/// TMDb image URLs at a fixed width or height. The size is in the path, so the server sends no more pixels than the screen shows.
enum TMDbImage {
    static func url(_ path: String?, size: String) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }
}

// MARK: - Wire format

private struct RawCreditsResponse: Decodable {
    let cast: [RawPerson]?
    let crew: [RawPerson]?
}

/// One entry of `/credits` or `/aggregate_credits`: a movie's entry has `character` or `job`, a series' has `roles` or `jobs`. A crew
/// entry also has its `department`.
private struct RawPerson: Decodable {
    let id: Int
    let name: String?
    let profilePath: String?
    let character: String?
    let job: String?
    let department: String?
    let roles: [RawRole]?
    let jobs: [RawRole]?

    enum CodingKeys: String, CodingKey {
        case id, name, character, job, department, roles, jobs
        case profilePath = "profile_path"
    }
}

private struct RawRole: Decodable {
    let character: String?
    let job: String?
}

private struct RawPersonResponse: Decodable {
    let id: Int
    let name: String?
    let biography: String?
    let knownForDepartment: String?
    let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, biography
        case knownForDepartment = "known_for_department"
        case profilePath = "profile_path"
    }
}

private struct RawCombinedResponse: Decodable {
    let cast: [RawCredit]?
    let crew: [RawCredit]?
}

/// One entry of `combined_credits`. A cast entry has `character`; a crew entry has `job` and `department`.
private struct RawCredit: Decodable {
    let id: Int
    let mediaType: String?
    let title: String?
    let name: String?
    let releaseDate: String?
    let firstAirDate: String?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?
    let voteCount: Int?
    let popularity: Double?
    let episodeCount: Int?
    let character: String?
    let job: String?
    let department: String?

    /// What the person did on this entry: acting for a cast entry, the crew job otherwise.
    var role: TMDbCreditRole {
        if let job, !job.isEmpty {
            return .crew(job: job, department: department ?? "")
        }
        if let department, !department.isEmpty, character == nil {
            return .crew(job: department, department: department)
        }
        let trimmed = character?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .acting(character: trimmed?.isEmpty == false ? trimmed : nil)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, name, popularity, character, job, department
        case mediaType = "media_type"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case episodeCount = "episode_count"
    }
}

private struct RawRecommendations: Decodable {
    let results: [RawRecommendation]?

    struct RawRecommendation: Decodable {
        let id: Int
        let overview: String?
        let mediaType: String?
        let title: String?
        let name: String?
        let releaseDate: String?
        let firstAirDate: String?
        let posterPath: String?
        let backdropPath: String?

        enum CodingKeys: String, CodingKey {
            case id, title, name, overview
            case mediaType = "media_type"
            case releaseDate = "release_date"
            case firstAirDate = "first_air_date"
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
        }
    }
}

private struct RawPersonImages: Decodable {
    let profiles: [RawProfile]?

    struct RawProfile: Decodable {
        let filePath: String
        let voteAverage: Double?
        let voteCount: Int?

        enum CodingKeys: String, CodingKey {
            case filePath = "file_path"
            case voteAverage = "vote_average"
            case voteCount = "vote_count"
        }
    }
}

private struct RawExternalIDs: Decodable {
    let imdbID: String?

    enum CodingKeys: String, CodingKey { case imdbID = "imdb_id" }
}
