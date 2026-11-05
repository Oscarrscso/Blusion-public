import Foundation
import Testing
@testable import StremioKit

@Suite struct JustWatchPricesTests {
    private func answer(_ nodes: String) -> Data {
        Data(#"{"data":{"popularTitles":{"edges":[\#(nodes)]}}}"#.utf8)
    }

    private func node(imdb: String, title: String = "Dune", year: Int = 2021, offers: String) -> String {
        #"{"node":{"content":{"title":"\#(title)","originalReleaseYear":\#(year),"externalIds":{"imdbId":"\#(imdb)"}},"offers":[\#(offers)]}}"#
    }

    private func offer(_ kind: String, _ quality: String, _ store: String, _ price: Double?) -> String {
        let value = price.map { "\($0)" } ?? "null"
        return #"{"monetizationType":"\#(kind)","presentationType":"\#(quality)","retailPriceValue":\#(value),"currency":"EUR","package":{"clearName":"\#(store)"}}"#
    }

    @Test func matchesByIMDbIDAndKeepsOnlyRentAndBuy() throws {
        let data = answer([
            node(imdb: "tt0087182", year: 1984, offers: offer("RENT", "HD", "Apple TV Store", 2.99)),
            node(imdb: "tt1160419", offers: [
                offer("FLATRATE", "HD", "Netflix", nil),
                offer("RENT", "SD", "Apple TV Store", 3.49),
                offer("RENT", "_4K", "Apple TV Store", 4.99),
                offer("RENT", "_4K", "Rakuten TV", 4.49),
                offer("RENT", "_4K", "Rakuten TV", 4.49),
                offer("BUY", "HD", "Sky Store", 13.99),
            ].joined(separator: ",")),
        ].joined(separator: ","))
        let prices = try #require(try JustWatchPrices.parse(data, id: "tt1160419", title: "Dune", year: 2021))
        #expect(prices.offers.count == 4, "the stream and the repeated offer are left out")
        #expect(prices.bestRent == TitlePrices.Offer(kind: .rent, quality: .uhd, store: "Rakuten TV", price: 4.49, currency: "EUR"))
        #expect(prices.cheapest(.rent, .uhd).map(\.store) == ["Rakuten TV", "Apple TV Store"])
        #expect(prices.cheapest(.buy, .hd).map(\.price) == [13.99])
    }

    @Test func anotherIDMatchesByNameAndYear() throws {
        let data = answer(node(imdb: "tt1160419", offers: offer("BUY", "SD", "Sky Store", 9.99)))
        #expect(try JustWatchPrices.parse(data, id: "kitsu:1", title: "DUNE!", year: 2022) != nil)
        #expect(try JustWatchPrices.parse(data, id: "kitsu:1", title: "Dune", year: 2024) == nil)
        #expect(try JustWatchPrices.parse(data, id: "tt0000001", title: "Dune", year: 2021) == nil)
    }

    @Test func noOffersOrNoDataIsNil() throws {
        let streamOnly = answer(node(imdb: "tt1160419", offers: offer("FLATRATE", "HD", "Netflix", nil)))
        #expect(try JustWatchPrices.parse(streamOnly, id: "tt1160419", title: "Dune", year: nil) == nil)
        let refused = Data(#"{"errors":[{"message":"unknown country"}],"data":null}"#.utf8)
        #expect(try JustWatchPrices.parse(refused, id: "tt1160419", title: "Dune", year: nil) == nil)
        #expect(throws: AddonError.self) { try JustWatchPrices.parse(Data("nope".utf8), id: "tt1", title: "Dune", year: nil) }
    }

    @Test func bestRentIsNilWithoutRent() {
        let prices = TitlePrices(offers: [TitlePrices.Offer(kind: .buy, quality: .uhd, store: "Apple TV Store", price: 8.99, currency: "EUR")])
        #expect(prices.bestRent == nil)
    }
}
