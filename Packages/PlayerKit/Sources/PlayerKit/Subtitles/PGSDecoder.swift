import Foundation

/// One bitmap of a subtitle cue, placed in video-frame pixels. Decoded images keep one palette index per pixel and share their palette,
/// a quarter of the memory of RGBA: a film's worth of cues stays in tens of megabytes. `rgba` is built when the image is drawn.
public struct BitmapSubtitleImage: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    private let storage: Storage

    private enum Storage: Sendable {
        case rgba([UInt8])
        /// Indices into `palette`, whose entries are R, G, B, A bytes in memory order.
        case indexed([UInt8], palette: [UInt32])
    }

    init(x: Int, y: Int, width: Int, height: Int, rgba: [UInt8]) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
        storage = .rgba(rgba)
    }

    init(x: Int, y: Int, width: Int, height: Int, indices: [UInt8], palette: [UInt32]) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
        storage = .indexed(indices, palette: palette)
    }

    /// `width * height * 4` bytes, straight (non-premultiplied) RGBA, row-major.
    public var rgba: [UInt8] {
        switch storage {
        case .rgba(let bytes):
            return bytes
        case .indexed(let indices, let palette):
            var out = [UInt8](repeating: 0, count: indices.count * 4)
            out.withUnsafeMutableBytes { bytes in
                indices.withUnsafeBufferPointer { source in
                    palette.withUnsafeBufferPointer { colours in
                        for offset in 0..<source.count {
                            bytes.storeBytes(of: colours[Int(source[offset])], toByteOffset: offset * 4, as: UInt32.self)
                        }
                    }
                }
            }
            return out
        }
    }

    public static func == (lhs: BitmapSubtitleImage, rhs: BitmapSubtitleImage) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y && lhs.width == rhs.width && lhs.height == rhs.height && lhs.rgba == rhs.rgba
    }
}

public struct BitmapSubtitleCue: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    /// The presentation's video size, from the PCS. Image positions are in these pixels.
    public let frameWidth: Int
    public let frameHeight: Int
    public let images: [BitmapSubtitleImage]
}

public enum PGSError: Error, Equatable, Sendable {
    case notPGS
    case truncated
    case tooLarge
}

/// Decodes Blu-ray HDMV Presentation Graphic Stream (`.sup`) subtitles to RGBA bitmaps.
/// Pure Swift with no UIKit or CoreGraphics: the app turns the pixels into images.
public enum PGSDecoder {
    public static let maximumBytes = 64 * 1024 * 1024

    /// Cue length when no display set follows (end of stream or a truncated file).
    private static let trailingCueDuration: TimeInterval = 5
    private static let ticksPerSecond: Double = 90_000
    /// Object bitmaps larger than this are skipped rather than allocated.
    private static let maximumObjectPixels = 4096 * 4096

    public static func decode(_ data: Data) throws -> [BitmapSubtitleCue] {
        guard data.count <= maximumBytes else { throw PGSError.tooLarge }
        let bytes = [UInt8](data)
        guard bytes.count >= 2, bytes[0] == 0x50, bytes[1] == 0x47 else { throw PGSError.notPGS }
        var parser = Parser()
        if parser.run(bytes) { throw PGSError.truncated }
        return parser.finish()
    }

    /// Walks the segments of one stream, keeping palettes, objects and the cue still on screen.
    private struct Parser {
        struct Crop {
            let x: Int
            let y: Int
            let width: Int
            let height: Int
        }

        struct Composition {
            let objectID: Int
            let x: Int
            let y: Int
            let crop: Crop?
        }

        struct DisplaySet {
            let pts: Int
            let frameWidth: Int
            let frameHeight: Int
            let paletteID: Int
            let compositions: [Composition]
        }

        struct Object {
            let width: Int
            let height: Int
            /// Palette index per pixel, `width * height` of them.
            let indices: [UInt8]
        }

        struct PendingObject {
            let width: Int
            let height: Int
            var data: [UInt8]
        }

        struct PendingCue {
            let start: TimeInterval
            let frameWidth: Int
            let frameHeight: Int
            let images: [BitmapSubtitleImage]
        }

        /// Bounds-checked big-endian reads. Every read returns nil past `end`.
        struct Reader {
            let bytes: [UInt8]
            var position: Int
            let end: Int

            var remaining: Int { end - position }

            mutating func u8() -> Int? {
                guard position < end else { return nil }
                position += 1
                return Int(bytes[position - 1])
            }

            mutating func u16() -> Int? {
                guard let high = u8(), let low = u8() else { return nil }
                return high << 8 | low
            }

            mutating func u24() -> Int? {
                guard let high = u8(), let low = u16() else { return nil }
                return high << 16 | low
            }
        }

        private var displaySet: DisplaySet?
        /// Raw Y, Cr, Cb, Alpha per palette index (256 entries), keyed by palette ID.
        private var palettes: [Int: [UInt8]] = [:]
        private var objects: [Int: Object] = [:]
        private var pendingObjects: [Int: PendingObject] = [:]
        private var pendingCue: PendingCue?
        private var cues: [BitmapSubtitleCue] = []

        /// Returns true when the stream is cut inside its first segment.
        mutating func run(_ bytes: [UInt8]) -> Bool {
            var position = 0
            var segmentCount = 0
            while position < bytes.count {
                let headerEnd = position + 13
                guard headerEnd <= bytes.count else { return segmentCount == 0 }
                guard bytes[position] == 0x50, bytes[position + 1] == 0x47 else { return false }
                let pts = Parser.bigEndian(bytes, at: position + 2, count: 4)
                let type = bytes[position + 10]
                let size = Parser.bigEndian(bytes, at: position + 11, count: 2)
                let payloadEnd = headerEnd + size
                guard payloadEnd <= bytes.count else { return segmentCount == 0 }

                var reader = Reader(bytes: bytes, position: headerEnd, end: payloadEnd)
                switch type {
                case 0x16: presentation(pts: pts, &reader)
                case 0x14: palette(&reader)
                case 0x15: object(&reader)
                case 0x80: endDisplaySet()
                default: break  // WDS and unknown segments carry nothing the cues need.
                }
                position = payloadEnd
                segmentCount += 1
            }
            return false
        }

        mutating func finish() -> [BitmapSubtitleCue] {
            closePendingCue(at: nil)
            return cues
        }

        // MARK: - Segments

        /// A PCS starts a new display set and ends the cue on screen.
        private mutating func presentation(pts: Int, _ reader: inout Reader) {
            closePendingCue(at: Double(pts) / PGSDecoder.ticksPerSecond)
            displaySet = nil
            guard let width = reader.u16(), let height = reader.u16(), reader.u8() != nil, reader.u16() != nil,
                  let state = reader.u8(), reader.u8() != nil, let paletteID = reader.u8(), let count = reader.u8() else { return }
            var compositions: [Composition] = []
            for _ in 0..<count {
                guard let objectID = reader.u16(), reader.u8() != nil, let flags = reader.u8(),
                      let x = reader.u16(), let y = reader.u16() else { return }
                var crop: Crop?
                if (flags & 0x80) != 0 {
                    guard let cropX = reader.u16(), let cropY = reader.u16(),
                          let cropWidth = reader.u16(), let cropHeight = reader.u16() else { return }
                    crop = Crop(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
                }
                compositions.append(Composition(objectID: objectID, x: x, y: y, crop: crop))
            }
            // An epoch start resets everything the following display sets may refer to.
            if state == 0x80 {
                palettes = [:]
                objects = [:]
                pendingObjects = [:]
            }
            displaySet = DisplaySet(pts: pts, frameWidth: width, frameHeight: height, paletteID: paletteID, compositions: compositions)
        }

        /// A PDS replaces the whole palette: entries it does not list are fully transparent.
        private mutating func palette(_ reader: inout Reader) {
            guard let id = reader.u8(), reader.u8() != nil else { return }
            var entries = [UInt8](repeating: 0, count: 256 * 4)
            while reader.remaining >= 5 {
                guard let entryID = reader.u8(), let y = reader.u8(), let cr = reader.u8(),
                      let cb = reader.u8(), let alpha = reader.u8() else { break }
                let base = entryID * 4
                entries[base] = UInt8(y)
                entries[base + 1] = UInt8(cr)
                entries[base + 2] = UInt8(cb)
                entries[base + 3] = UInt8(alpha)
            }
            palettes[id] = entries
        }

        /// An ODS arrives whole (0xC0) or in fragments (0x80 first, 0x40 last). The object is decoded once its last fragment arrives.
        private mutating func object(_ reader: inout Reader) {
            guard let id = reader.u16(), reader.u8() != nil, let sequence = reader.u8() else { return }
            if (sequence & 0x80) != 0 {
                pendingObjects[id] = nil
                // The declared length counts the 4 bytes of width and height.
                guard let dataLength = reader.u24(), let width = reader.u16(), let height = reader.u16(),
                      width * height <= PGSDecoder.maximumObjectPixels else { return }
                let rleCount = min(max(dataLength - 4, 0), reader.remaining)
                let rle = Array(reader.bytes[reader.position..<(reader.position + rleCount)])
                pendingObjects[id] = PendingObject(width: width, height: height, data: rle)
            } else {
                guard var pending = pendingObjects[id] else { return }
                pending.data.append(contentsOf: reader.bytes[reader.position..<reader.end])
                pendingObjects[id] = pending
            }
            if (sequence & 0x40) != 0, let pending = pendingObjects.removeValue(forKey: id) {
                let indices = Parser.decodeRLE(pending.data, width: pending.width, height: pending.height)
                objects[id] = Object(width: pending.width, height: pending.height, indices: indices)
            }
        }

        /// The END of a display set turns its composition into the cue that starts now and ends at the next PCS.
        private mutating func endDisplaySet() {
            guard let set = displaySet else { return }
            displaySet = nil
            let images = compose(set)
            guard !images.isEmpty else { return }
            pendingCue = PendingCue(start: Double(set.pts) / PGSDecoder.ticksPerSecond,
                                    frameWidth: set.frameWidth, frameHeight: set.frameHeight, images: images)
        }

        private mutating func closePendingCue(at end: TimeInterval?) {
            guard let pending = pendingCue else { return }
            pendingCue = nil
            let cueEnd = max(end ?? pending.start + PGSDecoder.trailingCueDuration, pending.start)
            cues.append(BitmapSubtitleCue(start: pending.start, end: cueEnd, frameWidth: pending.frameWidth,
                                          frameHeight: pending.frameHeight, images: pending.images))
        }

        // MARK: - Composition

        /// Renders the set's objects with its current palette. Fully transparent images are dropped.
        private func compose(_ set: DisplaySet) -> [BitmapSubtitleImage] {
            guard !set.compositions.isEmpty, let raw = palettes[set.paletteID] else { return [] }
            let palette = Parser.packedPalette(raw, bt709: set.frameHeight >= 720)
            var images: [BitmapSubtitleImage] = []
            for composition in set.compositions {
                guard let object = objects[composition.objectID] else { continue }
                var x0 = 0, y0 = 0, width = object.width, height = object.height
                if let crop = composition.crop {
                    x0 = min(crop.x, object.width)
                    y0 = min(crop.y, object.height)
                    width = min(crop.width, object.width - x0)
                    height = min(crop.height, object.height - y0)
                }
                guard width > 0, height > 0 else { continue }

                var cropped = [UInt8](repeating: 0, count: width * height)
                var visible = false
                cropped.withUnsafeMutableBufferPointer { out in
                    object.indices.withUnsafeBufferPointer { indices in
                        palette.opaque.withUnsafeBufferPointer { opaque in
                            for row in 0..<height {
                                let source = (y0 + row) * object.width + x0
                                let target = row * width
                                for column in 0..<width {
                                    let index = indices[source + column]
                                    out[target + column] = index
                                    if opaque[Int(index)] { visible = true }
                                }
                            }
                        }
                    }
                }
                guard visible else { continue }
                images.append(BitmapSubtitleImage(x: composition.x, y: composition.y, width: width, height: height, indices: cropped,
                                                  palette: palette.colours))
            }
            return images
        }

        /// A palette as RGBA pixels: `colours[i]` holds the bytes R, G, B, A of entry i in memory order.
        /// `opaque[i]` is true when entry i has non-zero alpha.
        private struct PackedPalette {
            let colours: [UInt32]
            let opaque: [Bool]
        }

        /// YCbCr to RGBA, 256 entries. BT.709 limited range for HD frames, BT.601 otherwise.
        private static func packedPalette(_ raw: [UInt8], bt709: Bool) -> PackedPalette {
            let rgba = rgbaPalette(raw, bt709: bt709)
            let colours = (0..<256).map { entry in
                let base = entry * 4
                let value = UInt32(rgba[base]) | UInt32(rgba[base + 1]) << 8 | UInt32(rgba[base + 2]) << 16 | UInt32(rgba[base + 3]) << 24
                return value.littleEndian
            }
            return PackedPalette(colours: colours, opaque: (0..<256).map { raw[$0 * 4 + 3] != 0 })
        }

        /// YCbCr to RGBA bytes, 256 entries. BT.709 limited range for HD frames, BT.601 otherwise.
        private static func rgbaPalette(_ raw: [UInt8], bt709: Bool) -> [UInt8] {
            var rgba = [UInt8](repeating: 0, count: 256 * 4)
            for entry in 0..<256 {
                let y = Double(raw[entry * 4]) - 16
                let cr = Double(raw[entry * 4 + 1]) - 128
                let cb = Double(raw[entry * 4 + 2]) - 128
                let red: Double, green: Double, blue: Double
                if bt709 {
                    red = 1.164 * y + 1.793 * cr
                    green = 1.164 * y - 0.213 * cb - 0.533 * cr
                    blue = 1.164 * y + 2.112 * cb
                } else {
                    red = 1.164 * y + 1.596 * cr
                    green = 1.164 * y - 0.392 * cb - 0.813 * cr
                    blue = 1.164 * y + 2.017 * cb
                }
                // Fully transparent entries are all zero, whatever their (possibly undefined) YCbCr.
                guard raw[entry * 4 + 3] != 0 else { continue }
                rgba[entry * 4] = clampByte(red)
                rgba[entry * 4 + 1] = clampByte(green)
                rgba[entry * 4 + 2] = clampByte(blue)
                rgba[entry * 4 + 3] = raw[entry * 4 + 3]
            }
            return rgba
        }

        private static func clampByte(_ value: Double) -> UInt8 {
            UInt8(min(255, max(0, value.rounded())))
        }

        /// Decodes one object's RLE data into palette indices. Truncated data stops decoding, and pixels outside the object are dropped.
        private static func decodeRLE(_ data: [UInt8], width: Int, height: Int) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: width * height)
            guard !pixels.isEmpty else { return pixels }
            pixels.withUnsafeMutableBufferPointer { out in
                data.withUnsafeBufferPointer { source in
                    var index = 0, x = 0, y = 0
                    let count = source.count

                    // Writes `run` pixels of one colour from (x, y). Pixels past the right edge or bottom are dropped.
                    // The buffer starts zeroed and each pixel is written once, so colour 0 needs no store.
                    func put(_ colour: UInt8, _ run: Int) {
                        if colour != 0, y < height, x < width {
                            (out.baseAddress! + y * width + x).update(repeating: colour, count: min(width, x + run) - x)
                        }
                        x += run
                    }

                    decoding: while index < count {
                        let byte = source[index]
                        index += 1
                        if byte != 0 {
                            put(byte, 1)
                            continue
                        }
                        guard index < count else { break decoding }
                        let control = source[index]
                        index += 1
                        if control == 0 {
                            y += 1
                            x = 0
                            if y >= height { break decoding }
                            continue
                        }
                        let length = Int(control & 0x3F)
                        switch control >> 6 {
                        case 0:
                            put(0, length)
                        case 1:
                            guard index < count else { break decoding }
                            put(0, (length << 8) | Int(source[index]))
                            index += 1
                        case 2:
                            guard index < count else { break decoding }
                            put(source[index], length)
                            index += 1
                        default:
                            guard index + 1 < count else { break decoding }
                            put(source[index + 1], (length << 8) | Int(source[index]))
                            index += 2
                        }
                    }
                }
            }
            return pixels
        }

        private static func bigEndian(_ bytes: [UInt8], at start: Int, count: Int) -> Int {
            var value = 0
            for offset in 0..<count {
                value = value << 8 | Int(bytes[start + offset])
            }
            return value
        }
    }
}

/// Cues sorted by start time, with a shift. Look-ups are O(log n + overlap), cheap enough to run every frame.
public struct BitmapSubtitleTimeline: Sendable, Equatable {
    private let cues: [BitmapSubtitleCue]
    private let maxDuration: TimeInterval

    public init(cues: [BitmapSubtitleCue]) {
        self.cues = cues.sorted { $0.start < $1.start }
        self.maxDuration = cues.map { $0.end - $0.start }.max() ?? 0
    }

    /// Cue to show at `position` seconds of playback. `offset` delays the subtitles (positive) or advances them (negative).
    public func cue(at position: TimeInterval, offset: TimeInterval = 0) -> BitmapSubtitleCue? {
        let time = position - offset
        guard !cues.isEmpty, time >= 0 else { return nil }
        // First cue whose start is > time, then walk back while a cue could still be active.
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        var index = low - 1
        while index >= 0, cues[index].start + maxDuration >= time {
            if cues[index].end > time { return cues[index] }
            index -= 1
        }
        return nil
    }
}
