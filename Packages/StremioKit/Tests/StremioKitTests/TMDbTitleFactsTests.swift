import Foundation
import Testing
@testable import StremioKit

/// TMDb's facts about a title, as the title page's Information shows them.
@Suite struct TMDbTitleFactsTests {
    @Test func aMovieGivesItsStudiosCountriesLanguageMoneyAndDate() throws {
        let json = #"""
            {"id":27205,"title":"Inception","original_title":"Inception","original_language":"en","status":"Released",
             "budget":160000000,"revenue":836836967,"release_date":"2010-07-15",
             "production_companies":[{"name":"Legendary Pictures"},{"name":"Syncopy"},{"name":" "},{"name":"Syncopy"}],
             "production_countries":[{"name":"United Kingdom"},{"name":"United States of America"}],
             "spoken_languages":[{"iso_639_1":"en","english_name":"English"},{"iso_639_1":"ja","english_name":"Japanese"}]}
            """#
        let facts = try TMDbTitleFacts.parse(Data(json.utf8))
        #expect(facts.studios == ["Legendary Pictures", "Syncopy"], "blank names go and each name is kept once")
        #expect(facts.countries == ["United Kingdom", "United States of America"])
        #expect(facts.originalLanguage == "English")
        #expect(facts.originalTitle == nil, "the same as the title")
        #expect(facts.budget == 160_000_000 && facts.revenue == 836_836_967)
        #expect(facts.releaseDate == "2010-07-15" && facts.status == "Released")
    }

    @Test func aSeriesGivesItsNetworkCreatorsAndRun() throws {
        let json = #"""
            {"id":1,"name":"Dark","original_name":"Dark","original_language":"de","status":"Ended","first_air_date":"2017-12-01",
             "last_air_date":"2020-06-27","number_of_seasons":3,"number_of_episodes":26,"budget":0,
             "networks":[{"name":"Netflix"}],"created_by":[{"name":"Baran bo Odar"},{"name":"Jantje Friese"}],"spoken_languages":[]}
            """#
        let facts = try TMDbTitleFacts.parse(Data(json.utf8))
        #expect(facts.networks == ["Netflix"] && facts.creators == ["Baran bo Odar", "Jantje Friese"])
        #expect(facts.seasonCount == 3 && facts.episodeCount == 26)
        #expect(facts.firstAired == "2017-12-01" && facts.lastAired == "2020-06-27")
        #expect(facts.budget == nil, "0 is unknown")
        #expect(facts.originalLanguage == "German", "named from its code when TMDb lists no spoken language for it")
    }

    @Test func anOriginalTitleIsKeptWhenItDiffers() throws {
        let facts = try TMDbTitleFacts.parse(Data(#"{"title":"Spirited Away","original_title":"千と千尋の神隠し"}"#.utf8))
        #expect(facts.originalTitle == "千と千尋の神隠し")
    }

    @Test func aMovieNamesItsFranchise() throws {
        let json = #"{"id":120,"title":"The Fellowship of the Ring","belongs_to_collection":{"id":119,"name":"The Lord of the Rings Collection"}}"#
        let facts = try TMDbTitleFacts.parse(Data(json.utf8))
        #expect(facts.tmdbID == 120 && facts.collectionID == 119)
    }

    @Test func aFranchiseListsItsFilmsInReleaseOrder() throws {
        let json = #"""
            {"id":119,"name":"The Lord of the Rings Collection","parts":[
             {"id":122,"title":"The Return of the King","release_date":"2003-12-01"},
             {"id":999,"title":"Untitled","release_date":""},
             {"id":120,"title":"The Fellowship of the Ring","release_date":"2001-12-18"},
             {"id":121,"title":"The Two Towers","release_date":"2002-12-18"}]}
            """#
        let franchise = try TMDbFranchise.parse(Data(json.utf8))
        #expect(franchise.name == "The Lord of the Rings Collection")
        #expect(franchise.parts.map(\.tmdbID) == [120, 121, 122, 999], "a film with no date yet comes last")
        #expect(franchise.parts.allSatisfy { $0.mediaType == "movie" })
        #expect(franchise.excluding(tmdbID: 120).parts.map(\.tmdbID) == [121, 122, 999], "the page's own film is left out")
    }

    @Test func anAnswerThatIsNotAnObjectThrows() {
        #expect(throws: AddonError.invalidJSON) { try TMDbTitleFacts.parse(Data("[]".utf8)) }
    }
}
