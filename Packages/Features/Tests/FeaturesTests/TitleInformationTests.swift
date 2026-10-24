import Foundation
import Testing
import StremioKit
@testable import Features

/// The rows of a title page's Information.
@Suite struct TitleInformationTests {
    private func labels(_ rows: [TitleInformation.Row]) -> [String] { rows.map(\.label) }

    @Test func aMovieShowsEverythingTMDbAndTheAddonKnow() {
        let detail = MetaDetail(preview: MetaPreview(id: "tt1375666", type: "movie", name: "Inception", releaseInfo: "2010",
                                                     genres: ["Action", "Sci-Fi"], runtime: "148 min"),
                                director: ["Christopher Nolan"], writers: ["Christopher Nolan"])
        let facts = TMDbTitleFacts(studios: ["Legendary Pictures", "Syncopy", "Warner Bros.", "Fourth"], countries: ["United Kingdom", "United States of America"],
                                   originalLanguage: "English", status: "Released", budget: 160_000_000, revenue: 836_836_967,
                                   releaseDate: "2010-07-15")
        let rows = TitleInformation.rows(detail: detail, facts: facts, certification: "PG-13", averageRating: "87/100")
        #expect(labels(rows) == ["Released", "Runtime", "Genres", "Director", "Writers", "Studios", "Countries", "Original language",
                                 "Budget", "Box office", "Age rating", "Average rating"])
        #expect(rows.first { $0.label == "Studios" }?.value == "Legendary Pictures, Syncopy, Warner Bros.", "at most three")
        #expect(rows.first { $0.label == "Budget" }?.value == "$160M")
        #expect(rows.first { $0.label == "Box office" }?.value.hasPrefix("$836") == true)
        #expect(rows.first { $0.label == "Released" }?.value.contains("2010") == true)
        #expect(!labels(rows).contains("Status"), "a released movie's status says nothing")
    }

    @Test func aSeriesShowsItsRunNetworkAndCreators() {
        let detail = MetaDetail(preview: MetaPreview(id: "tt5753856", type: "series", name: "Dark", releaseInfo: "2017-2020"))
        let ended = TMDbTitleFacts(networks: ["Netflix"], creators: ["Baran bo Odar", "Jantje Friese"], status: "Ended",
                                   firstAired: "2017-12-01", lastAired: "2020-06-27", seasonCount: 3, episodeCount: 26)
        let rows = TitleInformation.rows(detail: detail, facts: ended, certification: nil, averageRating: nil)
        #expect(labels(rows) == ["First aired", "Last aired", "Creators", "Network", "Seasons", "Status"])
        #expect(rows.first { $0.label == "Seasons" }?.value == "3 seasons, 26 episodes")
        var running = ended
        running.status = "Returning Series"
        #expect(!labels(TitleInformation.rows(detail: detail, facts: running, certification: nil, averageRating: nil)).contains("Last aired"))
    }

    @Test func aSeriesWithoutTMDbKeepsTheAddonsReleaseLine() {
        let detail = MetaDetail(preview: MetaPreview(id: "tt5753856", type: "series", name: "Dark", releaseInfo: "2017-2020"))
        #expect(TitleInformation.rows(detail: detail, facts: nil, certification: nil, averageRating: nil)
                    == [TitleInformation.Row(label: "Released", value: "2017-2020")], "a range is not a first air date")
    }

    @Test func moneyRoundsUpToTheNextUnit() {
        let detail = MetaDetail(preview: MetaPreview(id: "tt1", type: "movie", name: "Film"))
        let rows = TitleInformation.rows(detail: detail, facts: TMDbTitleFacts(budget: 999_950_000, revenue: 4_500), certification: nil,
                                         averageRating: nil)
        #expect(rows.first { $0.label == "Budget" }?.value == "$1B")
        #expect(rows.first { $0.label == "Box office" }?.value == "$4.5K")
    }

    @Test func withoutTMDbTheAddonsRowsAreAsBefore() {
        let detail = MetaDetail(preview: MetaPreview(id: "tt1", type: "movie", name: "Film", releaseInfo: "1999", runtime: "90 min"),
                                director: ["Someone"])
        let rows = TitleInformation.rows(detail: detail, facts: nil, certification: nil, averageRating: nil)
        #expect(rows == [TitleInformation.Row(label: "Released", value: "1999"), TitleInformation.Row(label: "Runtime", value: "90 min"),
                         TitleInformation.Row(label: "Director", value: "Someone")])
    }
}
