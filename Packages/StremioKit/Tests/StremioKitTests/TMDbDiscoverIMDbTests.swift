import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

private let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ0ZXN0In0.signature"

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
}()

private let testToday = utc.date(from: DateComponents(year: 2026, month: 10, day: 12)) ?? Date(timeIntervalSince1970: 0)

/// IMDb's ratings on the device, with the ids it was asked for.
private actor RatingsOnDevice: IMDbDataset {
    let ratings: [String: IMDbRating]
    private(set) var lookups: [String] = []

    init(_ ratings: [String: IMDbRating]) { self.ratings = ratings }

    func rating(for imdbID: String) -> IMDbRating? {
        lookups.append(imdbID)
        return ratings[imdbID]
    }

    func status() -> IMDbDatasetStatus? { IMDbDatasetStatus(titleCount: ratings.count, updatedAt: nil, checkedAt: nil) }
    func refreshIfNeeded() -> IMDbDatasetRefresh { .skipped }
}

/// The IMDb id the stub gives TMDb title `id`.
private func imdbID(_ id: Int) -> String { "tt\(1_000_000 + id)" }

/// IMDb's rating of TMDb title `id`.
private func rated(_ id: Int, _ score: Double, votes: Int = 50_000) -> (String, IMDbRating) {
    (imdbID(id), IMDbRating(imdbID: imdbID(id), rating: score, votes: votes))
}

/// TMDb's discover and trending pages of `total` movies, 20 to a page, each with TMDb's score `score`, and their IMDb ids.
private func stub(total: Int, score: Double = 5) -> StubTransport {
    StubTransport { request, _ in
        let path = request.url?.path ?? ""
        if path.hasPrefix("/3/discover/") || path.hasPrefix("/3/trending/") {
            let page = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value ?? "") ?? 1
            let first = (page - 1) * 20 + 1
            let ids = first <= total ? Array(first...min(first + 19, total)) : []
            let entries = ids.map { id in
                #"{"id":\#(id),"title":"Movie \#(id)","overview":"","poster_path":"/p\#(id).jpg","backdrop_path":"/b\#(id).jpg","#
                    + #""release_date":"2020-01-02","genre_ids":[18],"vote_average":\#(score),"vote_count":40,"original_language":"en"}"#
            }
            let body = #"{"page":\#(page),"total_pages":\#((total + 19) / 20),"results":[\#(entries.joined(separator: ","))]}"#
            return StubTransport.response(Data(body.utf8), for: request)
        }
        let parts = path.split(separator: "/")
        if parts.count == 4, parts[3] == "external_ids", let id = Int(parts[2]) {
            return StubTransport.response(Data(#"{"imdb_id":"\#(imdbID(id))"}"#.utf8), for: request)
        }
        return StubTransport.response(Data(), status: 500, for: request)
    }
}

/// The `name=value` items of the first list request.
private func listItems(_ transport: StubTransport) -> [String] {
    let request = transport.requests.first { ($0.url?.path ?? "").hasPrefix("/3/discover/") || ($0.url?.path ?? "").hasPrefix("/3/trending/") }
    return URLComponents(url: request?.url ?? URL(string: "https://x")!, resolvingAgainstBaseURL: false)?.queryItems?
        .map { "\($0.name)=\($0.value ?? "")" } ?? []
}

private func externalIDRequests(_ transport: StubTransport) -> Int {
    transport.requests.filter { ($0.url?.path ?? "").hasSuffix("/external_ids") }.count
}

/// A widget's score and votes are IMDb's once its dataset is on the device; a search's list keeps TMDb's.
@Suite struct TMDbDiscoverIMDbTests {
    private func ratings(_ transport: StubTransport) -> TMDbRatings {
        TMDbRatings(client: makeClient(transport), readAccessToken: jwt, titleIDs: TMDbTitleIDCache(), imdbIDs: TMDbIMDbIDCache())
    }

    private func items(_ query: TMDbDiscoverQuery, _ transport: StubTransport, imdb: (any IMDbDataset)?, limit: Int = 10,
                       skip: Int = 0) async throws -> [String] {
        try await ratings(transport).discoverItems(query, limit: limit, skip: skip, defaultRegion: "US", today: testToday, calendar: utc,
                                                   imdb: imdb).map(\.name)
    }

    @Test func aWidgetsScoreIsIMDbsRating() async throws {
        let imdb = RatingsOnDevice(Dictionary(uniqueKeysWithValues: [rated(1, 7.5), rated(2, 6.9), rated(4, 8), rated(5, 7), rated(6, 9.5)]))
        let transport = stub(total: 6)
        let shown = try await items(TMDbDiscoverQuery(minimumScore: 7, maximumScore: 9), transport, imdb: imdb)
        #expect(shown == ["Movie 1", "Movie 4", "Movie 5"], "6.9 and 9.5 are out of bounds, and a title IMDb has no rating for is left out")
        let asked = listItems(transport)
        #expect(asked.contains("vote_average.gte=6.0"), "TMDb is asked within a point of the bounds")
        #expect(!asked.contains { $0.hasPrefix("vote_average.lte") }, "a point above 9 is no bound")
    }

    @Test func aWidgetsVotesAreIMDbs() async throws {
        let imdb = RatingsOnDevice(Dictionary(uniqueKeysWithValues: [rated(1, 7, votes: 9_999), rated(2, 7, votes: 10_000), rated(3, 7, votes: 400_000)]))
        let transport = stub(total: 3)
        #expect(try await items(TMDbDiscoverQuery(minimumVotes: 10_000), transport, imdb: imdb) == ["Movie 2", "Movie 3"])
        #expect(listItems(transport).contains("vote_count.gte=100"), "TMDb counts far fewer votes, so it is asked for a hundredth")
        #expect(!listItems(transport).contains { $0.hasPrefix("vote_average") })
    }

    @Test func untilTheDatasetIsOnTheDeviceTheScoreIsTMDbs() async throws {
        let transport = stub(total: 3)
        let shown = try await items(TMDbDiscoverQuery(minimumScore: 7, minimumVotes: 100), transport, imdb: RatingsOnDevice([:]))
        #expect(shown == ["Movie 1", "Movie 2", "Movie 3"], "TMDb applied the bounds itself")
        #expect(listItems(transport).contains("vote_average.gte=7.0") && listItems(transport).contains("vote_count.gte=100"))
    }

    @Test func aSearchsListKeepsTMDbsScores() async throws {
        let imdb = RatingsOnDevice(Dictionary(uniqueKeysWithValues: [rated(1, 2)]))
        let transport = stub(total: 2)
        var query = TMDbDiscoverQuery(minimumScore: 7, minimumVotes: 300)
        query.usesTMDbScores = true
        #expect(try await items(query, transport, imdb: imdb) == ["Movie 1", "Movie 2"])
        #expect(listItems(transport).contains("vote_average.gte=7.0") && listItems(transport).contains("vote_count.gte=300"))
        #expect(await imdb.lookups.isEmpty)
    }

    @Test func aListWithoutScoreOrVotesIsAsBefore() async throws {
        let imdb = RatingsOnDevice(Dictionary(uniqueKeysWithValues: [rated(1, 2)]))
        let transport = stub(total: 2)
        #expect(try await items(TMDbDiscoverQuery(), transport, imdb: imdb) == ["Movie 1", "Movie 2"])
        #expect(await imdb.lookups.isEmpty)
    }

    @Test func aTrendingListIsCheckedAgainstIMDbNotTMDb() async throws {
        let imdb = RatingsOnDevice(Dictionary(uniqueKeysWithValues: [rated(1, 8), rated(2, 5)]))
        let transport = stub(total: 2, score: 3)
        #expect(try await items(TMDbDiscoverQuery(ordering: .trendingThisWeek, minimumScore: 7), transport, imdb: imdb) == ["Movie 1"])
    }

    @Test func onlyTheIMDbIDsNeededAreLookedUpAndSkipCountsMatchingTitles() async throws {
        let all = (1...60).map { rated($0, $0.isMultiple(of: 2) ? 8 : 5) }
        let imdb = RatingsOnDevice(Dictionary(uniqueKeysWithValues: all))
        let transport = stub(total: 60)
        #expect(try await items(TMDbDiscoverQuery(minimumScore: 7), transport, imdb: imdb, limit: 2) == ["Movie 2", "Movie 4"])
        #expect(externalIDRequests(transport) == 6, "one batch of six finds both")
        let later = stub(total: 60)
        #expect(try await items(TMDbDiscoverQuery(minimumScore: 7), later, imdb: imdb, limit: 3, skip: 12) == ["Movie 26", "Movie 28", "Movie 30"])
    }

    @Test func atMostFiveMorePagesAreReadToFindEnough() async throws {
        let transport = stub(total: 400)
        let imdb = RatingsOnDevice(Dictionary(uniqueKeysWithValues: [rated(999, 9)]))
        #expect(try await items(TMDbDiscoverQuery(minimumScore: 7), transport, imdb: imdb, limit: 5).isEmpty)
        let pages = transport.requests.filter { ($0.url?.path ?? "").hasPrefix("/3/discover/") }.count
        #expect(pages == 6, "one page for five titles, plus five")
    }

    @Test func theLoosenedBoundsStayWithinTMDbsScale() {
        func asked(_ query: TMDbDiscoverQuery) -> [String] {
            TMDbRatings.discoverRequest(query, page: 1, defaultRegion: "US", today: testToday, calendar: utc, scoresOnIMDb: true).query
                .map { "\($0.name)=\($0.value ?? "")" }.filter { $0.hasPrefix("vote_") }
        }
        #expect(asked(TMDbDiscoverQuery(minimumScore: 7.5, maximumScore: 8)) == ["vote_average.gte=6.5", "vote_average.lte=9.0"])
        #expect(asked(TMDbDiscoverQuery(minimumScore: 0.5, maximumScore: 9.5, minimumVotes: 5_000)) == ["vote_count.gte=50"])
        #expect(asked(TMDbDiscoverQuery(ordering: .newest, minimumVotes: 50)) == ["vote_count.gte=1"],
                "a list sorted by date keeps a vote floor, so it is not filled with titles nobody rated")
    }

    @Test func theTMDbFlagIsWrittenOnlyWhenSetAndASearchSetsIt() throws {
        let widget = TMDbDiscoverQuery(minimumScore: 7)
        #expect(!String(decoding: try JSONEncoder().encode(widget), as: UTF8.self).contains("usesTMDbScores"))
        let search = DescribedSearch(minimumScore: 7).query(keywords: [])
        #expect(search.usesTMDbScores)
        #expect(try JSONDecoder().decode(TMDbDiscoverQuery.self, from: JSONEncoder().encode(search)) == search)
    }
}
