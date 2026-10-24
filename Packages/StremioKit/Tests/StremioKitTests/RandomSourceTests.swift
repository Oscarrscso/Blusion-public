import Foundation
import Testing
@testable import StremioKit

/// A widget whose source is picked at random: from a set or from every catalog, kept until its next time, and named after the pick.
@Suite struct RandomSourceTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ hour: Int, day: Int = 16) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private static let manifest = Manifest(
        id: "test.cinemeta", name: "Cinemeta", version: "1", resources: [ResourceDescriptor(name: "catalog")], types: ["movie", "series"],
        catalogs: [CatalogDescriptor(type: "movie", id: "top", name: "Popular"), CatalogDescriptor(type: "series", id: "trending", name: "Trending"),
                   CatalogDescriptor(type: "movie", id: "search", name: "Search", extra: [ExtraDescriptor(name: "search", isRequired: true)])])

    private var addons: [InstalledAddon] {
        [InstalledAddon(id: UUID(), manifestURL: URL(string: "https://addon.example.com/manifest.json")!,
                        baseURL: URL(string: "https://addon.example.com")!, manifest: Self.manifest, isEnabled: true, installedAt: Date())]
    }

    private func catalog(_ id: String, _ type: String = "movie") -> WidgetSource {
        .addonCatalog(AddonCatalogReference(manifestID: "test.cinemeta", host: "addon.example.com", catalogType: type, catalogID: id))
    }

    private func widget(_ random: RandomSource?) -> HomeWidget {
        HomeWidget(id: "w", title: "My Row", content: .row(RowConfiguration(source: catalog("top"), randomSource: random)))
    }

    @Test func allSourcesAreEveryBrowsableCatalog() {
        #expect(WidgetShuffling.allSources(in: addons) == [catalog("top"), catalog("trending", "series")], "a search-only catalog is left out")
    }

    @Test func thePickComesFromTheSetAndTheSameSeedPicksTheSame() {
        let pool = [catalog("a"), catalog("b"), catalog("c")]
        for seed in [UInt64(1), 2, 3, 42] {
            let picked = WidgetShuffling.pick(from: pool, seed: seed)
            #expect(picked.map(pool.contains) == true)
            #expect(picked == WidgetShuffling.pick(from: pool, seed: seed))
        }
        #expect(Set((0..<60).compactMap { WidgetShuffling.pick(from: pool, seed: UInt64($0)) }).count == 3, "every source gets picked")
        #expect(WidgetShuffling.pick(from: [], seed: 1) == nil)
    }

    @Test func aPickedSourceNamesTheWidgetAndStaysUntilItsTime() throws {
        var random = SeededRandom(seed: 4)
        var states: [String: ShuffleState] = [:]
        let widgets = [widget(RandomSource(sources: [], schedule: .daily))]
        let first = try #require(WidgetShuffling.pickingSources(widgets, addons: addons, states: &states, now: date(9), calendar: calendar,
                                                                random: &random).first)
        guard case .row(let row) = first.content else { Issue.record("not a row"); return }
        #expect([catalog("top"), catalog("trending", "series")].contains(row.source))
        let named = row.source == catalog("top") ? DefaultWidgets.rowTitle(catalogName: "Popular", type: "movie")
            : DefaultWidgets.rowTitle(catalogName: "Trending", type: "series")
        #expect(first.title == named, "named after the source it picked")
        #expect(row.randomSource != nil, "it keeps its setting")
        let again = WidgetShuffling.pickingSources(widgets, addons: addons, states: &states, now: date(22), calendar: calendar, random: &random)
        #expect(again.first == first, "the same pick the same day")
        #expect(states[ShuffleKeys.source(of: "w")]?.until == date(0, day: 17))
    }

    @Test func aWidgetWithoutARandomSourceIsLeftAsItIs() {
        var random = SeededRandom(seed: 4)
        var states = [ShuffleKeys.source(of: "w"): ShuffleState(seed: 1, until: nil)]
        let plain = [widget(nil)]
        #expect(WidgetShuffling.pickingSources(plain, addons: addons, states: &states, now: date(9), calendar: calendar, random: &random) == plain)
        #expect(states.isEmpty, "a setting turned off lets its pick go")
    }

    @Test func aChosenSetIsPickedFrom() throws {
        var random = SeededRandom(seed: 8)
        var states: [String: ShuffleState] = [:]
        let picked = try #require(WidgetShuffling.pickingSources([widget(RandomSource(sources: [catalog("trending", "series")]))], addons: addons,
                                                                 states: &states, now: date(9), calendar: calendar, random: &random).first)
        guard case .row(let row) = picked.content else { Issue.record("not a row"); return }
        #expect(row.source == catalog("trending", "series") && picked.title == DefaultWidgets.rowTitle(catalogName: "Trending", type: "series"))
    }

    @Test func aTickedCatalogWhoseAddonIsGoneIsNotPicked() throws {
        var random = SeededRandom(seed: 3)
        var states: [String: ShuffleState] = [:]
        let gone = WidgetSource.addonCatalog(AddonCatalogReference(manifestID: "removed.addon", catalogType: "movie", catalogID: "vanished"))
        for day in 16...28 {
            states = [:]
            let picked = try #require(WidgetShuffling.pickingSources([widget(RandomSource(sources: [gone, catalog("trending", "series")]))],
                                                                     addons: addons, states: &states, now: date(9, day: day),
                                                                     calendar: calendar, random: &random).first)
            guard case .row(let row) = picked.content else { Issue.record("not a row"); return }
            #expect(row.source == catalog("trending", "series"))
        }
        let onlyGone = try #require(WidgetShuffling.pickingSources([widget(RandomSource(sources: [gone]))], addons: addons, states: &states,
                                                                   now: date(9), calendar: calendar, random: &random).first)
        guard case .row(let row) = onlyGone.content else { Issue.record("not a row"); return }
        #expect([catalog("top"), catalog("trending", "series")].contains(row.source), "with none left, every catalog")
    }

    @Test func withNoCatalogsAtAllTheWidgetIsLeftAsItIs() {
        var random = SeededRandom(seed: 3)
        var states: [String: ShuffleState] = [:]
        let widgets = [widget(RandomSource())]
        #expect(WidgetShuffling.pickingSources(widgets, addons: [], states: &states, now: date(9), calendar: calendar, random: &random) == widgets)
    }

    @Test func aRandomSourcesSeedIsKeptWhileItsWidgetIsInTheLayout() {
        var random = SeededRandom(seed: 3)
        var states = [ShuffleKeys.source(of: "w"): ShuffleState(seed: 1, until: nil),
                      ShuffleKeys.source(of: "gone"): ShuffleState(seed: 2, until: nil)]
        _ = WidgetShuffling.itemSeeds(for: [widget(RandomSource())], settings: WidgetShuffleSettings(), states: &states, now: date(9),
                                      calendar: calendar, random: &random)
        #expect(Set(states.keys) == [ShuffleKeys.source(of: "w")])
    }

    @Test func aSavedWidgetWithoutARandomSourceReadsAsBefore() throws {
        let row = RowConfiguration(source: catalog("top"))
        let written = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
        #expect(!written.contains("randomSource"))
        var random = row
        random.randomSource = RandomSource(sources: [catalog("top")], schedule: .hourly)
        #expect(try JSONDecoder().decode(RowConfiguration.self, from: JSONEncoder().encode(random)) == random)
    }
}
