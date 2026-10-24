import Foundation
import Testing
@testable import StremioKit

@Suite struct ResponseDecodingTests {
    private func data(_ name: String) throws -> Data { try Fixture.data("responses/\(name).json") }

    private struct MissingMeta: Error {}

    private func loadMeta(_ blob: Data, defaultType: String = "") throws -> MetaDetail {
        guard let detail = try ResponseDecoder.meta(from: blob, defaultType: defaultType) else { throw MissingMeta() }
        return detail
    }

    @Test func catalogBasic() throws {
        let metas = try ResponseDecoder.catalog(from: data("catalog-basic"), defaultType: "movie")
        #expect(metas.map(\.id) == ["tt0000001", "tt0000002"])
        #expect(metas[0].imdbRating == 7.5)
        #expect(metas[0].genres == ["Action", "Drama"])
        #expect(metas[0].releaseInfo == "1999")
        #expect(metas[0].poster?.absoluteString == "https://example.com/1.jpg")
    }

    @Test func catalogNumbersAsStrings() throws {
        let m = try #require(ResponseDecoder.catalog(from: data("catalog-strnums")).first)
        #expect(m.imdbRating == 8.1)
        #expect(m.releaseInfo == "2010")
        #expect(m.runtime == "120")
    }

    @Test func catalogDropsBadItemsAndKeepsGoodOnes() throws {
        let metas = try ResponseDecoder.catalog(from: data("catalog-nulls"))
        #expect(metas.map(\.id) == ["tt0000004", "tt0000005"])
        #expect(metas[0].genres.isEmpty)
        #expect(metas[0].poster == nil)
        #expect(metas[1].poster == nil, "about:blank is not a poster")
        #expect(metas[1].genres == ["Action", "Comedy"])
    }

    @Test func nullOrWronglyShapedMetasAreEmptyNotErrors() throws {
        #expect(try ResponseDecoder.catalog(from: data("catalog-metas-null")).isEmpty)
        #expect(try ResponseDecoder.catalog(from: data("catalog-wrong-shape")).isEmpty)
        #expect(try ResponseDecoder.catalog(from: Data("{}".utf8)).isEmpty)
        #expect(try ResponseDecoder.catalog(from: Data(#"{"err": "nope"}"#.utf8)).isEmpty)
    }

    @Test func defaultTypeFillsMissingType() throws {
        let metas = try ResponseDecoder.catalog(from: data("catalog-nulls"), defaultType: "movie")
        #expect(metas.allSatisfy { $0.type == "movie" })
        let explicit = try ResponseDecoder.catalog(from: data("catalog-basic"), defaultType: "series")
        #expect(explicit.allSatisfy { $0.type == "movie" }, "an explicit type is never overwritten")
    }

    @Test func metaDetail() throws {
        let meta = try loadMeta(data("meta-movie"))
        #expect(meta.name == "One")
        #expect(meta.preview.imdbRating == 7.5)
        #expect(meta.released == "1999-03-31T00:00:00.000Z")
        #expect(meta.preview.runtime == "136 min")
        #expect(meta.director == ["Dir A"])
        #expect(meta.cast == ["Actor A", "Actor B"])
        #expect(meta.writers == ["Writer A"])
        #expect(meta.links.map(\.name) == ["Action"], "a link without a name is dropped")
        #expect(meta.defaultVideoID == "tt0000001")
        #expect(meta.preview.background?.host == "example.com")
    }

    @Test func seriesEpisodesAreGroupedAndOrdered() throws {
        let meta = try loadMeta(data("meta-series"))
        #expect(meta.videos.count == 4, "the video without an id is dropped")
        #expect(meta.seasons == [1, 2, 0], "specials last")
        #expect(meta.episodes(inSeason: 1).map(\.title) == ["One", "Two"])
        #expect(meta.episodes(inSeason: 1).first?.season == 1, "season given as a string is coerced")
        #expect(meta.episodes(inSeason: 9).isEmpty)
    }

    @Test func nextEpisodeFollowsWatchingOrder() throws {
        let meta = try loadMeta(data("meta-series"))
        func video(_ id: String) throws -> Video { try #require(meta.videos.first { $0.id == id }) }
        #expect(meta.nextVideo(after: try video("tt0000010:1:1"))?.id == "tt0000010:1:2")
        #expect(meta.nextVideo(after: try video("tt0000010:1:2"))?.id == "tt0000010:2:1", "rolls over into the next season")
        #expect(meta.nextVideo(after: try video("tt0000010:2:1")) == nil, "the finale does not roll into specials")
        #expect(meta.nextVideo(after: try video("tt0000010:0:1")) == nil, "last in the list")
        #expect(meta.nextVideo(after: Video(id: "unknown")) == nil)
    }

    @Test func previousEpisodeStepsBackAcrossSeasonsButNeverIntoSpecials() throws {
        let meta = try loadMeta(data("meta-series"))
        func video(_ id: String) throws -> Video { try #require(meta.videos.first { $0.id == id }) }
        #expect(meta.previousVideo(before: try video("tt0000010:1:2"))?.id == "tt0000010:1:1")
        #expect(meta.previousVideo(before: try video("tt0000010:2:1"))?.id == "tt0000010:1:2", "back across the season's start")
        #expect(meta.previousVideo(before: try video("tt0000010:1:1")) == nil, "the first episode has none")
        #expect(meta.previousVideo(before: try video("tt0000010:0:1")) == nil, "a special does not step back into a regular season")
        #expect(meta.previousVideo(before: Video(id: "unknown")) == nil)
    }

    @Test func aSwitcherOffersNeitherAMissingNorAnUnairedEpisode() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let videos = [Video(id: "s:1:1", season: 1, episode: 1, released: "2020-01-01T00:00:00.000Z"),
                      Video(id: "s:1:2", season: 1, episode: 2, released: "2020-01-08T00:00:00.000Z"),
                      Video(id: "s:1:3", season: 1, episode: 3, released: "2030-01-01T00:00:00.000Z"),
                      Video(id: "s:0:1", season: 0, episode: 1),
                      Video(id: "s:0:2", season: 0, episode: 2)]
        let meta = MetaDetail(preview: MetaPreview(id: "s", type: "series", name: "S"), videos: videos)
        #expect(meta.neighbouringEpisodes(of: videos[4], by: now).previous?.id == "s:0:1", "specials step among themselves")
        let first = meta.neighbouringEpisodes(of: videos[0], by: now)
        #expect(first.previous == nil && first.next?.id == "s:1:2", "the first episode only steps forward")
        let second = meta.neighbouringEpisodes(of: videos[1], by: now)
        #expect(second.previous?.id == "s:1:1" && second.next == nil, "an episode that has not aired is not offered")
        let special = meta.neighbouringEpisodes(of: videos[3], by: now)
        #expect(special.previous == nil && special.next?.id == "s:0:2", "specials stay apart from the regular seasons")
    }

    @Test func requestsForEpisodesRememberTheNextOne() throws {
        let meta = try loadMeta(data("meta-series"))
        let first = try #require(meta.videos.first { $0.id == "tt0000010:1:1" })
        let request = StreamRequest(episode: first, of: meta)
        #expect(request.nextID == "tt0000010:1:2" && request.nextSeason == 1 && request.nextEpisode == 2)
        let next = try #require(request.nextRequest)
        #expect(next.id == "tt0000010:1:2" && next.title == "Series · Two" && next.type == "series")
        let finale = try #require(meta.videos.first { $0.id == "tt0000010:2:1" })
        #expect(StreamRequest(episode: finale, of: meta).nextRequest == nil)
        #expect(StreamRequest(movie: MetaPreview(id: "tt1", name: "M")).nextRequest == nil)
    }

    @Test func missingMetaIsNilNotAnError() throws {
        #expect(try ResponseDecoder.meta(from: data("meta-missing")) == nil)
        #expect(try ResponseDecoder.meta(from: Data("{}".utf8)) == nil)
        #expect(try ResponseDecoder.meta(from: Data(#"{"meta": {"name": "no id"}}"#.utf8)) == nil)
    }

    @Test func metaDefaultTypeAndFallback() throws {
        let meta = try loadMeta(Data(#"{"meta": {"id": "x"}}"#.utf8), defaultType: "movie")
        #expect(meta.type == "movie")
        let preview = MetaPreview(id: "p", type: "movie", name: "P")
        #expect(MetaDetail.fallback(from: preview).name == "P")
        #expect(MetaDetail.fallback(from: preview).videos.isEmpty)
    }

    @Test func metaRoundTrips() throws {
        let meta = try loadMeta(data("meta-series"))
        let again = try JSONDecoder().decode(MetaDetail.self, from: JSONEncoder().encode(meta))
        #expect(again == meta)
        let movie = try loadMeta(data("meta-movie"))
        #expect(try JSONDecoder().decode(MetaDetail.self, from: JSONEncoder().encode(movie)) == movie)
    }

    @Test func trailersComeFromTrailerStreamsThenTheOlderList() throws {
        let modern = Data(#"""
        {"meta":{"id":"tt1","type":"movie","name":"M",
         "trailerStreams":[{"title":"Trailer","ytId":"abc123"},{"ytId":""},{"title":"No id"},{"ytId":"abc123"},{"ytId":"def456"}],
         "trailers":[{"source":"zzz999","type":"Trailer"}]}}
        """#.utf8)
        #expect(try loadMeta(modern).trailers == ["abc123", "def456"], "empty and repeated ids are dropped; trailerStreams wins over trailers")
        let older = Data(#"""
        {"meta":{"id":"tt2","type":"movie","name":"M2",
         "trailers":[{"source":"old1","type":"Trailer"},{"source":""},{"source":"old1"}]}}
        """#.utf8)
        #expect(try loadMeta(older).trailers == ["old1"], "the older trailers list is used when trailerStreams gives no ids")
        #expect(try loadMeta(Data(#"{"meta":{"id":"tt3","type":"movie"}}"#.utf8)).trailers.isEmpty)
    }

    @Test func episodesFallBackToFirstAiredAndReadStringRatings() throws {
        let blob = Data(#"""
        {"meta":{"id":"tt9","type":"series","name":"Show","videos":[
          {"id":"tt9:1:1","season":1,"episode":1,"firstAired":"2008-01-20T00:00:00.000Z","rating":"8.4"},
          {"id":"tt9:1:2","season":1,"episode":2,"released":"2008-01-27T00:00:00.000Z","firstAired":"2008-01-27","rating":7.9}]}}
        """#.utf8)
        let meta = try loadMeta(blob)
        let first = try #require(meta.videos.first { $0.id == "tt9:1:1" })
        #expect(first.released == "2008-01-20T00:00:00.000Z", "firstAired stands in for a missing released")
        #expect(first.rating == 8.4)
        let second = try #require(meta.videos.first { $0.id == "tt9:1:2" })
        #expect(second.released == "2008-01-27T00:00:00.000Z", "released wins over firstAired")
        #expect(second.rating == 7.9)
        #expect(Video(id: "bare").rating == nil)
    }

    @Test func trailersAndVideoRatingsSurviveARoundTrip() throws {
        let blob = Data(#"""
        {"meta":{"id":"tt9","type":"series","name":"Show","trailerStreams":[{"ytId":"abc123"}],
         "videos":[{"id":"tt9:1:1","season":1,"episode":1,"firstAired":"2008-01-20","rating":"8.4"}]}}
        """#.utf8)
        let meta = try loadMeta(blob)
        let encoded = try JSONEncoder().encode(meta)
        let again = try JSONDecoder().decode(MetaDetail.self, from: encoded)
        #expect(again == meta)
        #expect(again.trailers == ["abc123"])
        #expect(again.videos.first?.rating == 8.4)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let streams = object["trailerStreams"] as? [[String: String]]
        #expect(streams == [["ytId": "abc123"]], "encoded as trailerStreams with ytId")
    }

    @Test func previewIdentityIncludesTheType() {
        #expect(MetaPreview(id: "tt1", type: "movie").identity == "movie/tt1")
        #expect(MetaPreview(id: "tt1", type: "series").identity != MetaPreview(id: "tt1", type: "movie").identity)
    }

    @Test func streamsOfEveryKind() throws {
        let streams = try ResponseDecoder.streams(from: data("streams-all-kinds"))
        #expect(streams.count == 8)
        #expect(streams[0].source == .direct(URL(string: "https://cdn.example.com/a.mp4")!))
        #expect(streams[0].description == "1080p\nline two")
        #expect(streams[0].behaviorHints.bingeGroup == "g1")
        #expect(streams[0].behaviorHints.videoSize == 1_048_576)
        #expect(streams[0].behaviorHints.filename == "a.mp4")
        #expect(streams[1].source == .torrent(infoHash: "abcdef0123456789abcdef0123456789abcdef01", fileIndex: 2, sources: ["tracker:udp://t.example:1"]))
        #expect(streams[1].description == "legacy title", "legacy `title` maps to description")
        #expect(streams[2].source == .youtube("aqz-KE-bpKQ"))
        #expect(streams[3].source == .external(URL(string: "https://example.com/watch")!))
        #expect(streams[4].source == .archive(kind: "nzbUrl"))
        #expect(streams[5].source == .archive(kind: "rarUrls"))
        #expect(streams[6].behaviorHints.notWebReady)
        #expect(streams[6].behaviorHints.proxyHeaders?.request == ["Referer": "https://example.com"])
        #expect(streams[6].behaviorHints.proxyHeaders?.response == ["X": "1"])
        #expect(streams[7].subtitles.count == 1, "a subtitle without a url is dropped")
    }

    @Test func streamsWithoutUsableSourceAreDropped() throws {
        let streams = try ResponseDecoder.streams(from: data("streams-bad-items"))
        #expect(streams.map(\.name) == ["ok"])
    }

    @Test func streamsRoundTrip() throws {
        let streams = try ResponseDecoder.streams(from: data("streams-all-kinds"))
        let encoded = try JSONEncoder().encode(["streams": streams])
        #expect(try ResponseDecoder.streams(from: encoded) == streams)
    }

    @Test func streamDisplayName() {
        let url = URL(string: "https://e.com/a.mp4")!
        #expect(AddonStream(name: "N", source: .direct(url)).displayName == "N")
        #expect(AddonStream(description: "first\nsecond", source: .direct(url)).displayName == "first")
        #expect(AddonStream(source: .direct(url)).displayName == "Stream")
    }

    @Test func subtitles() throws {
        let subs = try ResponseDecoder.subtitles(from: data("subtitles-basic"))
        #expect(subs.map(\.lang) == ["eng", "spa"])
        #expect(subs[0].id == "1")
        #expect(subs[1].id == "https://example.com/es.vtt", "id falls back to the url")
    }

    @Test func garbageIsInvalidJSONForEveryResource() {
        let junk = [Data(), Data("not json".utf8), Data("[]".utf8), Data("null".utf8), Data("{\"metas\":".utf8)]
        for blob in junk {
            #expect(throws: AddonError.invalidJSON) { try ResponseDecoder.catalog(from: blob) }
            #expect(throws: AddonError.invalidJSON) { try ResponseDecoder.meta(from: blob) }
            #expect(throws: AddonError.invalidJSON) { try ResponseDecoder.streams(from: blob) }
            #expect(throws: AddonError.invalidJSON) { try ResponseDecoder.subtitles(from: blob) }
        }
    }
}
