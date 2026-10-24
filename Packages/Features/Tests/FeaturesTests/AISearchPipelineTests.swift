import Foundation
import Testing
import StremioKit
@testable import Features

@MainActor
@Suite struct AISearchPipelineTests {
    private actor Calls {
        var plans = 0
        var ranks = 0
        var fetches = 0
        var queries: [TMDbDiscoverQuery] = []
        var updates: [AISearchUpdate] = []
        private var planWaiter: CheckedContinuation<Void, Never>?
        func plan() { plans += 1; planWaiter?.resume(); planWaiter = nil }
        func waitForPlan() async {
            if plans > 0 { return }
            await withCheckedContinuation { planWaiter = $0 }
        }
        func rank() { ranks += 1 }
        func nextFetch() -> Int { fetches += 1; return fetches }
        func query(_ value: TMDbDiscoverQuery) { queries.append(value) }
        func update(_ value: AISearchUpdate) { updates.append(value) }
    }

    private struct Interpreter: DescriptionInterpreting {
        let answer: AISearchPlan
        let calls: Calls
        func interpret(_ text: String) async -> DescribedSearch { answer.filters }
        func plan(_ text: String) async -> AISearchPlan { await calls.plan(); return answer }
    }

    private struct Ranker: CandidateRanking {
        let calls: Calls
        var rejectAll = false
        func rank(request: String, references: [String], candidates: [String], watched: [String]) async throws -> [RankedCandidate] {
            await calls.rank()
            if rejectAll { return [] }
            return candidates.indices.map { RankedCandidate(number: $0 + 1, reason: "Matches the supplied evidence") }
        }
    }

    @Test(arguments: ["90s comedy", "80s horror", "2000s sci-fi", "drama before 2010"])
    func explicitFiltersUseDatabaseFactsInsteadOfRejectingPlots(_ request: String) async {
        let calls = Calls()
        let filters = DescribedSearch.reading(request)
        let service = DescribedSearchService(interpreter: Interpreter(answer: AISearchPlan(filters: filters), calls: calls),
            keywords: { _ in [] }, titles: { query in
                await calls.query(query)
                return (1...12).map { number in
                    MetaPreview(id: "tt\(query.kind.rawValue)\(number)", type: query.kind == .movie ? "movie" : "series",
                                name: "Title \(number)", releaseInfo: String(filters.earliestYear ?? 2000))
                }
            }, ranker: Ranker(calls: calls, rejectAll: true))
        // TMDb has no TV horror genre: a TV query would drop it and list any popular series, so "80s horror" asks films only.
        let kinds: Set<TMDbDiscoverQuery.Kind> = request == "80s horror" ? [.movie] : [.movie, .series]
        let results = await service.titles(for: request) { await calls.update($0) }
        #expect(results.count == 12 * kinds.count, "a database-filter request has no arbitrary eight-pick limit or synopsis requirement")
        #expect(await calls.plans == 1, "every query still invokes AI interpretation")
        #expect(await calls.ranks == 0, "plot inference cannot discard correct genre/year matches")
        let queries = await calls.queries
        #expect(queries.count == kinds.count)
        #expect(Set(queries.map(\.kind)) == kinds)
        #expect(queries.allSatisfy { $0.releasedTo == "\(filters.latestYear!)-12-31" })
        #expect(await calls.updates.contains { !$0.items.isEmpty && $0.stage != .complete })
    }

    private actor Gate {
        private var open = false
        private var continuations: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { continuations.append($0) }
        }
        func release() { open = true; continuations.forEach { $0.resume() }; continuations = [] }
    }

    private struct WaitingInterpreter: DescriptionInterpreting {
        let gate: Gate
        var calls: Calls?
        func interpret(_ text: String) async -> DescribedSearch { .reading(text) }
        func plan(_ text: String) async -> AISearchPlan {
            if let calls { await calls.plan() }
            await gate.wait()
            return AISearchPlan(filters: .reading(text))
        }
    }

    @Test func firstFilterBatchAppearsBeforeTheModelOrNextPageFinishes() async {
        let gate = Gate()
        let calls = Calls()
        let service = DescribedSearchService(interpreter: WaitingInterpreter(gate: gate), keywords: { _ in [] }, titles: { _ in [] },
            pageTitles: { query, skip in
                await calls.query(query)
                guard skip < 12 else { return [] }
                return (skip..<(skip + DescribedSearchService.batchSize)).map {
                    MetaPreview(id: "tt\(query.kind.rawValue)\($0)", type: query.kind == .movie ? "movie" : "series",
                                name: "Title \($0)", releaseInfo: "1995")
                }
            })
        // This can finish only if a partial result releases the model, rather than waiting for the model first.
        let items = await service.titles(for: "90s comedy") { update in
            await calls.update(update)
            if !update.items.isEmpty { await gate.release() }
        }
        let snapshots = await calls.updates.filter { !$0.items.isEmpty }.map(\.items)
        #expect(snapshots.first?.count == DescribedSearchService.batchSize)
        #expect(items.count == 24)
        for pair in zip(snapshots, snapshots.dropFirst()) {
            #expect(pair.1.starts(with: pair.0), "later batches append without replacing or shuffling visible cards")
        }
    }

    @Test func semanticSearchPublishesEveryRankedBatchAndKeepsMoreThanEightMatches() async {
        let calls = Calls()
        let plan = AISearchPlan(filters: DescribedSearch(kind: .movie, genres: ["Crime"], moods: ["paranoia"]))
        let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { _ in [] }, titles: { _ in
            (1...18).map { MetaPreview(id: "tt\($0)", type: "movie", name: "Title \($0)", description: "A paranoid investigation.") }
        }, ranker: Ranker(calls: calls))
        let items = await service.titles(for: "tense crime films about paranoia") { await calls.update($0) }
        let sizes = await calls.updates.map { $0.items.count }
        #expect(items.count == 18)
        #expect(sizes.contains(12) && sizes.contains(18))
        #expect(await calls.ranks == 2, "twelve candidates share one short selection call")
    }

    @Test func metadataOnlyCastSearchUsesVerifiedCreditsWithoutNeedingASynopsis() async {
        let calls = Calls()
        let person = AISearchPlan.Person(name: "Requested Actor", role: .cast)
        let plan = AISearchPlan(filters: DescribedSearch(kind: .movie), people: [person], requiresSemanticRanking: false)
        let movie = MetaPreview(id: "tt1", type: "movie", name: "A Film Without a Synopsis")
        let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { _ in [] }, titles: { query in
            await calls.query(query); return []
        }, ranker: Ranker(calls: calls, rejectAll: true), peopleTitles: { people, _ in
            #expect(people == [person])
            return [AISearchCandidate(item: movie, evidence: "cast: Requested Actor")]
        })
        #expect(await service.titles(for: "movies starring Requested Actor") == [movie])
        #expect(await calls.ranks == 0)
        #expect(await calls.queries.isEmpty)
    }

    private actor Overlap {
        var running = 0
        var most = 0
        func enter() { running += 1; most = max(most, running) }
        func leave() { running -= 1 }
    }

    /// Accepts every candidate; the first batch answers last, so later batches finish first.
    private struct SlowRanker: CandidateRanking {
        let overlap: Overlap
        func rank(request: String, references: [String], candidates: [String], watched: [String]) async throws -> [RankedCandidate] {
            await overlap.enter()
            try? await Task.sleep(for: .milliseconds(candidates.first?.hasPrefix("Title 1,") == true ? 80 : 10))
            await overlap.leave()
            return candidates.indices.map { RankedCandidate(number: $0 + 1, reason: "") }
        }
    }

    @Test func candidateBatchesAreCheckedTwoAtATimeAndShownInOrder() async {
        let calls = Calls()
        let overlap = Overlap()
        let plan = AISearchPlan(filters: DescribedSearch(kind: .movie, genres: ["Crime"], moods: ["paranoia"]))
        let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { _ in [] }, titles: { _ in
            (1...36).map { MetaPreview(id: "tt\($0)", type: "movie", name: "Title \($0)", description: "A paranoid investigation.") }
        }, ranker: SlowRanker(overlap: overlap))
        let items = await service.titles(for: "tense crime films about paranoia") { await calls.update($0) }
        #expect(await overlap.most == DescribedSearchService.rankingConcurrency)
        #expect(items.count >= 24)
        #expect(items.map(\.name) == (1...items.count).map { "Title \($0)" }, "the first batch's picks come first, though it answered last")
        let snapshots = await calls.updates.filter { !$0.items.isEmpty }.map(\.items)
        for pair in zip(snapshots, snapshots.dropFirst()) { #expect(pair.1.starts(with: pair.0)) }
    }

    /// A page that fills the candidate limit at once still has its candidates checked, rather than none of them.
    @Test func candidatesTakenUpToTheLimitAreStillChecked() async {
        let calls = Calls()
        let plan = AISearchPlan(filters: DescribedSearch(genres: ["Comedy"], moods: ["paranoia"]))
        let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { _ in [] }, titles: { query in
            (1...40).map { MetaPreview(id: "tt\(query.kind.rawValue)\($0)", type: query.kind == .movie ? "movie" : "series", name: "Title \($0)",
                                       description: "A paranoid comedy.") }
        }, ranker: Ranker(calls: calls))
        let items = await service.titles(for: "comedies about paranoia")
        #expect(items.count >= DescribedSearchService.semanticTarget)
        #expect(await calls.ranks <= DescribedSearchService.rankingAttemptLimit)
    }

    @Test func languageStudioAndExclusionsReachBothDatabaseQueries() async {
        let calls = Calls()
        let plan = AISearchPlan(filters: DescribedSearch(genres: ["Animation"], excludedGenres: ["Horror"]),
                                companies: ["A Studio"], language: "ja", excludedTopics: ["revenge"], requiresSemanticRanking: false)
        let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { _ in
            [.init(id: 55, name: "revenge")]
        }, titles: { query in await calls.query(query); return [] }, companies: { _ in [.init(id: 9, name: "A Studio")] })
        _ = await service.titles(for: "Japanese animation from A Studio without horror or revenge")
        let queries = await calls.queries
        #expect(queries.count == 2)
        #expect(queries.allSatisfy { $0.language == "ja" && $0.companies.map(\.id) == [9] && $0.excludedKeywords.map(\.id) == [55] })
        #expect(queries.first?.excludedGenres.map(\.id) == [27])
    }

    @Test func aReferenceTitleUsesRelatedTitlesAndNeverReturnsTheReferenceItself() async {
        let calls = Calls()
        let seed = MetaPreview(id: "tt1", type: "movie", name: "Reference")
        let match = MetaPreview(id: "tt2", type: "movie", name: "Match", description: "A tense investigation.")
        let plan = AISearchPlan(filters: DescribedSearch(), referenceTitles: ["Reference"])
        let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { _ in [] },
            titles: { _ in [] }, ranker: Ranker(calls: calls), titleMatches: { _ in [seed] }, related: { _ in [seed, match] })
        #expect(await service.titles(for: "something like Reference") == [match])
    }

    /// The wider pool keeps a requested genre (it once dropped Horror and listed Coronation Street for "slow burn psychological
    /// horror"), draws on the genres feel words imply when none is named, and on a reference title's genres.
    @Test(arguments: [
        ("slow burn psychological horror", ["Horror"], [] as [String], [[27]]),
        ("80s dark gritty", [], [], [[53, 80], [53]]),
        ("something like Reference", [], ["Reference"], [[18, 53]]),
    ])
    func theWiderPoolKeepsTheGenreOrDrawsOnImpliedOnes(_ text: String, _ genres: [String], _ references: [String], _ expected: [[Int]]) async {
        let calls = Calls()
        let seed = MetaPreview(id: "tt1", type: "movie", name: "Reference", genres: ["Drama", "Thriller", "Crime"])
        let years = text.hasPrefix("80s") ? (1980, 1989) : (nil, nil)
        let filters = DescribedSearch(genres: genres, earliestYear: years.0, latestYear: years.1)
        let plan = AISearchPlan(filters: filters, referenceTitles: references, requiresSemanticRanking: true)
        let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { _ in [] },
            titles: { query in await calls.query(query); return [] }, ranker: Ranker(calls: calls),
            titleMatches: { _ in [seed] }, related: { _ in [] })
        _ = await service.titles(for: text)
        let queries = await calls.queries
        #expect(!queries.isEmpty)
        #expect(Set(queries.map { $0.genres.map(\.id) }) == Set(expected))
    }

    /// The searches shown before the model's reading never show what the words rule out, or what the viewer has watched when only
    /// unwatched titles are wanted: those wait for the reading and the viewing history.
    @Test func earlyResultsWaitForExclusionsAndHistory() async {
        let heist = MetaPreview(id: "tt1", type: "movie", name: "Seen Heist")
        let other = MetaPreview(id: "tt2", type: "movie", name: "New Heist")
        for (text, plan) in [
            ("heist movies without violence", AISearchPlan(filters: DescribedSearch(kind: .movie, moods: ["heist"]), excludedTopics: ["violence"],
                                                           requiresSemanticRanking: false)),
            ("heist movies new to me", AISearchPlan(filters: DescribedSearch(kind: .movie, moods: ["heist"]), unwatchedOnly: true,
                                                    requiresSemanticRanking: false)),
        ] {
            let calls = Calls()
            let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { phrase in
                [TMDbDiscoverQuery.Named(id: phrase.count, name: phrase)]
            }, titles: { query in
                await calls.query(query)
                return [heist, other]
            }, watched: { ["movie/tt1"] })
            let items = await service.titles(for: text)
            #expect(await calls.queries.allSatisfy { !$0.keywords.contains { $0.name.contains("violence") } }, "\(text)")
            if plan.unwatchedOnly { #expect(items == [other]) }
        }
    }

    /// TMDb's main keyword is the singular one: "zombies" tags a handful of titles, so both forms are asked for, singular first.
    @Test func aTopicAsksForBothFormsOfItsKeyword() {
        let found = [TMDbDiscoverQuery.Named(id: 2, name: "zombies"), .init(id: 1, name: "zombie"), .init(id: 3, name: "zombie apocalypse")]
        #expect(DescribedSearchService.sameTopic(found, "zombies").map(\.id) == [1, 2])
        #expect(DescribedSearchService.sameTopic(found, "vampires").isEmpty)
    }

    /// A title the model gave back is shown even when its words read as a genre that it is not ("Scary Movie" is a comedy), with
    /// its sequels, and never a film whose name merely contains the words.
    @Test func aTitleTheWordsNameIsShownWithItsSequelsDespiteTheirFilters() async {
        let calls = Calls()
        let films = [MetaPreview(id: "tt1", type: "movie", name: "Scary Movie", releaseInfo: "2000", genres: ["Comedy"]),
                     MetaPreview(id: "tt2", type: "movie", name: "Scary Movie 3", releaseInfo: "2003", genres: ["Comedy"]),
                     MetaPreview(id: "tt3", type: "movie", name: "A Very Scary Movie Night", releaseInfo: "2019", genres: ["Horror"])]
        var plan = AISearchPlan(filters: DescribedSearch(kind: .movie, genres: ["Horror"]), titleQueries: ["Scary Movie"],
                                requiresSemanticRanking: false)
        plan.titlesFromWords = true
        plan.titleSequelsOnly = true
        let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { _ in [] },
            titles: { _ in [] }, titleMatches: { _ in films })
        let items = await service.titles(for: "Scary Movie")
        #expect(items.prefix(2).map(\.name) == ["Scary Movie", "Scary Movie 3"])
        #expect(!items.contains { $0.name == "A Very Scary Movie Night" })
    }

    @Test func aLeadingArticleDoesNotChangeATitlesName() {
        #expect(DescribedSearchService.isNamedOrSequel(MetaPreview(id: "tt1", name: "The Lego Movie"), "lego movie"))
        #expect(DescribedSearchService.isNamed(MetaPreview(id: "tt2", name: "The War of the Worlds"), "War of the Worlds"))
        #expect(!DescribedSearchService.isNamed(MetaPreview(id: "tt3", name: "The"), "A"))
    }

    @Test func eachTopicsMainKeywordComesBeforeAnySecondForm() {
        let zombie = TMDbDiscoverQuery.Named(id: 1, name: "zombie"), zombies = TMDbDiscoverQuery.Named(id: 2, name: "zombies")
        let heist = TMDbDiscoverQuery.Named(id: 3, name: "heist"), heists = TMDbDiscoverQuery.Named(id: 4, name: "heists")
        #expect(DescribedSearchService.firstsFirst([[zombie, zombies], [heist, heists]]).map(\.id) == [1, 3, 2, 4])
    }

    /// Words searched as a title whose matches are only near ("Time Travel Tales" for "time travel") still get the theme search.
    @Test func aTitleSearchWithoutAnExactMatchStillSearchesTheThemes() async {
        let calls = Calls()
        let near = MetaPreview(id: "tt1", type: "movie", name: "Time Travel Tales")
        var plan = AISearchPlan(filters: DescribedSearch(moods: ["time travel"]), titleQueries: ["time travel"], requiresSemanticRanking: false)
        plan.titlesFromWords = true
        let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { phrase in
            [TMDbDiscoverQuery.Named(id: 1, name: phrase)]
        }, titles: { query in
            await calls.query(query)
            return []
        }, titleMatches: { _ in [near] })
        _ = await service.titles(for: "time travel")
        #expect(!(await calls.queries).isEmpty)
    }

    /// A title the model named ends the search once found, even under another name ("The Empire Strikes Back" for "Star Wars"), as
    /// before: the years left in the words never fill the row with unrelated 80s films.
    @Test func aNamedTitleFoundUnderAnotherNameStillEndsTheSearch() async {
        let calls = Calls()
        let found = [MetaPreview(id: "tt1", type: "movie", name: "The Empire Strikes Back", releaseInfo: "1980"),
                     MetaPreview(id: "tt2", type: "movie", name: "Return of the Jedi", releaseInfo: "1983")]
        let plan = AISearchPlan(filters: DescribedSearch(kind: .movie, earliestYear: 1980, latestYear: 1989), titleQueries: ["Star Wars"],
                                requiresSemanticRanking: false)
        let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { _ in [] }, titles: { query in
            await calls.query(query)
            return []
        }, titleMatches: { _ in found })
        #expect(await service.titles(for: "Star Wars movies from the 80s") == found)
        #expect(await calls.queries.isEmpty)
    }

    @Test func explicitUnwatchedRequestExcludesHistoryBeforeRanking() async {
        let calls = Calls()
        let plan = AISearchPlan(filters: DescribedSearch(kind: .movie, genres: ["Drama"]), unwatchedOnly: true)
        let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { _ in [] }, titles: { _ in
            [MetaPreview(id: "tt1", type: "movie", name: "Seen"), MetaPreview(id: "tt2", type: "movie", name: "New")]
        }, ranker: Ranker(calls: calls), watched: { ["movie/tt1"] })
        #expect(await service.titles(for: "dramas I haven't watched").map(\.name) == ["New"])
    }

    @Test func partialResultsStayVisibleWhileLaterWorkRunsAndCannotReturnAfterClearing() async throws {
        let gate = Gate()
        let calls = Calls()
        let item = MetaPreview(id: "tt1", type: "movie", name: "A Comedy", releaseInfo: "1995")
        let service = DescribedSearchService(interpreter: Interpreter(answer: AISearchPlan(filters: .reading("90s comedy")), calls: calls),
            keywords: { _ in [] }, titles: { _ in [] }, pageTitles: { query, _ in
                if query.kind == .movie { return [item] }
                await gate.wait() // Deliberately ignores cancellation like a slow network/cache callback.
                return []
            })
        let client = AddonClient()
        let services = AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client),
                                   client: client)
        let model = SearchViewModel(services: services, debounce: .milliseconds(1), describer: service, usesLivePicker: false)
        model.query = "90s comedy"
        model.queryDidChange()
        try await waitUntil { model.describedItems == [item] }
        #expect(model.aiPhase == .searching)
        model.query = ""
        model.queryDidChange()
        await gate.release()
        await model.waitUntilDone()
        #expect(model.describedItems.isEmpty && model.aiPhase == .idle)
    }

    @Test func aCombinedPersonRequestChecksGenreLanguageAndScoreToo() async throws {
        let calls = Calls()
        let data = Data(#"{"title":"Wrong Genre","imdb_id":"tt1234567","original_language":"en","genres":[{"name":"Horror"}],"vote_average":5,"vote_count":10}"#.utf8)
        let metadata = try #require(try TMDbSearchMetadata.parse(data, mediaType: "movie"))
        let plan = AISearchPlan(filters: DescribedSearch(kind: .movie, genres: ["Comedy"], minimumScore: 7),
                                people: [.init(name: "Requested Actor", role: .cast)], language: "fr", requiresSemanticRanking: false)
        let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { _ in [] },
            titles: { _ in [] }, peopleTitles: { _, _ in [AISearchCandidate(item: metadata.item, evidence: "cast: Requested Actor", metadata: metadata)] })
        #expect(await service.titles(for: "highly rated French comedies starring Requested Actor").isEmpty)
    }

    /// TMDb has tagged each of these with the one topic asked for, and the words ask for nothing a synopsis would have to show, so
    /// they are shown before the model's reading and the model checks none of them (it rejected real heist comedies for "funny heist
    /// movies" on 17 Oct). The topic pool still comes first and no generic popularity page is asked for.
    @Test func themeMatchesGetTheFirstSlotsAndFinishBeforeGenericPopularityPages() async {
        let calls = Calls()
        var plan = AISearchPlan(filters: DescribedSearch(kind: .movie, genres: ["Comedy"], moods: ["bank robbery"]))
        plan.trustsTopicMatches = true // as the reading of these words sets it: nothing in them is a feel
        let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { _ in
            [.init(id: 100, name: "bank robbery")]
        }, titles: { query in
            await calls.query(query)
            #expect(!query.keywords.isEmpty, "a useful theme pool must finish without generic pages spending the model budget")
            return (1...24).map {
                MetaPreview(id: "tt\($0)", type: "movie", name: "Heist Comedy \($0)", description: "An inept gang robs a bank.")
            }
        }, ranker: Ranker(calls: calls))
        let items = await service.titles(for: "comedies about bank robberies") { await calls.update($0) }
        #expect(items.count == 24)
        #expect(Set(await calls.queries.map(\.kind)) == [.movie, .series], "a search that names no kind asks for films and series")
        #expect(await calls.ranks == 0, "titles tagged with every requested topic need no synopsis check")
        let snapshots = await calls.updates.filter { !$0.items.isEmpty }.map(\.items)
        #expect(snapshots.allSatisfy { $0.allSatisfy { $0.name.hasPrefix("Heist Comedy") } })
    }

    @Test func laterPagesSurviveMissingIMDbIdentitiesInAnEarlierWindow() async {
        let calls = Calls()
        let plan = AISearchPlan(filters: DescribedSearch(kind: .movie, genres: ["Drama"], moods: ["isolation"]))
        let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { _ in [] },
            titles: { _ in [] }, ranker: Ranker(calls: calls), pageTitles: { query, skip in
                await calls.query(query)
                guard skip < 24 else { return [] }
                // Only one of the twelve database entries in each window has an IMDb identity.
                return [MetaPreview(id: "tt\(skip + 1)", type: "movie", name: "Isolated \(skip)", description: "A solitary journey.")]
            })
        let items = await service.titles(for: "dramas about isolation")
        #expect(items.map(\.name) == ["Isolated 0", "Isolated 12"])
        #expect(await calls.queries.count == 3)
    }

    @Test func aSlowMovieRequestCannotHideTheFirstSeriesResult() async {
        let gate = Gate()
        let calls = Calls()
        let show = MetaPreview(id: "tt1", type: "series", name: "A 90s Comedy", releaseInfo: "1995")
        let service = DescribedSearchService(interpreter: WaitingInterpreter(gate: gate), keywords: { _ in [] }, titles: { query in
            if query.kind == .movie { await gate.wait(); return [] }
            return [show]
        })
        let result = await service.titles(for: "90s comedy") { update in
            await calls.update(update)
            if update.items.contains(show) { await gate.release() }
        }
        #expect(result == [show])
        #expect(await calls.updates.contains { $0.items == [show] && $0.stage != .complete })
    }

    private struct FailingRanker: CandidateRanking {
        let calls: Calls
        struct Refused: Error {}
        func rank(request: String, references: [String], candidates: [String], watched: [String]) async throws -> [RankedCandidate] {
            await calls.rank()
            throw Refused()
        }
    }

    @Test func modelFailuresHaveOneSearchWideBudgetAndAVisibleRetryState() async {
        let calls = Calls()
        let plan = AISearchPlan(filters: DescribedSearch(genres: ["Crime"], moods: ["paranoia"]))
        let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { _ in [] },
            titles: { _ in [] }, ranker: FailingRanker(calls: calls), pageTitles: { query, skip in
                (skip..<(skip + DescribedSearchService.batchSize)).map {
                    MetaPreview(id: "tt\(query.kind.rawValue)\($0)", type: query.kind == .movie ? "movie" : "series",
                                name: "Crime \($0)", description: "A paranoid investigation.")
                }
            })
        #expect(await service.titles(for: "crime stories about paranoia") { await calls.update($0) }.isEmpty)
        #expect(await calls.ranks <= DescribedSearchService.rankingAttemptLimit)
        #expect(await calls.updates.last?.issue == .ranking)
        #expect(await calls.updates.last?.stage == .complete)
    }

    @Test func databaseFailuresAreDifferentFromAnEmptyRecommendationList() async {
        let calls = Calls()
        let service = DescribedSearchService(interpreter: KeywordDescriptionInterpreter(), keywords: { _ in [] }, titles: { _ in
            throw WidgetSourceError.needsTMDbToken
        })
        #expect(await service.titles(for: "90s comedy") { await calls.update($0) }.isEmpty)
        #expect(await calls.updates.last?.issue == .needsTMDbToken)
    }

    @Test func submittingAnInFlightQueryDoesNotRestartOnDeviceInference() async {
        let calls = Calls()
        let gate = Gate()
        let service = DescribedSearchService(interpreter: WaitingInterpreter(gate: gate, calls: calls),
                                             keywords: { _ in [] }, titles: { _ in [] })
        let client = AddonClient()
        let services = AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client),
                                   client: client)
        let model = SearchViewModel(services: services, debounce: .milliseconds(1), describer: service, usesLivePicker: false)
        model.query = "dark crime movies"
        model.queryDidChange()
        await calls.waitForPlan()
        await model.submit()
        await gate.release()
        await model.waitUntilDone()
        #expect(await calls.plans == 1)
        #expect(model.aiPhase == .done)
    }

    @Test func rankingSeesStoryEvidenceBeyondTheOldSynopsisCutoff() {
        let introduction = String(repeating: "A seemingly ordinary day. ", count: 12)
        let item = MetaPreview(id: "tt1", type: "movie", name: "A Story", description: introduction + "A bank robbery changes everything.")
        #expect(DescribedSearchService.line(item).contains("bank robbery"))
    }

    @Test func cachedSelectionsCannotFollowReorderedCandidatesOrOutliveTheirExpiry() async {
        let cache = AISearchInferenceCache()
        let date = Date(timeIntervalSince1970: 1_000)
        let key = AISearchInferenceCache.RankingKey(request: "tense crime", references: [], candidates: ["First", "Second"], watched: [])
        let reordered = AISearchInferenceCache.RankingKey(request: "tense crime", references: [], candidates: ["Second", "First"], watched: [])
        await cache.store([2], for: key, at: date)
        #expect(await cache.ranking(for: key, at: date) == [2])
        #expect(await cache.ranking(for: reordered, at: date) == nil, "a candidate number is valid only for the identical input list")
        #expect(await cache.ranking(for: key, at: date.addingTimeInterval(901)) == nil)
    }

    @Test func failedAISearchCanRetryWithoutRestartingTheNormalSearch() async {
        let calls = Calls()
        let item = MetaPreview(id: "tt1", type: "movie", name: "Recovered")
        let plan = AISearchPlan(filters: DescribedSearch(kind: .movie, genres: ["Crime"]), requiresSemanticRanking: false)
        let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { _ in [] }, titles: { _ in
            if await calls.nextFetch() == 1 { throw WidgetSourceError.addon(.invalidJSON) }
            return [item]
        })
        let client = AddonClient()
        let services = AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client),
                                   client: client)
        let model = SearchViewModel(services: services, describer: service, usesLivePicker: false)
        model.query = "dark crime films"
        await model.submit()
        await model.waitUntilDone()
        #expect(model.aiIssue == .database)
        #expect(!model.showsNoResults, "a failed database request does not prove there are no matches")
        #expect(model.phase == .done)
        model.retryAI()
        #expect(model.phase == .done && model.aiPhase == .searching)
        await model.waitUntilDone()
        #expect(model.describedItems == [item])
        #expect(model.aiIssue == nil)
    }

    private struct InvalidNumbersRanker: CandidateRanking {
        func rank(request: String, references: [String], candidates: [String], watched: [String]) async throws -> [RankedCandidate] {
            [Int.min, 0, 2, 2, 99, 1].map { RankedCandidate(number: $0, reason: "") }
        }
    }

    @Test func modelSelectionsCannotInventTitlesDuplicateCardsOrOverflowAnIndex() async {
        let calls = Calls()
        let movies = [MetaPreview(id: "tt1", type: "movie", name: "First"), MetaPreview(id: "tt2", type: "movie", name: "Second")]
        let plan = AISearchPlan(filters: DescribedSearch(kind: .movie, genres: ["Drama"], moods: ["isolation"]))
        let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { _ in [] },
                                             titles: { _ in movies }, ranker: InvalidNumbersRanker())
        #expect(await service.titles(for: "dramas about isolation").map(\.name) == ["Second", "First"])
    }

    @Test func knownGenreConflictsAreRejectedBeforeTheModelAndTVGenresUseTheirOwnIDs() async {
        let calls = Calls()
        let films = [MetaPreview(id: "tt1", type: "movie", name: "Wrong", genres: ["Romance"]),
                     MetaPreview(id: "tt2", type: "movie", name: "Right", genres: ["Comedy"])]
        let plan = AISearchPlan(filters: DescribedSearch(kind: .movie, genres: ["Comedy"], moods: ["quirky"]))
        let service = DescribedSearchService(interpreter: Interpreter(answer: plan, calls: calls), keywords: { _ in [] },
                                             titles: { _ in films }, ranker: Ranker(calls: calls))
        #expect(await service.titles(for: "quirky comedies").map(\.name) == ["Right"])

        let show = MetaPreview(id: "tt3", type: "series", name: "A Science Fiction Show", genres: ["Sci-Fi & Fantasy"])
        let tvPlan = AISearchPlan(filters: DescribedSearch(kind: .series, genres: ["Science Fiction"], moods: ["cerebral"]))
        let tvService = DescribedSearchService(interpreter: Interpreter(answer: tvPlan, calls: calls), keywords: { _ in [] },
                                               titles: { _ in [show] }, ranker: Ranker(calls: calls))
        #expect(await tvService.titles(for: "cerebral sci-fi series") == [show])
    }

    @Test func titleWordsDoNotBecomeGenreScoreOrRuntimeRequirements() async {
        let words = AISearchGrounding.plan(ModelReading(referenceTitles: ["War of the Worlds"]),
                                           for: "funny films like War of the Worlds under two hours").filters
        #expect(words.genres == ["Comedy"] && words.maximumRuntime == 120)
        let titles = AISearchGrounding.plan(ModelReading(titleQueries: ["Best in Show", "Short Term 12"]),
                                            for: "Best in Show and Short Term 12").filters
        #expect(titles.minimumScore == nil && titles.maximumRuntime == nil)

        let calls = Calls()
        let film = MetaPreview(id: "tt1", type: "movie", name: "War of the Worlds", genres: ["Science Fiction"])
        let service = DescribedSearchService(interpreter: KeywordDescriptionInterpreter(), keywords: { _ in [] }, titles: { query in
            await calls.query(query)
            return []
        }, ranker: Ranker(calls: calls, rejectAll: true), titleMatches: { _ in [film] })
        #expect(await service.titles(for: "War of the Worlds") == [film])
        #expect(await calls.ranks == 0)
        #expect(await calls.queries.isEmpty)
    }
}
