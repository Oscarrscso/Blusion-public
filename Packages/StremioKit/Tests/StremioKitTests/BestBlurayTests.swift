import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

/// The pages under `Fixtures/bestblurays` are real bestblurays.com film pages cut down to their address data and the part that names
/// the best release (attributes stripped), so the parser meets the site's actual markup.
@Suite struct BestBlurayTests {
    private let base = URL(string: "https://www.bestblurays.com")!

    private func fixture(_ name: String) throws -> String {
        String(decoding: try Fixture.data("bestblurays/\(name).html"), as: UTF8.self)
    }

    private func parse(_ name: String) throws -> BestBluraysClient.ParsedFilm {
        BestBluraysClient.parseFilm(html: try fixture(name), pageURL: base.appendingPathComponent("film/\(name)"))
    }

    // MARK: reading a page

    @Test func aMainstream4KFilmNamesItsReleaseNotesAndTier() throws {
        let page = try parse("dark-knight-2008")
        #expect(page.imdbID == "tt0468569")
        let edition = try #require(page.edition)
        #expect(edition.filmTitle == "The Dark Knight (2008)")
        #expect(edition.release == "WB 4K Blu-ray")
        #expect(edition.heading == "Best English-friendly & video release")
        #expect(edition.updated == "updated 4 months ago")
        #expect(edition.uhdTier == "Solid")
        #expect(edition.videoNotes?.hasPrefix("Caveat: mild DNR throughout the transfer") == true, "a link inside the sentence does not split it")
        #expect(edition.is4K)
    }

    @Test func aReleaseSpreadAcrossLinksReadsAsOneLine() throws {
        let hoop = try #require(try parse("hoop-dreams-1994").edition)
        #expect(hoop.release == "Criterion Blu-ray and UK Dogwoof Blu-ray probably similar")
        #expect(!hoop.is4K && hoop.uhdTier == nil && hoop.videoNotes == nil)
        let oz = try #require(try parse("wizard-of-oz-1939").edition)
        #expect(oz.release.hasPrefix("2D: Warner Bros 4K Blu-ray") && oz.release.contains("3D Blu-ray"))
    }

    @Test func upcomingReleasesAndPressingNotesAreKept() throws {
        let edition = try #require(try parse("space-odyssey-1968").edition)
        #expect(edition.release == "WB 4K Blu-ray")
        #expect(edition.uhdTier == "Excellent")
        #expect(edition.videoNotes == "(early pressing has errors of a shot, later pressings fixed)")
        #expect(edition.upcoming?.hasPrefix("Criterion Box Set coming October 20th") == true)
    }

    /// The site's page since October 2026: the release is under the heading and its date on a line of its own (Best Blu-rays showed no
    /// edition for any film until this was read).
    @Test func thePageWithTheReleaseUnderItsHeadingNamesItToo() throws {
        let page = try parse("dark-knight-2008-october-2026")
        #expect(page.imdbID == "tt0468569")
        let edition = try #require(page.edition)
        #expect(edition.release == "WB 4K Blu-ray")
        #expect(edition.heading == "Best English-friendly & video release")
        #expect(edition.updated == "updated 4 months ago")
        #expect(edition.uhdTier == "Solid")
        #expect(edition.videoNotes?.hasPrefix("Caveat: mild DNR throughout the transfer") == true)
        #expect(edition.videoNotes?.contains("Updated") == false, "the date is not a note")
    }

    @Test func aLongNoteStopsAtTheUHDTier() throws {
        let edition = try #require(try parse("high-noon-1952").edition)
        #expect(edition.release == "MoC 4K Blu-ray")
        #expect(edition.videoNotes?.contains("Kino Lorber") == true)
        #expect(edition.videoNotes?.contains("Compare the discs") == false)
    }

    @Test func aPageThatNamesNoReleaseHasNoEdition() {
        let html = "<html><head><title>Obscure (1999) Blu-ray Guide</title></head><body><h2>Obscure</h2><p>Nothing here yet.</p></body></html>"
        let page = BestBluraysClient.parseFilm(html: html, pageURL: base)
        #expect(page.edition == nil && page.title == "Obscure (1999)" && page.imdbID == nil)
    }

    @Test func titleCaseReleaseHeadingFromCurrentSiteIsRecognized() throws {
        let html = """
        <html><head><title>The Dark Knight (2008) 4K Blu-ray Guide</title></head><body>
        <h5>Best English-Friendly Release</h5><p><a>WB</a> <a>4K Blu-ray</a></p>
        <h5>Best Video Release</h5><p>WB 4K Blu-ray</p>
        </body></html>
        """
        let page = BestBluraysClient.parseFilm(html: html, pageURL: base)
        let edition = try #require(page.edition)
        #expect(edition.heading == "Best English-Friendly Release")
        #expect(edition.release == "WB 4K Blu-ray")
    }

    @Test func scriptsStylesCommentsAndEntitiesNeverReachTheText() {
        let html = #"<p>A &amp; B&#x27;s &#8211; <!-- hidden -->film</p><script>var x = "<p>no</p>";</script><style>p{}</style><p>Next&nbsp;line</p>"#
        #expect(BestBluraysText.tokens(in: html) == ["A & B's \u{2013} film", "Next line"])
        #expect(BestBluraysText.sentence(["mild", "DNR", ", throughout", "(see", "notes )"]) == "mild DNR, throughout (see notes)")
    }

    // MARK: finding the page

    @Test func slugsFollowTheSitesAddresses() {
        #expect(BestBluraysClient.slug("The Dark Knight") == "the-dark-knight")
        #expect(BestBluraysClient.slug("Winchester '73") == "winchester-73")
        #expect(BestBluraysClient.slug("2001: A Space Odyssey") == "2001-a-space-odyssey")
        #expect(BestBluraysClient.slug("Amélie") == "amelie")
        #expect(BestBluraysClient.slug("  Fast & Furious!  ") == "fast-furious")
    }

    @Test func searchResultsAreReadInOrderAndRankedForTheTitleAndYear() throws {
        let links = BestBluraysClient.filmLinks(in: try fixture("search-dark-knight"))
        #expect(links.map(\.path) == ["/film/1810-the-dark-knight-rises-2012", "/film/652-the-dark-knight-2008", "/film/1749-batman-begins-2005"])
        #expect(links[1].slug == "the-dark-knight" && links[1].year == "2008")
        let ranked = BestBluraysClient.rank(links, title: "The Dark Knight", year: "2008")
        #expect(ranked.first?.path == "/film/652-the-dark-knight-2008", "the exact title and year come before the sequel the site lists first")
        let byTitleOnly = BestBluraysClient.rank(links, title: "The Dark Knight", year: nil)
        #expect(byTitleOnly.first?.path == "/film/652-the-dark-knight-2008")
        #expect(BestBluraysClient.filmLinks(in: "<a href=\"/film/9-x-1999\">a</a><a href=\"/film/9-x-1999\">again</a>").count == 1)
    }

    // MARK: the client

    private func site(search: String, pages: [String: String]) -> StubTransport {
        StubTransport { request, _ in
            let url = try #require(request.url)
            let body = url.path == "/films" ? search : pages[url.path] ?? ""
            return StubTransport.response(Data(body.utf8), status: body.isEmpty ? 404 : 200, for: request)
        }
    }

    @Test func theClientOpensTheMatchingPageFirstAndConfirmsTheIMDbID() async throws {
        let transport = site(search: try fixture("search-dark-knight"),
                             pages: ["/film/652-the-dark-knight-2008": try fixture("dark-knight-2008")])
        let result = try await BestBluraysClient(client: makeClient(transport, retries: 0)).bestEdition(imdbID: "tt0468569", title: "The Dark Knight", year: "2008")
        guard case .edition(let edition) = result else { Issue.record("expected an edition, got \(result)"); return }
        #expect(edition.release == "WB 4K Blu-ray")
        #expect(edition.pageURL.absoluteString == "https://www.bestblurays.com/film/652-the-dark-knight-2008")
        let paths = transport.requests.compactMap { $0.url?.path }
        #expect(paths == ["/films", "/film/652-the-dark-knight-2008"], "no other film's page was opened")
        let search = try #require(transport.requests.first?.url)
        #expect(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "title", value: "The Dark Knight")])
        #expect(transport.requests.first?.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Blusion") == true)
        #expect(transport.limits.allSatisfy { $0.truncateAtLimit && $0.maxBytes <= 256 * 1024 }, "only the top of a page is read")
    }

    @Test func aPageForAnotherFilmWithTheSameTitleIsSkipped() async throws {
        let search = #"<a href="/film/10-hamlet-1996">x</a><a href="/film/11-hamlet-1990">y</a>"#
        let other = try fixture("hoop-dreams-1994")   // carries tt0110057, not the film asked for
        let transport = site(search: search, pages: ["/film/10-hamlet-1996": other, "/film/11-hamlet-1990": other])
        let result = try await BestBluraysClient(client: makeClient(transport, retries: 0)).bestEdition(imdbID: "tt0116477", title: "Hamlet", year: "1996")
        guard case .noPage(let searchURL) = result else { Issue.record("expected noPage, got \(result)"); return }
        #expect(searchURL.absoluteString == "https://www.bestblurays.com/films?title=Hamlet")
    }

    @Test func aFilmWithoutANamedReleaseSaysSo() async throws {
        let page = "<html><head><title>Obscure (1999) Blu-ray Guide</title><script>{\"sameAs\":[\"https://www.imdb.com/title/tt0000999\"]}</script></head><body><h2>x</h2></body></html>"
        let transport = site(search: #"<a href="/film/5-obscure-1999">o</a>"#, pages: ["/film/5-obscure-1999": page])
        let result = try await BestBluraysClient(client: makeClient(transport, retries: 0)).bestEdition(imdbID: "tt0000999", title: "Obscure", year: "1999")
        #expect(result == .pageWithoutEdition(title: "Obscure (1999)", url: URL(string: "https://www.bestblurays.com/film/5-obscure-1999")!))
    }

    @Test func aSearchWithNoFilmsIsNoPageAndAFailedRequestThrows() async throws {
        let empty = site(search: "<html><body>No results</body></html>", pages: [:])
        let none = try await BestBluraysClient(client: makeClient(empty, retries: 0)).bestEdition(imdbID: "tt1", title: "Nothing", year: nil)
        if case .noPage = none {} else { Issue.record("expected noPage, got \(none)") }
        #expect(empty.callCount == 1)
        let down = StubTransport { _, _ in throw AddonError.offline }
        await #expect(throws: AddonError.offline) {
            _ = try await BestBluraysClient(client: makeClient(down, retries: 0)).bestEdition(imdbID: "tt1", title: "Nothing", year: nil)
        }
    }
}
