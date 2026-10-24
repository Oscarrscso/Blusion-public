import Foundation
import Testing
@testable import Features

/// Artwork on disk has no expiry: it stays until the size limit makes room, and is checked for a newer copy after a while, BetterPosters'
/// sooner, since its posters carry ratings that move.
@Suite struct ImageCachePolicyTests {
    private let poster = URL(string: "https://images.metahub.space/poster/medium/tt0096697/img")!
    private let betterPoster = URL(string: "https://btttr.cc/poster/imdb/poster-default/tt0096697.jpg?rs=IM")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theDiskSizeIsTheSavedChoiceOrOneGigabyte() {
        #expect(ImageCachePolicy.diskBytes(forSavedMegabytes: nil) == 1024 * 1024 * 1024)
        #expect(ImageCachePolicy.diskBytes(forSavedMegabytes: 512) == 512 * 1024 * 1024)
        #expect(ImageCachePolicy.diskBytes(forSavedMegabytes: 300) == 1024 * 1024 * 1024, "a size the page does not offer is the default")
    }

    @Test func betterPostersAreCheckedAfterADayAndOtherArtworkAfterTwoWeeks() {
        #expect(!ImageCachePolicy.isDueForRefresh(url: betterPoster, fetched: now.addingTimeInterval(-23 * 3600), now: now))
        #expect(ImageCachePolicy.isDueForRefresh(url: betterPoster, fetched: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(!ImageCachePolicy.isDueForRefresh(url: poster, fetched: now.addingTimeInterval(-13 * 86400), now: now))
        #expect(ImageCachePolicy.isDueForRefresh(url: poster, fetched: now.addingTimeInterval(-15 * 86400), now: now))
        #expect(ImageCachePolicy.isDueForRefresh(url: poster, fetched: nil, now: now), "a copy with no date is checked")
    }

    @Test func theHttpDateReadsBackAsWritten() throws {
        let date = try #require(ImageCachePolicy.date(fromHeader: "Wed, 14 Oct 2026 21:00:00 GMT"))
        #expect(ImageCachePolicy.header(for: date) == "Wed, 14 Oct 2026 21:00:00 GMT")
        #expect(ImageCachePolicy.date(fromHeader: "not a date") == nil)
        #expect(ImageCachePolicy.date(fromHeader: nil) == nil)
    }
}
