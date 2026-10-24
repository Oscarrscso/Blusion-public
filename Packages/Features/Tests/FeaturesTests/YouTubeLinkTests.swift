import Foundation
import Testing
@testable import Features

@Suite struct YouTubeLinkTests {
    @Test func aWellFormedIDMakesTheAppAndWebLinks() {
        #expect(YouTubeLink.appURL(videoID: "EXeTwQWrcwY")?.absoluteString == "youtube://www.youtube.com/watch?v=EXeTwQWrcwY")
        #expect(YouTubeLink.webURL(videoID: "EXeTwQWrcwY")?.absoluteString == "https://www.youtube.com/watch?v=EXeTwQWrcwY")
        #expect(YouTubeLink.webURL(videoID: "a-_9")?.absoluteString == "https://www.youtube.com/watch?v=a-_9")
    }

    @Test func aMalformedIDMakesNoLink() {
        for id in ["", "not an id", "abc&x=1", "abc/../evil", "https://youtu.be/abc", "abcé"] {
            #expect(YouTubeLink.appURL(videoID: id) == nil, "\(id) is not a YouTube id")
            #expect(YouTubeLink.webURL(videoID: id) == nil, "\(id) is not a YouTube id")
        }
    }

    @Test func theEmbedOriginIsTheBundleIDInLowercase() {
        #expect(YouTubeLink.embedOrigin(bundleID: "app.blusion.player")?.absoluteString == "https://app.blusion.player")
        #expect(YouTubeLink.embedOrigin(bundleID: "App.Blusion-Mac.Player")?.absoluteString == "https://app.blusion-mac.player")
    }

    @Test func aMissingOrOddBundleIDFallsBackToBlusionsOwnOrigin() {
        for bundleID in [nil, "", "bad id", "app/evil", "app.blusion.é"] {
            #expect(YouTubeLink.embedOrigin(bundleID: bundleID)?.absoluteString == "https://app.blusion.player", "\(bundleID ?? "nil")")
        }
    }

    @Test func theEmbedPageIsNilForAMalformedID() {
        let origin = URL(string: "https://app.blusion.player")!
        for id in ["", "not an id", "abc&x=1", "abc/../evil"] {
            #expect(YouTubeLink.embedPage(videoID: id, origin: origin) == nil, "\(id) is not a YouTube id")
        }
    }

    @Test func theEmbedPageLoadsTheVideoWithTheEncodedOriginAndReportsToTheHandler() throws {
        let origin = try #require(YouTubeLink.embedOrigin(bundleID: "app.blusion.player"))
        let page = try #require(YouTubeLink.embedPage(videoID: "EXeTwQWrcwY", origin: origin))
        #expect(page.contains("/embed/EXeTwQWrcwY?"), "the video's embedded player")
        #expect(page.contains("playsinline=1"), "plays in the panel, not full screen")
        #expect(page.contains("origin=https%3A%2F%2Fapp%2Eblusion%2Eplayer"), "the origin is percent-encoded as a query value")
        #expect(page.contains(#"referrerpolicy="strict-origin-when-cross-origin""#))
        #expect(page.contains("window.webkit.messageHandlers.trailer.postMessage"), "reports through the trailer message handler")
        #expect(!page.contains("VIDEO") && !page.contains("ORIGIN"), "no placeholder is left in the page")
    }
}
