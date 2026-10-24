import Foundation
import Testing
@testable import StremioKit
@testable import Features

/// The model readings here are what Apple's on-device model returned for these searches on 17 Oct 2026, before grounding.
@Suite struct AISearchGroundingTests {
    private let now = Date(timeIntervalSince1970: 1_792_224_000) // 17 Oct 2026

    private func plan(_ text: String, _ reading: ModelReading = ModelReading()) -> AISearchPlan {
        AISearchGrounding.plan(reading, for: text, now: now)
    }

    @Test func aReleaseWindowTheWordsNeverGaveIsDropped() {
        let plan = plan("funny heist movies", ModelReading(themes: ["heist", "funny"]))
        #expect(plan.filters.earliestYear == nil && plan.filters.latestYear == nil, "the model gave 2000–2010")
        #expect(plan.filters.genres == ["Comedy"])
        #expect(plan.filters.kind == .movie)
        #expect(plan.filters.moods == ["heist"])
        #expect(plan.titleQueries.isEmpty && plan.referenceTitles.isEmpty)
    }

    @Test func genresTheWordsNeverGaveAreDroppedAndTheLanguageIsRead() {
        let plan = plan("Japanese samurai films with great reviews", ModelReading(themes: ["samurai", "historical"]))
        #expect(plan.filters.genres.isEmpty, "the model gave Action, Adventure and War, so TMDb had nothing")
        #expect(plan.language == "ja")
        #expect(plan.filters.moods == ["samurai"])
        #expect(plan.filters.minimumScore != nil)
        #expect(plan.filters.earliestYear == nil && plan.filters.latestYear == nil)
    }

    @Test func titlesAndReferencesTheWordsNeverNamedAreDroppedButThePersonIsKept() {
        let reading = ModelReading(themes: ["emotional depth", "character-driven storytelling"], titleQueries: ["Forrest Gump"],
                                   referenceTitles: ["Toy Story"], cast: ["Tom Hanks"])
        let plan = plan("Tom Hanks movies from the 90s", reading)
        #expect(plan.titleQueries.isEmpty)
        #expect(plan.referenceTitles.isEmpty)
        #expect(plan.people == [AISearchPlan.Person(name: "Tom Hanks", role: .cast)])
        #expect(plan.filters.earliestYear == 1990 && plan.filters.latestYear == 1999)
        #expect(plan.filters.moods.isEmpty)
        #expect(!plan.requiresSemanticRanking)
    }

    @Test func aTitleAloneIsSearchedAsATitleWithNothingAdded() {
        let reading = ModelReading(themes: ["Honor and duty", "Cultural ritual"], titleQueries: ["Harakiri"], referenceTitles: ["Bushido"])
        let plan = plan("Harakiri", reading)
        #expect(plan.titleQueries == ["Harakiri"])
        #expect(plan.referenceTitles.isEmpty)
        #expect(plan.filters.genres.isEmpty, "the model gave Drama and War, which hid Harakiri itself")
        #expect(plan.filters.moods.isEmpty)
        #expect(!plan.requiresSemanticRanking)
    }

    @Test func aMisspelledTitleTakesTheModelsSpelling() {
        #expect(plan("Hara kiri", ModelReading(titleQueries: ["Harakiri"])).titleQueries == ["Harakiri"])
        #expect(plan("Hara kiri", ModelReading(titleQueries: ["The Seven Samurai"])).titleQueries == ["Hara kiri"])
    }

    @Test func aReferenceIsNeverAlsoAResultAndTheRestIsRead() {
        let reading = ModelReading(themes: ["tense", "unresolved"], titleQueries: ["Prisoners"], referenceTitles: ["Prisoners"])
        let plan = plan("something like Prisoners but less depressing, under two hours", reading)
        #expect(plan.referenceTitles == ["Prisoners"])
        #expect(plan.titleQueries.isEmpty)
        #expect(plan.filters.maximumRuntime == 120)
        #expect(plan.filters.genres.isEmpty, "the model gave Crime, Thriller and Mystery")
        #expect(plan.requiresSemanticRanking)
        #expect(!plan.trustsTopicMatches)
    }

    @Test func theWordsAfterLikeStandInWhenTheModelNamesNoReference() {
        #expect(plan("something like Heat").referenceTitles == ["Heat"])
        #expect(plan("films like The Thing but funnier").referenceTitles == ["The Thing"])
        #expect(plan("films similar to Alien movies").referenceTitles == ["Alien"])
        #expect(plan("funny heist movies", ModelReading(referenceTitles: ["Ocean's Eleven"])).referenceTitles.isEmpty)
    }

    @Test func aThemeAndItsOwnWordsAreOneTheme() {
        let plan = plan("time travel series", ModelReading(themes: ["travel", "time", "time travel"]))
        #expect(plan.filters.moods == ["time travel"])
        #expect(plan.filters.kind == .series)
        #expect(plan.filters.earliestYear == nil && plan.filters.latestYear == nil, "the model gave 1960–2019")
        #expect(plan.trustsTopicMatches)
    }

    @Test func aDecadeAndMoodWordsAreKept() {
        let plan = plan("80s dark gritty", ModelReading(themes: ["dark", "gritty"]))
        #expect(plan.filters.earliestYear == 1980 && plan.filters.latestYear == 1989)
        #expect(plan.filters.genres.isEmpty, "the model gave Crime and Thriller")
        #expect(plan.filters.moods.contains("gritty"))
        #expect(plan.requiresSemanticRanking)
        #expect(!plan.trustsTopicMatches)
    }

    @Test func themesThatShareNoWordWithTheSearchAreDropped() {
        let sciFi = plan("dark atmospheric sci-fi before 2010 with great reviews", ModelReading(themes: ["dark atmosphere", "time travel"]))
        #expect(!sciFi.filters.moods.contains("time travel"))
        #expect(sciFi.filters.genres == ["Science Fiction"])
        #expect(sciFi.filters.latestYear == 2009)
        let brothers = plan("feel-good films about brothers", ModelReading(themes: ["brothers", "family bonding"]))
        #expect(brothers.filters.moods.contains("brothers"))
        #expect(!brothers.filters.moods.contains("family bonding"))
        #expect(brothers.filters.earliestYear == nil && brothers.filters.latestYear == nil, "the model gave 1990–2009")
        #expect(brothers.requiresSemanticRanking, "feel-good is a feel only a synopsis can show")
    }

    @Test func aGenreTheModelCallsAThemeIsNotATheme() {
        let plan = plan("slow burn psychological horror", ModelReading(themes: ["slow burn", "horror", "psychological"]))
        #expect(plan.filters.genres == ["Horror"])
        #expect(!plan.filters.moods.contains("horror"))
        #expect(plan.filters.moods.contains("slow burn"))
        #expect(plan.filters.earliestYear == nil && plan.filters.latestYear == nil, "the model gave 2001–2009")
    }

    @Test func peopleAndStudiosAreKeptOnlyWhenNamed() {
        let nolan = plan("movies directed by Christopher Nolan", ModelReading(titleQueries: ["Inception"], directors: ["Christopher Nolan"]))
        #expect(nolan.people == [AISearchPlan.Person(name: "Christopher Nolan", role: .director)])
        #expect(nolan.titleQueries.isEmpty)
        let ghibli = plan("ghibli films", ModelReading(companies: ["Studio Ghibli"]))
        #expect(ghibli.companies == ["Studio Ghibli"])
        let guessed = plan("cosy animated films", ModelReading(cast: ["Tom Hanks"], companies: ["Pixar"]))
        #expect(guessed.people.isEmpty && guessed.companies.isEmpty)
        #expect(guessed.filters.genres == ["Animation"])
    }

    @Test func aTopicIsRuledOutOnlyWhenTheWordsRuleItOut() {
        let without = plan("space movies without aliens", ModelReading(themes: ["space", "aliens"], excludedTopics: ["aliens"]))
        #expect(without.excludedTopics == ["aliens"])
        #expect(!without.filters.moods.contains("aliens"))
        #expect(plan("heist movies", ModelReading(excludedTopics: ["violence"])).excludedTopics.isEmpty)
    }

    @Test func wordsThatCouldBeATitleAreATopicWhenTheModelReadsOne() {
        let topic = plan("time travel", ModelReading(themes: ["time travel"]))
        #expect(topic.titleQueries.isEmpty)
        #expect(topic.filters.moods == ["time travel"])
        #expect(plan("Harakiri").titleQueries == ["Harakiri"], "with no reading at all, the words are searched as a title")
        #expect(plan("Harakiri").titlesFromWords)
        #expect(plan("Harakiri", ModelReading(titleQueries: ["Harakiri"])).titlesFromWords, "the model gave the words back as the title")
        #expect(!plan("Hara kiri", ModelReading(titleQueries: ["Harakiri"])).titlesFromWords, "a title the model spelt out itself")
    }

    /// The model gave these back as title names on 17 Oct, and each search found a film of that name or nothing.
    @Test func aDescriptionGivenBackAsATitleIsNotSearchedAsOne() {
        let sad = plan("sad movies", ModelReading(titleQueries: ["sad movies"]))
        #expect(sad.titlesFromWords && sad.titleSequelsOnly, "only a film of that very name stands for the title")
        #expect(sad.filters.moods == ["sad"], "the feel word is what the search is about")
        #expect(sad.requiresSemanticRanking)
        let best = plan("best movies of 2023", ModelReading(titleQueries: ["best movies of 2023"]))
        #expect(best.filters.earliestYear == 2023 && best.filters.latestYear == 2023)
        let scary = plan("Scary Movie", ModelReading(titleQueries: ["Scary Movie"]))
        #expect(scary.titleQueries == ["Scary Movie"] && scary.titlesFromWords, "a real title the model gave back stays the title")
        #expect(AISearchGrounding.mightBeTitle("1917"))
        #expect(plan("1917", ModelReading(titleQueries: ["1917"])).titleQueries == ["1917"])
        #expect(plan("Christmas movies", ModelReading(titleQueries: ["Christmas movies"])).filters.moods == ["christmas"])
        #expect(plan("best movies of 2023", ModelReading(themes: ["2023"])).filters.moods.isEmpty, "a year is no theme")
        #expect(plan("anime", ModelReading(titleQueries: ["anime"])).titleQueries.isEmpty, "no films called Anime")
        let anime = plan("anime")
        #expect(anime.language == "ja" && anime.filters.genres == ["Animation"] && anime.titleQueries.isEmpty)
        #expect(!AISearchGrounding.mightBeTitle("something to watch tonight"))
        #expect(AISearchGrounding.mightBeTitle("Her"), "one word of filler can still be a film")
    }

    @Test func whoIsWatchingAndTheOrderOfLanguagesAreRead() {
        #expect(plan("a comedy to watch with my girlfriend").filters.moods.isEmpty)
        #expect(plan("korean anime").language == "ko")
    }

    @Test func wordsTheModelLeftOutAreStillTheTheme() {
        #expect(plan("mind bending films").filters.moods == ["mind bending"])
        let scary = plan("scary movies", ModelReading(themes: ["scary"]))
        #expect(scary.filters.genres == ["Horror"])
        #expect(scary.filters.moods.isEmpty, "scary only says horror, so the list is horror films, not ones a synopsis calls scary")
    }

    @Test func aFeelIsNotAReference() {
        #expect(plan("films that feel like a warm hug").referenceTitles.isEmpty)
        #expect(plan("something that looks like a dream").referenceTitles.isEmpty)
        #expect(plan("films like Heat that feel like a hug").referenceTitles == ["Heat"])
        #expect(plan("something that looks like Blade Runner", ModelReading(referenceTitles: ["Blade Runner"])).referenceTitles
            == ["Blade Runner"])
    }

    @Test func aCurlyApostropheStillTakesTheTitleOutOfTheWords() {
        let plan = plan("films like Ocean\u{2019}s Eleven", ModelReading(referenceTitles: ["Ocean's Eleven"]))
        #expect(plan.referenceTitles == ["Ocean's Eleven"])
        #expect(plan.judgement.isEmpty)
    }

    @Test func eraWordsSetTheYears() {
        #expect(plan("classic westerns").filters.latestYear == 1979)
        #expect(plan("recent horror films").filters.earliestYear == 2022)
    }

    @Test func whoIsWatchingIsNotATopic() {
        #expect(AISearchGrounding.topicWords(in: "something to watch with my friends tonight").isEmpty)
        #expect(AISearchGrounding.topicPhrases(in: "funny heist movies from the 80s") == ["heist"])
        #expect(AISearchGrounding.topicPhrases(in: "time travel series") == ["time travel", "time", "travel"])
    }

    @Test func aKeywordIsTheSameTopicWithPluralsAside() {
        #expect(AISearchGrounding.isSameTopic("bank robbery", "bank robberies"))
        #expect(AISearchGrounding.isSameTopic("brother", "Brothers"))
        #expect(!AISearchGrounding.isSameTopic("brotherhood", "brothers"))
        #expect(AISearchGrounding.uncoveredTopics(in: "samurai revenge films", by: ["samurai"]) == ["revenge"])
    }
}

/// What the model checking candidates is told, where candidates are drawn from, and which credits a person search keeps.
@Suite struct AISearchCandidateTests {
    private func plan(_ text: String, _ reading: ModelReading = ModelReading()) -> AISearchPlan {
        AISearchGrounding.plan(reading, for: text, now: Date(timeIntervalSince1970: 1_792_224_000))
    }

    @Test func theJudgementIsWhatOnlyASynopsisCanShow() {
        #expect(plan("80s dark gritty").judgement == "dark gritty")
        #expect(plan("dark atmospheric sci-fi before 2010 with great reviews").judgement == "dark atmospheric")
        #expect(plan("something like Prisoners but less depressing, under two hours", ModelReading(referenceTitles: ["Prisoners"]))
            .judgement == "less depressing")
        #expect(plan("feel-good films about brothers").judgement == "feel-good brothers")
        #expect(plan("90s comedy").judgement.isEmpty)
    }

    @Test func feelWordsDrawOnTheGenresTheyImply() {
        #expect(AISearchGrounding.poolGenres(in: "80s dark gritty") == ["Thriller", "Crime"])
        #expect(AISearchGrounding.poolGenres(in: "feel-good films about brothers") == ["Comedy", "Family"])
        #expect(AISearchGrounding.poolGenres(in: "slow burn psychological") == ["Thriller", "Drama"])
        #expect(AISearchGrounding.poolGenres(in: "films about brothers").isEmpty)
    }

    @Test func aKindWithoutTheGenreIsNotAskedAndSeriesLeaveOutTalkShows() {
        let horror = AISearchPlan(filters: DescribedSearch(genres: ["Horror"])).queries(keywords: [])
        #expect(horror.map(\.kind) == [.movie])
        let horrorSeries = AISearchPlan(filters: DescribedSearch(kind: .series, genres: ["Horror"])).queries(keywords: [])
        #expect(horrorSeries.map(\.kind) == [.series], "asked for by name, series are still searched")
        let any = AISearchPlan(filters: DescribedSearch(earliestYear: 1980, latestYear: 1989)).queries(keywords: [])
        #expect(any.map(\.kind) == [.movie, .series])
        #expect(Set(any[1].excludedGenres.map(\.id)) == [10763, 10764, 10767])
        #expect(any[0].excludedGenres.isEmpty)
        let sciFi = AISearchPlan(filters: DescribedSearch(genres: ["Science Fiction"])).queries(keywords: [])
        #expect(sciFi[1].excludedGenres.contains { $0.id == 16 }, "no cartoons from Sci-Fi & Fantasy unless asked")
        let anime = AISearchPlan(filters: DescribedSearch(genres: ["Science Fiction", "Animation"])).queries(keywords: [])
        #expect(!anime[1].excludedGenres.contains { $0.id == 16 })
        #expect(!any[1].excludedGenres.contains { $0.id == 16 }, "a search without a merged genre keeps animated series")
        let series = AISearchPlan(filters: DescribedSearch(kind: .series, genres: ["Science Fiction"])).queries(keywords: [])
        #expect(!series[0].excludedGenres.contains { $0.id == 16 }, "sci-fi series keeps Rick and Morty and Arcane")
    }

    private func credit(_ type: String, _ date: String?, _ roles: [TMDbCreditRole]) -> TMDbPersonCredit {
        TMDbPersonCredit(mediaType: type, tmdbID: 1, title: "T", releaseDate: date, poster: nil, backdrop: nil, voteAverage: 7,
                         voteCount: 10, popularity: 1, roles: roles, episodeCount: nil)
    }

    @Test func aPersonSearchKeepsPartsInTheAllowedKindAndYears() {
        let nineties = DescribedSearch(kind: .movie, earliestYear: 1990, latestYear: 1999)
        #expect(DescribedSearchService.fitsFilmography(credit("movie", "1994-07-06", [.acting(character: "Forrest Gump")]), filters: nineties))
        #expect(!DescribedSearchService.fitsFilmography(credit("movie", "2026-06-19", [.acting(character: "Woody")]), filters: nineties))
        #expect(!DescribedSearchService.fitsFilmography(credit("tv", "1995-01-01", [.acting(character: "Tom")]), filters: nineties))
        #expect(!DescribedSearchService.fitsFilmography(credit("movie", nil, [.acting(character: "Tom")]), filters: nineties))
        let any = DescribedSearch()
        #expect(!DescribedSearchService.fitsFilmography(credit("tv", "1975-10-01", [.acting(character: "Self - Guest")]), filters: any))
        #expect(!DescribedSearchService.fitsFilmography(credit("tv", "1975-10-01", [.acting(character: "Himself")]), filters: any))
        #expect(DescribedSearchService.fitsFilmography(credit("movie", "2000-01-01", [.crew(job: "Director", department: "Directing")]),
                                                       filters: any))
    }
}
