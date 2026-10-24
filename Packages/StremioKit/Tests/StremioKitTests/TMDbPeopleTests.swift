import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

@Suite struct TMDbPeopleTests {
    private let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ0ZXN0In0.signature"

    // MARK: Title credits

    @Test func aMoviesCreditsMergeARepeatedCrewMemberIntoOneEntryWithEveryJob() throws {
        let data = Data(#"""
        {"id":155,"cast":[
            {"id":3894,"name":"Christian Bale","character":"Bruce Wayne","profile_path":"/bale.jpg","order":0},
            {"id":1,"name":"Nobody","character":"","profile_path":null,"order":1}],
         "crew":[
            {"id":525,"name":"Christopher Nolan","job":"Director","department":"Directing","profile_path":"/nolan.jpg"},
            {"id":525,"name":"Christopher Nolan","job":"Writer","department":"Writing","profile_path":"/nolan.jpg"},
            {"id":7,"name":"Sound Person","job":"Sound Mixer","department":"Sound","profile_path":null},
            {"id":8,"name":"Pro Ducer","job":"Producer","department":"Production","profile_path":null},
            {"id":8,"name":"Pro Ducer","job":"Executive Producer","department":"Production","profile_path":null}]}
        """#.utf8)
        let credits = try TMDbTitleCredits.parse(data)
        #expect(credits.cast.map(\.name) == ["Christian Bale", "Nobody"])
        #expect(credits.cast[0].roleText == "Bruce Wayne")
        #expect(credits.cast[0].profile?.absoluteString == "https://image.tmdb.org/t/p/w342/bale.jpg")
        #expect(credits.cast[1].roleText == nil && credits.cast[1].profile == nil)
        #expect(credits.groups == [.cast, .directing, .writing, .production, .sound])
        #expect(credits.people(in: .production).map(\.roles) == [["Producer", "Executive Producer"]], "two jobs in one part are one card")
        #expect(credits.people(in: .directing).map(\.roles) == [["Director"]], "each part has only its own jobs")
        #expect(credits.people(in: .writing).map(\.roles) == [["Writer"]])
        #expect(credits.people(in: .writing).first?.profile?.absoluteString == "https://image.tmdb.org/t/p/w342/nolan.jpg")
        #expect(credits.people(in: .sound).map(\.name) == ["Sound Person"])
        #expect(credits.people(in: .camera).isEmpty)
    }

    @Test func aSeriesAggregateCreditsKeepsEachPersonsRolesAndTheKeyJobsLeadTheirPart() throws {
        let data = Data(#"""
        {"cast":[{"id":10,"name":"Actor One","order":0,"profile_path":"/a.jpg",
                  "roles":[{"character":"Jon Snow","episode_count":60},{"character":"Lord Commander","episode_count":2}]}],
         "crew":[{"id":23,"name":"Casting Cass","department":"Production","profile_path":null,
                  "jobs":[{"job":"Casting","department":"Production"}]},
                 {"id":20,"name":"Producer Pat","department":"Production","profile_path":null,
                  "jobs":[{"job":"Producer","department":"Production"},{"job":"Executive Producer","department":"Production"}]},
                 {"id":21,"name":"Creator Cy","department":"Writing","profile_path":"/c.jpg",
                  "jobs":[{"job":"Creator","department":"Writing"},{"job":"Writer","department":"Writing"}]},
                 {"id":22,"name":"Director Dee","department":"Directing","profile_path":null,
                  "jobs":[{"job":"Director","department":"Directing"}]}]}
        """#.utf8)
        let credits = try TMDbTitleCredits.parse(data)
        #expect(credits.cast.first?.roleText == "Jon Snow · Lord Commander")
        #expect(credits.people(in: .production).map(\.name) == ["Producer Pat", "Casting Cass"], "a key job leads its part")
        #expect(credits.people(in: .production).first?.roleText == "Producer · Executive Producer", "every job in the part is kept")
        #expect(credits.people(in: .writing).map(\.name) == ["Creator Cy"])
        #expect(credits.people(in: .directing).map(\.name) == ["Director Dee"])
        #expect(credits.groups == [.cast, .directing, .writing, .production])
    }

    @Test func eachCrewDepartmentIsItsOwnPartAndOneWithoutAPartIsCrew() throws {
        let data = Data(#"""
        {"cast":[],
         "crew":[{"id":1,"name":"Gaffer Gil","job":"Gaffer","department":"Lighting"},
                 {"id":2,"name":"Stunts Sam","job":"Stunt Coordinator","department":"Crew"},
                 {"id":3,"name":"No Department","job":"Thanks"},
                 {"id":4,"name":"Make-Up Mo","job":"Makeup Artist","department":"Costume & Make-Up"},
                 {"id":5,"name":"Effects Eve","job":"Visual Effects Supervisor","department":"Visual Effects"},
                 {"id":6,"name":"Art Ari","job":"Production Design","department":"Art"},
                 {"id":7,"name":"Camera Cam","job":"Director of Photography","department":"Camera"},
                 {"id":8,"name":"Editor Ed","job":"Editor","department":"Editing"}]}
        """#.utf8)
        let credits = try TMDbTitleCredits.parse(data)
        #expect(credits.groups == [.art, .camera, .editing, .visualEffects, .costumeAndMakeUp, .crew])
        #expect(credits.people(in: .crew).map(\.name) == ["Gaffer Gil", "Stunts Sam", "No Department"])
        #expect(credits.people(in: .costumeAndMakeUp).map(\.name) == ["Make-Up Mo"])
        #expect(credits.people(in: .visualEffects).map(\.name) == ["Effects Eve"])
    }

    @Test func aPartWithNobodyInItGivesWayToTheFirstPartThereIs() {
        let person = TMDbTitlePerson(id: 1, name: "Dee", roles: ["Director"], isCast: false, profile: nil)
        let crewOnly = TMDbTitleCredits(cast: [], crew: [.directing: [person]])
        #expect(crewOnly.group(showing: .cast) == .directing)
        #expect(crewOnly.group(showing: .directing) == .directing)
        #expect(crewOnly.group(showing: .sound) == .directing)
        #expect(TMDbTitleCredits.empty.group(showing: .cast) == nil)
    }

    @Test func aMalformedCreditsAnswerThrowsInvalidJSON() {
        #expect(throws: AddonError.invalidJSON) { try TMDbTitleCredits.parse(Data("not json".utf8)) }
    }

    @Test func titleCreditsResolvesTheTitleThenAsksTheRightEndpoint() async throws {
        let transport = StubTransport { request, _ in
            let path = request.url?.path ?? ""
            let body = path.hasPrefix("/3/find") ? #"{"movie_results":[{"id":155,"vote_average":8.4,"vote_count":9}],"tv_results":[]}"# : #"{"cast":[],"crew":[]}"#
            return HTTPResult(data: Data(body.utf8), response: HTTPResponseInfo(statusCode: 200, headers: [:], url: request.url))
        }
        let client = TMDbRatings(client: makeClient(transport), readAccessToken: jwt)
        _ = try await client.titleCredits(imdbID: "tt0468569", type: "movie")
        let paths = transport.requests.compactMap { $0.url?.path }
        #expect(paths == ["/3/find/tt0468569", "/3/movie/155/credits"])
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(jwt)" })
    }

    @Test func theTitleIDIsLookedUpOnceAndSharedByConcurrentCallers() async throws {
        let transport = StubTransport { request, _ in
            let path = request.url?.path ?? ""
            let body = path.hasPrefix("/3/find") ?
                #"{"movie_results":[{"id":155,"vote_average":8.4,"vote_count":9}],"tv_results":[]}"# : #"{"cast":[],"crew":[],"results":[]}"#
            return HTTPResult(data: Data(body.utf8), response: HTTPResponseInfo(statusCode: 200, headers: [:], url: request.url))
        }
        let client = TMDbRatings(client: makeClient(transport), readAccessToken: jwt, titleIDs: TMDbTitleIDCache())
        async let credits = client.titleCredits(imdbID: "tt7001001", type: "movie")
        async let reviews = client.reviews(imdbID: "tt7001001", type: "movie")
        _ = try await credits
        _ = try await reviews
        let finds = { transport.requests.filter { $0.url?.path.hasPrefix("/3/find") == true }.count }
        #expect(finds() == 1, "concurrent calls share one lookup")
        _ = try await client.titleCredits(imdbID: "tt7001001", type: "movie")
        #expect(finds() == 1, "a later call reuses the id")
    }

    @Test func titleCreditsForAnUnknownTitleSendsNoSecondRequest() async throws {
        let transport = StubTransport(data: Data(#"{"movie_results":[],"tv_results":[]}"#.utf8))
        let credits = try await TMDbRatings(client: makeClient(transport), readAccessToken: jwt).titleCredits(imdbID: "tt0000001", type: "movie")
        #expect(credits == .empty && transport.callCount == 1)
    }

    // MARK: Person

    @Test func aPersonPageTrimsTheBiographyAndDropsAnEmptyOne() throws {
        let person = try TMDbPerson.parse(Data(#"""
        {"id":525,"name":"Christopher Nolan","biography":"  Born in London.\n","known_for_department":"Directing","profile_path":"/n.jpg"}
        """#.utf8))
        #expect(person.biography == "Born in London.")
        #expect(person.department == "Directing")
        #expect(person.profile?.absoluteString == "https://image.tmdb.org/t/p/h632/n.jpg")
        let blank = try TMDbPerson.parse(Data(#"{"id":1,"name":"A","biography":"  ","known_for_department":"","profile_path":null}"#.utf8))
        #expect(blank.biography == nil && blank.department == nil && blank.profile == nil)
    }

    // MARK: Filmography

    @Test func combinedCreditsMergeEveryRoleOnOneTitleAndSkipOtherMediaTypes() throws {
        let data = Data(#"""
        {"cast":[
            {"id":1,"media_type":"movie","title":"Memento","release_date":"2000-10-05","poster_path":"/p.jpg","backdrop_path":"/b.jpg",
             "character":"Leonard","vote_average":8.4,"vote_count":12000,"popularity":30.5},
            {"id":2,"media_type":"tv","name":"Show","first_air_date":"2010-01-01","character":"Hero","episode_count":10,
             "vote_average":0,"vote_count":0,"popularity":4},
            {"id":99,"media_type":"person","name":"Not a title","character":"X"}],
         "crew":[
            {"id":1,"media_type":"movie","title":"Memento","release_date":"2000-10-05","department":"Writing","job":"Screenplay",
             "vote_average":8.4,"vote_count":12000,"popularity":30.5},
            {"id":3,"media_type":"movie","title":"Undated","release_date":"","department":"Sound","job":"Sound Mixer","popularity":1}]}
        """#.utf8)
        let credits = try TMDbPersonCredit.parseCombined(data)
        #expect(credits.map(\.title) == ["Memento", "Show", "Undated"])
        let memento = try #require(credits.first)
        #expect(memento.year == 2000 && memento.isMovie)
        #expect(memento.roles == [.acting(character: "Leonard"), .crew(job: "Screenplay", department: "Writing")])
        #expect(memento.categories == [.acting, .writing])
        #expect(memento.voteAverage == 8.4)
        #expect(memento.poster?.absoluteString == "https://image.tmdb.org/t/p/w342/p.jpg")
        #expect(memento.backdrop?.absoluteString == "https://image.tmdb.org/t/p/w780/b.jpg")

        let show = credits[1]
        #expect(show.isMovie == false && show.year == 2010 && show.episodeCount == 10)
        #expect(show.voteAverage == nil, "an average without votes is not shown as a rating")

        let undated = credits[2]
        #expect(undated.releaseDate == nil && undated.year == nil)
        #expect(undated.categories == [.other], "a sound job is in Other")
    }

    @Test func unknownDepartmentsAndMissingTitlesStillParse() {
        #expect(CreditCategory(department: "Camera") == .other)
        #expect(CreditCategory(department: "Directing") == .directing)
        #expect(CreditCategory(department: "Production") == .production)
        let credits = try? TMDbPersonCredit.parseCombined(Data(#"{"cast":[{"id":5,"media_type":"movie","character":""}],"crew":[]}"#.utf8))
        #expect(credits?.first?.title == "" && credits?.first?.roles == [.acting(character: nil)])
    }

    @Test func personCreditsAskTheCombinedCreditsEndpoint() async throws {
        let transport = StubTransport(data: Data(#"{"cast":[],"crew":[]}"#.utf8))
        let credits = try await TMDbRatings(client: makeClient(transport), readAccessToken: jwt).personCredits(id: 525)
        #expect(credits.isEmpty)
        #expect(transport.requests.first?.url?.path == "/3/person/525/combined_credits")
    }

    @Test func personPhotosAreBestVotedFirstAndEmptyWhenThereAreNone() async throws {
        let transport = StubTransport(data: Data(#"""
        {"profiles":[{"file_path":"/low.jpg","vote_average":4.0,"vote_count":2},
                     {"file_path":"/top.jpg","vote_average":6.5,"vote_count":30},
                     {"file_path":"/mid.jpg","vote_average":5.0,"vote_count":9}]}
        """#.utf8))
        let photos = try await TMDbRatings(client: makeClient(transport), readAccessToken: jwt).personPhotos(id: 525)
        #expect(photos.map(\.lastPathComponent) == ["top.jpg", "mid.jpg", "low.jpg"])
        #expect(photos.first?.absoluteString == "https://image.tmdb.org/t/p/w342/top.jpg")
        #expect(transport.requests.first?.url?.path == "/3/person/525/images")
        let none = StubTransport(data: Data(#"{"profiles":[]}"#.utf8))
        #expect(try await TMDbRatings(client: makeClient(none), readAccessToken: jwt).personPhotos(id: 1).isEmpty)
    }

    // MARK: Related titles

    @Test func relatedTitlesKeepTmdbOrderAndSkipEntriesWithoutATitle() async throws {
        let transport = StubTransport { request, _ in
            let path = request.url?.path ?? ""
            let body = path.hasPrefix("/3/find") ? #"{"movie_results":[{"id":155,"vote_average":8.4,"vote_count":9}],"tv_results":[]}"# :
                #"""
                {"results":[{"id":272,"title":"Batman Begins","overview":"A determined hero returns to fight crime.",
                             "release_date":"2005-06-15","poster_path":"/b.jpg","backdrop_path":null},
                            {"id":9,"title":"","poster_path":null},
                            {"id":11,"name":"A Show","first_air_date":"2001-01-01","media_type":"tv"}]}
                """#
            return HTTPResult(data: Data(body.utf8), response: HTTPResponseInfo(statusCode: 200, headers: [:], url: request.url))
        }
        let related = try await TMDbRatings(client: makeClient(transport), readAccessToken: jwt, titleIDs: TMDbTitleIDCache())
            .relatedTitles(imdbID: "tt7002001", type: "movie")
        #expect(related.map(\.title) == ["Batman Begins", "A Show"])
        #expect(related[0].mediaType == "movie" && related[0].releaseDate == "2005-06-15" && related[0].backdrop == nil)
        #expect(related[1].mediaType == "tv" && related[1].releaseDate == "2001-01-01")
        #expect(related[0].overview == "A determined hero returns to fight crime." && related[1].overview == nil)
        #expect(transport.requests.last?.url?.path == "/3/movie/155/recommendations")
    }

    // MARK: IMDb id for a credit

    @Test func aCreditOpensTheTitleByItsIMDbID() async throws {
        let transport = StubTransport(data: Data(#"{"imdb_id":"tt0468569"}"#.utf8))
        let client = TMDbRatings(client: makeClient(transport), readAccessToken: jwt)
        #expect(try await client.imdbID(tmdbID: 155, mediaType: "movie") == "tt0468569")
        #expect(transport.requests.first?.url?.path == "/3/movie/155/external_ids")
    }

    @Test func aMissingOrMalformedIMDbIDIsNilAndAPersonWithoutATokenSendsNothing() async throws {
        let missing = StubTransport(data: Data(#"{"imdb_id":null}"#.utf8))
        #expect(try await TMDbRatings(client: makeClient(missing), readAccessToken: jwt).imdbID(tmdbID: 1, mediaType: "tv") == nil)
        let junk = StubTransport(data: Data(#"{"imdb_id":"not-an-id"}"#.utf8))
        #expect(try await TMDbRatings(client: makeClient(junk), readAccessToken: jwt).imdbID(tmdbID: 1, mediaType: "tv") == nil)
        let silent = StubTransport(data: Data())
        let noToken = TMDbRatings(client: makeClient(silent), readAccessToken: " ")
        #expect(try await noToken.imdbID(tmdbID: 1, mediaType: "movie") == nil)
        #expect(try await noToken.imdbID(tmdbID: 1, mediaType: "person") == nil)
        #expect(silent.callCount == 0)
    }
}
