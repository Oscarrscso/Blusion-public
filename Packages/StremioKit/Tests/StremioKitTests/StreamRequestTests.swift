import Foundation
import Testing
@testable import StremioKit

@Suite struct StreamRequestTests {
    @Test func runtimesReadAsDurations() {
        #expect(StreamRequest.duration(fromRuntime: "152 min") == 9120)
        #expect(StreamRequest.duration(fromRuntime: "49 min") == 2940)
        #expect(StreamRequest.duration(fromRuntime: "2h 32min") == 9120)
        #expect(StreamRequest.duration(fromRuntime: "1 h 5 m") == 3900)
        #expect(StreamRequest.duration(fromRuntime: "95") == 5700, "a bare number is minutes")
        #expect(StreamRequest.duration(fromRuntime: " 1h30m ") == 5400)
        #expect(StreamRequest.duration(fromRuntime: "2 hours 5 minutes") == 7500)
        #expect(StreamRequest.duration(fromRuntime: "2 h 32") == 9120)
    }

    @Test func unreadableAndZeroRuntimesGiveNothing() {
        let texts: [String?] = [nil, "", "0 min", "0", "abc", "1h 2 min 3 sec", "152 minutes long", "h", "-5 min"]
        for text in texts {
            #expect(StreamRequest.duration(fromRuntime: text) == nil, "\(text ?? "nil")")
        }
    }

    @Test func aYearIsTheFirstFourDigitRun() {
        #expect(StreamRequest.releaseYear(in: "2010") == "2010")
        #expect(StreamRequest.releaseYear(in: "2008–2013") == "2008")
        #expect(StreamRequest.releaseYear(in: "Jan 5, 2010") == "2010")
        #expect(StreamRequest.releaseYear(in: "12345") == nil, "five digits are not a year")
        #expect(StreamRequest.releaseYear(in: "") == nil)
        #expect(StreamRequest.releaseYear(in: nil) == nil)
    }

    @Test func movieRequestsTakeTheYearAndRuntimeOfTheMovie() {
        let preview = MetaPreview(id: "tt1", type: "movie", name: "Film", releaseInfo: "2010", runtime: "152 min")
        let request = StreamRequest(movie: preview)
        #expect(request.year == "2010")
        #expect(request.expectedDuration == 9120)
        #expect(request.seriesName == nil)
    }

    @Test func episodeRequestsTakeTheSeriesNameYearAndRuntime() {
        let video = Video(id: "tt9:2:5", title: "Pilot", season: 2, episode: 5)
        let next = Video(id: "tt9:2:6", title: "Second", season: 2, episode: 6)
        let series = MetaDetail(preview: MetaPreview(id: "tt9", type: "series", name: "Show", releaseInfo: "2008–2013", runtime: "49 min"),
                                videos: [video, next])
        let request = StreamRequest(episode: video, of: series)
        #expect(request.seriesName == "Show")
        #expect(request.year == "2008")
        #expect(request.expectedDuration == 2940)
        #expect(request.title == "Show · Pilot")
        let following = request.nextRequest
        #expect(following?.title == "Show · Second")
        #expect(following?.seriesName == "Show")
        #expect(following?.year == "2008")
        #expect(following?.expectedDuration == 2940)
    }

    @Test func anEpisodeThatHasNotAiredIsNeverTheNextOne() {
        let pilot = Video(id: "tt9:1:1", title: "Pilot", season: 1, episode: 1, released: "2008-01-20T00:00:00.000Z")
        let second = Video(id: "tt9:1:2", title: "Second", season: 1, episode: 2, released: "2008-01-27T00:00:00.000Z")
        let finale = Video(id: "tt9:1:3", title: "Finale", season: 1, episode: 3, released: "2099-01-01T00:00:00.000Z")
        let series = MetaDetail(preview: MetaPreview(id: "tt9", type: "series", name: "Show"), videos: [pilot, second, finale])
        #expect(StreamRequest(episode: pilot, of: series).nextID == "tt9:1:2", "an aired next episode is still offered")
        #expect(StreamRequest(episode: second, of: series).nextRequest == nil, "the finale airs in 2099: nothing to binge into")
    }

    @Test func requestsWrittenBeforeTheseFieldsExistStillDecode() throws {
        let decoded = try JSONDecoder().decode(StreamRequest.self, from: Data(#"{"type":"movie","id":"tt1","title":"Film"}"#.utf8))
        #expect(decoded.seriesName == nil && decoded.year == nil && decoded.expectedDuration == nil)
        #expect(decoded.identity == "movie/tt1")
    }
}
