import Foundation
import Testing
@testable import StremioKit

/// Genres and ratings kept on a saved title, which the Library filters by.
@Suite struct LibraryItemMetadataTests {
    @Test func savingKeepsGenresAndRatingFromThePreview() {
        let preview = MetaPreview(id: "tt1", type: "series", name: "Show", releaseInfo: "2019-2023", imdbRating: 8.4, genres: ["Drama", "Crime"])
        let item = LibraryItem(preview: preview, addedAt: Date(timeIntervalSince1970: 0))
        #expect(item.genres == ["Drama", "Crime"])
        #expect(item.imdbRating == 8.4)
        #expect(item.preview.genres == ["Drama", "Crime"], "the saved metadata reaches the preview Detail opens with")
        #expect(item.preview.imdbRating == 8.4)
    }

    @Test func anItemEncodedBeforeGenresWereKeptDecodesWithNone() throws {
        let json = #"""
        {"id":"movie/tt1","type":"movie","contentID":"tt1","name":"Old","releaseInfo":"1999","addedAt":0}
        """#
        let item = try JSONDecoder().decode(LibraryItem.self, from: Data(json.utf8))
        #expect(item.genres.isEmpty)
        #expect(item.imdbRating == nil)
        #expect(item.releaseInfo == "1999")
    }

    @Test func genresAndRatingSurviveAJSONRoundTrip() throws {
        let item = LibraryItem(id: "movie/tt2", type: "movie", contentID: "tt2", name: "N", addedAt: Date(timeIntervalSince1970: 5),
                               genres: ["Action"], imdbRating: 6.5)
        let decoded = try JSONDecoder().decode(LibraryItem.self, from: JSONEncoder().encode(item))
        #expect(decoded == item)
    }
}
