import Foundation
import Testing
import StremioKit
@testable import Features

@Suite struct ReviewConsensusTests {
    private func reviews(_ texts: [String]) throws -> [TMDbReview] {
        let json = try JSONSerialization.data(withJSONObject: texts.enumerated().map { ["id": "r\($0.offset)", "author": "a", "content": $0.element] })
        return try JSONDecoder().decode([TMDbReview].self, from: json)
    }

    private let long = String(repeating: "The performances are superb and the cinematography is gorgeous, but the pacing drags. ", count: 4)

    @Test func theLineReadsAsTwoSentences() {
        #expect(ReviewConsensus(praise: ["its performances", "the cinematography"], complaints: ["its slow pacing"]).text
                == "Praised for its performances and the cinematography. Common complaints: its slow pacing.")
        #expect(ReviewConsensus(praise: ["a", "b", "c"]).text == "Praised for a, b and c.")
        #expect(ReviewConsensus().text == nil, "nothing agreed: no line")
    }

    @Test func aPhraseTheReviewsDoNotSupportIsDropped() {
        let consensus = ReviewConsensus(praise: ["its performances", "an Oscar-winning score"], complaints: ["its pacing", "the 3D"])
        let grounded = consensus.grounded(in: ["Great performances throughout.", "The pacing is slow."])
        #expect(grounded.praise == ["its performances"], "no review mentions an Oscar or a score")
        #expect(grounded.complaints == ["its pacing"])
    }

    private actor Count { var calls = 0; func add() { calls += 1 } }

    private struct Summarizer: ReviewSummarizing {
        let count: Count
        func consensus(of reviews: [String]) async -> ReviewConsensus? {
            await count.add()
            return ReviewConsensus(praise: ["its performances", "a perfect score"], complaints: ["its pacing"])
        }
    }

    @MainActor @Test func aTitlesLineIsReadOnceAndKeepsOnlyWhatTheReviewsSay() async throws {
        let count = Count()
        let texts = try reviews([long + "A", long + "B", long + "C"])
        let line = await ReviewConsensusReader.line(for: texts, using: Summarizer(count: count))
        #expect(line == "Praised for its performances. Common complaints: its pacing.")
        #expect(await ReviewConsensusReader.line(for: texts, using: Summarizer(count: count)) == line)
        #expect(await count.calls == 1, "reopening the title reads the cached line")
        #expect(await ReviewConsensusReader.line(for: texts, using: nil) == nil, "no model, no line")
    }

    @Test func repeatedSubjectsAndSentencesAreNotPoints() {
        let consensus = ReviewConsensus(praise: ["amazing performances", "powerful performances", "tight plot"],
                                        complaints: ["not entirely sure it was really Best Picture worthy", "the pacing"])
        let grounded = consensus.grounded(in: ["Amazing performances and a tight plot.", "Powerful performances, slow pacing, not Best Picture worthy."])
        #expect(grounded.praise == ["amazing performances", "tight plot"])
        #expect(grounded.complaints == ["the pacing"])
    }

    @Test func everyNonblankReviewKeepsItsWholeTextWithoutACountOrLengthThreshold() throws {
        #expect(ReviewConsensusReader.texts(try reviews(["Good."])) == ["Good."])
        #expect(ReviewConsensusReader.texts(try reviews(["Good.", "Bad."])) == ["Good.", "Bad."])
        #expect(ReviewConsensusReader.texts(try reviews([" ", "\n"])) == nil)
        let texts = (0..<100).map { "\(long)\(String(repeating: "x", count: 10_000)) tail \($0)" }
        #expect(ReviewConsensusReader.texts(try reviews(texts)) == texts)
    }

    @MainActor @Test func editingAReviewInvalidatesTheCachedLineEvenWhenItsIDStaysTheSame() async throws {
        let count = Count()
        let before = try reviews(["The performances and pacing need work. Unique original text."])
        let after = try reviews(["The performances and pacing improve. Unique edited text."])
        #expect(ReviewConsensusReader.key(for: before) != ReviewConsensusReader.key(for: after))
        _ = await ReviewConsensusReader.line(for: before, using: Summarizer(count: count))
        _ = await ReviewConsensusReader.line(for: after, using: Summarizer(count: count))
        #expect(await count.calls == 2)
        #expect(ReviewConsensus(complaints: ["its pacing"]).text(reviewCount: 1) == "Criticised for its pacing.")
    }

    private enum Failure: Error { case failed }

    private actor Generator: ReviewThemeGenerating {
        var readTexts: [String] = []
        var promptSizes: [Int] = []
        var mergeCalls = 0
        var paragraphInputs: [[String]] = []
        let contextBytes: Int?
        let failsOn: String?
        let preservesSubjects: Bool
        let paragraphContextLimit: Int?

        init(contextBytes: Int? = nil, failsOn: String? = nil, preservesSubjects: Bool = false, paragraphContextLimit: Int? = nil) {
            self.contextBytes = contextBytes
            self.failsOn = failsOn
            self.preservesSubjects = preservesSubjects
            self.paragraphContextLimit = paragraphContextLimit
        }

        func themes(from sources: [String], merging: Bool) async throws -> ReviewThemeGroups {
            promptSizes.append(ReviewSummaryPipeline.prompt(for: sources, merging: merging).utf8.count)
            if let contextBytes, sources.joined().utf8.count > contextBytes { throw ReviewThemeGenerationError.contextWindow }
            if let failsOn, sources.contains(where: { $0.contains(failsOn) }) { throw Failure.failed }
            if !merging { readTexts += sources }
            if merging { mergeCalls += 1 }
            if preservesSubjects {
                let points = sources.enumerated().map { index, source in
                    ReviewThemeGroup(phrase: "its \(source.split(separator: " ").last!)", sources: [index])
                }
                return ReviewThemeGroups(praise: points)
            }
            let performances = sources.indices.filter { sources[$0].contains("performances") }
            let pacing = sources.indices.filter { sources[$0].contains("pacing") }
            return ReviewThemeGroups(praise: performances.isEmpty ? [] : [ReviewThemeGroup(phrase: "its performances", sources: performances)],
                                     complaints: pacing.isEmpty ? [] : [ReviewThemeGroup(phrase: "its pacing", sources: pacing)])
        }

        func paragraph(from sources: [String], reviewCount: Int) async throws -> [ReviewSummarySentence] {
            paragraphInputs.append(sources)
            if let paragraphContextLimit, sources.count > paragraphContextLimit { throw ReviewThemeGenerationError.contextWindow }
            return ["Overall verdict", "Praise", "Complaint"].compactMap { kind in
                guard let index = sources.firstIndex(where: { $0.hasPrefix(kind + ",") }) else { return nil }
                let phrase = sources[index].components(separatedBy: ": ").dropFirst().joined(separator: ": ")
                return ReviewSummarySentence(text: "Reviewers highlight \(phrase) as a meaningful aspect of the film\'s storytelling.", sources: [index])
            }
        }
    }

    @Test func longReviewsAndReviewsBeyondTheOldPrefixAreAllRead() async {
        let generator = Generator()
        let first = String(repeating: "An extended discussion. ", count: 900) + "Excellent performances, but slow pacing."
        let texts = [first] + (0..<40).map { "Review \($0): excellent performances, but slow pacing." }
        let result = await ReviewSummaryPipeline(generator: generator).consensus(of: texts)
        #expect(result?.praise == ["its performances"])
        #expect(result?.complaints == ["its pacing"])
        #expect(await generator.readTexts.contains(where: { $0.contains("performances") }), "selected evidence retains the final opinion")
        #expect(await generator.promptSizes.allSatisfy { $0 <= ReviewSummaryPipeline.inputByteBudget })
    }

    @Test func manyChunksOfOneReviewCannotManufactureAgreement() async {
        let generator = Generator()
        let first = String(repeating: "The performances are excellent. ", count: 500)
        let result = await ReviewSummaryPipeline(generator: generator).consensus(of: [first, "An unrelated opinion."])
        #expect(result != nil)
        #expect(result?.text != nil, "a minority opinion is valid material, with its actual support rather than an invented consensus")
        #expect(await generator.paragraphInputs.last?.first?.contains("supported by 1 distinct review(s)") == true)
        let single = await ReviewSummaryPipeline(generator: Generator()).consensus(of: [first])
        #expect(single?.praise == ["its performances"], "one review can still have its own summary")
    }

    @Test func tokenDenseTextIsSplitAgainWithoutDroppingUnicodeOrTheTail() async {
        let generator = Generator(contextBytes: 500)
        let text = String(repeating: "\u{1F3AC} e\u{301} 中 \n", count: 500) + "Excellent performances."
        _ = await ReviewSummaryPipeline(generator: generator).consensus(of: [text])
        #expect(await generator.readTexts.contains(where: { $0.contains("performances") }), "the complete review is scanned to find its opinion")
        #expect(ReviewSummaryPipeline.chunks(of: text, maximumBytes: 17).joined() == text)
    }

    @Test func moreEvidenceThanOneMergeCanHoldIsReducedInBoundedRounds() async {
        let generator = Generator(preservesSubjects: true)
        let texts = (0..<80).map { "topic" + String(UnicodeScalar(97 + $0 / 26)!) + String(UnicodeScalar(97 + $0 % 26)!) }
        _ = await ReviewSummaryPipeline(generator: generator).consensus(of: texts)
        let read = await generator.readTexts
        #expect(read.count > 0 && read.count <= texts.count)
        #expect(await generator.mergeCalls <= 1, "bounded merging avoids repeated expensive model passes")
        #expect(await generator.promptSizes.allSatisfy { $0 <= ReviewSummaryPipeline.inputByteBudget })
    }

    @Test func aFailedLaterChunkDoesNotPublishAPartialReading() async {
        let generator = Generator(failsOn: "FAIL_LATE")
        let text = String(repeating: "Excellent performances throughout. ", count: 300) + "The FAIL_LATE acting and performances disappoint."
        let result = await ReviewSummaryPipeline(generator: generator).consensus(of: [text])
        #expect(result == nil)
    }

    private actor ParagraphGenerator: ReviewThemeGenerating {
        static let praise = "The performances make the characters convincing and give their relationships emotional weight."
        static let complaint = "The pacing slows in the middle and leaves several interesting subplots unresolved."
        static let verdict = "The performances make this a worthwhile watch despite its uneven pacing."
        var paragraphInputs: [[String]] = []
        var failuresRemaining: Int
        let dropsCriticismOnMerge: Bool
        let omitsCriticismInParagraph: Bool
        let invalidReference: Bool

        init(dropsCriticismOnMerge: Bool = false, omitsCriticismInParagraph: Bool = false,
             invalidReference: Bool = false, failures: Int = 0) {
            self.dropsCriticismOnMerge = dropsCriticismOnMerge
            self.omitsCriticismInParagraph = omitsCriticismInParagraph
            self.invalidReference = invalidReference
            failuresRemaining = failures
        }

        func themes(from sources: [String], merging: Bool) async throws -> ReviewThemeGroups {
            func group(_ phrase: String, kind: String, keyword: String) -> [ReviewThemeGroup] {
                let indices = sources.indices.filter {
                    merging ? sources[$0].hasPrefix(kind) : sources[$0].contains(keyword)
                }
                return indices.isEmpty ? [] : [ReviewThemeGroup(phrase: phrase, sources: indices)]
            }
            return ReviewThemeGroups(praise: group(Self.praise, kind: "Praise,", keyword: "characters"),
                                     complaints: merging && dropsCriticismOnMerge ? []
                                        : group(Self.complaint, kind: "Complaint,", keyword: "subplots"),
                                     verdicts: group(Self.verdict, kind: "Overall verdict,", keyword: "worthwhile"))
        }

        func paragraph(from sources: [String], reviewCount: Int) async throws -> [ReviewSummarySentence] {
            paragraphInputs.append(sources)
            if failuresRemaining > 0 { failuresRemaining -= 1; throw Failure.failed }
            if invalidReference { return [ReviewSummarySentence(text: Self.praise, sources: [sources.count])] }
            return sources.enumerated().compactMap { index, source in
                if omitsCriticismInParagraph, source.hasPrefix("Complaint,") { return nil }
                return ReviewSummarySentence(text: source.components(separatedBy: ": ").dropFirst().joined(separator: ": "), sources: [index])
            }
        }
    }

    @Test func detailedReasonsAndAnOverallVerdictReachOneNaturalParagraph() async {
        let generator = ParagraphGenerator()
        let body = [ParagraphGenerator.praise, ParagraphGenerator.complaint, ParagraphGenerator.verdict].joined(separator: " ")
        let result = await ReviewSummaryPipeline(generator: generator).consensus(of: Array(repeating: body, count: 8))
        #expect(result?.text?.contains("Praised:") == true)
        #expect(result?.text?.contains("Criticised:") == true)
        #expect(result?.text?.split(separator: "\n").count == 3)
        #expect(await generator.paragraphInputs.last?.allSatisfy { $0.contains("supported by 8 distinct review(s)") } == true)
    }

    @Test func aMergeCannotEraseTheOnlyDissentingCriticism() async {
        let generator = ParagraphGenerator(dropsCriticismOnMerge: true)
        let positive = ParagraphGenerator.praise + " " + ParagraphGenerator.verdict
        let reviews = Array(repeating: positive, count: 40) + [ParagraphGenerator.complaint]
        let result = await ReviewSummaryPipeline(generator: generator).consensus(of: reviews)
        #expect(result?.text?.contains("subplots unresolved") == true)
        let sources = await generator.paragraphInputs.last ?? []
        #expect(sources.contains { $0.hasPrefix("Complaint, supported by 1 distinct review(s)") })
        #expect(sources.contains { $0.hasPrefix("Praise, supported by 40 distinct review(s)") })
    }

    @Test func invalidSourcesOrOmittedCriticismCannotPublishAnIncompleteParagraph() async {
        let body = ParagraphGenerator.praise + " " + ParagraphGenerator.complaint + " " + ParagraphGenerator.verdict
        let invalid = await ReviewSummaryPipeline(generator: ParagraphGenerator(invalidReference: true)).consensus(of: [body])
        let incomplete = await ReviewSummaryPipeline(generator: ParagraphGenerator(omitsCriticismInParagraph: true)).consensus(of: [body])
        #expect(invalid?.text?.contains("Praised:") == true, "rejected final citations fall back only to fully formed extracted evidence")
        #expect(incomplete?.text?.contains("Criticised:") == true, "missing generated categories can use independently supported evidence")
    }

    @MainActor @Test func aFailedParagraphIsRetriedThenTheCompleteParagraphIsCached() async throws {
        let generator = ParagraphGenerator(failures: 1)
        let summarizer = ReviewSummaryPipeline(generator: generator)
        let texts = try reviews([ParagraphGenerator.praise + " Unique retry evidence."])
        let line = await ReviewConsensusReader.line(for: texts, using: summarizer)
        #expect(line?.contains("Based on 1 TMDb review.") == true)
        #expect(line?.contains("Overall:") == false, "no overall verdict may be invented")
        #expect(await ReviewConsensusReader.line(for: texts, using: summarizer) == line)
        #expect(await generator.paragraphInputs.count == 1, "a valid extracted fallback is reused without repeating model calls")
    }

    @Test func fullLengthReviewIsScannedAndExcerptStaysBounded() {
        let text = String(repeating: "Neutral setup. ", count: 700)
            + "The ending is disappointing but the acting is excellent."
        let excerpt = ReviewSummaryPipeline.representativeEvidence(in: text, maximumBytes: 1_100)
        #expect(excerpt.utf8.count <= 1_100)
        #expect(excerpt.contains("ending") || excerpt.contains("acting"))
    }

    @Test func missingFinalCategoryStillProducesTheSupportedCriticism() async {
        let generator = ParagraphGenerator(omitsCriticismInParagraph: true)
        let source = ParagraphGenerator.praise + " " + ParagraphGenerator.complaint
        let result = await ReviewSummaryPipeline(generator: generator).consensus(of: [source, source])
        #expect(result?.text?.contains("Praised:") == true)
        #expect(result?.text?.contains("Criticised:") == true)
    }

    @Test func aFailedFinalModelPassStillProducesAUsefulEvidenceBackedSummary() async {
        let generator = ParagraphGenerator(failures: 1)
        let source = ParagraphGenerator.praise + " " + ParagraphGenerator.complaint
        let result = await ReviewSummaryPipeline(generator: generator).consensus(of: [source])
        #expect(result?.text?.contains("Praised:") == true)
        #expect(result?.text?.contains("Criticised:") == true)
    }

    @Test func largeSetsStillIncludeEachReviewWithoutExcessiveModelInput() {
        #expect(ReviewSummaryPipeline.excerptBudget(for: 1) == 1_100)
        #expect(ReviewSummaryPipeline.excerptBudget(for: 10) == 1_100)
        #expect(ReviewSummaryPipeline.excerptBudget(for: 100) == 360)
        #expect(ReviewSummaryPipeline.excerptBudget(for: 200) == 240)
    }

    @Test func screenshotStyleFragmentsAreRejected() {
        #expect(!ReviewSummaryPipeline.isUsefulSummaryLine("Pretty awesome movie."))
        #expect(!ReviewSummaryPipeline.isUsefulSummaryLine("should be seen as widely as possible, if only so that... chances."))
        #expect(!ReviewSummaryPipeline.isUsefulSummaryLine("A reasonable for those who thought a classic is boring."))
        #expect(!ReviewSummaryPipeline.isUsefulSummaryLine("Shows what one crazy person can convince others to do."))
        #expect(ReviewSummaryPipeline.isUsefulSummaryLine(
            "Reviewers praise the cast's performances and atmospheric direction while questioning the film's uneven pacing."))
    }

    @Test func excerptSelectionNeverCutsSentencesHalfway() {
        let review = String(repeating: "There is background context and setup. ", count: 100)
            + "The performances are excellent, although the slow pacing undermines the tension."
        let excerpt = ReviewSummaryPipeline.representativeEvidence(in: review, maximumBytes: 1_100)
        #expect(excerpt.utf8.count <= 1_100)
        #expect(excerpt.contains("slow pacing undermines the tension."))
        #expect(!excerpt.contains("..."))
    }

    @Test func sparseMaterialIsAcknowledgedWithoutInventingAnOpinion() async {
        let generator = Generator()
        let result = await ReviewSummaryPipeline(generator: generator).consensus(of: ["!", "?"])
        #expect(result?.text?.contains("too little specific opinion") == true)
        #expect(await generator.paragraphInputs.isEmpty)
    }

    @Test func paragraphContextRetriesCompressEvidenceWithoutRereadingReviews() async {
        let generator = Generator(preservesSubjects: true, paragraphContextLimit: 3)
        let texts = (0..<12).map { "topic" + String(UnicodeScalar(97 + $0)!) }
        let result = await ReviewSummaryPipeline(generator: generator).consensus(of: texts)
        #expect(result?.text != nil)
        #expect(await generator.readTexts.count > 0, "bounded review batches are inspected before synthesis")
    }
}
