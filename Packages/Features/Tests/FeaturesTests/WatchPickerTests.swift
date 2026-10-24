import Foundation
import Testing
import StremioKit
@testable import Features

@MainActor
@Suite struct WatchPickerTests {
    private struct StubWish: WishInterpreting {
        let wish: WatchWish?
        func interpret(_ text: String) async -> WatchWish? { wish }
    }

    /// Stands in for the on-device model's ranking: answers fixed numbers, including ones outside the list.
    private final class StubRanker: CandidateRanking, @unchecked Sendable {
        let answer: [RankedCandidate]
        private(set) var shown: [String] = []
        init(_ answer: [RankedCandidate]) { self.answer = answer }
        private(set) var references: [String] = []
        func rank(request: String, references: [String], candidates: [String], watched: [String]) async throws -> [RankedCandidate] {
            shown = candidates
            self.references = references
            return answer
        }
    }

    private let prisoners = MetaPreview(id: "tt1392214", type: "movie", name: "Prisoners", genres: ["Crime", "Drama"])
    private let zodiac = MetaPreview(id: "tt0443706", type: "movie", name: "Zodiac", releaseInfo: "2007", genres: ["Crime"], runtime: "157 min")
    private let incendies = MetaPreview(id: "tt1255953", type: "movie", name: "Incendies")
    private let seen = MetaPreview(id: "tt0114369", type: "movie", name: "Se7en")
    private let knives = MetaPreview(id: "tt8946378", type: "movie", name: "Knives Out")

    private func picker(_ ranker: StubRanker, wish: WatchWish? = WatchWish(likeTitles: ["Prisoners"])) -> WatchPicker {
        let prisoners = prisoners, zodiac = zodiac, incendies = incendies, seen = seen, knives = knives
        return WatchPicker(interpreter: StubWish(wish: wish), ranker: ranker, findTitle: { _ in prisoners },
                           related: { _ in [zodiac, seen, incendies, prisoners] },
                           discover: { _ in [knives, zodiac] },
                           watched: { [(identity: seen.identity, name: seen.name)] })
    }

    @Test func picksAreOnlyRealUnwatchedCandidates() async {
        // Candidates: 1 Zodiac, 2 Incendies, 3 Knives Out (Se7en is watched and Prisoners is the reference, so both are left out).
        let ranker = StubRanker([RankedCandidate(number: 99, reason: "Not in the list"), RankedCandidate(number: 2, reason: "Tense and humane"),
                                 RankedCandidate(number: 2, reason: "Twice"), RankedCandidate(number: 0, reason: "Zero"),
                                 RankedCandidate(number: 1, reason: "   "), RankedCandidate(number: 3, reason: "Lighter")])
        let picks = await picker(ranker).picks(for: "something like Prisoners but less depressing")
        #expect(picks.map(\.item.name) == ["Incendies", "Knives Out"], "a number outside the list, a repeat and a blank reason are dropped")
        #expect(picks.first?.reason == "Tense and humane")
        #expect(ranker.shown.count == 3 && ranker.shown.allSatisfy { !$0.contains("Se7en") && !$0.hasPrefix("Prisoners") })
        #expect(ranker.shown.first == "Zodiac (2007), film. Crime. 157 min")
        #expect(ranker.references == ["Prisoners, film. Crime, Drama"], "the model is told what the named title is")
    }

    @Test func aTitleLongerThanTheRequestAllowsIsNotACandidate() async {
        let ranker = StubRanker([RankedCandidate(number: 1, reason: "Fits")])
        var search = DescribedSearch()
        search.maximumRuntime = 120
        let picks = await picker(ranker, wish: WatchWish(likeTitles: ["Prisoners"], search: search)).picks(for: "something like Prisoners under two hours")
        #expect(!ranker.shown.contains { $0.hasPrefix("Zodiac") }, "Zodiac runs 157 minutes")
        #expect(picks.first?.item.name == "Incendies")
        #expect(WatchPicker.minutes("2h 17min") == 137 && WatchPicker.minutes("98 min") == 98 && WatchPicker.minutes(nil) == nil)
    }

    /// The model's safety check can refuse a request outright.
    private struct RefusingRanker: CandidateRanking {
        struct Refused: Error {}
        func rank(request: String, references: [String], candidates: [String], watched: [String]) async throws -> [RankedCandidate] {
            throw Refused()
        }
    }

    @Test func aRefusedRankingDoesNotPretendTMDbMatchesWereChosenByAI() async {
        let prisoners = prisoners, zodiac = zodiac, knives = knives
        let picker = WatchPicker(interpreter: StubWish(wish: WatchWish(likeTitles: ["Prisoners"])), ranker: RefusingRanker(),
                                 findTitle: { _ in prisoners }, related: { _ in [zodiac] }, discover: { _ in [knives] }, watched: { [] })
        let picks = await picker.picks(for: "something like Prisoners")
        #expect(picks.isEmpty, "only actual model selections belong in the AI row")
    }

    @Test func aRecommendationOfTheWrongKindOrYearsIsNotACandidate() {
        let show = MetaPreview(id: "tt1", type: "series", name: "Show", releaseInfo: "2015")
        let old = MetaPreview(id: "tt2", type: "movie", name: "Old", releaseInfo: "1975")
        let undated = MetaPreview(id: "tt3", type: "movie", name: "Undated")
        let films = DescribedSearch(kind: .movie, earliestYear: 1990)
        #expect(!WatchPicker.fitsKindAndYears(show, films) && !WatchPicker.fitsKindAndYears(old, films))
        #expect(WatchPicker.fitsKindAndYears(undated, films), "a title with no known year is kept")
        #expect(WatchPicker.fitsKindAndYears(show, DescribedSearch()))
    }

    private struct SynopsisRefusal: CandidateRanking {
        struct Blocked: Error {}
        func rank(request: String, references: [String], candidates: [String], watched: [String]) async throws -> [RankedCandidate] {
            if candidates.contains(where: { $0.contains("REFUSED_PLOT") }) { throw Blocked() }
            return candidates.indices.map { RankedCandidate(number: $0 + 1, reason: "Story matches") }
        }
    }

    @Test func aSingleRefusedSynopsisDoesNotDiscardOtherMovies() async throws {
        let safe = MetaPreview(id: "tt1", type: "movie", name: "Safe", description: "A mystery involving a missing friend.")
        let blocked = MetaPreview(id: "tt2", type: "movie", name: "Blocked", description: "REFUSED_PLOT")
        let other = MetaPreview(id: "tt3", type: "movie", name: "Other", description: "A paranoid investigation.")
        let missing = MetaPreview(id: "tt4", type: "movie", name: "Missing Synopsis")
        let picks = try await WatchPicker.rankedPicks(request: "mysteries about paranoia", references: [],
                                                      candidates: [safe, blocked, other, missing], watched: [],
                                                      ranker: SynopsisRefusal())
        #expect(picks.map(\.item.name) == ["Safe", "Other"])
        #expect(WatchPicker.line(safe).contains("Synopsis: A mystery involving a missing friend."))
        #expect(WatchPicker.synopsis(" \n ") == nil)
        #expect(WatchPicker.synopsis(String(repeating: "x", count: 500))?.count == 240)
    }

    private final class BatchRanker: CandidateRanking, @unchecked Sendable {
        private let lock = NSLock()
        private var sizes: [Int] = []
        var requestSizes: [Int] { lock.withLock { sizes } }

        func rank(request: String, references: [String], candidates: [String], watched: [String]) async throws -> [RankedCandidate] {
            lock.withLock { sizes.append(candidates.count) }
            return candidates.prefix(2).enumerated().map {
                RankedCandidate(number: $0.offset + 1, reason: "A grounded plot match")
            }
        }
    }

    @Test func largeSearchesAreRankedInBoundedSynopsisGroups() async throws {
        let candidates = (1...34).map {
            MetaPreview(id: "tt\($0)", type: "movie", name: "Film \($0)", description: "A story about a quest number \($0).")
        }
        let ranker = BatchRanker()
        let picks = try await WatchPicker.rankedPicks(request: "films about quests", references: [],
                                                      candidates: candidates, watched: [], ranker: ranker)
        #expect(!picks.isEmpty)
        #expect(ranker.requestSizes.count >= 4)
        #expect(ranker.requestSizes.allSatisfy { $0 <= WatchPicker.maxModelBatch })
        #expect(picks.count <= WatchPicker.maxPicks)
    }

    @Test func explicitBrothersRequestRejectsUnrelatedRomanceButKeepsStepBrothers() {
        let step = MetaPreview(id: "tt1", type: "movie", name: "Step Brothers",
                               description: "Two grown men are forced to live together after their parents marry.")
        let romance = MetaPreview(id: "tt2", type: "movie", name: "Through My Window",
                                  description: "A girl becomes infatuated with her mysterious neighbour.")
        #expect(WatchPicker.matchesStorySubject(step, request: "funny movies about brothers"))
        #expect(!WatchPicker.matchesStorySubject(romance, request: "funny movies about brothers"))
        #expect(WatchPicker.matchesStorySubject(romance, request: "funny romances"))
    }

    @Test func noWishMeansNoPicks() async {
        let ranker = StubRanker([RankedCandidate(number: 1, reason: "Fits")])
        #expect(await picker(ranker, wish: nil).picks(for: "something like Prisoners").isEmpty)
        #expect(ranker.shown.isEmpty, "nothing is ranked without a wish")
    }

    @Test func atMostEightPicks() {
        let items = (1...12).map { MetaPreview(id: "tt\($0)", type: "movie", name: "T\($0)") }
        let ranked = (1...12).map { RankedCandidate(number: $0, reason: "r") }
        #expect(WatchPicker.validated(ranked, candidates: items).count == 8)
    }

    @Test func onlyRequestsReadLikeRequests() {
        #expect(WatchPicker.readsLikeRequest("Something like Prisoners, but less depressing, under two hours"))
        #expect(WatchPicker.readsLikeRequest("what should I watch tonight"))
        #expect(WatchPicker.readsLikeRequest("movies like Heat"))
        #expect(WatchPicker.readsLikeRequest("movies with shocking twists like Shutter Island"))
        #expect(!WatchPicker.readsLikeRequest("Prisoners"))
        #expect(!WatchPicker.readsLikeRequest("a dark atmospheric sci-fi film from before 2010"))
    }
}
