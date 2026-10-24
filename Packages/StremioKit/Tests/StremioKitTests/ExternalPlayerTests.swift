import Foundation
import Testing
@testable import StremioKit

@Suite struct ExternalPlayerTests {
    private func url(_ text: String) -> URL { URL(string: text)! }

    // MARK: the hand-off link

    @Test func aFullRequestMakesTheExactInfuseLink() throws {
        let request = ExternalPlaybackRequest(
            streamURL: url("https://cdn.example.com/Movie%20One/film.mkv"), position: 1234, filename: "Inception-2010.mkv",
            subtitleURL: url("https://subs.example.com/en.srt"),
            successCallback: url("blusion://x-callback-url/handoff/abc/finished"), errorCallback: url("blusion://x-callback-url/handoff/abc/failed"))
        let link = try #require(ExternalPlayer.infuse.playURL(for: request))
        #expect(link.absoluteString == "infuse://x-callback-url/play?url=https%3A%2F%2Fcdn.example.com%2FMovie%2520One%2Ffilm.mkv"
                + "&position=1234&filename=Inception-2010.mkv&sub=https%3A%2F%2Fsubs.example.com%2Fen.srt"
                + "&x-success=blusion%3A%2F%2Fx-callback-url%2Fhandoff%2Fabc%2Ffinished"
                + "&x-error=blusion%3A%2F%2Fx-callback-url%2Fhandoff%2Fabc%2Ffailed")
    }

    @Test func aSaveRequestMakesTheExactInfuseSaveLinkWithoutDownloading() throws {
        let request = ExternalPlaybackRequest(
            streamURL: url("https://cdn.example.com/Movie%20One/film.mkv"), position: 1234, filename: "Inception-2010.mkv",
            subtitleURL: url("https://subs.example.com/en.srt"), successCallback: ExternalPlayerCallback.savedURL)
        let link = try #require(ExternalPlayer.infuse.saveURL(for: request))
        #expect(link.absoluteString == "infuse://x-callback-url/save?url=https%3A%2F%2Fcdn.example.com%2FMovie%2520One%2Ffilm.mkv"
                + "&filename=Inception-2010.mkv&sub=https%3A%2F%2Fsubs.example.com%2Fen.srt&download=0"
                + "&x-success=blusion%3A%2F%2Fx-callback-url%2Fsaved", "the position is not part of a save")
        let bare = try #require(ExternalPlayer.infuse.saveURL(for: ExternalPlaybackRequest(streamURL: url("https://cdn.example.com/a.mp4"))))
        #expect(bare.absoluteString == "infuse://x-callback-url/save?url=https%3A%2F%2Fcdn.example.com%2Fa.mp4&download=0")
    }

    @Test func theSavedCallbackIsNotAHandoff() throws {
        let saved = try #require(ExternalPlayerCallback.savedURL)
        #expect(saved.absoluteString == "blusion://x-callback-url/saved")
        #expect(ExternalPlayerCallback.parse(saved) == nil, "coming back from a save records nothing")
    }

    @Test func nilZeroAndEmptyOptionalsAreLeftOut() throws {
        let stream = url("https://cdn.example.com/a.mp4")
        let bare = try #require(ExternalPlayer.infuse.playURL(for: ExternalPlaybackRequest(streamURL: stream)))
        #expect(bare.absoluteString == "infuse://x-callback-url/play?url=https%3A%2F%2Fcdn.example.com%2Fa.mp4")
        let zero = try #require(ExternalPlayer.infuse.playURL(for: ExternalPlaybackRequest(streamURL: stream, position: 0, filename: "")))
        #expect(zero == bare, "a zero position and an empty filename are not sent")
        let negative = try #require(ExternalPlayer.infuse.playURL(for: ExternalPlaybackRequest(streamURL: stream, position: -5)))
        #expect(negative == bare)
    }

    @Test func aStreamURLWithSpacesSymbolsAndUnicodeSurvivesTheRoundTrip() throws {
        let stream = url("https://cdn.example.com/é/Some%20Movie%20%26%20Co/a=b.mkv?token=1&x=2#frag")
        let request = ExternalPlaybackRequest(streamURL: stream, filename: "Some Movie & Co?.mkv", subtitleURL: stream)
        let link = try #require(ExternalPlayer.infuse.playURL(for: request))
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "url" }?.value == stream.absoluteString)
        #expect(items.first { $0.name == "sub" }?.value == stream.absoluteString)
        #expect(items.first { $0.name == "filename" }?.value == "Some Movie & Co?.mkv")
        #expect(!link.absoluteString.contains(" "), "nothing unescaped reaches the link")
    }

    @Test func canPlayOnlyPlainHTTPStreams() {
        #expect(ExternalPlayer.infuse.canPlay(streamURL: url("https://a.example.com/x.mkv"), headers: [:]))
        #expect(ExternalPlayer.infuse.canPlay(streamURL: url("http://a.example.com/x.mp4"), headers: [:]))
        #expect(ExternalPlayer.infuse.canPlay(streamURL: url("HTTPS://A.EXAMPLE.COM/x.mkv"), headers: [:]))
        #expect(!ExternalPlayer.infuse.canPlay(streamURL: url("ftp://a.example.com/x.mkv"), headers: [:]))
        #expect(!ExternalPlayer.infuse.canPlay(streamURL: url("file:///tmp/x.mkv"), headers: [:]))
        #expect(!ExternalPlayer.infuse.canPlay(streamURL: url("rtmp://a.example.com/live"), headers: [:]))
        #expect(!ExternalPlayer.infuse.canPlay(streamURL: url("https://a.example.com/x.mkv"), headers: ["Referer": "https://r.example.com"]),
                "a stream that needs request headers stays in Blusion")
    }

    @Test func theExtensionOfAContainerNamesItsFile() {
        #expect(MediaContainer.matroska.fileExtension == "mkv")
        #expect(MediaContainer.mp4.fileExtension == "mp4")
        #expect(MediaContainer.mpegTS.fileExtension == "ts")
        #expect(MediaContainer.hls.fileExtension == "m3u8")
    }

    // MARK: the callbacks

    @Test func callbackURLsCarryTheTokenInThePath() {
        #expect(ExternalPlayerCallback.successURL(token: "abc")?.absoluteString == "blusion://x-callback-url/handoff/abc/finished")
        #expect(ExternalPlayerCallback.errorURL(token: "abc")?.absoluteString == "blusion://x-callback-url/handoff/abc/failed")
        #expect(ExternalPlayerCallback.successURL(token: "") == nil)
        #expect(ExternalPlayerCallback.errorURL(token: "") == nil)
    }

    @Test func aFinishedCallbackReadsItsPosition() throws {
        let parsed = try #require(ExternalPlayerCallback.parse(url("blusion://x-callback-url/handoff/abc/finished?lastPlayedUrl=https%3A%2F%2Fh%2Fv.mkv&position=1234")))
        #expect(parsed.token == "abc")
        #expect(parsed.result == .finished(position: 1234))
    }

    @Test func aFailedCallbackReadsItsCodeAndMessage() throws {
        let parsed = try #require(ExternalPlayerCallback.parse(url("blusion://x-callback-url/handoff/abc/failed?errorCode=404&errorMessage=Not%20found")))
        #expect(parsed.token == "abc")
        #expect(parsed.result == .failed(code: "404", message: "Not found"))
    }

    @Test func callbacksWithoutAQueryOrWithDecimalPositions() throws {
        let bare = try #require(ExternalPlayerCallback.parse(url("blusion://x-callback-url/handoff/abc/finished")))
        #expect(bare.result == .finished(position: nil))
        let failed = try #require(ExternalPlayerCallback.parse(url("blusion://x-callback-url/handoff/abc/failed")))
        #expect(failed.result == .failed(code: nil, message: nil))
        let decimal = try #require(ExternalPlayerCallback.parse(url("blusion://x-callback-url/handoff/abc/finished?position=12.7&unknown=1")))
        #expect(decimal.result == .finished(position: 12.7), "unknown parameters are ignored")
        let junk = try #require(ExternalPlayerCallback.parse(url("blusion://x-callback-url/handoff/abc/finished?position=soon")))
        #expect(junk.result == .finished(position: nil))
    }

    @Test func anyOtherURLIsNotOurs() {
        #expect(ExternalPlayerCallback.parse(url("https://example.com/handoff/abc/finished")) == nil)
        #expect(ExternalPlayerCallback.parse(url("blusion://other-host/handoff/abc/finished")) == nil)
        #expect(ExternalPlayerCallback.parse(url("blusion://x-callback-url/handoff/abc/unknown")) == nil)
        #expect(ExternalPlayerCallback.parse(url("blusion://x-callback-url/abc/finished")) == nil)
        #expect(ExternalPlayerCallback.parse(url("blusion://x-callback-url/handoff/abc/finished/extra")) == nil)
        #expect(ExternalPlayerCallback.parse(url("infuse://x-callback-url/handoff/abc/finished")) == nil)
    }

    @Test func callbackTokensRoundTrip() throws {
        let link = try #require(ExternalPlayerCallback.successURL(token: "a b/c"))
        let parsed = try #require(ExternalPlayerCallback.parse(link))
        #expect(parsed.token == "a b/c", "the token is decoded from the path, so a slash inside it cannot change the path's shape")
    }

    // MARK: file names

    @Test func fileNamesFollowInfusesStyle() {
        #expect(ExternalPlayerCallback.filename(title: "Inception", year: "2010", season: nil, episode: nil, fileExtension: "mkv") == "Inception-2010.mkv")
        #expect(ExternalPlayerCallback.filename(title: "Breaking Bad", year: "2008", season: 2, episode: 5, fileExtension: "MKV")
                == "Breaking-Bad-S02-E05.mkv", "a season and episode take the place of the year")
        #expect(ExternalPlayerCallback.filename(title: "Mad Men", year: nil, season: 1, episode: 1, fileExtension: "mp4") == "Mad-Men-S01-E01.mp4")
        #expect(ExternalPlayerCallback.filename(title: "Some Title", year: nil, season: nil, episode: nil, fileExtension: nil) == "Some-Title.mp4")
    }

    @Test func fileNameRulesDropCharactersAndDefaultTheExtension() {
        #expect(ExternalPlayerCallback.filename(title: "Spider-Man: Homecoming!", year: "2017", season: nil, episode: nil, fileExtension: "mp4")
                == "Spider-Man-Homecoming-2017.mp4")
        #expect(ExternalPlayerCallback.filename(title: "Mr. Robot", year: nil, season: nil, episode: nil, fileExtension: nil) == "Mr-Robot.mp4")
        #expect(ExternalPlayerCallback.filename(title: "A  -  B", year: nil, season: nil, episode: nil, fileExtension: nil) == "A-B.mp4")
        #expect(ExternalPlayerCallback.filename(title: "Amélie", year: nil, season: nil, episode: nil, fileExtension: nil) == "Amélie.mp4")
        #expect(ExternalPlayerCallback.filename(title: "?? ", year: nil, season: nil, episode: nil, fileExtension: nil) == "Video.mp4")
        #expect(ExternalPlayerCallback.filename(title: "Film", year: "", season: nil, episode: nil, fileExtension: "") == "Film.mp4")
        #expect(ExternalPlayerCallback.filename(title: "Film", year: nil, season: nil, episode: nil, fileExtension: ".MP4") == "Film.mp4")
        #expect(ExternalPlayerCallback.filename(title: "Film", year: "2010–2015", season: nil, episode: nil, fileExtension: nil) == "Film-2010.mp4",
                "only the year is kept from a range")
        #expect(ExternalPlayerCallback.filename(title: "Show", year: nil, season: 0, episode: 12, fileExtension: nil) == "Show-S00-E12.mp4")
    }

    /// What Infuse 8.5 really sends: the stream's URL is appended raw, so a URL with its own query spills its parameters into ours.
    @Test func theCallbackSurvivesAnUnencodedStreamURLWithItsOwnQuery() throws {
        let raw = "blusion://x-callback-url/handoff/abc/finished?lastPlayedUrl=https://files.example.com/v.mkv?sig=1&position=3&position=1234"
        let url = try #require(URL(string: raw))
        let parsed = try #require(ExternalPlayerCallback.parse(url))
        #expect(parsed.token == "abc")
        #expect(parsed.result == .finished(position: 1234), "the player's own position is the last one")
    }
}
