import Foundation

/// The IMDb id of each TMDb movie or series, kept for the session. A discover widget asks for many titles at once, and the same titles on
/// every page, so each id is looked up once. A title TMDb has no IMDb id for is kept too; a failed lookup is not, so it is asked again.
public actor TMDbIMDbIDCache {
    public static let shared = TMDbIMDbIDCache()

    private var ids: [String: String] = [:]
    private var withoutID: Set<String> = []
    private var lookups: [String: Task<String?, Error>] = [:]

    public init() {}

    /// The cached answer for `key`, or the answer of `lookup`. Callers that ask at the same time share one lookup.
    func imdbID(for key: String, lookup: @escaping @Sendable () async throws -> String?) async throws -> String? {
        if let id = ids[key] { return id }
        if withoutID.contains(key) { return nil }
        if let pending = lookups[key] { return try await pending.value }
        let task = Task { try await lookup() }
        lookups[key] = task
        defer { lookups[key] = nil }
        let id = try await task.value
        if let id { ids[key] = id } else { withoutID.insert(key) }
        return id
    }
}

/// One title on a TMDb discover or trending page, with the fields a row needs. Internal: the public result is `MetaPreview`.
struct TMDbDiscoverEntry: Sendable, Equatable {
    let tmdbID: Int
    let title: String
    let overview: String
    let posterPath: String?
    let backdropPath: String?
    /// The release date, or the first air date for a series, as TMDb sends it ("2024-03-01").
    let date: String?
    let genreIDs: [Int]
    let voteAverage: Double?
    let voteCount: Int?
    let originalLanguage: String?

    /// The entries of one page and TMDb's count of pages. Movies name the title `title` and the date `release_date`; series use `name` and
    /// `first_air_date`. An entry without a title or with an id of 0 or less is skipped. Throws `invalidJSON` when the answer has no
    /// `results` list.
    static func parsePage(_ data: Data) throws -> (entries: [TMDbDiscoverEntry], totalPages: Int) {
        let page: RawPage
        do { page = try JSONDecoder().decode(RawPage.self, from: data) } catch { throw AddonError.invalidJSON }
        guard let results = page.results else { throw AddonError.invalidJSON }
        return (results.compactMap(\.entry), page.totalPages ?? 0)
    }

    private struct RawPage: Decodable {
        let results: [RawEntry]?
        let totalPages: Int?

        enum CodingKeys: String, CodingKey {
            case results
            case totalPages = "total_pages"
        }
    }

    private struct RawEntry: Decodable {
        let id: Int?
        let title: String?
        let name: String?
        let overview: String?
        let posterPath: String?
        let backdropPath: String?
        let releaseDate: String?
        let firstAirDate: String?
        let genreIDs: [Int]?
        let voteAverage: Double?
        let voteCount: Int?
        let originalLanguage: String?

        enum CodingKeys: String, CodingKey {
            case id, title, name, overview
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
            case releaseDate = "release_date"
            case firstAirDate = "first_air_date"
            case genreIDs = "genre_ids"
            case voteAverage = "vote_average"
            case voteCount = "vote_count"
            case originalLanguage = "original_language"
        }

        var entry: TMDbDiscoverEntry? {
            guard let id, id > 0, let heading = Self.text(title) ?? Self.text(name) else { return nil }
            return TMDbDiscoverEntry(tmdbID: id, title: heading, overview: Self.text(overview) ?? "", posterPath: posterPath,
                                     backdropPath: backdropPath, date: Self.text(releaseDate) ?? Self.text(firstAirDate),
                                     genreIDs: genreIDs ?? [], voteAverage: voteAverage, voteCount: voteCount,
                                     originalLanguage: Self.text(originalLanguage))
        }

        /// The value trimmed, or nil when it is missing or blank.
        private static func text(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
    }
}

extension TMDbRatings {
    /// The path and query for one page of a discover widget. A trending query asks TMDb's trending list, which takes no filters. Any other
    /// query asks `discover` with each filter it sets and supports, and a date range from `dateRange`. With `scoresOnIMDb`, the score and
    /// votes are IMDb's and checked title by title: TMDb is asked only for scores within a point of the bounds, and for a hundredth of the
    /// votes, since TMDb counts far fewer, so a page holds the titles likely to meet them. Without that floor a list sorted by date would be
    /// mostly titles nobody has rated. Pure: nothing is requested.
    static func discoverRequest(_ query: TMDbDiscoverQuery, page: Int, defaultRegion: String, today: Date, calendar: Calendar,
                                scoresOnIMDb: Bool = false) -> (path: [String], query: [URLQueryItem]) {
        let isMovie = query.kind == .movie
        let kind = isMovie ? "movie" : "tv"
        if query.isTrending {
            let window = query.ordering == .trendingToday ? "day" : "week"
            return (["trending", kind, window], [URLQueryItem(name: "page", value: String(page))])
        }
        let active: (TMDbDiscoverQuery.Filter) -> Bool = { query.isSet($0) && query.supports($0) }
        var items = [URLQueryItem(name: "include_adult", value: "false"), URLQueryItem(name: "page", value: String(page)),
                     URLQueryItem(name: "sort_by", value: sortKey(query.ordering, isMovie: isMovie))]
        func add(_ name: String, _ value: String?) {
            if let value { items.append(URLQueryItem(name: name, value: value)) }
        }
        add("with_genres", active(.genres) ? joinedIDs(query.genres, separator: ",") : nil)
        add("without_genres", query.effectiveExcludedGenres.isEmpty ? nil : joinedIDs(query.effectiveExcludedGenres, separator: ","))
        add("with_keywords", active(.keywords) ? joinedIDs(query.keywords, separator: "|") : nil)
        add("without_keywords", active(.excludedKeywords) ? joinedIDs(query.excludedKeywords, separator: ",") : nil)
        if scoresOnIMDb {
            add("vote_average.gte", active(.score) ? query.minimumScore.flatMap { $0 > 1 ? oneDecimal($0 - 1) : nil } : nil)
            add("vote_average.lte", active(.score) ? query.maximumScore.flatMap { $0 < 9 ? oneDecimal($0 + 1) : nil } : nil)
            add("vote_count.gte", active(.votes) ? query.minimumVotes.map { String(max(1, $0 / 100)) } : nil)
        } else {
            add("vote_average.gte", active(.score) ? query.minimumScore.map(oneDecimal) : nil)
            add("vote_average.lte", active(.score) ? query.maximumScore.map(oneDecimal) : nil)
            add("vote_count.gte", active(.votes) ? query.minimumVotes.map { String($0) } : nil)
        }
        add("with_original_language", active(.language) ? query.language : nil)
        add("with_runtime.gte", active(.runtime) ? query.minimumRuntime.map { String($0) } : nil)
        add("with_runtime.lte", active(.runtime) ? query.maximumRuntime.map { String($0) } : nil)
        let range = query.dateRange(today: today, calendar: calendar)
        add(isMovie ? "primary_release_date.gte" : "first_air_date.gte", range.from)
        add(isMovie ? "primary_release_date.lte" : "first_air_date.lte", range.to)
        if active(.providers) {
            add("with_watch_providers", joinedIDs(query.providers, separator: "|"))
            add("watch_region", query.region ?? defaultRegion)
        }
        add("with_cast", active(.cast) ? joinedIDs(query.cast, separator: ",") : nil)
        add("with_crew", active(.crew) ? joinedIDs(query.crew, separator: ",") : nil)
        add("with_companies", active(.companies) ? joinedIDs(query.companies, separator: "|") : nil)
        return (["discover", kind], items)
    }

    /// TMDb's sort for an ordering. Trending orderings never reach `discover`, so they sort by popularity.
    private static func sortKey(_ ordering: TMDbDiscoverQuery.Ordering, isMovie: Bool) -> String {
        switch ordering {
        case .newest: return isMovie ? "primary_release_date.desc" : "first_air_date.desc"
        case .oldest: return isMovie ? "primary_release_date.asc" : "first_air_date.asc"
        case .popular, .trendingToday, .trendingThisWeek: return "popularity.desc"
        }
    }

    private static func joinedIDs(_ named: [TMDbDiscoverQuery.Named], separator: String) -> String {
        named.map { String($0.id) }.joined(separator: separator)
    }

    /// A score with one decimal place, always with a point: "7.0".
    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// Whether a trending entry meets the filters a trending list can use, which TMDb does not apply itself: every selected genre, the
    /// score and vote bounds, the language, and the release date range. An entry without a score, votes, language or date fails a bound it
    /// is asked to meet. With `scoresOnIMDb`, the score and votes are left to IMDb's rating (`meetsIMDbBounds`).
    static func matchesTrendingFilters(_ entry: TMDbDiscoverEntry, query: TMDbDiscoverQuery, today: Date, calendar: Calendar,
                                       scoresOnIMDb: Bool = false) -> Bool {
        guard query.genres.allSatisfy({ entry.genreIDs.contains($0.id) }) else { return false }
        if query.isSet(.score), !scoresOnIMDb {
            guard let score = entry.voteAverage else { return false }
            if let minimum = query.minimumScore, score < minimum { return false }
            if let maximum = query.maximumScore, score > maximum { return false }
        }
        if !scoresOnIMDb, let minimum = query.minimumVotes, (entry.voteCount ?? 0) < minimum { return false }
        if let language = query.language, entry.originalLanguage?.lowercased() != language.lowercased() { return false }
        let range = query.dateRange(today: today, calendar: calendar)
        if range.from != nil || range.to != nil {
            guard let date = entry.date else { return false }
            if let from = range.from, date < from { return false }
            if let to = range.to, date > to { return false }
        }
        return true
    }
}

extension TMDbRatings {
    /// Whether IMDb's rating of a title meets the query's score and vote bounds. A title without a rating fails a bound it is asked to meet.
    static func meetsIMDbBounds(_ rating: IMDbRating?, query: TMDbDiscoverQuery) -> Bool {
        if query.isSet(.score) {
            guard let score = rating?.rating else { return false }
            if let minimum = query.minimumScore, score < minimum { return false }
            if let maximum = query.maximumScore, score > maximum { return false }
        }
        if let minimum = query.minimumVotes, (rating?.votes ?? 0) < minimum { return false }
        return true
    }

    /// Whether a title has a genre the query leaves out. TMDb is asked the same with `without_genres`; this checks each title as well.
    static func hasExcludedGenre(_ entry: TMDbDiscoverEntry, query: TMDbDiscoverQuery) -> Bool {
        query.effectiveExcludedGenres.contains { genre in entry.genreIDs.contains(genre.id) }
    }

    /// One page of a discover or trending widget as `MetaPreview`s, from `skip` on, `limit` at most. Pages are read from TMDb until enough
    /// titles are found or the pages run out. Entries without an IMDb id are left out, since the addon's links need one. A widget's score
    /// and votes are IMDb's when `imdb` holds IMDb's ratings: each title is checked against its IMDb rating, and up to five more pages are
    /// read to find enough. Throws `AddonError` for refusals and failures, and `CancellationError` when the caller is cancelled. Empty
    /// without a credential.
    public func discoverItems(_ query: TMDbDiscoverQuery, limit: Int, skip: Int, defaultRegion: String, today: Date = Date(),
                              calendar: Calendar = .current, imdb: (any IMDbDataset)? = nil) async throws -> [MetaPreview] {
        guard limit > 0, credential != nil else { return [] }
        if query.spansBothKinds {
            // A title that names neither films nor shows asks for both kinds, and interleaves them, so a show is in the list as a film is.
            var films = query
            films.kind = .movie
            films.spansBothKinds = false
            var shows = query
            shows.kind = .series
            shows.spansBothKinds = false
            // Adult animation leaves out a show's kids' shows as well as the family titles, so the shows side does the same.
            if query.excludedGenres.contains(where: { $0.id == 10751 }), !query.excludedGenres.contains(where: { $0.id == 10762 }) {
                shows.excludedGenres.append(TMDbDiscoverQuery.Named(id: 10762, name: "Kids"))
            }
            let needed = max(skip, 0) + limit
            let movieItems = try await discoverItems(films, limit: needed, skip: 0, defaultRegion: defaultRegion, today: today, calendar: calendar,
                                                     imdb: imdb)
            let seriesItems = try await discoverItems(shows, limit: needed, skip: 0, defaultRegion: defaultRegion, today: today, calendar: calendar,
                                                      imdb: imdb)
            var merged: [MetaPreview] = []
            for index in 0..<max(movieItems.count, seriesItems.count) {
                if index < movieItems.count { merged.append(movieItems[index]) }
                if index < seriesItems.count { merged.append(seriesItems[index]) }
            }
            return Array(merged.dropFirst(max(skip, 0)).prefix(limit))
        }
        // A widget's score and votes are IMDb's once its dataset is on the device; until then, and for a search's list, TMDb's.
        var scores: (any IMDbDataset)?
        if let imdb, !query.usesTMDbScores, query.isSet(.score) || query.isSet(.votes), (await imdb.status()?.titleCount ?? 0) > 0 {
            scores = imdb
        }
        let offset = max(skip, 0)
        let needed = offset + limit
        let discoverPages = (needed + 19) / 20
        let pageBudget = query.isTrending || scores != nil ? discoverPages + 5 : discoverPages
        let mediaType = query.kind == .movie ? "movie" : "tv"
        var entries: [TMDbDiscoverEntry] = []
        // With IMDb's scores: the titles that met them, with their IMDb ids.
        var rated: [(entry: TMDbDiscoverEntry, imdbID: String?)] = []
        var seen: Set<Int> = []
        var page = 1
        while (scores == nil ? entries.count : rated.count) < needed, page <= pageBudget {
            try Task.checkCancellation()
            let (path, items) = Self.discoverRequest(query, page: page, defaultRegion: defaultRegion, today: today, calendar: calendar,
                                                     scoresOnIMDb: scores != nil)
            let (url, headers) = try request(path: path, query: items)
            let result = try await client.get(url, headers: headers, limits: FetchLimits(maxBytes: 1024 * 1024), timeout: 8)
            let answer = try TMDbDiscoverEntry.parsePage(result.data)
            var fresh: [TMDbDiscoverEntry] = []
            for entry in answer.entries where seen.insert(entry.tmdbID).inserted {
                if query.isTrending,
                   !Self.matchesTrendingFilters(entry, query: query, today: today, calendar: calendar, scoresOnIMDb: scores != nil) { continue }
                // `without_genres` is asked of TMDb for discover lists, and each title is checked here too, trending lists included.
                if Self.hasExcludedGenre(entry, query: query) { continue }
                fresh.append(entry)
            }
            if let scores {
                rated += try await imdbRated(fresh, mediaType: mediaType, query: query, scores: scores, wanted: needed - rated.count)
            } else {
                entries += fresh
            }
            if page >= min(answer.totalPages, 500) { break }
            page += 1
        }
        let window: [(entry: TMDbDiscoverEntry, imdbID: String?)]
        if scores != nil {
            window = Array(rated.dropFirst(offset).prefix(limit))
        } else {
            let plain = Array(entries.dropFirst(offset).prefix(limit))
            window = Array(zip(plain, try await resolveIMDbIDs(for: plain, mediaType: mediaType)))
        }
        return window.compactMap { entry, imdbID in
            guard let imdbID else { return nil }
            return MetaPreview(id: imdbID, type: query.kind == .movie ? "movie" : "series", name: entry.title,
                               poster: TMDbImage.url(entry.posterPath, size: "w500"),
                                   background: TMDbImage.url(entry.backdropPath, size: "w1280"),
                               description: entry.overview.isEmpty ? nil : entry.overview, releaseInfo: Self.releaseYear(entry.date),
                               genres: Self.genreNames(entry.genreIDs, mediaType: mediaType))
        }
    }

    /// Real title matches for an unstructured name such as "Dune". This is distinct from keyword discovery:
    /// it prevents a single title query from returning a random page of popular films.
    public func searchTitleItems(_ text: String, kind: TMDbDiscoverQuery.Kind? = nil, limit: Int = 12) async throws -> [MetaPreview] {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, limit > 0, credential != nil else { return [] }
        let mediaTypes = kind.map { [$0 == .movie ? "movie" : "tv"] } ?? ["movie", "tv"]
        var all: [[MetaPreview]] = []
        for mediaType in mediaTypes {
            try Task.checkCancellation()
            let (url, headers) = try request(path: ["search", mediaType],
                                             query: [URLQueryItem(name: "query", value: term),
                                                     URLQueryItem(name: "page", value: "1"),
                                                     URLQueryItem(name: "include_adult", value: "false")])
            let response = try await client.get(url, headers: headers, limits: FetchLimits(maxBytes: 1024 * 1024), timeout: 8)
            let page = try TMDbDiscoverEntry.parsePage(response.data)
            let entries = Array(page.entries.prefix(limit))
            let ids = try await resolveIMDbIDs(for: entries, mediaType: mediaType)
            all.append(zip(entries, ids).compactMap { entry, imdb -> MetaPreview? in
                guard let imdb else { return nil }
                return MetaPreview(id: imdb, type: mediaType == "movie" ? "movie" : "series",
                                   name: entry.title, poster: TMDbImage.url(entry.posterPath, size: "w500"),
                                   background: TMDbImage.url(entry.backdropPath, size: "w1280"),
                                   description: entry.overview.isEmpty ? nil : entry.overview, releaseInfo: Self.releaseYear(entry.date),
                               genres: Self.genreNames(entry.genreIDs, mediaType: mediaType))
            })
        }
        // Interleave the movie and TV results without allowing either to dominate an untyped query.
        var merged: [MetaPreview] = []
        var seen: Set<String> = []
        for index in 0..<(all.map(\.count).max() ?? 0) {
            for list in all where index < list.count {
                let item = list[index]
                if seen.insert(item.identity).inserted { merged.append(item) }
                if merged.count == limit { return merged }
            }
        }
        return merged
    }

    /// The entries whose IMDb rating meets the query's score and vote bounds, in order, with their IMDb ids, at most `wanted`. Ids are asked
    /// for six at a time, and only until enough titles are found. A title without an IMDb id or rating is left out.
    private func imdbRated(_ entries: [TMDbDiscoverEntry], mediaType: String, query: TMDbDiscoverQuery, scores: any IMDbDataset,
                           wanted: Int) async throws -> [(entry: TMDbDiscoverEntry, imdbID: String?)] {
        var rated: [(entry: TMDbDiscoverEntry, imdbID: String?)] = []
        var start = 0
        while start < entries.count, rated.count < wanted {
            let batch = Array(entries[start..<min(start + 6, entries.count)])
            let ids = try await resolveIMDbIDs(for: batch, mediaType: mediaType)
            for (entry, imdbID) in zip(batch, ids) {
                guard let imdbID, Self.meetsIMDbBounds(await scores.rating(for: imdbID), query: query) else { continue }
                rated.append((entry, imdbID))
            }
            start += 6
        }
        return Array(rated.prefix(max(wanted, 0)))
    }

    /// The IMDb id of each entry, in order, asked for at most six at a time. Nil for an entry TMDb has no IMDb id for, or whose lookup
    /// failed. Throws `CancellationError` when the caller is cancelled.
    private func resolveIMDbIDs(for entries: [TMDbDiscoverEntry], mediaType: String) async throws -> [String?] {
        var resolved: [String?] = []
        for start in stride(from: 0, to: entries.count, by: 6) {
            let batch = Array(entries[start..<min(start + 6, entries.count)])
            let found: [String?] = await withTaskGroup(of: (Int, String?).self, returning: [String?].self) { group in
                for (offset, entry) in batch.enumerated() {
                    group.addTask { (offset, try? await self.cachedIMDbID(tmdbID: entry.tmdbID, mediaType: mediaType)) }
                }
                var answers = [String?](repeating: nil, count: batch.count)
                for await (offset, imdbID) in group { answers[offset] = imdbID }
                return answers
            }
            try Task.checkCancellation()
            resolved += found
        }
        return resolved
    }

    /// The IMDb id of a TMDb title, kept by `imdbIDs` for the session.
    private func cachedIMDbID(tmdbID: Int, mediaType: String) async throws -> String? {
        try await imdbIDs.imdbID(for: "\(mediaType)/\(tmdbID)") {
            try await self.imdbID(tmdbID: tmdbID, mediaType: mediaType)
        }
    }

    private static func genreNames(_ ids: [Int], mediaType: String) -> [String] {
        let names = TMDbDiscoverQuery.genreClues.compactMap { mediaType == "movie" ? $0.movie : $0.series }
        return ids.compactMap { id in names.first(where: { $0.id == id })?.name }
    }

    /// The first four characters of a date when they are a year, such as "2024" from "2024-03-01"; nil otherwise.
    private static func releaseYear(_ date: String?) -> String? {
        guard let year = date?.prefix(4), year.count == 4, year.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(year)
    }
}

// MARK: - Editor lookups

extension TMDbRatings {
    /// The genres TMDb lists for movies or series. Empty without a credential. Throws `AddonError` for refusals and failures.
    public func genres(kind: TMDbDiscoverQuery.Kind) async throws -> [TMDbDiscoverQuery.Named] {
        guard credential != nil else { return [] }
        let answer: RawGenreAnswer = try await lookup(["genre", kind == .movie ? "movie" : "tv", "list"])
        return Self.named(answer.genres)
    }

    /// The keywords that match the text, in TMDb's order, at most 30. Empty for blank text, which sends no request.
    public func searchKeywords(_ text: String) async throws -> [TMDbDiscoverQuery.Named] {
        try await search(["search", "keyword"], text)
    }

    /// The people whose names match the text, in TMDb's order, at most 30. Empty for blank text, which sends no request.
    public func searchPeople(_ text: String) async throws -> [TMDbDiscoverQuery.Named] {
        try await search(["search", "person"], text, extra: [URLQueryItem(name: "include_adult", value: "false")])
    }

    /// The production companies that match the text, in TMDb's order, at most 30. Empty for blank text, which sends no request.
    public func searchCompanies(_ text: String) async throws -> [TMDbDiscoverQuery.Named] {
        try await search(["search", "company"], text)
    }

    /// The watch providers offered in a region, most prominent first, at most 30. `region` is an ISO 3166-1 code such as "IE". Empty for a
    /// blank region, which sends no request.
    public func watchProviders(kind: TMDbDiscoverQuery.Kind, region: String) async throws -> [TMDbDiscoverQuery.Named] {
        let code = region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, credential != nil else { return [] }
        let answer: RawProviderAnswer = try await lookup(["watch", "providers", kind == .movie ? "movie" : "tv"],
                                                         query: [URLQueryItem(name: "watch_region", value: code)])
        let byPriority = answer.results.enumerated()
            .sorted { (($0.element.displayPriority ?? Int.max), $0.offset) < (($1.element.displayPriority ?? Int.max), $1.offset) }
            .map(\.element)
        let named = byPriority.compactMap { raw -> TMDbDiscoverQuery.Named? in
            guard let id = raw.providerID, id > 0, let name = raw.providerName?.trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty
            else { return nil }
            return TMDbDiscoverQuery.Named(id: id, name: name)
        }
        return Array(named.prefix(30))
    }

    /// The matches of a `search` path for trimmed text. Blank text sends nothing.
    private func search(_ path: [String], _ text: String, extra: [URLQueryItem] = []) async throws -> [TMDbDiscoverQuery.Named] {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, credential != nil else { return [] }
        let query = [URLQueryItem(name: "query", value: term), URLQueryItem(name: "page", value: "1")] + extra
        let answer: RawSearchAnswer = try await lookup(path, query: query)
        return Array(Self.named(answer.results).prefix(30))
    }

    /// Reads one lookup answer. Throws `AddonError` for refusals and failures, and `invalidJSON` for an answer of the wrong shape.
    private func lookup<Answer: Decodable>(_ path: [String], query: [URLQueryItem] = []) async throws -> Answer {
        let (url, headers) = try request(path: path, query: query)
        let result = try await client.get(url, headers: headers, limits: FetchLimits(maxBytes: 512 * 1024), timeout: 8)
        do { return try JSONDecoder().decode(Answer.self, from: result.data) } catch { throw AddonError.invalidJSON }
    }

    /// The named entries with a positive id and a name, in order.
    private static func named(_ raw: [RawNamed]) -> [TMDbDiscoverQuery.Named] {
        raw.compactMap { entry in
            guard let id = entry.id, id > 0, let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            else { return nil }
            return TMDbDiscoverQuery.Named(id: id, name: name)
        }
    }

    private struct RawNamed: Decodable {
        let id: Int?
        let name: String?
    }

    private struct RawGenreAnswer: Decodable { let genres: [RawNamed] }
    private struct RawSearchAnswer: Decodable { let results: [RawNamed] }

    private struct RawProviderAnswer: Decodable { let results: [RawProvider] }

    private struct RawProvider: Decodable {
        let providerID: Int?
        let providerName: String?
        let displayPriority: Int?

        enum CodingKeys: String, CodingKey {
            case providerID = "provider_id"
            case providerName = "provider_name"
            case displayPriority = "display_priority"
        }
    }
}
