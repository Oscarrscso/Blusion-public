import CoreGraphics
import Testing
@testable import Features

@Suite struct JustifiedLineBreakerTests {
    /// Words of a sample text, each letter 10 wide and a space 10 wide.
    private struct Sample {
        let widths: [CGFloat]
        let characters: [Int]
        init(_ text: String) {
            let words = text.split(separator: " ").map(String.init)
            characters = words.map(\.count)
            widths = words.map { CGFloat($0.count) * 10 }
        }
    }

    private func breaks(_ sample: Sample, width: CGFloat, minimum: Int = JustifiedLineBreaker.defaultMinimumCharacters,
                        maximum: Int = JustifiedLineBreaker.defaultMaximumCharacters, joined: [Bool] = []) -> [Range<Int>] {
        JustifiedLineBreaker.breaks(wordWidths: sample.widths, wordCharacters: sample.characters, spaceWidth: 10, lineWidth: width,
                                    minimumCharacters: minimum, maximumCharacters: maximum, joinedToPrevious: joined)
    }

    private func natural(_ range: Range<Int>, _ sample: Sample) -> CGFloat {
        range.reduce(0) { $0 + sample.widths[$1] } + CGFloat(range.count - 1) * 10
    }

    /// The characters of a line of words, the spaces between them included.
    private func lineCharacters(_ range: Range<Int>, _ sample: Sample) -> Int {
        range.reduce(0) { $0 + sample.characters[$1] } + range.count - 1
    }

    /// The widest gap, in natural spaces, that the multi-word lines but the last are drawn with. A ragged line keeps its natural spaces.
    private func worstGap(_ lines: [Range<Int>], _ sample: Sample, width: CGFloat) -> CGFloat {
        lines.dropLast().filter { $0.count > 1 }.map { line in
            JustifiedSpacing.gap(wordsWidth: line.reduce(0) { $0 + sample.widths[$1] }, wordCount: line.count, spaceWidth: 10,
                                 lineWidth: width, justified: true) / 10
        }.max() ?? 0
    }

    /// The least a line can take, its gaps at the minimum.
    private func compressed(_ range: Range<Int>, _ sample: Sample) -> CGFloat {
        range.reduce(0) { $0 + sample.widths[$1] } + CGFloat(range.count - 1) * 10 * JustifiedLineBreaker.minimumGapFactor
    }

    /// The largest slack ratio over the lines but the last.
    private func worstSlack(_ lines: [Range<Int>], _ sample: Sample, width: CGFloat) -> CGFloat {
        lines.dropLast().map { (width - natural($0, sample)) / width }.max() ?? 0
    }

    /// The line a greedy fill takes from `start`: as many words as fit at natural spaces.
    private func greedyLine(from start: Int, _ sample: Sample, width: CGFloat) -> Range<Int> {
        var end = start + 1
        while end < sample.widths.count, natural(start..<(end + 1), sample) <= width { end += 1 }
        return start..<end
    }

    /// Greedy filling, for comparison.
    private func greedy(_ sample: Sample, width: CGFloat) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        while start < sample.widths.count {
            let line = greedyLine(from: start, sample, width: width)
            result.append(line)
            start = line.upperBound
        }
        return result
    }

    /// Ordinary prose, one paragraph each. The first starts with a short word, the kind that used to stand alone on a line.
    private let prose = [
        "A promising young director takes a bold step with this film, trading the familiar comforts of the genre for a slower and more thoughtful rhythm.",
        "The performances are uniformly strong, with a lead who carries the quieter scenes and a supporting cast that never overplays its hand.",
        "Some viewers will find the pacing uneven, but the final act pays off every earlier hesitation with a sequence of real emotional force.",
        "It is not a perfect film, yet it lingers long after the credits roll, which is more than most of its competitors manage this year.",
        "A quiet, patient story about a family that keeps its secrets until the very last scene, when a single letter changes everything they believed.",
    ]

    /// Every width from narrow to very wide that the prose is laid out at.
    private let widths = Array(stride(from: CGFloat(200), through: 3000, by: 5))

    /// How many characters a line may fall short of the greedy fill from the same word. About a word and its gap: the longest word of the
    /// prose with its space is 13 characters, and the breaker is at most 14 short on this prose when it ends a line a word early so that the
    /// next line is not loose.
    private let greedyTolerance = 15

    private let paragraph = "The quick brown fox jumps over the lazy dog while a small bird watches from the old oak tree nearby"

    @Test func everyWordAppearsOnceAndInOrder() {
        let sample = Sample(paragraph)
        let lines = breaks(sample, width: 300)
        #expect(lines.first?.lowerBound == 0)
        #expect(lines.last?.upperBound == sample.widths.count)
        for pair in zip(lines, lines.dropFirst()) { #expect(pair.0.upperBound == pair.1.lowerBound) }
        #expect(lines.allSatisfy { !$0.isEmpty })
    }

    @Test func noLineIsWiderThanTheWidthOrTheMaximumUnlessOneWord() {
        let sample = Sample(paragraph + " supercalifragilisticexpialidocious and more")
        for line in breaks(sample, width: 200, maximum: 20) {
            guard line.count > 1 else { continue }
            #expect(compressed(line, sample) <= 200)
            let characters = line.reduce(0) { $0 + sample.characters[$1] } + line.count - 1
            #expect(characters <= 20)
        }
    }

    @Test func aWordWiderThanTheLineTakesALineOfItsOwn() {
        let sample = Sample("a supercalifragilisticexpialidocious b")
        let lines = breaks(sample, width: 150)
        #expect(lines.contains(1..<2))
    }

    @Test func aLooseGreedyLineBeforeALongWordIsBalanced() {
        let sample = Sample("It was a good one. Incredible movie. So extraordinarilylongword here and then the rest of the story goes on and on")
        let width: CGFloat = 300
        let balanced = breaks(sample, width: width)
        #expect(worstGap(balanced, sample, width: width) < worstGap(greedy(sample, width: width), sample, width: width))
    }

    @Test func balancingNeverMakesTheWorstLineLooserThanGreedyOnOrdinaryText() {
        let sample = Sample(paragraph + " " + paragraph)
        for width in stride(from: CGFloat(260), through: 400, by: 20) {
            let lines = breaks(sample, width: width)
            #expect(worstGap(lines, sample, width: width) <= worstGap(greedy(sample, width: width), sample, width: width) + 1e-9)
        }
    }

    @Test func minimumCharactersAreRespectedWhenFeasible() {
        let sample = Sample(paragraph)
        let lines = breaks(sample, width: 300, minimum: 20)
        for line in lines.dropLast() {
            let characters = line.reduce(0) { $0 + sample.characters[$1] } + line.count - 1
            #expect(characters >= 20)
        }
    }

    @Test func aWidowIsPulledDownWhenPossible() {
        // Greedy leaves "go." alone on the last line at this width.
        let sample = Sample("one two three four five six seven go.")
        let lines = breaks(sample, width: 300)
        #expect((lines.last?.count ?? 0) > 1)
    }

    @Test func emptyAndSingleWordInput() {
        #expect(breaks(Sample(""), width: 100).isEmpty)
        #expect(breaks(Sample("word"), width: 100) == [0..<1])
        #expect(breaks(Sample("wordwordwordwordword"), width: 50) == [0..<1])
    }

    @Test func aLineTakesAnotherWordByCompressingItsGaps() {
        // "aaaa bbbb cccc" is 140 wide at natural gaps and 135 with gaps at 0.75, so it fits a 135 line only compressed.
        let sample = Sample("aaaa bbbb cccc dddd")
        let lines = breaks(sample, width: 135, minimum: 1)
        #expect(lines.first == 0..<3)
        #expect(compressed(0..<3, sample) <= 135)
    }

    @Test func noLineNeedsMoreCompressionThanTheMinimum() {
        let sample = Sample(paragraph + " " + paragraph)
        for width in stride(from: CGFloat(200), through: 400, by: 17) {
            for line in breaks(sample, width: width) where line.count > 1 {
                #expect(compressed(line, sample) <= width + 1e-9)
            }
        }
    }

    @Test func gapsAreStretchedUpToTheCapThenLeftNatural() {
        let space: CGFloat = 10
        // Five words of 20: sum 100 in a 140 line leaves 10 per gap (natural); 160 leaves 15 (stretched); 400 leaves 75 (over the cap).
        #expect(JustifiedSpacing.gap(wordsWidth: 100, wordCount: 5, spaceWidth: space, lineWidth: 160, justified: true) == 15)
        #expect(JustifiedSpacing.gap(wordsWidth: 100, wordCount: 5, spaceWidth: space, lineWidth: 400, justified: true) == space)
        #expect(JustifiedSpacing.gap(wordsWidth: 100, wordCount: 5, spaceWidth: space, lineWidth: 160, justified: false) == space)
        #expect(JustifiedSpacing.gap(wordsWidth: 100, wordCount: 5, spaceWidth: space, lineWidth: 100 + 4 * 19, justified: true) == 19)
    }

    @Test func gapsShrinkToTheMinimumAndNoFurther() {
        let space: CGFloat = 10
        #expect(JustifiedSpacing.gap(wordsWidth: 100, wordCount: 5, spaceWidth: space, lineWidth: 132, justified: true) == 8)
        #expect(JustifiedSpacing.gap(wordsWidth: 100, wordCount: 5, spaceWidth: space, lineWidth: 100, justified: false) == 7.5)
        #expect(JustifiedSpacing.gap(wordsWidth: 100, wordCount: 1, spaceWidth: space, lineWidth: 50, justified: true) == space)
    }

    @Test func aWordWiderThanTheLineStaysOnALineAloneWhateverItsNeighbours() {
        let sample = Sample("see https://example.com/a/very/long/path/that/never/ends now")
        let lines = breaks(sample, width: 200)
        #expect(lines.contains(1..<2))
    }

    @Test func ordinaryProseHasNoStrandedWordAndFillsLikeGreedyAtEveryWidth() {
        for text in prose {
            let sample = Sample(text)
            for width in widths {
                for line in breaks(sample, width: width).dropLast() {
                    if line.count == 1 {
                        let fits = sample.widths[line.lowerBound] + 10 + sample.widths[line.upperBound] <= width
                        #expect(!fits, "a lone word at width \(width)")
                    }
                    let greedyFill = greedyLine(from: line.lowerBound, sample, width: width)
                    #expect(lineCharacters(line, sample) + greedyTolerance >= lineCharacters(greedyFill, sample), "a line short of greedy at width \(width)")
                }
            }
        }
    }

    @Test func aWideContainerFillsItsLinesWithoutACharacterCap() {
        let sample = Sample(Array(repeating: prose[0], count: 3).joined(separator: " "))
        let lines = breaks(sample, width: 2000)
        #expect(lines.count > 1)
        for line in lines.dropLast() {
            #expect(lineCharacters(line, sample) > 90)
        }
    }

    @Test func aSmallCharacterMaximumInAVeryWideContainerStillHoldsSeveralWords() {
        for text in prose {
            for line in breaks(Sample(text), width: 3000, maximum: 30).dropLast() {
                #expect(line.count >= 2)
            }
        }
    }

    @Test func aWiderLineNeverAddsLines() {
        for text in prose {
            let sample = Sample(text)
            var previous = Int.max
            for width in widths {
                let count = breaks(sample, width: width).count
                #expect(count <= previous, "more lines at width \(width)")
                previous = count
            }
        }
    }

    @Test func piecesOfOneWordNeverShareALine() {
        // "bb" and "cc" are pieces of one word. All four words would fit one line, so only the joins keep the pieces apart.
        let sample = Sample("aa bb cc dd")
        #expect(breaks(sample, width: 1000) == [0..<4])
        let lines = breaks(sample, width: 1000, joined: [false, false, true, false])
        #expect(lines.allSatisfy { !($0.contains(1) && $0.contains(2)) })
    }

    @Test func aWrappedWordEndsAfterAWrapCharacterNearItsEnd() {
        let url = Array("https://example.com/a/very/long/path".utf16)
        // Of the 18 units that fit, the last third holds the "." at unit 15, so the piece ends after it.
        #expect(JustifiedLineBreaker.wrapLength(units: url, start: 0, fitting: 18) { _ in true } == 16)
        // A wrap character in the first two thirds of the piece is ignored.
        #expect(JustifiedLineBreaker.wrapLength(units: Array("abcd/efghijklmnop".utf16), start: 0, fitting: 12) { _ in true } == 12)
    }

    @Test func aWrapCharacterIsIgnoredAtAPositionThatIsNotACharacterBoundary() {
        let text = Array("abcd/efgh.ijkl".utf16)
        #expect(JustifiedLineBreaker.wrapLength(units: text, start: 0, fitting: 12) { _ in true } == 10)
        #expect(JustifiedLineBreaker.wrapLength(units: text, start: 0, fitting: 12) { $0 != 10 } == 12)
    }

    @Test func aWrappedPieceNeverRunsPastTheWordAndIsNeverEmpty() {
        let text = Array("abc".utf16)
        #expect(JustifiedLineBreaker.wrapLength(units: text, start: 0, fitting: 10) { _ in true } == 3)
        #expect(JustifiedLineBreaker.wrapLength(units: text, start: 1, fitting: 1) { _ in true } == 1)
        #expect(JustifiedLineBreaker.wrapLength(units: text, start: 0, fitting: 0) { _ in true } == 1)
    }
}
