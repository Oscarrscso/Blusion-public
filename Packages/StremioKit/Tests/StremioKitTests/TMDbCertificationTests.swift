import Foundation
import Testing
@testable import StremioKit

@Suite struct TMDbCertificationTests {
    @Test func aMoviesUSCertificateComesFromItsReleaseDates() throws {
        let data = Data(#"""
        {"id":155,"results":[
            {"iso_3166_1":"GB","release_dates":[{"certification":"12A"}]},
            {"iso_3166_1":"US","release_dates":[{"certification":""},{"certification":"PG-13"}]}]}
        """#.utf8)
        #expect(try TMDbRatings.parseCertification(data, isMovie: true) == "PG-13")
    }

    @Test func aShowsUSContentRatingComesFromItsContentRatings() throws {
        let data = Data(#"{"id":1399,"results":[{"iso_3166_1":"US","rating":"TV-MA"},{"iso_3166_1":"DE","rating":"16"}]}"#.utf8)
        #expect(try TMDbRatings.parseCertification(data, isMovie: false) == "TV-MA")
    }

    @Test func noUSEntryOrBlankRatingMeansNoCertification() throws {
        let foreignOnly = Data(#"{"results":[{"iso_3166_1":"FR","release_dates":[{"certification":"U"}]}]}"#.utf8)
        #expect(try TMDbRatings.parseCertification(foreignOnly, isMovie: true) == nil)
        let blank = Data(#"{"results":[{"iso_3166_1":"US","rating":"  "}]}"#.utf8)
        #expect(try TMDbRatings.parseCertification(blank, isMovie: false) == nil)
        let empty = Data(#"{}"#.utf8)
        #expect(try TMDbRatings.parseCertification(empty, isMovie: true) == nil)
    }

    @Test func aNonJSONAnswerIsInvalid() {
        #expect(throws: AddonError.self) { try TMDbRatings.parseCertification(Data("nope".utf8), isMovie: true) }
    }
}
