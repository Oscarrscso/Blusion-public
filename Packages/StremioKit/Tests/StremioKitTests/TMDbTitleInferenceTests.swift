import Foundation
import Testing
@testable import StremioKit

/// The filters read from a Fusion TMDb list's title, for the lists whose exports carry none.
@Suite struct TMDbTitleInferenceTests {
    @Test func aTitleNamingAGenreFiltersByItsTMDbID() {
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Horror") == TMDbDiscoverQuery(genres: [.init(id: 27, name: "Horror")]))
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Westerns") == TMDbDiscoverQuery(genres: [.init(id: 37, name: "Western")]))
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Popular Sci-Fi Movies")
            == TMDbDiscoverQuery(genres: [.init(id: 878, name: "Science Fiction")]))
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Top Documentaries") == TMDbDiscoverQuery(genres: [.init(id: 99, name: "Documentary")]))
    }

    @Test func aTVTitleUsesTMDbsTVGenres() {
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Sci-Fi TV") == TMDbDiscoverQuery(kind: .series, genres: [.init(id: 10765, name: "Sci-Fi & Fantasy")]))
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Westerns TV") == TMDbDiscoverQuery(kind: .series, genres: [.init(id: 37, name: "Western")]))
    }

    @Test func aGenreTVDoesNotHaveIsLeftOutOfATVTitle() {
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Horror TV") == TMDbDiscoverQuery(kind: .series))
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Romance Series") == TMDbDiscoverQuery(kind: .series))
    }

    @Test func aGenreNamedTwiceIsKeptOnce() {
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Sci-Fi & Fantasy TV").genres == [.init(id: 10765, name: "Sci-Fi & Fantasy")])
    }

    @Test func genresNamedTogetherAreAllKeptInTMDbsOrder() {
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "History & War").genres
            == [.init(id: 36, name: "History"), .init(id: 10752, name: "War")])
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Sci-Fi & Fantasy").genres
            == [.init(id: 14, name: "Fantasy"), .init(id: 878, name: "Science Fiction")])
    }

    @Test func aDecadeIsTheReleaseWindow() {
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "1980s TV") == TMDbDiscoverQuery(kind: .series, releasedFrom: "1980-01-01", releasedTo: "1989-12-31"))
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "2010s TV").releasedFrom == "2010-01-01")
    }

    @Test func decadesWrittenWithAnApostropheOrTwoDigitsAreRead() {
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "1980's TV").releasedFrom == "1980-01-01")
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "80s Movies")
            == TMDbDiscoverQuery(genres: [], releasedFrom: "1980-01-01", releasedTo: "1989-12-31"))
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "00s Movies").releasedFrom == "2000-01-01")
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "10s TV").releasedFrom == "2010-01-01")
    }

    @Test func aTitleNamingFilmsAndTVReadsAsFilms() {
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Popular Movies & TV") == TMDbDiscoverQuery())
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Horror Movies TV") == TMDbDiscoverQuery(genres: [.init(id: 27, name: "Horror")]))
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Film Noir TV") == TMDbDiscoverQuery(kind: .series))
    }

    @Test func newClassicAcclaimedAndHiddenGemsSetTheOrderOrTheBounds() {
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "New TV Series") == TMDbDiscoverQuery(kind: .series, ordering: .newest))
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Trending Horror").ordering == .trendingThisWeek)
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Trending Horror Today").ordering == .trendingToday)
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Classic Animation Movies")
            == TMDbDiscoverQuery(genres: [.init(id: 16, name: "Animation")], releasedTo: "1999-12-31"))
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Critically Acclaimed Movies") == TMDbDiscoverQuery(minimumScore: 7.5, minimumVotes: 1000))
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Hidden Gems") == TMDbDiscoverQuery(minimumScore: 7.0, minimumVotes: 100))
    }

    @Test func aTitleWithNoCluesIsThePopularFilms() {
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Most Popular Movies") == TMDbDiscoverQuery())
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "") == TMDbDiscoverQuery())
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Family-Friendly") == TMDbDiscoverQuery(genres: [.init(id: 10751, name: "Family")]))
    }

    @Test func aWordInsideAnotherWordIsNotAGenre() {
        // Words match whole, so "war" does not match "Warriors".
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Warriors") == TMDbDiscoverQuery())
    }

    @Test func adultAnimationNamesTheKeywordAndLeavesOutAnimeAndHentai() {
        // TMDb's "adult animation" keyword is what Fusion's list is built on; The Simpsons carries it where its genre alone does not reach the list.
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Adult Animation")
            == TMDbDiscoverQuery(genres: [.init(id: 16, name: "Animation")],
                                 keywords: [.init(id: 161919, name: "adult animation")],
                                 excludedKeywords: [.init(id: 210024, name: "anime"), .init(id: 198385, name: "hentai")],
                                 excludedGenres: [.init(id: 10751, name: "Family")], spansBothKinds: true))
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Animation").keywords.isEmpty, "a plain animation list names no keyword")
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Non-Adult Animation").keywords.isEmpty, "a negated adult animation names no keyword")
    }

    @Test func adultAnimationLeavesOutTheFamilyTitlesAndForTVTheKidsShows() {
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Adult Animation")
            == TMDbDiscoverQuery(genres: [.init(id: 16, name: "Animation")],
                                 keywords: [.init(id: 161919, name: "adult animation")],
                                 excludedKeywords: [.init(id: 210024, name: "anime"), .init(id: 198385, name: "hentai")],
                                 excludedGenres: [.init(id: 10751, name: "Family")], spansBothKinds: true))
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Adult Animation TV")
            == TMDbDiscoverQuery(kind: .series, genres: [.init(id: 16, name: "Animation")],
                                 keywords: [.init(id: 161919, name: "adult animation")],
                                 excludedKeywords: [.init(id: 210024, name: "anime"), .init(id: 198385, name: "hentai")],
                                 excludedGenres: [.init(id: 10751, name: "Family"), .init(id: 10762, name: "Kids")]))
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Adult-Animation Movies").excludedGenres == [.init(id: 10751, name: "Family")])
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Animation").excludedGenres.isEmpty)
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Adults Only").excludedGenres.isEmpty, "only the words adult animation count")
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Adult Animated Movies").excludedGenres == [.init(id: 10751, name: "Family")])
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Non-Adult Animation").excludedGenres.isEmpty, "a negated adult animation is not left out")
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Animation without adult animation").excludedGenres.isEmpty)
    }

    @Test func aFamilyGenreTheTitleNamesIsNotLeftOut() {
        // Naming animation with neither films nor shows asks for both kinds, so the list holds shows as well (see `spansBothKinds`).
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Family Adult Animation")
            == TMDbDiscoverQuery(genres: [.init(id: 16, name: "Animation"), .init(id: 10751, name: "Family")],
                                 keywords: [.init(id: 161919, name: "adult animation")],
                                 excludedKeywords: [.init(id: 210024, name: "anime"), .init(id: 198385, name: "hentai")],
                                 spansBothKinds: true))
    }

    @Test func aTitleReadFromFusionWritesBackAsBlusionsQuery() throws {
        let widget = HomeWidget(title: "Horror", content: .row(RowConfiguration(source: .tmdbDiscover(.inferred(fromTitle: "Horror")))))
        let data = try FusionWidgetCodec.encode([widget])
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"blusion.tmdbDiscover\""))
        let read = try FusionWidgetCodec.decode(data, installed: [])
        #expect(read.widgets == [widget])
    }
}
