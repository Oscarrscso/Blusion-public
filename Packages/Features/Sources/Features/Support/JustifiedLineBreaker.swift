import CoreGraphics
import Foundation

/// Chooses where the lines of one paragraph break so that, once each line is justified, the gaps between words come out alike and none is
/// extreme. It is a minimum-raggedness dynamic programme over the whole paragraph (a total fit), not a greedy fill: a line is allowed to be
/// a little short if that keeps the next one from being very loose. The breaker never splits a word; a word wider than the line is wrapped
/// into pieces by the layout first (see `wrapLength`).
enum JustifiedLineBreaker {
    /// The fewest characters a line should hold, spaces between its words included. Tunable. Shorter lines are allowed when nothing else
    /// fits, for instance before a very long word, but they cost more.
    static let defaultMinimumCharacters = 18
    /// The most characters a line may hold, spaces between its words included. No limit by default, so lines fill the width they are
    /// given; a caller that wants a narrower measure limits the width of the view instead. A single word longer than this still takes a
    /// line of its own.
    static let defaultMaximumCharacters = Int.max

    /// What a short line costs on top of its looseness, so the breaker avoids it unless the alternative is worse.
    private static let shortLinePenalty = 4.0
    /// What a line of one word costs when a second word would have fitted.
    private static let loneWordPenalty = 1.5
    /// What a last line of one short word (a widow) costs.
    private static let widowPenalty = 0.5
    /// A last line of one word with fewer characters than this is a widow.
    private static let widowCharacters = 8
    /// The narrowest a gap between two words may be, as a share of the natural space. A line takes another word before it stretches, as long
    /// as its gaps stay at least this wide. The breaker and the drawing use the same figure, so a line fits the same way in both.
    static let minimumGapFactor: CGFloat = 0.75
    /// The widest a gap may be, as a share of the natural space, on a line that is justified. A line that would need more is ragged: it is
    /// drawn with natural gaps from the leading edge instead of stretched.
    static let maximumGapFactor: CGFloat = 1.9
    /// What a gap stretched past the natural space costs, per unit of stretch cubed (the stretch in natural spaces). Steeper than the
    /// slack, so the breaker prefers lines of alike gaps.
    private static let stretchWeight = 1.0
    /// What a gap compressed under the natural space costs, per unit of compression squared.
    private static let compressWeight = 2.0
    /// What a ragged line costs before its slack. A justified line costs about one at most, so every ragged line costs more than any
    /// justified one.
    private static let raggedPenalty = 3.0
    /// What a ragged line costs per unit of slack squared. Its slack is the share of the width it leaves empty, clamped to 0...1, so a
    /// fuller ragged line is cheaper, and from the same start a ragged line with more words always is.
    private static let raggedWeight = 10.0
    /// The characters a word wider than a line may wrap after, when one lies near the end of a piece. They end the parts of a URL or path.
    private static let wrapAfter: Set<UInt16> = Set("/-.?&=_%".utf16)
    /// Costs closer than this are equal, and the tie-break decides.
    private static let epsilon = 1e-9

    /// The word range of each line of one paragraph.
    /// - Parameters:
    ///   - wordWidths: the width of each word on its own.
    ///   - wordCharacters: the number of characters of each word.
    ///   - spaceWidth: the width of the single space between two words on a line.
    ///   - lineWidth: the width a line may take.
    ///   - minimumCharacters: the fewest characters a line should hold; a soft limit.
    ///   - maximumCharacters: the most characters a line may hold, unless it is one word.
    ///   - joinedToPrevious: for each word, whether it is a piece of a wrapped word that continues the word before it. Such a word never
    ///     shares a line with that word, so the pieces of one word are never set with a gap between them. Empty when no word is a piece.
    static func breaks(wordWidths: [CGFloat], wordCharacters: [Int], spaceWidth: CGFloat, lineWidth: CGFloat,
                       minimumCharacters: Int, maximumCharacters: Int, joinedToPrevious: [Bool] = []) -> [Range<Int>] {
        let count = min(wordWidths.count, wordCharacters.count)
        guard count > 0 else { return [] }
        let width = max(lineWidth, 1)
        func isJoined(_ index: Int) -> Bool { index < joinedToPrevious.count && joinedToPrevious[index] }

        // Cost and line count of the best layout of words `i..<count`; `next[i]` is where its first line ends.
        var cost = [Double](repeating: 0, count: count + 1)
        var lines = [Int](repeating: 0, count: count + 1)
        var next = [Int](repeating: count, count: count + 1)

        for start in stride(from: count - 1, through: 0, by: -1) {
            var wordsWidth: CGFloat = 0
            var characters = 0
            var bestCost = Double.infinity
            var bestLines = Int.max
            var bestEnd = start + 1
            var end = start
            while end < count {
                if end > start, isJoined(end) { break }
                wordsWidth += wordWidths[end]
                characters += wordCharacters[end] + (end > start ? 1 : 0)
                end += 1
                let gaps = CGFloat(end - start - 1)
                let natural = wordsWidth + gaps * spaceWidth
                let isSingle = end - start == 1
                // The line fits when its gaps can shrink to the minimum.
                if !isSingle && (wordsWidth + gaps * spaceWidth * minimumGapFactor > width || characters > maximumCharacters) { break }

                var lineCost: Double
                if end == count {
                    lineCost = isSingle && !(natural > width) && wordCharacters[start] < widowCharacters && count > 1 && start > 0
                        ? widowPenalty : 0
                } else {
                    // A line of two or more words whose gaps stay within the cap is justified; any other line is ragged.
                    var ratio = CGFloat.infinity
                    if !isSingle, spaceWidth > 0 { ratio = (width - wordsWidth) / (gaps * spaceWidth) }
                    if ratio <= maximumGapFactor {
                        let slack = abs(Double((width - natural) / width))
                        let stretch = Double(max(0, ratio - 1))
                        let compress = Double(max(0, 1 - ratio))
                        lineCost = slack * slack + stretchWeight * stretch * stretch * stretch + compressWeight * compress * compress
                    } else {
                        let slack = Double(min(1, max(0, (width - natural) / width)))
                        lineCost = raggedPenalty + raggedWeight * slack * slack
                    }
                    if characters < minimumCharacters {
                        lineCost += shortLinePenalty + Double(minimumCharacters - characters) / Double(max(minimumCharacters, 1))
                    }
                    if isSingle, !isJoined(start + 1), wordFitsWithNext(start, wordWidths, wordCharacters, spaceWidth, width, maximumCharacters) {
                        lineCost += loneWordPenalty
                    }
                }
                let total = lineCost + cost[end]
                let totalLines = 1 + lines[end]
                // Lowest cost, then fewer lines, then the earlier break (the first found, as `end` only grows).
                if total < bestCost - epsilon || (abs(total - bestCost) <= epsilon && totalLines < bestLines) {
                    bestCost = total
                    bestLines = totalLines
                    bestEnd = end
                }
            }
            cost[start] = bestCost
            lines[start] = bestLines
            next[start] = bestEnd
        }

        var result: [Range<Int>] = []
        var start = 0
        while start < count {
            result.append(start..<next[start])
            start = next[start]
        }
        return result
    }

    private static func wordFitsWithNext(_ index: Int, _ widths: [CGFloat], _ characters: [Int], _ space: CGFloat, _ width: CGFloat,
                                         _ maximum: Int) -> Bool {
        guard index + 1 < widths.count else { return false }
        return widths[index] + space * minimumGapFactor + widths[index + 1] <= width && characters[index] + 1 + characters[index + 1] <= maximum
    }

    /// The length, in UTF-16 units, of the piece of a word wider than a line that starts at `start`. `fitting` is the most units that fit, and
    /// ends on a character boundary. The piece ends just after one of the wrap characters instead, when that lies in its last third and
    /// `isBoundary` says the position is a character boundary. The piece is never empty, and `start` is before the end of `units`.
    static func wrapLength(units: [UInt16], start: Int, fitting: Int, isBoundary: (Int) -> Bool) -> Int {
        let rest = units.count - start
        let fits = max(1, fitting)
        guard fits < rest else { return rest }
        let shortest = max(1, (2 * fits + 2) / 3)
        var length = fits
        while length >= shortest {
            if wrapAfter.contains(units[start + length - 1]), isBoundary(start + length) { return length }
            length -= 1
        }
        return fits
    }
}

/// How wide the gaps of one drawn line are, apart from UIKit so it can be tested.
enum JustifiedSpacing {
    /// The gap between the words of a line of `wordCount` words whose words take `wordsWidth` in all, in a line `lineWidth` wide.
    /// A line too long at the natural space shrinks its gaps, to the minimum at most. A justified line stretches them to fill the line,
    /// unless that takes more than the maximum, and then it keeps the natural space (and is drawn from the leading edge). A line that is
    /// not justified keeps the natural space.
    static func gap(wordsWidth: CGFloat, wordCount: Int, spaceWidth: CGFloat, lineWidth: CGFloat, justified: Bool) -> CGFloat {
        guard wordCount > 1 else { return spaceWidth }
        let fill = (lineWidth - wordsWidth) / CGFloat(wordCount - 1)
        if fill < spaceWidth { return max(fill, spaceWidth * JustifiedLineBreaker.minimumGapFactor) }
        guard justified, fill <= spaceWidth * JustifiedLineBreaker.maximumGapFactor else { return spaceWidth }
        return fill
    }

    /// The width of a line of words at the narrowest gaps: the least it can take.
    static func compressedWidth(wordsWidth: CGFloat, wordCount: Int, spaceWidth: CGFloat) -> CGFloat {
        wordsWidth + spaceWidth * JustifiedLineBreaker.minimumGapFactor * CGFloat(max(0, wordCount - 1))
    }
}

/// The sums behind a justified text's size, apart from UIKit so they can be tested. The height SwiftUI is given comes from a layout at
/// the width it proposed; the text is drawn at the width the view ends up with, which can differ by a pixel after SwiftUI snaps the
/// frame. A different width can break into a different number of lines, and a line the height did not count is cut off. So the drawing
/// uses the layout the size was measured with whenever the two widths are that close.
enum JustifiedSizing {
    /// How far the drawn width may differ from the measured one (pixel snapping) before the text is laid out afresh.
    static let widthTolerance: CGFloat = 1.5

    /// The width to lay the text out at when drawing it in `bounds`.
    static func layoutWidth(measured: CGFloat?, bounds: CGFloat) -> CGFloat {
        guard let measured, measured.isFinite, abs(measured - bounds) <= widthTolerance else { return bounds }
        return max(measured, 1)
    }

    /// The lines drawn: all of them, or the limit.
    static func shownLines(total: Int, lineLimit: Int) -> Int {
        lineLimit > 0 ? min(lineLimit, total) : total
    }

    /// The height of the text: whole lines, and with `reservesSpace` at least the limit.
    static func height(totalLines: Int, lineLimit: Int, reservesSpace: Bool, lineHeight: CGFloat) -> CGFloat {
        let shown = shownLines(total: totalLines, lineLimit: lineLimit)
        let lines = reservesSpace && lineLimit > 0 ? max(shown, lineLimit) : shown
        return ceil(CGFloat(lines) * lineHeight)
    }
}

/// Finds the link a tap is meant for. A link drawn in body text is one line tall, far smaller than a fingertip, so a tap also counts
/// when it lands near a link: each link's frame is grown to at least `minimumTarget` points each way (and by `slop` at least), and the
/// nearest link whose grown frame holds the tap wins. A tap inside a link's own frame always wins.
enum JustifiedLinkHit {
    /// The smallest touch target, as the system's own controls have.
    static let minimumTarget: CGFloat = 44
    /// How far past a link's own frame a tap still counts, when the frame is already as large as `minimumTarget` that way.
    static let slop: CGFloat = 8

    /// The index of the frame in `frames` the tap at `point` is meant for, or nil when it is near none of them.
    static func index(at point: CGPoint, frames: [CGRect]) -> Int? {
        if let inside = frames.firstIndex(where: { !$0.isEmpty && $0.contains(point) }) { return inside }
        var best: (index: Int, distance: CGFloat)?
        for (index, frame) in frames.enumerated() where !frame.isEmpty {
            let grown = frame.insetBy(dx: -max(slop, (minimumTarget - frame.width) / 2), dy: -max(slop, (minimumTarget - frame.height) / 2))
            guard grown.contains(point) else { continue }
            let distance = squaredDistance(from: point, to: frame)
            // Frames are read in order and only a strictly nearer one replaces the best, so a tie goes to the lower index.
            if let best, best.distance <= distance { continue }
            best = (index, distance)
        }
        return best?.index
    }

    /// The squared distance from `point` to `frame`, zero when the point is inside it.
    private static func squaredDistance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return dx * dx + dy * dy
    }
}
