// swiftlint:disable line_length
import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

@Suite struct BackdropPickerTests {
    private let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ0ZXN0In0.signature"

    private func url(_ name: String) -> URL? { URL(string: "https://image.tmdb.org/t/p/original/\(name).jpg") }

    private func candidate(_ name: String, language: String? = nil, rating: Double? = nil, votes: Int? = nil, width: Int? = nil) -> BackdropCandidate {
        BackdropCandidate(url: url(name) ?? URL(fileURLWithPath: "/"), language: language, voteAverage: rating, voteCount: votes, width: width)
    }

    @Test func aTextlessBackdropBeatsAHigherRatedOneWithALanguage() {
        let picked = BackdropPicker.best([
            candidate("english", language: "en", rating: 9.5, votes: 300, width: 3840),
            candidate("textless", rating: 6.0, votes: 20, width: 1920),
        ])
        #expect(picked == url("textless"))
    }

    @Test func theHighestRatedTextlessBackdropWins() {
        let picked = BackdropPicker.best([
            candidate("low", rating: 7.1, votes: 900, width: 3840),
            candidate("top", rating: 8.3, votes: 5, width: 1920),
            candidate("english", language: "en", rating: 9.9, votes: 500, width: 3840),
        ])
        #expect(picked == url("top"))
    }

    @Test func ratingTiesGoToTheMostVotesThenTheWidestImage() {
        #expect(BackdropPicker.best([
            candidate("fewer", rating: 7.0, votes: 10, width: 3840),
            candidate("more", rating: 7.0, votes: 50, width: 1280),
        ]) == url("more"))
        #expect(BackdropPicker.best([
            candidate("narrow", rating: 7.0, votes: 50, width: 1280),
            candidate("wide", rating: 7.0, votes: 50, width: 3840),
        ]) == url("wide"))
    }

    @Test func anEnglishBackdropBeatsOtherLanguagesWhenThereIsNoTextless() {
        #expect(BackdropPicker.best([
            candidate("french", language: "fr", rating: 9.0, votes: 100, width: 3840),
            candidate("english", language: "en", rating: 5.0, votes: 3, width: 1920),
        ]) == url("english"))
        #expect(BackdropPicker.best([
            candidate("german", language: "de", rating: 3.0, votes: 3, width: 1920),
            candidate("french", language: "fr", rating: 9.0, votes: 100, width: 3840),
        ]) == url("french"))
    }

    @Test func anUnratedTextlessBackdropStillBeatsARatedEnglishOne() {
        #expect(BackdropPicker.best([
            candidate("english", language: "en", rating: 1.0, votes: 1, width: 1920),
            candidate("textless", width: 1920),
        ]) == url("textless"))
    }

    @Test func aBlankLanguageTagCountsAsTextless() {
        #expect(BackdropPicker.best([
            candidate("english", language: "en", rating: 5.0, votes: 10, width: 1920),
            candidate("blank", language: " ", rating: 2.0, votes: 10, width: 1920),
        ]) == url("blank"))
    }

    @Test func noCandidatesMeansNoBackdrop() {
        #expect(BackdropPicker.best([]) == nil)
    }

    @Test func theAnswerDoesNotDependOnTheOrderOfTheCandidates() {
        let candidates = [
            candidate("a", rating: 7.0, votes: 10, width: 1920),
            candidate("b", rating: 7.0, votes: 50, width: 3840),
            candidate("c", language: "en", rating: 9.0, votes: 99, width: 3840),
            candidate("d", rating: 7.0, votes: 50, width: 3840),
        ]
        let rotated = Array(candidates.dropFirst() + candidates.prefix(1))
        #expect(BackdropPicker.best(candidates) == url("b"))
        #expect(BackdropPicker.best(Array(candidates.reversed())) == url("b"))
        #expect(BackdropPicker.best(rotated) == url("b"))
    }

    @Test func theTitleArtworkUsesTheBestTextlessBackdropFromTMDb() async throws {
        let images = #"{"backdrops":[{"file_path":"/english-card.jpg","iso_639_1":"en","vote_average":9.5,"vote_count":300,"width":3840},{"file_path":"/clean-popular.jpg","iso_639_1":null,"vote_average":6.2,"vote_count":80,"width":3840},{"file_path":"/clean-rated.jpg","vote_average":8.1,"vote_count":40,"width":1920}],"posters":[],"logos":[]}"#
        let transport = StubTransport { request, _ in
            let json = request.url?.lastPathComponent == "images" ? images : #"{"movie_results":[{"id":155}],"tv_results":[]}"#
            return StubTransport.response(Data(json.utf8), for: request)
        }
        let artwork = try await TMDbRatings(client: makeClient(transport), readAccessToken: jwt, titleIDs: TMDbTitleIDCache())
            .artwork(imdbID: "tt0468569", type: "movie")
        #expect(artwork?.backdrop == URL(string: "https://image.tmdb.org/t/p/original/clean-rated.jpg"))
    }

    private func image(_ name: String, language: String? = nil, votes: Int = 10, rating: Double = 6.0) -> String {
        let tag = language.map { "\"\($0)\"" } ?? "null"
        return #"{"file_path":"/\#(name).jpg","iso_639_1":\#(tag),"vote_average":\#(rating),"vote_count":\#(votes),"width":1920}"#
    }

    private func portraitArtwork(posters: [String] = [], backdrops: [String] = []) async throws -> TMDbArtwork? {
        let images = #"{"backdrops":[\#(backdrops.joined(separator: ","))],"posters":[\#(posters.joined(separator: ","))],"logos":[]}"#
        let transport = StubTransport { request, _ in
            let json = request.url?.lastPathComponent == "images" ? images : #"{"movie_results":[{"id":155}],"tv_results":[]}"#
            return StubTransport.response(Data(json.utf8), for: request)
        }
        return try await TMDbRatings(client: makeClient(transport), readAccessToken: jwt, titleIDs: TMDbTitleIDCache())
            .artwork(imdbID: "tt0468569", type: "movie")
    }

    @Test func aTextlessPosterIsThePortraitBeforeATextlessBackdrop() async throws {
        let artwork = try await portraitArtwork(posters: [image("poster-clean", votes: 10)],
                                                backdrops: [image("backdrop-clean", votes: 900, rating: 9.0)])
        #expect(artwork?.portrait == url("poster-clean"))
        #expect(artwork?.portraitHidesLogo == false)
    }

    @Test func aTextlessBackdropIsThePortraitWhenThereIsNoTextlessPoster() async throws {
        let artwork = try await portraitArtwork(posters: [image("poster-en", language: "en", votes: 900, rating: 9.0)],
                                                backdrops: [image("backdrop-clean", votes: 10)])
        #expect(artwork?.portrait == url("backdrop-clean"))
        #expect(artwork?.backdrop == url("backdrop-clean"))
        #expect(artwork?.portraitHidesLogo == false)
    }

    @Test func anEnglishPosterIsThePortraitAndHidesTheLogo() async throws {
        let artwork = try await portraitArtwork(posters: [image("poster-fr", language: "fr", votes: 900, rating: 9.0),
                                                          image("poster-en", language: "en", votes: 10)],
                                                backdrops: [image("backdrop-en", language: "en", votes: 900)])
        #expect(artwork?.portrait == url("poster-en"))
        #expect(artwork?.portraitHidesLogo == true)
    }

    @Test func anOtherLanguagePosterIsThePortraitAndHidesTheLogo() async throws {
        let artwork = try await portraitArtwork(posters: [image("poster-fr", language: "fr")],
                                                backdrops: [image("backdrop-fr", language: "fr", votes: 900)])
        #expect(artwork?.portrait == url("poster-fr"))
        #expect(artwork?.portraitHidesLogo == true)
    }

    @Test func thePortraitIsTheMostVotedImageWithinItsTier() async throws {
        let textless = try await portraitArtwork(posters: [image("low", votes: 10, rating: 9.0), image("top", votes: 50, rating: 6.0),
                                                           image("en", language: "en", votes: 900)])
        #expect(textless?.portrait == url("top"))
        #expect(textless?.portraitHidesLogo == false)
        let blank = try await portraitArtwork(posters: [image("top", votes: 50), image("blank", language: " ", votes: 60)])
        #expect(blank?.portrait == url("blank"))
        #expect(blank?.portraitHidesLogo == false)
        let english = try await portraitArtwork(posters: [image("en-low", language: "en", votes: 10),
                                                          image("en-top", language: " EN ", votes: 50)])
        #expect(english?.portrait == url("en-top"))
        #expect(english?.portraitHidesLogo == true)
    }
}
// swiftlint:enable line_length
