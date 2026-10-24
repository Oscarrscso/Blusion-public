import Foundation

/// When a widget's items, or Home's widgets, take a new random order. The order is kept between times: it does not change on every
/// redraw, only when the next time comes.
public enum WidgetShuffle: Sendable, Equatable, Hashable, Codable {
    /// Never: the order the source gives.
    case off
    /// A new order each time Home opens.
    case everyOpen
    /// A new order at the start of every hour.
    case hourly
    /// A new order at the start of every day.
    case daily
    /// A new order at a random time between `minHours` and `maxHours` after the last one.
    case randomTimes(minHours: Int, maxHours: Int)

    /// The windows offered for random times.
    public static let randomWindows: [(minHours: Int, maxHours: Int)] = [(1, 6), (3, 12), (6, 24)]

    /// Every schedule offered, in the order the menus list them.
    public static var choices: [WidgetShuffle] {
        [.off, .everyOpen, .hourly, .daily] + randomWindows.map { .randomTimes(minHours: $0.minHours, maxHours: $0.maxHours) }
    }

    /// When an order made at `date` gives way to the next: the start of the next hour or day, a random time in the window, or nil for
    /// every open (each opening makes a new one) and off (never).
    public func next(after date: Date, calendar: Calendar, random: inout some RandomNumberGenerator) -> Date? {
        switch self {
        case .off, .everyOpen:
            return nil
        case .hourly:
            let start = calendar.dateInterval(of: .hour, for: date)?.start ?? date
            return calendar.date(byAdding: .hour, value: 1, to: start)
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
        case .randomTimes(let low, let high):
            let lowest = max(1, min(low, high))
            let highest = max(lowest, max(low, high))
            let seconds = Double.random(in: Double(lowest) * 3600...Double(highest) * 3600, using: &random)
            return date.addingTimeInterval(seconds)
        }
    }
}

/// A row that takes its items from a source picked at random: from `sources`, or from every catalog of the installed addons when it is
/// empty, picked again on `schedule`.
public struct RandomSource: Sendable, Codable, Equatable, Hashable {
    public var sources: [WidgetSource]
    public var schedule: WidgetShuffle

    public init(sources: [WidgetSource] = [], schedule: WidgetShuffle = .daily) {
        self.sources = sources
        self.schedule = schedule
    }

    /// True when the pick is from every catalog of the installed addons.
    public var usesAllSources: Bool { sources.isEmpty }
}

/// The order a widget, or Home, keeps until its next shuffle: the seed it is shuffled with and when that seed gives way.
public struct ShuffleState: Sendable, Equatable, Codable {
    public var seed: UInt64
    /// Nil keeps the seed only for the current opening of Home (every open).
    public var until: Date?

    public init(seed: UInt64, until: Date?) {
        self.seed = seed
        self.until = until
    }

    /// The state to use now: the current one while its time has not come, else a new seed with its next time. Nil when `schedule` is
    /// off. Every open makes a new seed each time this is asked, so it is asked once per opening of Home.
    public static func resolve(_ current: ShuffleState?, schedule: WidgetShuffle, now: Date, calendar: Calendar,
                               random: inout some RandomNumberGenerator) -> ShuffleState? {
        if schedule == .off { return nil }
        if schedule != .everyOpen, let current, let until = current.until, now < until { return current }
        return ShuffleState(seed: random.next(), until: schedule.next(after: now, calendar: calendar, random: &random))
    }
}

/// A random number generator that gives the same numbers for the same seed (SplitMix64), so an order can be made again from its seed.
public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

extension Array {
    /// The elements in the order `seed` gives: the same seed, the same order.
    public func shuffled(seed: UInt64) -> [Element] {
        var random = SeededRandom(seed: seed)
        return shuffled(using: &random)
    }
}

/// The shuffle settings on the widgets page: the schedule for every widget that has none of its own, and whether Home's widgets take a
/// new order on that schedule too.
public struct WidgetShuffleSettings: Sendable, Equatable, Codable {
    public var schedule: WidgetShuffle
    public var shufflesOrder: Bool

    public init(schedule: WidgetShuffle = .off, shufflesOrder: Bool = false) {
        self.schedule = schedule
        self.shufflesOrder = shufflesOrder
    }
}

/// Where the shuffle settings and every order's seed are kept.
public protocol WidgetShuffleStore: Sendable {
    func settings() async -> WidgetShuffleSettings
    func save(_ settings: WidgetShuffleSettings) async
    /// The seeds, by widget id, and by `ShuffleKeys.order` for Home's own order.
    func states() async -> [String: ShuffleState]
    func save(_ states: [String: ShuffleState]) async
    func clear() async
}

public enum ShuffleKeys {
    /// The seed of Home's widget order.
    public static let order = "home.order"

    /// The seed of a widget's random source.
    public static func source(of id: String) -> String { "\(id)#source" }
}

public actor InMemoryWidgetShuffleStore: WidgetShuffleStore {
    private var stored: WidgetShuffleSettings
    private var seeds: [String: ShuffleState] = [:]

    public init(_ settings: WidgetShuffleSettings = WidgetShuffleSettings()) {
        stored = settings
    }

    public func settings() async -> WidgetShuffleSettings { stored }
    public func save(_ settings: WidgetShuffleSettings) async { stored = settings }
    public func states() async -> [String: ShuffleState] { seeds }
    public func save(_ states: [String: ShuffleState]) async { seeds = states }

    public func clear() async {
        stored = WidgetShuffleSettings()
        seeds = [:]
    }
}

/// JSON in UserDefaults: the settings under "widgets.shuffle.settings.v1", the seeds under "widgets.shuffle.seeds.v1".
public final class DefaultsWidgetShuffleStore: WidgetShuffleStore, @unchecked Sendable {
    public static let settingsKey = "widgets.shuffle.settings.v1"
    public static let seedsKey = "widgets.shuffle.seeds.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Unreadable data reads as the defaults: shuffle off.
    public func settings() async -> WidgetShuffleSettings {
        lock.withLock {
            defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(WidgetShuffleSettings.self, from: $0) }
                ?? WidgetShuffleSettings()
        }
    }

    public func save(_ settings: WidgetShuffleSettings) async {
        lock.withLock { defaults.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey) }
    }

    public func states() async -> [String: ShuffleState] {
        lock.withLock {
            defaults.data(forKey: Self.seedsKey).flatMap { try? JSONDecoder().decode([String: ShuffleState].self, from: $0) } ?? [:]
        }
    }

    public func save(_ states: [String: ShuffleState]) async {
        lock.withLock {
            guard !states.isEmpty, let data = try? JSONEncoder().encode(states) else {
                defaults.removeObject(forKey: Self.seedsKey)
                return
            }
            defaults.set(data, forKey: Self.seedsKey)
        }
    }

    public func clear() async {
        lock.withLock {
            defaults.removeObject(forKey: Self.settingsKey)
            defaults.removeObject(forKey: Self.seedsKey)
        }
    }
}

/// Puts Home's widgets and their items in the order the shuffle settings give.
public enum WidgetShuffling {
    /// The schedule a widget follows: its own, or the widgets page's when it has none. Widgets that load no items have none.
    public static func schedule(for widget: HomeWidget, settings: WidgetShuffleSettings) -> WidgetShuffle {
        switch widget.content {
        case .hero(let row), .banner(let row), .row(let row): row.shuffle ?? settings.schedule
        case .collection, .continueWatching, .unsupported: .off
        }
    }

    /// The seeds to use for this opening of Home, by widget id, and the states to keep (`states`, updated in place). A widget without a
    /// shuffle has no seed and loses its state.
    public static func itemSeeds(for widgets: [HomeWidget], settings: WidgetShuffleSettings, states: inout [String: ShuffleState],
                                 now: Date, calendar: Calendar, random: inout some RandomNumberGenerator) -> [String: UInt64] {
        var seeds: [String: UInt64] = [:]
        for widget in widgets {
            let state = ShuffleState.resolve(states[widget.id], schedule: schedule(for: widget, settings: settings), now: now,
                                             calendar: calendar, random: &random)
            states[widget.id] = state
            if let state { seeds[widget.id] = state.seed }
        }
        // Seeds of widgets no longer in the layout are let go.
        let ids = widgets.map(\.id)
        let kept = Set(ids).union(ids.map(ShuffleKeys.source(of:))).union([ShuffleKeys.order])
        states = states.filter { kept.contains($0.key) }
        return seeds
    }

    // MARK: Random sources

    /// Every catalog of the enabled addons, in the user's order: what a random source picks from when it has no sources of its own.
    public static func allSources(in addons: [InstalledAddon]) -> [WidgetSource] {
        var seen = Set<AddonCatalogReference>()
        var sources: [WidgetSource] = []
        for addon in addons where addon.isEnabled {
            for catalog in addon.manifest.browsableCatalogs() {
                let reference = AddonCatalogReference(manifestID: addon.manifest.id, host: addon.displayHost, catalogType: catalog.type,
                                                      catalogID: catalog.id)
                if seen.insert(reference).inserted { sources.append(.addonCatalog(reference)) }
            }
        }
        return sources
    }

    /// The source `seed` picks from `pool`, or nil from an empty pool.
    public static func pick(from pool: [WidgetSource], seed: UInt64) -> WidgetSource? {
        guard !pool.isEmpty else { return nil }
        var random = SeededRandom(seed: seed)
        return pool[Int(random.next() % UInt64(pool.count))]
    }

    /// A source's name as a row's title: "Popular Movies", "Trending Shows", a Trakt list's name. Nil when it cannot be named.
    public static func title(of source: WidgetSource, in addons: [InstalledAddon]) -> String? {
        switch source {
        case .addonCatalog(let reference):
            guard let match = reference.resolve(in: addons) else { return nil }
            return DefaultWidgets.rowTitle(catalogName: match.catalog.name, type: match.catalog.type)
        case .traktList(let list): return list.listName
        case .traktFeed(let feed): return feed.title
        case .tmdbDiscover(let query): return query.title
        case .unsupported: return nil
        }
    }

    /// The widgets with each random source picked: the row takes the picked source, and its title is that source's name. A pick stays
    /// until its schedule's next time (its seed is kept in `states`). A pool with nothing in it leaves the widget as it is.
    public static func pickingSources(_ widgets: [HomeWidget], addons: [InstalledAddon], states: inout [String: ShuffleState],
                                      now: Date, calendar: Calendar, random: inout some RandomNumberGenerator) -> [HomeWidget] {
        let every = allSources(in: addons)
        return widgets.map { widget in
            let key = ShuffleKeys.source(of: widget.id)
            guard var row = loadingRow(of: widget), let setting = row.randomSource else {
                states[key] = nil
                return widget
            }
            // A ticked catalog whose addon has since been removed or turned off is left out; with none left, every catalog is the pool.
            let available = setting.sources.filter { source in
                guard case .addonCatalog(let reference) = source else { return true }
                return reference.resolve(in: addons.filter(\.isEnabled)) != nil
            }
            let pool = available.isEmpty ? every : available
            // A random source always picks again on some schedule: one saved as off picks daily.
            let schedule = setting.schedule == .off ? WidgetShuffle.daily : setting.schedule
            let state = ShuffleState.resolve(states[key], schedule: schedule, now: now, calendar: calendar, random: &random)
            states[key] = state
            guard let state, let picked = pick(from: pool, seed: state.seed) else { return widget }
            row.source = picked
            var result = widget
            result.content = replacingRow(of: widget.content, with: row)
            if let name = title(of: picked, in: addons) { result.title = name }
            return result
        }
    }

    private static func loadingRow(of widget: HomeWidget) -> RowConfiguration? {
        switch widget.content {
        case .hero(let row), .banner(let row), .row(let row): row
        case .collection, .continueWatching, .unsupported: nil
        }
    }

    private static func replacingRow(of content: HomeWidget.Content, with row: RowConfiguration) -> HomeWidget.Content {
        switch content {
        case .hero: .hero(row)
        case .banner: .banner(row)
        case .row: .row(row)
        case .collection, .continueWatching, .unsupported: content
        }
    }

    /// Home's widgets in a new order when the widgets page shuffles them, on its schedule. The showcase stays first and Continue
    /// Watching keeps its place (see `HomeLayout`); the others take each other's places.
    public static func ordered(_ widgets: [HomeWidget], settings: WidgetShuffleSettings, states: inout [String: ShuffleState],
                               now: Date, calendar: Calendar, random: inout some RandomNumberGenerator) -> [HomeWidget] {
        let schedule = settings.shufflesOrder ? settings.schedule : .off
        guard let state = ShuffleState.resolve(states[ShuffleKeys.order], schedule: schedule, now: now, calendar: calendar,
                                               random: &random) else {
            states[ShuffleKeys.order] = nil
            return widgets
        }
        states[ShuffleKeys.order] = state
        return reordered(widgets, seed: state.seed)
    }

    /// The widgets with every movable one in the order `seed` gives. The showcase and Continue Watching stay where they are. Each widget
    /// is ranked by its own id and the seed, so adding or removing one widget leaves the others in the same order among themselves.
    public static func reordered(_ widgets: [HomeWidget], seed: UInt64) -> [HomeWidget] {
        let fixed = { (widget: HomeWidget) in HomeLayout.isShowcase(widget) || HomeLayout.isContinueWatching(widget) }
        let places = widgets.indices.filter { !fixed(widgets[$0]) }
        let moved = places.map { widgets[$0] }.sorted { rank($0.id, seed: seed) < rank($1.id, seed: seed) }
        var result = widgets
        for (place, widget) in zip(places, moved) { result[place] = widget }
        return result
    }

    /// A widget's place in a shuffled order: the seed mixed with a hash of its id (FNV-1a), the same on every launch.
    private static func rank(_ id: String, seed: UInt64) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        var random = SeededRandom(seed: seed ^ hash)
        return random.next()
    }
}
