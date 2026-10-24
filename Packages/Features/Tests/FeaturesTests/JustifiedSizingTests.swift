import CoreGraphics
import Testing
@testable import Features

@Suite struct JustifiedSizingTests {
    /// A long synopsis of several paragraphs; each letter is 7 wide and a space 7 wide.
    private static let paragraphs: [String] = (0..<6).map { index in
        (0..<(40 + index * 13)).map { word in String(repeating: "x", count: 2 + (word * 7 + index * 3) % 9) }.joined(separator: " ")
    }

    /// The lines the whole text takes at `width`, as the label's layout counts them: each paragraph broken on its own.
    private func lineCount(width: CGFloat) -> Int {
        Self.paragraphs.reduce(0) { total, paragraph in
            let words = paragraph.split(separator: " ")
            return total + JustifiedLineBreaker.breaks(wordWidths: words.map { CGFloat($0.count) * 7 }, wordCharacters: words.map(\.count),
                                                       spaceWidth: 7, lineWidth: width, minimumCharacters: JustifiedLineBreaker.defaultMinimumCharacters,
                                                       maximumCharacters: JustifiedLineBreaker.defaultMaximumCharacters).count
        }
    }

    @Test func drawsAtTheMeasuredWidthWhenThePixelSnappedWidthIsClose() {
        #expect(JustifiedSizing.layoutWidth(measured: 361.33, bounds: 361.67) == 361.33)
        #expect(JustifiedSizing.layoutWidth(measured: 361.33, bounds: 361.0) == 361.33)
    }

    @Test func drawsAtTheViewsWidthWhenItIsFarFromTheMeasuredOne() {
        #expect(JustifiedSizing.layoutWidth(measured: 300, bounds: 361) == 361)
        #expect(JustifiedSizing.layoutWidth(measured: nil, bounds: 361) == 361)
        #expect(JustifiedSizing.layoutWidth(measured: .greatestFiniteMagnitude, bounds: 361) == 361)
    }

    /// Every width a view could be snapped to from the measured one lays out as many lines as were measured, so none is cut off.
    @Test func everySnappedWidthDrawsTheMeasuredLineCount() {
        var checked = 0
        for measuredHalfPoints in 400..<900 {
            let measured = CGFloat(measuredHalfPoints) / 2
            let expected = lineCount(width: measured)
            for drift in stride(from: -1.0, through: 1.0, by: 1.0 / 3) {
                let bounds = measured + CGFloat(drift)
                let drawn = JustifiedSizing.layoutWidth(measured: measured, bounds: bounds)
                #expect(lineCount(width: drawn) == expected)
                checked += 1
            }
        }
        #expect(checked > 0)
    }

    /// Without the rule, a drift of a pixel does change the count for a long text, which is how the last lines were cut.
    @Test func aFewPixelsCanChangeTheLineCountOfALongText() {
        let counts = (400..<900).map { lineCount(width: CGFloat($0) / 2) != lineCount(width: CGFloat($0) / 2 + 0.5) }
        #expect(counts.contains(true))
    }

    @Test func expandedHeightHoldsEveryLine() {
        let lineHeight: CGFloat = 20.3
        let total = lineCount(width: 361)
        #expect(total > 20)
        let expanded = JustifiedSizing.height(totalLines: total, lineLimit: 0, reservesSpace: false, lineHeight: lineHeight)
        #expect(expanded >= CGFloat(total) * lineHeight)
        #expect(JustifiedSizing.shownLines(total: total, lineLimit: 0) == total)
    }

    @Test func foldedHeightKeepsTheLimitAndReservesShortTexts() {
        #expect(JustifiedSizing.height(totalLines: 10, lineLimit: 3, reservesSpace: false, lineHeight: 20) == 60)
        #expect(JustifiedSizing.height(totalLines: 2, lineLimit: 3, reservesSpace: false, lineHeight: 20) == 40)
        #expect(JustifiedSizing.height(totalLines: 2, lineLimit: 3, reservesSpace: true, lineHeight: 20) == 60)
    }
}
