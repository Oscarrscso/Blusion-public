import Foundation
import Testing
@testable import PlayerKit

@Suite struct SubtitleParserTests {
    @Test func parsesTheMocksSRTAtItsKnownCueTimes() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,000
        First cue

        2
        00:00:04,500 --> 00:00:06,250
        Second cue
        with two lines

        3
        00:00:08,000 --> 00:00:09,500
        Third cue

        """
        let (cues, format) = try SubtitleParser.parse(data: Data(srt.utf8))
        #expect(format == .srt)
        #expect(cues == [SubtitleCue(start: 1.0, end: 3.0, text: "First cue"),
                         SubtitleCue(start: 4.5, end: 6.25, text: "Second cue\nwith two lines"),
                         SubtitleCue(start: 8.0, end: 9.5, text: "Third cue")])
    }

    @Test func parsesTheMocksVTT() throws {
        let vtt = "WEBVTT\n\ncue-1\n00:00:01.000 --> 00:00:03.000\nFirst cue\n\ncue-2\n00:00:04.500 --> 00:00:06.250\nSecond cue\nwith two lines\n"
        let (cues, format) = try SubtitleParser.parse(data: Data(vtt.utf8))
        #expect(format == .vtt)
        #expect(cues.map(\.start) == [1.0, 4.5])
        #expect(cues[1].text == "Second cue\nwith two lines")
    }

    @Test func toleratesCRLFBOMAndMissingIndexes() throws {
        let text = "\u{FEFF}00:00:01,000 --> 00:00:02,000\r\nHello\r\n\r\n2\r\n00:00:03.5 --> 00:00:04.5\r\nWorld\r\n"
        let (cues, _) = try SubtitleParser.parse(data: Data(text.utf8))
        #expect(cues.map(\.text) == ["Hello", "World"])
        #expect(cues[1].start == 3.5)
    }

    @Test func stripsMarkupAndEntities() {
        let cue = "<i>Italic</i> and <b>bold</b> &amp; {\\an8}positioned<br/>done &lt;ok&gt;"
        #expect(SubtitleParser.clean(cue) == "Italic and bold & positioneddone <ok>")
        #expect(SubtitleParser.clean("<c.yellow>Yellow</c> <v Bob>Hi</v> <00:00:01.500>there") == "Yellow Hi there")
        #expect(SubtitleParser.clean("  padded  \n\n  lines  ") == "padded\nlines")
    }

    @Test func vttIgnoresHeaderNotesStylesAndCueSettings() throws {
        let vtt = """
        WEBVTT - some title

        NOTE this is a comment
        --> not a cue

        STYLE
        ::cue { color: red }

        00:01.000 --> 00:02.000 line:90% align:center
        Short timestamp form

        01:00:00.000 --> 01:00:01.000
        An hour in
        """
        let (cues, format) = try SubtitleParser.parse(data: Data(vtt.utf8))
        #expect(format == .vtt)
        #expect(cues.map(\.text) == ["Short timestamp form", "An hour in"])
        #expect(cues[0].start == 1.0 && cues[1].start == 3600.0)
    }

    @Test func srtPositionHintsAfterTheEndTimeAreIgnored() throws {
        let (cues, _) = try SubtitleParser.parse(data: Data("1\n00:00:01,000 --> 00:00:02,000 X1:100 X2:200 Y1:50 Y2:80\nText\n".utf8))
        #expect(cues == [SubtitleCue(start: 1, end: 2, text: "Text")])
    }

    @Test func badBlocksAreSkippedNotFatal() throws {
        let text = "1\nnot a time --> nope\nBad\n\n2\n00:00:05,000 --> 00:00:04,000\nBackwards\n\n3\n00:00:06,000 --> 00:00:07,000\n"
            + "Good\n\n4\n00:00:08,000 --> 00:00:09,000\n\n"
        let (cues, _) = try SubtitleParser.parse(data: Data(text.utf8))
        #expect(cues.map(\.text) == ["Good"], "unparseable, backwards and empty cues are dropped")
    }

    @Test func cuesAreSortedByStartTime() throws {
        let text = "1\n00:00:05,000 --> 00:00:06,000\nLate\n\n2\n00:00:01,000 --> 00:00:02,000\nEarly\n"
        #expect(try SubtitleParser.parse(data: Data(text.utf8)).cues.map(\.text) == ["Early", "Late"])
    }

    @Test func decodesCommonEncodings() throws {
        let line = "1\n00:00:01,000 --> 00:00:02,000\nCafé señor\n"
        #expect(try SubtitleParser.parse(data: Data(line.utf8)).cues.first?.text == "Café señor")
        #expect(try SubtitleParser.parse(data: line.data(using: .utf16LittleEndian).map { Data([0xFF, 0xFE]) + $0 } ?? Data()).cues.first?.text == "Café señor")
        #expect(try SubtitleParser.parse(data: line.data(using: .utf16BigEndian).map { Data([0xFE, 0xFF]) + $0 } ?? Data()).cues.first?.text == "Café señor")
        // Windows-1252 bytes that are not valid UTF-8.
        let latin = Data("1\n00:00:01,000 --> 00:00:02,000\nCaf".utf8) + Data([0xE9]) + Data(" se".utf8) + Data([0xF1]) + Data("or\n".utf8)
        #expect(try SubtitleParser.parse(data: latin).cues.first?.text == "Café señor")
    }

    @Test func rejectsEmptyOversizedAndGarbage() {
        #expect(throws: SubtitleError.empty) { try SubtitleParser.parse(data: Data()) }
        #expect(throws: SubtitleError.empty) { try SubtitleParser.parse(data: Data("just some text\nwithout cues\n".utf8)) }
        #expect(throws: SubtitleError.empty) { try SubtitleParser.parse(data: Data("WEBVTT\n\n".utf8)) }
        #expect(throws: SubtitleError.tooLarge) { try SubtitleParser.parse(data: Data(count: SubtitleParser.maximumBytes + 1)) }
    }

    @Test func timestampsAcceptCommaDotAndOptionalHours() {
        #expect(SubtitleParser.parseTimestamp("01:02:03,500") == 3723.5)
        #expect(SubtitleParser.parseTimestamp("02:03.500") == 123.5)
        #expect(SubtitleParser.parseTimestamp(" 00:00:00.000 ") == 0)
        #expect(SubtitleParser.parseTimestamp("75:30.000") == 4530, "minutes beyond 59 are tolerated")
        for bad in ["", "12", "a:b:c", "00:00:-1", "1:2:3:4", "00:xx"] { #expect(SubtitleParser.parseTimestamp(bad) == nil, "\(bad)") }
    }

    @Test func fuzzedInputNeverCrashes() {
        var generator = SystemRandomNumberGenerator()
        let pieces = ["-->", "\n", "\r\n", "00:00:01,000", "WEBVTT", "<i>", "</", "{\\an8}", "&", "NOTE", " ", "\u{0}", "é", "99:99:99.999", "1", "\n\n"]
        for _ in 0..<500 {
            var text = ""
            for _ in 0..<Int.random(in: 0..<40, using: &generator) { text += pieces.randomElement(using: &generator)! }
            _ = try? SubtitleParser.parse(data: Data(text.utf8))
        }
    }
}

@Suite struct SubtitleTimelineTests {
    private let timeline = SubtitleTimeline(cues: [
        SubtitleCue(start: 1.0, end: 3.0, text: "First"),
        SubtitleCue(start: 4.5, end: 6.25, text: "Second"),
        SubtitleCue(start: 8.0, end: 9.5, text: "Third"),
    ])

    @Test func showsCuesAtTheRightTimes() {
        #expect(timeline.text(at: 0.5) == nil)
        #expect(timeline.text(at: 1.0) == "First", "start is inclusive")
        #expect(timeline.text(at: 2.99) == "First")
        #expect(timeline.text(at: 3.0) == nil, "end is exclusive")
        #expect(timeline.text(at: 5.0) == "Second")
        #expect(timeline.text(at: 6.25) == nil)
        #expect(timeline.text(at: 8.5) == "Third")
        #expect(timeline.text(at: 100) == nil)
        #expect(timeline.text(at: -1) == nil)
    }

    @Test func offsetShiftsSubtitlesLaterOrEarlier() {
        #expect(timeline.text(at: 3.5, offset: 2.0) == "First", "delayed by 2 s: First now ends at 5")
        #expect(timeline.text(at: 1.5, offset: 2.0) == nil)
        #expect(timeline.text(at: 0.5, offset: -1.0) == "First", "advanced by 1 s")
        #expect(timeline.text(at: 8.5, offset: 0.0) == "Third")
    }

    @Test func overlappingCuesAreShownTogetherInOrder() {
        let overlap = SubtitleTimeline(cues: [SubtitleCue(start: 0, end: 10, text: "Long"), SubtitleCue(start: 2, end: 4, text: "Inside")])
        #expect(overlap.text(at: 1) == "Long")
        #expect(overlap.text(at: 3) == "Long\nInside")
        #expect(overlap.text(at: 5) == "Long")
    }

    @Test func aLongEarlyCueIsFoundEvenAfterManyShortOnes() {
        var cues = [SubtitleCue(start: 0, end: 1000, text: "Banner")]
        for i in 1...200 { cues.append(SubtitleCue(start: Double(i), end: Double(i) + 0.5, text: "c\(i)")) }
        let big = SubtitleTimeline(cues: cues)
        #expect(big.text(at: 150.2) == "Banner\nc150")
        #expect(big.text(at: 150.7) == "Banner")
    }

    @Test func emptyTimelinesShowNothing() {
        #expect(SubtitleTimeline(cues: []).text(at: 5) == nil)
    }

    @Test func unsortedInputIsSorted() {
        let t = SubtitleTimeline(cues: [SubtitleCue(start: 5, end: 6, text: "B"), SubtitleCue(start: 1, end: 2, text: "A")])
        #expect(t.cues.map(\.text) == ["A", "B"])
        #expect(t.text(at: 1.5) == "A" && t.text(at: 5.5) == "B")
    }
}

@Suite struct StyledSubtitleTests {
    private let yellow = SubtitleColourValue(red: 1, green: 1, blue: 0)

    @Test func srtItalicFontColourAndAlignmentBecomeSpans() throws {
        let srt = #"""
        1
        00:00:01,000 --> 00:00:02,000
        {\an8}<i>Hello</i> <font color="#FFFF00">yellow</font> world
        """#
        let (cues, format) = try SubtitleParser.parse(data: Data(srt.utf8))
        #expect(format == .srt)
        #expect(cues.count == 1)
        #expect(cues[0].alignment == .top)
        #expect(cues[0].text == "Hello yellow world")
        #expect(cues[0].spans == [
            SubtitleSpan(text: "Hello", isItalic: true),
            SubtitleSpan(text: " "),
            SubtitleSpan(text: "yellow", colour: yellow),
            SubtitleSpan(text: " world"),
        ])
    }

    @Test func srtInlineAssFlagsStyleText() throws {
        let srt = #"""
        1
        00:00:01,000 --> 00:00:02,000
        {\i1}ital{\i0} plain
        """#
        let (cues, _) = try SubtitleParser.parse(data: Data(srt.utf8))
        #expect(cues[0].spans == [SubtitleSpan(text: "ital", isItalic: true), SubtitleSpan(text: " plain")])
        #expect(cues[0].alignment == .bottom)
    }

    @Test func vttLineSettingsAlignmentAndClassColours() throws {
        let vtt = #"""
        WEBVTT

        00:00:01.000 --> 00:00:02.000 line:0%
        Top line

        00:00:03.000 --> 00:00:04.000 align:right line:-1
        <c.yellow>Yellow</c> right

        00:00:05.000 --> 00:00:06.000 line:90% align:start
        Bottom left
        """#
        let (cues, format) = try SubtitleParser.parse(data: Data(vtt.utf8))
        #expect(format == .vtt)
        // A negative line counts up from the bottom, so it keeps the bottom row.
        #expect(cues.map(\.alignment) == [.top, .bottomRight, .bottomLeft])
        #expect(cues[1].spans == [SubtitleSpan(text: "Yellow", colour: yellow), SubtitleSpan(text: " right")])
    }

    @Test func bitmapFormatsReportWhatTheyAre() {
        #expect(throws: SubtitleError.bitmap("pgs")) { try SubtitleParser.parse(data: Data("PG".utf8) + Data("junk".utf8)) }
        #expect(throws: SubtitleError.bitmap("vobsub")) { try SubtitleParser.parse(data: Data("# VobSub index file, v7 (do not modify this line!)\n".utf8)) }
        #expect(throws: SubtitleError.bitmap("vobsub")) { try SubtitleParser.parse(data: Data([0x00, 0x00, 0x01, 0xBA, 0x44])) }
        // A large .sup reports what it is rather than being refused for its size.
        #expect(throws: SubtitleError.bitmap("pgs")) { try SubtitleParser.parse(data: Data("PG".utf8) + Data(count: SubtitleParser.maximumASSBytes + 1)) }
    }

    @Test func assGetsALargerSizeCapThanTextFormats() throws {
        let padding = String(repeating: "a", count: SubtitleParser.maximumBytes + 1024)
        let ass = "[Script Info]\n\(padding)\n[Events]\nFormat: Layer, Start, End, Style, Text\nDialogue: 0,0:00:01.00,0:00:02.00,Default,Hi\n"
        let (cues, format) = try SubtitleParser.parse(data: Data(ass.utf8))
        #expect(format == .ass)
        #expect(cues.map(\.text) == ["Hi"])
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n" + padding
        #expect(throws: SubtitleError.tooLarge) { try SubtitleParser.parse(data: Data(srt.utf8)) }
        let oversized = "[Script Info]\n" + String(repeating: "a", count: SubtitleParser.maximumASSBytes)
        #expect(throws: SubtitleError.tooLarge) { try SubtitleParser.parse(data: Data(oversized.utf8)) }
        #expect(SubtitleParser.largestAcceptedBytes == SubtitleParser.maximumASSBytes)
    }

    @Test func eventsSectionAloneIsEnoughToDetectASS() throws {
        let (cues, format) = try SubtitleParser.parse(data: Data("[Events]\nFormat: Layer, Start, End, Style, Text\nDialogue: 0,0:00:01.00,0:00:02.00,Default,Hi\n".utf8))
        #expect(format == .ass)
        #expect(cues.map(\.text) == ["Hi"])
    }

    @Test func needsEngineRenderingFlagsEffectsAndCrowdedPositions() {
        func cue(_ start: Double, _ end: Double, at position: SubtitlePoint? = nil, advanced: Bool = false) -> SubtitleCue {
            SubtitleCue(start: start, end: end, spans: [SubtitleSpan(text: "x")], position: position, usesAdvancedEffects: advanced)
        }
        #expect(!SubtitleParser.needsEngineRendering([cue(0, 1)], format: .ass))
        #expect(SubtitleParser.needsEngineRendering([cue(0, 1, advanced: true)], format: .ass))
        // The overlay stacks two overlapping cues, but cannot place three that sit in different spots.
        #expect(!SubtitleParser.needsEngineRendering([cue(0, 5), cue(1, 5)], format: .ass))
        #expect(!SubtitleParser.needsEngineRendering([cue(0, 5), cue(1, 5), cue(2, 5)], format: .ass))
        #expect(SubtitleParser.needsEngineRendering([cue(0, 5, at: SubtitlePoint(x: 0.1, y: 0.1)), cue(1, 5), cue(2, 5)], format: .ass))
        // Advanced effects only come from ASS.
        #expect(!SubtitleParser.needsEngineRendering([cue(0, 1, advanced: true)], format: .srt))
    }

    @Test func cueTextIsTheJoinOfItsSpans() {
        let cue = SubtitleCue(start: 0, end: 1, spans: [SubtitleSpan(text: "a", isItalic: true), SubtitleSpan(text: " b")])
        #expect(cue.text == "a b")
        #expect(SubtitleCue(start: 0, end: 1, text: "plain").spans == [SubtitleSpan(text: "plain")])
    }

    @Test func cuesAtReturnsActiveCuesInStartThenLayerOrder() {
        let timeline = SubtitleTimeline(cues: [
            SubtitleCue(start: 0, end: 10, spans: [SubtitleSpan(text: "top")], layer: 1),
            SubtitleCue(start: 0, end: 10, spans: [SubtitleSpan(text: "under")], layer: 0),
            SubtitleCue(start: 2, end: 4, spans: [SubtitleSpan(text: "later")]),
        ])
        #expect(timeline.cues(at: 3).map(\.text) == ["under", "top", "later"])
        #expect(timeline.cues(at: 3, offset: 2).map(\.text) == ["under", "top"], "delayed 2 s, so 'later' has not started at 1 s")
        #expect(timeline.cues(at: 11).isEmpty)
        #expect(timeline.cues(at: -1).isEmpty)
    }
}

@Suite struct LanguageCodesTests {
    @Test(arguments: [("en", "eng"), ("eng", "eng"), ("English", "eng"), ("EN", "eng"), ("es", "spa"), ("spa", "spa"), ("fr", "fre"), ("fra", "fre"),
                      ("pt-BR", "por"), ("pob", "por"), ("pt_PT", "por"), ("zh", "chi"), ("zho", "chi"), ("zh-TW", "chi"), ("de", "ger"), ("deu", "ger"),
                      ("ja", "jpn"), ("klingon", "klingon"), ("", "")] as [(String, String)])
    func normalises(raw: String, expected: String) {
        #expect(LanguageCodes.normalise(raw) == expected)
    }

    @Test func displayNamesAndMatching() {
        #expect(LanguageCodes.displayName("eng") == "English")
        #expect(LanguageCodes.displayName("pt-BR") == "Portuguese")
        #expect(LanguageCodes.displayName("xx") == "XX")
        #expect(LanguageCodes.displayName("Klingon") == "Klingon")
        #expect(LanguageCodes.displayName("") == "Unknown")
        #expect(LanguageCodes.matches("eng", preferred: "en"))
        #expect(LanguageCodes.matches("fre", preferred: "French"))
        #expect(!LanguageCodes.matches("eng", preferred: "es"))
    }
}
