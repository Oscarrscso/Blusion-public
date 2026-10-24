import Foundation
import Testing
@testable import StremioKit

/// Shuffling a widget's titles and Home's widgets: when a new order comes, and that an order stays until then.
@Suite struct WidgetShuffleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 16) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    // MARK: When the next order comes

    @Test func hourlyAndDailyTurnOverOnTheClock() {
        var random = SeededRandom(seed: 1)
        #expect(WidgetShuffle.hourly.next(after: date(14, 37), calendar: calendar, random: &random) == date(15))
        #expect(WidgetShuffle.daily.next(after: date(14, 37), calendar: calendar, random: &random) == date(0, day: 17))
        #expect(WidgetShuffle.off.next(after: date(14), calendar: calendar, random: &random) == nil)
        #expect(WidgetShuffle.everyOpen.next(after: date(14), calendar: calendar, random: &random) == nil)
    }

    @Test func randomTimesFallInsideTheirWindow() throws {
        var random = SeededRandom(seed: 7)
        for _ in 0..<50 {
            let next = try #require(WidgetShuffle.randomTimes(minHours: 1, maxHours: 6).next(after: date(10), calendar: calendar, random: &random))
            let hours = next.timeIntervalSince(date(10)) / 3600
            #expect((1...6).contains(hours))
        }
    }

    // MARK: Keeping an order

    @Test func anOrderStaysUntilItsTimeThenANewOneComes() throws {
        var random = SeededRandom(seed: 3)
        let first = try #require(ShuffleState.resolve(nil, schedule: .hourly, now: date(14, 5), calendar: calendar, random: &random))
        #expect(first.until == date(15))
        let later = ShuffleState.resolve(first, schedule: .hourly, now: date(14, 59), calendar: calendar, random: &random)
        #expect(later == first, "the same order within the hour")
        let next = try #require(ShuffleState.resolve(first, schedule: .hourly, now: date(15, 1), calendar: calendar, random: &random))
        #expect(next.seed != first.seed && next.until == date(16))
    }

    @Test func everyOpenMakesANewOrderEachTimeAndOffMakesNone() throws {
        var random = SeededRandom(seed: 5)
        let first = try #require(ShuffleState.resolve(nil, schedule: .everyOpen, now: date(9), calendar: calendar, random: &random))
        let second = try #require(ShuffleState.resolve(first, schedule: .everyOpen, now: date(9), calendar: calendar, random: &random))
        #expect(first.seed != second.seed)
        #expect(ShuffleState.resolve(first, schedule: .off, now: date(9), calendar: calendar, random: &random) == nil)
    }

    @Test func theSameSeedGivesTheSameOrder() {
        let items = Array(1...30)
        #expect(items.shuffled(seed: 42) == items.shuffled(seed: 42))
        #expect(items.shuffled(seed: 42) != items.shuffled(seed: 43))
        #expect(items.shuffled(seed: 42).sorted() == items)
    }

    // MARK: Home

    private let source = WidgetSource.addonCatalog(AddonCatalogReference(manifestID: "a", catalogType: "movie", catalogID: "top"))

    private func row(_ id: String, shuffle: WidgetShuffle? = nil) -> HomeWidget {
        HomeWidget(id: id, title: id, content: .row(RowConfiguration(source: source, shuffle: shuffle)))
    }

    @Test func withShuffleOffNothingChanges() {
        var random = SeededRandom(seed: 9)
        var states: [String: ShuffleState] = [:]
        let widgets = [row("a"), row("b"), HomeWidget(id: "cw", title: "Continue", content: .continueWatching)]
        let settings = WidgetShuffleSettings()
        #expect(WidgetShuffling.ordered(widgets, settings: settings, states: &states, now: date(9), calendar: calendar, random: &random) == widgets)
        #expect(WidgetShuffling.itemSeeds(for: widgets, settings: settings, states: &states, now: date(9), calendar: calendar,
                                          random: &random).isEmpty)
        #expect(states.isEmpty)
    }

    @Test func aWidgetsOwnShuffleWinsOverThePagesSetting() {
        var random = SeededRandom(seed: 9)
        var states: [String: ShuffleState] = [:]
        let widgets = [row("own", shuffle: .daily), row("never", shuffle: .off), row("follows")]
        let seeds = WidgetShuffling.itemSeeds(for: widgets, settings: WidgetShuffleSettings(schedule: .hourly), states: &states,
                                              now: date(9), calendar: calendar, random: &random)
        #expect(Set(seeds.keys) == ["own", "follows"])
        #expect(states["own"]?.until == date(0, day: 17) && states["follows"]?.until == date(10))
    }

    @Test func shufflingHomeKeepsTheShowcaseAndContinueWatchingInPlace() {
        let showcase = HomeWidget(id: "hero", title: "Spotlight", hideTitle: true, content: .hero(RowConfiguration(source: source)))
        let continueWatching = HomeWidget(id: "cw", title: "Continue", content: .continueWatching)
        let widgets = [showcase, continueWatching] + (1...8).map { row("r\($0)") }
        for seed in [UInt64(1), 2, 3, 99] {
            let shuffled = WidgetShuffling.reordered(widgets, seed: seed)
            #expect(shuffled[0] == showcase && shuffled[1] == continueWatching)
            #expect(Set(shuffled.map(\.id)) == Set(widgets.map(\.id)))
        }
        #expect(WidgetShuffling.reordered(widgets, seed: 1) != widgets)
    }

    @Test func removingAWidgetLeavesTheOthersInTheirShuffledOrder() {
        let widgets = (1...10).map { row("r\($0)") }
        let shuffled = WidgetShuffling.reordered(widgets, seed: 77).map(\.id)
        let fewer = WidgetShuffling.reordered(widgets.filter { $0.id != "r4" }, seed: 77).map(\.id)
        #expect(fewer == shuffled.filter { $0 != "r4" })
    }

    @Test func homesOrderIsShuffledOnlyWhenAskedAndStaysUntilItsTime() {
        var random = SeededRandom(seed: 11)
        var states: [String: ShuffleState] = [:]
        let widgets = (1...8).map { row("r\($0)") }
        var settings = WidgetShuffleSettings(schedule: .daily)
        #expect(WidgetShuffling.ordered(widgets, settings: settings, states: &states, now: date(9), calendar: calendar, random: &random) == widgets)
        settings.shufflesOrder = true
        let first = WidgetShuffling.ordered(widgets, settings: settings, states: &states, now: date(9), calendar: calendar, random: &random)
        let again = WidgetShuffling.ordered(widgets, settings: settings, states: &states, now: date(20), calendar: calendar, random: &random)
        #expect(first == again, "the same order the same day")
        #expect(first != widgets)
    }

    @Test func seedsOfRemovedWidgetsAreLetGo() {
        var random = SeededRandom(seed: 2)
        var states = ["gone": ShuffleState(seed: 1, until: nil), ShuffleKeys.order: ShuffleState(seed: 2, until: nil)]
        _ = WidgetShuffling.itemSeeds(for: [row("a", shuffle: .daily)], settings: WidgetShuffleSettings(), states: &states,
                                      now: date(9), calendar: calendar, random: &random)
        #expect(Set(states.keys) == ["a", ShuffleKeys.order])
    }

    // MARK: Saved widgets

    @Test func aSavedWidgetWithoutAShuffleReadsAsBefore() throws {
        let row = RowConfiguration(source: source)
        let written = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
        #expect(!written.contains("shuffle"), "nothing is written for a widget without one")
        #expect(try JSONDecoder().decode(RowConfiguration.self, from: Data(written.utf8)) == row)
        var shuffled = row
        shuffled.shuffle = .randomTimes(minHours: 3, maxHours: 12)
        #expect(try JSONDecoder().decode(RowConfiguration.self, from: JSONEncoder().encode(shuffled)) == shuffled)
    }

    @Test func theStoreKeepsSettingsAndSeedsAndClears() async throws {
        let suite = "widget-shuffle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DefaultsWidgetShuffleStore(defaults: defaults)
        #expect(await store.settings() == WidgetShuffleSettings())
        let settings = WidgetShuffleSettings(schedule: .hourly, shufflesOrder: true)
        await store.save(settings)
        await store.save(["a": ShuffleState(seed: 7, until: date(10))])
        let reopened = DefaultsWidgetShuffleStore(defaults: defaults)
        #expect(await reopened.settings() == settings)
        #expect(await reopened.states()["a"] == ShuffleState(seed: 7, until: date(10)))
        await store.clear()
        #expect(await reopened.settings() == WidgetShuffleSettings())
        #expect(await reopened.states().isEmpty)
    }
}
