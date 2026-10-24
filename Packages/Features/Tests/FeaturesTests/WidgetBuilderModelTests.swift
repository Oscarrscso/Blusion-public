import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

/// A catalog addon with a popular movie list (three genres) and a series list without genres.
private let cinemeta = Manifest(
    id: "test.cinemeta", name: "Cinemeta", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie", "series"],
    catalogs: [CatalogDescriptor(type: "movie", id: "top", name: "Popular",
                                 extra: [ExtraDescriptor(name: "genre", options: ["Action", "Drama", "Comedy"])]),
               CatalogDescriptor(type: "series", id: "trending", name: "Trending")])

private let irelandName = Locale.current.localizedString(forRegionCode: "IE") ?? "IE"
private let japaneseName = Locale.current.localizedString(forLanguageCode: "ja") ?? "JA"

private func named(_ id: Int, _ name: String) -> TMDbDiscoverQuery.Named {
    TMDbDiscoverQuery.Named(id: id, name: name)
}

/// The TMDb calls a test made, in order.
private actor CallLog {
    private(set) var calls: [String] = []

    func record(_ call: String) { calls.append(call) }
}

private struct Unreachable: Error {}

/// Lookups that answer from fixed lists and log each call. With `fails` set, every call throws.
private func fakeLookups(_ log: CallLog, hasToken: Bool = true, fails: Bool = false) -> WidgetBuilderLookups {
    WidgetBuilderLookups(
        hasToken: { hasToken },
        genres: { kind in
            await log.record("genres:\(kind.rawValue)")
            if fails { throw Unreachable() }
            return [named(28, "Action"), named(16, "Animation")]
        },
        keywords: { text in
            await log.record("keywords:\(text)")
            if fails { throw Unreachable() }
            return [named(1, "Heist")]
        },
        people: { text in
            await log.record("people:\(text)")
            if fails { throw Unreachable() }
            return [named(31, "Tom Hanks")]
        },
        companies: { text in
            await log.record("companies:\(text)")
            if fails { throw Unreachable() }
            return [named(41077, "A24")]
        },
        providers: { kind, region in
            await log.record("providers:\(kind.rawValue):\(region)")
            if fails { throw Unreachable() }
            return [named(8, "Netflix")]
        })
}

/// A manager that has loaded the default layout over the Cinemeta addon, with the services it was built from.
@MainActor
private func loadedManager(widgets: [HomeWidget]? = nil) async throws -> (manager: WidgetsManagerViewModel, services: AppServices) {
    let (registry, client) = try await makeStubbedRegistry(manifests: [cinemeta], transport: StubTransport(data: Data()))
    let services = AppServices(registry: registry, client: client, widgets: InMemoryWidgetStore(widgets))
    let manager = WidgetsManagerViewModel(services: services)
    await manager.load()
    return (manager, services)
}

/// A builder in the device region Ireland, over the fake lookups unless others are given.
@MainActor
private func builder(_ mode: WidgetBuilderModel.Mode = .create, widget: HomeWidget? = nil, manager: WidgetsManagerViewModel,
                     lookups: WidgetBuilderLookups? = nil) -> WidgetBuilderModel {
    WidgetBuilderModel(mode: mode, widget: widget, manager: manager, lookups: lookups ?? fakeLookups(CallLog()), region: "IE")
}

/// A saved row of `source`, with the given id, title and item count.
private func rowWidget(id: String = "w", title: String, _ source: WidgetSource, limit: Int = 20) -> HomeWidget {
    HomeWidget(id: id, title: title, content: .row(RowConfiguration(source: source, limit: limit)))
}

/// An edit of a TMDB list with `query`, titled by the query unless `title` is given.
@MainActor
private func tmdbBuilder(_ query: TMDbDiscoverQuery, limit: Int = 20, title: String? = nil,
                         manager: WidgetsManagerViewModel) -> WidgetBuilderModel {
    builder(.edit, widget: rowWidget(title: title ?? query.title, .tmdbDiscover(query), limit: limit), manager: manager)
}

/// The sentence as plain text: one space between parts, and a kind as its noun.
@MainActor
private func plain(_ model: WidgetBuilderModel) -> String {
    model.sentence.map { item -> String in
        switch item.part {
        case .text(let text): return text
        case .kind(let kind): return kind.noun
        case .token(let token): return token.text
        }
    }
    .joined(separator: " ")
}

@MainActor
private func tokens(_ model: WidgetBuilderModel) -> [WidgetBuilderModel.Token] {
    model.sentence.compactMap { item -> WidgetBuilderModel.Token? in
        if case .token(let token) = item.part { return token }
        return nil
    }
}

@MainActor
private func pill(_ model: WidgetBuilderModel, _ field: WidgetBuilderModel.Field) -> WidgetBuilderModel.Pill? {
    model.pills.first { $0.field == field }
}

/// A token as the sentence builds it: its id is the field's name, with the value's id when the field holds several values.
private func token(_ field: WidgetBuilderModel.Field, _ text: String, valueID: Int? = nil,
                   removable: Bool = true) -> WidgetBuilderModel.Part {
    let id = valueID.map { "\(field.rawValue):\($0)" } ?? field.rawValue
    return .token(WidgetBuilderModel.Token(id: id, field: field, text: text, isRemovable: removable, valueID: valueID))
}

private let popularPrefix = "Make a movie list sorted by Popular and "

@MainActor
@Suite struct WidgetBuilderModelTests {
    // MARK: Starting and committing

    @Test func aNewBuilderIsATMDbListThatCommitsThroughTheManager() async throws {
        let (manager, services) = try await loadedManager()
        let before = manager.widgets.count
        let model = builder(manager: manager)
        #expect(model.mode == .create)
        #expect(model.widget.title == "Popular Movies" && model.query == TMDbDiscoverQuery())
        #expect(model.customTitle.isEmpty && model.autoTitle == "Popular Movies")
        #expect(model.canCommit)
        await model.commit()
        #expect(manager.widgets.count == before + 1)
        #expect(manager.widgets.last?.id == model.widget.id)
        let saved = await services.widgets.load()
        #expect(saved?.last?.id == model.widget.id)
    }

    @Test func anEditKeepsTheWidgetsIDAndCommitsAnUpdate() async throws {
        let original = rowWidget(id: "w1", title: "Old", .tmdbDiscover(TMDbDiscoverQuery()))
        let (manager, services) = try await loadedManager(widgets: [original])
        let model = builder(.edit, widget: original, manager: manager)
        #expect(model.mode == .edit && model.customTitle == "Old", "a title that differs from the source's name is custom")
        model.setCustomTitle("New")
        await model.commit()
        #expect(manager.widgets.map(\.id) == [HomeLayout.continueWatchingID, "w1"], "an update replaces the widget rather than adding one")
        #expect(manager.widgets.last?.title == "New")
        let saved = await services.widgets.load()
        #expect(saved?.map(\.title) == ["Continue", "New"])
    }

    @Test func removeWidgetRemovesTheWidgetFromHome() async throws {
        let original = rowWidget(id: "w1", title: "Popular Movies", .tmdbDiscover(TMDbDiscoverQuery()))
        let (manager, _) = try await loadedManager(widgets: [original])
        let model = builder(.edit, widget: original, manager: manager)
        await model.removeWidget()
        #expect(manager.widgets.map(\.id) == [HomeLayout.continueWatchingID], "only Continue Watching, which Home always shows, is left")
    }

    @Test func anUnsupportedSourceCannotBeCommitted() async throws {
        let (manager, _) = try await loadedManager()
        let before = manager.widgets
        let widget = HomeWidget(id: "u", title: "Mine", content: .row(RowConfiguration(source: .unsupported(kind: "anilistCatalog"))))
        let model = builder(.edit, widget: widget, manager: manager)
        #expect(!model.canCommit)
        #expect(plain(model) == "Choose what this widget shows: Source .")
        await model.commit()
        #expect(manager.widgets == before)
    }

    @Test func aWidgetThatIsNotARowIsShownAsAnEmptyRow() async throws {
        let (manager, _) = try await loadedManager()
        let model = builder(.edit, widget: HomeWidget(id: "c", title: "Continue", content: .continueWatching), manager: manager)
        #expect(model.row.source == .unsupported(kind: ""))
        #expect(!model.canCommit)
    }

    // MARK: The sentence

    @Test func theDefaultSentenceReadsAsAMovieListSortedByPopular() async throws {
        let (manager, _) = try await loadedManager()
        let model = builder(manager: manager)
        #expect(model.sentence.map(\.part) == [
            .text("Make a"), .kind(.movie), .text("list sorted by"), token(.ordering, "Popular", removable: false), .text("."),
        ])
        #expect(plain(model) == "Make a movie list sorted by Popular .")
    }

    @Test func theExampleReadsSeriesTrendingThisWeekAndAnimation() async throws {
        let (manager, _) = try await loadedManager()
        let query = TMDbDiscoverQuery(kind: .series, ordering: .trendingThisWeek, genres: [named(16, "Animation")])
        let model = tmdbBuilder(query, manager: manager)
        #expect(model.sentence.map(\.part) == [
            .text("Make a"), .kind(.series), .text("list sorted by"), token(.ordering, "Trending this week", removable: false),
            .text("and"), .text("about"), token(.genres, "animation", valueID: 16), .text("."),
        ])
        #expect(plain(model) == "Make a series list sorted by Trending this week and about animation .")
    }

    @Test func threeClausesAreJoinedWithCommasAndOneAnd() async throws {
        let (manager, _) = try await loadedManager()
        let query = TMDbDiscoverQuery(period: .lastYear, genres: [named(16, "Animation")], minimumScore: 7)
        let model = tmdbBuilder(query, manager: manager)
        let separators = model.sentence.compactMap { item -> String? in
            if case .text(let text) = item.part, text == "," || text == "and" { return text }
            return nil
        }
        #expect(separators == [",", ",", "and"])
        #expect(plain(model) == "Make a movie list sorted by Popular , about animation , from last year and rated 7+ on IMDb .")
    }

    @Test func eachClauseReadsItsValue() async throws {
        let (manager, _) = try await loadedManager()
        let cases: [(TMDbDiscoverQuery, String)] = [
            (TMDbDiscoverQuery(minimumScore: 7), "rated 7+ on IMDb"),
            (TMDbDiscoverQuery(maximumScore: 6), "rated up to 6 on IMDb"),
            (TMDbDiscoverQuery(minimumScore: 7, maximumScore: 9), "rated 7 to 9 on IMDb"),
            (TMDbDiscoverQuery(minimumScore: 7.5, maximumScore: 8.5), "rated 7.5 to 8.5 on IMDb"),
            (TMDbDiscoverQuery(minimumVotes: 500), "with 500+ IMDb votes"),
            (TMDbDiscoverQuery(minimumRuntime: 90), "running 90+ min"),
            (TMDbDiscoverQuery(maximumRuntime: 120), "running under 120 min"),
            (TMDbDiscoverQuery(minimumRuntime: 90, maximumRuntime: 120), "running 90 to 120 min"),
            (TMDbDiscoverQuery(releasedFrom: "2010-05-01", releasedTo: "2020-12-31"), "released 2010 to 2020"),
            (TMDbDiscoverQuery(releasedFrom: "2010-05-01"), "released from 2010"),
            (TMDbDiscoverQuery(releasedTo: "2020-12-31"), "released up to 2020"),
            (TMDbDiscoverQuery(language: "ja"), "in \(japaneseName)"),
            (TMDbDiscoverQuery(keywords: [named(1, "Heist")]), "with Heist"),
            (TMDbDiscoverQuery(excludedKeywords: [named(2, "Remake")]), "without Remake"),
            (TMDbDiscoverQuery(period: .lastMonth), "from the last month"),
            (TMDbDiscoverQuery(period: .last3Months), "from the last 3 months"),
            (TMDbDiscoverQuery(period: .thisYear), "from this year"),
            (TMDbDiscoverQuery(period: .lastYear), "from last year"),
            (TMDbDiscoverQuery(period: .last5Years), "from the last 5 years"),
            (TMDbDiscoverQuery(period: .last10Years), "from the last 10 years"),
            (TMDbDiscoverQuery(cast: [named(31, "Tom Hanks")]), "starring Tom Hanks"),
            (TMDbDiscoverQuery(crew: [named(5, "Jane Doe")]), "made by Jane Doe"),
            (TMDbDiscoverQuery(companies: [named(41077, "A24")]), "from A24"),
        ]
        for (query, clause) in cases {
            let model = tmdbBuilder(query, manager: manager)
            #expect(plain(model) == popularPrefix + clause + " .", "the clause for \(clause)")
        }
    }

    @Test func providersAreFollowedByTheRegionTheyAreLookedUpIn() async throws {
        let (manager, _) = try await loadedManager()
        let deviceRegion = tmdbBuilder(TMDbDiscoverQuery(providers: [named(8, "Netflix"), named(337, "Disney+")]), manager: manager)
        #expect(plain(deviceRegion) == "Make a movie list sorted by Popular , on Netflix Disney+ and in \(irelandName) .")
        #expect(tokens(deviceRegion).first { $0.field == .region }?.isRemovable == false, "the device's region is not a filter to remove")

        let chosen = tmdbBuilder(TMDbDiscoverQuery(providers: [named(8, "Netflix")], region: "JP"), manager: manager)
        let region = tokens(chosen).first { $0.field == .region }
        #expect(region?.text == (Locale.current.localizedString(forRegionCode: "JP") ?? "JP"))
        #expect(region?.isRemovable == true)
    }

    @Test func limitAndTitleClausesAppearOnlyWhenTheyDiffer() async throws {
        let (manager, _) = try await loadedManager()
        #expect(plain(tmdbBuilder(TMDbDiscoverQuery(), limit: 30, manager: manager)) == popularPrefix + "showing 30 titles .")
        #expect(plain(tmdbBuilder(TMDbDiscoverQuery(), manager: manager)) == "Make a movie list sorted by Popular .", "20 is the default")
        let titled = tmdbBuilder(TMDbDiscoverQuery(), title: "Mine", manager: manager)
        #expect(plain(titled) == popularPrefix + "called \u{201C}Mine\u{201D} .")
    }

    // MARK: Removing values

    @Test func removingAGenreTokenRemovesOnlyThatGenre() async throws {
        let (manager, _) = try await loadedManager()
        let model = tmdbBuilder(TMDbDiscoverQuery(genres: [named(28, "Action"), named(16, "Animation")]), manager: manager)
        model.remove(try #require(tokens(model).first { $0.field == .genres && $0.valueID == 16 }))
        #expect(model.query?.genres == [named(28, "Action")])
    }

    @Test func removingTheSingleValueTokensClearsTheirFilters() async throws {
        let (manager, _) = try await loadedManager()
        let query = TMDbDiscoverQuery(period: .lastYear, minimumScore: 7, maximumScore: 9, minimumVotes: 500, language: "ja",
                                      minimumRuntime: 90, maximumRuntime: 120, providers: [named(8, "Netflix")], region: "JP")
        let model = tmdbBuilder(query, limit: 30, title: "Mine", manager: manager)
        for id in ["period", "votes", "language", "region", "runtime", "limit", "title"] {
            model.remove(try #require(tokens(model).first { $0.id == id }))
        }
        #expect(model.query?.period == nil && model.query?.minimumVotes == nil && model.query?.language == nil)
        #expect(model.query?.region == nil && model.query?.minimumRuntime == nil && model.query?.maximumRuntime == nil)
        #expect(model.row.limit == 20 && model.customTitle.isEmpty && model.widget.title == "Popular Movies")
        #expect(model.query?.providers == [named(8, "Netflix")], "a value the token did not name stays")

        model.remove(try #require(tokens(model).first { $0.id == "score" }))
        #expect(model.query?.minimumScore == nil && model.query?.maximumScore == nil, "a score token clears both bounds")
    }

    @Test func removingAReleaseTokenClearsBothDates() async throws {
        let (manager, _) = try await loadedManager()
        let model = tmdbBuilder(TMDbDiscoverQuery(releasedFrom: "2010-05-01", releasedTo: "2020-12-31"), manager: manager)
        model.remove(try #require(tokens(model).first { $0.id == "release" }))
        #expect(model.query?.releasedFrom == nil && model.query?.releasedTo == nil)
    }

    @Test func catalogGenreAndTraktSortTokensAreRemovable() async throws {
        let (manager, _) = try await loadedManager()
        let catalog = AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "movie", catalogID: "top", genre: "Action")
        let catalogModel = builder(.edit, widget: rowWidget(id: "c", title: "Action", .addonCatalog(catalog)), manager: manager)
        catalogModel.remove(try #require(tokens(catalogModel).first { $0.field == .catalogGenre }))
        let plainCatalog = AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "movie", catalogID: "top")
        #expect(catalogModel.row.source == .addonCatalog(plainCatalog))

        let list = TraktListReference(username: "tvgeniekodi", listSlug: "daily-picks", listName: "Daily Picks", sort: .rating)
        let traktModel = builder(.edit, widget: rowWidget(id: "t", title: "Daily Picks", .traktList(list)), manager: manager)
        traktModel.remove(try #require(tokens(traktModel).first { $0.field == .traktSort }))
        #expect(traktModel.traktSort == nil)
        if case .traktList(let changed) = traktModel.row.source {
            #expect(changed.sort == nil)
        } else {
            Issue.record("the source should stay a Trakt list")
        }
    }

    @Test func nonRemovableTokensDoNothing() async throws {
        let (manager, _) = try await loadedManager()
        let model = tmdbBuilder(TMDbDiscoverQuery(genres: [named(16, "Animation")]), manager: manager)
        let before = model.widget
        for token in tokens(model) where !token.isRemovable {
            model.remove(token)
        }
        #expect(model.widget == before)
    }

    // MARK: Lists and filters

    @Test func togglingAValueAddsItAndTakesItOffAgain() async throws {
        let (manager, _) = try await loadedManager()
        let model = builder(manager: manager)
        model.toggle(named(16, "Animation"), in: .genres)
        #expect(model.query?.genres == [named(16, "Animation")])
        model.toggle(named(16, "Animation"), in: .genres)
        #expect(model.query?.genres.isEmpty == true)
    }

    @Test func aKeywordThatIsExcludedMovesToTheKeywords() async throws {
        let (manager, _) = try await loadedManager()
        let model = tmdbBuilder(TMDbDiscoverQuery(excludedKeywords: [named(1, "Heist")]), manager: manager)
        model.toggle(named(1, "Heist"), in: .keywords)
        #expect(model.query?.keywords == [named(1, "Heist")] && model.query?.excludedKeywords.isEmpty == true)
        model.toggle(named(1, "Heist"), in: .excludedKeywords)
        #expect(model.query?.excludedKeywords == [named(1, "Heist")] && model.query?.keywords.isEmpty == true)
    }

    @Test func aTrendingOrderingDropsTheFiltersItCannotUseAndDisablesTheirPills() async throws {
        let (manager, _) = try await loadedManager()
        let query = TMDbDiscoverQuery(period: .thisYear, genres: [named(28, "Action")], keywords: [named(1, "Heist")],
                                      excludedKeywords: [named(2, "Remake")], minimumRuntime: 90, providers: [named(8, "Netflix")],
                                      region: "JP", cast: [named(31, "Tom Hanks")], crew: [named(5, "Jane Doe")],
                                      companies: [named(41077, "A24")])
        let model = tmdbBuilder(query, manager: manager)
        model.select(.keywords)
        #expect(model.selectedField == WidgetBuilderModel.Field.keywords)
        model.setOrdering(.trendingToday)
        #expect(model.query?.keywords.isEmpty == true && model.query?.excludedKeywords.isEmpty == true)
        #expect(model.query?.minimumRuntime == nil && model.query?.providers.isEmpty == true && model.query?.region == nil)
        #expect(model.query?.cast.isEmpty == true && model.query?.crew.isEmpty == true && model.query?.companies.isEmpty == true)
        #expect(model.query?.genres == [named(28, "Action")] && model.query?.period == TMDbDiscoverQuery.Period.thisYear,
                "the filters a trending list keeps stay")
        #expect(model.selectedField == nil, "a selection that is no longer enabled is dropped")
        for field in [WidgetBuilderModel.Field.keywords, .excludedKeywords, .runtime, .providers, .region, .cast, .crew, .companies] {
            let entry = try #require(pill(model, field))
            #expect(!entry.isEnabled && entry.value == "Not with Trending", "\(field.rawValue) is not available")
        }
        model.select(.keywords)
        #expect(model.selectedField == nil, "a disabled setting cannot be opened")
    }

    @Test func aSeriesDropsCastAndCrewAndSaysMoviesOnly() async throws {
        let (manager, _) = try await loadedManager()
        let people = TMDbDiscoverQuery(cast: [named(31, "Tom Hanks")], crew: [named(5, "Jane Doe")], companies: [named(41077, "A24")])
        let model = tmdbBuilder(people, manager: manager)
        model.setKind(.series)
        #expect(model.query?.kind == .series && model.query?.cast.isEmpty == true && model.query?.crew.isEmpty == true)
        #expect(model.query?.companies == [named(41077, "A24")], "companies are not a movie-only filter")
        #expect(pill(model, .cast)?.value == "Movies only" && pill(model, .cast)?.isEnabled == false)
        #expect(pill(model, .crew)?.value == "Movies only" && pill(model, .companies)?.isEnabled == true)
    }

    @Test func aReleaseDateClearsThePeriodAndAPeriodClearsTheDates() async throws {
        let (manager, _) = try await loadedManager()
        let model = tmdbBuilder(TMDbDiscoverQuery(period: .lastYear), manager: manager)
        model.updateQuery { $0.releasedFrom = "2010-01-01" }
        #expect(model.query?.period == nil && model.query?.releasedFrom == "2010-01-01")
        model.updateQuery { $0.period = .thisYear }
        #expect(model.query?.period == TMDbDiscoverQuery.Period.thisYear)
        #expect(model.query?.releasedFrom == nil && model.query?.releasedTo == nil)
    }

    @Test func aScoreOrVotesSetInTheEditorAreIMDbs() async throws {
        let (manager, _) = try await loadedManager()
        let model = tmdbBuilder(TMDbDiscoverQuery(minimumScore: 7, minimumVotes: 300, usesTMDbScores: true), manager: manager)
        model.updateQuery { $0.language = "ja" }
        #expect(model.query?.usesTMDbScores == true, "another filter leaves a search's TMDb scores as they are")
        model.updateQuery { $0.minimumVotes = 10_000 }
        #expect(model.query?.usesTMDbScores == false)
        let scored = tmdbBuilder(TMDbDiscoverQuery(minimumScore: 7, usesTMDbScores: true), manager: manager)
        scored.updateQuery { $0.maximumScore = 9 }
        #expect(scored.query?.usesTMDbScores == false)
    }

    @Test func aBlankLanguageOrRegionIsStoredAsNilAndACodeIsKept() async throws {
        let (manager, _) = try await loadedManager()
        let model = builder(manager: manager)
        model.updateQuery { $0.language = "   " }
        #expect(model.query?.language == nil, "a blank language is not stored")
        model.updateQuery { $0.language = " ja " }
        #expect(model.query?.language == "ja")
        model.updateQuery { $0.region = "  " }
        #expect(model.query?.region == nil)
        model.updateQuery { $0.region = "jp" }
        #expect(model.query?.region == "JP")
    }

    // MARK: Title and row settings

    @Test func theTitleFollowsTheSourceUntilItIsNamedAndGoesBackWhenCleared() async throws {
        let (manager, _) = try await loadedManager()
        let model = builder(manager: manager)
        model.toggle(named(16, "Animation"), in: .genres)
        #expect(model.widget.title == "Popular Animation Movies")
        model.setOrdering(.trendingThisWeek)
        #expect(model.widget.title == "Trending Animation Movies This Week")
        model.setCustomTitle("Mine")
        #expect(model.customTitle == "Mine" && model.widget.title == "Mine")
        model.setOrdering(.popular)
        #expect(model.widget.title == "Mine", "a named widget keeps its name")
        model.setCustomTitle("   ")
        #expect(model.customTitle.isEmpty && model.widget.title == "Popular Animation Movies")
    }

    @Test func styleLimitAndPresentationChangesKeepTheRowValid() async throws {
        let (manager, _) = try await loadedManager()
        let model = builder(manager: manager)
        model.setStyle(.spotlight)
        #expect(model.style == .spotlight && model.hidesTitle && model.row.limit == 8)
        model.setStyle(.row)
        #expect(!model.hidesTitle && model.row.limit == 20)
        model.updateRow { $0.limit = 500 }
        #expect(model.row.limit == 100)
        model.updateRow { $0.limit = 0 }
        #expect(model.row.limit == 1)
        model.updateRow { $0.presentation.usesBetterPosters = true }
        #expect(pill(model, .posters)?.value == "Better Posters")
        model.setHideTitle(true)
        #expect(model.hidesTitle)
    }

    // MARK: Pills

    @Test func theDefaultPillsAreTheSourceThenTheFiltersThenTheCommonOnes() async throws {
        let (manager, _) = try await loadedManager()
        let model = builder(manager: manager)
        #expect(model.pills.map(\.field) == [
            .source, .ordering, .period, .genres, .keywords, .excludedKeywords, .score, .votes, .language, .runtime, .release,
            .providers, .region, .cast, .crew, .companies, .title, .limit, .style, .cards, .posters, .shuffle, .randomSource,
        ])
        #expect(model.pills.dropLast().last?.value == "Like Other Widgets", "a new widget follows the widgets page's shuffle")
        #expect(model.pills.last?.value == "Off", "and has no random source")
        let values = Dictionary(uniqueKeysWithValues: model.pills.map { ($0.field, $0.value) })
        #expect(values[.source] == "TMDB" && values[.ordering] == "Popular" && values[.period] == "Any time")
        #expect(values[.genres] == "Any" && values[.excludedKeywords] == "None" && values[.region] == irelandName)
        #expect(values[.title] == "Automatic" && values[.limit] == "20" && values[.style] == "Row")
        #expect(values[.cards] == "Poster · Medium" && values[.posters] == "Standard")
        let allEnabled = model.pills.allSatisfy { $0.isEnabled }
        #expect(allEnabled)
    }

    @Test func listPillsNameTheFirstValueAndCountTheRest() async throws {
        let (manager, _) = try await loadedManager()
        let model = tmdbBuilder(TMDbDiscoverQuery(genres: [named(16, "Animation"), named(35, "Comedy"), named(18, "Drama")],
                                                  providers: [named(8, "Netflix")], cast: [named(31, "Tom Hanks")]), manager: manager)
        #expect(pill(model, .genres)?.value == "Animation +2")
        #expect(pill(model, .providers)?.value == "Netflix")
        #expect(pill(model, .cast)?.value == "Tom Hanks")
    }

    @Test func aCatalogSourceHasItsGenrePillOnlyWhenItHasGenres() async throws {
        let (manager, _) = try await loadedManager()
        let withGenres = AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "movie", catalogID: "top")
        let model = builder(.edit, widget: rowWidget(id: "c", title: "Popular Movies", .addonCatalog(withGenres)), manager: manager)
        #expect(model.pills.map(\.field) == [.source, .catalogGenre, .title, .limit, .style, .cards, .posters, .shuffle, .randomSource])
        #expect(pill(model, .source)?.value == "Cinemeta" && pill(model, .catalogGenre)?.value == "All")
        #expect(plain(model) == "Show Popular Movies · Cinemeta .")
        model.setCatalogGenre("Action")
        #expect(pill(model, .catalogGenre)?.value == "Action")
        #expect(plain(model) == "Show Popular Movies · Cinemeta about Action .")

        let withoutGenres = AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "series", catalogID: "trending")
        let plainModel = builder(.edit, widget: rowWidget(id: "s", title: "Trending", .addonCatalog(withoutGenres)), manager: manager)
        #expect(plainModel.pills.map(\.field) == [.source, .title, .limit, .style, .cards, .posters, .shuffle, .randomSource])
    }

    @Test func aTraktListHasItsSortAndATraktFeedHasNoSortAndBothSayWhatTheyShow() async throws {
        let (manager, _) = try await loadedManager()
        let list = TraktListReference(username: "tvgeniekodi", listSlug: "daily-picks", listName: "Daily Picks")
        let listModel = builder(.edit, widget: rowWidget(id: "t", title: "Daily Picks", .traktList(list)), manager: manager)
        #expect(listModel.pills.map(\.field) == [.source, .traktSort, .title, .limit, .style, .cards, .posters, .shuffle, .randomSource])
        #expect(pill(listModel, .source)?.value == "Trakt" && pill(listModel, .traktSort)?.value == "List Default")
        #expect(plain(listModel) == "Show the Trakt list Daily Picks .")
        listModel.setTraktSort(.title)
        #expect(pill(listModel, .traktSort)?.value == "Title")
        #expect(plain(listModel) == "Show the Trakt list Daily Picks sorted by Title .")

        let feedModel = builder(.edit, widget: rowWidget(id: "f", title: "Trending Movies", .traktFeed(.moviesTrending)), manager: manager)
        #expect(feedModel.pills.map(\.field) == [.source, .title, .limit, .style, .cards, .posters, .shuffle, .randomSource])
        #expect(plain(feedModel) == "Show Trending Movies from Trakt .")
    }

    @Test func theTitleItemsStyleAndCardPillsAreAlwaysLast() async throws {
        let (manager, _) = try await loadedManager()
        let sources: [WidgetSource] = [
            .tmdbDiscover(TMDbDiscoverQuery()),
            .addonCatalog(AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "movie", catalogID: "top")),
            .traktList(TraktListReference(username: "u", listSlug: "s", listName: "L")),
            .traktFeed(.showsPopular),
            .unsupported(kind: "anilistCatalog"),
        ]
        for source in sources {
            let model = builder(.edit, widget: rowWidget(id: "x", title: "X", source), manager: manager)
            #expect(model.pills.suffix(7).map(\.field) == [.title, .limit, .style, .cards, .posters, .shuffle, .randomSource], "the common pills end \(source)")
        }
    }

    @Test func aTrendingListShowsItsFilterPillsAsAvailableOnlyWhereTheQueryAllowsThem() async throws {
        let (manager, _) = try await loadedManager()
        let model = tmdbBuilder(TMDbDiscoverQuery(ordering: .trendingThisWeek), manager: manager)
        #expect(pill(model, .period)?.isEnabled == true && pill(model, .genres)?.isEnabled == true)
        #expect(pill(model, .score)?.isEnabled == true && pill(model, .release)?.isEnabled == true)
        #expect(pill(model, .keywords)?.isEnabled == false)
    }

    // MARK: Sources

    @Test func setSourceAndUseTMDbListSwapTheSource() async throws {
        let (manager, _) = try await loadedManager()
        let model = builder(manager: manager)
        model.setSource(.addonCatalog(AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "movie", catalogID: "top")))
        #expect(pill(model, .source)?.value == "Cinemeta" && model.query == nil)
        #expect(model.widget.title == "Popular Movies", "the title follows the new source")
        model.useTMDbList()
        #expect(model.query == TMDbDiscoverQuery())
        model.setKind(.series)
        model.useTMDbList()
        #expect(model.query?.kind == .series, "a TMDB list that is already set is kept")
    }

    @Test func aTraktSortChosenBeforeTheListIsAppliedWhenItIsChosen() async throws {
        let (manager, _) = try await loadedManager()
        let model = builder(manager: manager)
        model.setTraktSort(.title)
        #expect(model.traktSort == .title)
        let list = TraktListReference(username: "tvgeniekodi", listSlug: "daily-picks", listName: "Daily Picks")
        model.setSource(.traktList(list))
        #expect(model.traktSort == .title)
        if case .traktList(let chosen) = model.row.source { #expect(chosen.sort == .title) } else { Issue.record("expected a Trakt list") }
    }

    @Test func needsTMDbTokenFollowsTheSourceAndTheSavedToken() async throws {
        let (manager, _) = try await loadedManager()
        let noToken = builder(manager: manager, lookups: fakeLookups(CallLog(), hasToken: false))
        await noToken.load()
        #expect(noToken.needsTMDbToken)
        noToken.setSource(.addonCatalog(AddonCatalogReference(manifestID: "test.cinemeta", catalogType: "movie", catalogID: "top")))
        #expect(!noToken.needsTMDbToken, "a catalog does not need the TMDB token")
        noToken.useTMDbList()
        #expect(noToken.needsTMDbToken)

        let withToken = builder(manager: manager, lookups: fakeLookups(CallLog(), hasToken: true))
        await withToken.load()
        #expect(!withToken.needsTMDbToken)
    }

    // MARK: Options and suggestions

    @Test func loadOptionsFillsTheGenresOnceForTheKind() async throws {
        let (manager, _) = try await loadedManager()
        let log = CallLog()
        let model = builder(manager: manager, lookups: fakeLookups(log))
        await model.loadOptions(for: .genres)
        #expect(model.genreOptions == [named(28, "Action"), named(16, "Animation")])
        #expect(model.optionsMessage == nil && !model.isLoadingOptions)
        await model.loadOptions(for: .genres)
        #expect(await log.calls == ["genres:movie"], "the same kind is not asked again")
        model.setKind(.series)
        await model.loadOptions(for: .genres)
        #expect(await log.calls == ["genres:movie", "genres:series"])
    }

    @Test func loadOptionsSaysWhenTMDBCannotBeReached() async throws {
        let (manager, _) = try await loadedManager()
        let model = builder(manager: manager, lookups: fakeLookups(CallLog(), fails: true))
        await model.loadOptions(for: .genres)
        #expect(model.optionsMessage == "TMDB couldn't be reached.")
        #expect(model.genreOptions.isEmpty && !model.isLoadingOptions)
    }

    @Test func loadOptionsWithoutATokenSaysSoAndSendsNothing() async throws {
        let (manager, _) = try await loadedManager()
        let log = CallLog()
        let model = builder(manager: manager, lookups: fakeLookups(log, hasToken: false))
        await model.loadOptions(for: .genres)
        #expect(model.optionsMessage == "Add a TMDB Read Access Token in Settings to choose from TMDB's lists.")
        #expect(model.genreOptions.isEmpty)
        #expect(await log.calls.isEmpty)
    }

    @Test func providersLoadForTheRegionTheQueryNamesOrTheDevice() async throws {
        let (manager, _) = try await loadedManager()
        let log = CallLog()
        let model = builder(manager: manager, lookups: fakeLookups(log))
        await model.loadOptions(for: .providers)
        #expect(model.providerOptions == [named(8, "Netflix")])
        model.updateQuery { $0.region = "jp" }
        await model.loadOptions(for: .providers)
        #expect(await log.calls == ["providers:movie:IE", "providers:movie:JP"])
    }

    @Test func loadOptionsDoesNothingForOtherFieldsAndSources() async throws {
        let (manager, _) = try await loadedManager()
        let log = CallLog()
        let model = builder(manager: manager, lookups: fakeLookups(log))
        await model.loadOptions(for: .keywords)
        model.setSource(.traktFeed(.moviesPopular))
        await model.loadOptions(for: .genres)
        #expect(await log.calls.isEmpty)
    }

    @Test func suggestionsRouteEachFieldToItsLookupAndAnswerNothingForBlankText() async throws {
        let (manager, _) = try await loadedManager()
        let log = CallLog()
        let model = builder(manager: manager, lookups: fakeLookups(log))
        #expect(await model.suggestions(for: .keywords, matching: " heist ") == [named(1, "Heist")])
        _ = await model.suggestions(for: .excludedKeywords, matching: "remake")
        #expect(await model.suggestions(for: .cast, matching: "tom") == [named(31, "Tom Hanks")])
        _ = await model.suggestions(for: .crew, matching: "jane")
        #expect(await model.suggestions(for: .companies, matching: "a24") == [named(41077, "A24")])
        #expect(await model.suggestions(for: .genres, matching: "action").isEmpty)
        #expect(await model.suggestions(for: .keywords, matching: "   ").isEmpty)
        #expect(await log.calls == ["keywords:heist", "keywords:remake", "people:tom", "people:jane", "companies:a24"])

        let failing = builder(manager: manager, lookups: fakeLookups(CallLog(), fails: true))
        #expect(await failing.suggestions(for: .keywords, matching: "heist").isEmpty)
    }

    @Test func languagesAndRegionsMatchByNameOrCode() async throws {
        let english = Locale(identifier: "en_US")
        let byName = WidgetBuilderModel.languages(matching: "jap", locale: english)
        #expect(byName.contains { $0.code == "ja" && $0.name == "Japanese" })
        let byCode = WidgetBuilderModel.languages(matching: "ja", locale: english)
        #expect(byCode.contains { $0.code == "ja" && $0.name == "Japanese" })
        #expect(byCode.count < WidgetBuilderModel.languages(matching: "", locale: english).count, "the text narrows the list")
        let names = WidgetBuilderModel.languages(matching: "", locale: english).map(\.name)
        #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, "sorted by name")

        let regionByName = WidgetBuilderModel.regions(matching: "ire", locale: english)
        #expect(regionByName.contains { $0.code == "IE" && $0.name == "Ireland" })
        let regionByCode = WidgetBuilderModel.regions(matching: "IE", locale: english)
        #expect(regionByCode.contains { $0.code == "IE" && $0.name == "Ireland" })
    }

    // MARK: Live lookups

    @Test func theLiveLookupsSendNothingWithoutATokenAndReadTheSavedOneWhenThereIs() async throws {
        let transport = StubTransport(data: Data(#"{"genres":[{"id":28,"name":"Action"}]}"#.utf8))
        let (registry, client) = try await makeStubbedRegistry(manifests: [cinemeta], transport: transport)
        let blank = AppServices(registry: registry, client: client,
                                settings: InMemorySettingsStore(PlaybackSettings(tmdbReadToken: "  ")))
        let withoutToken = WidgetBuilderLookups.live(services: blank)
        #expect(await withoutToken.hasToken() == false)
        let before = transport.callCount
        #expect(try await withoutToken.genres(.movie).isEmpty)
        #expect(try await withoutToken.keywords("heist").isEmpty)
        #expect(transport.callCount == before, "no request without a token")

        let saved = AppServices(registry: registry, client: client, settings: InMemorySettingsStore(PlaybackSettings(tmdbReadToken: "abc")))
        let withToken = WidgetBuilderLookups.live(services: saved)
        #expect(await withToken.hasToken())
        #expect(try await withToken.genres(.movie) == [named(28, "Action")])
    }
}
