import Foundation
import Observation
import PlayerKit
import StremioKit

/// Library: saved titles and what has been watched. The filter narrows both sections at once.
@MainActor
@Observable
public final class LibraryViewModel {
    /// The sections as the view shows them: each already filtered and sorted. Watched has one card per movie and one per show.
    public private(set) var saved: [LibraryItem] = []
    public private(set) var watched: [WatchedCard] = []
    public private(set) var hasLoaded = false

    /// The filters and sort in use. Changing it re-filters the sections at once.
    public var filter = LibraryFilter() {
        didSet { applyFilter() }
    }

    private let services: AppServices
    /// Everything the Library knows, before any filter. The sections above are the visible part of these.
    private var savedEntries: [LibraryEntry] = []
    private var watchedEntries: [LibraryEntry] = []
    private var visibleSaved: [LibraryEntry] = []
    private var visibleWatched: [LibraryEntry] = []
    private var lastTraktPull = Date.distantPast
    /// Where the scores from the rating sites other than IMDb come from. Nil until the view attaches it.
    @ObservationIgnored private var ratings: PosterRatingsStore?
    @ObservationIgnored private var filterTask: Task<Void, Never>?

    public init(services: AppServices) {
        self.services = services
    }

    /// Lets the rating filter look up Letterboxd, Rotten Tomatoes and Metacritic scores. Titles re-filter as each score arrives.
    public func attachRatings(_ store: PosterRatingsStore?) {
        ratings = store
        applyFilter()
    }

    /// True when the Library holds nothing at all, whatever the filter. A filter that matches nothing is not empty.
    public var isEmpty: Bool { savedEntries.isEmpty && watchedEntries.isEmpty }

    /// True when at least one section has a title to show under the current filter.
    public var hasMatches: Bool { !(saved.isEmpty && watched.isEmpty) }

    /// The genres and year span of everything in the Library, for the filter's pickers.
    public var availableGenres: [String] { LibraryFiltering.genres(in: savedEntries + watchedEntries) }
    public var availableYears: ClosedRange<Int>? { LibraryFiltering.yearRange(in: savedEntries + watchedEntries) }

    /// An empty library can recover from a missed Trakt import without signing in again.
    public func refresh(now: Date = Date()) async {
        await load()
        guard isEmpty, await services.traktAccount.isSignedIn(), now.timeIntervalSince(lastTraktPull) >= 300 else { return }
        lastTraktPull = now
        _ = try? await services.traktSync.sync(force: true)
        await load()
    }

    public func load() async {
        let all = await services.progress.all()
        let savedItems = await services.library.all()
        let savedByID = Dictionary(savedItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recordsByTitle = Dictionary(grouping: all, by: Self.titleKey(of:))

        savedEntries = savedItems.map { LibraryEntry(item: $0, records: recordsByTitle[$0.id] ?? []) }
        watchedEntries = all.filter(\.isWatched).map { record in
            LibraryEntry(record: record, saved: savedByID[Self.titleKey(of: record)])
        }
        hasLoaded = true
        applyFilter()
    }

    /// In-progress items worth resuming, newest first, one per series (the latest episode).
    public static func continueWatching(from all: [WatchProgress]) -> [WatchProgress] {
        var seenSeries = Set<String>()
        return all.filter { item in
            guard let series = item.seriesID else { return true }
            return seenSeries.insert(series).inserted
        }
            .filter { !$0.isWatched && (itemIsQueued($0) || ProgressRecorder.resumePosition(for: $0) > 0) }
    }

    private static func itemIsQueued(_ item: WatchProgress) -> Bool { item.isQueuedForContinue == true }

    public func markWatched(_ item: WatchProgress) async {
        var updated = item
        updated.isWatched = true
        updated.updatedAt = Date()
        await services.progress.save(updated)
        await load()
    }

    /// Clears the watched mark from every watched record of the card's title as it is now, so an episode watched since the
    /// card was drawn is cleared too. In-progress records of the title are left alone.
    public func markUnwatched(_ card: WatchedCard) async {
        let current = await services.progress.all().filter { $0.isWatched && WatchedCards.titleKey(of: $0) == card.id }
        await services.progress.remove(current.map(\.id))
        await load()
    }

    public func removeSaved(_ item: LibraryItem) async {
        await services.library.remove(item.id)
        await load()
    }

    /// Clears every filter, keeping the sort.
    public func clearFilters() {
        filter.clearFilters()
    }

    /// Clears the filter one chip stands for.
    public func removeFilter(_ chip: FilterChip) {
        filter.remove(chip.target)
    }

    /// What tapping an in-progress item plays; the player resumes from the saved position.
    nonisolated public static func request(for progress: WatchProgress) -> StreamRequest {
        StreamRequest(type: progress.type, id: progress.contentID, title: progress.title, poster: progress.poster,
                      season: progress.season, episode: progress.episode)
    }

    /// The saved title a progress record belongs to: its type and series id (the episode's series for a series).
    private static func titleKey(of record: WatchProgress) -> String {
        WatchedCards.titleKey(of: record)
    }

    private func applyFilter() {
        let now = Date()
        let filter = filter
        let (savedEntries, watchedEntries) = (self.savedEntries, self.watchedEntries)
        let score = scoreLookup(for: filter)
        // Reading each title's score inside the tracking block means a score that arrives later re-runs the filter on its own.
        let (visibleSaved, visibleWatched) = withObservationTracking {
            (LibraryFiltering.apply(filter, to: savedEntries, now: now, score: score),
             LibraryFiltering.apply(filter, to: watchedEntries, now: now, score: score))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.filterTask?.cancel()
                self.filterTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    self?.applyFilter()
                }
            }
        }
        self.visibleSaved = visibleSaved
        self.visibleWatched = visibleWatched
        saved = visibleSaved.compactMap(\.item)
        watched = WatchedCards.cards(from: visibleWatched)
    }

    /// Every site's score for a title comes from the rating store, which starts a lookup for it if it has none yet. Without a
    /// threshold no score is needed, so nothing is looked up.
    private func scoreLookup(for filter: LibraryFilter) -> LibraryFiltering.ScoreLookup {
        guard filter.minimumRating != nil, let store = ratings else { return LibraryFiltering.catalogueScores }
        return { entry, source in
            if source == .imdb, let rating = entry.preview.imdbRating { return rating }
            return store.ratings(for: entry.preview, source: source).score(for: source)
        }
    }
}
