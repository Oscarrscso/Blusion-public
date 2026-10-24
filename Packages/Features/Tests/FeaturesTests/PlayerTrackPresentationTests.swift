import Foundation
import Testing
import PlayerKit
@testable import Features

@Suite struct PlayerTrackPresentationTests {
    @Test func identicallyNamedEmbeddedTracksStayDistinctAndExplainTheirVariants() {
        let tracks = [
            MediaTrack(id: "s1", title: "English · Main", language: "eng", codec: "srt"),
            MediaTrack(id: "s2", title: "English · Main", language: "eng", isForced: true, codec: "ass"),
            MediaTrack(id: "s3", title: "English · Main", language: "eng", isHearingImpaired: true, codec: "hdmv_pgs_subtitle"),
        ]
        let rows = PlayerTrackPresentation.embedded(tracks + [tracks[0]])
        #expect(rows.map(\.id) == ["s1", "s2", "s3"])
        #expect(Set(rows.map(\.subtitle)).count == 3)
        #expect(rows[0].subtitle.contains("SRT") && rows[0].subtitle.contains("In video"))
        #expect(rows[1].tags == ["Forced"] && rows[2].tags == ["SDH"])
    }

    @Test func onlineRowsShowSourceAndFormatWithoutLeakingSignedURLs() {
        let url = URL(string: "https://subs.example.com/private-key/en.srt?token=secret")!
        let options = [SubtitleOption(id: "provider-id|\(url)", language: "eng", title: "English · Main", url: url, source: .addon("Main")),
                       SubtitleOption(id: "another-id", language: "eng", title: "English · Main", url: url, source: .stream, isForced: true)]
        let rows = PlayerTrackPresentation.external(options)
        #expect(rows[0].subtitle.contains("Main") && rows[0].subtitle.contains("SRT"))
        #expect(rows[0].subtitle != rows[1].subtitle)
        for row in rows {
            #expect(!row.subtitle.contains("secret") && !row.subtitle.contains("private-key") && !row.subtitle.contains("provider-id"))
        }
    }

    @Test func longListsRetainStableDecoderIDsAndAudioDetails() {
        let tracks = (0..<150).map { MediaTrack(id: "a\($0)", title: "English", language: "eng", codec: "eac3", channelCount: 6) }
        let rows = PlayerTrackPresentation.embedded(tracks, audio: true)
        #expect(rows.count == 150 && rows.map(\.id) == tracks.map(\.id))
        #expect(rows.allSatisfy { $0.subtitle.contains("5.1") && $0.subtitle.contains("EAC3") })
    }
}
