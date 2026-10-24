import Foundation
import Testing
@testable import Features

@Suite struct TextLinksTests {
    /// The text each link covers, so a test reads the words it links rather than offsets.
    private func covered(_ links: [TextLink], in text: String) -> [String] {
        links.map { (text as NSString).substring(with: $0.range) }
    }

    @Test func aMarkdownLinkKeepsItsTextAndTarget() throws {
        let text = "Read the notes now"
        let target = try #require(URL(string: "https://example.com/notes"))
        let links = TextLinks.all(in: text, markdown: [TextLink(range: NSRange(location: 9, length: 5), url: target)])
        #expect(covered(links, in: text) == ["notes"])
        #expect(links.first?.url == target)
    }

    @Test func aBareURLIsLinkedAndItsSurroundingWordsAreNot() throws {
        let text = "Source: https://example.com/page here"
        let links = TextLinks.all(in: text)
        #expect(covered(links, in: text) == ["https://example.com/page"])
        #expect(links.first?.url.absoluteString == "https://example.com/page")
    }

    @Test func trailingPunctuationIsNotPartOfABareURL() {
        let text = "See https://example.com/page. Also (https://example.org/x), and https://example.net/y?"
        let links = TextLinks.all(in: text)
        #expect(covered(links, in: text) == ["https://example.com/page", "https://example.org/x", "https://example.net/y"])
    }

    @Test func linksComeInTheOrderTheyAppear() throws {
        // The text as shown: "[second](https://example.org/b)" has become "second", linked by its markdown target.
        let text = "First https://example.com/a then second and https://example.net/c"
        let target = try #require(URL(string: "https://example.org/b"))
        let markdownRange = (text as NSString).range(of: "second")
        let links = TextLinks.all(in: text, markdown: [TextLink(range: markdownRange, url: target)])
        #expect(covered(links, in: text) == ["https://example.com/a", "second", "https://example.net/c"])
        #expect(links.map(\.url.absoluteString) == ["https://example.com/a", "https://example.org/b", "https://example.net/c"])
    }

    @Test func aURLInsideAMarkdownLinkIsNotLinkedTwice() throws {
        let text = "https://example.com"
        let target = try #require(URL(string: "https://other.example.org/page"))
        let links = TextLinks.all(in: text, markdown: [TextLink(range: NSRange(location: 0, length: text.utf16.count), url: target)])
        #expect(links == [TextLink(range: NSRange(location: 0, length: text.utf16.count), url: target)])
    }

    @Test func aMarkdownLinkWhoseTextIsAURLKeepsItsOwnTarget() throws {
        let text = "see https://example.com/long/path"
        let target = try #require(URL(string: "https://example.com/short"))
        let range = (text as NSString).range(of: "https://example.com/long/path")
        let links = TextLinks.all(in: text, markdown: [TextLink(range: range, url: target)])
        #expect(links.count == 1)
        #expect(links.first?.url == target)
    }

    @Test func aJavascriptLinkIsRejected() throws {
        let target = try #require(URL(string: "javascript:alert(1)"))
        #expect(TextLinks.isWebLink(target) == false)
        #expect(TextLinks.all(in: "tap here", markdown: [TextLink(range: NSRange(location: 0, length: 3), url: target)]).isEmpty)
    }

    @Test func aMailtoLinkIsRejectedInMarkdownAndAsABareAddress() throws {
        let target = try #require(URL(string: "mailto:someone@example.com"))
        #expect(TextLinks.isWebLink(target) == false)
        #expect(TextLinks.all(in: "write to me", markdown: [TextLink(range: NSRange(location: 9, length: 2), url: target)]).isEmpty)
        #expect(TextLinks.all(in: "write to someone@example.com").isEmpty)
    }

    @Test func otherSchemesAreRejected() throws {
        for address in ["tel:+15551234", "file:///private/notes.txt", "ftp://example.com/file", "myapp://open/title"] {
            let target = try #require(URL(string: address))
            #expect(TextLinks.isWebLink(target) == false, "\(address) is not a web link")
        }
    }

    @Test func httpAndHTTPSAreWebLinks() throws {
        #expect(TextLinks.isWebLink(try #require(URL(string: "http://example.com"))))
        #expect(TextLinks.isWebLink(try #require(URL(string: "HTTPS://example.com"))))
    }

    @Test func aTextWithNoLinksHasNone() {
        #expect(TextLinks.all(in: "Plain words, with a full stop.").isEmpty)
        #expect(TextLinks.all(in: "").isEmpty)
    }

    @Test func aNameWithoutASchemeStaysPlain() {
        #expect(TextLinks.all(in: "Visit www.example.com for more").isEmpty)
    }
}
