import Foundation
import Observation
import StremioKit

/// Observable per title, so a score arriving late redraws only its own poster or review row.
@MainActor
@Observable
public final class TitleRatings: Identifiable {
    public nonisolated let id: String
    /// IMDb's score out of 10: from IMDb's own dataset on the device when it has the title, else the one the catalog carries.
    public internal(set) var imdb: Double?
    /// The votes behind `imdb`, known only when the score comes from the dataset.
    public internal(set) var imdbVotes: Int?
    /// Letterboxd's average out of 5, for films only.
    public internal(set) var letterboxd: Double?
    public internal(set) var rottenTomatoes: Double?
    public internal(set) var metacritic: Double?
    public internal(set) var tmdb: Double?
    public internal(set) var tmdbURL: URL?
    @ObservationIgnored var catalogIMDb: Double?
    @ObservationIgnored var datasetIMDb: Double?

    nonisolated init(id: String, imdb: Double? = nil, letterboxd: Double? = nil) {
        self.id = id
        self._imdb = imdb
        self._letterboxd = letterboxd
        self.catalogIMDb = imdb
    }

    /// The site's own score, on its own scale; nil until that site has answered for this title.
    public func score(for source: RatingSource) -> Double? {
        switch source {
        case .letterboxd: letterboxd
        case .imdb: imdb
        case .rottenTomatoes: rottenTomatoes
        case .metacritic: metacritic
        }
    }

    /// Whole numbers out of 100, never a decimal: IMDb and TMDb are out of 10 and Letterboxd out of 5, so each is scaled to 100 first
    /// ("8.6" is 86, "4.2" is 84). Rotten Tomatoes and Metacritic already are.
    public var imdbText: String? { imdb.map { String(Int(($0 * 10).rounded())) } }
    public var letterboxdText: String? { letterboxd.map { String(Int(($0 * 20).rounded())) } }
    /// Prefer IMDb and Letterboxd, then fill either missing score from the other available sites.
    public var posterSites: [ReviewSite] {
        Array(ReviewSite.allCases.filter { shortText(for: $0) != nil }.prefix(2))
    }
    public var isEmpty: Bool { posterSites.isEmpty }

    /// The score alone, for a small button that already shows the site's icon: "8.7", "91%", "82".
    public func shortText(for site: ReviewSite) -> String? {
        switch site {
        case .imdb: imdbText
        case .letterboxd: letterboxdText
        case .rottenTomatoes: rottenTomatoes.map { String(format: "%.0f", $0) }
        case .metacritic: metacritic.map { String(format: "%.0f", $0) }
        case .tmdb: tmdb.map { String(Int(($0 * 10).rounded())) }
        }
    }

    /// The site's score out of 100, unrounded: IMDb and TMDb are out of 10 and Letterboxd out of 5, as `shortText` scales them.
    public func scoreOutOf100(for site: ReviewSite) -> Double? {
        switch site {
        case .imdb: imdb.map { $0 * 10 }
        case .letterboxd: letterboxd.map { $0 * 20 }
        case .rottenTomatoes: rottenTomatoes
        case .metacritic: metacritic
        case .tmdb: tmdb.map { $0 * 10 }
        }
    }

    /// The average of the scores the title page's ratings row shows (each site's own score, TMDb's included, never the ratings on single
    /// reviews), each out of 100 first, as a whole number out of 100. Nil until at least two sites have a score.
    public var averageScore: Int? {
        Self.average(of: ReviewSite.allCases.map { scoreOutOf100(for: $0) })
    }

    /// The rounded mean of the known scores, all out of 100; nil for fewer than two.
    nonisolated static func average(of scores: [Double?]) -> Int? {
        let known = scores.compactMap { $0 }
        guard known.count >= 2 else { return nil }
        return Int((known.reduce(0, +) / Double(known.count)).rounded())
    }

    public func text(for site: ReviewSite) -> String? {
        switch site {
        case .imdb: imdbText.map { "\($0)/100" }
        case .letterboxd: letterboxdText.map { "\($0)/100" }
        case .rottenTomatoes: rottenTomatoes.map { String(format: "%.0f%%", $0) }
        case .metacritic: metacritic.map { String(format: "%.0f/100", $0) }
        case .tmdb: tmdb.map { "\(Int(($0 * 10).rounded()))/100" }
        }
    }
}

/// Lazy, bounded lookups. Cached scores stay visible while expired answers are refreshed.
@MainActor
@Observable
public final class PosterRatingsStore {
    /// Makes visible posters, review rows and episodes ask again after saving credentials or refreshing.
    public private(set) var reviewServicesRevision = 0
    public private(set) var omdbError: String?
    public private(set) var reviewServiceIssue: String?
    public var isEnabled: Bool {
        didSet { if isEnabled { Task { startLookups() } } }
    }
    /// Read by the rating logos: their brand colours when on, the text colour when off. Mirrors the saved setting.
    public var showsColouredLogos = false

    @ObservationIgnored private var entries: [String: TitleRatings] = [:]
    @ObservationIgnored private var queue: [Lookup] = []
    @ObservationIgnored private var queued: Set<String> = []
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var cacheTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var cachePriorities: Set<String> = []
    @ObservationIgnored private var nextLookupAt: [String: Date] = [:]
    /// An explicit refresh bypasses disk freshness once per lookup; nextLookupAt then prevents repeated requests.
    @ObservationIgnored private var ignoresCachedFreshness = false
    @ObservationIgnored private var episodeTasks: [String: Task<[Int: Double], Never>] = [:]
    @ObservationIgnored private var episodeRetryAfter: [String: Date] = [:]
    @ObservationIgnored private var episodeDatasetScores: [String: EpisodeDatasetLookup] = [:]
    @ObservationIgnored private var episodeIndexIDs: [String: EpisodeIndexLookup] = [:]
    /// Hero artwork answers by title, kept for the session and dropped with the other review data by `forgetAll`.
    @ObservationIgnored private var heroArtworkByID: [String: TMDbArtwork] = [:]
    /// Hero artwork lookups under way, by title, so a title asked for twice at once (a prewarm and the page, say) shares one request.
    @ObservationIgnored private var heroArtworkTasks: [String: Task<TMDbArtwork?, Never>] = [:]
    /// The US age rating of each title asked for this session, for the spotlight's metadata line. Empty when TMDb has none for the title.
    @ObservationIgnored private var certificationByID: [String: String] = [:]
    @ObservationIgnored private var certificationTasks: [String: Task<String?, Error>] = [:]
    /// The most prewarm lookups that run at once. A fast scroll past many cards asks TMDb for a few titles at a time, not all of them.
    private static let maxPrewarmLookups = 4
    /// Prewarm lookups running, and the ones waiting for a turn with the callers that can drop them when their cards scroll away.
    @ObservationIgnored private var prewarmRunning = 0
    @ObservationIgnored private var prewarmWaiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    /// Set when OMDb refused the key or the daily quota ran out: nothing asks it again until then, so a bad key does not
    /// spend one failing request per poster.
    @ObservationIgnored private var omdbPausedUntil: Date?
    @ObservationIgnored private var isClearing = false
    @ObservationIgnored private let letterboxd: LetterboxdRatings?
    @ObservationIgnored private var omdb: OMDbRatings?
    @ObservationIgnored private var tmdb: TMDbRatings?
    @ObservationIgnored private let cache: any RatingsCache
    /// IMDb's ratings dataset kept on the device. Read for every IMDb title shown, with no network.
    @ObservationIgnored private let dataset: (any IMDbDataset)?
    /// Counts dataset installs. A title looked up under an older count is looked up again the next time it is asked for.
    @ObservationIgnored private var datasetGeneration = 0
    @ObservationIgnored private var datasetChecked: [String: Int] = [:]
    @ObservationIgnored private let maxConcurrentLookups: Int
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let logger: AddonLogger

    public nonisolated init(isEnabled: Bool = true, letterboxd: LetterboxdRatings? = nil, cache: (any RatingsCache)? = nil,
                            maxConcurrentLookups: Int = 3, now: @escaping @Sendable () -> Date = { Date() },
                            omdb: OMDbRatings? = nil, tmdb: TMDbRatings? = nil, dataset: (any IMDbDataset)? = nil,
                            logger: AddonLogger = .silent) {
        self._isEnabled = isEnabled
        self.dataset = dataset
        self.letterboxd = letterboxd
        self.omdb = omdb
        self.tmdb = tmdb
        self.cache = cache ?? InMemoryRatingsCache()
        self.maxConcurrentLookups = max(1, maxConcurrentLookups)
        self.now = now
        self.logger = logger
    }

    /// Settings changed on another device: visible posters and review rows ask again with the current settings.
    public func settingsDidChangeElsewhere() {
        reviewServicesRevision += 1
    }

    /// Returns the same object every time. No observed property changes synchronously when called from a view body.
    public func ratings(for item: MetaPreview, includeReviews: Bool = false, source: RatingSource? = nil) -> TitleRatings {
        let entry: TitleRatings
        if let known = entries[item.identity] {
            entry = known
            if let rating = item.imdbRating {
                known.catalogIMDb = rating
                let shown = known.datasetIMDb ?? rating
                if known.imdb != shown { Task { known.imdb = known.datasetIMDb ?? known.catalogIMDb } }
            }
        } else {
            entry = TitleRatings(id: item.identity, imdb: item.imdbRating)
            entries[item.identity] = entry
        }
        guard !isClearing, isEnabled || includeReviews, LetterboxdRatings.isIMDbID(item.id) else { return entry }
        if source == nil || source == .imdb { lookUpInDataset(item, entry: entry) }
        if letterboxd != nil, item.type == "movie", source == nil || source == .letterboxd {
            enqueue(item, provider: .letterboxd, includeReviews: includeReviews)
        }
        if tmdb != nil, ["movie", "series"].contains(item.type), source == nil {
            enqueue(item, provider: .tmdb, includeReviews: includeReviews)
        }
        // OMDb gives Rotten Tomatoes and Metacritic for a film. Only the title page asks: every poster card calls this on each redraw, so it
        // must not do any work here. The allowance and any refusal are checked when the lookup runs.
        if includeReviews, omdb != nil, item.type == "movie", LetterboxdRatings.isIMDbID(item.id),
           source == nil || source == .rottenTomatoes || source == .metacritic {
            enqueue(item, provider: .omdb, includeReviews: includeReviews)
        }
        return entry
    }

    /// Reads the title's score from the dataset on the device. A title is read once per dataset install, however often views ask.
    private func lookUpInDataset(_ item: MetaPreview, entry: TitleRatings) {
        guard let dataset, datasetChecked[item.identity] != datasetGeneration else { return }
        datasetChecked[item.identity] = datasetGeneration
        let generation = datasetGeneration
        Task { [self] in
            let found = await dataset.rating(for: item.id)
            guard !isClearing, generation == datasetGeneration else {
                // Dropped on purpose (clearing, or a newer dataset arrived): ask again next time.
                if datasetChecked[item.identity] == generation { datasetChecked[item.identity] = nil }
                return
            }
            guard let found else { return }
            entry.datasetIMDb = found.rating
            if entry.imdb != found.rating { entry.imdb = found.rating }
            if entry.imdbVotes != found.votes { entry.imdbVotes = found.votes }
        }
    }

    /// Fetches a newer copy of the IMDb dataset when one is due (at most once a day; see `IMDbRatingsUpdater`). Runs off the main actor
    /// and never blocks a view. When new data arrives, visible titles read it at once.
    public func refreshIMDbDataset() async {
        guard let dataset else { return }
        let outcome = await dataset.refreshIfNeeded()
        switch outcome {
        case .updated(let titles):
            logger.log(.info, "IMDb ratings updated: \(titles) titles")
            datasetGeneration += 1
            reviewServicesRevision += 1
        case .episodeIndexUpdated:
            logger.log(.info, "IMDb offline episode mapping updated")
            datasetGeneration += 1
            reviewServicesRevision += 1
        case .failed(let reason):
            logger.log(.warning, "IMDb ratings update failed: \(reason)")
        case .skipped, .notModified:
            break
        }
    }

    /// What the device holds, for Settings. Nil when nothing has been downloaded yet.
    public func imdbDatasetStatus() async -> IMDbDatasetStatus? { await dataset?.status() }

    /// Called after the user saves or removes credentials. Old requests finish cancelling before the clients change.
    public func setReviewServices(omdb: OMDbRatings? = nil, tmdb: TMDbRatings?, refreshCache: Bool = false) async {
        await cancelLookups()
        self.omdb = omdb
        self.tmdb = tmdb
        ignoresCachedFreshness = refreshCache
        omdbPausedUntil = nil
        omdbError = nil
        reviewServiceIssue = nil
        for entry in entries.values {
            if tmdb == nil {
                entry.tmdb = nil
                entry.tmdbURL = nil
            }
        }
        isClearing = false
        reviewServicesRevision += 1
    }

    /// Recheck visible titles, including old empty answers and failed requests. Keep good scores on screen and on disk.
    public func refresh() async {
        await cancelLookups()
        ignoresCachedFreshness = true
        omdbPausedUntil = nil
        omdbError = nil
        reviewServiceIssue = nil
        isClearing = false
        reviewServicesRevision += 1
    }

    /// Cancel before clearing, so an old answer cannot restore cleared data.
    public func forgetAll() async {
        await cancelLookups()
        await cache.clear()
        heroArtworkByID.removeAll()
        heroArtworkTasks.removeAll()
        certificationByID.removeAll()
        certificationTasks.removeAll()
        for entry in entries.values {
            entry.imdb = entry.datasetIMDb ?? entry.catalogIMDb
            entry.letterboxd = nil
            entry.rottenTomatoes = nil
            entry.metacritic = nil
            entry.tmdb = nil
            entry.tmdbURL = nil
        }
        omdbPausedUntil = nil
        omdbError = nil
        reviewServiceIssue = nil
        isClearing = false
        reviewServicesRevision += 1
    }

    private func cancelLookups() async {
        isClearing = true
        queue.removeAll()
        let pending = Array(tasks.values) + Array(cacheTasks.values)
        let pendingEpisodes = Array(episodeTasks.values)
        for task in pending { task.cancel() }
        for task in pendingEpisodes { task.cancel() }
        for task in pending { await task.value }
        for task in pendingEpisodes { _ = await task.value }
        queued.removeAll()
        cacheTasks.removeAll()
        cachePriorities.removeAll()
        episodeTasks.removeAll()
        episodeRetryAfter.removeAll()
        episodeDatasetScores.removeAll()
        episodeIndexIDs.removeAll()
        nextLookupAt.removeAll()
    }

    private func enqueue(_ item: MetaPreview, provider: Provider, includeReviews: Bool) {
        let lookup = Lookup(item: item, provider: provider, includeReviews: includeReviews)
        if includeReviews, cacheTasks[lookup.id] != nil { cachePriorities.insert(lookup.id) }
        if includeReviews, let index = queue.firstIndex(where: { $0.id == lookup.id }) {
            var priority = queue.remove(at: index)
            priority.includeReviews = true
            queue.insert(priority, at: 0)
            Task { startLookups() }
            return
        }
        guard nextLookupAt[lookup.id].map({ now() >= $0 }) ?? true, queued.insert(lookup.id).inserted else { return }
        // Cache reads never wait for a network worker slot.
        cacheTasks[lookup.id] = Task { [self] in
            defer { cacheTasks[lookup.id] = nil; cachePriorities.remove(lookup.id) }
            let cached = await cache.value(for: lookup.cacheKey)
            guard !Task.isCancelled else { return }
            if let cached {
                apply(cached, lookup: lookup)
                let expires = cached.fetchedAt.addingTimeInterval(cacheLifetime(cached, provider: lookup.provider))
                if !ignoresCachedFreshness, now() < expires {
                    nextLookupAt[lookup.id] = expires
                    queued.remove(lookup.id)
                    return
                }
            }
            var ready = lookup
            ready.includeReviews = includeReviews || cachePriorities.contains(lookup.id)
            if ready.includeReviews { queue.insert(ready, at: 0) } else { queue.append(ready) }
            startLookups()
        }
    }

    private func startLookups() {
        guard !isClearing else { return }
        while tasks.count < maxConcurrentLookups, let index = queue.firstIndex(where: { isEnabled || $0.includeReviews }) {
            let lookup = queue.remove(at: index)
            tasks[lookup.id] = Task { [self] in
                defer { tasks[lookup.id] = nil; queued.remove(lookup.id); startLookups() }
                do {
                    let answer: CachedRating
                    switch lookup.provider {
                    case .letterboxd:
                        guard let letterboxd else { return }
                        answer = CachedRating(rating: try await letterboxd.rating(imdbID: lookup.item.id), fetchedAt: now())
                    case .tmdb:
                        guard let tmdb else { return }
                        answer = CachedRating(rating: nil, fetchedAt: now(),
                                              reviews: try await tmdb.ratings(imdbID: lookup.item.id, type: lookup.item.type))
                    case .omdb:
                        // The allowance and any refusal are checked here, off the view's redraw path.
                        guard let omdb, !isOMDbPaused, omdb.usage.today() < OMDbUsage.dailyLimit else { return }
                        answer = CachedRating(rating: nil, fetchedAt: now(), reviews: try await omdb.ratings(imdbID: lookup.item.id))
                    }
                    guard !Task.isCancelled else { return }
                    await cache.store(answer, for: lookup.cacheKey)
                    guard !Task.isCancelled else { return }
                    nextLookupAt[lookup.id] = answer.fetchedAt.addingTimeInterval(cacheLifetime(answer, provider: lookup.provider))
                    apply(answer, lookup: lookup)
                    if lookup.provider == .tmdb { reviewServiceIssue = nil }
                } catch {
                    guard !Task.isCancelled else { return }
                    nextLookupAt[lookup.id] = now().addingTimeInterval(60)
                    let mapped = AddonError.from(error)
                    logger.log(.warning, "\(lookup.provider.rawValue) lookup failed for \(lookup.item.identity): \(mapped.shortDescription)")
                    if lookup.provider == .tmdb { reviewServiceIssue = Self.issueText(for: mapped) }
                    if lookup.provider == .omdb { pauseOMDbIfRefused(error) }
                }
            }
        }
    }

    /// The hero artwork already fetched for this title this session, read without waiting. Nil until a lookup for it has succeeded.
    public func cachedHeroArtwork(for item: MetaPreview) -> TMDbArtwork? {
        heroArtworkByID[item.id]
    }

    /// Original-resolution portrait and landscape artwork for the featured carousel, independent of poster rating visibility.
    /// Successful answers are kept for the session, so a title coming back into the spotlight is ready at once. A title asked for again
    /// while its lookup runs waits for that lookup rather than making another request.
    public func heroArtwork(for item: MetaPreview) async -> TMDbArtwork? {
        if let known = heroArtworkByID[item.id] { return known }
        guard let tmdb, !isClearing else { return nil }
        if let running = heroArtworkTasks[item.id] { return await running.value }
        let task = Task<TMDbArtwork?, Never> { try? await tmdb.artwork(imdbID: item.id, type: item.type) }
        heroArtworkTasks[item.id] = task
        let artwork = await task.value
        // Forgotten while it ran (the data was cleared): the answer is handed back but not kept.
        guard heroArtworkTasks[item.id] == task else { return artwork }
        heroArtworkTasks[item.id] = nil
        if let artwork { heroArtworkByID[item.id] = artwork }
        return artwork
    }

    /// The age rating already fetched for this title this session, read without waiting. Nil until a lookup for it has answered, and
    /// when TMDb has none.
    public func cachedCertification(for item: MetaPreview) -> String? {
        certificationByID[item.id].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The title's US age rating, for the spotlight's metadata line. Answers are kept for the session, "none" included, so a title coming
    /// back into the spotlight asks nothing. A lookup that failed is not kept, and a title asked for again while its lookup runs waits
    /// for that lookup.
    public func certification(for item: MetaPreview) async -> String? {
        if certificationByID[item.id] != nil { return cachedCertification(for: item) }
        guard let tmdb, !isClearing else { return nil }
        if let running = certificationTasks[item.id] { return try? await running.value }
        let task = Task<String?, Error> { try await tmdb.certification(imdbID: item.id, type: item.type) }
        certificationTasks[item.id] = task
        let answer: String?
        do {
            answer = try await task.value
        } catch {
            if certificationTasks[item.id] == task { certificationTasks[item.id] = nil }
            return nil
        }
        // Forgotten while it ran (the data was cleared): the answer is handed back but not kept.
        guard certificationTasks[item.id] == task else { return answer }
        certificationTasks[item.id] = nil
        certificationByID[item.id] = answer ?? ""
        return answer
    }

    /// Whether hero artwork can be asked for at all: a TMDb client is configured. Without one, prewarming is skipped entirely.
    public var canLookUpHeroArtwork: Bool { tmdb != nil && !isClearing }

    /// Looks up a title's hero artwork before its page opens, for a card that has been on screen for a moment. Only the TMDb answer is asked
    /// for, never a picture. At most `maxPrewarmLookups` run at once, so a fast scroll does not burst TMDb, and a lookup still waiting for its
    /// turn is dropped when its card scrolls away. Does nothing without a TMDb client, or when the title's artwork is already known.
    public func prewarmHeroArtwork(for item: MetaPreview) async {
        guard tmdb != nil, !isClearing, heroArtworkByID[item.id] == nil else { return }
        let waiter = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if prewarmRunning < Self.maxPrewarmLookups {
                    prewarmRunning += 1
                    continuation.resume(returning: true)
                } else {
                    prewarmWaiting.append((waiter, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelPrewarmWait(waiter) }
        }
        guard granted else { return }
        defer { releasePrewarmSlot() }
        guard !Task.isCancelled else { return }
        _ = await heroArtwork(for: item)
    }

    /// Passes the slot to the next prewarm waiting for one, or frees it when none is waiting.
    private func releasePrewarmSlot() {
        if prewarmWaiting.isEmpty { prewarmRunning -= 1 } else { prewarmWaiting.removeFirst().continuation.resume(returning: true) }
    }

    /// Drops a prewarm that is still waiting for its turn. It is resumed without a slot.
    private func cancelPrewarmWait(_ waiter: UUID) {
        guard let index = prewarmWaiting.firstIndex(where: { $0.id == waiter }) else { return }
        prewarmWaiting.remove(at: index).continuation.resume(returning: false)
    }

    /// TMDb scores fill episodes that have no rating from their addon.
    public func episodeRatings(seriesIMDbID: String, season: Int) async -> [Int: Double] {
        guard let tmdb, !isClearing else { return [:] }
        do {
            let scores = try await tmdb.seasonEpisodeRatings(seriesIMDbID: seriesIMDbID, season: season)
            guard !Task.isCancelled else { return [:] }
            reviewServiceIssue = nil
            return scores
        } catch {
            guard !Task.isCancelled else { return [:] }
            let mapped = AddonError.from(error)
            logger.log(.warning, "TMDb episode lookup for season \(season) failed: \(mapped.shortDescription)")
            reviewServiceIssue = Self.issueText(for: mapped)
            return [:]
        }
    }

    static func issueText(for error: AddonError) -> String {
        switch error {
        case .http(status: 401), .http(status: 403): "TMDb refused the Read Access Token. Check it in Settings."
        case .http(status: 429): "TMDb rate limit reached. Scores will return later."
        case .offline, .network, .timeout: "TMDb could not be reached."
        default: "TMDb lookup failed: \(error.shortDescription)."
        }
    }

    /// IMDb scores from the local dataset using OMDb's episode IDs, with OMDb's scores filling gaps.
    /// One network request per season; complete seasons refresh daily, partial/empty ones hourly. Cached identities work offline.
    public func episodeRatings(for seriesID: String, season: Int, expectedEpisodes: Set<Int> = []) async -> [Int: Double] {
        guard !isClearing, LetterboxdRatings.isIMDbID(seriesID), season >= 0 else { return [:] }
        let key = "omdb:\(seriesID):s\(season)"
        if let running = episodeTasks[key] { return await running.value }
        let task = Task<[Int: Double], Never> { [self] in
            let cached = await cache.value(for: key)
            guard !Task.isCancelled else { return [:] }
            let previousIDs = cached?.episodeIDs ?? [:]
            let indexedIDs = await localEpisodeIDs(for: seriesID, season: season, key: key)
            let ids = previousIDs.merging(indexedIDs) { _, local in local }
            var carried = cached?.episodes ?? [:]
            for (number, id) in ids where previousIDs[number] != nil && previousIDs[number] != id {
                carried[number] = nil // Never inherit a stale score from a mismatched identity.
            }
            let previous = await resolveEpisodeScores(carried, ids: ids, key: key)
            guard !Task.isCancelled else { return [:] }
            // Stored only for a real change. An old score-only entry keeps its missing IDs when none were found, since that is how
            // `needsIDs` below knows to ask OMDb for them once: writing empty IDs over it marked it upgraded without any.
            if var enriched = cached, enriched.episodes != previous || (!ids.isEmpty && enriched.episodeIDs != ids) {
                enriched.episodes = previous
                if !ids.isEmpty {
                    enriched.episodeIDs = ids
                    enriched.episodeNumbers = (enriched.episodeNumbers ?? []).union(ids.keys)
                }
                await cache.store(enriched, for: key)
            }
            guard !Task.isCancelled else { return [:] }
            if let retry = episodeRetryAfter[key], now() < retry { return previous }
            let knownEpisodes = (cached?.episodeNumbers ?? []).union(ids.keys)
            let expected = expectedEpisodes.isEmpty ? knownEpisodes : expectedEpisodes
            if !indexedIDs.isEmpty && !expected.isEmpty && expected.isSubset(of: Set(previous.keys)) {
                return previous // Fully resolved offline: no OMDb season request required.
            }
            let lifetime = Self.episodeCacheLifetime(scores: previous, knownEpisodes: knownEpisodes, expectedEpisodes: expectedEpisodes)
            let expires = cached?.fetchedAt.addingTimeInterval(lifetime) ?? .distantPast
            // Upgrade old score-only caches once, instead of making this fix wait for their 24-hour expiry.
            let needsIDs = dataset != nil && ids.isEmpty && cached?.episodeIDs == nil
            if !needsIDs, let until = nextLookupAt[key], now() < min(until, expires) { return previous }
            if !needsIDs, !ignoresCachedFreshness, now() < expires {
                return previous
            }
            guard let omdb, omdbAllowsEpisodeRequests else { return previous }
            do {
                let answer = try await omdb.seasonRatings(imdbID: seriesID, season: season)
                guard !Task.isCancelled else { return [:] }
                var retained = previous
                var remoteScores = answer.scores
                for (number, remoteID) in answer.episodeIDs {
                    if let localID = indexedIDs[number], localID != remoteID {
                        // Never assign OMDb's score for a different episode to the authoritative offline IMDb ID.
                        retained[number] = nil
                        remoteScores[number] = nil
                    } else if let previousID = previousIDs[number], previousID != remoteID {
                        retained[number] = nil
                    }
                }
                let mergedIDs = answer.episodeIDs.merging(ids) { _, local in local }
                let scores = await resolveEpisodeScores(retained.merging(remoteScores) { _, new in new }, ids: mergedIDs, key: key)
                guard !Task.isCancelled else { return [:] }
                let numbers = (cached?.episodeNumbers ?? []).union(answer.episodeNumbers)
                let fetchedAt = now()
                await cache.store(CachedRating(rating: nil, fetchedAt: fetchedAt, episodes: scores,
                                               episodeIDs: mergedIDs, episodeNumbers: numbers.union(mergedIDs.keys)), for: key)
                guard !Task.isCancelled else { return [:] }
                episodeRetryAfter[key] = nil
                nextLookupAt[key] = fetchedAt.addingTimeInterval(Self.episodeCacheLifetime(scores: scores, knownEpisodes: numbers,
                                                                                          expectedEpisodes: expectedEpisodes))
                if !isOMDbPaused { omdbError = nil }
                // The request that used up the allowance: cards ask again, and TMDb fills in from now on.
                if omdb.usage.today() >= OMDbUsage.dailyLimit { reviewServicesRevision += 1 }
                return scores
            } catch {
                if !Task.isCancelled {
                    episodeRetryAfter[key] = now().addingTimeInterval(60)
                    pauseOMDbIfRefused(error)
                }
                return previous
            }
        }
        episodeTasks[key] = task
        let scores = await task.value
        if episodeTasks[key] == task { episodeTasks[key] = nil }
        return scores
    }

    /// Resolve an episode's IMDb title ID from the existing offline index or cached OMDb season.
    public func imdbEpisodeID(seriesIMDbID: String, season: Int, episode: Int) async -> String? {
        guard LetterboxdRatings.isIMDbID(seriesIMDbID), season >= 0, episode >= 0 else { return nil }
        let key = "omdb:\(seriesIMDbID):s\(season)"
        let local = await localEpisodeIDs(for: seriesIMDbID, season: season, key: key)
        if let id = local[episode], LetterboxdRatings.isIMDbID(id) { return id }
        let cached = await cache.value(for: key)
        guard let id = cached?.episodeIDs?[episode], LetterboxdRatings.isIMDbID(id) else { return nil }
        return id
    }

    private struct EpisodeIndexLookup {
        let generation: Int
        let ids: [Int: String]
    }

    private func localEpisodeIDs(for seriesID: String, season: Int, key: String) async -> [Int: String] {
        guard let dataset else { return [:] }
        if let cached = episodeIndexIDs[key], cached.generation == datasetGeneration { return cached.ids }
        let generation = datasetGeneration
        let ids = await dataset.episodeIDs(for: seriesID, season: season)
        if generation == datasetGeneration {
            episodeIndexIDs[key] = EpisodeIndexLookup(generation: generation, ids: ids)
        }
        return ids
    }

    private struct EpisodeDatasetLookup {
        let generation: Int
        let ids: [Int: String]
        let scores: [Int: Double]
    }

    /// Indexed local reads, once per season and dataset generation. No per-episode network requests.
    private func resolveEpisodeScores(_ scores: [Int: Double], ids: [Int: String], key: String) async -> [Int: Double] {
        guard let dataset, !ids.isEmpty else { return scores }
        if let found = episodeDatasetScores[key], found.generation == datasetGeneration, found.ids == ids {
            return scores.merging(found.scores) { _, local in local }
        }
        let generation = datasetGeneration
        var local: [Int: Double] = [:]
        for (number, id) in ids {
            guard !Task.isCancelled else { return scores }
            if let rating = await dataset.rating(for: id), rating.rating.isFinite, rating.rating > 0, rating.rating <= 10 {
                local[number] = rating.rating
            }
        }
        guard !Task.isCancelled else { return scores }
        if generation == datasetGeneration { episodeDatasetScores[key] = EpisodeDatasetLookup(generation: generation, ids: ids, scores: local) }
        return scores.merging(local) { _, local in local }
    }

    private static func episodeCacheLifetime(scores: [Int: Double], knownEpisodes: Set<Int>, expectedEpisodes: Set<Int>) -> TimeInterval {
        let expected = expectedEpisodes.isEmpty ? knownEpisodes : expectedEpisodes
        return scores.isEmpty || !expected.isSubset(of: Set(scores.keys)) ? 3_600 : 86_400
    }

    /// Whether OMDb can still be asked for episode scores: there is a key, OMDb has not refused it (401 or the 429 quota pause) and today's
    /// requests from this device are under the daily limit. TMDb fills gaps after IMDb has been checked.
    public var omdbAllowsEpisodeRequests: Bool {
        guard let omdb else { return false }
        return !isOMDbPaused && omdb.usage.today() < OMDbUsage.dailyLimit
    }

    private var isOMDbPaused: Bool { omdbPausedUntil.map { now() < $0 } ?? false }

    /// A rejected key or an exhausted quota will fail the same way for every other title, so stop asking for an hour.
    private func pauseOMDbIfRefused(_ error: Error) {
        switch error {
        case AddonError.http(401): omdbError = "OMDb rejected the API key. Check the key and save it again."
        case AddonError.http(429): omdbError = "OMDb's request limit was reached. Try again later."
        default: omdbError = "IMDb ratings couldn't load. Check your connection, then try Refresh Ratings."
        }
        guard case AddonError.http(let status) = error, status == 401 || status == 429 else { return }
        omdbPausedUntil = now().addingTimeInterval(3600)
        // Episode cards ask again, now that TMDb may fill their scores.
        reviewServicesRevision += 1
    }

    private func cacheLifetime(_ cached: CachedRating, provider: Provider) -> TimeInterval {
        let hasScore: Bool
        switch provider {
        case .letterboxd: hasScore = cached.rating != nil
        case .tmdb: hasScore = cached.reviews?.tmdb != nil
        case .omdb: hasScore = cached.reviews?.rottenTomatoes != nil || cached.reviews?.metacritic != nil
        }
        return hasScore ? 7 * 86_400 : 3_600
    }

    private func apply(_ cached: CachedRating, lookup: Lookup) {
        guard let entry = entries[lookup.item.identity] else { return }
        switch lookup.provider {
        case .letterboxd:
            if let rating = cached.rating { entry.letterboxd = rating }
        case .tmdb:
            if let rating = cached.reviews?.tmdb { entry.tmdb = rating }
            if let url = cached.reviews?.tmdbURL { entry.tmdbURL = url }
            // The answer names the title's TMDb id, also when it was read from the cache: its page then asks only for its artwork.
            if let tmdb, let reviews = cached.reviews {
                let item = lookup.item
                Task { await tmdb.rememberID(from: reviews, imdbID: item.id, type: item.type) }
            }
        case .omdb:
            // Only scores OMDb gave are set: a title it has none for keeps whatever the other providers said.
            if let score = cached.reviews?.rottenTomatoes { entry.rottenTomatoes = score }
            if let score = cached.reviews?.metacritic { entry.metacritic = score }
        }
    }

    private enum Provider: String { case letterboxd, tmdb, omdb }
    private struct Lookup {
        let item: MetaPreview
        let provider: Provider
        var includeReviews: Bool
        var id: String { "\(provider.rawValue):\(item.identity)" }
        var cacheKey: String {
            switch provider {
            case .letterboxd: item.id
            case .tmdb: "tmdb:\(item.identity)"
            case .omdb: "omdb:\(item.identity)"
            }
        }
    }
}
