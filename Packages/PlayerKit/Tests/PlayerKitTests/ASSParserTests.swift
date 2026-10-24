import Foundation
import Testing
@testable import PlayerKit

@Suite struct ASSParserTests {
    private let white = SubtitleColourValue(red: 1, green: 1, blue: 1)
    private let yellow = SubtitleColourValue(red: 1, green: 1, blue: 0)
    private let red = SubtitleColourValue(red: 1, green: 0, blue: 0)

    private static let fixture = #"""
    [Script Info]
    Title: Blusion test
    ScriptType: v4.00+
    PlayResX: 384
    PlayResY: 288

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, Bold, Italic, Underline, StrikeOut, Alignment
    Style: Default,Arial,20,&H00FFFFFF,0,0,0,0,2
    Style: Sign,Georgia,40,&H0000FFFF,-1,-1,0,0,8

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Comment: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,This is a comment
    Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,Hello, world {\i1}italic{\i0}\NSecond line
    Dialogue: 0,0:00:04.00,0:00:05.00,Sign,,0,0,0,,{\an8}Top sign
    Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,{\pos(192,144)}Centred
    Dialogue: 0,0:00:06.00,0:00:07.00,Default,,0,0,0,,{\c&H0000FF&}Red text
    Dialogue: 0,0:00:07.00,0:00:08.00,Default,,0,0,0,,{\move(100,100,200,200)}Moving
    Dialogue: 0,0:00:08.00,0:00:09.00,Default,,0,0,0,,{\p1}m 0 0 l 100 0{\p0}
    """#

    @Test func parsesStylesEventsAndOverridesFromARealisticFile() throws {
        // A BOM and CRLF line endings, as real files often have.
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(Self.fixture.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        let (cues, format) = try SubtitleParser.parse(data: data)
        #expect(format == .ass)
        #expect(cues.map(\.start) == [1, 4, 5, 6, 7], "the Comment and the drawing-only event are dropped")

        let hello = cues[0]
        #expect(hello.text == "Hello, world italic\nSecond line", "commas survive in the Text field")
        #expect(hello.spans == [
            SubtitleSpan(text: "Hello, world "),
            SubtitleSpan(text: "italic\n", isItalic: true),
            SubtitleSpan(text: "Second line"),
        ])
        #expect(hello.alignment == .bottom)
        #expect(hello.fontName == "Arial")
        #expect(hello.fontScale == 1)
        #expect(!hello.usesAdvancedEffects)

        let sign = cues[1]
        #expect(sign.text == "Top sign")
        #expect(sign.alignment == .top)
        #expect(sign.fontName == "Georgia")
        #expect(sign.fontScale == 2, "Sign is 40 pt against the Default style's 20 pt")
        #expect(sign.spans == [SubtitleSpan(text: "Top sign", isItalic: true, isBold: true, colour: yellow)])

        #expect(cues[2].position == SubtitlePoint(x: 0.5, y: 0.5), "192 of 384 and 144 of 288")
        #expect(cues[2].alignment == .bottom)
        #expect(cues[3].spans == [SubtitleSpan(text: "Red text", colour: red)])
        #expect(cues[4].usesAdvancedEffects, "\\move needs the engine")
        #expect(cues[4].text == "Moving")
        #expect(!cues.prefix(4).contains { $0.usesAdvancedEffects })
        #expect(!cues.contains { $0.text.contains("comment") || $0.text.contains("m 0 0") })
        #expect(SubtitleParser.needsEngineRendering(cues, format: .ass))
        #expect(!SubtitleParser.needsEngineRendering(Array(cues.prefix(4)), format: .ass), "no advanced effects and no crowding")
    }

    @Test func ssaLegacyAlignmentAndDecimalColoursConvert() {
        let ssa = #"""
        [Script Info]
        ScriptType: v4.00
        PlayResX: 640
        PlayResY: 480

        [V4 Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, Alignment
        Style: Default,Arial,16,16777215,65535,0,0,0,0,6

        [Events]
        Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: Marked=0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Legacy top
        Dialogue: Marked=0,0:00:03.00,0:00:04.00,Default,,0,0,0,,{\a9\pos(320,240)}Legacy middle
        """#
        let cues = ASSParser.parse(ssa)
        #expect(cues.map(\.alignment) == [.top, .middleLeft], "legacy 6 is top centre, legacy 9 is middle left")
        #expect(cues[0].spans == [SubtitleSpan(text: "Legacy top")], "decimal 16777215 is white, the default, so the viewer's colour applies")
        #expect(cues[1].position == SubtitlePoint(x: 0.5, y: 0.5), "PlayRes 640x480 is the frame")
    }

    @Test func resetHardSpaceAndSoftBreaks() {
        let ass = #"""
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, Bold, Italic, Alignment
        Style: Default,Arial,20,&H00FFFFFF,0,0,2

        [Events]
        Format: Layer, Start, End, Style, Text
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,{\b1}bold{\r}plain a\hb\nc
        """#
        let cues = ASSParser.parse(ass)
        #expect(cues.count == 1)
        #expect(cues[0].text == "boldplain a\u{00A0}b c")
        #expect(cues[0].spans == [
            SubtitleSpan(text: "bold", isBold: true),
            SubtitleSpan(text: "plain a\u{00A0}b c"),
        ])
    }

    @Test func coloursDecodeBGRAndAlpha() {
        #expect(ASSParser.parseColour("&H0080FF&") == SubtitleColourValue(red: 1, green: 128.0 / 255, blue: 0), "BBGGRR: red is the low byte")
        #expect(ASSParser.parseColour("&H80FFFFFF")?.alpha == 1 - 128.0 / 255, "alpha 80 is about half transparent")
        #expect(ASSParser.parseColour("16777215") == white, "decimal SSA colours have no alpha")
        #expect(ASSParser.parseColour("nope") == nil)
    }

    @Test func unknownSectionsTagsAndColumnsAreIgnored() {
        let ass = #"""
        [Script Info]
        PlayResX: 0
        [Fonts]
        fontname: nothing
        [Events]
        Format: Layer, Start, End, Style, Text
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,{\zzz9\i1}odd,column
        Dialogue: 0,0:00:03.00,0:00:02.00,Default,backwards
        Dialogue: 0,0:00:04.00,0:00:05.00,Default,{\an5}
        """#
        let cues = ASSParser.parse(ass)
        #expect(cues.map(\.text) == ["odd,column"], "the Text keeps its commas, and the backwards and empty events are dropped")
        #expect(cues.first?.spans == [SubtitleSpan(text: "odd,column", isItalic: true)], "unknown tags are ignored, known ones still apply")
    }
}
