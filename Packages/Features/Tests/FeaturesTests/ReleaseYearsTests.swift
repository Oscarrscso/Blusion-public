import Foundation
import StremioKit
import Testing
@testable import Features

/// The release filter picks whole years; widgets saved with other days keep them until the filter is changed.
@Suite struct ReleaseYearsTests {
    @Test func aYearIsTheWholeCalendarYear() {
        #expect(ReleaseYears.from(2015) == "2015-01-01", "From is the year's first day")
        #expect(ReleaseYears.to(2015) == "2015-12-31", "To is its last")
        #expect(ReleaseYears.from(1874) == "1874-01-01")
        #expect(ReleaseYears.to(2036) == "2036-12-31")
    }

    @Test func theYearPickedAndTheDateSavedAgree() {
        for year in [1874, 1999, 2000, 2024] {
            #expect(ReleaseYears.year(of: ReleaseYears.from(year)) == year)
            #expect(ReleaseYears.year(of: ReleaseYears.to(year)) == year)
        }
    }

    /// Picking the year a saved date already shows keeps its day; another year saves that year's first or last day.
    @Test func onlyAnotherYearRewritesASavedDate() {
        #expect(ReleaseYears.edit(shown: 2010, picked: 2010, date: ReleaseYears.from) == nil)
        #expect(ReleaseYears.edit(shown: 2010, picked: 2012, date: ReleaseYears.from) == "2012-01-01")
        #expect(ReleaseYears.edit(shown: 2020, picked: 2018, date: ReleaseYears.to) == "2018-12-31")
    }

    @Test func aSavedDateShowsItsYear() {
        #expect(ReleaseYears.year(of: "2010-05-01") == 2010)
        #expect(ReleaseYears.year(of: "1999-12-31") == 1999)
        #expect(ReleaseYears.year(of: nil) == nil)
        #expect(ReleaseYears.year(of: "2010") == nil, "only a whole date is read")
        #expect(ReleaseYears.year(of: "soon") == nil)
    }

    @Test func theYearsOfferedRunFromTheFirstFilmsToTenYearsAheadNewestFirst() throws {
        let now = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 16)))
        let years = ReleaseYears.offered(now: now)
        #expect(years.first == 2036)
        #expect(years.last == 1874)
        #expect(years == years.sorted(by: >))
        #expect(years.count == 2036 - 1874 + 1)
    }

    @Test func aSavedYearOutsideThemIsOfferedToo() throws {
        let now = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 1, day: 1)))
        #expect(ReleaseYears.offered(now: now, including: 1850).last == 1850)
        #expect(ReleaseYears.offered(now: now, including: 2050).first == 2050)
        #expect(ReleaseYears.offered(now: now, including: 2000).filter { $0 == 2000 }.count == 1)
    }

    @Test func theDescriptionSaysYears() {
        #expect(ReleaseYears.text(from: "2010-01-01", to: "2020-12-31") == "2010 to 2020")
        #expect(ReleaseYears.text(from: "2015-01-01", to: "2015-12-31") == "in 2015")
        #expect(ReleaseYears.text(from: "2010-05-01", to: nil) == "from 2010")
        #expect(ReleaseYears.text(from: nil, to: "2020-12-31") == "up to 2020")
        #expect(ReleaseYears.text(from: nil, to: nil) == nil)
    }

    /// A widget saved with days of its own, imported ones included, keeps them: TMDB is asked for exactly the same dates.
    @Test func aSavedWidgetLoadsUnchanged() throws {
        let saved = TMDbDiscoverQuery(kind: .movie, releasedFrom: "2010-05-01", releasedTo: "2020-06-15")
        let loaded = try JSONDecoder().decode(TMDbDiscoverQuery.self, from: JSONEncoder().encode(saved))
        #expect(loaded == saved)
        #expect(loaded.releasedFrom == "2010-05-01")
        #expect(loaded.releasedTo == "2020-06-15")
        let range = loaded.dateRange(today: Date(), calendar: Calendar(identifier: .gregorian))
        #expect(range.from == "2010-05-01" && range.to == "2020-06-15")
        #expect(ReleaseYears.year(of: loaded.releasedFrom) == 2010 && ReleaseYears.year(of: loaded.releasedTo) == 2020)
    }
}
