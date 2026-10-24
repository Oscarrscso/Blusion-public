import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

@MainActor
@Suite struct SearchViewModelTests {
    private func manifest(_ id: String, searchable: Bool = true) -> Manifest {
        Manifest(id: id, name: id, version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
                 catalogs: [CatalogDescriptor(type: "movie", id: "main", extra: searchable ? [ExtraDescriptor(name: "search")] : [])])
    }

    /// Answers `{"metas":[{"id":"<host>-<term>"}]}` and counts calls; hosts containing "fail" answer 500; "slow0" waits a bit.
    private func stub() -> StubTransport {
        StubTransport { request, _ in
            let host = request.url?.host ?? ""
            if host.contains("stub2") { try await Task.sleep(for: .milliseconds(150)) }
            if host.contains("stub1") { return StubTransport.response(Data(), status: 500, for: request) }
            let term = request.url?.path.components(separatedBy: "search=").last?.replacingOccurrences(of: ".json", with: "") ?? "?"
            return StubTransport.response(Data(#"{"metas":[{"id":"\#(host)-\#(term)","name":"\#(term)"}]}"#.utf8), for: request)
        }
    }

    private func model(manifests: [Manifest], transport: StubTransport, debounce: Duration = .milliseconds(40),
                       history: (any SearchHistoryStore)? = nil) async throws -> SearchViewModel {
        let (registry, client) = try await makeStubbedRegistry(manifests: manifests, transport: transport)
        // The AI side reads with the keyword reader and finds nothing, so these tests never depend on whether this Mac has Apple
        // Intelligence (with it, the live model was still reading when a test looked).
        let quietAI = DescribedSearchService(interpreter: KeywordDescriptionInterpreter(), keywords: { _ in [] }, titles: { _ in [] })
        return SearchViewModel(services: AppServices(registry: registry, client: client, browse: BrowseService(registry: registry, client: client)),
                               debounce: debounce, history: history, describer: quietAI, usesLivePicker: false)
    }

    @Test func typingIsDebouncedIntoOneSearch() async throws {
        let transport = stub()
        let model = try await model(manifests: [manifest("a")], transport: transport, debounce: .milliseconds(120))
        for text in ["b", "bl", "blu", "blue"] {
            model.query = text
            model.queryDidChange()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.phase == .searching)
        await model.waitUntilDone()
        #expect(transport.callCount == 1, "only the final text was searched")
        #expect(model.phase == .done)
        #expect(model.sections.first?.items.first?.name == "blue")
    }

    @Test func clearingTheQueryResetsEverything() async throws {
        let model = try await model(manifests: [manifest("a")], transport: stub())
        model.query = "x"
        model.queryDidChange()
        await model.waitUntilDone()
        #expect(model.hasResults)
        model.query = "   "
        model.queryDidChange()
        #expect(model.phase == .idle)
        #expect(model.sections.isEmpty && model.failures.isEmpty)
        #expect(!model.showsNoResults)
    }

    @Test func eachAddonGetsASectionAndFailuresBecomeChips() async throws {
        let model = try await model(manifests: [manifest("stub0"), manifest("stub1"), manifest("stub2")], transport: stub())
        model.query = "dune"
        await model.submit()
        #expect(model.phase == .done)
        #expect(model.sections.map(\.addon.name) == ["stub0", "stub2"])
        #expect(model.failures.map(\.addon.name) == ["stub1"])
        #expect(model.failures.first?.text == "stub1: Server error (500)")
        #expect(model.hasResults)
        #expect(!model.showsNoResults)
    }

    @Test func sectionsStayInAddonOrderWhateverOrderTheyAnswerIn() async throws {
        // The first addon (host stub0) answers 1.5 s late, long enough for the fast one's section to be seen on a busy Mac; the
        // second (stub1) answers at once.
        let transport = StubTransport { request, _ in
            if request.url?.host == "stub0.example.com" { try await Task.sleep(for: .milliseconds(1500)) }
            return StubTransport.response(Data(#"{"metas":[{"id":"x"}]}"#.utf8), for: request)
        }
        let model = try await model(manifests: [manifest("first"), manifest("second")], transport: transport)
        model.query = "q"
        let search = Task { await model.submit() }
        try await waitUntil(timeout: 30) { model.sections.count == 1 }
        #expect(model.sections.map(\.addon.name) == ["second"], "the fast addon appears first while the slow one is pending")
        await search.value
        #expect(model.sections.map(\.addon.name) == ["first", "second"], "then it slots into the user's order")
    }

    @Test func noResultsIsReportedOnlyWhenNothingFailed() async throws {
        let empty = StubTransport(data: Data(#"{"metas":[]}"#.utf8))
        let model = try await model(manifests: [manifest("a")], transport: empty)
        model.query = "zzz"
        await model.submit()
        // "No results" waits for the AI search as well, which runs beside the addons' search and is not part of `submit`.
        await model.waitUntilDone()
        #expect(model.showsNoResults)
        let failing = StubTransport(data: Data(), status: 500)
        let other = try await self.model(manifests: [manifest("a")], transport: failing)
        other.query = "zzz"
        await other.submit()
        await other.waitUntilDone()
        #expect(!other.showsNoResults, "an error chip explains the empty screen")
        #expect(other.failures.count == 1)
    }

    @Test func addonsWithoutSearchableCatalogsAreNotAsked() async throws {
        let transport = stub()
        let model = try await model(manifests: [manifest("a", searchable: false)], transport: transport)
        model.query = "x"
        await model.submit()
        #expect(transport.callCount == 0)
        #expect(model.showsNoSearchableAddons)
        #expect(!model.showsNoResults, "no addon could have answered, so 'no results' would mislead")
    }

    @Test func resultsAreGroupedByTypeAndDeduplicatedAcrossAddons() async throws {
        // Addon "a" has one movie catalog. Addon "b" has the same movie plus a movie, a channel, a series and an anime catalog, in that order.
        let movies = Manifest(id: "a", name: "A", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
                              catalogs: [CatalogDescriptor(type: "movie", id: "movies", extra: [ExtraDescriptor(name: "search")])])
        let mixed = Manifest(id: "b", name: "B", version: "1", resources: [ResourceDescriptor(name: "catalog")],
                             types: ["movie", "tv", "series", "anime"],
                             catalogs: [CatalogDescriptor(type: "movie", id: "films", extra: [ExtraDescriptor(name: "search")]),
                                        CatalogDescriptor(type: "tv", id: "channels", extra: [ExtraDescriptor(name: "search")]),
                                        CatalogDescriptor(type: "series", id: "shows", extra: [ExtraDescriptor(name: "search")]),
                                        CatalogDescriptor(type: "anime", id: "kitsu", extra: [ExtraDescriptor(name: "search")])])
        let bodies = [
            "movie/movies": #"{"metas":[{"id":"tt1","name":"Dune"},{"id":"tt2","name":"Arrival"}]}"#,
            "movie/films": #"{"metas":[{"id":"tt1","name":"Dune"},{"id":"tt3","name":"Heat"}]}"#,
            "tv/channels": #"{"metas":[{"id":"ch1","name":"Channel One"}]}"#,
            "series/shows": #"{"metas":[{"id":"tt9","name":"The Wire"}]}"#,
            "anime/kitsu": #"{"metas":[{"id":"kitsu:1","name":"Akira"}]}"#,
        ]
        let transport = StubTransport { request, _ in
            let path = request.url?.path ?? ""
            let body = bodies.first { path.contains("/catalog/\($0.key)/") }?.value ?? #"{"metas":[]}"#
            return StubTransport.response(Data(body.utf8), for: request)
        }
        let model = try await model(manifests: [movies, mixed], transport: transport)
        model.query = "x"
        await model.submit()
        #expect(model.groups.map(\.type) == ["movie", "series", "tv", "anime"], "movies, then series, then other types in order of first appearance")
        #expect(model.groups.map(\.title) == ["Movies", "Series", "Live TV", "Anime"])
        #expect(model.groups.first?.items.map(\.name) == ["Dune", "Arrival", "Heat"], "Dune from both addons appears once, in addon order")
        #expect(model.groups.first { $0.type == "tv" }?.items.map(\.name) == ["Channel One"])
    }

    @Test func aSeriesResultLandsInTheSeriesGroup() async throws {
        let shows = Manifest(id: "shows", name: "Shows", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["series"],
                             catalogs: [CatalogDescriptor(type: "series", id: "top", extra: [ExtraDescriptor(name: "search")])])
        let model = try await model(manifests: [shows], transport: stub())
        model.query = "wire"
        await model.submit()
        #expect(model.groups.map(\.title) == ["Series"])
        #expect(model.groups.first?.items.first?.type == "series")
        #expect(model.hasResults)
        #expect(!model.showsNoResults)
    }

    @Test func aRegistryWithOnlyStreamAddonsSaysSoWithoutAskingAnyone() async throws {
        let streams = Manifest(id: "streams", name: "Streams", version: "1", resources: [ResourceDescriptor(name: "stream", types: ["movie"])],
                               types: ["movie"])
        let transport = stub()
        let model = try await model(manifests: [streams], transport: transport)
        await model.refreshAvailability()
        #expect(!model.hasSearchableAddons)
        #expect(model.showsNoSearchableAddons)
        model.query = "dune"
        await model.submit()
        #expect(model.phase == .done)
        #expect(model.sections.isEmpty && model.failures.isEmpty)
        #expect(!model.showsNoResults)
        #expect(model.groups.isEmpty)
        #expect(transport.callCount == 0)
    }

    @Test func aNewQueryCancelsTheRunningSearch() async throws {
        let transport = stub()
        let model = try await model(manifests: [manifest("stub2")], transport: transport, debounce: .milliseconds(10))
        model.query = "first"
        model.queryDidChange()
        try await Task.sleep(for: .milliseconds(60))   // first search is in flight (150 ms answer)
        model.query = "second"
        model.queryDidChange()
        await model.waitUntilDone()
        #expect(model.sections.first?.items.first?.name == "second")
        #expect(model.sections.count == 1)
    }

    @Test func typingCancelsAnAlreadySubmittedSearchWithoutRestoringItsResults() async throws {
        let transport = submittedSearchTransport()
        let model = try await model(manifests: [manifest("a")], transport: transport, debounce: .zero)
        model.query = "first"
        let submitted = Task { await model.submit() }
        try await waitUntil { transport.callCount == 1 }
        model.query = "second"
        model.queryDidChange()
        await model.waitUntilDone()
        await submitted.value
        #expect(model.sections.first?.items.first?.name == "second")
        #expect(model.sections.count == 1 && model.phase == .done)
        #expect(model.recentQueries.isEmpty, "a search records no query; a title opened from it does")
    }

    @Test func clearingTheFieldCancelsAnAlreadySubmittedSearch() async throws {
        let transport = submittedSearchTransport()
        let model = try await model(manifests: [manifest("a")], transport: transport)
        model.query = "first"
        let submitted = Task { await model.submit() }
        try await waitUntil { transport.callCount == 1 }
        model.query = ""
        model.queryDidChange()
        await submitted.value
        #expect(model.phase == .idle && model.sections.isEmpty && model.failures.isEmpty)
        #expect(model.recentQueries.isEmpty)
    }

    @Test func cancellingTheSubmitCallerAlsoCancelsItsSearch() async throws {
        let transport = submittedSearchTransport()
        let model = try await model(manifests: [manifest("a")], transport: transport)
        model.query = "first"
        let submitted = Task { await model.submit() }
        try await waitUntil { transport.callCount == 1 }
        submitted.cancel()
        await submitted.value
        #expect(model.sections.isEmpty && model.recentQueries.isEmpty)
    }

    private func submittedSearchTransport() -> StubTransport {
        StubTransport { request, _ in
            let term = request.url?.path.components(separatedBy: "search=").last?.replacingOccurrences(of: ".json", with: "") ?? ""
            if term == "first" { try? await Task.sleep(for: .milliseconds(200)) }
            return StubTransport.response(Data(#"{"metas":[{"id":"\#(term)","name":"\#(term)"}]}"#.utf8), for: request)
        }
    }

    // MARK: browse genres

    private func genreManifest(_ options: [String], type: String = "movie") -> Manifest {
        Manifest(id: "genres.\(type)", name: "Genres", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: [type],
                 catalogs: [CatalogDescriptor(type: type, id: "films", extra: [ExtraDescriptor(name: "genre", options: options)])])
    }

    @Test func browseGenresComeFromTheMovieCatalogAndSkipBlanksAndRepeats() async throws {
        let shows = Manifest(id: "shows", name: "Shows", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["series"],
                             catalogs: [CatalogDescriptor(type: "series", id: "top", extra: [ExtraDescriptor(name: "genre", options: ["Drama"])])])
        let films = Manifest(id: "films", name: "Films", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
                             catalogs: [CatalogDescriptor(type: "movie", id: "films",
                                 extra: [ExtraDescriptor(name: "genre", options: ["Action", "Comedy", "Action", "  "])])])
        let model = try await model(manifests: [shows, films], transport: stub())
        await model.refreshAvailability()
        #expect(model.browseGenres.map(\.name) == ["Action", "Comedy"], "the movie catalog wins over the series one listed before it")
        let first = try #require(model.browseGenres.first)
        #expect(first.source == .addonCatalog(AddonCatalogReference(manifestID: nil, host: "stub1.example.com", catalogType: "movie",
                                                                    catalogID: "films", genre: "Action")))
    }

    @Test func aSeriesCatalogIsUsedWhenNoMovieCatalogHasGenres() async throws {
        let shows = Manifest(id: "shows", name: "Shows", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["series"],
                             catalogs: [CatalogDescriptor(type: "series", id: "top", extra: [ExtraDescriptor(name: "genre", options: ["Drama", "Crime"])])])
        let model = try await model(manifests: [shows], transport: stub())
        await model.refreshAvailability()
        #expect(model.browseGenres.map(\.name) == ["Drama", "Crime"])
        #expect(model.browseGenres.last?.source == .addonCatalog(AddonCatalogReference(manifestID: nil, host: "stub0.example.com", catalogType: "series",
                                                                                       catalogID: "top", genre: "Crime")))
    }

    @Test func browseGenresAreCappedAtSixteen() async throws {
        let model = try await model(manifests: [genreManifest((1...20).map { "Genre \($0)" })], transport: stub())
        await model.refreshAvailability()
        #expect(model.browseGenres.count == 16)
        #expect(model.browseGenres.last?.name == "Genre 16")
    }

    @Test func noShortcutsWithoutGenresOrWithOnlyRequiredGenreCatalogs() async throws {
        let plain = Manifest(id: "plain", name: "Plain", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie"],
                             catalogs: [CatalogDescriptor(type: "movie", id: "top")])
        let model = try await model(manifests: [plain], transport: stub())
        await model.refreshAvailability()
        #expect(model.browseGenres.isEmpty)
        // A catalog that needs a genre to open cannot be browsed as a plain row, so it offers no shortcuts either.
        var required = genreManifest(["Action"])
        required.catalogs[0].extra[0].isRequired = true
        let other = try await self.model(manifests: [required], transport: stub())
        await other.refreshAvailability()
        #expect(other.browseGenres.isEmpty)
    }

    // MARK: recent searches

    @Test func aSearchRecordsNothingAndATitleIsRecordedTrimmed() async throws {
        let store = InMemorySearchHistoryStore()
        let model = try await model(manifests: [manifest("a")], transport: stub(), history: store)
        #expect(model.recentQueries.isEmpty)
        model.query = "  Dune  "
        await model.submit()
        #expect(model.recentQueries.isEmpty && store.load().isEmpty, "a search alone records nothing")
        #expect(SearchViewModel.recording("  Dune  ", into: []) == ["Dune"], "a title opened is recorded trimmed")
    }

    @Test func aSearchThatFoundNothingOrFailedIsNotRemembered() async throws {
        let store = InMemorySearchHistoryStore()
        let empty = try await model(manifests: [manifest("a")], transport: StubTransport(data: Data(#"{"metas":[]}"#.utf8)), history: store)
        empty.query = "zzz"
        await empty.submit()
        #expect(empty.recentQueries.isEmpty)
        let failing = try await model(manifests: [manifest("a")], transport: StubTransport(data: Data(), status: 500), history: store)
        failing.query = "dune"
        await failing.submit()
        #expect(failing.recentQueries.isEmpty && store.load().isEmpty)
    }

    @Test func recentsAreNewestFirstWithOneCopyOfEachTitle() {
        var recents: [String] = []
        for title in ["dune", "arrival", "Dune"] {
            recents = SearchViewModel.recording(title, into: recents)
        }
        #expect(recents == ["Dune", "arrival"], "a repeat moves to the top, in its newest spelling")
    }

    @Test func recentsAreCappedAtFour() {
        var recents: [String] = []
        for index in 1...9 {
            recents = SearchViewModel.recording("q\(index)", into: recents)
        }
        #expect(recents.count == 4)
        #expect(recents.first == "q9" && recents.last == "q6")
    }

    @Test func recentsAreLoadedFromTheStoreAndCleanedUp() async throws {
        let store = InMemorySearchHistoryStore(["a", " ", "B", "A ", "c"])
        let model = try await model(manifests: [manifest("a")], transport: stub(), history: store)
        #expect(model.recentQueries == ["a", "B", "c"])
    }

    @Test func recentsSurviveANewScreen() async throws {
        let store = InMemorySearchHistoryStore()
        store.save(SearchViewModel.recording("Heat", into: store.load()))
        let second = try await model(manifests: [manifest("a")], transport: stub(), history: store)
        #expect(second.recentQueries == ["Heat"])
    }

    @Test func clearingHistoryOutsideSearchDoesNotRestoreOldQueries() async throws {
        let store = InMemorySearchHistoryStore(["Old search"])
        let model = try await model(manifests: [manifest("a")], transport: stub(), history: store)
        store.save([])
        await model.refreshAvailability()
        #expect(model.recentQueries.isEmpty)
        model.query = "New search"
        await model.submit()
        #expect(store.load().isEmpty, "a search does not write to the store")
    }

    @Test func aRecentCanBeRemovedWhateverItsCase() async throws {
        let store = InMemorySearchHistoryStore(["Dune", "Arrival", "Heat"])
        let model = try await model(manifests: [manifest("a")], transport: stub(), history: store)
        model.removeRecent("dune")
        #expect(model.recentQueries == ["Arrival", "Heat"])
        #expect(store.load() == ["Arrival", "Heat"], "the removal is saved")
        model.clearRecents()
        #expect(model.recentQueries.isEmpty && store.load().isEmpty)
    }
}
