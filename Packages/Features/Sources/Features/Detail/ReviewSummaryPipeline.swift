import Foundation

/// A model pass names a point and the numbered sources that support it. Review counts are computed in Swift, never by the model.
struct ReviewThemeGroup: Sendable {
    var phrase: String
    var sources: [Int]
}

struct ReviewThemeGroups: Sendable {
    var praise: [ReviewThemeGroup] = []
    var complaints: [ReviewThemeGroup] = []
    var verdicts: [ReviewThemeGroup] = []
}

struct ReviewSummarySentence: Sendable {
    var text: String
    var sources: [Int]
}

enum ReviewThemeGenerationError: Error {
    case contextWindow
    case unsupportedParagraph
}

protocol ReviewThemeGenerating: Sendable {
    func themes(from sources: [String], merging: Bool) async throws -> ReviewThemeGroups
    func paragraph(from sources: [String], reviewCount: Int) async throws -> [ReviewSummarySentence]
    var cachesEvidence: Bool { get }
}

extension ReviewThemeGenerating {
    var cachesEvidence: Bool { false }
}

/// Reads every part of every review in bounded passes, then merges their evidence in a tree of bounded passes. Only the size of an
/// individual model request is limited. A review may span any number of requests, and contributes at most one vote to a shared point.
struct ReviewSummaryPipeline: ReviewSummarizing {
    let generator: any ReviewThemeGenerating
    static let inputByteBudget = 6_000
    static let sourcesPerBatch = 12
    static let chunkByteBudget = 4_800
    static let maximumAnalysisDuration: Duration = .seconds(150)
    static let reviewExcerptBudget = 1_100
    private static let totalEvidenceByteBudget = 36_000

    /// Large sets still contribute evidence from every review, without growing model work linearly without bound.
    static func excerptBudget(for reviewCount: Int) -> Int {
        min(reviewExcerptBudget, max(240, totalEvidenceByteBudget / max(1, reviewCount)))
    }
    private static let evidenceCache = ReviewEvidenceCache.shared

    private enum Kind: String, CaseIterable, Sendable, Hashable {
        case praise = "Praise"
        case complaint = "Complaint"
        case verdict = "Overall verdict"
    }

    private struct Source: Sendable {
        var text: String
        var reviews: Set<Int>
        /// Nil for an original excerpt; a merged statement can only cite evidence of its own kind.
        var kind: Kind?
    }

    private struct Theme: Sendable {
        var phrase: String
        var kind: Kind
        var reviews: Set<Int>

        var source: Source {
            Source(text: "\(kind.rawValue), supported by \(reviews.count) distinct review(s): \(phrase)", reviews: reviews, kind: kind)
        }
    }

    func consensus(of reviews: [String]) async -> ReviewConsensus? {
        await consensus(of: reviews, progress: { _, _ in })
    }

    /// Inspect all of every review locally, selecting opinion-bearing excerpts from across its length. This reduces
    /// on-device generations without limiting review count or silently throwing away later reviews.
    func consensus(of reviews: [String], progress: @escaping @Sendable (Int, Int) -> Void) async -> ReviewConsensus? {
        guard !reviews.isEmpty else { return nil }
        do {
            let deadline = ContinuousClock.now.advanced(by: Self.maximumAnalysisDuration)
            var themes: [Theme] = []
            var pending: [Source] = []
            for (review, text) in reviews.enumerated() {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { return nil }
                let excerpt = Self.representativeEvidence(in: text, maximumBytes: Self.excerptBudget(for: reviews.count))
                for chunk in Self.chunks(of: excerpt, maximumBytes: Self.chunkByteBudget) {
                    try Task.checkCancellation()
                    let source = Source(text: chunk, reviews: [review], kind: nil)
                    if !pending.isEmpty, !Self.fits(pending.map(\.text) + [chunk], merging: false) {
                        themes += try await read(pending, merging: false)
                        pending.removeAll(keepingCapacity: true)
                    }
                    pending.append(source)
                }
                if (review + 1) % 5 == 0 || review + 1 == reviews.count {
                    progress(review + 1, reviews.count)
                }
            }
            guard ContinuousClock.now < deadline else { return nil }
            if !pending.isEmpty { themes += try await read(pending, merging: false) }
            guard ContinuousClock.now < deadline else { return nil }
            // The first pass has already identified the review-level opinions.
            // A second "merge" generation previously rewrote or erased evidence, adding latency and
            // sometimes returning unusable source indices. Select a bounded, diverse set locally instead.
            themes = Self.compact(themes)
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { return nil }
            var result = ReviewConsensus(praise: themes.filter { $0.kind == .praise }.map(\.phrase),
                                         complaints: themes.filter { $0.kind == .complaint }.map(\.phrase))
            guard !themes.isEmpty else {
                result.paragraph = "These reviews contain too little specific opinion for a reliable summary."
                return result
            }
            do {
                result.paragraph = try await paragraph(from: themes, reviewCount: reviews.count)
            } catch is CancellationError {
                return nil
            } catch {
                try Task.checkCancellation()
                // Use only complete, meaningful sentences from already extracted evidence.
                // Never display a fragment or make up consensus to cover a failed final model pass.
                guard let fallback = Self.fallbackDigest(from: themes, reviewCount: reviews.count) else {
                    // A real generation failure remains retryable; never cache a failure as a summary.
                    return nil
                }
                result.paragraph = fallback
            }
            return result
        } catch {
            // Cancellation or a genuine extraction failure is not a completed summary. The view exposes the failure.
            return nil
        }
    }

    /// Inspect the complete text locally and select WHOLE, opinion-bearing sentences only.
    /// Truncating prefixes or suffixes produced misleading snippets such as "if only so that... chances".
    /// We never pass incomplete sentence fragments to the language model.
    static func representativeEvidence(in text: String, maximumBytes: Int) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard text.utf8.count <= maximumBytes else {
            let sentences = text.split(whereSeparator: { ".!?\n".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !sentences.isEmpty else { return "" }
            let terms: Set<String> = [
                "acting", "actor", "actors", "performance", "performances", "cast", "writing", "script", "story",
                "plot", "character", "characters", "pacing", "pace", "direction", "director", "visual", "visuals",
                "cinematography", "camera", "editing", "soundtrack", "music", "score", "dialogue", "ending",
                "themes", "theme", "tone", "humor", "humour", "comedy", "tension", "suspense",
                "thriller", "animation", "effects", "style", "atmosphere", "narrative", "emotion", "emotional",
                "great", "excellent", "wonderful", "compelling", "powerful", "memorable", "impressive",
                "brilliant", "engaging", "moving", "beautiful", "funny", "entertaining", "effective",
                "weak", "poor", "boring", "slow", "uneven", "predictable", "confusing", "disappointing",
                "terrible", "awful", "dull", "rushed", "underwhelming", "flawed", "messy", "tedious",
                "class", "inequality", "wealth", "poverty", "social", "commentary", "satire",
                "metaphor", "symbolism", "politics", "identity", "society", "family", "relationships",
                "ambition", "originality", "morality", "meaning", "subtext", "message", "subplots",
                "however", "although", "despite", "but", "because"
            ]
            struct Candidate {
                let index: Int
                let sentence: String
                let score: Int
            }
            let candidates: [Candidate] = sentences.enumerated().compactMap { index, sentence in
                let complete = sentence + "."
                // Oversized sentences are skipped, not truncated at arbitrary character positions.
                guard complete.utf8.count <= min(maximumBytes, 380), sentence.split(whereSeparator: \.isWhitespace).count >= 2 else {
                    return nil
                }
                let words = sentence.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
                let hits = words.filter { terms.contains($0) }.count
                return Candidate(index: index, sentence: complete, score: hits)
            }
            guard !candidates.isEmpty else { return "" }
            // Favor substantive evaluation over plot recaps and introductions, without ignoring later review sections.
            let ordered = candidates.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.index < $1.index
            }
            // Reserve room for the opening, middle and conclusion of a lengthy review.
            // Otherwise a repetitive opening can crowd out a crucial opinion at the end.
            let firstBoundary = max(1, sentences.count / 3)
            let lastBoundary = min(sentences.count, max(firstBoundary, sentences.count * 2 / 3))
            let regions = [0..<firstBoundary, firstBoundary..<lastBoundary, lastBoundary..<sentences.count]
            let regional = regions.compactMap { region in
                ordered.first { region.contains($0.index) && ($0.score > 0 || ordered[0].score == 0) }
            }
            var selected: [Candidate] = []
            var selectedIndices = Set<Int>()
            var used = 0
            for candidate in regional + ordered where !selectedIndices.contains(candidate.index) {
                if ordered[0].score > 0 && candidate.score == 0 { continue }
                let bytes = candidate.sentence.utf8.count + (selected.isEmpty ? 0 : 1)
                if bytes + used <= maximumBytes {
                    selected.append(candidate)
                    selectedIndices.insert(candidate.index)
                    used += bytes
                }
            }
            return selected.sorted { $0.index < $1.index }.map(\.sentence).joined(separator: " ")
        }
        return text
    }

    /// A review can make an intelligible point about several aspects of filmmaking, but vague enthusiasm
    /// or an isolated fragment ("pretty awesome movie") is not a usable observation.
    private static func isSpecificEvidence(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let aspects: Set<String> = [
            "acting", "actor", "actors", "performance", "performances", "cast", "writing", "script",
            "story", "plot", "character", "characters", "pacing", "pace", "direction", "director",
            "visual", "visuals", "cinematography", "camera", "editing", "soundtrack", "music",
            "score", "dialogue", "ending", "themes", "theme", "tone", "humor", "humour",
            "comedy", "tension", "suspense", "thriller", "animation", "effects", "style",
            "atmosphere", "narrative", "emotion", "emotional", "structure", "scenes", "scene",
            "sequences", "sequence", "twist", "twists", "originality", "message", "satire",
            "action", "world", "design", "cinematic", "filmmaking", "storytelling",
            "social", "commentary", "class", "inequality", "poverty", "identity", "morality",
            "relationships", "chemistry", "choreography", "casting", "subplots", "subtext",
            "premise", "delivery", "ambition", "society", "politics", "symbolism", "metaphor"
        ]
        return (2...42).contains(words.count) && words.contains(where: { aspects.contains($0) })
    }

    /// A completed synthesis must stand on its own and explain a concrete aspect of the film.
    /// Empty cheerleading, broken clause fragments and reviews copied directly as verdicts are not summaries.
    static func isUsefulSummaryLine(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard words.count >= 6, words.count <= 32, text.utf8.count <= 350,
              let first = words.first,
              !Set(["which", "who", "where", "if", "although", "because", "and", "but"]).contains(first),
              !text.contains("..."), !text.contains("…") else { return false }
        // Generic reactions such as "pretty awesome movie" are not summaries, but an
        // otherwise coherent paraphrase does not need to contain a term from a fixed film glossary.
        guard isSpecificEvidence(text) || words.count >= 12 else { return false }
        let last = words.last ?? ""
        return !Set(["the", "a", "an", "if", "so", "that", "and", "but", "for", "because", "to",
                     "with", "or", "of", "as", "at", "which"]).contains(last)
    }

    /// Prefer repeated evidence but reserve a place for each sentiment and contrasting viewpoints.
    /// Do not run an unbounded tree of model-generated merges for very large corpora.
    private static func compact(_ input: [Theme]) -> [Theme] {
        let themes = Self.coalesced(input)
        guard !Self.fits(themes.map { $0.source.text }, merging: true) else { return themes }
        let ranked = Self.ranked(themes)
        var chosen: [Theme] = []
        for kind in Kind.allCases {
            if let theme = ranked.first(where: { $0.kind == kind }) { chosen.append(theme) }
        }
        // A supported minority position matters even when a more common position is present.
        for kind in Kind.allCases {
            let opinions = ranked.filter { $0.kind == kind }
            if opinions.count > 1, let dissent = opinions.last,
               !chosen.contains(where: { $0.phrase == dissent.phrase && $0.kind == dissent.kind }),
               Self.fits((chosen + [dissent]).map { $0.source.text }, merging: true) {
                chosen.append(dissent)
            }
        }
        for theme in ranked where !chosen.contains(where: { $0.phrase == theme.phrase && $0.kind == theme.kind }) {
            guard Self.fits((chosen + [theme]).map { $0.source.text }, merging: true) else { continue }
            chosen.append(theme)
        }
        return chosen
    }

    /// Output is allowed only when extracted observations are complete enough to stand alone.
    /// This fallback is not another model pass and cannot turn a raw source snippet into a verdict.
    private static func fallbackDigest(from themes: [Theme], reviewCount: Int) -> String? {
        let ranked = Self.ranked(themes)
        let kinds: [(Kind, String)] = [(.verdict, "Overall"), (.praise, "Praised"), (.complaint, "Criticised")]
        var lines: [String] = []
        for (kind, label) in kinds {
            guard let theme = ranked.first(where: {
                $0.kind == kind && ($0.kind != .verdict || reviewCount <= 2 || $0.reviews.count >= 2)
                    && Self.isUsefulSummaryLine($0.phrase)
            }) else { continue }
            let text = theme.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("\(label): \(text)")
        }
        guard !lines.isEmpty else { return nil }
        if reviewCount <= 2 {
            lines.append("Based on \(reviewCount) TMDb review\(reviewCount == 1 ? "" : "s").")
        }
        return lines.joined(separator: "\n")
    }

    /// The first model pass extracts opinions; the final pass is short and bounded.
    private func paragraph(from input: [Theme], reviewCount: Int) async throws -> String {
        var themes = input
        while true {
            try Task.checkCancellation()
            do {
                let sentences = try await generator.paragraph(from: themes.map { $0.source.text }, reviewCount: reviewCount)
                try Task.checkCancellation()
                guard !sentences.isEmpty else { throw ReviewThemeGenerationError.unsupportedParagraph }
                var linesByKind: [Kind: String] = [:]
                for sentence in sentences {
                    let indices = Set(sentence.sources)
                    guard !indices.isEmpty, indices.allSatisfy({ themes.indices.contains($0) }) else { continue }
                    let kinds = Set(indices.map { themes[$0].kind })
                    guard kinds.count == 1, let kind = kinds.first, linesByKind[kind] == nil else { continue }
                    let line = sentence.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    // Citation provenance is authoritative here. Literal word overlap is NOT:
                    // the model has been asked to paraphrase, so matching words would reject valid prose.
                    guard Self.isUsefulSummaryLine(line),
                          kind != .verdict || reviewCount <= 2 || indices.contains(where: { themes[$0].reviews.count >= 2 }) else {
                        continue
                    }
                    linesByKind[kind] = line
                }
                // If the final model omitted a sentiment, a fully formed, previously supported
                // extraction can still fill that ONE missing category without fabricating consensus.
                for kind in Kind.allCases where linesByKind[kind] == nil {
                    guard let alternative = Self.ranked(themes).first(where: {
                        $0.kind == kind && Self.isUsefulSummaryLine($0.phrase)
                            && (kind != .verdict || reviewCount <= 2 || $0.reviews.count >= 2)
                    }) else { continue }
                    linesByKind[kind] = alternative.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // A valid strength remains useful even if there was no sound overall verdict.
                // Only reject the whole digest when none of its evidence is usable.
                guard !linesByKind.isEmpty else { throw ReviewThemeGenerationError.unsupportedParagraph }
                // Takeaway first; at most three short, individually supported lines.
                let ordered: [Kind] = [.verdict, .praise, .complaint]
                var digest = ordered.compactMap { kind -> String? in
                    guard let line = linesByKind[kind] else { return nil }
                    let label = kind == .verdict ? "Overall" : kind == .praise ? "Praised" : "Criticised"
                    return "\(label): \(line)"
                }
                if reviewCount <= 2 {
                    digest.append("Based on \(reviewCount) TMDb review\(reviewCount == 1 ? "" : "s").")
                }
                return digest.joined(separator: "\n")
            } catch ReviewThemeGenerationError.contextWindow {
                guard themes.count > 3 else { throw ReviewThemeGenerationError.contextWindow }
                themes = Self.balanced(themes, maximum: max(3, themes.count / 2))
            }
        }
    }

    /// A fresh session is used by the generator for each call. Unusually token-dense text is split again if a request still overflows.
    private func read(_ sources: [Source], merging: Bool) async throws -> [Theme] {
        try Task.checkCancellation()
        do {
            let key = ReviewEvidenceCache.Key(merging: merging, sources: sources.map(\.text))
            let answer: ReviewThemeGroups
            if generator.cachesEvidence, let cached = await Self.evidenceCache.value(for: key) {
                answer = cached
            } else {
                let generated = try await generator.themes(from: sources.map(\.text), merging: merging)
                try Task.checkCancellation()
                if generator.cachesEvidence { await Self.evidenceCache.store(generated, for: key) }
                answer = generated
            }
            try Task.checkCancellation()
            func supported(_ groups: [ReviewThemeGroup], kind: Kind) -> [Theme] {
                groups.compactMap { group in
                    let indices = Set(group.sources)
                    guard !indices.isEmpty, indices.allSatisfy({ sources.indices.contains($0) }),
                          group.phrase.utf8.count <= 320 else { return nil }
                    let evidence = indices.sorted().map { sources[$0] }
                    // A merge cannot turn a complaint into praise, or manufacture an index that was not in its input.
                    guard evidence.allSatisfy({ $0.kind == nil || $0.kind == kind }),
                          evidence.allSatisfy({ Self.supports(group.phrase, in: [$0.text]) }) else { return nil }
                    let reviews = evidence.reduce(into: Set<Int>()) { result, source in
                        result.formUnion(source.reviews)
                    }
                    return Theme(phrase: group.phrase, kind: kind, reviews: reviews)
                }
            }
            return Self.coalesced(supported(answer.praise, kind: .praise) + supported(answer.complaints, kind: .complaint)
                                  + supported(answer.verdicts, kind: .verdict))
        } catch ReviewThemeGenerationError.contextWindow {
            if sources.count > 1 {
                let middle = sources.count / 2
                let first = try await read(Array(sources[..<middle]), merging: merging)
                let last = try await read(Array(sources[middle...]), merging: merging)
                return Self.coalesced(first + last)
            }
            guard !merging, let source = sources.first else { throw ReviewThemeGenerationError.contextWindow }
            let chunks = Self.chunks(of: source.text, maximumBytes: max(1, source.text.utf8.count / 2))
            guard chunks.count > 1 else { throw ReviewThemeGenerationError.contextWindow }
            var themes: [Theme] = []
            for text in chunks {
                themes += try await read([Source(text: text, reviews: source.reviews, kind: nil)], merging: false)
            }
            return Self.coalesced(themes)
        }
    }

    static func prompt(for sources: [String], merging: Bool) -> String {
        let task = merging
            ? "Combine genuinely equivalent supported opinions within each kind. Rewrite them as complete, specific observations about filmmaking, not quotations. Preserve source indices, disagreement and distinct-review counts. Do not manufacture agreement."
            : "Identify what the reviewer thinks about acting, writing, plot, character work, pacing, direction, visuals or other specific craft, and WHY. Summarise the opinion in your own complete words rather than copying snippets. Ignore generic enthusiasm, plot recaps and incomplete or irrelevant remarks. Keep source indices exact."
        return task + "\n\n" + sources.enumerated().map { "Source \($0.offset):\n\($0.element)" }.joined(separator: "\n\n")
    }

    static func paragraphPrompt(for sources: [String], reviewCount: Int) -> String {
        """
        You are writing a film-review consensus, NOT reproducing or stitching together reviewer sentences.
        The evidence below is already grouped by sentiment and annotated with how many DISTINCT reviews support it.
        Synthesize the most informative recurring opinions, focusing on what people liked or disliked AND why.
        Your sentences must be original, natural, clear and understandable WITHOUT the source text beside them.
        Never simply copy an excerpt or emit vague statements such as "pretty awesome movie" or "must be seen".
        Do not use dangling clauses, first-person or second-person comments, plot summaries, or generic filler.

        Return at most ONE complete sentence for each evidence kind that exists:
        Overall verdict (only if a supported, genuinely representative overall assessment exists),
        Praise (specific strengths and reasons), and Complaint (specific weaknesses and reasons).
        Each sentence should be roughly 10–20 words, never more than 25. Use plain, grammatical English.
        The Overall sentence must cite ONLY Overall verdict sources; the Praise sentence must cite ONLY Praise
        sources; the Complaint sentence must cite ONLY Complaint sources. Do not combine kinds.
        Make the summary representative of these \(reviewCount) reviews, not an isolated quirky take.
        If the evidence is mixed, say so without inventing consensus. For small samples, don't imply a majority.
        A view is "common" only when more than half of the distinct reviews individually support it.
        Never invent a reason, opinion, or film-specific detail. No headings, labels, lists, scores or spoilers.
        The app displays the labels. Return each sentence with ONLY its zero-based supporting source indices.

        \(sources.enumerated().map { "Source \($0.offset):\n\($0.element)" }.joined(separator: "\n\n"))
        """
    }

    /// Extraction-only sanity check. Require just one meaningful shared topic, allowing
    /// grammatical variants ("performances" versus "performance") and genuine paraphrases.
    /// Final summaries are checked by source-index/category provenance, not lexical overlap.
    private static func supports(_ statement: String, in evidence: [String]) -> Bool {
        func roots(_ text: String) -> Set<String> {
            let ignored: Set<String> = ["about", "review", "reviews", "reviewer", "reviewers", "source", "sources",
                                        "praise", "complaint", "verdict", "overall", "supported", "distinct",
                                        "movie", "movies", "film", "films", "series", "their", "there", "these",
                                        "they", "this", "that", "with", "from", "have", "were", "been", "what"]
            return Set(text.lowercased().split(whereSeparator: { !$0.isLetter })
                .map(String.init)
                .filter { $0.count >= 4 && !ignored.contains($0) }
                .map { token in
                    if token.hasSuffix("ies") && token.count > 5 { return String(token.dropLast(3)) + "y" }
                    if token.hasSuffix("sses") && token.count > 6 { return String(token.dropLast(2)) }
                    if token.hasSuffix("s") && !token.hasSuffix("ss") && token.count > 4 { return String(token.dropLast()) }
                    return token
                })
        }
        let terms = roots(statement)
        guard !terms.isEmpty else { return false }
        let equivalent: [String: String] = [
            "acting": "performance", "actor": "performance", "cast": "performance",
            "pacing": "pace", "cinematography": "visual", "photography": "visual",
            "screenplay": "script", "writing": "script", "storytelling": "story",
            "characterisation": "character", "characterization": "character",
            "directing": "direction", "music": "soundtrack", "score": "soundtrack"
        ]
        func canonical(_ words: Set<String>) -> Set<String> {
            Set(words.map { equivalent[$0] ?? $0 })
        }
        let expected = canonical(terms)
        return evidence.contains { !expected.isDisjoint(with: canonical(roots($0))) }
    }

    private static func fits(_ sources: [String], merging: Bool) -> Bool {
        sources.count <= sourcesPerBatch && prompt(for: sources, merging: merging).utf8.count <= inputByteBudget
    }

    private static func batches(_ themes: [Theme]) -> [[Theme]] {
        var batches: [[Theme]] = []
        var pending: [Theme] = []
        for theme in themes {
            if !pending.isEmpty, !fits(pending.map { $0.source.text } + [theme.source.text], merging: true) {
                batches.append(pending)
                pending = []
            }
            pending.append(theme)
        }
        if !pending.isEmpty { batches.append(pending) }
        return batches
    }

    private static func ranked(_ themes: [Theme]) -> [Theme] {
        themes.enumerated().sorted {
            if $0.element.reviews.count != $1.element.reviews.count { return $0.element.reviews.count > $1.element.reviews.count }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    private static func balanced(_ themes: [Theme], maximum: Int) -> [Theme] {
        let ranked = ranked(themes)
        var indices: [Int] = []
        for kind in Kind.allCases {
            if let index = ranked.firstIndex(where: { $0.kind == kind }) { indices.append(index) }
        }
        for index in ranked.indices where !indices.contains(index) && indices.count < maximum { indices.append(index) }
        return indices.map { ranked[$0] }
    }

    /// A merge must never erase an entire sentiment because its statements have fewer supporters than the other kinds.
    private static func preservingKinds(_ merged: [Theme], from original: [Theme]) -> [Theme] {
        var kept = merged
        for kind in Kind.allCases where !kept.contains(where: { $0.kind == kind }) {
            if let point = ranked(original).first(where: { $0.kind == kind }) { kept.append(point) }
        }
        return coalesced(kept)
    }

    private static func coalesced(_ themes: [Theme]) -> [Theme] {
        var kept: [Theme] = []
        var positions: [String: Int] = [:]
        for theme in themes {
            let words = theme.phrase.lowercased().split(whereSeparator: { !$0.isLetter })
            let name = words.drop(while: { ["its", "the", "their"].contains(String($0)) }).joined(separator: " ")
            let key = "\(theme.kind):\(name)"
            if let index = positions[key] {
                kept[index].reviews.formUnion(theme.reviews)
            } else {
                positions[key] = kept.count
                kept.append(theme)
            }
        }
        return kept
    }

    /// Splits at whitespace where possible, retaining every Unicode scalar, including punctuation and whitespace between chunks.
    /// UTF-8 bytes bound token-dense input more conservatively than counting Swift Characters.
    static func chunks(of text: String, maximumBytes: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        let scalars = text.unicodeScalars
        var chunks: [String] = []
        var start = scalars.startIndex
        while start < scalars.endIndex {
            var end = start
            var boundary: String.Index?
            var bytes = 0
            while end < scalars.endIndex {
                let scalar = scalars[end]
                let size = scalar.utf8.count
                if bytes + size > max(1, maximumBytes), end > start { break }
                bytes += size
                end = scalars.index(after: end)
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { boundary = end }
            }
            let split = end == scalars.endIndex ? end : (boundary ?? end)
            chunks.append(String(scalars[start..<split]))
            start = split
        }
        return chunks
    }
}


/// A small process-local cache for completed intermediate on-device extractions. Cancellation never caches
/// a finished overall summary, but successful batches can be reused after a retry.
private actor ReviewEvidenceCache {
    struct Key: Hashable {
        let merging: Bool
        let sources: [String]
    }

    static let shared = ReviewEvidenceCache()
    private var entries: [Key: ReviewThemeGroups] = [:]
    private var order: [Key] = []
    private let capacity = 80

    func value(for key: Key) -> ReviewThemeGroups? { entries[key] }

    func store(_ value: ReviewThemeGroups, for key: Key) {
        guard entries[key] == nil else { return }
        if order.count >= capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
        entries[key] = value
        order.append(key)
    }
}
