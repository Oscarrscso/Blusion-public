import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

/// Gregorian UTC, so date arithmetic is the same on every machine.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
}()

private let testToday = utc.date(from: DateComponents(year: 2026, month: 10, day: 12)) ?? Date(timeIntervalSince1970: 0)

private let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ0ZXN0In0.signature"

/// A movie entry of a discover or trending page, as TMDb sends it.
private func movieJSON(_ id: Int, genres: [Int] = [], score: Double = 7.5, votes: Int = 900, language: String = "en",
                       date: String = "2020-01-02") -> String {
    let genreList = genres.map { String($0) }.joined(separator: ",")
    return #"""
        {"id":\#(id),"title":"Movie \#(id)","overview":"About \#(id)","poster_path":"/p\#(id).jpg","backdrop_path":"/b\#(id).jpg",
        "release_date":"\#(date)","genre_ids":[\#(genreList)],"vote_average":\#(score),"vote_count":\#(votes),
        "original_language":"\#(language)"}
        """#
}

/// A series entry of a discover page: its name and first air date, and no overview or poster.
private func seriesJSON(_ id: Int) -> String {
    #"""
        {"id":\#(id),"name":"Show \#(id)","overview":"","poster_path":null,"backdrop_path":"/s\#(id).jpg",
        "first_air_date":"2011-04-17","genre_ids":[16],"vote_average":8.1,"vote_count":400,"original_language":"en"}
        """#
}

/// The pages of `total` entries, 20 to a page, each entry made by `make`.
private func pages(total: Int, _ make: @escaping @Sendable (Int) -> String) -> @Sendable (Int) -> [String] {
    { page in
        let first = (page - 1) * 20 + 1
        guard first <= total else { return [] }
        return (first...min(first + 19, total)).map(make)
    }
}

/// The value of a query item in a URL, or nil.
private func queryValue(_ url: URL?, _ name: String) -> String? {
    guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
    return items.first { $0.name == name }?.value
}

/// Answers TMDb's discover and trending requests with `entries(page)` and `totalPages`, and the external ids of titles: "tt" and a million
/// plus the TMDb id, null for `noIMDb` and a 404 for `failing`.
private func tmdbStub(totalPages: Int = 5, noIMDb: Set<Int> = [], failing: Set<Int> = [],
                      entries: @escaping @Sendable (Int) -> [String]) -> StubTransport {
    StubTransport { request, _ in
        let path = request.url?.path ?? ""
        if path.hasPrefix("/3/discover/") || path.hasPrefix("/3/trending/") {
            let page = Int(queryValue(request.url, "page") ?? "") ?? 1
            let body = #"{"page":\#(page),"total_pages":\#(totalPages),"results":[\#(entries(page).joined(separator: ","))]}"#
            return StubTransport.response(Data(body.utf8), for: request)
        }
        // /3/movie/{id}/external_ids or /3/tv/{id}/external_ids
        let parts = path.split(separator: "/")
        if parts.count == 4, parts[3] == "external_ids", let id = Int(parts[2]) {
            if failing.contains(id) { return StubTransport.response(Data(), status: 404, for: request) }
            let imdb = noIMDb.contains(id) ? "null" : "\"tt\(1_000_000 + id)\""
            return StubTransport.response(Data(#"{"imdb_id":\#(imdb)}"#.utf8), for: request)
        }
        return StubTransport.response(Data(), status: 500, for: request)
    }
}

/// How many requests went to the discover or trending lists.
private func listRequests(_ transport: StubTransport) -> Int {
    transport.requests.filter { request in
        let path = request.url?.path ?? ""
        return path.hasPrefix("/3/discover/") || path.hasPrefix("/3/trending/")
    }.count
}

/// How many external-id lookups were asked, for one TMDb id or for every title.
private func externalIDRequests(_ transport: StubTransport, tmdbID: Int? = nil) -> Int {
    transport.requests.filter { request in
        let parts = (request.url?.path ?? "").split(separator: "/")
        guard parts.count == 4, parts[3] == "external_ids" else { return false }
        return tmdbID.map { parts[2] == String($0) } ?? true
    }.count
}

@Suite struct TMDbDiscoverTests {
    private func ratings(_ transport: StubTransport) -> TMDbRatings {
        TMDbRatings(client: makeClient(transport), readAccessToken: jwt, titleIDs: TMDbTitleIDCache(), imdbIDs: TMDbIMDbIDCache())
    }

    /// The path and the `name=value` items of the request a query makes for one page.
    private func request(_ query: TMDbDiscoverQuery, page: Int = 1, region: String = "US") -> (path: [String], items: [String]) {
        let request = TMDbRatings.discoverRequest(query, page: page, defaultRegion: region, today: testToday, calendar: utc)
        return (request.path, request.query.map { "\($0.name)=\($0.value ?? "")" })
    }

    @Test func exactTitleSearchQueriesTmdbMoviesAndSeriesAndKeepsOverviews() async throws {
        let transport = StubTransport { request, _ in
            let path = request.url?.path ?? ""
            if path == "/3/search/movie" {
                return StubTransport.response(Data(
                    #"{"results":[{"id":155,"title":"Dune","overview":"A hero crosses a dangerous desert.","release_date":"2021-10-22"}]}"#.utf8),
                    for: request)
            }
            if path == "/3/search/tv" {
                return StubTransport.response(Data(
                    #"{"results":[{"id":211,"name":"Dune","overview":"A desert-world miniseries.","first_air_date":"2000-12-03"}]}"#.utf8),
                    for: request)
            }
            let parts = path.split(separator: "/")
            if parts.count == 4, parts[3] == "external_ids", let id = Int(parts[2]) {
                return StubTransport.response(Data(#"{"imdb_id":"tt\#(1_000_000 + id)"}"#.utf8), for: request)
            }
            return StubTransport.response(Data(), status: 404, for: request)
        }
        let items = try await ratings(transport).searchTitleItems("Dune", limit: 12)
        #expect(items.map(\.type) == ["movie", "series"])
        #expect(items.map(\.name) == ["Dune", "Dune"])
        #expect(items.map(\.description) == ["A hero crosses a dangerous desert.", "A desert-world miniseries."])
        let titleCalls = transport.requests.filter { ($0.url?.path ?? "").hasPrefix("/3/search/") }
        #expect(titleCalls.count == 2)
        #expect(titleCalls.allSatisfy { queryValue($0.url, "query") == "Dune" })
    }

    // MARK: Requests

    @Test func aTrendingQueryAsksTheTrendingListAndIgnoresItsFilters() {
        let series = request(TMDbDiscoverQuery(kind: .series, ordering: .trendingThisWeek), page: 2)
        #expect(series.path == ["trending", "tv", "week"])
        #expect(series.items == ["page=2"])
        #expect(request(TMDbDiscoverQuery(ordering: .trendingToday)).path == ["trending", "movie", "day"])
        let filtered = request(TMDbDiscoverQuery(ordering: .trendingToday, genres: [.init(id: 16, name: "Animation")], minimumVotes: 5))
        #expect(filtered.items == ["page=1"], "TMDb's trending lists take no filters; the app applies them")
    }

    @Test func aPlainPopularMovieQueryHasOnlyTheBaseItems() {
        let plain = request(TMDbDiscoverQuery())
        #expect(plain.path == ["discover", "movie"])
        #expect(plain.items == ["include_adult=false", "page=1", "sort_by=popularity.desc"])
    }

    @Test func excludedGenresAreSentAsWithoutGenres() {
        let animation = [TMDbDiscoverQuery.Named(id: 16, name: "Animation")]
        let family = [TMDbDiscoverQuery.Named(id: 10751, name: "Family")]
        #expect(request(TMDbDiscoverQuery(genres: animation, excludedGenres: family)).items
            == ["include_adult=false", "page=1", "sort_by=popularity.desc", "with_genres=16", "without_genres=10751"])
        let kids = family + [TMDbDiscoverQuery.Named(id: 10762, name: "Kids")]
        #expect(request(TMDbDiscoverQuery(kind: .series, genres: animation, excludedGenres: kids)).items.contains("without_genres=10751,10762"))
        #expect(request(TMDbDiscoverQuery(genres: animation)).items.allSatisfy { !$0.hasPrefix("without_genres") })
    }

    @Test func aFullMovieQueryHasEveryItemWithItsSeparator() {
        let query = TMDbDiscoverQuery(
            kind: .movie, ordering: .newest, period: .thisYear,
            genres: [.init(id: 16, name: "Animation"), .init(id: 10751, name: "Family")],
            keywords: [.init(id: 1, name: "a"), .init(id: 2, name: "b")],
                        excludedKeywords: [.init(id: 3, name: "c"), .init(id: 4, name: "d")],
            minimumScore: 7, maximumScore: 9.5, minimumVotes: 500, language: "ja", minimumRuntime: 90, maximumRuntime: 120,
            providers: [.init(id: 8, name: "Netflix"), .init(id: 337, name: "Disney+")], region: "IE",
            cast: [.init(id: 1, name: "A"), .init(id: 2, name: "B")], crew: [.init(id: 525, name: "N")],
            companies: [.init(id: 2, name: "x"), .init(id: 3, name: "y")])
        let movie = request(query)
        #expect(movie.path == ["discover", "movie"])
        #expect(movie.items == [
            "include_adult=false", "page=1", "sort_by=primary_release_date.desc", "with_genres=16,10751", "with_keywords=1|2",
            "without_keywords=3,4", "vote_average.gte=7.0", "vote_average.lte=9.5", "vote_count.gte=500", "with_original_language=ja",
            "with_runtime.gte=90", "with_runtime.lte=120", "primary_release_date.gte=2026-01-01", "primary_release_date.lte=2026-10-12",
            "with_watch_providers=8|337", "watch_region=IE", "with_cast=1,2", "with_crew=525", "with_companies=2|3",
        ])
    }

    @Test func aSeriesQueryUsesFirstAirDatesAndNoPeopleFilters() {
        let query = TMDbDiscoverQuery(kind: .series, ordering: .oldest, period: .lastYear, genres: [.init(id: 16, name: "Animation")],
                                      cast: [.init(id: 1, name: "A")], crew: [.init(id: 525, name: "N")],
                                      companies: [.init(id: 2, name: "x"), .init(id: 3, name: "y")])
        let series = request(query)
        #expect(series.path == ["discover", "tv"])
        #expect(series.items == ["include_adult=false", "page=1", "sort_by=first_air_date.asc", "with_genres=16",
                                 "first_air_date.gte=2025-01-01", "first_air_date.lte=2025-12-31", "with_companies=2|3"])
    }

    @Test func newestStopsAtTodayAndTheRegionIsTheQuerysOrTheDeviceOnes() {
        #expect(request(TMDbDiscoverQuery(ordering: .newest)).items.suffix(1) == ["primary_release_date.lte=2026-10-12"])
        let providers = TMDbDiscoverQuery(providers: [.init(id: 8, name: "Netflix")])
        #expect(request(providers, region: "GB").items.suffix(2) == ["with_watch_providers=8", "watch_region=GB"])
        let chosen = TMDbDiscoverQuery(providers: [.init(id: 8, name: "Netflix")], region: "IE")
        #expect(request(chosen, region: "GB").items.contains("watch_region=IE"))
    }

    // MARK: Pages

    @Test func aMoviePageReadsTitlesDatesAndGenres() throws {
        let data = Data(#"""
        {"page":1,"total_pages":3,"total_results":41,"results":[
          {"id":603,"title":"The Matrix","overview":"  A hacker learns the truth.  ","poster_path":"/m.jpg","backdrop_path":"/mb.jpg",
           "release_date":"1999-03-30","genre_ids":[28,878],"vote_average":8.2,"vote_count":25000,"original_language":"en"}]}
        """#.utf8)
        let page = try TMDbDiscoverEntry.parsePage(data)
        #expect(page.totalPages == 3)
        #expect(page.entries == [TMDbDiscoverEntry(tmdbID: 603, title: "The Matrix", overview: "A hacker learns the truth.",
                                                           posterPath: "/m.jpg",
                                                   backdropPath: "/mb.jpg", date: "1999-03-30", genreIDs: [28, 878], voteAverage: 8.2,
                                                   voteCount: 25000, originalLanguage: "en")])
    }

    @Test func aSeriesPageReadsNamesAndFirstAirDates() throws {
        let data = Data(#"""
        {"page":1,"total_pages":1,"results":[{"id":1399,"name":"Game of Thrones","overview":"","poster_path":null,"backdrop_path":null,
          "first_air_date":"2011-04-17","genre_ids":[18],"vote_average":0,"vote_count":0,"original_language":"en"}]}
        """#.utf8)
        let page = try TMDbDiscoverEntry.parsePage(data)
        let show = try #require(page.entries.first)
        #expect(show.title == "Game of Thrones" && show.date == "2011-04-17" && show.overview.isEmpty)
        #expect(show.posterPath == nil && show.genreIDs == [18])
    }

    @Test func entriesWithoutATitleOrAUsableIDAreSkipped() throws {
        let data = Data(#"""
            {"total_pages":2,"results":[{"id":0,"title":"No id"},{"id":5,"title":"   "},{"id":6},
            {"id":7,"name":"Named","first_air_date":""}]}
            """#.utf8)
        let page = try TMDbDiscoverEntry.parsePage(data)
        #expect(page.totalPages == 2)
        #expect(page.entries.map(\.tmdbID) == [7] && page.entries.first?.title == "Named" && page.entries.first?.date == nil)
    }

    @Test func badJSONAndAnAnswerWithoutResultsThrowInvalidJSON() {
        #expect(throws: AddonError.invalidJSON) { try TMDbDiscoverEntry.parsePage(Data("not json".utf8)) }
        #expect(throws: AddonError.invalidJSON) { try TMDbDiscoverEntry.parsePage(Data(#"{"total_pages":2}"#.utf8)) }
    }

    // MARK: Trending filters

    private func entry(_ id: Int = 1, genres: [Int] = [], score: Double? = 7.5, votes: Int? = 900, language: String? = "en",
                       date: String? = "2026-10-01") -> TMDbDiscoverEntry {
        TMDbDiscoverEntry(tmdbID: id, title: "T\(id)", overview: "", posterPath: nil, backdropPath: nil, date: date, genreIDs: genres,
                          voteAverage: score, voteCount: votes, originalLanguage: language)
    }

    private func matches(_ entry: TMDbDiscoverEntry, _ query: TMDbDiscoverQuery) -> Bool {
        TMDbRatings.matchesTrendingFilters(entry, query: query, today: testToday, calendar: utc)
    }

    @Test func aTitleWithAnExcludedGenreIsLeftOut() {
        let family = TMDbDiscoverQuery(genres: [.init(id: 16, name: "Animation")], excludedGenres: [.init(id: 10751, name: "Family")])
        #expect(TMDbRatings.hasExcludedGenre(entry(1, genres: [16, 10751]), query: family))
        #expect(!TMDbRatings.hasExcludedGenre(entry(1, genres: [16, 18]), query: family))
        #expect(!TMDbRatings.hasExcludedGenre(entry(1, genres: [16, 10751]), query: TMDbDiscoverQuery(genres: [.init(id: 16, name: "Animation")])))
    }

    @Test func aGenreTheListNamesIsNeverLeftOut() {
        let named = [TMDbDiscoverQuery.Named(id: 16, name: "Animation"), TMDbDiscoverQuery.Named(id: 10751, name: "Family")]
        let both = TMDbDiscoverQuery(genres: named, excludedGenres: [.init(id: 10751, name: "Family")])
        #expect(!TMDbRatings.hasExcludedGenre(entry(1, genres: [16, 10751]), query: both))
        #expect(request(both).items.allSatisfy { !$0.hasPrefix("without_genres") })
    }

    @Test func anEntryWithNoFilterMatchesWhateverItLacks() {
        let trending = TMDbDiscoverQuery(ordering: .trendingThisWeek)
        #expect(matches(entry(score: nil, votes: nil, language: nil, date: nil), trending))
    }

    @Test func everySelectedGenreMustBeOnTheEntry() {
        let query = TMDbDiscoverQuery(ordering: .trendingThisWeek, genres: [.init(id: 16, name: "Animation")])
        #expect(matches(entry(genres: [16, 18]), query))
        #expect(!matches(entry(genres: [18]), query))
        let both = TMDbDiscoverQuery(ordering: .trendingThisWeek, genres: [.init(id: 16, name: "A"), .init(id: 18, name: "D")])
        #expect(!matches(entry(genres: [16]), both))
    }

    @Test func theScoreBoundsNeedAScore() {
        let minimum = TMDbDiscoverQuery(ordering: .trendingThisWeek, minimumScore: 7)
        #expect(matches(entry(score: 7.5), minimum) && !matches(entry(score: 6.9), minimum) && !matches(entry(score: nil), minimum))
        let maximum = TMDbDiscoverQuery(ordering: .trendingThisWeek, maximumScore: 8)
        #expect(!matches(entry(score: 8.5), maximum) && matches(entry(score: 8), maximum))
    }

    @Test func votesLanguageAndDatesAreChecked() {
        let votes = TMDbDiscoverQuery(ordering: .trendingThisWeek, minimumVotes: 1000)
        #expect(!matches(entry(votes: 900), votes) && !matches(entry(votes: nil), votes))
        let japanese = TMDbDiscoverQuery(ordering: .trendingThisWeek, language: "ja")
        #expect(matches(entry(language: "ja"), japanese) && !matches(entry(language: "en"), japanese)
                    && !matches(entry(language: nil), japanese))
        let lastMonth = TMDbDiscoverQuery(ordering: .trendingThisWeek, period: .lastMonth)
        #expect(matches(entry(date: "2026-09-20"), lastMonth) && !matches(entry(date: "2026-08-01"), lastMonth))
        #expect(!matches(entry(date: nil), lastMonth), "an entry without a date fails a date range")
        let released = TMDbDiscoverQuery(ordering: .trendingThisWeek, releasedFrom: "2026-10-01")
        #expect(matches(entry(date: "2026-10-01"), released) && !matches(entry(date: "2026-09-30"), released))
    }

    // MARK: Items

    @Test func aPageStartsAtSkipAndReadsOnlyThePagesItNeeds() async throws {
        let transport = tmdbStub(totalPages: 3, entries: pages(total: 50) { movieJSON($0) })
        let items = try await ratings(transport).discoverItems(TMDbDiscoverQuery(), limit: 3, skip: 22, defaultRegion: "US",
                                                               today: testToday, calendar: utc)
        #expect(items.map(\.name) == ["Movie 23", "Movie 24", "Movie 25"])
        #expect(items.map(\.id) == ["tt1000023", "tt1000024", "tt1000025"])
        #expect(listRequests(transport) == 2, "25 entries need two pages of 20")
    }

    @Test func aTitleListedOnTwoPagesAppearsOnce() async throws {
        // Page 2 repeats 15...20 from page 1, so 34 different titles are read.
        let transport = tmdbStub(totalPages: 2, entries: { page in
                    page == 1 ? (1...20).map { movieJSON($0) } : (15...34).map { movieJSON($0) }
                })
        let items = try await ratings(transport).discoverItems(TMDbDiscoverQuery(), limit: 30, skip: 0, defaultRegion: "US",
                                                               today: testToday, calendar: utc)
        #expect(items.count == 30 && Set(items.map(\.id)).count == 30)
        #expect(items.last?.name == "Movie 30")
    }

    @Test func entriesWithoutAnIMDbIDAreLeftOutWithoutBackfilling() async throws {
        let transport = tmdbStub(noIMDb: [2, 4], entries: pages(total: 20) { movieJSON($0) })
        let items = try await ratings(transport).discoverItems(TMDbDiscoverQuery(), limit: 5, skip: 0, defaultRegion: "US",
                                                               today: testToday, calendar: utc)
        #expect(items.map(\.name) == ["Movie 1", "Movie 3", "Movie 5"])
    }

    @Test func anIMDbLookupIsAskedOncePerTitleAcrossCalls() async throws {
        let transport = tmdbStub(entries: pages(total: 20) { movieJSON($0) })
        let client = ratings(transport)
        _ = try await client.discoverItems(TMDbDiscoverQuery(), limit: 5, skip: 0, defaultRegion: "US", today: testToday, calendar: utc)
        let again = try await client.discoverItems(TMDbDiscoverQuery(), limit: 5, skip: 0,
            defaultRegion: "US", today: testToday, calendar: utc)
        #expect(again.count == 5)
        #expect(externalIDRequests(transport) == 5, "each title is looked up once, however often it is listed")
        #expect(listRequests(transport) == 2, "the pages themselves are asked again")
    }

    @Test func aFailedLookupIsLeftOutOfTheAnswerAndAskedAgain() async throws {
        let transport = tmdbStub(failing: [3], entries: pages(total: 20) { movieJSON($0) })
        let client = ratings(transport)
        let first = try await client.discoverItems(TMDbDiscoverQuery(), limit: 5, skip: 0,
            defaultRegion: "US", today: testToday, calendar: utc)
        #expect(first.map(\.name) == ["Movie 1", "Movie 2", "Movie 4", "Movie 5"])
        _ = try await client.discoverItems(TMDbDiscoverQuery(), limit: 5, skip: 0, defaultRegion: "US", today: testToday, calendar: utc)
        #expect(externalIDRequests(transport, tmdbID: 3) == 2, "a failure is not remembered")
        #expect(externalIDRequests(transport, tmdbID: 1) == 1)
    }

    @Test func aTrendingQueryKeepsOnlyTheEntriesThatMatch() async throws {
        let transport = tmdbStub(totalPages: 1, entries: { _ in
            [movieJSON(1, genres: [16], score: 8), movieJSON(2, genres: [18], score: 8), movieJSON(3, genres: [16], score: 6),
             movieJSON(4, genres: [16], score: 7.5)]
        })
        let query = TMDbDiscoverQuery(ordering: .trendingThisWeek, genres: [.init(id: 16, name: "Animation")], minimumScore: 7)
        let items = try await ratings(transport).discoverItems(query, limit: 10, skip: 0,
            defaultRegion: "US", today: testToday, calendar: utc)
        #expect(items.map(\.name) == ["Movie 1", "Movie 4"])
        #expect(transport.requests.first?.url?.path == "/3/trending/movie/week")
    }

    @Test func aTrendingQueryReadsAtMostFiveMorePagesThanADiscoverQueryWould() async throws {
        let transport = tmdbStub(totalPages: 100, entries: pages(total: 2000) { movieJSON($0, genres: [18]) })
        let query = TMDbDiscoverQuery(ordering: .trendingToday, genres: [.init(id: 16, name: "Animation")])
        let items = try await ratings(transport).discoverItems(query, limit: 5, skip: 0,
            defaultRegion: "US", today: testToday, calendar: utc)
        #expect(items.isEmpty)
        #expect(listRequests(transport) == 6, "one page for five titles, plus five")
    }

    @Test func aMovieBecomesAMetaPreviewWithItsArtwork() async throws {
        let transport = tmdbStub(entries: pages(total: 3) { id in
            movieJSON(id, date: id == 3 ? "" : "1999-03-30")
        })
        let items = try await ratings(transport).discoverItems(TMDbDiscoverQuery(), limit: 3, skip: 0, defaultRegion: "US",
                                                               today: testToday, calendar: utc)
        let first = try #require(items.first)
        #expect(first.type == "movie" && first.name == "Movie 1" && first.id == "tt1000001")
        #expect(first.poster?.absoluteString == "https://image.tmdb.org/t/p/w500/p1.jpg")
        #expect(first.background?.absoluteString == "https://image.tmdb.org/t/p/w1280/b1.jpg")
        #expect(first.description == "About 1" && first.releaseInfo == "1999")
        #expect(items.last?.releaseInfo == nil, "no date means no year")
    }

    @Test func aSeriesBecomesASeriesPreviewWithItsFirstAirYear() async throws {
        let transport = tmdbStub(totalPages: 1, entries: { _ in [seriesJSON(7)] })
        let query = TMDbDiscoverQuery(kind: .series)
        let items = try await ratings(transport).discoverItems(query, limit: 5, skip: 0,
            defaultRegion: "US", today: testToday, calendar: utc)
        let show = try #require(items.first)
        #expect(show.type == "series" && show.name == "Show 7" && show.id == "tt1000007")
        #expect(show.poster == nil && show.description == nil, "an empty overview and a missing poster are nil")
        #expect(show.background?.absoluteString == "https://image.tmdb.org/t/p/w1280/s7.jpg" && show.releaseInfo == "2011")
        #expect(transport.requests.first?.url?.path == "/3/discover/tv")
    }

    @Test func noCredentialSendsNothing() async throws {
        let transport = StubTransport(data: Data())
        let client = TMDbRatings(client: makeClient(transport), readAccessToken: " ", imdbIDs: TMDbIMDbIDCache())
        let items = try await client.discoverItems(TMDbDiscoverQuery(), limit: 5, skip: 0, defaultRegion: "US")
        #expect(items.isEmpty && transport.callCount == 0)
    }

    // MARK: Editor lookups

    @Test func genresComeFromTheMovieOrSeriesList() async throws {
        let transport = StubTransport(data: Data(#"""
            {"genres":[{"id":16,"name":"Animation"},{"id":18,"name":"Drama"},
            {"id":0,"name":"Bad"}]}
            """#.utf8))
        let genres = try await ratings(transport).genres(kind: .series)
        #expect(genres == [.init(id: 16, name: "Animation"), .init(id: 18, name: "Drama")])
        #expect(transport.requests.first?.url?.path == "/3/genre/tv/list")
    }

    @Test func keywordSearchTrimsTheTextAndCapsTheList() async throws {
        let transport = StubTransport(data: Data(#"{"results":[{"id":210024,"name":"anime"}]}"#.utf8))
        let found = try await ratings(transport).searchKeywords("  anime  ")
        #expect(found == [.init(id: 210024, name: "anime")])
        let url = transport.requests.first?.url
        #expect(url?.path == "/3/search/keyword" && queryValue(url, "query") == "anime" && queryValue(url, "page") == "1")

        let many = (1...40).map { #"{"id":\#($0),"name":"K\#($0)"}"# }.joined(separator: ",")
        let capped = try await ratings(StubTransport(data: Data(#"{"results":[\#(many)]}"#.utf8))).searchKeywords("k")
        #expect(capped.count == 30)
    }

    @Test func peopleSearchExcludesAdultResults() async throws {
        let transport = StubTransport(data: Data(#"{"results":[{"id":525,"name":"Christopher Nolan"}]}"#.utf8))
        #expect(try await ratings(transport).searchPeople("nolan") == [.init(id: 525, name: "Christopher Nolan")])
        let url = transport.requests.first?.url
        #expect(url?.path == "/3/search/person" && queryValue(url, "include_adult") == "false")
    }

    @Test func companySearchAsksTheCompanyList() async throws {
        let transport = StubTransport(data: Data(#"{"results":[{"id":41077,"name":"A24"}]}"#.utf8))
        #expect(try await ratings(transport).searchCompanies("a24") == [.init(id: 41077, name: "A24")])
        #expect(transport.requests.first?.url?.path == "/3/search/company")
    }

    @Test func watchProvidersAreSortedByDisplayPriority() async throws {
        let transport = StubTransport(data: Data(#"""
        {"results":[{"provider_id":8,"provider_name":"Netflix","display_priority":2},
                    {"provider_id":337,"provider_name":"Disney Plus","display_priority":1},
                    {"provider_id":9,"provider_name":"Amazon Prime","display_priority":3}]}
        """#.utf8))
        let providers = try await ratings(transport).watchProviders(kind: .movie, region: "IE")
        #expect(providers.map(\.name) == ["Disney Plus", "Netflix", "Amazon Prime"])
        #expect(providers.first?.id == 337)
        let url = transport.requests.first?.url
        #expect(url?.path == "/3/watch/providers/movie" && queryValue(url, "watch_region") == "IE")
    }

    @Test func blankTextAndBlankRegionSendNothing() async throws {
        let transport = StubTransport(data: Data(#"{"results":[]}"#.utf8))
        let client = ratings(transport)
        #expect(try await client.searchKeywords("   ").isEmpty)
        #expect(try await client.searchPeople("").isEmpty)
        #expect(try await client.searchCompanies(" \n ").isEmpty)
        #expect(try await client.watchProviders(kind: .movie, region: " ").isEmpty)
        #expect(transport.callCount == 0)
    }
}
