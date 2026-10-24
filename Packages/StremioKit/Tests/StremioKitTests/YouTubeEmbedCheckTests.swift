import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

@Suite struct YouTubeEmbedCheckTests {
    /// A check whose answer is `status`, with no retries so each answer is seen once.
    private func check(status: Int) -> (YouTubeEmbedCheck, StubTransport) {
        let transport = StubTransport(data: Data(), status: status)
        return (YouTubeEmbedCheck(client: makeClient(transport, retries: 0)), transport)
    }

    @Test func aVideoThatCanBeEmbeddedIsAllowed() async {
        let (embed, transport) = check(status: 200)
        #expect(await embed.allowsEmbedding(videoID: "abc123"))
        #expect(transport.callCount == 1)
    }

    @Test func aVideoYouTubeRefusesOrCannotFindIsNotAllowed() async {
        for status in [400, 401, 403, 404] {
            let (embed, _) = check(status: status)
            #expect(await embed.allowsEmbedding(videoID: "abc123") == false, "status \(status)")
        }
    }

    @Test func otherStatusesAndFailuresLeaveTheDecisionToThePlayer() async {
        let (serverError, _) = check(status: 500)
        #expect(await serverError.allowsEmbedding(videoID: "abc123"), "a server error is not YouTube refusing the video")
        let (rateLimited, _) = check(status: 429)
        #expect(await rateLimited.allowsEmbedding(videoID: "abc123"), "a rate limit is not YouTube refusing the video")
        let offline = YouTubeEmbedCheck(client: makeClient(StubTransport { _, _ in throw URLError(.notConnectedToInternet) }, retries: 0))
        #expect(await offline.allowsEmbedding(videoID: "abc123"), "no answer at all: the player decides")
    }

    @Test func aMalformedIDIsRefusedWithoutARequest() async {
        for id in ["a b", "", "x/../y"] {
            let (embed, transport) = check(status: 200)
            #expect(await embed.allowsEmbedding(videoID: id) == false, "\(id)")
            #expect(transport.callCount == 0, "no request for \(id)")
        }
    }

    @Test func theOEmbedAddressNamesTheWatchPageOfTheVideo() async throws {
        let (embed, transport) = check(status: 200)
        #expect(await embed.allowsEmbedding(videoID: "EXeTwQWrcwY"))
        let request = try #require(transport.requests.first)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https" && components.host == "www.youtube.com" && components.path == "/oembed")
        let items = components.queryItems ?? []
        #expect(items.first { $0.name == "format" }?.value == "json")
        #expect(items.first { $0.name == "url" }?.value == "https://www.youtube.com/watch?v=EXeTwQWrcwY")
        let expected = "https://www.youtube.com/oembed?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DEXeTwQWrcwY&format=json"
        #expect(url.absoluteString == expected, "the address is exactly the documented oEmbed form")
        #expect(YouTubeEmbedCheck.url(videoID: "a b") == nil)
    }

    /// A check whose answer is a 200 with `body`.
    private func check(body: String) -> YouTubeEmbedCheck {
        YouTubeEmbedCheck(client: makeClient(StubTransport(data: Data(body.utf8)), retries: 0))
    }

    @Test func theAnswerGivesThePicturesShape() async throws {
        let wide = await check(body: #"{"width":200,"height":113}"#).check(videoID: "abc123")
        #expect(wide.allowsEmbedding)
        let widescreen = try #require(wide.aspectRatio)
        #expect(abs(widescreen - 200.0 / 113.0) < 0.0001)
        let standard = try #require(await check(body: #"{"width":200,"height":150}"#).check(videoID: "abc123").aspectRatio)
        #expect(abs(standard - 4.0 / 3.0) < 0.0001)
    }

    @Test func numericTextIsReadAsASize() {
        #expect(YouTubeEmbedCheck.aspectRatio(from: Data(#"{"width":"200","height":"100"}"#.utf8)) == 2.0)
    }

    @Test func aBodyWithoutAUsableSizeGivesNoShapeButStillAllowsTheVideo() async {
        let bodies = [#"{"title":"No size"}"#, #"{"width":0,"height":113}"#, #"{"width":200,"height":-3}"#,
                      #"{"width":200,"height":"tall"}"#, #"[200,113]"#, "not json", ""]
        for body in bodies {
            let answer = await check(body: body).check(videoID: "abc123")
            #expect(answer.aspectRatio == nil, "\(body)")
            #expect(answer.allowsEmbedding, "no size is not a refusal: \(body)")
        }
    }

    @Test func aRefusedVideoGivesNoShape() async {
        let (embed, _) = check(status: 401)
        let answer = await embed.check(videoID: "abc123")
        #expect(answer == YouTubeEmbedCheck.Answer(allowsEmbedding: false))
    }

    @Test func aMalformedIDGivesNoShapeAndNoRequest() async {
        let (embed, transport) = check(status: 200)
        #expect(await embed.check(videoID: "a b") == YouTubeEmbedCheck.Answer(allowsEmbedding: false))
        #expect(transport.callCount == 0)
    }
}
