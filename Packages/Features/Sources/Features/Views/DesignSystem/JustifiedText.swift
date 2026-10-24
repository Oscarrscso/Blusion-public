#if canImport(UIKit)
import CoreText
import SwiftUI
import UIKit

/// Text set justified, which SwiftUI's `Text` cannot do. It is laid out and drawn by `JustifiedLabel` in the body font of `textStyle`
/// (it follows Dynamic Type). Lines break where `JustifiedLineBreaker` puts them so the word gaps come out alike, and every line but the
/// last of a paragraph is justified by widening only the gaps between words. A word wider than a line is wrapped onto as many lines as it
/// needs (see `JustifiedLabel.makeLayout`); only a single character wider than the line is cut.
///
/// `lineLimit` shows that many lines of the same layout, the last one ending in an ellipsis after a whole word; zero shows every line.
/// With `isTruncated` it says whether the cut text leaves some out. Pass `lineLimit` zero (expanded) and it leaves the answer as it was.
struct JustifiedText: UIViewRepresentable {
    let text: String
    var textStyle: UIFont.TextStyle = .body
    var color: UIColor = .label
    /// Read as inline Markdown, as `Text(LocalizedStringKey)` reads it. Plain otherwise, as `Text(String)` shows it.
    var isMarkdown = false
    /// The lines shown; zero shows them all.
    var lineLimit = 0
    /// With a line limit, the cut text always takes that many lines, so cards holding texts of different lengths share a height.
    var reservesSpace = false
    var isTruncated: Binding<Bool>?
    /// The fewest characters a line should hold; see `JustifiedLineBreaker`.
    var minimumLineCharacters = JustifiedLineBreaker.defaultMinimumCharacters
    /// The most characters a line may hold. None by default, so lines fill the width they are given; a narrower measure limits the frame.
    var maximumLineCharacters = JustifiedLineBreaker.defaultMaximumCharacters
    /// Draws the web links in the text (see `TextLinks`) in the link colour and underlined: markdown links and bare http or https URLs.
    var showsLinks = false
    /// With `showsLinks`, a tap on a link is reported to `onTap` with that link, and VoiceOver offers the links as actions. Off, a tap
    /// reports no link.
    var linksAreTappable = false
    /// Called with the link a tap lands on, or nil for a tap elsewhere on the text. Unset, the text takes no taps, so the views around it
    /// get them as before.
    var onTap: ((URL?) -> Void)?

    func makeUIView(context: Context) -> JustifiedLabel {
        let label = JustifiedLabel(frame: .zero)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    func updateUIView(_ label: JustifiedLabel, context: Context) {
        configure(label)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: JustifiedLabel, context: Context) -> CGSize? {
        configure(label)
        // One layout for this width answers both the whole text and the limited one.
        let measured = label.measure(width: proposal.width ?? .greatestFiniteMagnitude)
        if let isTruncated, lineLimit > 0 {
            report(truncated: measured.totalLines > lineLimit, to: isTruncated)
        }
        let height = JustifiedSizing.height(totalLines: measured.totalLines, lineLimit: lineLimit, reservesSpace: reservesSpace,
                                            lineHeight: measured.lineHeight)
        return CGSize(width: proposal.width ?? measured.widestLine, height: height)
    }

    private func configure(_ label: JustifiedLabel) {
        label.show(text: text, textStyle: textStyle, color: color, isMarkdown: isMarkdown, showsLinks: showsLinks)
        label.lineLimit = lineLimit
        label.minimumLineCharacters = minimumLineCharacters
        label.maximumLineCharacters = maximumLineCharacters
        label.linksAreTappable = linksAreTappable
        label.onTap = onTap
    }

    /// Sets the answer after the layout pass, and only when it changed, so the state never changes during a layout.
    private func report(truncated: Bool, to binding: Binding<Bool>) {
        guard binding.wrappedValue != truncated else { return }
        let set: @MainActor (Bool) -> Void = { binding.wrappedValue = $0 }
        Task { @MainActor in set(truncated) }
    }
}

/// The view behind `JustifiedText`. It measures each word once, keeps the line layouts of the last few widths, and draws the lines with
/// Core Text, so a container that animates its width pays for a layout only at widths it has not met.
final class JustifiedLabel: UIView {
    private struct Look: Equatable {
        let text: String
        let textStyle: UIFont.TextStyle
        let color: UIColor
        let isMarkdown: Bool
        let showsLinks: Bool
        let category: UIContentSizeCategory
        let style: UIUserInterfaceStyle
    }

    /// A word, ready to draw. Its attributes may change inside it (a bold part), and it keeps those of its last character for an ellipsis.
    /// It keeps its text as well, so a word wider than a line can be wrapped into pieces when the layout is made.
    private struct Word {
        let text: NSAttributedString
        let line: CTLine
        let width: CGFloat
        let characters: Int
        let endAttributes: [NSAttributedString.Key: Any]
    }

    /// A link as the last drawing placed it: the frame it covers in its line, so a tap near it can find it (see `JustifiedLinkHit`).
    private struct PlacedLink {
        let frame: CGRect
        let url: URL
    }

    /// The measured text: its paragraphs of words, the metrics of the base font, and the links in it.
    private struct Content {
        let paragraphs: [[Word]]
        let font: UIFont
        let spaceWidth: CGFloat
        let plain: String
        let links: [TextLink]
    }

    /// One line of a layout: the words it takes from the layout's words, and whether it is its paragraph's last line (which is not justified).
    private struct Line {
        let words: Range<Int>
        let isParagraphEnd: Bool
    }

    /// A text laid out at one width: its words, with the pieces of any wrapped word in place of it, and the lines that take them in order.
    private final class Layout {
        let words: [Word]
        let lines: [Line]
        let widestLine: CGFloat
        init(words: [Word], lines: [Line], widestLine: CGFloat) {
            self.words = words
            self.lines = lines
            self.widestLine = widestLine
        }
    }

    private struct LayoutKey: Equatable {
        let halfPoints: Int
        let minimum: Int
        let maximum: Int
    }

    /// How many widths keep their layout.
    private static let cachedLayouts = 4
    /// The width used when none is proposed: wide enough that only the character limit and newlines break lines.
    private static let unboundedWidth: CGFloat = 100_000

    private var look: Look?
    private var content: Content?
    private var layouts: [(key: LayoutKey, layout: Layout)] = []
    /// The width of the last measurement. Drawing uses that layout when the view's width is within a pixel of it (see `JustifiedSizing`).
    private var measuredWidth: CGFloat?
    /// The links the last drawing placed, each with the frame it covers. Empty unless links are tappable.
    private var placedLinks: [PlacedLink] = []
    /// Taps the text when `onTap` is set. Off until then, so a text without it takes no touches.
    private let tapRecognizer = UITapGestureRecognizer()

    /// Whether a tap on a link reports it, and the links are offered to VoiceOver. See `JustifiedText.linksAreTappable`.
    var linksAreTappable = false {
        didSet {
            guard linksAreTappable != oldValue else { return }
            updateLinkActions()
            setNeedsDisplay()
        }
    }
    /// Called on each tap with the link under it, or nil. See `JustifiedText.onTap`.
    var onTap: ((URL?) -> Void)? {
        didSet { tapRecognizer.isEnabled = onTap != nil }
    }

    /// The lines shown; zero shows them all.
    var lineLimit = 0 {
        didSet { if lineLimit != oldValue { setNeedsDisplay() } }
    }
    var minimumLineCharacters = JustifiedLineBreaker.defaultMinimumCharacters {
        didSet { if minimumLineCharacters != oldValue { setNeedsDisplay() } }
    }
    var maximumLineCharacters = JustifiedLineBreaker.defaultMaximumCharacters {
        didSet { if maximumLineCharacters != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) { (label: JustifiedLabel, _) in
            label.rebuildForTraits()
        }
        tapRecognizer.addTarget(self, action: #selector(tapped(_:)))
        tapRecognizer.isEnabled = false
        addGestureRecognizer(tapRecognizer)
    }

    required init?(coder: NSCoder) {
        fatalError("JustifiedLabel is made in code only")
    }

    /// Sets the text and its look, when either differs from what is shown.
    func show(text: String, textStyle: UIFont.TextStyle, color: UIColor, isMarkdown: Bool, showsLinks: Bool) {
        let next = Look(text: text, textStyle: textStyle, color: color, isMarkdown: isMarkdown, showsLinks: showsLinks,
                        category: traitCollection.preferredContentSizeCategory, style: traitCollection.userInterfaceStyle)
        guard next != look else { return }
        look = next
        content = build(next)
        layouts = []
        accessibilityLabel = content?.plain
        updateLinkActions()
        setNeedsDisplay()
        invalidateIntrinsicContentSize()
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        onTap?(linksAreTappable ? link(at: recognizer.location(in: self)) : nil)
    }

    /// The link the last drawing placed nearest `point`, if one is near it (see `JustifiedLinkHit`).
    private func link(at point: CGPoint) -> URL? {
        JustifiedLinkHit.index(at: point, frames: placedLinks.map(\.frame)).map { placedLinks[$0].url }
    }

    /// Offers the links to VoiceOver as actions when they are tappable. A folded text offers none, so its links read as plain text.
    private func updateLinkActions() {
        guard linksAreTappable, let content, !content.links.isEmpty else {
            accessibilityCustomActions = nil
            return
        }
        let plain = content.plain as NSString
        accessibilityCustomActions = content.links.map { link in
            UIAccessibilityCustomAction(name: plain.substring(with: link.range), actionHandler: { [weak self] _ in
                self?.onTap?(link.url)
                return true
            })
        }
    }

    /// What the text takes at `width`: its lines in all, the widest of them, and the height of one line.
    func measure(width: CGFloat) -> (totalLines: Int, widestLine: CGFloat, lineHeight: CGFloat) {
        guard let content else { return (0, 0, UIFont.preferredFont(forTextStyle: .body).lineHeight) }
        measuredWidth = width
        let layout = layout(forWidth: width)
        return (layout.lines.count, layout.widestLine, content.font.lineHeight)
    }

    private func rebuildForTraits() {
        guard let look else { return }
        self.look = nil
        show(text: look.text, textStyle: look.textStyle, color: look.color, isMarkdown: look.isMarkdown, showsLinks: look.showsLinks)
    }

    // MARK: Building the words

    private func build(_ look: Look) -> Content {
        let font = UIFont.preferredFont(forTextStyle: look.textStyle, compatibleWith: traitCollection)
        let color = look.color.resolvedColor(with: traitCollection)
        let text = attributed(look, font: font, color: color)
        let string = text.string as NSString
        let space = CTLineCreateWithAttributedString(NSAttributedString(string: " ", attributes: attributes(font: font, color: color)))
        let spaceWidth = CGFloat(CTLineGetTypographicBounds(space, nil, nil, nil))

        var paragraphs: [[Word]] = []
        var words: [Word] = []
        var wordStart: Int?
        func endWord(at end: Int) {
            guard let start = wordStart else { return }
            wordStart = nil
            let piece = text.attributedSubstring(from: NSRange(location: start, length: end - start))
            words.append(makeWord(piece, line: CTLineCreateWithAttributedString(piece)))
        }
        for index in 0..<string.length {
            switch string.character(at: index) {
            case 0x0A:
                endWord(at: index)
                paragraphs.append(words)
                words = []
            case 0x20, 0x09, 0x0D:
                endWord(at: index)
            default:
                if wordStart == nil { wordStart = index }
            }
        }
        endWord(at: string.length)
        paragraphs.append(words)
        while paragraphs.count > 1, paragraphs.last?.isEmpty == true { paragraphs.removeLast() }
        if paragraphs.count == 1, paragraphs[0].isEmpty { paragraphs = [] }
        return Content(paragraphs: paragraphs, font: font, spaceWidth: spaceWidth, plain: text.string, links: links(in: text))
    }

    /// The links drawn in `text`, found by their link attribute.
    private func links(in text: NSAttributedString) -> [TextLink] {
        var links: [TextLink] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let url = value as? URL { links.append(TextLink(range: range, url: url)) }
        }
        return links
    }

    /// The word made of `piece`, drawn as `line`.
    private func makeWord(_ piece: NSAttributedString, line: CTLine) -> Word {
        Word(text: piece, line: line, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), characters: piece.string.count,
             endAttributes: piece.attributes(at: piece.length - 1, effectiveRange: nil))
    }

    private func attributes(font: UIFont, color: UIColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor]
    }

    /// The text in the base font and colour. Markdown keeps its bold and italic as traits of that font. With `showsLinks`, the links are
    /// given their link look; code is plain text.
    private func attributed(_ look: Look, font: UIFont, color: UIColor) -> NSAttributedString {
        let base = attributes(font: font, color: color)
        let result = NSMutableAttributedString()
        var markdownLinks: [TextLink] = []
        if look.isMarkdown, let parsed = try? AttributedString(markdown: look.text,
                                                               options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            for run in parsed.runs {
                var traits: UIFontDescriptor.SymbolicTraits = []
                if let intent = run.inlinePresentationIntent {
                    if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                    if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                }
                var runFont = font
                if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                    runFont = UIFont(descriptor: descriptor, size: font.pointSize)
                }
                var runAttributes = base
                runAttributes[.font] = runFont
                let piece = String(parsed[run.range].characters)
                if let url = run.link {
                    markdownLinks.append(TextLink(range: NSRange(location: result.length, length: piece.utf16.count), url: url))
                }
                result.append(NSAttributedString(string: piece, attributes: runAttributes))
            }
        } else {
            result.append(NSAttributedString(string: look.text, attributes: base))
        }
        // Bare URLs are found in the text as shown. A markdown link keeps its own target, and TextLinks drops any other scheme.
        if look.showsLinks {
            for link in TextLinks.all(in: result.string, markdown: markdownLinks) {
                result.addAttributes(linkAttributes(url: link.url), range: link.range)
            }
        }
        return result
    }

    /// The look of a link: the system link colour, underlined, with the URL as its value. Core Text reads its own key for the colour, so
    /// both are given. The underline has one key: Core Text's is the same string as `.underlineStyle`, and a dictionary literal traps on
    /// a key given twice.
    private func linkAttributes(url: URL) -> [NSAttributedString.Key: Any] {
        let tint = UIColor.link.resolvedColor(with: traitCollection)
        return [
            .link: url,
            .foregroundColor: tint,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): tint.cgColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
    }

    // MARK: Layout

    private func layout(forWidth proposed: CGFloat) -> Layout {
        let width = proposed.isFinite && proposed < Self.unboundedWidth ? max(proposed, 1) : Self.unboundedWidth
        let key = LayoutKey(halfPoints: Int((width * 2).rounded(.down)), minimum: minimumLineCharacters, maximum: maximumLineCharacters)
        if let index = layouts.firstIndex(where: { $0.key == key }) {
            let entry = layouts.remove(at: index)
            layouts.append(entry)
            return entry.layout
        }
        // Rounded down to the half point, so a line is never wider than the view.
        let layout = makeLayout(width: max(1, CGFloat(key.halfPoints) / 2), key: key)
        layouts.append((key, layout))
        if layouts.count > Self.cachedLayouts { layouts.removeFirst() }
        return layout
    }

    private func makeLayout(width: CGFloat, key: LayoutKey) -> Layout {
        guard let content else { return Layout(words: [], lines: [], widestLine: 0) }
        var words: [Word] = []
        var lines: [Line] = []
        var widest: CGFloat = 0
        for paragraph in content.paragraphs {
            let first = words.count
            if paragraph.isEmpty {
                lines.append(Line(words: first..<first, isParagraphEnd: true))
                continue
            }
            var pieces: [Word] = []
            var joinedToPrevious: [Bool] = []
            for word in paragraph {
                let parts = wrapped(word, width: width)
                pieces += parts
                joinedToPrevious += parts.indices.map { $0 > 0 }
            }
            let ranges = JustifiedLineBreaker.breaks(wordWidths: pieces.map(\.width), wordCharacters: pieces.map(\.characters),
                                                     spaceWidth: content.spaceWidth, lineWidth: width,
                                                     minimumCharacters: key.minimum, maximumCharacters: key.maximum,
                                                     joinedToPrevious: joinedToPrevious)
            words += pieces
            for (offset, range) in ranges.enumerated() {
                lines.append(Line(words: (first + range.lowerBound)..<(first + range.upperBound), isParagraphEnd: offset == ranges.count - 1))
                widest = max(widest, naturalWidth(pieces[range], content.spaceWidth))
            }
        }
        return Layout(words: words, lines: lines, widestLine: min(widest, width))
    }

    /// The word itself when it fits a line of `width`; otherwise its pieces, each as long as fits, so a long URL takes as many lines as it
    /// needs. A piece ends after a wrap character near its end when there is one (see `JustifiedLineBreaker.wrapLength`), and the breaker
    /// keeps each piece off the line of the piece before it.
    private func wrapped(_ word: Word, width: CGFloat) -> [Word] {
        guard word.width > width else { return [word] }
        let text = word.text
        let string = text.string as NSString
        let units = Array(text.string.utf16)
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        var pieces: [Word] = []
        var start = 0
        while start < units.count {
            var fitting = CTTypesetterSuggestClusterBreak(typesetter, start, Double(width))
            if fitting < 1 { fitting = string.rangeOfComposedCharacterSequence(at: start).length }
            let length = JustifiedLineBreaker.wrapLength(units: units, start: start, fitting: fitting) {
                string.rangeOfComposedCharacterSequence(at: $0).location == $0
            }
            let piece = text.attributedSubstring(from: NSRange(location: start, length: length))
            pieces.append(makeWord(piece, line: CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length))))
            start += length
        }
        return pieces
    }

    private func compressedWidth(_ words: ArraySlice<Word>, _ space: CGFloat) -> CGFloat {
        JustifiedSpacing.compressedWidth(wordsWidth: words.reduce(0) { $0 + $1.width }, wordCount: words.count, spaceWidth: space)
    }

    private func naturalWidth(_ words: ArraySlice<Word>, _ space: CGFloat) -> CGFloat {
        words.reduce(0) { $0 + $1.width } + space * CGFloat(max(0, words.count - 1))
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let content, let context = UIGraphicsGetCurrentContext(), bounds.width > 0 else { return }
        // The layout the height was measured with, so every line it counted is drawn.
        let layout = layout(forWidth: JustifiedSizing.layoutWidth(measured: measuredWidth, bounds: bounds.width))
        let width = bounds.width
        let total = layout.lines.count
        let shown = JustifiedSizing.shownLines(total: total, lineLimit: lineLimit)
        let isCut = lineLimit > 0 && total > lineLimit
        let scale = max(contentScaleFactor, 1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        placedLinks = []
        for index in 0..<shown {
            let line = layout.lines[index]
            let words = Array(layout.words[line.words])
            guard !words.isEmpty else { continue }
            let baseline = ((CGFloat(index) * content.font.lineHeight + content.font.ascender) * scale).rounded() / scale
            let cut = isCut && index == shown - 1
            drawLine(words, in: context, content: content, width: width, baseline: baseline, scale: scale,
                     justified: !line.isParagraphEnd, ellipsis: cut)
        }
    }

    /// The links in `word`, each with the frame it covers in a line where the word starts at `x`. The extent is measured from the
    /// word's own text, not from string indices in its line: a piece of a wrapped word has a line of its own, indexed from its start.
    private func linkFrames(in word: Word, x: CGFloat, top: CGFloat, height: CGFloat) -> [PlacedLink] {
        var frames: [PlacedLink] = []
        let text = word.text
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let url = value as? URL else { return }
            let leading = NSRange(location: 0, length: range.location)
            let through = NSRange(location: 0, length: NSMaxRange(range))
            let start = range.location == 0 ? 0 : typographicWidth(text.attributedSubstring(from: leading))
            let end = NSMaxRange(range) >= text.length ? word.width : typographicWidth(text.attributedSubstring(from: through))
            frames.append(PlacedLink(frame: CGRect(x: x + start, y: top, width: max(0, end - start), height: height), url: url))
        }
        return frames
    }

    /// The typographic width of `text` drawn as one line.
    private func typographicWidth(_ text: NSAttributedString) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil))
    }

    /// Draws one line. Justified, the gaps between words share the slack equally, up to a cap (see `JustifiedSpacing`); otherwise the words
    /// keep single spaces from the leading edge. A line too long at single spaces shrinks its gaps. A word wider than the line is cut
    /// short with an ellipsis to fit, never scaled and never drawn past the line. The layout wraps longer words, so only a single character
    /// wider than the line is cut this way. With `ellipsis`, trailing words are dropped until the mark fits.
    private func drawLine(_ words: [Word], in context: CGContext, content: Content, width: CGFloat, baseline: CGFloat, scale: CGFloat,
                          justified: Bool, ellipsis: Bool) {
        var kept = words
        var mark: (line: CTLine, width: CGFloat)?
        if ellipsis, let last = words.last {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: last.endAttributes))
            mark = (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
            while kept.count > 1, compressedWidth(kept[...], content.spaceWidth) + (mark?.width ?? 0) > width { kept.removeLast() }
        }
        let markWidth = mark?.width ?? 0
        let widths = kept.enumerated().map { $0.element.width + ($0.offset == kept.count - 1 ? markWidth : 0) }
        let sum = widths.reduce(0, +)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(x: 0, y: -10_000, width: width, height: 20_000_000))
        if kept.count == 1, let only = kept.first, sum > width {
            // One character wider than the line, which the layout cannot wrap: cut at the tail to an ellipsis, on a line of its own.
            let token = mark?.line ?? CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: only.endAttributes))
            let line = CTLineCreateTruncatedLine(only.line, Double(width), .end, token) ?? only.line
            context.textPosition = CGPoint(x: 0, y: baseline)
            CTLineDraw(line, context)
            return
        }
        let gap = JustifiedSpacing.gap(wordsWidth: sum, wordCount: kept.count, spaceWidth: content.spaceWidth, lineWidth: width,
                                       justified: justified)
        var x: CGFloat = 0
        for (offset, word) in kept.enumerated() {
            context.textPosition = CGPoint(x: (x * scale).rounded() / scale, y: baseline)
            CTLineDraw(word.line, context)
            if linksAreTappable {
                // The line box of the word: its top is the line's top, which the baseline sits `ascender` below.
                placedLinks += linkFrames(in: word, x: x, top: baseline - content.font.ascender, height: content.font.lineHeight)
            }
            if offset == kept.count - 1, let mark {
                context.textPosition = CGPoint(x: ((x + word.width) * scale).rounded() / scale, y: baseline)
                CTLineDraw(mark.line, context)
            }
            x += widths[offset] + gap
        }
    }
}
#endif
