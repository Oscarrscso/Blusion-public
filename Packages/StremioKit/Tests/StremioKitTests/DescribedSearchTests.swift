import Foundation
import Testing
@testable import StremioKit

@Suite struct DescribedSearchTests {
    @Test func aDescriptionBecomesTMDbFilters() {
        let search = DescribedSearch(kind: .movie, genres: ["Science Fiction", "thriller", "Made Up"], excludedGenres: ["Horror"],
                                     latestYear: 2009, minimumScore: 7.5, maximumRuntime: 120)
        let query = search.query(keywords: [TMDbDiscoverQuery.Named(id: 1, name: "dark")])
        #expect(query.kind == .movie && !query.spansBothKinds)
        #expect(query.genres.map(\.id) == [878, 53], "an unknown genre is dropped")
        #expect(query.excludedGenres.map(\.id) == [27])
        #expect(query.keywords.map(\.id) == [1])
        #expect(query.releasedFrom == nil && query.releasedTo == "2009-12-31")
        #expect(query.minimumScore == 7.5 && query.minimumVotes == 300, "a score asks for enough votes to mean something")
        #expect(query.maximumRuntime == 120)
    }

    @Test func eitherKindAsksForBothAndSwappedYearsAreOrdered() {
        let query = DescribedSearch(genres: ["drama"], earliestYear: 2010, latestYear: 1990).query(keywords: [])
        #expect(query.spansBothKinds)
        #expect(query.releasedFrom == "1990-01-01" && query.releasedTo == "2010-12-31")
        #expect(DescribedSearch(kind: .series, genres: ["Science Fiction"]).query(keywords: []).genres.map(\.id) == [10765],
                "TV's genre for science fiction")
    }

    @Test func eitherKindStaysWithFilmsWhenAGenreDiffersForTV() {
        #expect(!DescribedSearch(genres: ["Science Fiction"]).query(keywords: []).spansBothKinds, "TV has no genre 878")
        #expect(!DescribedSearch(excludedGenres: ["Horror"]).query(keywords: []).spansBothKinds)
        #expect(DescribedSearch(genres: ["Comedy"]).query(keywords: []).spansBothKinds)
        #expect(DescribedSearch(minimumScore: 75).query(keywords: []).minimumScore == 7.5, "a score out of 100 is read out of 10")
    }

    @Test func theKeywordReaderReadsTheExample() {
        let search = DescribedSearch.reading("Find a dark, atmospheric sci-fi film from before 2010 with great reviews.")
        #expect(search.kind == .movie)
        #expect(search.genres == ["Science Fiction"])
        #expect(search.latestYear == 2009 && search.earliestYear == nil)
        #expect(search.minimumScore == 7.5)
        #expect(search.moods == ["dark", "atmospheric"])
        #expect(DescribedSearch.reading("a 90s comedy under two hours").earliestYear == 1990)
        #expect(DescribedSearch.reading("a 90s comedy under two hours").maximumRuntime == 120)
        #expect(DescribedSearch.reading("Inception").isEmpty)
        let eighties = DescribedSearch.reading("80s dark gritty")
        #expect(eighties.earliestYear == 1980 && eighties.latestYear == 1989 && eighties.moods == ["dark", "gritty"])
    }

    @Test func theWordsCorrectAModelThatPutsAYearAtTheWrongEnd() {
        // The on-device model read "before 2010" as an earliest year of 2009 on the Mac (16 Oct).
        let model = DescribedSearch(kind: .movie, genres: ["Science Fiction"], earliestYear: 2009, moods: ["dark"])
        let text = "a dark, atmospheric sci-fi film from before 2010 with great reviews"
        let corrected = model.correcting(with: .reading(text))
        #expect(corrected.earliestYear == nil && corrected.latestYear == 2009)
        #expect(corrected.minimumScore == 7.5 && corrected.genres == ["Science Fiction"] && corrected.moods == ["dark"])
        #expect(model.correcting(with: .reading("dark sci-fi films about space")) == model, "no years in the words: the model's stand")
    }

    @Test func explicitComedyAndBrothersSurviveAnIncorrectModelInterpretation() {
        let request = "funny movies about brothers"
        let words = DescribedSearch.reading(request)
        #expect(words.genres == ["Comedy"])
        #expect(words.moods.first == "brothers")
        let model = DescribedSearch(kind: .movie, genres: ["Romance"], moods: [])
        let corrected = model.correcting(with: words)
        #expect(corrected.genres == ["Comedy"])
        #expect(corrected.moods.contains("brothers"))
        #expect(DescribedSearch.readsLikeDescription(request))
        #expect(DescribedSearch.readsLikeDescription("dark gritty crime"))
    }

    @Test func onlyADescriptionReadsLikeOne() {
        #expect(DescribedSearch.readsLikeDescription("a dark, atmospheric sci-fi film from before 2010 with great reviews"))
        #expect(DescribedSearch.readsLikeDescription("funny shows about a family"))
        #expect(!DescribedSearch.readsLikeDescription("Inception"))
        #expect(!DescribedSearch.readsLikeDescription("The Lord of the Rings"))
        #expect(DescribedSearch.readsLikeDescription("sci-fi film"), "explicit filters don't become title searches because they are short")
        #expect(DescribedSearch.readsLikeDescription("80s dark gritty"), "three description words in three")
        #expect(DescribedSearch.readsLikeDescription("80s dark grity"), "a decade and a mood in three words, a typo besides")
        #expect(!DescribedSearch.readsLikeDescription("Scary Movie 2"))
        #expect(!DescribedSearch.readsLikeDescription("The Dark Knight"))
        #expect(!DescribedSearch.readsLikeDescription("The Dark Knight Rises"))
        #expect(!DescribedSearch.readsLikeDescription("War of the Worlds"))
        #expect(!DescribedSearch.readsLikeDescription("The Girl with the Dragon Tattoo"))
    }

    @Test(arguments: ["90s comedy", "80s horror", "2000s sci-fi", "drama before 2010", "comedy under two hours"])
    func shortExplicitFiltersAreRecognisedAcrossGenresAndYears(_ text: String) {
        #expect(DescribedSearch.isFilterOnly(text))
        #expect(DescribedSearch.readsLikeDescription(text))
    }

    @Test func storyRequirementsAreNeverReducedToOnlyTheirGenre() {
        #expect(!DescribedSearch.isFilterOnly("90s comedy about brothers"))
        #expect(!DescribedSearch.isFilterOnly("dark gritty crime"))
        #expect(!DescribedSearch.isFilterOnly("The Dark Knight"))
        let words = DescribedSearch.reading("comedy without romance")
        #expect(words.genres == ["Comedy"])
        #expect(words.excludedGenres == ["Romance"])
        let corrected = DescribedSearch(genres: ["Comedy", "Romance"]).correcting(with: words)
        #expect(corrected.genres == ["Comedy"] && corrected.excludedGenres == ["Romance"])
    }
}
