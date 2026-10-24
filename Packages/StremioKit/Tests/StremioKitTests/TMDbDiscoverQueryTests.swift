import Foundation
import Testing
@testable import StremioKit

/// Gregorian UTC, so date arithmetic is the same on every machine.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
}()

private let testToday = utc.date(from: DateComponents(year: 2026, month: 10, day: 12)) ?? Date(timeIntervalSince1970: 0)

/// A query with every filter set, so each filter's support and clearing can be checked.
private func fullQuery(kind: TMDbDiscoverQuery.Kind = .movie, ordering: TMDbDiscoverQuery.Ordering = .popular) -> TMDbDiscoverQuery {
    TMDbDiscoverQuery(kind: kind, ordering: ordering, period: .lastYear, genres: [.init(id: 16, name: "Animation")],
                      keywords: [.init(id: 1, name: "anime")], excludedKeywords: [.init(id: 2, name: "remake")], minimumScore: 7,
                      maximumScore: 9, minimumVotes: 500, language: "ja", minimumRuntime: 60, maximumRuntime: 120,
                      releasedFrom: "2020-01-01", releasedTo: "2020-12-31", providers: [.init(id: 8, name: "Netflix")], region: "IE",
                      cast: [.init(id: 3, name: "Actor")], crew: [.init(id: 4, name: "Director")],
                          companies: [.init(id: 5, name: "Studio")])
}

/// Sets one filter to a value, for the tests that walk every filter.
private func setting(_ filter: TMDbDiscoverQuery.Filter) -> TMDbDiscoverQuery {
    var query = TMDbDiscoverQuery()
    switch filter {
    case .period: query.period = .thisYear
    case .genres: query.genres = [.init(id: 16, name: "Animation")]
    case .keywords: query.keywords = [.init(id: 1, name: "anime")]
    case .excludedKeywords: query.excludedKeywords = [.init(id: 2, name: "remake")]
    case .score: query.minimumScore = 7
    case .votes: query.minimumVotes = 100
    case .language: query.language = "fr"
    case .runtime: query.maximumRuntime = 90
    case .release: query.releasedTo = "2021-01-01"
    case .providers: query.providers = [.init(id: 8, name: "Netflix")]
    case .region: query.region = "GB"
    case .cast: query.cast = [.init(id: 3, name: "Actor")]
    case .crew: query.crew = [.init(id: 4, name: "Director")]
    case .companies: query.companies = [.init(id: 5, name: "Studio")]
    }
    return query
}

@Suite struct TMDbDiscoverQueryTests {
    // MARK: Codable

    @Test func aQueryRoundTripsThroughJSON() throws {
        let query = fullQuery(kind: .series, ordering: .newest)
        let data = try JSONEncoder().encode(query)
        #expect(try JSONDecoder().decode(TMDbDiscoverQuery.self, from: data) == query)
    }

    @Test func anEmptyObjectDecodesToTheDefaults() throws {
        #expect(try JSONDecoder().decode(TMDbDiscoverQuery.self, from: Data("{}".utf8)) == TMDbDiscoverQuery())
        #expect(TMDbDiscoverQuery().kind == .movie && TMDbDiscoverQuery().ordering == .popular)
    }

    @Test func unknownRawValuesFallBackToTheDefaults() throws {
        let text = #"{"kind":"podcast","ordering":"sideways","period":"lastCentury","genres":[{"id":16,"name":"Animation"}]}"#
        let query = try JSONDecoder().decode(TMDbDiscoverQuery.self, from: Data(text.utf8))
        #expect(query.kind == .movie)
        #expect(query.ordering == .popular)
        #expect(query.period == nil)
        #expect(query.genres == [.init(id: 16, name: "Animation")], "the rest of the file still decodes")
    }

    @Test func excludedGenresRoundTripAndAreNotWrittenWhenEmpty() throws {
        // Snapshot file names and Fusion exports are made from this encoding, so a list that leaves no genre out keeps its keys.
        let plain = String(decoding: try JSONEncoder().encode(TMDbDiscoverQuery(genres: [.init(id: 16, name: "Animation")])), as: UTF8.self)
        #expect(!plain.contains("excludedGenres"))
        let excluded = TMDbDiscoverQuery(genres: [.init(id: 16, name: "Animation")], excludedGenres: [.init(id: 10751, name: "Family")])
        #expect(String(decoding: try JSONEncoder().encode(excluded), as: UTF8.self).contains("\"excludedGenres\""))
        #expect(try JSONDecoder().decode(TMDbDiscoverQuery.self, from: JSONEncoder().encode(excluded)) == excluded)
        #expect(try JSONDecoder().decode(TMDbDiscoverQuery.self, from: Data("{}".utf8)).excludedGenres.isEmpty)
    }

    @Test func aFileFromANewerVersionWithExtraKeysStillDecodes() throws {
        let text = #"{"kind":"series","ordering":"oldest","futureFilter":{"x":1},"minimumScore":6.5}"#
        let query = try JSONDecoder().decode(TMDbDiscoverQuery.self, from: Data(text.utf8))
        #expect(query.kind == .series && query.ordering == .oldest && query.minimumScore == 6.5)
    }

    // MARK: Support

    @Test func trendingListsTakeOnlyTheFiltersTheAppAppliesItself() {
        let trending = TMDbDiscoverQuery(ordering: .trendingThisWeek)
        let supported: Set<TMDbDiscoverQuery.Filter> = [.period, .genres, .score, .votes, .language, .release]
        for filter in TMDbDiscoverQuery.Filter.allCases {
            #expect(trending.supports(filter) == supported.contains(filter), "trending support for \(filter)")
        }
        #expect(TMDbDiscoverQuery(ordering: .trendingToday).isTrending)
        #expect(!TMDbDiscoverQuery(ordering: .newest).isTrending)
    }

    @Test func seriesCannotFilterByPerson() {
        let series = TMDbDiscoverQuery(kind: .series)
        #expect(!series.supports(.cast) && !series.supports(.crew))
        #expect(series.supports(.companies) && series.supports(.keywords) && series.supports(.runtime))
        let movie = TMDbDiscoverQuery(kind: .movie)
        #expect(movie.supports(.cast) && movie.supports(.crew))
    }

    @Test func theRegionIsSupportedExactlyWhenProvidersAre() {
        for ordering in TMDbDiscoverQuery.Ordering.allCases {
            for kind in TMDbDiscoverQuery.Kind.allCases {
                let query = TMDbDiscoverQuery(kind: kind, ordering: ordering)
                #expect(query.supports(.region) == query.supports(.providers))
            }
        }
    }

    @Test func removingUnsupportedFiltersKeepsOnlyWhatTheQueryCanUse() {
        let trending = fullQuery(ordering: .trendingToday).removingUnsupportedFilters()
        #expect(trending.genres == [.init(id: 16, name: "Animation")] && trending.minimumScore == 7 && trending.language == "ja")
        #expect(trending.keywords.isEmpty && trending.providers.isEmpty && trending.region == nil && trending.minimumRuntime == nil)
        #expect(trending.cast.isEmpty && trending.companies.isEmpty)

        let series = fullQuery(kind: .series).removingUnsupportedFilters()
        #expect(series.cast.isEmpty && series.crew.isEmpty)
        #expect(series.companies == [.init(id: 5, name: "Studio")] && series.region == "IE")

        let movie = fullQuery()
        #expect(movie.removingUnsupportedFilters() == movie, "nothing is cleared when everything is supported")
    }

    // MARK: Filters

    @Test func everyFilterReportsWhetherItIsSetAndClearsBack() {
        #expect(!TMDbDiscoverQuery().isSet(.period), "a default query sets no filter")
        for filter in TMDbDiscoverQuery.Filter.allCases {
            var query = setting(filter)
            #expect(query.isSet(filter), "\(filter) is set once it has a value")
            query.clear(filter)
            #expect(!query.isSet(filter), "\(filter) is not set after clearing")
            #expect(query == TMDbDiscoverQuery(), "clearing \(filter) returns the query to its default")
        }
    }

    @Test func scoreRuntimeAndReleaseClearBothBounds() {
        var query = fullQuery()
        query.clear(.score)
        #expect(query.minimumScore == nil && query.maximumScore == nil)
        query.clear(.runtime)
        #expect(query.minimumRuntime == nil && query.maximumRuntime == nil)
        query.clear(.release)
        #expect(query.releasedFrom == nil && query.releasedTo == nil)
        #expect(query.genres.count == 1, "other filters are untouched")
    }

    // MARK: Titles

    @Test func titleNamesTheOrderingTheGenreAndTheKind() {
        #expect(TMDbDiscoverQuery().title == "Popular Movies")
        #expect(TMDbDiscoverQuery(kind: .series, ordering: .trendingToday).title == "Trending Series Today")
        let animation = TMDbDiscoverQuery(ordering: .newest, genres: [.init(id: 16, name: "Animation")])
        #expect(animation.title == "Newest Animation Movies")
        #expect(TMDbDiscoverQuery(ordering: .trendingThisWeek).title == "Trending Movies This Week")
    }

    @Test func summaryCountsFiltersOtherThanGenres() {
        #expect(TMDbDiscoverQuery().summary == "TMDB · Popular Movies")
        let genreOnly = TMDbDiscoverQuery(genres: [.init(id: 16, name: "Animation")])
        #expect(genreOnly.summary == "TMDB · Popular Animation Movies", "a genre is part of the title, not a filter count")
        let one = TMDbDiscoverQuery(minimumVotes: 100)
        #expect(one.summary == "TMDB · Popular Movies · 1 filter")
        let two = TMDbDiscoverQuery(keywords: [.init(id: 1, name: "anime")], minimumVotes: 100)
        #expect(two.summary == "TMDB · Popular Movies · 2 filters")
    }

    @Test func everyOrderingAndPeriodHasATitle() {
        #expect(TMDbDiscoverQuery.Ordering.allCases.map(\.title) == ["Popular", "Trending Today", "Trending This Week", "Newest", "Oldest"])
        #expect(TMDbDiscoverQuery.Period.allCases.map(\.title)
            == ["Last Month", "Last 3 Months", "This Year", "Last Year", "Last 5 Years", "Last 10 Years"])
        #expect(TMDbDiscoverQuery.Kind.movie.title == "Movies" && TMDbDiscoverQuery.Kind.series.noun == "series")
    }

    // MARK: Dates

    @Test func eachPeriodIsAWindowEndingToday() {
        func range(_ period: TMDbDiscoverQuery.Period) -> [String?] {
            let range = TMDbDiscoverQuery(period: period).dateRange(today: testToday, calendar: utc)
            return [range.from, range.to]
        }
        #expect(range(.lastMonth) == ["2026-09-12", "2026-10-12"])
        #expect(range(.last3Months) == ["2026-07-14", "2026-10-12"])
        #expect(range(.thisYear) == ["2026-01-01", "2026-10-12"])
        #expect(range(.lastYear) == ["2025-01-01", "2025-12-31"])
        #expect(range(.last5Years) == ["2021-10-12", "2026-10-12"])
        #expect(range(.last10Years) == ["2016-10-12", "2026-10-12"])
    }

    @Test func explicitDatesTakeThePlaceOfThePeriod() {
        let query = TMDbDiscoverQuery(period: .lastMonth, releasedFrom: "2020-01-01")
        let range = query.dateRange(today: testToday, calendar: utc)
        #expect(range.from == "2020-01-01" && range.to == nil, "the dates are the answer as they are")
    }

    @Test func newestWithNothingSetStopsAtToday() {
        let newest = TMDbDiscoverQuery(ordering: .newest).dateRange(today: testToday, calendar: utc)
        #expect(newest.from == nil && newest.to == "2026-10-12")
        let popular = TMDbDiscoverQuery(ordering: .popular).dateRange(today: testToday, calendar: utc)
        #expect(popular.from == nil && popular.to == nil)
    }

    @Test func datesAreReadInTheCalendarsTimeZone() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        // 02:00 UTC on 12 October is still 11 October in New York.
        let lateUTC = try #require(utc.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 2)))
        #expect(TMDbDiscoverQuery(ordering: .newest).dateRange(today: lateUTC, calendar: newYork).to == "2026-10-11")
    }
}
