import Foundation
import Testing
@testable import PlayerKit

/// Writes .sup segments explicitly, so each fixture reads as the display sets it describes.
private enum SupFixture {
    struct Composition {
        var objectID = 0
        var x = 0
        var y = 0
        /// Crop rectangle as x, y, width, height.
        var crop: [Int]?
    }

    struct Entry {
        let id: Int
        let y: Int
        let cr: Int
        let cb: Int
        let alpha: Int
    }

    static func u16(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func u24(_ value: Int) -> [UInt8] {
        [UInt8((value >> 16) & 0xFF)] + u16(value & 0xFFFF)
    }

    static func u32(_ value: Int) -> [UInt8] {
        u16((value >> 16) & 0xFFFF) + u16(value & 0xFFFF)
    }

    static func segment(_ type: UInt8, pts: Int, _ payload: [UInt8]) -> [UInt8] {
        let header: [UInt8] = [0x50, 0x47] + u32(pts) + u32(0) + [type] + u16(payload.count)
        return header + payload
    }

    static func pcs(pts: Int, width: Int = 1920, height: Int = 1080, state: UInt8 = 0x00,
                    paletteUpdate: Bool = false, paletteID: Int = 0, objects: [Composition] = []) -> [UInt8] {
        var payload: [UInt8] = u16(width) + u16(height) + [0x10] + u16(0)
        payload += [state, paletteUpdate ? 0x80 : 0, UInt8(paletteID), UInt8(objects.count)]
        for object in objects {
            payload += u16(object.objectID) + [0, object.crop == nil ? 0 : 0x80]
            payload += u16(object.x) + u16(object.y)
            if let crop = object.crop {
                payload += crop.flatMap { u16($0) }
            }
        }
        return segment(0x16, pts: pts, payload)
    }

    static func wds(pts: Int) -> [UInt8] {
        let window: [UInt8] = [1, 0] + u16(0) + u16(0) + u16(4) + u16(2)
        return segment(0x17, pts: pts, window)
    }

    static func pds(pts: Int, id: Int = 0, entries: [Entry]) -> [UInt8] {
        var payload: [UInt8] = [UInt8(id), 0]
        for entry in entries {
            payload += [UInt8(entry.id), UInt8(entry.y), UInt8(entry.cr), UInt8(entry.cb), UInt8(entry.alpha)]
        }
        return segment(0x14, pts: pts, payload)
    }

    /// An ODS segment. `rleLength` is the declared RLE size, sent only with the first fragment (sequence 0x80).
    static func ods(pts: Int, id: Int = 0, sequence: UInt8 = 0xC0, width: Int = 4, height: Int = 2,
                    rleLength: Int? = nil, rle: [UInt8]) -> [UInt8] {
        var payload: [UInt8] = u16(id) + [0, sequence]
        if (sequence & 0x80) != 0 {
            payload += u24((rleLength ?? rle.count) + 4) + u16(width) + u16(height)
        }
        return segment(0x15, pts: pts, payload + rle)
    }

    static func end(pts: Int) -> [UInt8] {
        segment(0x80, pts: pts, [])
    }

    static func stream(_ segments: [UInt8]...) -> Data {
        Data(segments.flatMap { $0 })
    }

    static let whiteAndClear = [
        Entry(id: 0, y: 16, cr: 128, cb: 128, alpha: 0),
        Entry(id: 1, y: 235, cr: 128, cb: 128, alpha: 255),
    ]

    /// 4x2 object: row 0 is `1 0 1 0`, row 1 is `0 1 1 0`.
    static let fourByTwoRLE: [UInt8] = [
        0x01, 0x00, 0x01, 0x01, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x01, 0x01, 0x01, 0x00, 0x01, 0x00, 0x00,
    ]

    /// Straight RGBA for `fourByTwoRLE` with colour 1 painted in the given RGB at full alpha.
    static func fourByTwoRGBA(red: UInt8, green: UInt8, blue: UInt8) -> [UInt8] {
        let on: [UInt8] = [red, green, blue, 255]
        let off: [UInt8] = [0, 0, 0, 0]
        return on + off + on + off + off + on + on + off
    }
}

@Suite struct PGSDecoderTests {
    private let fourByTwoAt = SupFixture.Composition(objectID: 0, x: 100, y: 200)

    @Test func decodesOneObjectToExactRGBAWithTiming() throws {
        let data = SupFixture.stream(
            SupFixture.pcs(pts: 90_000, objects: [fourByTwoAt]),
            SupFixture.wds(pts: 90_000),
            SupFixture.pds(pts: 90_000, entries: SupFixture.whiteAndClear),
            SupFixture.ods(pts: 90_000, rle: SupFixture.fourByTwoRLE),
            SupFixture.end(pts: 90_000),
            SupFixture.pcs(pts: 270_000),
            SupFixture.end(pts: 270_000)
        )
        let cues = try PGSDecoder.decode(data)
        let image = BitmapSubtitleImage(x: 100, y: 200, width: 4, height: 2,
                                        rgba: SupFixture.fourByTwoRGBA(red: 255, green: 255, blue: 255))
        #expect(cues == [BitmapSubtitleCue(start: 1.0, end: 3.0, frameWidth: 1920, frameHeight: 1080, images: [image])])
    }

    @Test func decodesAllRLEFormsAndEndOfLine() throws {
        // Row 0 (600 px): 5 x colour 0 (short), 1 x colour 1 (literal), 3 x colour 2 (short, coloured),
        // 300 x colour 0 (14-bit), 41 x colour 1 (short, coloured), 250 x colour 3 (14-bit, coloured), end of line.
        let row0: [UInt8] = [0x00, 0x05, 0x01, 0x00, 0x83, 0x02, 0x00, 0x41, 0x2C,
                             0x00, 0xA9, 0x01, 0x00, 0xC0, 0xFA, 0x03, 0x00, 0x00]
        // Row 1: three literal pixels (colours 1, 2, 3), then end of line.
        let row1: [UInt8] = [0x01, 0x02, 0x03, 0x00, 0x00]
        let data = SupFixture.stream(
            SupFixture.pcs(pts: 90_000, width: 600, height: 2, objects: [SupFixture.Composition(objectID: 0)]),
            SupFixture.pds(pts: 90_000, entries: [
                SupFixture.Entry(id: 0, y: 16, cr: 128, cb: 128, alpha: 0),
                SupFixture.Entry(id: 1, y: 235, cr: 128, cb: 128, alpha: 255),
                SupFixture.Entry(id: 2, y: 235, cr: 128, cb: 128, alpha: 128),
                SupFixture.Entry(id: 3, y: 235, cr: 128, cb: 128, alpha: 64),
            ]),
            SupFixture.ods(pts: 90_000, width: 600, height: 2, rle: row0 + row1),
            SupFixture.end(pts: 90_000)
        )
        let cues = try PGSDecoder.decode(data)

        func run(_ alpha: UInt8, _ count: Int) -> [UInt8] { [UInt8](repeating: alpha, count: count) }
        let alphaRow0 = run(0, 5) + run(255, 1) + run(128, 3) + run(0, 300) + run(255, 41) + run(64, 250)
        let alphaRow1 = [UInt8]([255, 128, 64]) + run(0, 597)
        let rgba = (alphaRow0 + alphaRow1).flatMap { alpha -> [UInt8] in
            alpha == 0 ? [0, 0, 0, 0] : [255, 255, 255, alpha]
        }
        #expect(cues.count == 1)
        #expect(cues.first?.images == [BitmapSubtitleImage(x: 0, y: 0, width: 600, height: 2, rgba: rgba)])
    }

    @Test func reassemblesObjectSplitAcrossFragments() throws {
        let rle = SupFixture.fourByTwoRLE
        let data = SupFixture.stream(
            SupFixture.pcs(pts: 90_000, objects: [fourByTwoAt]),
            SupFixture.pds(pts: 90_000, entries: SupFixture.whiteAndClear),
            SupFixture.ods(pts: 90_000, sequence: 0x80, rleLength: rle.count, rle: Array(rle[0..<7])),
            SupFixture.ods(pts: 90_000, sequence: 0x40, rle: Array(rle[7...])),
            SupFixture.end(pts: 90_000),
            SupFixture.end(pts: 270_000)
        )
        let cues = try PGSDecoder.decode(data)
        let image = BitmapSubtitleImage(x: 100, y: 200, width: 4, height: 2,
                                        rgba: SupFixture.fourByTwoRGBA(red: 255, green: 255, blue: 255))
        #expect(cues.map(\.images) == [[image]])
    }

    @Test func cropsObjectToItsRectangleAtCompositionPosition() throws {
        let crop = SupFixture.Composition(objectID: 0, x: 10, y: 20, crop: [1, 0, 2, 1])
        let data = SupFixture.stream(
            SupFixture.pcs(pts: 90_000, objects: [crop]),
            SupFixture.pds(pts: 90_000, entries: SupFixture.whiteAndClear),
            SupFixture.ods(pts: 90_000, rle: SupFixture.fourByTwoRLE),
            SupFixture.end(pts: 90_000),
            SupFixture.end(pts: 270_000)
        )
        let cues = try PGSDecoder.decode(data)
        // Pixels x 1...2 of row 0 are transparent then white.
        let image = BitmapSubtitleImage(x: 10, y: 20, width: 2, height: 1, rgba: [0, 0, 0, 0, 255, 255, 255, 255])
        #expect(cues.map(\.images) == [[image]])
    }

    @Test func paletteOnlyUpdateStartsSecondCueWithStoredObject() throws {
        let data = SupFixture.stream(
            SupFixture.pcs(pts: 90_000, objects: [fourByTwoAt]),
            SupFixture.pds(pts: 90_000, entries: SupFixture.whiteAndClear),
            SupFixture.ods(pts: 90_000, rle: SupFixture.fourByTwoRLE),
            SupFixture.end(pts: 90_000),
            SupFixture.pcs(pts: 180_000, paletteUpdate: true, objects: [fourByTwoAt]),
            SupFixture.pds(pts: 180_000, entries: [SupFixture.Entry(id: 1, y: 16, cr: 128, cb: 128, alpha: 255)]),
            SupFixture.end(pts: 180_000),
            SupFixture.pcs(pts: 270_000),
            SupFixture.end(pts: 270_000)
        )
        let cues = try PGSDecoder.decode(data)
        #expect(cues.count == 2)
        #expect(cues.first?.end == 2.0)
        #expect(cues.last?.start == 2.0)
        #expect(cues.last?.end == 3.0)
        let white = BitmapSubtitleImage(x: 100, y: 200, width: 4, height: 2,
                                        rgba: SupFixture.fourByTwoRGBA(red: 255, green: 255, blue: 255))
        let black = BitmapSubtitleImage(x: 100, y: 200, width: 4, height: 2,
                                        rgba: SupFixture.fourByTwoRGBA(red: 0, green: 0, blue: 0))
        #expect(cues.first?.images == [white])
        #expect(cues.last?.images == [black])
    }

    @Test func lastCueWithoutFollowingSetEndsFiveSecondsLater() throws {
        let data = SupFixture.stream(
            SupFixture.pcs(pts: 90_000, objects: [fourByTwoAt]),
            SupFixture.pds(pts: 90_000, entries: SupFixture.whiteAndClear),
            SupFixture.ods(pts: 90_000, rle: SupFixture.fourByTwoRLE),
            SupFixture.end(pts: 90_000)
        )
        let cues = try PGSDecoder.decode(data)
        #expect(cues.map(\.start) == [1.0])
        #expect(cues.map(\.end) == [6.0])
    }

    @Test func truncatedFileReturnsEarlierCues() throws {
        let complete = SupFixture.stream(
            SupFixture.pcs(pts: 90_000, objects: [fourByTwoAt]),
            SupFixture.pds(pts: 90_000, entries: SupFixture.whiteAndClear),
            SupFixture.ods(pts: 90_000, rle: SupFixture.fourByTwoRLE),
            SupFixture.end(pts: 90_000)
        )
        let second = SupFixture.pcs(pts: 180_000, objects: [fourByTwoAt])
            + SupFixture.pds(pts: 180_000, entries: SupFixture.whiteAndClear)
            + SupFixture.ods(pts: 180_000, rle: SupFixture.fourByTwoRLE)
        var data = complete
        data.append(contentsOf: second.dropLast(10))  // cut inside the second object definition
        let cues = try PGSDecoder.decode(data)
        #expect(cues.count == 1)
        #expect(cues.first?.start == 1.0)
        #expect(cues.first?.end == 2.0)
    }

    @Test func truncatedRLEStopsWithoutCrashing() throws {
        // One literal pixel, then a control byte cut off before its length.
        let data = SupFixture.stream(
            SupFixture.pcs(pts: 90_000, objects: [fourByTwoAt]),
            SupFixture.pds(pts: 90_000, entries: SupFixture.whiteAndClear),
            SupFixture.ods(pts: 90_000, rle: [0x01, 0x00]),
            SupFixture.end(pts: 90_000)
        )
        let cues = try PGSDecoder.decode(data)
        let rgba = try #require(cues.first?.images.first?.rgba)
        #expect(cues.count == 1)
        #expect(Array(rgba.prefix(4)) == [255, 255, 255, 255])
    }

    @Test func rejectsNonPGSText() {
        let srt = Data("1\n00:00:01,000 --> 00:00:03,000\nHello\n".utf8)
        #expect(throws: PGSError.notPGS) { try PGSDecoder.decode(srt) }
    }

    @Test func rejectsTruncatedFirstSegment() {
        #expect(throws: PGSError.truncated) { try PGSDecoder.decode(Data([0x50, 0x47, 0, 0, 0])) }
    }

    @Test func rejectsOversizedInput() {
        let data = Data(count: PGSDecoder.maximumBytes + 1)
        #expect(throws: PGSError.tooLarge) { try PGSDecoder.decode(data) }
    }

    @Test func choosesBT709ForHDFramesAndBT601BelowThat() throws {
        // Y=100, Cr=200, Cb=128: BT.709 gives (227, 59, 98), BT.601 gives (213, 39, 98).
        let entries = [
            SupFixture.Entry(id: 0, y: 16, cr: 128, cb: 128, alpha: 0),
            SupFixture.Entry(id: 1, y: 100, cr: 200, cb: 128, alpha: 255),
        ]
        func decodeColour(frameHeight: Int) throws -> [UInt8] {
            let data = SupFixture.stream(
                SupFixture.pcs(pts: 90_000, width: 1920, height: frameHeight, objects: [SupFixture.Composition(objectID: 0)]),
                SupFixture.pds(pts: 90_000, entries: entries),
                SupFixture.ods(pts: 90_000, width: 1, height: 1, rle: [0x01, 0x00, 0x00]),
                SupFixture.end(pts: 90_000)
            )
            return try #require(PGSDecoder.decode(data).first?.images.first?.rgba)
        }
        #expect(try decodeColour(frameHeight: 720) == [227, 59, 98, 255])
        #expect(try decodeColour(frameHeight: 719) == [213, 39, 98, 255])
    }

    @Test func timelineFindsCueAtPositionWithOffset() {
        func cue(_ start: Double, _ end: Double) -> BitmapSubtitleCue {
            BitmapSubtitleCue(start: start, end: end, frameWidth: 1920, frameHeight: 1080, images: [])
        }
        let first = cue(1.0, 2.0)
        let second = cue(3.0, 4.0)
        let timeline = BitmapSubtitleTimeline(cues: [second, first])
        #expect(timeline.cue(at: 0.5) == nil)
        #expect(timeline.cue(at: 1.0) == first)
        #expect(timeline.cue(at: 1.9) == first)
        #expect(timeline.cue(at: 2.0) == nil)
        #expect(timeline.cue(at: 3.5) == second)
        #expect(timeline.cue(at: 4.5) == nil)
        // Positive offsets delay the subtitles, negative offsets advance them.
        #expect(timeline.cue(at: 1.5, offset: 1.0) == nil)
        #expect(timeline.cue(at: 2.2, offset: 1.0) == first)
        #expect(timeline.cue(at: 0.9, offset: -0.2) == first)
        #expect(BitmapSubtitleTimeline(cues: []).cue(at: 1.0) == nil)
    }
}
