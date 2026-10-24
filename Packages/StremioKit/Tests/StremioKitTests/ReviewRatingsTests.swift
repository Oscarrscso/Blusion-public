import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

@Suite struct ReviewRatingsTests {
    private let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ0ZXN0In0.signature"
    private let findTV = Data(#"{"movie_results":[],"tv_results":[{"id":1399,"vote_average":8.4,"vote_count":50}]}"#.utf8)

    @Test func reviewsReadEveryPageKeepFullBodiesAndDeduplicateIDs() async throws {
        let find = findTV
        let body = String(repeating: "A complete review. ", count: 100_000) + "The final opinion."
        let transport = StubTransport { request, _ in
            if request.url?.path.contains("/find/") == true { return StubTransport.response(find, for: request) }
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
            let rows: [[String: String]]
            switch page {
            case "1": rows = [["id": "first", "author": "a", "content": "First review."]]
            case "2": rows = [["id": "first", "author": "a", "content": "Duplicate."],
                              ["id": "long", "author": "b", "content": body]]
            case "3": rows = [["id": "last", "author": "c", "content": "Last review."],
                              ["id": "empty", "author": "d", "content": " \n"]]
            default: throw AddonError.invalidJSON
            }
            let data = try JSONSerialization.data(withJSONObject: ["page": Int(page!)!, "total_pages": 3, "results": rows])
            return StubTransport.response(data, for: request)
        }
        let service = TMDbRatings(client: makeClient(transport), readAccessToken: jwt, titleIDs: TMDbTitleIDCache())
        let reviews = try await service.reviews(imdbID: "tt0944947", type: "series")
        #expect(reviews.map(\.id) == ["first", "long", "last"])
        #expect(reviews[1].content == body)
        #expect(transport.requests.filter { $0.url?.path.hasSuffix("/reviews") == true }.count == 3)
        #expect(transport.limits.last?.maxBytes == Int.max, "no former 1 MB review-page cutoff")
    }

    @Test func failedLaterReviewPagesDoNotReturnAnApparentlyCompleteSubset() async throws {
        let find = findTV
        let transport = StubTransport { request, _ in
            if request.url?.path.contains("/find/") == true { return StubTransport.response(find, for: request) }
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
            if page == "1" {
                let data = Data(#"{"page":1,"total_pages":2,"results":[{"id":"r1","author":"a","content":"Good performances."}]}"#.utf8)
                return StubTransport.response(data, for: request)
            }
            return StubTransport.response(Data(), status: 503, for: request)
        }
        let service = TMDbRatings(client: makeClient(transport, retries: 0), readAccessToken: jwt, titleIDs: TMDbTitleIDCache())
        await #expect(throws: AddonError.http(status: 503)) {
            try await service.reviews(imdbID: "tt0944947", type: "series")
        }
    }

    @Test func aReadAccessTokenGoesInTheBearerHeaderNeverInTheURL() async throws {
        let transport = StubTransport(data: findTV)
        let ratings = try await TMDbRatings(client: makeClient(transport), readAccessToken: jwt).ratings(imdbID: "tt0944947", type: "series")
        #expect(ratings.tmdb == 8.4 && ratings.tmdbURL?.absoluteString == "https://www.themoviedb.org/tv/1399")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.themoviedb.org/3/find/tt0944947?external_source=imdb_id")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(jwt)")
        #expect(request.url?.absoluteString.contains(jwt) == false)
    }

    @Test func aV3ApiKeyGoesInTheQueryInsteadOfAHeader() async throws {
        let transport = StubTransport(data: findTV)
        _ = try await TMDbRatings(client: makeClient(transport), readAccessToken: "0123456789abcdef0123456789abcdef").ratings(imdbID: "tt0944947", type: "series")
        let request = try #require(transport.requests.first)
        let items = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.contains(URLQueryItem(name: "api_key", value: "0123456789abcdef0123456789abcdef")) == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func pastedTokensAreTrimmedAndAPastedBearerPrefixIsDropped() async throws {
        let transport = StubTransport(data: findTV)
        _ = try await TMDbRatings(client: makeClient(transport), readAccessToken: "  Bearer \(jwt)\n").ratings(imdbID: "tt0944947", type: "series")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(jwt)")
    }

    @Test func invalidIDsOrEmptyTokensDoNotSendRequests() async throws {
        let transport = StubTransport(data: findTV)
        let badID = try await TMDbRatings(client: makeClient(transport), readAccessToken: jwt).ratings(imdbID: "title/id", type: "movie")
        let noToken = try await TMDbRatings(client: makeClient(transport), readAccessToken: " \n ").ratings(imdbID: "tt0468569", type: "movie")
        let badType = try await TMDbRatings(client: makeClient(transport), readAccessToken: jwt).ratings(imdbID: "tt0468569", type: "anime")
        let noEpisodes = try await TMDbRatings(client: makeClient(transport), readAccessToken: "").seasonEpisodeRatings(seriesIMDbID: "tt0944947", season: 1)
        #expect(badID.isEmpty && noToken.isEmpty && badType.isEmpty && noEpisodes.isEmpty && transport.callCount == 0)
    }

    @Test func aRefusedTokenThrowsSoTheCallerCanSayWhy() async throws {
        let transport = StubTransport(data: Data(#"{"success":false,"status_code":7,"status_message":"Invalid API key"}"#.utf8), status: 401)
        let client = TMDbRatings(client: makeClient(transport), readAccessToken: jwt)
        await #expect(throws: AddonError.http(status: 401)) {
            try await client.ratings(imdbID: "tt0468569", type: "movie")
        }
        #expect(transport.callCount == 1, "a 401 is not retried")
    }

    @Test func tmdbResolvesTheCorrectKindAndNeverInventsRatingsForUnratedTitles() throws {
        let data = Data(#"{"movie_results":[{"id":155,"vote_average":9.1,"vote_count":20}],"tv_results":[{"id":1399,"vote_average":8.4,"vote_count":50}]}"#.utf8)
        #expect(try TMDbRatings.parse(data, type: "series").tmdb == 8.4)
        let movie = try TMDbRatings.parse(data, type: "movie")
        #expect(movie.tmdb == 9.1 && movie.tmdbURL?.lastPathComponent == "155")

        let unrated = Data(#"{"movie_results":[{"id":155,"vote_average":0,"vote_count":0}],"tv_results":[]}"#.utf8)
        let unratedMovie = try TMDbRatings.parse(unrated, type: "movie")
        #expect(unratedMovie.tmdb == nil && unratedMovie.tmdbURL != nil)
        #expect(try TMDbRatings.parse(unrated, type: "series").isEmpty)
        #expect(throws: AddonError.invalidJSON) { try TMDbRatings.parse(Data("{}".utf8), type: "movie") }
        #expect(throws: AddonError.invalidJSON) { try TMDbRatings.parse(Data("not json".utf8), type: "movie") }
    }

    @Test func seasonEpisodeScoresComeFromTheSeriesFindThenTheSeasonEndpoint() async throws {
        let season = Data(#"""
        {"episodes":[
          {"episode_number":1,"vote_average":8.1,"vote_count":12},
          {"episode_number":2,"vote_average":0,"vote_count":0},
          {"episode_number":3,"vote_average":11,"vote_count":4},
          {"episode_number":4,"vote_average":7.25,"vote_count":3},
          {"vote_average":9,"vote_count":9}
        ]}
        """#.utf8)
        let transport = StubTransport { request, call in
            call == 1 ? StubTransport.response(self.findTV, for: request) : StubTransport.response(season, for: request)
        }
        let scores = try await TMDbRatings(client: makeClient(transport), readAccessToken: jwt)
            .seasonEpisodeRatings(seriesIMDbID: "tt0944947", season: 2)
        #expect(scores == [1: 8.1, 4: 7.25])
        #expect(transport.requests.count == 2)
        #expect(transport.requests[1].url?.absoluteString == "https://api.themoviedb.org/3/tv/1399/season/2")
        #expect(transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer \(jwt)")
    }

    @Test func aSeriesOrSeasonTMDbDoesNotKnowIsEmptyNotAnError() async throws {
        let unknownShow = StubTransport(data: Data(#"{"movie_results":[],"tv_results":[]}"#.utf8))
        let none = try await TMDbRatings(client: makeClient(unknownShow), readAccessToken: jwt).seasonEpisodeRatings(seriesIMDbID: "tt0944947", season: 1)
        #expect(none.isEmpty && unknownShow.callCount == 1)

        let missingSeason = StubTransport { request, call in
            call == 1 ? StubTransport.response(self.findTV, for: request) : StubTransport.response(Data("{}".utf8), status: 404, for: request)
        }
        let absent = try await TMDbRatings(client: makeClient(missingSeason), readAccessToken: jwt).seasonEpisodeRatings(seriesIMDbID: "tt0944947", season: 9)
        #expect(absent.isEmpty)
    }

    @Test func aRefusedSeasonRequestThrowsWithTheStatus() async throws {
        let transport = StubTransport { request, call in
            call == 1 ? StubTransport.response(self.findTV, for: request) : StubTransport.response(Data("{}".utf8), status: 401, for: request)
        }
        let client = TMDbRatings(client: makeClient(transport), readAccessToken: jwt)
        await #expect(throws: AddonError.http(status: 401)) {
            try await client.seasonEpisodeRatings(seriesIMDbID: "tt0944947", season: 1)
        }
    }

    @Test func metacriticUserReviewsUseTheTitlesAddressWithAGuessedSlug() {
        let film = MetaPreview(id: "tt0468569", type: "movie", name: "The Dark Knight")
        #expect(ReviewSite.metacritic.reviewsURL(for: film)?.absoluteString == "https://www.metacritic.com/movie/the-dark-knight/user-reviews/")
        let list = MetaPreview(id: "tt0108052", type: "movie", name: "Schindler's List")
        #expect(ReviewSite.metacritic.reviewsURL(for: list)?.absoluteString == "https://www.metacritic.com/movie/schindlers-list/user-reviews/")
        let show = MetaPreview(id: "tt0096697", type: "series", name: "The Simpsons")
        #expect(ReviewSite.metacritic.reviewsURL(for: show)?.absoluteString == "https://www.metacritic.com/tv/the-simpsons/user-reviews/")
    }

    @Test func tmdbUserReviewsAreThePageBelowTheTitlesOwnAndASearchStaysASearch() {
        let film = MetaPreview(id: "tt0133093", type: "movie", name: "The Matrix")
        let title = URL(string: "https://www.themoviedb.org/movie/603")
        #expect(ReviewSite.tmdb.reviewsURL(for: film, tmdbURL: title)?.absoluteString == "https://www.themoviedb.org/movie/603/reviews")
        #expect(ReviewSite.tmdb.reviewsURL(for: film, tmdbURL: URL(string: "https://www.themoviedb.org/tv/1399/"))?.absoluteString
                == "https://www.themoviedb.org/tv/1399/reviews", "a trailing slash makes no double slash")
        #expect(ReviewSite.tmdb.url(for: film, tmdbURL: title) == title, "the title's own page is unchanged")
        #expect(ReviewSite.tmdb.reviewsURL(for: film) == ReviewSite.tmdb.url(for: film), "without TMDB's address, its search")
    }

    @Test func onlyIMDbsReviewsPageWaitsForAHeadingNotItsSearch() {
        let reviews = URL(string: "https://www.imdb.com/title/tt0468569/reviews/")!
        let search = URL(string: "https://www.imdb.com/find/?q=Film")!
        #expect(ReviewSite.imdb.waitsForReviewsHeading(at: reviews))
        #expect(!ReviewSite.imdb.waitsForReviewsHeading(at: search), "a search page has no reviews heading to wait for")
        #expect(!ReviewSite.letterboxd.waitsForReviewsHeading(at: reviews), "Letterboxd's reviews have no heading the script finds")
        #expect(ReviewSite.metacritic.waitsForReviewsHeading(at: URL(string: "https://www.metacritic.com/movie/film/user-reviews/")!))
    }

    @Test func linksUseKnownIDsAndSearchForUnknownSlugsWithoutLeakingQuerySyntax() throws {
        let movie = MetaPreview(id: "tt0468569", type: "movie", name: "Film / #? & more")
        #expect(ReviewSite.imdb.url(for: movie)?.absoluteString == "https://www.imdb.com/title/tt0468569/")
        #expect(ReviewSite.letterboxd.url(for: movie)?.absoluteString == "https://letterboxd.com/imdb/tt0468569/")
        #expect(ReviewSite.imdb.reviewsURL(for: movie)?.absoluteString == "https://www.imdb.com/title/tt0468569/reviews/", "IMDb's user reviews")
        #expect(ReviewSite.letterboxd.reviewsURL(for: movie) == ReviewSite.letterboxd.url(for: movie), "Letterboxd's page opens its reviews itself")
        for site in [ReviewSite.rottenTomatoes, .metacritic, .tmdb] { #expect(site.isSearch(for: movie)) }
        let tomatoURL = try #require(ReviewSite.rottenTomatoes.url(for: movie))
        let parameters = URLComponents(url: tomatoURL, resolvingAgainstBaseURL: false)?.queryItems
        #expect(parameters == [URLQueryItem(name: "search", value: movie.name)])
        #expect(ReviewSite.metacritic.url(for: movie)?.query == nil)
        let direct = URL(string: "https://www.themoviedb.org/movie/155")
        #expect(ReviewSite.tmdb.url(for: movie, tmdbURL: direct) == direct)
        #expect(!ReviewSite.tmdb.isSearch(for: movie, tmdbURL: direct))
        #expect(ReviewSite.letterboxd.isSearch(for: MetaPreview(id: movie.id, type: "series")))
    }

    private let season = Data(#"""
    {"Title":"Show","Season":"1","totalSeasons":"3","Response":"True","Episodes":[
      {"Title":"Pilot","Released":"2011-04-17","Episode":"1","imdbRating":"9.1","imdbID":"tt1480055"},
      {"Title":"Second","Released":"2011-04-24","Episode":"2","imdbRating":"8.8","imdbID":"tt1668746"},
      {"Title":"Unrated","Released":"2011-05-01","Episode":"3","imdbRating":"N/A","imdbID":"tt1668747"},
      {"Title":"Broken","Released":"N/A","Episode":"x","imdbRating":"7.0","imdbID":"tt1668748"},
      {"Title":"Out of range","Released":"N/A","Episode":"5","imdbRating":"11.2","imdbID":"tt1668749"}]}
    """#.utf8)

    @Test func omdbSeasonAnswersGiveEpisodeScoresAndSkipUnusableOnes() throws {
        #expect(try OMDbRatings.parseSeason(season) == [1: 9.1, 2: 8.8])
    }

    @Test func unratedEpisodesKeepTheirIMDbIDsForLocalDatasetLookups() throws {
        let answer = try OMDbRatings.parseSeasonRatings(season)
        #expect(answer.scores == [1: 9.1, 2: 8.8])
        #expect(answer.episodeIDs == [1: "tt1480055", 2: "tt1668746", 3: "tt1668747", 5: "tt1668749"])
        #expect(answer.episodeNumbers == [1, 2, 3, 5])
        let invalid = Data(#"{"Response":"True","Episodes":[{"Episode":"1","imdbRating":"N/A","imdbID":"N/A"}]}"#.utf8)
        #expect(try OMDbRatings.parseSeasonRatings(invalid).episodeIDs.isEmpty)
    }

    @Test func theSeriesIDCannotBecomeAnEpisodeLookupID() async throws {
        let transport = StubTransport(data: Data(#"{"Response":"True","Episodes":[{"Episode":"1","imdbRating":"N/A","imdbID":"tt0944947"}]}"#.utf8))
        let answer = try await OMDbRatings(client: makeClient(transport), apiKey: "test-key").seasonRatings(imdbID: "tt0944947", season: 1)
        #expect(answer.episodeIDs.isEmpty && answer.episodeNumbers == [1])
    }

    @Test func omdbSeasonRequestsCarryTheSeasonNumber() async throws {
        let transport = StubTransport(data: season)
        let scores = try await OMDbRatings(client: makeClient(transport), apiKey: "test-key").episodeRatings(imdbID: "tt0944947", season: 1)
        #expect(scores == [1: 9.1, 2: 8.8])
        let url = try #require(transport.requests.first?.url)
        let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(parameters?.contains(URLQueryItem(name: "Season", value: "1")) == true)
        #expect(parameters?.contains(URLQueryItem(name: "i", value: "tt0944947")) == true)
        let invalid = try await OMDbRatings(client: makeClient(transport), apiKey: "test-key").episodeRatings(imdbID: "kitsu:1", season: 1)
        let noKey = try await OMDbRatings(client: makeClient(transport), apiKey: "").episodeRatings(imdbID: "tt0944947", season: 1)
        #expect(invalid.isEmpty && noKey.isEmpty && transport.callCount == 1)
    }

    @Test func omdbMissingSeasonsAreEmptyButBadKeysAndQuotasStillThrow() throws {
        #expect(try OMDbRatings.parseSeason(Data(#"{"Response":"False","Error":"Series or season not found!"}"#.utf8)).isEmpty)
        #expect(throws: AddonError.http(status: 401)) {
            try OMDbRatings.parseSeason(Data(#"{"Response":"False","Error":"Invalid API key!"}"#.utf8))
        }
        #expect(throws: AddonError.http(status: 429)) {
            try OMDbRatings.parseSeason(Data(#"{"Response":"False","Error":"Request limit reached!"}"#.utf8))
        }
        #expect(throws: AddonError.invalidJSON) { try OMDbRatings.parseSeason(Data("{}".utf8)) }
    }

    @Test func episodeScoresSurviveTheCacheFile() throws {
        let current = CachedRating(rating: nil, fetchedAt: Date(timeIntervalSince1970: 100), episodes: [1: 9.1, 12: 7.4],
                                   episodeIDs: [1: "tt1480055", 2: "tt1668746"], episodeNumbers: [1, 2, 12])
        #expect(try JSONDecoder().decode(CachedRating.self, from: JSONEncoder().encode(current)) == current)
    }

    @Test func extendedCachesDecodeOldAnswersAndRoundTripNewScores() throws {
        let legacy = Data(#"{"rating":4.5,"fetchedAt":100}"#.utf8)
        let decoded = try JSONDecoder().decode(CachedRating.self, from: legacy)
        #expect(decoded.rating == 4.5 && decoded.reviews == nil)
        #expect(decoded.episodeIDs == nil && decoded.episodeNumbers == nil)
        // Existing cached scores from either provider survive the merged build.
        let combined = Data(#"{"rating":null,"fetchedAt":100,"reviews":{"imdb":8.7,"rottenTomatoes":91,"tmdb":8.4}}"#.utf8)
        #expect(try JSONDecoder().decode(CachedRating.self, from: combined).reviews == ReviewRatings(imdb: 8.7, rottenTomatoes: 91, tmdb: 8.4))
        let current = CachedRating(rating: nil, fetchedAt: Date(), reviews: ReviewRatings(tmdb: 7.5, tmdbURL: URL(string: "https://www.themoviedb.org/movie/1")))
        #expect(try JSONDecoder().decode(CachedRating.self, from: JSONEncoder().encode(current)) == current)
    }
}
