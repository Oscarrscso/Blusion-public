import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import StremioKit
import StremioKitTestSupport

@Suite struct LetterboxdRatingsTests {
    /// The first bytes of a film page: boilerplate, then the rating tag about 2.3 KB in, as Letterboxd sends it.
    static func pagePrefix(rating: String) -> Data {
        let head = String(repeating: #"<link rel="preload" href="/static/css/site.css" as="style" />"# + "\n", count: 30)
        return Data("<!DOCTYPE html><html><head>\(head)<meta name=\"twitter:data2\" content=\"\(rating)\" /></head><body></body></html>".utf8)
    }

    /// A head holding only the given markup, for the parser.
    static func head(_ markup: String) -> Data {
        Data("<!DOCTYPE html><html><head>\(markup)</head><body></body></html>".utf8)
    }

    @Test func requestsTheFilmPageByIMDbIDForItsFirstBytesOnly() async throws {
        let transport = StubTransport { request, _ in
            StubTransport.response(Self.pagePrefix(rating: "4.50 out of 5"), status: 206, for: request)
        }
        let rating = try await LetterboxdRatings(client: makeClient(transport)).rating(imdbID: "tt0468569")
        #expect(rating == 4.5)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://letterboxd.com/imdb/tt0468569/")
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-4095")
        let limits = try #require(transport.limits.first)
        #expect(limits.maxBytes == 8192)
        #expect(limits.truncateAtLimit)
        #expect(transport.callCount == 1)
    }

    @Test func aFullPageAnsweredWith200IsReadToo() async throws {
        let transport = StubTransport(data: Self.pagePrefix(rating: "3.5 out of 5"), status: 200)
        let rating = try await LetterboxdRatings(client: makeClient(transport)).rating(imdbID: "tt0468569")
        #expect(rating == 3.5)
    }

    @Test func aPageWithoutTheTagHasNoRating() async throws {
        let transport = StubTransport(data: Data("<html><head><title>Series</title></head></html>".utf8))
        let rating = try await LetterboxdRatings(client: makeClient(transport)).rating(imdbID: "tt0944947")
        #expect(rating == nil)
    }

    @Test func aMissingPageThrowsRatherThanCachingANetworkFailure() async {
        let transport = StubTransport(data: Data(), status: 404)
        await #expect(throws: AddonError.notFound) {
            try await LetterboxdRatings(client: makeClient(transport)).rating(imdbID: "tt9999991")
        }
        #expect(transport.callCount == 1)
    }

    @Test func malformedIDsAreNotRequested() async throws {
        let transport = StubTransport(data: Self.pagePrefix(rating: "4.50 out of 5"))
        let lookup = LetterboxdRatings(client: makeClient(transport))
        for id in ["", "tt", "tt1234", "tt12345678901", "0468569", "movie/tt0468569", "tt0468569/", " tt0468569", "TT0468569", "tt04685x9", "tt0468569\n"] {
            let rating = try await lookup.rating(imdbID: id)
            #expect(rating == nil, "\(id) is not an IMDb id")
        }
        #expect(transport.callCount == 0)
    }

    @Test func isIMDbIDAcceptsFiveToTenDigits() {
        #expect(LetterboxdRatings.isIMDbID("tt12345"))
        #expect(LetterboxdRatings.isIMDbID("tt1234567890"))
        #expect(!LetterboxdRatings.isIMDbID("tt1234"))
        #expect(!LetterboxdRatings.isIMDbID("tt12345678901"))
    }

    @Test func aTransportErrorThrows() async {
        let transport = StubTransport { _, _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: AddonError.offline) { try await LetterboxdRatings(client: makeClient(transport, retries: 0)).rating(imdbID: "tt0468569") }
    }

    @Test func aServerErrorThrows() async {
        let transport = StubTransport(data: Data(), status: 500)
        await #expect(throws: AddonError.http(status: 500)) {
            try await LetterboxdRatings(client: makeClient(transport, retries: 0)).rating(imdbID: "tt0468569")
        }
    }

    @Test func parsesTheStatedAverageInAnyAttributeOrderOrQuoteStyle() {
        #expect(LetterboxdRatings.parseRating(inPagePrefix: Self.head(#"<meta name="twitter:data2" content="4.50 out of 5" />"#)) == 4.5)
        #expect(LetterboxdRatings.parseRating(inPagePrefix: Self.head(#"<meta content="3.5 out of 5" name="twitter:data2">"#)) == 3.5)
        #expect(LetterboxdRatings.parseRating(inPagePrefix: Self.head("<meta name='twitter:data2' content='2 out of 5'>")) == 2)
        #expect(LetterboxdRatings.parseRating(inPagePrefix: Self.head(#"<meta name="twitter:data2" content="0 out of 5">"#)) == 0)
    }

    @Test func aBareNumberIsAccepted() {
        #expect(LetterboxdRatings.parseRating(inPagePrefix: Self.head(#"<meta name="twitter:data2" content="4.5">"#)) == 4.5)
        #expect(LetterboxdRatings.parseRating(inPagePrefix: Self.head(#"<meta name="twitter:data2" content="5">"#)) == 5)
    }

    @Test func valuesOutsideTheFiveStarScaleAreRejected() {
        #expect(LetterboxdRatings.parseRating(inPagePrefix: Self.head(#"<meta name="twitter:data2" content="7 out of 5">"#)) == nil)
        #expect(LetterboxdRatings.parseRating(inPagePrefix: Self.head(#"<meta name="twitter:data2" content="7.2">"#)) == nil)
        #expect(LetterboxdRatings.parseRating(inPagePrefix: Self.head(#"<meta name="twitter:data2" content="4 out of 10">"#)) == nil)
        #expect(LetterboxdRatings.parseRating(inPagePrefix: Self.head(#"<meta name="twitter:data2" content="-1">"#)) == nil)
    }

    @Test func otherMetaTagsAndFreeTextAreIgnored() {
        let mixed = #"<meta name="twitter:card" content="summary" /><meta name="twitter:data2" content="4 out of 5" />"#
        #expect(LetterboxdRatings.parseRating(inPagePrefix: Self.head(mixed)) == 4)
        #expect(LetterboxdRatings.parseRating(inPagePrefix: Self.head(#"<meta name="twitter:data2" content="not rated">"#)) == nil)
        #expect(LetterboxdRatings.parseRating(inPagePrefix: Self.head(#"<meta data-name="twitter:data2" content="4 out of 5">"#)) == nil)
        #expect(LetterboxdRatings.parseRating(inPagePrefix: Self.head(#"<meta property="twitter:data2" content="4 out of 5">"#)) == nil)
        #expect(LetterboxdRatings.parseRating(inPagePrefix: Self.head("<title>Nothing here</title>")) == nil)
    }

    @Test func garbageHasNoRating() {
        #expect(LetterboxdRatings.parseRating(inPagePrefix: Data([0xFF, 0xFE, 0x00, 0x3C, 0x80])) == nil)
        #expect(LetterboxdRatings.parseRating(inPagePrefix: Data()) == nil)
    }

    @Test func aPrefixThatEndsMidCharacterStillParses() {
        // "é" is two bytes; cutting the second one leaves a broken character at the end of the prefix.
        let whole = Data(#"<meta name="twitter:data2" content="4.50 out of 5" />é"#.utf8)
        #expect(LetterboxdRatings.parseRating(inPagePrefix: whole.dropLast()) == 4.5)
    }
}
