import Foundation
import Testing
@testable import Features

@Suite struct LandscapeArtworkTests {
    @Test func tmdbPicturesAtOriginalOrW1280BecomeW780ForTheMac() throws {
        let original = try #require(URL(string: "https://image.tmdb.org/t/p/original/abc.jpg"))
        #expect(PosterQuality.smallerLandscape(original)?.absoluteString == "https://image.tmdb.org/t/p/w780/abc.jpg")
        let large = try #require(URL(string: "https://image.tmdb.org/t/p/w1280/abc.jpg"))
        #expect(PosterQuality.smallerLandscape(large)?.absoluteString == "https://image.tmdb.org/t/p/w780/abc.jpg")
    }

    @Test func otherPicturesAreReturnedAsTheyCame() throws {
        let metahub = try #require(URL(string: "https://images.metahub.space/background/large/tt0944947/img"))
        #expect(PosterQuality.smallerLandscape(metahub) == metahub)
        #expect(PosterQuality.smallerLandscape(nil) == nil)
    }

    @Test func iPhoneAndTheTestHostKeepTheirPictures() throws {
        // Only the Mac's build shrinks them, so the test host (not Catalyst) keeps the picture as it came.
        let original = try #require(URL(string: "https://image.tmdb.org/t/p/original/abc.jpg"))
        #expect(PosterQuality.landscape(original) == original)
    }
}
