// swiftlint:disable line_length
import Foundation
import Testing
@testable import StremioKit

/// The Fusion widget types and sources found in Fusion's own starter-kit exports, and how each one reads, keeps and writes back.
@Suite struct FusionWidgetCoverageTests {
    private func decode(_ text: String) throws -> FusionWidgetCodec.ImportResult {
        try FusionWidgetCodec.decode(Data(text.utf8), installed: [])
    }

    private func roundTrip(_ widgets: [HomeWidget]) throws -> [[String: Any]] {
        let data = try FusionWidgetCodec.encode(widgets)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["widgets"] as? [[String: Any]])
    }

    @Test func aNumberedRowDecodesAsARowWithRanks() throws {
        let result = try decode(#"""
        { "widgets": [
          { "id": "top", "title": "Top 10", "type": "row.classic.numbered", "limit": 10,
            "presentation": { "aspectRatio": "poster", "cardStyle": "medium", "badges": { "providers": false, "ratings": true } },
            "dataSource": { "kind": "traktList", "payload": { "listName": "Top", "listSlug": "top", "username": "u" } } }
        ] }
        """#)
        #expect(result.skipped == 0)
        let widget = try #require(result.widgets.first)
        guard case .row(let row) = widget.content else {
            Issue.record("a numbered row should decode to a row")
            return
        }
        #expect(row.presentation.showsRank, "the card carries its rank")
        #expect(row.limit == 10)
        #expect(row.presentation.aspectRatio == .poster && row.presentation.showsRatings)
    }

    @Test func aNumberedRowWritesBackAsNumbered() throws {
        let row = RowConfiguration(source: .traktList(TraktListReference(username: "u", listSlug: "s", listName: "S")),
                                   presentation: WidgetPresentation(showsRank: true))
        let written = try roundTrip([HomeWidget(id: "n", title: "N", content: .row(row))])
        #expect(written.first?["type"] as? String == "row.classic.numbered")

        let again = try FusionWidgetCodec.decode(try FusionWidgetCodec.encode([HomeWidget(id: "n", title: "N", content: .row(row))]), installed: [])
        #expect(again.widgets.first?.content == .row(row))
    }

    @Test func aPlainRowIsNotNumbered() throws {
        let row = RowConfiguration(source: .traktList(TraktListReference(username: "u", listSlug: "s", listName: "S")))
        let written = try roundTrip([HomeWidget(id: "p", title: "P", content: .row(row))])
        #expect(written.first?["type"] as? String == "row.classic")
    }

    @Test func anUnknownWidgetTypeIsKeptWithItsTypeAndWrittenBack() throws {
        let result = try decode(#"""
        { "widgets": [ { "id": "cal", "title": "Calendar", "type": "calendar.week", "dataSource": { "kind": "traktCalendar", "payload": { "x": 1 } } } ] }
        """#)
        #expect(result.skipped == 0)
        #expect(result.widgets.first?.content == .unsupported(type: "calendar.week"))
        #expect(result.widgets.first?.title == "Calendar")

        let written = try roundTrip(result.widgets)
        #expect(written.first?["type"] as? String == "calendar.week", "the type survives a round trip")
        #expect(written.first?["dataSource"] == nil, "the unreadable contents are not kept")
    }

    @Test func aTraktRecommendationsSourceIsKeptAsUnsupported() throws {
        let result = try decode(#"""
        { "widgets": [ { "id": "rec", "title": "For you", "type": "row.classic",
            "dataSource": { "kind": "traktRecommendations", "payload": { "ignoreWatchlisted": true, "limit": 20, "type": "movies" } } } ] }
        """#)
        guard case .row(let row) = result.widgets.first?.content else {
            Issue.record("the row should be kept")
            return
        }
        #expect(row.source == .unsupported(kind: "traktRecommendations"))
    }

    /// The payload's own filters are not read (their names are not Blusion's); the title decides, so the Comedy payload here loses to "Action".
    @Test func aTmdbDiscoverTileWithoutFiltersReadsItsFiltersFromItsTitle() throws {
        let result = try decode(#"""
        { "widgets": [ { "id": "c", "title": "Genres", "type": "collection.row",
            "dataSource": { "kind": "collection", "payload": { "items": [
              { "id": "t1", "title": "Action", "imageAspect": "wide",
                "dataSources": [ { "kind": "tmdbDiscover", "payload": { "includeGenres": [35], "sortBy": "popularity.desc", "type": "movie" } } ] } ] } } } ] }
        """#)
        let tile = try #require(result.widgets.first.flatMap { widget -> CollectionItem? in
            if case .collection(let tiles) = widget.content { return tiles.first }
            return nil
        })
        #expect(tile.sources == [.tmdbDiscover(TMDbDiscoverQuery(genres: [.init(id: 28, name: "Action")]))])
    }

    /// The starter-kit widget types and sources, one of each, as Fusion writes them. None may read as unsupported, and every one keeps a
    /// source that can load.
    @Test func everyKindInAStarterExportReadsToALoadableWidget() throws {
        let result = try decode(#"""
        { "exportType": "fusionWidgets", "exportVersion": 1, "widgets": [
          { "id": "auto.hero", "title": "Spotlight", "type": "blusion.hero", "limit": 8, "cacheTTL": 3600, "hideTitle": true,
            "presentation": { "aspectRatio": "poster", "cardStyle": "medium", "badges": { "providers": false, "ratings": true } },
            "dataSource": { "kind": "traktList", "payload": { "listName": "IMDB: Popular Movies", "listSlug": "imdb-popular-movies", "traktId": 2142788, "username": "justin" } } },
          { "id": "auto.continue", "title": "Continue", "type": "blusion.continueWatching" },
          { "id": "feed", "title": "Popular Movies", "type": "row.classic", "limit": 20,
            "presentation": { "aspectRatio": "poster", "cardStyle": "medium", "badges": { "providers": false, "ratings": true }, "blusionBetterPosters": true },
            "dataSource": { "kind": "blusion.traktFeed", "payload": { "feed": "moviesPopular" } } },
          { "id": "auto.genres", "title": "Browse by Genre", "type": "collection.row",
            "dataSource": { "kind": "collection", "payload": { "items": [
              { "id": "auto.genre.Action", "title": "Action", "imageAspect": "wide", "hideTitle": false,
                "dataSources": [ { "kind": "addonCatalog", "payload": { "addonId": "blusion:com.linvo.cinemeta", "catalogId": "movie::top", "catalogType": "movie", "genre": "Action" } } ] } ] } } },
          { "id": "numbered", "title": "IMDB Top Movies", "type": "row.classic.numbered", "limit": 20,
            "presentation": { "aspectRatio": "poster", "cardStyle": "medium", "badges": { "providers": false, "ratings": true } },
            "dataSource": { "kind": "traktList", "payload": { "listName": "IMDB: Top Rated Movies", "listSlug": "imdb-top-rated-movies", "traktId": 2142753, "username": "justin" } } },
          { "id": "banner", "title": "Trending Movies", "type": "hero.banner", "limit": 8,
            "dataSource": { "kind": "blusion.traktFeed", "payload": { "feed": "moviesTrending" } } },
          { "id": "discover", "title": "Top Mysteries", "type": "row.classic",
            "dataSource": { "kind": "tmdbDiscover", "payload": {} } },
          { "id": "discover-banner", "title": "Classic Science Fiction Movies", "type": "hero.banner",
            "dataSource": { "kind": "tmdbDiscover", "payload": {} } },
          { "id": "discover-numbered", "title": "Most Popular TV", "type": "row.classic.numbered",
            "dataSource": { "kind": "tmdbDiscover", "payload": {} } },
          { "id": "decades", "title": "TV by the Decade", "type": "collection.row",
            "dataSource": { "kind": "collection", "payload": { "items": [
              { "id": "d1", "title": "1980s TV", "hideTitle": true, "dataSources": [ { "kind": "tmdbDiscover", "payload": {} } ] } ] } } }
        ] }
        """#)
        #expect(result.skipped == 0)
        #expect(result.widgets.count == 10)
        for widget in result.widgets {
            if case .unsupported(let type) = widget.content { Issue.record("\(widget.title) should not be unsupported (\(type))") }
            for source in sources(of: widget.content) where isUnsupported(source) {
                Issue.record("\(widget.title) should not keep an unsupported source")
            }
        }
        #expect(sources(of: result.widgets[6].content) == [.tmdbDiscover(TMDbDiscoverQuery(genres: [.init(id: 9648, name: "Mystery")]))])
        #expect(sources(of: result.widgets[7].content) == [.tmdbDiscover(TMDbDiscoverQuery(kind: .movie, genres: [.init(id: 878, name: "Science Fiction")],
                                                                                          releasedTo: "1999-12-31"))])
        #expect(sources(of: result.widgets[9].content) == [.tmdbDiscover(TMDbDiscoverQuery(kind: .series, releasedFrom: "1980-01-01", releasedTo: "1989-12-31"))])
    }

    private func sources(of content: HomeWidget.Content) -> [WidgetSource] {
        switch content {
        case .row(let row), .hero(let row), .banner(let row): return [row.source]
        case .collection(let tiles): return tiles.flatMap(\.sources)
        case .continueWatching, .unsupported: return []
        }
    }

    private func isUnsupported(_ source: WidgetSource) -> Bool {
        if case .unsupported = source { return true }
        return false
    }

    @Test func aPresentationWithoutRankStillDecodes() throws {
        let json = #"{"aspectRatio":"wide","cardStyle":"large","showsRatings":false,"showsProviders":true}"#
        let presentation = try JSONDecoder().decode(WidgetPresentation.self, from: Data(json.utf8))
        #expect(presentation == WidgetPresentation(aspectRatio: .wide, cardStyle: .large, showsRatings: false, showsProviders: true, showsRank: false))
    }
}
// swiftlint:enable line_length
