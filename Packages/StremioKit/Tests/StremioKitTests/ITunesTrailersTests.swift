import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

@Suite struct ITunesTrailersTests {
    private func results(_ items: String) -> Data {
        Data(#"{"resultCount":\#(items.count),"results":[\#(items)]}"#.utf8)
    }

    @Test func theSearchAsksForTheMovieOrTheSeasonsInIreland() throws {
        let movie = try #require(ITunesTrailers.searchURL(title: "Inception", type: "movie"))
        #expect(movie.absoluteString == "https://itunes.apple.com/search?term=Inception&media=movie&entity=movie&country=ie")
        let series = try #require(ITunesTrailers.searchURL(title: "Breaking Bad", type: "series"))
        #expect(series.absoluteString == "https://itunes.apple.com/search?term=Breaking%20Bad&media=tvShow&entity=tvSeason&country=ie")
        #expect(ITunesTrailers.searchURL(title: "Inception", type: "channel") == nil)
    }

    @Test func aMovieMatchesItsExactNameNotALongerOne() throws {
        let data = results(#"""
        {"trackName":"Inception: Extra Scenes","releaseDate":"2010-07-16T07:00:00Z","previewUrl":"https://a.example.com/extra.m4v"},
        {"trackName":"Inception","releaseDate":"2010-07-16T07:00:00Z","previewUrl":"https://a.example.com/inception.m4v"}
        """#)
        let trailer = try ITunesTrailers.parse(data, title: "Inception", year: 2010, type: "movie")
        #expect(trailer?.directURL == URL(string: "https://a.example.com/inception.m4v"))
        #expect(trailer?.title == "Trailer" && trailer?.kind == .trailer && trailer?.isOfficial == true && trailer?.language == nil)
        #expect(trailer?.duration == nil)
    }

    @Test func namesMatchWithoutCaseAccentsOrPunctuation() throws {
        let data = results(#"{"trackName":"AMELIE!","previewUrl":"https://a.example.com/amelie.m4v"}"#)
        #expect(try ITunesTrailers.parse(data, title: "Amélie", year: nil, type: "movie")?.directURL != nil)
        #expect(try ITunesTrailers.parse(data, title: "Amelie 2", year: nil, type: "movie") == nil)
    }

    @Test func aKnownYearMustBeWithinOneYear() throws {
        let data = results(#"{"trackName":"Dune","releaseDate":"2021-10-22T07:00:00Z","previewUrl":"https://a.example.com/dune.m4v"}"#)
        #expect(try ITunesTrailers.parse(data, title: "Dune", year: 2020, type: "movie") != nil)
        #expect(try ITunesTrailers.parse(data, title: "Dune", year: 2022, type: "movie") != nil)
        #expect(try ITunesTrailers.parse(data, title: "Dune", year: 2024, type: "movie") == nil)
        #expect(try ITunesTrailers.parse(data, title: "Dune", year: nil, type: "movie") != nil, "no year known: the name alone matches")
    }

    @Test func onlyAnHTTPSPreviewCounts() throws {
        let data = results(#"{"trackName":"Dune","previewUrl":"http://a.example.com/dune.m4v"}"#)
        #expect(try ITunesTrailers.parse(data, title: "Dune", year: nil, type: "movie") == nil)
        #expect(try ITunesTrailers.parse(results(#"{"trackName":"Dune"}"#), title: "Dune", year: nil, type: "movie") == nil)
    }

    @Test func aSeriesTakesTheMatchForItsLowestSeason() throws {
        let data = results(#"""
        {"collectionName":"Show, Season 3","releaseDate":"2015-01-01T00:00:00Z","previewUrl":"https://a.example.com/s3.m4v"},
        {"collectionName":"Show - Season 1","releaseDate":"2010-01-01T00:00:00Z","previewUrl":"https://a.example.com/s1.m4v"},
        {"collectionName":"Show Extra, Season 1","releaseDate":"2010-01-01T00:00:00Z","previewUrl":"https://a.example.com/other.m4v"},
        {"collectionName":"Show, Season 2","releaseDate":"2012-01-01T00:00:00Z","previewUrl":"https://a.example.com/s2.m4v"}
        """#)
        let trailer = try ITunesTrailers.parse(data, title: "Show", year: nil, type: "series")
        #expect(trailer?.directURL == URL(string: "https://a.example.com/s1.m4v"))
    }

    @Test func noResultsOrAnotherTypeGiveNoTrailer() throws {
        #expect(try ITunesTrailers.parse(results(""), title: "Dune", year: nil, type: "movie") == nil)
        #expect(try ITunesTrailers.parse(results(#"{"trackName":"Dune","previewUrl":"https://a.example.com/d.m4v"}"#),
                                         title: "Dune", year: nil, type: "channel") == nil)
    }

    @Test func aBadAnswerIsInvalid() {
        #expect(throws: AddonError.self) { try ITunesTrailers.parse(Data("nope".utf8), title: "Dune", year: nil, type: "movie") }
        #expect(throws: AddonError.self) { try ITunesTrailers.parse(Data(#"{"resultCount":0}"#.utf8), title: "Dune", year: nil, type: "movie") }
    }

    @Test func aSearchIsSentOnceAndAnswersAreKeptIncludingNone() async throws {
        let transport = StubTransport(data: results(#"{"trackName":"Stub Ledger Film","previewUrl":"https://a.example.com/l.m4v"}"#))
        let itunes = ITunesTrailers(client: makeClient(transport, retries: 0), cache: ITunesTrailerCache())
        let first = try await itunes.preview(title: "Stub Ledger Film", year: nil, type: "movie")
        #expect(first?.directURL == URL(string: "https://a.example.com/l.m4v"))
        let again = try await itunes.preview(title: "stub ledger film!", year: nil, type: "movie")
        #expect(again == first)
        #expect(transport.callCount == 1, "the second title is answered from the session")
    }

    @Test func aTitleWithNoPreviewIsAlsoKept() async throws {
        let transport = StubTransport { request, _ in
            StubTransport.response(Data((isChart(request) ? #"{"feed":{}}"# : #"{"resultCount":0,"results":[]}"#).utf8), for: request)
        }
        let itunes = ITunesTrailers(client: makeClient(transport, retries: 0), cache: ITunesTrailerCache(), chartCache: ITunesChartCache())
        #expect(try await itunes.preview(title: "Nothing Here", year: nil, type: "movie") == nil)
        #expect(try await itunes.preview(title: "Nothing Here", year: nil, type: "movie") == nil)
        #expect(searches(transport) == 1, "the search is kept, nil included")
        #expect(chartRequests(transport) == 1, "the chart is downloaded once")
    }

    @Test func whenTheSearchFindsNothingTheCurrentChartIsUsedAndDownloadedOncePerType() async throws {
        let chart = Data(chartFixture.utf8)
        let transport = StubTransport { request, _ in
            StubTransport.response(isChart(request) ? chart : results(""), for: request)
        }
        let itunes = ITunesTrailers(client: makeClient(transport, retries: 0), cache: ITunesTrailerCache(), chartCache: ITunesChartCache())
        let toyStory = try await itunes.preview(title: "Toy Story 5", year: 2026, type: "movie")
        #expect(toyStory?.directURL == URL(string: "https://video-ssl.itunes.apple.com/toy5.m4v"))
        let oppenheimer = try await itunes.preview(title: "Oppenheimer", year: 2023, type: "movie")
        #expect(oppenheimer?.directURL == URL(string: "https://video-ssl.itunes.apple.com/oppenheimer.m4v"))
        #expect(searches(transport) == 2, "each title is searched first")
        #expect(chartRequests(transport) == 1, "the chart is downloaded once for both titles")
    }

    @Test func aSearchThatFindsAPreviewDoesNotReadTheChart() async throws {
        let transport = StubTransport(data: results(#"{"trackName":"Stub Ledger Film","previewUrl":"https://a.example.com/l.m4v"}"#))
        let itunes = ITunesTrailers(client: makeClient(transport, retries: 0), cache: ITunesTrailerCache(), chartCache: ITunesChartCache())
        #expect(try await itunes.preview(title: "Stub Ledger Film", year: nil, type: "movie") != nil)
        #expect(chartRequests(transport) == 0)
    }

    @Test func theChartsAreTheStoresTopFeedsForTheCountry() throws {
        #expect(ITunesTrailers.chartURL(type: "movie")?.absoluteString == "https://itunes.apple.com/ie/rss/topmovies/limit=200/json")
        #expect(ITunesTrailers.chartURL(type: "series")?.absoluteString == "https://itunes.apple.com/ie/rss/toptvseasons/limit=200/json")
        #expect(ITunesTrailers.chartURL(type: "channel") == nil)
    }

    @Test func aChartEntryMatchesByNameAndReleaseYearAndTakesAnArrayOfLinks() throws {
        let toyStory = try ITunesTrailers.parseChart(Data(chartFixture.utf8), title: "Toy Story 5", year: 2026, type: "movie")
        #expect(toyStory?.directURL == URL(string: "https://video-ssl.itunes.apple.com/toy5.m4v"), "the enclosure is taken from the link list")
        let oppenheimer = try ITunesTrailers.parseChart(Data(chartFixture.utf8), title: "oppenheimer", year: 2024, type: "movie")
        #expect(oppenheimer?.directURL == URL(string: "https://video-ssl.itunes.apple.com/oppenheimer.m4v"), "a year within one of the release")
    }

    @Test func aChartWithASingleEntryAsAnObjectIsRead() throws {
        let single = Data(#"""
        {"feed":{"entry":{"im:name":{"label":"Toy Story 5"},"im:releaseDate":{"label":"2026-06-19T00:00:00-07:00"},
         "link":{"attributes":{"rel":"enclosure","type":"video/x-m4v","href":"https://video-ssl.itunes.apple.com/toy5.m4v"}}}}}
        """#.utf8)
        let trailer = try ITunesTrailers.parseChart(single, title: "Toy Story 5", year: 2026, type: "movie")
        #expect(trailer?.directURL == URL(string: "https://video-ssl.itunes.apple.com/toy5.m4v"))
    }

    @Test func aChartEntryWithoutAMatchingNameOrYearOrAnHTTPSFileGivesNothing() throws {
        let data = Data(chartFixture.utf8)
        #expect(try ITunesTrailers.parseChart(data, title: "Missing Title", year: nil, type: "movie") == nil, "no entry has the name")
        #expect(try ITunesTrailers.parseChart(data, title: "Oppenheimer", year: 2010, type: "movie") == nil, "the release year is 2023")
        #expect(try ITunesTrailers.parseChart(data, title: "Dune", year: nil, type: "movie") == nil, "an http file is rejected")
        #expect(try ITunesTrailers.parseChart(data, title: "Heat", year: nil, type: "movie") == nil, "an entry with only a web page link is skipped")
        #expect(try ITunesTrailers.parseChart(data, title: "Toy Story 5", year: 2026, type: "channel") == nil)
    }

    @Test func aSeriesChartTakesTheLowestSeasonOfTheShow() throws {
        let data = Data(#"""
        {"feed":{"entry":[
         {"im:name":{"label":"Show - Season 2"},"im:releaseDate":{"label":"2024-01-01T00:00:00-07:00"},
          "link":{"attributes":{"rel":"enclosure","href":"https://video-ssl.itunes.apple.com/s2.m4v"}}},
         {"im:name":{"label":"Show, Season 1"},"im:releaseDate":{"label":"2023-01-01T00:00:00-07:00"},
          "link":{"attributes":{"rel":"enclosure","href":"https://video-ssl.itunes.apple.com/s1.m4v"}}}]}}
        """#.utf8)
        let trailer = try ITunesTrailers.parseChart(data, title: "Show", year: nil, type: "series")
        #expect(trailer?.directURL == URL(string: "https://video-ssl.itunes.apple.com/s1.m4v"))
    }

    @Test func aBadChartIsInvalid() {
        #expect(throws: AddonError.self) { try ITunesTrailers.parseChart(Data("nope".utf8), title: "Toy Story 5", year: nil, type: "movie") }
        #expect(throws: AddonError.self) { try ITunesTrailers.parseChart(Data(#"{"resultCount":0}"#.utf8), title: "X", year: nil, type: "movie") }
    }

    /// The store's current-films chart: three entries. "Toy Story 5" has a link list, "Oppenheimer" a single link object, "Dune" an http file,
    /// "Heat" only a web page.
    private let chartFixture = #"""
    {"feed":{"author":{"name":{"label":"iTunes Store"}},"entry":[
     {"im:name":{"label":"Toy Story 5"},"im:releaseDate":{"label":"2026-06-19T00:00:00-07:00","attributes":{"label":"2026-06-19T00:00:00-07:00"}},
      "link":[{"attributes":{"rel":"alternate","type":"text/html","href":"https://itunes.apple.com/ie/movie/toy-story-5/id1"}},
              {"attributes":{"rel":"enclosure","type":"video/x-m4v","href":"https://video-ssl.itunes.apple.com/toy5.m4v"}}]},
     {"im:name":{"label":"Oppenheimer"},"im:releaseDate":{"label":"2023-07-21T00:00:00-07:00"},
      "link":{"attributes":{"rel":"enclosure","type":"video/x-m4v","href":"https://video-ssl.itunes.apple.com/oppenheimer.m4v"}}},
     {"im:name":{"label":"Dune"},"im:releaseDate":{"label":"2024-03-01T00:00:00-07:00"},
      "link":{"attributes":{"rel":"enclosure","type":"video/x-m4v","href":"http://video-ssl.itunes.apple.com/dune.m4v"}}},
     {"im:name":{"label":"Heat"},"im:releaseDate":{"label":"1995-12-15T00:00:00-07:00"},
      "link":{"attributes":{"rel":"alternate","type":"text/html","href":"https://itunes.apple.com/ie/movie/heat/id2"}}}
    ]}}
    """#

    private func isChart(_ request: URLRequest) -> Bool { request.url?.path.hasPrefix("/ie/rss/") == true }

    private func searches(_ transport: StubTransport) -> Int { transport.requests.filter { $0.url?.path == "/search" }.count }

    private func chartRequests(_ transport: StubTransport) -> Int { transport.requests.filter(isChart).count }

    @Test func aTitleWithNoLettersIsNotSearched() async throws {
        let transport = StubTransport(data: results(""))
        let itunes = ITunesTrailers(client: makeClient(transport, retries: 0), cache: ITunesTrailerCache())
        #expect(try await itunes.preview(title: "!!!", year: nil, type: "movie") == nil)
        #expect(transport.callCount == 0)
    }
}
