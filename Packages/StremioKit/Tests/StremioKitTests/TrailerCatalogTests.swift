import Foundation
import Testing
@testable import StremioKit

@Suite struct TrailerCatalogTests {
    /// A TMDb video decoded from its wire form, so the tests read the same fields TMDb sends.
    private func tmdb(_ key: String, name: String = "Clip", type: String = "Trailer", official: Bool? = nil, language: String? = "en",
                      publishedAt: String? = nil) throws -> TMDbVideo {
        var json: [String: Any] = ["name": name, "key": key, "site": "YouTube", "type": type]
        if let official { json["official"] = official }
        if let language { json["iso_639_1"] = language }
        if let publishedAt { json["published_at"] = publishedAt }
        return try JSONDecoder().decode(TMDbVideo.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func merged(previews: [Trailer] = [], youtube: [String] = [], urls: [String] = [], tmdb: [TMDbVideo] = []) -> [Trailer] {
        TrailerCatalog.merge(previews: previews, addonYouTubeIDs: youtube, addonURLs: urls.compactMap(URL.init(string:)), tmdb: tmdb)
    }

    private func keys(_ trailers: [Trailer]) -> [String] { trailers.compactMap(\.youtubeID) }

    @Test func anAddonIDTMDbAlsoListsKeepsTheTMDbEntry() throws {
        let trailers = merged(youtube: ["abc123", "def456"], tmdb: [try tmdb("abc123", name: "  Official Trailer  ", official: true)])
        #expect(trailers.map(\.id) == ["yt:abc123", "yt:def456"])
        #expect(trailers[0].title == "Official Trailer", "the TMDb title is trimmed and kept")
        #expect(trailers[0].isOfficial && trailers[0].language == "en")
        #expect(trailers[1].title == "Trailer" && trailers[1].kind == .trailer, "an addon-only entry gets the plain title and kind")
        #expect(trailers[1].isOfficial && trailers[1].language == nil)
    }

    @Test func aDuplicatedAddonIDIsListedOnce() {
        let trailers = merged(youtube: ["abc123", "abc123", "not an id"])
        #expect(keys(trailers) == ["abc123"], "repeated and malformed addon ids are dropped")
    }

    @Test func anOfficialEnglishTeaserOutranksAnUnofficialEnglishTrailer() throws {
        let trailers = merged(tmdb: [try tmdb("unofficial", official: false), try tmdb("teaser", type: "Teaser", official: true)])
        #expect(keys(trailers) == ["teaser", "unofficial"], "language, then official, then kind")
    }

    @Test func englishBeforeNoLanguageBeforeOtherLanguagesAndOnlyTheBestThreeAreKept() throws {
        let trailers = merged(youtube: ["addon01"], tmdb: [
            try tmdb("french", official: true, language: "fr"),
            try tmdb("nolang", official: true, language: nil),
            try tmdb("english", official: false, language: "EN "),
        ])
        #expect(keys(trailers) == ["addon01", "english", "nolang"],
                "addon-only entries count as English and official; the French one falls past the three")
    }

    @Test func officialTrailersAreRankedNewestFirstAndUndatedLast() throws {
        let trailers = merged(tmdb: [
            try tmdb("undated", official: true),
            try tmdb("old", official: true, publishedAt: "2019-03-01T10:00:00.000Z"),
            try tmdb("new", official: true, publishedAt: "2024-07-15T10:00:00.000Z"),
        ])
        #expect(keys(trailers) == ["new", "old", "undated"], "the undated trailer comes last")
    }

    @Test func entriesThatTieKeepTheirSourceOrder() throws {
        let trailers = merged(youtube: ["second", "third"], tmdb: [try tmdb("first", official: true)])
        #expect(keys(trailers) == ["first", "second", "third"])
    }

    @Test func teasersAreIncludedWithTheirKind() throws {
        let trailers = merged(tmdb: [try tmdb("teaserKey", name: "  ", type: "Teaser")])
        #expect(trailers.count == 1)
        #expect(trailers[0].kind == .teaser)
        #expect(trailers[0].title == "Teaser", "a blank TMDb name falls back to the kind")
    }

    @Test func youTubeIsTheFallbackWhenNoDirectFileExistsAndAtMostThreeAreKept() {
        let trailers = merged(youtube: ["one", "two", "three", "four"])
        #expect(keys(trailers) == ["one", "two", "three"], "at most three YouTube trailers, in case YouTube refuses one")
    }

    @Test func aDirectFileIsOfferedAloneAndYouTubeIsLeftOut() throws {
        let preview = Trailer(source: .direct(URL(string: "https://audio-ssl.itunes.apple.com/a.m4v")!))
        let trailers = merged(previews: [preview], youtube: ["abc123"], urls: ["https://cdn.example.com/t.mp4"],
                              tmdb: [try tmdb("def456", official: true)])
        #expect(trailers.map(\.id) == ["url:https://audio-ssl.itunes.apple.com/a.m4v", "url:https://cdn.example.com/t.mp4"],
                "the iTunes preview is first, then the addon's direct link; no YouTube entry alongside a direct file")
    }

    @Test func directSourcesAreHTTPOnlyAndListedOnce() {
        let preview = Trailer(source: .direct(URL(string: "https://a.example.com/p.mp4")!))
        let trailers = merged(previews: [preview, Trailer(source: .direct(URL(string: "ftp://a.example.com/x.mp4")!))],
                              urls: ["https://a.example.com/p.mp4", "http://cdn.example.com/u.mp4", "ftp://cdn.example.com/v.mp4",
                                     "file:///tmp/w.mp4", "http://cdn.example.com/u.mp4"])
        #expect(trailers.map(\.id) == ["url:https://a.example.com/p.mp4", "url:http://cdn.example.com/u.mp4"])
        let direct = trailers[1]
        #expect(direct.directURL == URL(string: "http://cdn.example.com/u.mp4"))
        #expect(direct.youtubeID == nil && direct.isOfficial && direct.language == nil)
    }

    @Test func thumbnailsAreBestFirstForYouTubeAndEmptyForDirectSources() throws {
        let youtube = Trailer(source: .youtube("abc123"))
        #expect(youtube.thumbnailCandidates.map(\.absoluteString) == [
            "https://img.youtube.com/vi/abc123/maxresdefault.jpg",
            "https://img.youtube.com/vi/abc123/hq720.jpg",
            "https://img.youtube.com/vi/abc123/mqdefault.jpg",
        ])
        #expect(Trailer(source: .direct(URL(string: "https://cdn.example.com/t.mp4")!)).thumbnailCandidates.isEmpty)
    }

    @Test func parseVideosKeepsOnlyYouTubeTrailersAndTeasers() throws {
        let data = Data(#"""
        {"id":155,"results":[
            {"name":"Main","key":"abc123","site":"YouTube","type":"Trailer","official":true,"iso_639_1":"en","published_at":"2024-01-01T00:00:00.000Z"},
            {"name":"Vimeo","key":"123456","site":"Vimeo","type":"Trailer"},
            {"name":"Clip","key":"def456","site":"youtube","type":"Clip"},
            {"name":"Teaser","key":"ghi789","site":"YouTube","type":"teaser"},
            {"name":"Bad key","key":"not an id","site":"YouTube","type":"Trailer"},
            {"name":"Empty key","key":"","site":"YouTube","type":"Trailer"}
        ]}
        """#.utf8)
        let videos = try TMDbRatings.parseVideos(data)
        #expect(videos.map(\.key) == ["abc123", "ghi789"], "Vimeo, clips and ids that are not YouTube ids are dropped")
        #expect(videos[0].official == true && videos[0].iso_639_1 == "en" && videos[0].published_at == "2024-01-01T00:00:00.000Z")
        #expect(videos[1].official == nil, "a missing official flag stays unknown")
        #expect(try TMDbRatings.parseVideos(Data(#"{"results":[]}"#.utf8)).isEmpty)
        #expect(throws: AddonError.self) { try TMDbRatings.parseVideos(Data("nope".utf8)) }
        #expect(throws: AddonError.self) { try TMDbRatings.parseVideos(Data(#"{"id":1}"#.utf8)) }
    }

    @Test func playbackOrderListsTheDirectFilesThenTheThreeBestYouTubeTrailers() {
        let preview = Trailer(source: .direct(URL(string: "https://a.example.com/p.m4v")!))
        let order = TrailerCatalog.playbackOrder(previews: [preview], addonYouTubeIDs: ["one", "two", "three", "four"], addonURLs: [],
                                                 tmdb: [])
        #expect(order.map(\.id) == ["url:https://a.example.com/p.m4v", "yt:one", "yt:two", "yt:three"],
                "YouTube is the fallback after every direct file")
    }

    @Test func playbackOrderWithoutAnInAppSourceIsTheMergeList() {
        let ids = ["one", "two", "three"]
        let order = TrailerCatalog.playbackOrder(previews: [], addonYouTubeIDs: ids, addonURLs: [], tmdb: [])
        #expect(order.map(\.id) == ["yt:one", "yt:two", "yt:three"])
        #expect(order == TrailerCatalog.merge(previews: [], addonYouTubeIDs: ids, addonURLs: [], tmdb: []))
    }

    @Test func isYouTubeIDAcceptsOnlyShortASCIIIDs() {
        #expect(Trailer.isYouTubeID("EXeTwQWrcwY"))
        #expect(Trailer.isYouTubeID("a-_9"))
        #expect(!Trailer.isYouTubeID(""))
        #expect(!Trailer.isYouTubeID("not an id"))
        #expect(!Trailer.isYouTubeID("https://youtu.be/abc"))
        #expect(!Trailer.isYouTubeID("abcé"))
    }

    @Test func trailerStreamURLsDecodeDedupedAndSurviveARoundTrip() throws {
        let meta = try #require(try ResponseDecoder.meta(from: Data(#"""
        {"meta":{"id":"tt1","type":"movie","name":"M",
         "trailerStreams":[{"title":"Trailer","ytId":"abc123"},
                           {"title":"Direct","url":"https://cdn.example.com/t.mp4"},
                           {"url":"https://cdn.example.com/t.mp4"},
                           {"url":"ftp://example.com/x.mp4"},
                           {"url":"file:///tmp/x.mp4"},
                           {"ytId":"def456"}]}}
        """#.utf8)))
        #expect(meta.trailers == ["abc123", "def456"])
        #expect(meta.trailerURLs == [URL(string: "https://cdn.example.com/t.mp4")!])
        let encoded = try JSONEncoder().encode(meta)
        let again = try JSONDecoder().decode(MetaDetail.self, from: encoded)
        #expect(again == meta)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let streams = object["trailerStreams"] as? [[String: String]]
        #expect(streams == [["ytId": "abc123"], ["ytId": "def456"], ["url": "https://cdn.example.com/t.mp4"]])
        #expect(MetaDetail(preview: MetaPreview(id: "tt2")).trailerURLs.isEmpty)
    }
}
