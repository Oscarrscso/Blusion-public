import Testing
@testable import Features

@Suite struct ContentTypeNameTests {
    @Test func pluralNamesTheKnownTypes() {
        #expect(ContentTypeName.plural("movie") == "Movies")
        #expect(ContentTypeName.plural("series") == "Series")
        #expect(ContentTypeName.plural("anime") == "Anime")
        #expect(ContentTypeName.plural("tv") == "Live TV")
        #expect(ContentTypeName.plural("channel") == "Channels")
        #expect(ContentTypeName.plural("") == "Other")
    }

    @Test func singularNamesTheKnownTypes() {
        #expect(ContentTypeName.singular("movie") == "Movie")
        #expect(ContentTypeName.singular("series") == "Series")
        #expect(ContentTypeName.singular("anime") == "Anime")
        #expect(ContentTypeName.singular("tv") == "Channel")
        #expect(ContentTypeName.singular("channel") == "Channel")
        #expect(ContentTypeName.singular("") == "Title")
    }

    @Test func unknownTypesAreCapitalisedWithSeparatorsAsSpaces() {
        #expect(ContentTypeName.plural("anime.series") == "Anime Series")
        #expect(ContentTypeName.singular("anime.series") == "Anime Series")
        #expect(ContentTypeName.plural("my_type-x") == "My Type X")
        #expect(ContentTypeName.plural("all") == "All")
    }

    @Test func aTypeWithNothingLeftFallsBackToTheDefaultName() {
        #expect(ContentTypeName.plural("..") == "Other")
        #expect(ContentTypeName.singular("  ") == "Title")
    }

    @Test func matchingIgnoresCaseAndSurroundingSpaces() {
        #expect(ContentTypeName.plural("  Movie ") == "Movies")
        #expect(ContentTypeName.plural("TV") == "Live TV")
        #expect(ContentTypeName.sortRank(" SERIES") == 1)
        #expect(ContentTypeName.plural("  ") == "Other")
    }

    @Test func sortRankOrdersTheTabs() {
        #expect(ContentTypeName.sortRank("movie") == 0)
        #expect(ContentTypeName.sortRank("series") == 1)
        #expect(ContentTypeName.sortRank("anime") == 2)
        #expect(ContentTypeName.sortRank("tv") == 3)
        #expect(ContentTypeName.sortRank("channel") == 4)
        #expect(ContentTypeName.sortRank("all") == 5)
        #expect(ContentTypeName.sortRank("") == 5)
    }
}
