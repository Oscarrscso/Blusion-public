import Foundation
import Observation
import PlayerKit
import StremioKit

/// Home: the user's widgets, or the automatic layout, as sections. Each hero and row loads on its own and fills in as its addon answers.
@MainActor
@Observable
public final class HomeViewModel {
    public enum Phase: Equatable {
        case loading
        /// Nothing installed: the empty state explains how to add an addon by URL.
        case noAddons
        /// Addons are installed, nothing is saved, and none offers a browsable catalog for the automatic layout.
        case noCatalogs
        case ready
    }

    public struct Section: Identifiable, Equatable {
        public let widget: HomeWidget
        /// Items of a `.hero`, `.banner` or `.row` widget. `.collection` and `.continueWatching` sections stay `.loaded([])`.
        public var state: Loadable<[MetaPreview]>
        /// Why a row has nothing to show (addon missing, Trakt client ID needed, unsupported source). nil when fine or still loading.
        public var issue: WidgetSourceError?
        /// True while the section shows items from before (this launch or the last) and a fresh load is on its way.
        public var isRefreshing = false
        public var id: String { widget.id }
    }

    public private(set) var phase: Phase = .loading
    public private(set) var sections: [Section] = []
    /// The seed each shuffled widget's items take on this opening of Home (see `WidgetShuffling`). A widget without a shuffle has none.
    private var itemSeeds: [String: UInt64] = [:]
    /// The widgets as saved, by id, before any shuffle or random source changed what Home shows: what a widget's export shares.
    public private(set) var layoutWidgets: [String: HomeWidget] = [:]
    /// The photo of each genre tile without a picture of its own, by `tilePhotoKey`: the artwork of a title in its genre, a different title
    /// for each tile of a widget. A tile without one yet shows its colours.
    public private(set) var tilePhotos: [String: URL] = [:]
    /// In-progress titles, newest first (`LibraryViewModel.continueWatching(from:)`).
    public private(set) var continueWatching: [WatchProgress] = []
    public enum ContinueState: Equatable { case loading, disconnected, ready, failed(String) }
    public private(set) var continueState: ContinueState = .loading
    public private(set) var continueEntries: [ContinueWatchingEntry] = []
    /// True when the user has saved their own widget list; false for the automatic layout.
    public private(set) var isCustomised = false

    private let services: AppServices
    private var generation = 0
    public private(set) var loadRevision = 0
    @ObservationIgnored private var requestedSections: Set<String> = []
    private var traktPlayback: [TraktPlaybackItem] = []
    private var refreshingPlayback = false
    private var lastPlaybackRefresh = Date.distantPast
    private var addonSignature: [String]?

    public init(services: AppServices) {
        self.services = services
    }

    /// Every hero/row section failed and every failure was "offline": show one banner instead of an error on every row.
    public var isOffline: Bool {
        let rows = sections.filter { loadingConfiguration($0.widget.content) != nil }
        let errors = rows.compactMap(\.state.error)
        return phase == .ready && !rows.isEmpty && errors.count == rows.count && Connectivity.isOffline(errors)
    }

    /// Rebuilds the sections from the saved widgets (or `DefaultWidgets.make(for:)`) and leaves row loading to viewport visibility.
    public func load() async {
        generation += 1
        let current = generation
        let addons = await services.registry.addons
        var saved = await services.widgets.load()
        // A saved layout without Continue Watching would have it drawn above the showcase, and one with its showcase out of place would
        // lead with another row: it is put right once, and saved, so the widgets page shows the same list. A layout that keeps Home's
        // rules is left as it is.
        if let list = saved {
            let repaired = HomeLayout.normalised(list)
            if repaired != list {
                await services.widgets.save(repaired)
                saved = repaired
            }
        }
        let local = await services.progress.all()
        let inProgress = LibraryViewModel.continueWatching(from: local)
        guard current == generation, !Task.isCancelled else { return }
        continueWatching = inProgress
        continueEntries = ContinueWatchingEntry.merge(local: local, remote: traktPlayback)
        isCustomised = saved != nil
        guard !addons.isEmpty else {
            sections = []
            phase = .noAddons
            HomeStartup.shared.markSettled()
            return
        }
        let laidOut = saved ?? DefaultWidgets.make(for: addons)
        layoutWidgets = Dictionary(laidOut.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let widgets = await shuffled(laidOut, addons: addons)
        guard current == generation, !Task.isCancelled else { return }
        let previous = sections
        sections = widgets.map { HomeViewModel.startingSection(for: $0, previous: previous, known: [:]) }
        requestedSections = []
        loadRevision += 1
        phase = (saved == nil && widgets.isEmpty) ? .noCatalogs : .ready
        if widgets.isEmpty { HomeStartup.shared.markSettled() }
    }

    /// Fetch only sections that enter the viewport. Completed sections keep their metadata when scrolled away.
    public func loadVisibleSection(_ id: String) async {
        guard !Task.isCancelled, !requestedSections.contains(id),
              let section = sections.first(where: { $0.id == id }) else { return }
        let current = generation
        if let row = loadingConfiguration(section.widget.content) {
            await showLastKnownItems(for: [(id, row)], generation: current)
            guard current == generation, !Task.isCancelled else { return }
            let result = await HomeViewModel.fetch(id: id, row: row, from: services.widgetContent, seed: itemSeeds[id])
            guard current == generation, !Task.isCancelled else { return }
            requestedSections.insert(id)
            apply(result)
            HomeStartup.shared.markSettled()
        } else if case .collection = section.widget.content {
            let widgets = [section.widget]
            let missing = await showKnownTilePhotos(for: widgets, generation: current)
            await loadTilePhotos(missing, widgets: widgets, generation: current)
            guard current == generation, !Task.isCancelled else { return }
            requestedSections.insert(id)
        }
    }

    /// Forgets every cached page, then loads again. The rows keep what they show until the new items arrive.
    public func refresh() async {
        await services.posterRatings.refresh()
        await services.widgetContent.invalidate()
        await refreshContinueWatching(force: true)
        await load()
    }

    /// Loads one hero or row again, after it failed.
    public func retry(sectionID: String) async {
        guard let index = sections.firstIndex(where: { $0.id == sectionID }),
              let row = loadingConfiguration(sections[index].widget.content) else { return }
        let current = generation
        sections[index].state = .loading
        sections[index].isRefreshing = false
        sections[index].issue = nil
        let result = await HomeViewModel.fetch(id: sectionID, row: row, from: services.widgetContent, seed: itemSeeds[sectionID])
        guard current == generation, !Task.isCancelled else { return }
        apply(result)
    }

    /// Turns Better Posters on or off for a poster row and saves the layout. The row keeps its items: only its cards change. Only a saved
    /// layout can change this way. Saving the automatic layout would stop it following the addons, so nothing is saved for it.
    public func setBetterPosters(_ on: Bool, sectionID: String) async {
        guard isCustomised, let index = sections.firstIndex(where: { $0.id == sectionID }),
              case .row(var row) = sections[index].widget.content,
              row.presentation.aspectRatio == .poster, row.presentation.usesBetterPosters != on else { return }
        row.presentation.usesBetterPosters = on
        var widget = sections[index].widget
        widget.content = .row(row)
        let current = sections[index]
        sections[index] = Section(widget: widget, state: current.state, issue: current.issue, isRefreshing: current.isRefreshing)
        isCustomised = true
        // Saved into the saved widget, in the saved layout's own order: Home may show its widgets shuffled, and a widget with a random
        // source shows the source it picked, not the ones it picks from.
        let saved = await services.widgets.load() ?? sections.map(\.widget)
        await services.widgets.save(saved.map { $0.id == sectionID ? HomeViewModel.withBetterPosters($0, on) : $0 })
        layoutWidgets[sectionID] = layoutWidgets[sectionID].map { HomeViewModel.withBetterPosters($0, on) }
    }

    /// Removes a widget from the layout, as the widgets page does. The change starts from the list as it is saved now, so an edit made
    /// elsewhere is not saved over. Nothing saved while this layout was customised means it was reset elsewhere: the change is refused,
    /// and Home shows the automatic layout again. From the automatic layout, the first removal saves the whole layout minus the widget.
    public func removeWidget(sectionID: String) async {
        guard sections.contains(where: { $0.id == sectionID }) else { return }
        let saved = await services.widgets.load()
        guard saved != nil || !isCustomised else {
            await load()
            return
        }
        let current = saved ?? sections.map(\.widget)
        guard current.contains(where: { $0.id == sectionID }) else {
            await load()
            return
        }
        isCustomised = true
        await services.widgets.save(current.filter { $0.id != sectionID })
        await services.widgetContent.invalidate()
        // Home drops the row in place only when it shows the list that was saved from. Otherwise the saved layout is loaded again, so
        // the screen matches it. A reload fetches every row, so it is not the usual path.
        guard current == sections.map(\.widget) else {
            await load()
            return
        }
        sections.removeAll { $0.id == sectionID }
    }

    /// Puts a copy of a widget straight after it, as the widgets page does, starting from the list as it is saved now. The copy shows what
    /// the original shows at once, so nothing is fetched again. Nothing saved while this layout was customised means it was reset
    /// elsewhere: the change is refused, and Home shows the automatic layout again.
    public func duplicateWidget(sectionID: String) async {
        guard sections.contains(where: { $0.id == sectionID }) else { return }
        let saved = await services.widgets.load()
        guard saved != nil || !isCustomised else {
            await load()
            return
        }
        let current = saved ?? sections.map(\.widget)
        guard let list = WidgetsManagerViewModel.duplicating(sectionID, in: current),
              let index = list.firstIndex(where: { $0.id == sectionID }) else { return }
        isCustomised = true
        await services.widgets.save(list)
        // Home adds the copy in place only when it shows the list that was saved from; otherwise it loads the saved layout again.
        guard current == sections.map(\.widget), let shown = sections.firstIndex(where: { $0.id == sectionID }) else {
            await load()
            return
        }
        let original = sections[shown]
        let copy = list[index + 1]
        sections.insert(Section(widget: copy, state: original.state, issue: original.issue, isRefreshing: original.isRefreshing),
                        at: shown + 1)
        // The copy keeps the same order; its viewport task loads it when needed.
        itemSeeds[copy.id] = itemSeeds[sectionID]
    }

    /// Cheap refresh for when Home reappears after something was watched: only Continue Watching changes.
    public func continueWatchingRefreshInterval() async -> Int {
        let settings = await services.settings.load()
        return max(0, settings.continueWatchingRefreshSeconds ?? 300)
    }

    public func refreshContinueWatching(force: Bool = false) async {
        let local = await services.progress.all()
        continueWatching = LibraryViewModel.continueWatching(from: local)
        continueEntries = ContinueWatchingEntry.merge(local: local, remote: traktPlayback)
        guard !refreshingPlayback else { return }
        refreshingPlayback = true
        defer { refreshingPlayback = false }
        guard await services.traktAccount.isSignedIn() else {
            traktPlayback = []
            continueEntries = ContinueWatchingEntry.merge(local: local, remote: [])
            continueState = .disconnected
            lastPlaybackRefresh = .distantPast
            return
        }
        let interval = await continueWatchingRefreshInterval()
        guard force || lastPlaybackRefresh == .distantPast
                || (interval > 0 && Date().timeIntervalSince(lastPlaybackRefresh) >= Double(interval)) else { return }
        let previousState = continueState
        lastPlaybackRefresh = Date()
        continueState = .loading
        do {
            let playback = try await services.traktAccount.playback()
            try Task.checkCancellation()
            guard await services.traktAccount.isSignedIn() else {
                traktPlayback = []
                continueState = .disconnected
                continueEntries = ContinueWatchingEntry.merge(local: await services.progress.all(), remote: [])
                return
            }
            traktPlayback = await services.traktSync.visiblePlayback(playback)
            await services.traktSync.storeRemotePlayback(traktPlayback)
            continueState = .ready
        } catch {
            if Task.isCancelled {
                continueState = previousState
                lastPlaybackRefresh = .distantPast
                return
            }
            continueState = .failed((error as? TraktAccountError)?.message ?? "Couldn’t load Trakt playback. Try again.")
        }
        let updated = await services.progress.all()
        continueWatching = LibraryViewModel.continueWatching(from: updated)
        continueEntries = ContinueWatchingEntry.merge(local: updated, remote: traktPlayback)
    }

    /// Takes a title off Continue Watching. The removal is queued for Trakt, which sync sends now or when Trakt can next be reached; Trakt's
    /// paused record stays hidden until it is gone.
    public func removeFromContinueWatching(_ entry: ContinueWatchingEntry) async {
        await services.removeContinueWatching(identity: entry.id)
        traktPlayback.removeAll { $0.id == entry.id }
        let local = await services.progress.all()
        continueWatching = LibraryViewModel.continueWatching(from: local)
        continueEntries = ContinueWatchingEntry.merge(local: local, remote: traktPlayback)
    }

    /// Marks the selected movie or episode watched, syncing its history and clearing Trakt's paused entry.
    public func markWatched(_ entry: ContinueWatchingEntry) async {
        guard !GhostMode.isOn else { return }
        let request = entry.request
        var record = await services.progress.progress(for: entry.id) ?? WatchProgress(
            id: entry.id, type: request.type, contentID: request.id, title: request.title,
            poster: request.poster, position: 0, duration: 0, isWatched: false,
            updatedAt: entry.updatedAt, season: request.season, episode: request.episode)
        record.isWatched = true
        record.isQueuedForContinue = false
        record.updatedAt = Date()
        await services.progress.save(record)
        await services.traktSync.playbackRemoved(entry.id)
        traktPlayback.removeAll { $0.id == entry.id }
        await services.queueNextContinueEpisode(after: request)
        let local = await services.progress.all()
        continueWatching = LibraryViewModel.continueWatching(from: local)
        continueEntries = ContinueWatchingEntry.merge(local: local, remote: traktPlayback)
    }

    /// Reloads whenever the set, order or enabled state of addons changes. Run from a view's `.task`; cancelling stops it.
    public func observeAddons() async {
        for await addons in await services.registry.updates() {
            guard !Task.isCancelled else { break }
            let newSignature = addons.map { "\($0.id.uuidString):\($0.isEnabled)" }
            // Returning from details keeps completed shelves intact. Interrupted loads still resume.
            guard newSignature != addonSignature || phase == .loading else { continue }
            await load()
            if !Task.isCancelled { addonSignature = newSignature }
        }
    }

    // MARK: Loading

    /// Fills the rows still waiting for their first items with their last-known ones, one row at a time from the top, each as soon as it
    /// is read. A row that already shows items keeps them.
    private func showLastKnownItems(for rows: [(id: String, row: RowConfiguration)], generation current: Int) async {
        let content = services.widgetContent
        for (id, row) in rows {
            guard current == generation, !Task.isCancelled else { return }
            guard let items = await HomeViewModel.knownItems(for: row, from: content, seed: itemSeeds[id]), !items.isEmpty else { continue }
            guard current == generation, !Task.isCancelled,
                  let index = sections.firstIndex(where: { $0.id == id }), sections[index].state.isLoading else { continue }
            sections[index].state = .loaded(items)
            sections[index].isRefreshing = true
        }
    }

    /// Applies a finished row load. A failure keeps the items the row already shows (stale content beats an error), but an issue
    /// (the source cannot load at all) always replaces them, so a removed addon's items do not linger.
    private func apply(_ result: RowResult) {
        guard !Task.isCancelled, result.state.error != .cancelled,
              let index = sections.firstIndex(where: { $0.id == result.id }) else { return }
        sections[index].isRefreshing = false
        if result.issue == nil, result.state.error != nil, let shown = sections[index].state.value, !shown.isEmpty { return }
        sections[index].state = result.state
        sections[index].issue = result.issue
    }

    /// The items of one row, in the order `seed` gives when the row is shuffled. The issue is checked first, so a source that cannot load
    /// (say, a removed addon) never answers from the cache.
    nonisolated private static func fetch(id: String, row: RowConfiguration, from content: WidgetContentService,
                                          seed: UInt64? = nil) async -> RowResult {
        if let issue = await content.issue(with: row.source) {
            return RowResult(id: id, state: .loaded([]), issue: issue)
        }
        do {
            let items = try await content.items(for: row.source, limit: row.limit, cacheTTL: row.cacheTTL)
            return RowResult(id: id, state: .loaded(seed.map(items.shuffled(seed:)) ?? items), issue: nil)
        } catch let error as WidgetSourceError {
            guard case .addon(let addonError) = error else { return RowResult(id: id, state: .loaded([]), issue: error) }
            return RowResult(id: id, state: .failed(addonError), issue: nil)
        } catch {
            return RowResult(id: id, state: .failed(AddonError.from(error)), issue: nil)
        }
    }

    /// The items a row can show before its fresh load. A source that cannot load shows nothing, so a removed addon's items never linger.
    nonisolated private static func knownItems(for row: RowConfiguration, from content: WidgetContentService,
                                               seed: UInt64?) async -> [MetaPreview]? {
        guard await content.issue(with: row.source) == nil else { return nil }
        let items = await content.lastKnownItems(for: row.source, limit: row.limit)
        return seed.flatMap { seed in items.map { $0.shuffled(seed: seed) } } ?? items
    }

    // MARK: Genre tile photos

    /// The key of a tile's photo in `tilePhotos`. It names the tile's sources too, so a tile edited to another genre never shows the old
    /// genre's photo. Only for this run of the app: the photos are not saved.
    nonisolated public static func tilePhotoKey(widgetID: String, tile: CollectionItem) -> String {
        "\(widgetID)/\(tile.id)/\(tile.sources.hashValue)"
    }

    /// Whether a collection tile stands for a genre and has no picture of its own: every source is a catalog filtered to a genre, or a
    /// TMDb list of named genres.
    nonisolated static func isGenreTile(_ tile: CollectionItem) -> Bool {
        tile.imageURL == nil && !tile.sources.isEmpty && tile.sources.allSatisfy { source in
            switch source {
            case .addonCatalog(let reference): return reference.genre?.isEmpty == false
            case .tmdbDiscover(let query): return !query.genres.isEmpty
            case .traktList, .traktFeed, .unsupported: return false
            }
        }
    }

    /// A photo for each tile, in order, from `items` by tile id: the artwork of the first title no earlier tile shows, the backdrop for a
    /// wide or square tile and the poster for a poster tile. A tile whose titles have no artwork left gets none.
    nonisolated static func tilePhotos(for tiles: [CollectionItem], items: [String: [MetaPreview]]) -> [String: URL] {
        var shownTitles = Set<String>()
        var shownPhotos = Set<URL>()
        var photos: [String: URL] = [:]
        for tile in tiles where photos[tile.id] == nil {
            for item in items[tile.id] ?? [] {
                guard let photo = tile.imageAspect == .poster ? item.poster : item.background,
                      !shownTitles.contains(item.identity), !shownPhotos.contains(photo) else { continue }
                photos[tile.id] = photo
                shownTitles.insert(item.identity)
                shownPhotos.insert(photo)
                break
            }
        }
        return photos
    }

    /// Gives every genre tile of the collections a photo from the titles last loaded for it, which asks nothing of the network. Returns the
    /// tiles nothing was ever loaded for, so `loadTilePhotos` can load them once the rows are in. Answers to an older `load()` are dropped.
    private func showKnownTilePhotos(for widgets: [HomeWidget], generation current: Int) async -> [(widgetID: String, tile: CollectionItem)] {
        let tiles = widgets.flatMap { widget -> [(widgetID: String, tile: CollectionItem)] in
            guard case .collection(let items) = widget.content else { return [] }
            return items.filter(HomeViewModel.isGenreTile).map { (widget.id, $0) }
        }
        guard !tiles.isEmpty else { return [] }
        let known = await HomeViewModel.tileItems(tiles, from: services.widgetContent, fresh: false)
        guard current == generation, !Task.isCancelled else { return [] }
        tilePhotos.merge(HomeViewModel.photos(widgets, items: known)) { _, new in new }
        return tiles.filter { known[HomeViewModel.tilePhotoKey(widgetID: $0.widgetID, tile: $0.tile)] == nil }
    }

    /// Loads the titles of the tiles nothing was known for, as the tile's grid asks for them, so the grid reuses the page and the next
    /// launch shows the photo at once from its snapshot. Each tile's photo is picked again with the known titles, so two tiles never share
    /// a title. Answers to an older `load()` are dropped.
    private func loadTilePhotos(_ tiles: [(widgetID: String, tile: CollectionItem)], widgets: [HomeWidget], generation current: Int) async {
        guard !tiles.isEmpty, current == generation, !Task.isCancelled else { return }
        let content = services.widgetContent
        let fresh = await HomeViewModel.tileItems(tiles, from: content, fresh: true)
        guard current == generation, !Task.isCancelled, !fresh.isEmpty else { return }
        let all = widgets.flatMap { widget -> [(widgetID: String, tile: CollectionItem)] in
            guard case .collection(let items) = widget.content else { return [] }
            return items.filter(HomeViewModel.isGenreTile).map { (widget.id, $0) }
        }
        var items = await HomeViewModel.tileItems(all, from: content, fresh: false)
        items.merge(fresh) { _, new in new }
        guard current == generation, !Task.isCancelled else { return }
        tilePhotos.merge(HomeViewModel.photos(widgets, items: items)) { _, new in new }
    }

    /// The photos of every collection's genre tiles, by `tilePhotoKey`, from `items` by the same key.
    nonisolated private static func photos(_ widgets: [HomeWidget], items: [String: [MetaPreview]]) -> [String: URL] {
        var photos: [String: URL] = [:]
        for widget in widgets {
            guard case .collection(let tiles) = widget.content else { continue }
            let genreTiles = tiles.filter(isGenreTile)
            var byTile: [String: [MetaPreview]] = [:]
            for tile in genreTiles { byTile[tile.id] = items[tilePhotoKey(widgetID: widget.id, tile: tile)] }
            let picked = tilePhotos(for: genreTiles, items: byTile)
            for tile in genreTiles { photos[tilePhotoKey(widgetID: widget.id, tile: tile)] = picked[tile.id] }
        }
        return photos
    }

    /// The titles behind each tile, by `tilePhotoKey`, loaded concurrently: the last-known first page of a one-source tile, or a fresh load
    /// asked as the tile's grid asks it. A tile whose source cannot load or fails has none.
    nonisolated private static func tileItems(_ tiles: [(widgetID: String, tile: CollectionItem)], from content: WidgetContentService,
                                              fresh: Bool) async -> [String: [MetaPreview]] {
        await withTaskGroup(of: (String, [MetaPreview]).self, returning: [String: [MetaPreview]].self) { group in
            for (widgetID, tile) in tiles {
                group.addTask {
                    let key = tilePhotoKey(widgetID: widgetID, tile: tile)
                    if tile.sources.count > 1 {
                        guard fresh else { return (key, []) }
                        return (key, (try? await content.items(for: tile.sources, limit: CatalogListViewModel.mergedLimit)) ?? [])
                    }
                    let source = tile.sources[0]
                    guard await content.issue(with: source) == nil else { return (key, []) }
                    if !fresh { return (key, await content.lastKnownItems(for: source, limit: CatalogListViewModel.pageSize) ?? []) }
                    return (key, (try? await content.items(for: source, limit: CatalogListViewModel.pageSize, skip: 0)) ?? [])
                }
            }
            var items: [String: [MetaPreview]] = [:]
            for await (key, list) in group where !list.isEmpty { items[key] = list }
            return items
        }
    }

    /// A row widget with Better Posters turned on or off.
    private static func withBetterPosters(_ widget: HomeWidget, _ on: Bool) -> HomeWidget {
        guard case .row(var row) = widget.content else { return widget }
        row.presentation.usesBetterPosters = on
        var changed = widget
        changed.content = .row(row)
        return changed
    }

    /// The widgets in the order the shuffle settings give for this opening of Home, each random source picked, with each shuffled
    /// widget's seed in `itemSeeds`. The seeds are saved, so an order or a pick lasts until its next time, across launches.
    private func shuffled(_ widgets: [HomeWidget], addons: [InstalledAddon]) async -> [HomeWidget] {
        let settings = await services.widgetShuffle.settings()
        let saved = await services.widgetShuffle.states()
        var states = saved
        var random = SystemRandomNumberGenerator()
        let now = Date()
        let picked = WidgetShuffling.pickingSources(widgets, addons: addons, states: &states, now: now, calendar: .current, random: &random)
        let ordered = WidgetShuffling.ordered(picked, settings: settings, states: &states, now: now, calendar: .current, random: &random)
        itemSeeds = WidgetShuffling.itemSeeds(for: ordered, settings: settings, states: &states, now: now, calendar: .current,
                                              random: &random)
        if states != saved { await services.widgetShuffle.save(states) }
        return ordered
    }

    /// What a hero or row shows before its fresh load: the items already on screen for the same widget, else its last-known items,
    /// both while refreshing; otherwise nothing yet, so it is loading. Other widgets have no items to load.
    private static func startingSection(for widget: HomeWidget, previous: [Section], known: [String: [MetaPreview]]) -> Section {
        guard loadingConfiguration(widget.content) != nil else { return Section(widget: widget, state: .loaded([]), issue: nil) }
        if let kept = previous.first(where: { $0.id == widget.id && $0.widget.content == widget.content })?.state.value, !kept.isEmpty {
            return Section(widget: widget, state: .loaded(kept), issue: nil, isRefreshing: true)
        }
        if let items = known[widget.id] {
            return Section(widget: widget, state: .loaded(items), issue: nil, isRefreshing: true)
        }
        return Section(widget: widget, state: .loading, issue: nil)
    }
}

/// What one row's load produced.
private struct RowResult: Sendable {
    let id: String
    let state: Loadable<[MetaPreview]>
    let issue: WidgetSourceError?
}

/// The configuration of a `.hero`, `.banner` or `.row`, the widgets that load items; nil for the others.
private func loadingConfiguration(_ content: HomeWidget.Content) -> RowConfiguration? {
    switch content {
    case .hero(let row), .banner(let row), .row(let row): return row
    case .collection, .continueWatching, .unsupported: return nil
    }
}
