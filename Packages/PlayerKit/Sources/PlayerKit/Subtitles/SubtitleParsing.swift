import Foundation

/// Where a cue sits on screen. Raw values are the numpad layout that ASS `\an` uses.
public enum SubtitleAlignment: Int, Sendable, Equatable {
    case bottomLeft = 1, bottom = 2, bottomRight = 3
    case middleLeft = 4, middle = 5, middleRight = 6
    case topLeft = 7, top = 8, topRight = 9

    public var isTop: Bool { row == 2 }
    public var isMiddle: Bool { row == 1 }

    /// 0 bottom, 1 middle, 2 top.
    var row: Int { (rawValue - 1) / 3 }
    /// 0 left, 1 centre, 2 right.
    var column: Int { (rawValue - 1) % 3 }

    static func make(row: Int, column: Int) -> SubtitleAlignment {
        SubtitleAlignment(rawValue: min(max(row, 0), 2) * 3 + min(max(column, 0), 2) + 1) ?? .bottom
    }
}

/// A colour with components in 0...1. Alpha 1 is opaque.
public struct SubtitleColourValue: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// A run of cue text that shares one style. Renderers draw spans; `SubtitleCue.text` is their plain join.
public struct SubtitleSpan: Sendable, Equatable {
    public var text: String
    public var isItalic: Bool
    public var isBold: Bool
    public var isUnderlined: Bool
    public var isStrikethrough: Bool
    /// Nil means the user's style colour.
    public var colour: SubtitleColourValue?

    public init(text: String, isItalic: Bool = false, isBold: Bool = false, isUnderlined: Bool = false,
                isStrikethrough: Bool = false, colour: SubtitleColourValue? = nil) {
        self.text = text
        self.isItalic = isItalic
        self.isBold = isBold
        self.isUnderlined = isUnderlined
        self.isStrikethrough = isStrikethrough
        self.colour = colour
    }
}

/// A screen position normalised to 0...1 of the video frame.
public struct SubtitlePoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct SubtitleCue: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    /// Styled runs. `text` is their plain join.
    public var spans: [SubtitleSpan]
    public var alignment: SubtitleAlignment
    /// From ASS `\pos`. Nil means `alignment` places the cue.
    public var position: SubtitlePoint?
    public var fontName: String?
    /// Relative to the reference style (the "Default" style's size). 1 means unchanged.
    public var fontScale: Double
    /// ASS layer. Higher layers draw on top.
    public var layer: Int
    /// The event uses an effect the overlay cannot draw. See `SubtitleParser.needsEngineRendering`.
    public var usesAdvancedEffects: Bool

    /// Computed from `spans`, so it can never disagree with them.
    public var text: String { spans.map(\.text).joined() }

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.init(start: start, end: end, spans: [SubtitleSpan(text: text)])
    }

    public init(start: TimeInterval, end: TimeInterval, spans: [SubtitleSpan], alignment: SubtitleAlignment = .bottom,
                position: SubtitlePoint? = nil, fontName: String? = nil, fontScale: Double = 1, layer: Int = 0,
                usesAdvancedEffects: Bool = false) {
        self.start = start
        self.end = end
        self.spans = spans
        self.alignment = alignment
        self.position = position
        self.fontName = fontName
        self.fontScale = fontScale
        self.layer = layer
        self.usesAdvancedEffects = usesAdvancedEffects
    }
}

public enum SubtitleFormat: String, Sendable {
    case srt, vtt, ass
}

public enum SubtitleError: Error, Equatable, Sendable {
    case empty
    case unreadable
    case tooLarge
    /// A picture-based format (`pgs` or `vobsub`) that this text parser cannot draw.
    case bitmap(String)
}

/// Parses SRT, WebVTT and ASS leniently: real subtitle files have BOMs, CRLF, missing indexes, dots instead of commas, and junk.
public enum SubtitleParser {
    public static let maximumBytes = 4 * 1024 * 1024
    /// ASS files embed their fonts, so they get a larger cap.
    public static let maximumASSBytes = 8 * 1024 * 1024
    /// The most a caller should download before parsing, whatever the format.
    public static var largestAcceptedBytes: Int { maximumASSBytes }
    /// Enough of the file to recognise ASS before the size cap is applied.
    private static let sniffBytes = 4096

    /// Decodes bytes (UTF-8/16 with BOM, UTF-8, else Windows-1252) and parses, detecting ASS and WebVTT by their headers.
    public static func parse(data: Data) throws -> (cues: [SubtitleCue], format: SubtitleFormat) {
        // Checked before the size cap, so a large .sup reports what it is rather than `tooLarge`.
        if let kind = bitmapKind(data) { throw SubtitleError.bitmap(kind) }
        let head = decode(data.prefix(sniffBytes)) ?? ""
        guard data.count <= (isASS(head) ? maximumASSBytes : maximumBytes) else { throw SubtitleError.tooLarge }
        guard let text = decode(data) else { throw SubtitleError.unreadable }
        let format: SubtitleFormat
        if isASS(text) {
            format = .ass
        } else if text.drop(while: { $0.isWhitespace }).hasPrefix("WEBVTT") {
            format = .vtt
        } else {
            format = .srt
        }
        let cues: [SubtitleCue]
        switch format {
        case .ass: cues = ASSParser.parse(text)
        case .vtt: cues = parseVTT(text)
        case .srt: cues = parseSRT(text)
        }
        guard !cues.isEmpty else { throw SubtitleError.empty }
        return (cues, format)
    }

    /// True when the file has effects the app's subtitle overlay cannot draw, so the engine should render it instead.
    /// Only ASS can carry them. Overlapping cues are a problem only when they sit at different positions, because the
    /// overlay stacks cues at one place but cannot place three or more apart.
    public static func needsEngineRendering(_ cues: [SubtitleCue], format: SubtitleFormat) -> Bool {
        guard format == .ass else { return false }
        if cues.contains(where: \.usesAdvancedEffects) { return true }
        var active: [SubtitleCue] = []
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            active.removeAll { $0.end <= cue.start }
            active.append(cue)
            if active.count > 2, active.contains(where: { $0.position != cue.position || $0.alignment != cue.alignment }) {
                return true
            }
        }
        return false
    }

    public static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data, encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16BigEndian) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    public static func parseSRT(_ text: String) -> [SubtitleCue] {
        parseBlocks(text, vtt: false)
    }

    public static func parseVTT(_ text: String) -> [SubtitleCue] {
        parseBlocks(text, vtt: true)
    }

    // MARK: - Internals

    /// `PG` opens every PGS/SUP segment, `00 00 01 BA` is an MPEG pack header in a VobSub `.sub`, and the `.idx` is text.
    static func bitmapKind(_ data: Data) -> String? {
        if data.starts(with: [0x50, 0x47]) { return "pgs" }
        if data.starts(with: [0x00, 0x00, 0x01, 0xBA]) { return "vobsub" }
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
        return body.starts(with: "# VobSub index file".utf8) ? "vobsub" : nil
    }

    /// ASS/SSA starts with `[Script Info]` or has an `[Events]` section header. SRT and WebVTT never do.
    static func isASS(_ text: String) -> Bool {
        if text.drop(while: { $0.isWhitespace }).hasPrefix("[Script Info]") { return true }
        return text.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "[events]" }
    }

    private static func parseBlocks(_ text: String, vtt: Bool) -> [SubtitleCue] {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalised.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            if vtt, let first = lines.first, first.hasPrefix("NOTE") || first.hasPrefix("STYLE") || first.hasPrefix("REGION") { continue }
            guard let (start, end) = parseTiming(lines[timingIndex]), end >= start else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = clean(body)
            guard !cleaned.isEmpty else { continue }
            let runs = markupRuns(body)
            var spans = lineSpans(runs.runs)
            // The plain text must stay exactly what `clean(_:)` gives. If the markup walk disagrees, keep one plain span.
            if spans.map(\.text).joined() != cleaned { spans = [SubtitleSpan(text: cleaned)] }
            var alignment = runs.alignment ?? .bottom
            if vtt { alignment = vttAlignment(lines[timingIndex], base: alignment) }
            cues.append(SubtitleCue(start: start, end: end, spans: spans, alignment: alignment))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// `00:00:01,000 --> 00:00:02,000 position:50%`, `01:02.500 --> 01:04.000`
    static func parseTiming(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2, let start = parseTimestamp(parts[0]) else { return nil }
        let endText = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard let end = parseTimestamp(endText) else { return nil }
        return (start, end)
    }

    /// `HH:MM:SS.mmm` or `MM:SS.mmm` (comma or dot before the milliseconds). Out-of-range fields are tolerated: real files have them.
    static func parseTimestamp(_ text: String) -> TimeInterval? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let pieces = cleaned.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(pieces.count) else { return nil }
        var total = 0.0
        for piece in pieces {
            guard let value = Double(piece), value >= 0, value.isFinite else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Strips markup (`<i>`, `<c.cls>`, `<v Name>`, inline timestamps, `{\an8}`), decodes entities, trims lines.
    static func clean(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"</?[a-zA-Z][^>]*>"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"<\d{1,2}:\d{2}[:.]\d{2,3}(\.\d{1,3})?>"#, with: "", options: .regularExpression)
        for (entity, replacement) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "), ("&lrm;", ""), ("&rlm;", "")] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static let entityTable: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " ", "&lrm;": "", "&rlm;": "",
    ]

    /// Walks SRT/VTT markup into styled runs. It removes the same tags, blocks and entities as `clean(_:)`, so the runs'
    /// text matches the plain text. `<i>`, `<b>`, `<u>`, `<s>`, `<font color>`, `<c.class>` and `{\i1}`-style blocks style text.
    static func markupRuns(_ body: String) -> (runs: [SubtitleSpan], alignment: SubtitleAlignment?) {
        var runs: [SubtitleSpan] = []
        var style = SubtitleSpan(text: "")
        var buffer = ""
        var alignment: SubtitleAlignment?

        func flush() {
            guard !buffer.isEmpty else { return }
            var run = style
            run.text = buffer
            runs.append(run)
            buffer = ""
        }

        var index = body.startIndex
        while index < body.endIndex {
            let char = body[index]
            if char == "{", let close = body[index...].firstIndex(of: "}"), body[body.index(after: index)] == "\\" {
                for tag in tags(in: body[body.index(after: index)..<close]) {
                    let (name, value) = splitTag(tag)
                    if name == "an" {
                        // Alignment only counts at the start of the cue, where SRT authors put `{\an8}`.
                        if runs.isEmpty, buffer.isEmpty, let number = Int(value), let found = SubtitleAlignment(rawValue: number) { alignment = found }
                    } else {
                        flush()
                        applyFlagTag(name, value: String(value), to: &style)
                    }
                }
                index = body.index(after: close)
                continue
            }
            if char == "<", let close = body[index...].firstIndex(of: ">") {
                let content = body[body.index(after: index)..<close]
                let closing = content.first == "/"
                let name = (closing ? content.dropFirst() : content).prefix { $0.isLetter }.lowercased()
                if !name.isEmpty {
                    flush()
                    switch name {
                    case "i", "b", "u", "s": applyFlagTag(name, value: closing ? "0" : "1", to: &style)
                    case "font": if closing { style.colour = nil } else if let colour = colourAttribute(content) { style.colour = colour }
                    case "c": if closing { style.colour = nil } else if let colour = classColour(content) { style.colour = colour }
                    default: break
                    }
                    index = body.index(after: close)
                    continue
                }
                // Timestamps such as `<00:00:01.500>` are dropped too. Any other `<` is literal text.
                if content.first?.isNumber == true, content.contains(":") {
                    index = body.index(after: close)
                    continue
                }
            }
            if char == "&", let entity = entityTable.first(where: { body[index...].hasPrefix($0.key) }) {
                buffer += entity.value
                index = body.index(index, offsetBy: entity.key.count)
                continue
            }
            buffer.append(char)
            index = body.index(after: index)
        }
        flush()
        return (runs, alignment)
    }

    /// Joins runs into display lines the way `clean(_:)` does: each line trimmed, empty lines dropped, lines joined by `\n`.
    /// Adjacent runs with the same style are merged, so spans stay minimal.
    static func lineSpans(_ runs: [SubtitleSpan]) -> [SubtitleSpan] {
        var lines: [[SubtitleSpan]] = [[]]
        for run in runs {
            for (index, piece) in run.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if index > 0 { lines.append([]) }
                if !piece.isEmpty {
                    var span = run
                    span.text = String(piece)
                    lines[lines.count - 1].append(span)
                }
            }
        }
        var joined: [SubtitleSpan] = []
        for var line in lines {
            trimEdges(&line)
            guard !line.isEmpty else { continue }
            if !joined.isEmpty { joined[joined.count - 1].text += "\n" }
            joined += line
        }
        var merged: [SubtitleSpan] = []
        for span in joined {
            if let last = merged.last, sameStyle(last, span) {
                merged[merged.count - 1].text += span.text
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    private static func trimEdges(_ line: inout [SubtitleSpan]) {
        while let first = line.first {
            let text = String(first.text.drop { isInlineSpace($0) })
            if !text.isEmpty {
                line[0].text = text
                break
            }
            line.removeFirst()
        }
        while let last = line.last {
            var text = last.text
            while let char = text.last, isInlineSpace(char) { text.removeLast() }
            if !text.isEmpty {
                line[line.count - 1].text = text
                break
            }
            line.removeLast()
        }
    }

    /// Same characters as `CharacterSet.whitespaces`, which is what `clean(_:)` trims.
    private static func isInlineSpace(_ char: Character) -> Bool {
        char.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
    }

    private static func sameStyle(_ a: SubtitleSpan, _ b: SubtitleSpan) -> Bool {
        a.isItalic == b.isItalic && a.isBold == b.isBold && a.isUnderlined == b.isUnderlined
            && a.isStrikethrough == b.isStrikethrough && a.colour == b.colour
    }

    /// Applies `i`, `b`, `u` or `s` to a span. Used by SRT/VTT tags and ASS overrides alike. ASS bold weights (600 and up) count as bold.
    @discardableResult
    static func applyFlagTag(_ name: String, value: String, to span: inout SubtitleSpan) -> Bool {
        guard let number = Int(value) else { return false }
        let on = name == "b" ? (number == 1 || number >= 600) : number != 0
        switch name {
        case "i": span.isItalic = on
        case "b": span.isBold = on
        case "u": span.isUnderlined = on
        case "s": span.isStrikethrough = on
        default: return false
        }
        return true
    }

    /// Splits an override block at backslashes outside parentheses, so `\t(0,100,\i1)` stays one tag.
    static func tags(in block: Substring) -> [Substring] {
        var tags: [Substring] = []
        var depth = 0
        var start = block.startIndex
        var index = block.startIndex
        while index < block.endIndex {
            switch block[index] {
            case "(": depth += 1
            case ")": depth = max(depth - 1, 0)
            case "\\" where depth == 0:
                tags.append(block[start..<index])
                start = block.index(after: index)
            default: break
            }
            index = block.index(after: index)
        }
        tags.append(block[start...])
        return tags.filter { !$0.isEmpty }
    }

    /// `fscx120` becomes ("fscx", "120"), `1c&H0000FF&` becomes ("c", "&H0000FF&") and `fnArial` becomes ("fn", "Arial").
    static func splitTag(_ tag: Substring) -> (name: String, value: Substring) {
        var end = tag.startIndex
        if tag.first?.isNumber == true { end = tag.index(after: end) }
        while end < tag.endIndex, tag[end].isLetter { end = tag.index(after: end) }
        let letters = tag[..<end]
        // Font names and `\r` style names can start with letters that are also tag names, so they are split by hand.
        if letters.hasPrefix("fn") { return ("fn", tag.dropFirst(2)) }
        if letters.hasPrefix("r") { return ("r", tag.dropFirst()) }
        return (letters == "1c" ? "c" : String(letters), tag[end...])
    }

    /// `#RRGGBB` or one of the basic names. Used by SRT `<font>` and VTT `<c.name>`.
    static func htmlColour(_ text: String) -> SubtitleColourValue? {
        let lower = text.lowercased()
        if lower.hasPrefix("#"), lower.count == 7, let value = UInt32(lower.dropFirst(), radix: 16) { return rgb(value) }
        return namedColours[lower]
    }

    /// `<font color="#FFFF00">` or `<font color=yellow>`.
    static func colourAttribute(_ tag: Substring) -> SubtitleColourValue? {
        guard let range = tag.range(of: "color=", options: .caseInsensitive) else { return nil }
        let value = tag[range.upperBound...]
            .drop { $0 == " " || $0 == "\"" || $0 == "'" }
            .prefix { $0 != " " && $0 != "\"" && $0 != "'" }
        return htmlColour(String(value))
    }

    /// `<c.yellow>` and `<c.yellow.bg_black>`: the first class that names a colour wins.
    static func classColour(_ tag: Substring) -> SubtitleColourValue? {
        for part in tag.split(separator: ".").dropFirst() {
            if let colour = namedColours[part.lowercased()] { return colour }
        }
        return nil
    }

    private static let namedColours: [String: SubtitleColourValue] = [
        "white": rgb(0xFFFFFF), "yellow": rgb(0xFFFF00), "red": rgb(0xFF0000), "green": rgb(0x00FF00),
        "blue": rgb(0x0000FF), "cyan": rgb(0x00FFFF), "magenta": rgb(0xFF00FF), "black": rgb(0x000000),
    ]

    /// Packed 0xRRGGBB.
    static func rgb(_ hex: UInt32) -> SubtitleColourValue {
        SubtitleColourValue(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// The WebVTT cue settings on the timing line. `line:0%`..`line:20%` puts the cue at the top, and `align:` sets the column.
    /// Negative lines count up from the bottom, so they keep the bottom default.
    static func vttAlignment(_ timingLine: String, base: SubtitleAlignment) -> SubtitleAlignment {
        guard let arrow = timingLine.range(of: "-->") else { return base }
        // The first token after the arrow is the end timestamp. The rest are cue settings.
        let settings = timingLine[arrow.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst()
        var row = base.row
        var column = base.column
        for setting in settings {
            let parts = setting.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1]
            switch parts[0] {
            case "line":
                if value.hasSuffix("%") {
                    if let percent = Double(value.dropLast()), percent >= 0, percent <= 20 { row = 2 }
                } else if let line = Double(value), line >= 0, line <= 1 {
                    row = 2
                }
            case "align":
                switch value {
                case "left", "start": column = 0
                case "center", "middle": column = 1
                case "right", "end": column = 2
                default: break
                }
            default:
                break
            }
        }
        return .make(row: row, column: column)
    }
}

/// Cues sorted by start time, with a shift. Look-ups are O(log n + overlap), cheap enough to run every frame.
public struct SubtitleTimeline: Sendable, Equatable {
    public let cues: [SubtitleCue]
    private let maxDuration: TimeInterval

    public init(cues: [SubtitleCue]) {
        self.cues = cues.sorted { $0.start < $1.start }
        self.maxDuration = cues.map { $0.end - $0.start }.max() ?? 0
    }

    /// Text to show at `position` seconds of playback. `offset` delays the subtitles (positive) or advances them (negative).
    public func text(at position: TimeInterval, offset: TimeInterval = 0) -> String? {
        let active = activeIndices(at: position - offset)
        return active.isEmpty ? nil : active.reversed().map { cues[$0].text }.joined(separator: "\n")
    }

    /// Cues active at `position`, in start order then layer, for renderers that need spans, positions and layers.
    public func cues(at position: TimeInterval, offset: TimeInterval = 0) -> [SubtitleCue] {
        activeIndices(at: position - offset)
            .sorted { lhs, rhs in
                let a = cues[lhs], b = cues[rhs]
                return (a.start, a.layer, lhs) < (b.start, b.layer, rhs)
            }
            .map { cues[$0] }
    }

    /// Indices of the cues active at `time`, latest start first.
    private func activeIndices(at time: TimeInterval) -> [Int] {
        guard !cues.isEmpty, time >= 0 else { return [] }
        // First cue whose start is > time, then walk back while a cue could still be active.
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        var active: [Int] = []
        var index = low - 1
        while index >= 0, cues[index].start + maxDuration >= time {
            if cues[index].end > time { active.append(index) }
            index -= 1
        }
        return active
    }
}
