import Foundation
import Testing
@testable import Features

@Suite struct SearchHistoryTests {
    @Test func theInMemoryStoreKeepsWhatWasSaved() {
        let store = InMemorySearchHistoryStore()
        #expect(store.load().isEmpty)
        store.save(["dune", "heat"])
        #expect(store.load() == ["dune", "heat"])
        store.save([])
        #expect(store.load().isEmpty)
    }

    @Test func theDefaultsStoreUsesTheDocumentedKeyAndSurvivesARelaunch() throws {
        let name = "SearchHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(DefaultsSearchHistoryStore.key == "search.recentQueries")
        let store = DefaultsSearchHistoryStore(defaults: defaults)
        #expect(store.load().isEmpty)
        store.save(["dune", "Arrival"])
        #expect(store.load() == ["dune", "Arrival"])
        #expect(defaults.stringArray(forKey: "search.recentQueries") == ["dune", "Arrival"])
        // A new store on the same defaults, as after a relaunch, reads the same list.
        #expect(DefaultsSearchHistoryStore(defaults: defaults).load() == ["dune", "Arrival"])
    }
}
