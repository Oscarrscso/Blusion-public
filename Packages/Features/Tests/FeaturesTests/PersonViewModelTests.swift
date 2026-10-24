import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

@MainActor
@Suite struct PersonViewModelTests {
    /// Noon on 2026-10-09, UTC: the same calendar day in any time zone from UTC-12 to UTC+11.
    private let today = Date(timeIntervalSince1970: 1_791_547_200)

    private func makeModel(_ credits: [TMDbPersonCredit]) -> PersonViewModel {
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: 1, maxRetries: 0))
        let services = AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client), client: client)
        let model = PersonViewModel(destination: PersonDestination(id: 1, name: "Person", profile: nil), services: services, today: { [today] in today })
        model.credits = credits
        return model
    }

    private func credit(_ id: Int, _ title: String, date: String?, movie: Bool = true, roles: [TMDbCreditRole] = [.acting(character: "X")],
                        votes: Int = 100, average: Double? = 7.0, popularity: Double = 1, backdrop: Bool = true) -> TMDbPersonCredit {
        TMDbPersonCredit(mediaType: movie ? "movie" : "tv", tmdbID: id, title: title, releaseDate: date, poster: nil,
                         backdrop: backdrop ? URL(string: "https://image.tmdb.org/t/p/w780/\(id).jpg") : nil,
                         voteAverage: votes > 0 ? average : nil, voteCount: votes, popularity: popularity, roles: roles, episodeCount: nil)
    }

    @Test func creditsAreGroupedByYearNewestFirstWithUndatedTitlesLast() {
        let model = makeModel([
            credit(1, "Old", date: "1999-03-31"),
            credit(2, "Undated", date: nil),
            credit(3, "New", date: "2024-05-01"),
            credit(4, "Same year, later", date: "2024-12-01"),
            credit(5, "Same year, earlier", date: "2024-01-15"),
        ])
        #expect(model.sections.map(\.year) == [2024, 1999, nil])
        #expect(model.sections[0].credits.map(\.title) == ["Same year, later", "New", "Same year, earlier"])
    }

    @Test func mediaAndRoleFiltersCombine() {
        let model = makeModel([
            credit(1, "Film actor", date: "2020-01-01", roles: [.acting(character: "A")]),
            credit(2, "Film director", date: "2021-01-01", roles: [.crew(job: "Director", department: "Directing")]),
            credit(3, "Series writer", date: "2022-01-01", movie: false, roles: [.crew(job: "Writer", department: "Writing")]),
            credit(4, "Film both", date: "2023-01-01", roles: [.acting(character: "B"), .crew(job: "Producer", department: "Production")]),
        ])
        model.mediaFilter = .movies
        #expect(model.filteredCredits.map(\.title) == ["Film both", "Film director", "Film actor"])
        model.roleFilter = .directing
        #expect(model.filteredCredits.map(\.title) == ["Film director"])
        model.mediaFilter = .tv
        #expect(model.roleFilter == nil, "Directing has no series here, so switching to TV drops it")
        #expect(model.filteredCredits.map(\.title) == ["Series writer"])
        model.roleFilter = .writing
        #expect(model.filteredCredits.map(\.title) == ["Series writer"])
        model.mediaFilter = .all
        model.roleFilter = .production
        #expect(model.filteredCredits.map(\.title) == ["Film both"], "a title with several roles is listed under each of them")
        model.roleFilter = nil
        #expect(model.filteredCredits.count == 4)
    }

    @Test func thePageLoadsSixtyCreditsAtATimeAndChangingAFilterStartsOver() {
        let model = makeModel((1...130).map { credit($0, "Title \($0)", date: "2000-01-01") })
        #expect(model.sections.flatMap(\.credits).count == PersonViewModel.pageSize)
        #expect(model.hasMoreCredits)
        model.loadMore()
        #expect(model.sections.flatMap(\.credits).count == 120)
        model.loadMore()
        #expect(model.sections.flatMap(\.credits).count == 130 && !model.hasMoreCredits)
        model.loadMore()
        #expect(model.visibleCount == 180, "asking for more when there is no more changes nothing visible")
        model.mediaFilter = .tv
        #expect(model.visibleCount == PersonViewModel.pageSize)
    }

    @Test func knownForPrefersWellRatedTitlesWithBackdropsAndFallsBackWhenTooFewQualify() {
        let model = makeModel([
            credit(1, "Popular and rated", date: "2010-01-01", votes: 500, average: 8, popularity: 50),
            credit(2, "Popular, low votes", date: "2011-01-01", votes: 3, average: 9, popularity: 90),
            credit(3, "Rated, no backdrop", date: "2012-01-01", votes: 500, average: 8.5, popularity: 80, backdrop: false),
            credit(4, "Rated, lower", date: "2013-01-01", votes: 200, average: 7, popularity: 400),
            credit(5, "Rated, third", date: "2014-01-01", votes: 60, average: 6.5, popularity: 10),
        ])
        #expect(model.knownFor.map(\.title) == ["Popular and rated", "Rated, lower", "Rated, third"], "ranked by votes, not by the trending popularity")
        let sparse = makeModel([credit(1, "Only", date: "2010-01-01", votes: 2, average: 4, popularity: 1)])
        #expect(sparse.knownFor.map(\.title) == ["Only"], "with too few well-rated titles, any title with a backdrop may show")
    }

    @Test func knownForRanksALastingClassicAboveATrendingHit() {
        let model = makeModel([
            credit(1, "Classic", date: "1994-01-01", votes: 900, average: 8.5, popularity: 5),
            credit(2, "Trending this week", date: "2026-08-01", votes: 120, average: 7, popularity: 400),
            credit(3, "Solid", date: "2005-01-01", votes: 300, average: 7, popularity: 30),
            credit(4, "Rated, no backdrop", date: "2012-01-01", votes: 5000, average: 9, popularity: 900, backdrop: false),
            credit(5, "Too few votes", date: "2013-01-01", votes: 19, average: 9, popularity: 800),
            credit(6, "Rated too low", date: "2014-01-01", votes: 200, average: 6.4, popularity: 700),
        ])
        #expect(model.knownFor.map(\.title) == ["Classic", "Solid", "Trending this week"],
                "the high-popularity title with fewer votes ranks below the lower-popularity one with more")
    }

    @Test func knownForBreaksVoteTiesByPopularityThenTitle() {
        let model = makeModel([
            credit(1, "Zulu", date: "2001-01-01", votes: 300, average: 7, popularity: 10),
            credit(2, "Beta", date: "2002-01-01", votes: 300, average: 7, popularity: 10),
            credit(3, "Alpha", date: "2003-01-01", votes: 300, average: 7, popularity: 10),
            credit(4, "Less popular", date: "2004-01-01", votes: 300, average: 7, popularity: 2),
            credit(5, "Most popular", date: "2005-01-01", votes: 300, average: 7, popularity: 40),
        ])
        #expect(model.knownFor.map(\.title) == ["Most popular", "Alpha", "Beta", "Zulu", "Less popular"],
                "equal votes fall to popularity, and equal popularity to the title")
    }

    @Test func knownForShowsAtMostTwelveTitles() {
        let model = makeModel((1...15).map { credit($0, "Title \($0)", date: "2000-01-01", votes: 100 + $0) })
        #expect(model.knownFor.count == 12)
        #expect(model.knownFor.first?.title == "Title 15" && model.knownFor.last?.title == "Title 4")
    }

    @Test func knownForCardsTakeTheTMDbArtworkThatAnswersAndKeepThePlainBackdropOtherwise() async {
        let model = makeModel([
            credit(1, "Answers", date: "2010-01-01", votes: 500, average: 8, popularity: 50),
            credit(2, "Not found", date: "2011-01-01", votes: 500, average: 8, popularity: 40),
            credit(3, "Answers too", date: "2012-01-01", votes: 500, average: 8, popularity: 30),
        ])
        let backdrop = #"{"file_path":"/clean.jpg","iso_639_1":null,"vote_average":6,"vote_count":10,"width":1920}"#
        let logo = #"{"file_path":"/logo.png","iso_639_1":"en","vote_average":5,"vote_count":3,"width":800}"#
        let images = #"{"backdrops":[\#(backdrop)],"posters":[],"logos":[\#(logo)]}"#
        let transport = StubTransport { request, _ in
            if request.url?.path == "/3/movie/2/images" { return StubTransport.response(Data(), status: 404, for: request) }
            return StubTransport.response(Data(images.utf8), for: request)
        }
        await model.loadKnownForArtwork(using: TMDbRatings(client: makeClient(transport, retries: 0), readAccessToken: "token"))
        #expect(Set(model.knownForArtwork.keys) == ["movie/1", "movie/3"], "a title whose lookup fails has no artwork and keeps its plain backdrop")
        #expect(model.knownForArtwork["movie/1"]?.backdrop == URL(string: "https://image.tmdb.org/t/p/original/clean.jpg"))
        #expect(model.knownForArtwork["movie/1"]?.logo == URL(string: "https://image.tmdb.org/t/p/original/logo.png"))
    }

    @Test func aTitleDatedAfterTodayIsUnreleasedAndAnUndatedOneIsNot() {
        let model = makeModel([])
        #expect(model.isUnreleased(credit(1, "Soon", date: "2027-01-01")))
        #expect(model.isUnreleased(credit(2, "Today", date: "2026-10-09")) == false)
        #expect(model.isUnreleased(credit(3, "Gone", date: "2008-07-18")) == false)
        #expect(model.isUnreleased(credit(4, "Undated", date: nil)) == false)
    }

    @Test func roleTextListsEveryJobOnceAndTheCharacterForActing() {
        let both = credit(1, "T", date: nil, roles: [.crew(job: "Director", department: "Directing"), .crew(job: "Writer", department: "Writing"),
                                                      .acting(character: "Cameo"), .crew(job: "Director", department: "Directing")])
        #expect(both.roleText == "Director · Writer · as Cameo")
        #expect(credit(2, "U", date: nil, roles: [.acting(character: nil)]).roleText == "Actor")
    }

    @Test func aCreditBecomesTheTitleItOpensAndTheCardItDraws() {
        let film = credit(155, "The Dark Knight", date: "2008-07-18")
        #expect(film.titleDestination == TMDbTitleDestination(tmdbID: 155, mediaType: "movie", name: "The Dark Knight", poster: nil,
                                                              backdrop: film.backdrop, year: 2008))
        #expect(film.preview.id == "tmdb:movie:155" && film.preview.type == "movie" && film.preview.releaseInfo == "2008")
        #expect(credit(9, "", date: nil, movie: false).preview.name == "Untitled")
    }

    @Test func theRoleMenueListsOnlyRolesThePersonHasAndDropsARoleTheMediaFilterRemoves() {
        let model = makeModel([
            credit(1, "Film actor", date: "2020-01-01", roles: [.acting(character: "A")]),
            credit(2, "Series director", date: "2021-01-01", movie: false, roles: [.crew(job: "Director", department: "Directing")]),
        ])
        #expect(model.availableRoles == [.acting, .directing])
        model.roleFilter = .directing
        model.mediaFilter = .movies
        #expect(model.availableRoles == [.acting], "no film is directed here, so Directing leaves the menu")
        #expect(model.roleFilter == nil, "and the filter that no longer matches anything is cleared")
    }

    @Test func yearAndDayHelpersReadTmdbDates() {
        #expect(credit(1, "A", date: "2008-07-18").year == 2008)
        #expect(credit(1, "A", date: "").year == nil)
        #expect(PersonViewModel.isoDay(today) == "2026-10-09")
    }
}
