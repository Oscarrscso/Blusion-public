import Foundation

/// Parses ASS and SSA subtitles. A style gives each cue its defaults, and `{...}` overrides change them run by run.
/// Effects the overlay cannot draw are flagged on the cue rather than dropped, so the caller can route the file elsewhere.
enum ASSParser {
    /// Column names used when a file omits its `Format:` line.
    private static let defaultStyleFormat = ["name", "fontname", "fontsize", "primarycolour", "secondarycolour", "outlinecolour", "backcolour",
                                             "bold", "italic", "underline", "strikeout", "scalex", "scaley", "spacing", "angle", "borderstyle",
                                             "outline", "shadow", "alignment", "marginl", "marginr", "marginv", "encoding"]
    private static let defaultEventFormat = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]

    static func parse(_ text: String) -> [SubtitleCue] {
        let source = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var section = ""
        var playWidth = 384.0, playHeight = 288.0  // The ASS default when PlayRes is missing.
        var styleFormat = defaultStyleFormat
        var eventFormat = defaultEventFormat
        var styleLines: [(value: String, legacy: Bool)] = []
        var eventLines: [String] = []
        // Lines are collected first and resolved after the loop, so a Format line applies whichever way it is ordered.
        for line in source.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                section = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch section {
            case "script info":
                if key == "playresx", let width = Double(value), width > 0 { playWidth = width }
                if key == "playresy", let height = Double(value), height > 0 { playHeight = height }
            case "v4+ styles", "v4 styles":
                if key == "format" { styleFormat = columnNames(value, fallback: styleFormat) }
                if key == "style" { styleLines.append((value, section == "v4 styles")) }
            case "events":
                if key == "format" { eventFormat = columnNames(value, fallback: eventFormat) }
                if key == "dialogue" { eventLines.append(value) }
            default:
                break
            }
        }

        var styles: [String: Style] = [:]
        var orderedStyles: [Style] = []
        for (value, legacy) in styleLines {
            let fields = splitFields(value, count: styleFormat.count)
            guard let name = field("name", fields, styleFormat) else { continue }
            let style = makeStyle(fields, format: styleFormat, legacy: legacy)
            styles[styleKey(name)] = style
            orderedStyles.append(style)
        }
        let defaultStyle = styles["default"] ?? orderedStyles.first ?? Style()
        let context = Context(styles: styles, defaultStyle: defaultStyle, playWidth: playWidth, playHeight: playHeight)

        var cues: [SubtitleCue] = []
        for value in eventLines {
            let fields = splitFields(value, count: eventFormat.count)
            guard fields.count == eventFormat.count, let dialogueText = fields.last,
                  let start = field("start", fields, eventFormat).flatMap({ SubtitleParser.parseTimestamp($0) }),
                  let end = field("end", fields, eventFormat).flatMap({ SubtitleParser.parseTimestamp($0) }), end >= start
            else { continue }
            let style = styles[styleKey(field("style", fields, eventFormat) ?? "")] ?? defaultStyle
            let layer = field("layer", fields, eventFormat).flatMap { Int($0) } ?? 0
            var builder = CueBuilder(context: context, style: style)
            builder.parse(dialogueText)
            let spans = SubtitleParser.lineSpans(builder.finish())
            guard !spans.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, spans: spans, alignment: builder.alignment, position: builder.position,
                                    fontName: builder.fontName, fontScale: builder.fontScale, layer: layer,
                                    usesAdvancedEffects: builder.usesAdvancedEffects))
        }
        // Stable sort by start, so simultaneous cues keep their file order.
        return cues.enumerated().sorted { a, b in
            a.element.start != b.element.start ? a.element.start < b.element.start : a.offset < b.offset
        }.map(\.element)
    }

    /// `&HBBGGRR`, `&HAABBGGRR` (alpha 00 is opaque, FF transparent) or a decimal SSA colour.
    static func parseColour(_ value: String) -> SubtitleColourValue? {
        let text = value.trimmingCharacters(in: .whitespaces)
        let packed: UInt32
        let alphaByte: UInt32
        if text.hasPrefix("&H") || text.hasPrefix("&h") {
            var hex = text.dropFirst(2)
            if hex.hasSuffix("&") { hex = hex.dropLast() }
            guard let number = UInt32(hex, radix: 16) else { return nil }
            packed = number
            alphaByte = (number >> 24) & 0xFF
        } else {
            // Decimal SSA colours have no alpha.
            guard let number = Int(text) else { return nil }
            packed = UInt32(truncatingIfNeeded: number) & 0xFFFFFF
            alphaByte = 0
        }
        return SubtitleColourValue(red: Double(packed & 0xFF) / 255,
                                   green: Double((packed >> 8) & 0xFF) / 255,
                                   blue: Double((packed >> 16) & 0xFF) / 255,
                                   alpha: 1 - Double(alphaByte) / 255)
    }

    /// SSA numbering (V4 Alignment and `\a`): 1-3 bottom, 5-7 top, 9-11 middle. Converted to numpad.
    static func legacyAlignment(_ value: Int) -> SubtitleAlignment? {
        switch value {
        case 1...3: return SubtitleAlignment(rawValue: value)
        case 5...7: return SubtitleAlignment(rawValue: value + 2)
        case 9...11: return SubtitleAlignment(rawValue: value - 5)
        default: return nil
        }
    }

    static func styleKey(_ name: String) -> String {
        var key = name.trimmingCharacters(in: .whitespaces)
        if key.hasPrefix("*") { key.removeFirst() }
        return key.lowercased()
    }

    // MARK: - Sections

    private struct Style {
        var fontName: String?
        var fontSize = 0.0
        var colour: SubtitleColourValue?
        var isBold = false
        var isItalic = false
        var isUnderlined = false
        var isStrikethrough = false
        var alignment = SubtitleAlignment.bottom
    }

    private struct Context {
        let styles: [String: Style]
        let defaultStyle: Style
        let playWidth: Double
        let playHeight: Double

        /// Relative to the Default style's size, clamped so one odd `\fs` cannot make text unreadable.
        func scale(_ size: Double) -> Double {
            let reference = defaultStyle.fontSize
            guard reference > 0, size > 0 else { return 1 }
            return min(max(size / reference, 0.3), 4)
        }
    }

    private static func columnNames(_ value: String, fallback: [String]) -> [String] {
        let names = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return names.isEmpty ? fallback : names
    }

    private static func splitFields(_ value: String, count: Int) -> [String] {
        // The last field (Text) keeps its commas, so split at most count-1 times.
        value.split(separator: ",", maxSplits: max(count - 1, 0), omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func field(_ name: String, _ fields: [String], _ format: [String]) -> String? {
        guard let index = format.firstIndex(of: name), index < fields.count else { return nil }
        return fields[index]
    }

    private static func makeStyle(_ fields: [String], format: [String], legacy: Bool) -> Style {
        var style = Style()
        style.fontName = field("fontname", fields, format).flatMap { $0.isEmpty ? nil : $0 }
        style.fontSize = field("fontsize", fields, format).flatMap { Double($0) } ?? 0
        // An opaque white style is the format's default, not a choice: it leaves the colour to the viewer's subtitle style.
        style.colour = field("primarycolour", fields, format).flatMap { parseColour($0) }
            .flatMap { $0 == SubtitleColourValue(red: 1, green: 1, blue: 1, alpha: 1) ? nil : $0 }
        style.isBold = flag(field("bold", fields, format))
        style.isItalic = flag(field("italic", fields, format))
        style.isUnderlined = flag(field("underline", fields, format))
        style.isStrikethrough = flag(field("strikeout", fields, format))
        style.alignment = styleAlignment(field("alignment", fields, format), legacy: legacy)
        return style
    }

    /// ASS uses -1 for true, so any non-zero value counts.
    private static func flag(_ value: String?) -> Bool {
        (value.flatMap { Int($0) } ?? 0) != 0
    }

    private static func styleAlignment(_ value: String?, legacy: Bool) -> SubtitleAlignment {
        guard let value, let number = Int(value) else { return .bottom }
        if legacy { return legacyAlignment(number) ?? .bottom }
        return SubtitleAlignment(rawValue: number) ?? .bottom
    }

    // MARK: - Dialogue text

    /// Walks one Dialogue's text, applying overrides to the run style and collecting cue-level settings.
    private struct CueBuilder {
        let context: Context
        /// The line's own style. `\r` with no name returns to it.
        let style: Style
        var run = SubtitleSpan(text: "")
        var runs: [SubtitleSpan] = []
        var buffer = ""
        var alignment = SubtitleAlignment.bottom
        var position: SubtitlePoint?
        var fontName: String?
        var fontScale = 1.0
        var isDrawing = false
        var usesAdvancedEffects = false

        init(context: Context, style: Style) {
            self.context = context
            self.style = style
            reset(to: style)
        }

        mutating func parse(_ text: String) {
            var index = text.startIndex
            while index < text.endIndex {
                let char = text[index]
                if char == "{", let close = text[index...].firstIndex(of: "}") {
                    for tag in SubtitleParser.tags(in: text[text.index(after: index)..<close]) { apply(tag) }
                    index = text.index(after: close)
                    continue
                }
                if char == "\\" {
                    let next = text.index(after: index)
                    if next < text.endIndex, let replacement = Self.escape(text[next]) {
                        if !isDrawing { buffer += replacement }
                        index = text.index(after: next)
                        continue
                    }
                }
                if !isDrawing { buffer.append(char) }
                index = text.index(after: index)
            }
        }

        mutating func finish() -> [SubtitleSpan] {
            flush()
            return runs
        }

        /// `\N` is a hard break, `\n` a soft one (a space unless WrapStyle 2), `\h` a non-breaking space.
        private static func escape(_ char: Character) -> String? {
            switch char {
            case "N": return "\n"
            case "n": return " "
            case "h": return "\u{00A0}"
            default: return nil
            }
        }

        private mutating func flush() {
            guard !buffer.isEmpty else { return }
            var piece = run
            piece.text = buffer
            runs.append(piece)
            buffer = ""
        }

        /// Starts a fresh run in the given style. Cue-level settings follow it too, since `\r` resets them.
        private mutating func reset(to style: Style) {
            flush()
            run = SubtitleSpan(text: "", isItalic: style.isItalic, isBold: style.isBold, isUnderlined: style.isUnderlined,
                               isStrikethrough: style.isStrikethrough, colour: style.colour)
            alignment = style.alignment
            fontName = style.fontName
            fontScale = context.scale(style.fontSize)
        }

        private static let advancedNames: Set<String> = ["move", "t", "fad", "fade", "clip", "iclip"]

        private mutating func apply(_ tag: Substring) {
            let (name, valueText) = SubtitleParser.splitTag(tag)
            let value = String(valueText)
            // These need the engine. They are flagged on the cue, and the cue's text still shows.
            if Self.advancedNames.contains(name) || name.hasPrefix("fr") || name.hasPrefix("k") || name == "K" {
                usesAdvancedEffects = true
            }
            switch name {
            case "i", "b", "u", "s":
                flush()
                SubtitleParser.applyFlagTag(name, value: value, to: &run)
            case "c":
                flush()
                if value.isEmpty {
                    run.colour = style.colour
                } else if let colour = ASSParser.parseColour(value) {
                    run.colour = colour
                }
            case "r":
                flush()
                let named = value.isEmpty ? nil : context.styles[ASSParser.styleKey(value)]
                reset(to: named ?? style)
            case "an":
                if let number = Int(value), let found = SubtitleAlignment(rawValue: number) { alignment = found }
            case "a":
                if let number = Int(value), let found = ASSParser.legacyAlignment(number) { alignment = found }
            case "fn":
                fontName = value.isEmpty ? style.fontName : value
            case "fs":
                if let size = Double(value), size > 0 { fontScale = context.scale(size) }
            case "pos":
                let numbers = value.trimmingCharacters(in: CharacterSet(charactersIn: "()")).split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if numbers.count == 2 {
                    position = SubtitlePoint(x: numbers[0] / context.playWidth, y: numbers[1] / context.playHeight)
                }
            case "p":
                // Drawing mode replaces text with vector paths, so text is dropped until `\p0`.
                if let mode = Int(value) {
                    isDrawing = mode > 0
                    if mode > 0 { usesAdvancedEffects = true }
                }
            default:
                break
            }
        }
    }
}
