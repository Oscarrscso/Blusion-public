import Foundation
import Observation
import PlayerKit
import StremioKit

/// Detail: starts from the catalog preview, upgrades to the addon's full `meta` when it arrives.
@MainActor
@Observable
public final class DetailViewModel {
    public let preview: MetaPreview
    public private(set) var detail: MetaDetail
    public private(set) var isLoading = true
    /// True when no addon returned `meta` and Detail is built from the catalog preview alone.
    public private(set) var isFallback = false
    public var selectedSeason: Int?
    public private(set) var isInLibrary = false
    /// Goes up each time the page reads in what it shows (the details, library membership, watched marks) rather than the user changing it
    /// here. The Save and Watched buttons tick only for a change that comes without it, so a page that opens on a saved or watched title is
    /// silent.
    public private(set) var loadRevision = 0
    /// Episode cards are as wide as the text above them, as chosen with the toggle beside the season name. The choice is saved, and read
    /// again when the details load.
    public private(set) var matchesEpisodeWidthToText = false
    /// Seasons whose TMDb episode scores are already in `detail`, or on their way.
    private var episodeRatingSeasons: Set<Int> = []
    /// How long each episode runs, in minutes, by episode id, from TMDb's season data. Filled a season at a time as its cards appear.
    public private(set) var episodeRuntimes: [String: Int] = [:]
    /// Seasons TMDb has answered for, even with no runtimes, so they are not asked again on this page. A failed lookup is asked again.
    @ObservationIgnored private var runtimeSeasons: Set<Int> = []
    /// The season lookups on their way. The page owns them: a card that scrolls away does not call its season's lookup off.
    @ObservationIgnored private var runtimeTasks: [Int: Task<Void, Never>] = [:]
    /// Identities (`type/id`) of watched movies and episodes shown on this screen.
    public private(set) var watchedIdentities: Set<String> = []
    /// Share of the runtime saved for the movie and episodes shown here, by identity (0...1). Only progress that playback can
    /// resume from is listed, so a bar or a "Resume" label always means the player starts at the saved position.
    public private(set) var progressFractions: [String: Double] = [:]
    /// Saved records for the movie and episodes shown here, by identity. `nextUp` reads their update times.
    private var savedProgress: [String: WatchProgress] = [:]
    /// Recomputed when details or progress change, rather than sorting every episode during SwiftUI redraws.
    public private(set) var nextUp: Video?
    /// A show's watched button must not reparse every episode's air date on each view update.
    public private(set) var isSeriesWatched = false

    private let services: AppServices
    /// The Play request whose stream lookup was started from this page.
    private var prefetchedStreamRequest: StreamRequest?
    public private(set) var tmdbArtwork: TMDbArtwork?
    public private(set) var isLoadingArtwork = true
    // Separate from metadata: these requests start after hero and stream priority work.
    public private(set) var isLoadingReviews = true
    public private(set) var isLoadingCredits = true
    public private(set) var isLoadingRelated = true
    public private(set) var isLoadingFacts = true
    public private(set) var reviews: [TMDbReview] = []
    /// What the TMDb reviews praise and complain about, from their complete text, by the on-device model.
    public private(set) var reviewConsensus: String?
    public private(set) var isSummarizingReviews = false
    public private(set) var reviewSummaryError: String?
    public private(set) var reviewedCount = 0
    @ObservationIgnored private var reviewSummaryRequest = UUID()
    /// The YouTube trailers and teasers TMDb lists for the title. Empty until TMDb answers, or when no read token is saved.
    public private(set) var tmdbVideos: [TMDbVideo] = []
    /// The title's preview from Apple's iTunes store: a direct file the app plays. Nil until the search answers, or when the store has none.
    public private(set) var itunesTrailer: Trailer?
    /// The lookups of the trailers beyond the addon's (TMDb's videos and the iTunes preview), shared by the page's load and a trailer tap
    /// that comes before it gets to them.
    private var trailerSourcesTask: Task<Void, Never>?
    /// Set once every place a trailer can come from has answered, so a title with none dims its trailer button only then.
    public private(set) var hasCheckedTrailerSources = false
    /// The cast and crew with TMDb ids and photos. Nil until TMDb answers, or when no read token is saved.
    public private(set) var titleCredits: TMDbTitleCredits?
    /// Titles TMDb recommends for this one, for the shelf at the bottom of the page. Empty until TMDb answers.
    public private(set) var relatedTitles: [TMDbRelatedTitle] = []
    /// What TMDb knows beyond the addon's details (studios, countries, language, budget, a series' network and run), for Information. Nil
    /// until TMDb answers, or when no read token is saved.
    public private(set) var titleFacts: TMDbTitleFacts?
    /// The US age rating ("R", "TV-MA") for the meta line. Nil until TMDb answers, or when it has none.
    public private(set) var certification: String?
    /// Set after the hero picture/logo and the first stream prefetch have been prioritised, so secondary page work may start.
    public private(set) var hasSettledHero = false
    /// The title's trailer: its loading, the player in the page's panel, and a failure. The trailer button and the panel share it.
    public let trailer: TrailerLoader
    /// Goes up when the trailer is closed by a control that gave its own haptic (the full-screen trailer's X), so the Trailer button does not
    /// tick a second time.
    public private(set) var trailerQuietCloses = 0
    /// The title's Play colour as "rrggbb" ("" for the plain button), or nil while it is not decided. Read when the page opens; a title whose
    /// colour was not decided yet (a dull poster whose logo had not loaded, or no card that showed it) takes it once, as soon as the page's
    /// own read decides it, rather than on the next opening. It never changes after that.
    public private(set) var playColourHex: String?

    public init(preview: MetaPreview, services: AppServices, artwork: TMDbArtwork? = nil, artworkChecked: Bool = false,
                trailerPreparer: (any TrailerPreparing)? = nil) {
        self.preview = preview
        self.detail = .fallback(from: preview)
        self.services = services
        // The title's Play colour from its poster, when the poster is already in the image cache, so the page is coloured from its first frame.
        #if canImport(UIKit)
        PlayColourStore.shared.readNow(identity: preview.identity, pictures: PlayColourStore.pictures(for: preview),
                                       logos: PlayColourStore.logos(for: preview))
        playColourHex = PlayColourStore.shared.hex(for: preview.identity)
        PlayColourStore.shared.logPageColour(identity: preview.identity)
        #else
        playColourHex = nil
        #endif
        self.trailer = TrailerLoader(preparer: trailerPreparer ?? UnavailableTrailerPreparer())
        // An artwork handed over by Home, or one looked up earlier this session, is used at once: the page then has nothing to wait for.
        let known = artwork ?? services.posterRatings.cachedHeroArtwork(for: preview)
        self.tmdbArtwork = known
        self.isLoadingArtwork = known == nil && !artworkChecked
        // The age rating the spotlight already showed for this title is there from the first frame, so the line does not change on opening.
        self.certification = services.posterRatings.cachedCertification(for: preview)
        #if canImport(UIKit)
        if playColourHex == nil {
            // The page's own stand-in picture, so a picture fetched for the colour is the stand-in's own download: the Mac's stands in with a
            // backdrop.
            #if targetEnvironment(macCatalyst)
            let standIn = HeroPicture.standInURL(for: preview, backdropOnly: true)
            #else
            let standIn = HeroPicture.standInURL(for: preview)
            #endif
            let identity = preview.identity
            let pictures = PlayColourStore.pictures(for: preview), logos = PlayColourStore.logos(for: preview)
            Task { [weak self] in
                let hex = await PlayColourStore.shared.readForPage(identity: identity, standIn: standIn, pictures: pictures, logos: logos)
                guard let self, let hex, self.playColourHex == nil else { return }
                self.playColourHex = hex
            }
        }
        #endif
    }

    /// Runs the hero's load, and gives up after five seconds, so a slow picture never holds the page.
    private func loadHero(_ hero: @escaping @MainActor @Sendable () async -> Void) async {
        let heroTask = Task { @MainActor in await hero() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await heroTask.value }
            group.addTask { try? await Task.sleep(for: .seconds(5)) }
            await group.next()
            group.cancelAll()
        }
    }

    public func load(afterHero hero: (@MainActor @Sendable () async -> Void)? = nil,
                     priorityStream: StreamRequest? = nil, prefetchOnOpen: Bool = false) async {
        isLoading = true
        isLoadingReviews = true
        isLoadingCredits = true
        isLoadingRelated = true
        isLoadingFacts = true
        episodeRatingSeasons.removeAll()
        trailerSourcesTask = nil
        // The picture and logo get the network first. Metadata must not compete with the hero's
        // initial load; retain the existing hero timeout so a failed image cannot stall the page.
        await loadArtwork()
        guard !Task.isCancelled else { return }
        if let hero, !hasSettledHero { await loadHero(hero) }
        guard !Task.isCancelled else { return }
        // Essential metadata supplies the right episode and watch progress for stream selection.
        async let playbackSettings = services.settings.load()
        let result = await services.browse.detail(for: preview)
        // A load that was cancelled must not overwrite what the newer load shows.
        guard !Task.isCancelled else { return }
        let settings = await playbackSettings
        matchesEpisodeWidthToText = settings.matchesEpisodeWidthToText
        detail = result.detail
        loadRevision += 1
        isFallback = result.isFallback
        if !result.isFallback { services.heroMeta.record(detail.preview, for: preview) }
        // What has been watched is read with the details, so Play and the episodes are right the moment they show: a tap on Play made
        // while the page loaded plays the episode it names.
        await refreshUserState()
        guard !Task.isCancelled else { return }
        // A series opens on the season of its next episode, so the list starts where the viewer left off.
        if selectedSeason == nil { selectedSeason = nextUp?.season ?? detail.seasons.first }
        isLoading = false
        // Prime Play's stream lookup before starting any ratings, trailers, credits, or related-title requests.
        // Continue Watching primes its requested episode instead of an unrelated series episode.
        // The lookup runs independently after registration, so it does not block the page on addon responses.
        if prefetchOnOpen {
            await prefetchStreams(for: priorityStream ?? primaryRequest)
            guard !Task.isCancelled else { return }
        }
        hasSettledHero = true
        // Only after hero and stream prefetch do the less urgent enrichment requests start.
        async let reviews: Void = loadReviews()
        async let credits: Void = loadTitleCredits()
        async let related: Void = loadRelatedTitles()
        async let rating: Void = loadCertification()
        async let trailerSources: Void = loadTrailerSources()
        async let facts: Void = loadTitleFacts()
        await reviews
        await credits
        await related
        await rating
        await trailerSources
        await facts
    }

    public func refresh() async {
        await services.posterRatings.refresh()
        await load()
    }

    /// Only what Play needs: the details and what has been watched, for a poster held to play (see `PosterPlayLauncher`). No hero, reviews,
    /// credits or trailers are asked for; the title's Play colour is read as for any page.
    public func loadForPlayback() async {
        let result = await services.browse.detail(for: preview)
        guard !Task.isCancelled else { return }
        detail = result.detail
        isFallback = result.isFallback
        isLoading = false
        await refreshUserState()
    }

    private func loadArtwork() async {
        // An artwork handed over by Home, or a lookup that has answered, is never fetched again.
        guard tmdbArtwork == nil, isLoadingArtwork else { return }
        defer { isLoadingArtwork = false }
        // The store holds the TMDb client and keeps each answer for the session, so a title opened again asks TMDb nothing.
        let artwork = await services.posterRatings.heroArtwork(for: preview)
        guard !Task.isCancelled else { return }
        tmdbArtwork = artwork
    }

    private func loadTitleFacts() async {
        defer { isLoadingFacts = false }
        let settings = await services.settings.load()
        guard let token = settings.tmdbReadToken, !token.isEmpty else { titleFacts = nil; return }
        let loaded = try? await TMDbRatings(client: services.client, readAccessToken: token).titleFacts(imdbID: preview.id, type: preview.type)
        guard !Task.isCancelled else { return }
        titleFacts = loaded ?? nil
    }

    private func loadTitleCredits() async {
        defer { isLoadingCredits = false }
        let settings = await services.settings.load()
        guard let token = settings.tmdbReadToken, !token.isEmpty else { titleCredits = nil; return }
        let loaded = try? await TMDbRatings(client: services.client, readAccessToken: token).titleCredits(imdbID: preview.id, type: preview.type)
        guard !Task.isCancelled else { return }
        titleCredits = loaded
    }

    /// The age rating comes from the same session cache the spotlight reads, so a title shown on Home is not asked for again. Without
    /// a saved TMDb read token none is asked for, as before.
    private func loadCertification() async {
        let settings = await services.settings.load()
        guard let token = settings.tmdbReadToken, !token.isEmpty else { certification = nil; return }
        let loaded = await services.posterRatings.certification(for: preview)
        guard !Task.isCancelled else { return }
        certification = loaded
    }

    private func loadRelatedTitles() async {
        defer { isLoadingRelated = false }
        let settings = await services.settings.load()
        guard let token = settings.tmdbReadToken, !token.isEmpty else { relatedTitles = []; return }
        let loaded = try? await TMDbRatings(client: services.client, readAccessToken: token).relatedTitles(imdbID: preview.id, type: preview.type)
        guard !Task.isCancelled else { return }
        relatedTitles = loaded ?? []
    }

    /// The part of the cast and crew picked from its menu: the cast until another is picked.
    public var creditGroup: TitleCreditGroup = .cast

    /// The parts of the cast and crew the menu offers: the cast, then each crew department TMDb lists anyone in.
    public var creditGroups: [TitleCreditGroup] { titleCredits?.groups ?? [] }

    /// The part the section shows: the one picked, or the first there is when nobody is in it. Nil while TMDb's credits are unknown or
    /// list nobody.
    public var shownCreditGroup: TitleCreditGroup? { titleCredits?.group(showing: creditGroup) }

    /// The people of the part shown, the cast's first twenty. Nil while TMDb's credits are unknown; empty when TMDb has none, so the
    /// screen falls back to the addon's plain names.
    public var shownCredits: [TMDbTitlePerson]? {
        guard let titleCredits else { return nil }
        guard let group = shownCreditGroup else { return [] }
        let people = titleCredits.people(in: group)
        return group == .cast ? Array(people.prefix(20)) : people
    }

    /// Sums up the TMDb reviews the page has, once per set of reviews. The page asks once its reviews are in.
    public func loadReviewConsensus(using summarizer: (any ReviewSummarizing)? = nil) async {
        let request = UUID()
        reviewSummaryRequest = request
        let sourceReviews = reviews
        let key = ReviewConsensusReader.key(for: sourceReviews)
        let summarizer = summarizer ?? ReviewConsensusReader.available()
        reviewConsensus = summarizer == nil ? nil : ReviewConsensusReader.cache[key]
        reviewSummaryError = nil
        reviewedCount = 0
        isSummarizingReviews = reviewConsensus == nil && summarizer != nil && ReviewConsensusReader.texts(sourceReviews) != nil
        defer { if reviewSummaryRequest == request { isSummarizingReviews = false } }
        let line = await ReviewConsensusReader.line(for: sourceReviews, using: summarizer) { [weak self] scanned, _ in
            Task { @MainActor [weak self] in
                guard let self, self.reviewSummaryRequest == request else { return }
                self.reviewedCount = scanned
            }
        }
        guard !Task.isCancelled, reviewSummaryRequest == request, key == ReviewConsensusReader.key(for: reviews) else { return }
        reviewConsensus = line
        if line == nil && summarizer != nil && !sourceReviews.isEmpty {
            reviewSummaryError = "Could not summarise these reviews on device. Tap to retry."
        }
    }

    private func loadReviews() async {
        defer { isLoadingReviews = false }
        let settings = await services.settings.load()
        guard let token = settings.tmdbReadToken, !token.isEmpty else { reviews = []; return }
        let loaded = try? await TMDbRatings(client: services.client, readAccessToken: token).reviews(imdbID: preview.id, type: preview.type)
        guard !Task.isCancelled else { return }
        let newReviews = loaded ?? []
        if ReviewConsensusReader.key(for: newReviews) != ReviewConsensusReader.key(for: reviews) {
            // Invalidate a visible or in-flight summary if TMDb edits its review text.
            reviewSummaryRequest = UUID()
            reviewConsensus = nil
            isSummarizingReviews = false
            reviewSummaryError = nil
            reviewedCount = 0
        }
        reviews = newReviews
    }

    /// TMDb's videos and the iTunes preview, looked up once per load of the page: a trailer tap and the page's load share the lookup.
    private func loadTrailerSources() async {
        if let trailerSourcesTask { return await trailerSourcesTask.value }
        let task = Task { [weak self] in
            guard let self else { return }
            async let videos: Void = self.loadVideos()
            async let preview: Void = self.loadPreview()
            await videos
            await preview
            guard !Task.isCancelled else { return }
            self.hasCheckedTrailerSources = true
        }
        trailerSourcesTask = task
        await task.value
    }

    /// Returns once the details are in, the caller is cancelled, or `deadline` has passed (a page left while it loaded never finishes). A
    /// tap made while the page is still loading waits here, so its button works from the moment it is shown.
    public func waitForDetails(deadline: Duration = .seconds(30)) async {
        let end = ContinuousClock.now.advanced(by: deadline)
        while isLoading, !Task.isCancelled, ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func loadVideos() async {
        let settings = await services.settings.load()
        guard let token = settings.tmdbReadToken, !token.isEmpty else { tmdbVideos = []; return }
        let loaded = try? await TMDbRatings(client: services.client, readAccessToken: token).videos(imdbID: preview.id, type: preview.type)
        guard !Task.isCancelled else { return }
        tmdbVideos = loaded ?? []
    }

    /// The iTunes preview for the title, looked up by its name and release year. Needs no TMDb token.
    private func loadPreview() async {
        let loaded = try? await ITunesTrailers(client: services.client).preview(title: detail.preview.name,
                                                                                year: Self.releaseYear(detail.preview.releaseInfo),
                                                                                type: preview.type)
        guard !Task.isCancelled else { return }
        itunesTrailer = loaded
    }

    /// The first four-digit run in a release text such as "2010" or "2008-2013", as a year.
    private static func releaseYear(_ text: String?) -> Int? {
        guard let text, let run = text.range(of: #"\d{4}"#, options: .regularExpression) else { return nil }
        return Int(text[run])
    }

    private var seriesIMDbID: String? {
        if LetterboxdRatings.isIMDbID(detail.preview.id) { return detail.preview.id }
        return detail.videos.lazy.compactMap { Video.seriesIMDbID(fromVideoID: $0.id) }.first
    }

    /// One TMDb lookup fills the season's remaining gaps after checking IMDb and the addon.
    private func loadEpisodeRatings(season: Int?) async {
        // Called only for an episode the IMDb lookup has no score for, whether or not OMDb is available.
        guard let season, isSeries, !episodeRatingSeasons.contains(season), let seriesID = seriesIMDbID,
              detail.episodes(inSeason: season).contains(where: { $0.rating == nil }) else { return }
        episodeRatingSeasons.insert(season)
        let scores = await services.posterRatings.episodeRatings(seriesIMDbID: seriesID, season: season)
        guard !Task.isCancelled else { episodeRatingSeasons.remove(season); return }
        if scores.isEmpty { episodeRatingSeasons.remove(season) }
        detail.fillEpisodeRatings(season: season, scores: scores, source: .tmdb)
    }

    /// How long `video` runs, in minutes. Nil until TMDb's season data is in, or when TMDb has none.
    public func runtimeMinutes(for video: Video) -> Int? {
        episodeRuntimes[video.id]
    }

    /// Minutes as a card writes them: "45m", "1h", "1h 2m".
    nonisolated static func runtimeText(minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// One TMDb lookup gives the runtimes of a season's episodes, shared by the season's cards. Without a TMDb read token nothing is asked.
    private func loadEpisodeRuntimes(season: Int?) async {
        guard let season, isSeries, !runtimeSeasons.contains(season), let seriesID = seriesIMDbID else { return }
        if let pending = runtimeTasks[season] { return await pending.value }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetchEpisodeRuntimes(season: season, seriesID: seriesID)
        }
        runtimeTasks[season] = task
        await task.value
        if runtimeTasks[season] == task { runtimeTasks[season] = nil }
    }

    private func fetchEpisodeRuntimes(season: Int, seriesID: String) async {
        let settings = await services.settings.load()
        guard let token = settings.tmdbReadToken, !token.isEmpty else { return }
        guard let minutes = try? await TMDbRatings(client: services.client, readAccessToken: token)
            .seasonEpisodeRuntimes(seriesIMDbID: seriesID, season: season) else { return }
        guard !Task.isCancelled else { return }
        runtimeSeasons.insert(season)
        var updatedRuntimes = episodeRuntimes
        for video in detail.episodes(inSeason: season) {
            if let episode = video.episode, let runtime = minutes[episode] { updatedRuntimes[video.id] = runtime }
        }
        // One observed assignment per season, rather than one invalidation per episode card.
        if updatedRuntimes != episodeRuntimes { episodeRuntimes = updatedRuntimes }
    }

    /// Switches the episode cards between their fixed width and the width of the text above them. The cards change at once; the
    /// choice is then saved, so every title page opens the same way.
    public func setMatchesEpisodeWidthToText(_ value: Bool) async {
        matchesEpisodeWidthToText = value
        var settings = await services.settings.load()
        settings.matchesEpisodeWidthToText = value
        await services.settings.save(settings)
    }

    /// Library membership, watched marks and saved progress, from the local stores. `afterUserChange` is for a change the user just made
    /// on this page, which the Save and Watched buttons tick for; any other read moves `loadRevision` along with the state, so they stay silent.
    public func refreshUserState(afterUserChange: Bool = false) async {
        let identities = [movieIdentity] + detail.videos.map { episodeIdentity($0) }
        async let membership = services.library.contains(libraryIdentity)
        async let progress = services.progress.progress(for: identities)
        let records = await progress
        let isSaved = await membership
        guard !Task.isCancelled else { return }
        // A quiet revision must precede state changes, so loading watched/save state cannot tick a button.
        if !afterUserChange { loadRevision += 1 }
        isInLibrary = isSaved
        var watched = Set<String>()
        var saved: [String: WatchProgress] = [:]
        var fractions: [String: Double] = [:]
        for record in records {
            let identity = record.id
            saved[identity] = record
            if record.isWatched {
                watched.insert(identity)
            } else if ProgressRecorder.resumePosition(for: record) > 0 {
                fractions[identity] = record.fraction
            }
        }
        watchedIdentities = watched
        savedProgress = saved
        progressFractions = fractions
        nextUp = findNextUp()
        let airedEpisodes = detail.episodesCountingAsWatched()
        isSeriesWatched = !airedEpisodes.isEmpty && airedEpisodes.allSatisfy { watched.contains(episodeIdentity($0)) }
    }

    private var libraryIdentity: String {
        LibraryItem.identity(type: detail.type.isEmpty ? (preview.type.isEmpty ? "movie" : preview.type) : detail.type, contentID: detail.id)
    }

    public func toggleLibrary() async {
        if isInLibrary {
            await services.library.remove(libraryIdentity)
        } else {
            await services.library.add(LibraryItem(preview: detail.preview, addedAt: Date()))
        }
        isInLibrary = await services.library.contains(libraryIdentity)
    }

    public func isWatched(_ request: StreamRequest) -> Bool { watchedIdentities.contains(request.identity) }

    public func isWatched(_ video: Video) -> Bool { watchedIdentities.contains(episodeIdentity(video)) }

    /// Marks a movie or episode watched, or clears the mark (and any saved position).
    public func setWatched(_ watched: Bool, for request: StreamRequest) async {
        if watched {
            await services.progress.save(WatchProgress(id: request.identity, type: request.type, contentID: request.id, title: request.title,
                                                       poster: request.poster, position: 0, duration: 0, isWatched: true, updatedAt: Date(),
                                                       season: request.season, episode: request.episode))
        } else {
            await services.progress.remove(request.identity)
        }
        await refreshUserState(afterUserChange: true)
    }

    // MARK: watched marks for a whole show

    /// Marks every aired episode of the show, specials aside, watched, or clears every one of those marks. Specials keep their own
    /// marks (the season menu and an episode's menu reach them): a show counts as watched without them.
    public func setSeriesWatched(_ watched: Bool) async {
        await setWatched(watched, episodes: detail.episodesCountingAsWatched())
    }

    /// The same for one season, specials included when that season is the specials.
    public func setSeasonWatched(_ watched: Bool, season: Int) async {
        await setWatched(watched, episodes: markableEpisodes(in: [season]))
    }

    /// Mark every aired episode through the selected one, inclusive, in season/episode order.
    /// Specials have their own order and never mark the regular seasons (or vice versa).
    public func markEpisodesWatched(through selected: Video) async {
        guard let season = selected.season else { return }
        let seasons = season == 0 ? [0] : detail.seasons.filter { $0 > 0 && $0 <= season }
        let ordered = seasons.flatMap { detail.episodes(inSeason: $0) }
        guard let index = ordered.firstIndex(where: { $0.id == selected.id }) else { return }
        let remaining = ordered.prefix(through: index).filter { $0.hasAired() && !isWatched($0) }
        guard !remaining.isEmpty else { return }
        await setWatched(true, episodes: Array(remaining))
    }

    /// True when the season has aired episodes and every one of them is marked.
    public func isSeasonWatched(_ season: Int) -> Bool {
        let episodes = markableEpisodes(in: [season])
        return !episodes.isEmpty && episodes.allSatisfy { watchedIdentities.contains(episodeIdentity($0)) }
    }

    private func markableEpisodes(in seasons: [Int], now: Date = Date()) -> [Video] {
        seasons.flatMap { detail.episodes(inSeason: $0) }.filter { $0.hasAired(by: now) }
    }

    private func setWatched(_ watched: Bool, episodes: [Video]) async {
        if watched {
            let type = detail.type.isEmpty ? "series" : detail.type
            let records = episodes.map { video in
                WatchProgress(id: episodeIdentity(video), type: type, contentID: video.id, title: "\(detail.name) · \(video.title)",
                              poster: detail.preview.poster, position: 0, duration: 0, isWatched: true, updatedAt: Date(),
                              season: video.season, episode: video.episode)
            }
            await services.progress.save(records)
        } else {
            await services.progress.remove(episodes.map { episodeIdentity($0) })
        }
        await refreshUserState(afterUserChange: true)
    }

    // MARK: episode scores

    /// An episode's score and where it came from: IMDb's local dataset/OMDb first, then the addon or TMDb.
    public struct EpisodeScore: Equatable, Sendable {
        public let value: Double
        public let isIMDb: Bool
        /// A whole number out of 100, never a decimal: the score is out of 10, so "8.9" is 89.
        public var text: String { String(Int((value * 10).rounded())) }
    }

    /// Resolved IMDb scores by season, then episode number. An empty entry means IMDb has been checked for that season.
    public private(set) var omdbEpisodeScores: [Int: [Int: Double]] = [:]
    @ObservationIgnored private var scoreTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var scoresRevision = 0

    /// Changes when review credentials do, so the cards ask again.
    public func download(_ request: StreamRequest) async { await services.downloads?.enqueueBest(request) }
    public var downloadManager: DownloadManager? { services.downloads }

    public var reviewServicesRevision: Int { services.posterRatings.reviewServicesRevision }

    /// A visible card checks IMDb first; TMDb fills any remaining gaps. The store coalesces requests and controls refresh/retry times.
    /// The season's episode runtimes are looked up alongside.
    public func episodeAppeared(_ video: Video) async {
        async let runtimes: Void = loadEpisodeRuntimes(season: video.season)
        await loadEpisodeScores(season: video.season)
        if !Task.isCancelled, score(for: video) == nil { await loadEpisodeRatings(season: video.season) }
        await runtimes
    }

    /// Cards appearing together share the season lookup. Completed tasks are released so scrolling back can retry after a failure
    /// or cache expiry. Scrolling away does not cancel it: the answer is cached either way.
    public func loadEpisodeScores(season: Int?) async {
        guard let season, isSeries, let seriesID = seriesIMDbID else { return }
        let revision = reviewServicesRevision
        if scoresRevision != revision {
            scoresRevision = revision
            scoreTasks.removeAll()
        }
        if let running = scoreTasks[season] {
            await running.value
            return
        }
        let ratings = services.posterRatings
        let expected = Set(detail.episodes(inSeason: season).filter { $0.hasAired() }.compactMap(\.episode))
        let task = Task { [weak self] in
            let scores = await ratings.episodeRatings(for: seriesID, season: season, expectedEpisodes: expected)
            guard let self, scoresRevision == revision else { return }
            omdbEpisodeScores[season] = scores
        }
        scoreTasks[season] = task
        await task.value
        if scoreTasks[season] == task { scoreTasks[season] = nil }
    }

    /// IMDb's resolved score wins. TMDb can fill a gap once the season's IMDb lookup has finished.
    public func score(for video: Video) -> EpisodeScore? {
        if let season = video.season, let episode = video.episode, let value = omdbEpisodeScores[season]?[episode] {
            return EpisodeScore(value: value, isIMDb: true)
        }
        // A TMDb score waits only while OMDb is usable and has not yet answered for this season; once it has, TMDb fills its gaps.
        let omdbAnswered = video.season.map { omdbEpisodeScores[$0] != nil } ?? false
        if video.ratingSource == .tmdb, services.posterRatings.omdbAllowsEpisodeRequests, !omdbAnswered { return nil }
        return video.rating.map { EpisodeScore(value: $0, isIMDb: false) }
    }

    public var isSeries: Bool { detail.type == "series" || !detail.videos.isEmpty }
    public var seasons: [Int] { detail.seasons }
    public var episodes: [Video] { selectedSeason.map { detail.episodes(inSeason: $0) } ?? [] }

    /// What "Play" asks addons for: the movie itself.
    public var movieRequest: StreamRequest { StreamRequest(movie: detail.preview.type.isEmpty ? preview : detail.preview) }

    public func request(for video: Video) -> StreamRequest {
        var request = StreamRequest(episode: video, of: detail)
        if let minutes = episodeRuntimes[video.id] { request.expectedDuration = TimeInterval(minutes) * 60 }
        return request
    }

    /// The episodes the stream picker's switcher steps to from `request`'s: the one before and the one after in watching order, as their
    /// cards would open them. Each is nil when there is none or it has not aired, and both are nil for a film.
    public func neighbouringEpisodes(of request: StreamRequest) -> (previous: StreamRequest?, next: StreamRequest?) {
        // By its id first, so a series listing two videos with the same numbers still steps on from the one shown.
        guard isSeries, let season = request.season, let episode = request.episode,
              let video = detail.videos.first(where: { $0.id == request.id })
                ?? detail.videos.first(where: { $0.season == season && $0.episode == episode }) else { return (nil, nil) }
        let neighbours = detail.neighbouringEpisodes(of: video)
        return (neighbours.previous.map(self.request(for:)), neighbours.next.map(self.request(for:)))
    }

    /// Starts the stream lookup for the Play button's request, once per title. A new request (a series moving to its next episode) lets the previous lookup go.
    public func prefetchStreams(for request: StreamRequest?) async {
        guard let request, !Task.isCancelled else { return }
        if let previous = prefetchedStreamRequest, previous.id == request.id, previous.type == request.type { return }
        if let previous = prefetchedStreamRequest { services.streams.releasePrefetch(previous) }
        prefetchedStreamRequest = request
        // Register with the prefetch cache before lower-priority network work starts.
        await services.streams.prefetch(request)
    }

    /// Stop page-owned lookups after leaving the details screen. Individual cards may disappear
    /// while scrolling without cancelling their shared season requests; page departure is different.
    public func cancelOffscreenWork() {
        trailerSourcesTask?.cancel()
        trailerSourcesTask = nil
        for task in runtimeTasks.values { task.cancel() }
        runtimeTasks.removeAll()
        for task in scoreTasks.values { task.cancel() }
        scoreTasks.removeAll()
        reviewsLoadTimeout?.cancel()
        reviewsLoadTimeout = nil
    }

    /// Leaving the page lets an unclaimed lookup go (after a short grace), Shuffle's included.
    public func releaseStreamPrefetch() {
        shuffleLookup?.cancel()
        shuffleLookup = nil
        if let shuffle = prefetchedShuffleRequest {
            services.streams.releasePrefetch(shuffle)
            prefetchedShuffleRequest = nil
        }
        guard let request = prefetchedStreamRequest else { return }
        services.streams.releasePrefetch(request)
        prefetchedStreamRequest = nil
    }

    // MARK: Shuffle

    /// The episode Shuffle plays next, picked ahead so the button can name it. The first one's streams are looked up as the page opens.
    public private(set) var shuffleNext: Video?
    /// The lookup started for the first `shuffleNext`, let go when the page is left.
    private var prefetchedShuffleRequest: StreamRequest?
    /// Waits for the Play button's lookup to finish, then starts Shuffle's.
    private var shuffleLookup: Task<Void, Never>?
    /// True once Shuffle has been tapped: later picks are not looked up ahead.
    private var hasTakenShuffle = false

    /// Picks Shuffle's first episode and looks up its streams once the Play button's lookup has every answer, so the two never ask the
    /// addons at once, and the first tap of Shuffle starts at once. Coming back to the page looks the same episode up again.
    public func prepareShuffle() {
        guard !hasTakenShuffle, prefetchedShuffleRequest == nil else { return }
        if shuffleNext == nil { shuffleNext = randomEpisode(avoiding: nextUp) }
        guard let video = shuffleNext else { return }
        let request = request(for: video)
        prefetchedShuffleRequest = request
        let play = prefetchedStreamRequest
        let streams = services.streams
        shuffleLookup = Task {
            if let play { await streams.waitForPrefetch(play) }
            guard !Task.isCancelled else { return }
            await streams.prefetch(request)
        }
    }

    /// Shuffle's episode for this tap: the one picked ahead, else a new pick. The next one is picked at once and named beside the button;
    /// only the first is looked up ahead, so later taps load as Play does.
    public func takeShuffle() -> Video? {
        guard let video = shuffleNext ?? randomEpisode(avoiding: nil) else { return nil }
        hasTakenShuffle = true
        shuffleNext = randomEpisode(avoiding: video)
        return video
    }

    /// A random episode that has aired, other than `avoiding` when there is another to pick.
    private func randomEpisode(avoiding: Video?) -> Video? {
        let aired = detail.episodesCountingAsWatched()
        let others = aired.filter { $0.id != avoiding?.id }
        return (others.isEmpty ? aired : others).randomElement()
    }

    /// Series: resume the latest session, or move on from its completed episode before considering older unfinished ones.
    private func findNextUp() -> Video? {
        guard isSeries else { return nil }
        let ordered = watchingOrder
        if let latest = ordered.filter({ savedProgress[episodeIdentity($0)] != nil }).max(by: { lastUpdate($0) < lastUpdate($1) }),
           watchedIdentities.contains(episodeIdentity(latest)), let index = ordered.firstIndex(where: { $0.id == latest.id }),
           let next = ordered.dropFirst(index + 1).first(where: { !watchedIdentities.contains(episodeIdentity($0)) }) {
            return next
        }
        let unfinished = ordered.filter { isUnfinished(episodeIdentity($0)) }
        if let latest = unfinished.max(by: { lastUpdate($0) < lastUpdate($1) }) { return latest }
        return ordered.first(where: { !watchedIdentities.contains(episodeIdentity($0)) }) ?? ordered.first
    }

    /// "Play", "Resume", "Play S1 · E1", "Resume S2 · E5". "Resume" only when playback starts from saved progress. A next episode that has
    /// not aired yet gives its air date instead (see `unairedAirLabel`).
    public var primaryActionTitle: String {
        guard isSeries else { return progressFractions[movieIdentity] == nil ? "Play" : "Resume" }
        guard let next = nextUp else { return "Play" }
        if let airs = unairedAirLabel { return airs }
        let verb = progressFractions[episodeIdentity(next)] == nil ? "Play" : "Resume"
        guard let season = next.season, let episode = next.episode else { return verb }
        return "\(verb) S\(season) · E\(episode)"
    }

    /// What the main action plays: a movie itself, or a series' next episode once it has aired. Nil while a series' episodes are still
    /// arriving, and while the next episode has not aired: nothing is played then, and the button shows `unairedAirLabel` instead.
    public var primaryRequest: StreamRequest? {
        guard isSeries else { return movieRequest }
        guard let next = nextUp, next.hasAired() else { return nil }
        return request(for: next)
    }

    /// The main action's label while a series' next episode has not aired yet: its air date, e.g. "Airs Oct 20, 2026". Nil otherwise.
    public var unairedAirLabel: String? {
        guard let next = nextUp, !next.hasAired(), let airDate = next.airDate else { return nil }
        return "Airs \(airDate.formatted(date: .abbreviated, time: .omitted))"
    }

    // MARK: shuffle

    /// Whether Shuffle has an episode to pick: a series whose episodes have arrived, with at least one aired.
    public var canShuffle: Bool {
        // Eligibility needs one aired regular episode, not every season sorted and every air date parsed.
        let now = Date()
        return isSeries && detail.videos.contains { ($0.season.map { $0 > 0 } ?? true) && $0.hasAired(by: now) }
    }

    /// Shuffle's pick: a random episode that has aired, from the episodes "watched" covers, so specials stay out. An episode that has not
    /// aired is never picked, as it is never the next one. Nil for a movie and when `canShuffle` is false.
    public func shuffledRequest(now: Date = Date()) -> StreamRequest? {
        guard isSeries else { return nil }
        return detail.episodesCountingAsWatched(by: now).randomElement().map { request(for: $0) }
    }

    /// The episode's score as its card shows it ("89"), for the stream selector's heading. Nil for a film or an episode without a score.
    public func episodeScore(for request: StreamRequest) -> EpisodeScore? {
        guard isSeries, let season = request.season, let episode = request.episode,
              let video = detail.videos.first(where: { $0.season == season && $0.episode == episode }) else { return nil }
        return score(for: video)
    }

    /// The stream picker's episode asks for its season's scores the same way its card would, so its heading gets the score even when
    /// the card never came on screen (Play on a season the list is not showing).
    public func prepareEpisodeScore(for request: StreamRequest) async {
        guard isSeries, let season = request.season, let episode = request.episode,
              let video = detail.videos.first(where: { $0.season == season && $0.episode == episode }) else { return }
        await episodeAppeared(video)
    }

    /// Share of the movie that is saved and resumable (0...1). Nil when it has not started, is watched or cannot be resumed.
    public func progressFraction(for request: StreamRequest) -> Double? { progressFractions[request.identity] }

    /// The same for an episode of this series.
    public func progressFraction(for video: Video) -> Double? { progressFractions[episodeIdentity(video)] }

    /// Separate landscape and portrait heroes. Keep the transition's poster until the artwork lookup finishes. Falls back to the
    /// preview this page was opened from, so Home and the title page use the same URL.
    public var backdropURL: URL? {
        tmdbArtwork?.backdrop ?? (isLoadingArtwork ? nil : preview.background ?? MetahubArtwork.background(imdbID: preview.id))
    }
    public var portraitArtworkURL: URL? {
        tmdbArtwork?.portrait ?? (isLoadingArtwork ? nil : preview.background ?? MetahubArtwork.background(imdbID: preview.id))
    }

    /// The title's logo (a transparent image), when the preview or the TMDb lookup has one.
    public var logoURL: URL? { preview.logo ?? tmdbArtwork?.logo }

    /// Whether the portrait picture already carries the title, so the separate logo is not shown in portrait.
    public var portraitHidesLogo: Bool { tmdbArtwork?.portraitHidesLogo ?? false }

    /// The metadata line both heroes show, for `MetaLine`: year, the first two genres, certification, runtime and the IMDb rating, in that
    /// order ("2008", "Drama", "Crime", "PG-13", "152 min", "★ 90"). Missing parts
    /// stay nil and `MetaLine` leaves them out. The score is IMDb's own when the caller has it (`imdbRating`), else the catalog's.
    nonisolated public static func heroMetaParts(for preview: MetaPreview, certification: String?, imdbRating: Double? = nil) -> [String?] {
        let rating = (imdbRating ?? preview.imdbRating).map { "★ \(ScoreText.wholeScore($0))" }
        let genres = DetailViewModel.heroMetaGenres(for: preview).map { Optional($0) }
        return [preview.releaseInfo] + genres + [certification, preview.runtime, rating]
    }

    /// The genres the metadata line shows: the first two. `MetaLine` drops these first when the line is too long for one line.
    nonisolated public static func heroMetaGenres(for preview: MetaPreview) -> [String] {
        Array(preview.genres.prefix(2))
    }

    /// The metadata line under the hero, built by the shared store exactly as Home's spotlight builds it (see `HeroMetaStore.parts`).
    public var heroMetaLine: [String?] {
        services.heroMeta.parts(for: preview, certification: certification, ratings: services.posterRatings)
    }

    /// The genres in the metadata line, the same ones `heroMetaLine` shows, for `MetaLine` to drop first when the line is too long.
    public var heroMetaGenres: [String] {
        services.heroMeta.genres(for: preview)
    }

    /// The title's trailers known without a tap, merged and ordered (see `TrailerCatalog`): the iTunes preview first when there is one,
    /// then the addon's direct links; YouTube trailers only when there is no direct file at all.
    public var trailers: [Trailer] {
        TrailerCatalog.merge(previews: itunesTrailer.map { [$0] } ?? [], addonYouTubeIDs: detail.trailers, addonURLs: detail.trailerURLs,
                             tmdb: tmdbVideos)
    }

    /// Whether the trailer button can do anything: a trailer is known, or its sources have not all answered yet, so a tap waits for them.
    public var canPlayTrailer: Bool { !trailers.isEmpty || !hasCheckedTrailerSources }

    /// A rating's site, shown on the page under the ratings: its reviews for this title, or a search when the site has no page for it.
    public struct OpenedReviews: Equatable, Sendable {
        public let site: ReviewSite
        public let url: URL
        public let isSearch: Bool
    }

    /// The reviews opened from a rating, under the ratings. Nil when none are open.
    public private(set) var openedReviews: OpenedReviews?
    /// The site that stays on screen while another rating's site loads in its place. Nil once the new one shows, or when none was open.
    public private(set) var shownReviews: OpenedReviews?

    /// A rating's tap: shows its site's reviews under the ratings, or closes them when that site's are already open. Another site's reviews
    /// replace the ones open once they have loaded: until then the open site stays on screen. A trailer that is open stays open: the two
    /// sit on the page together, the trailer above the reviews.
    public func toggleReviews(_ site: ReviewSite, url: URL, isSearch: Bool) {
        if openedReviews?.site == site || shownReviews?.site == site {
            closeReviews()
            return
        }
        // The site on screen: the open one once it has loaded, or the one still kept while another loaded.
        if let open = openedReviews, !reviewsLoading { shownReviews = open }
        openedReviews = OpenedReviews(site: site, url: url, isSearch: isSearch)
        reviewsLoading = true
        startReviewsTimeout()
    }

    /// Closes the reviews opened from a rating.
    public func closeReviews() {
        openedReviews = nil
        shownReviews = nil
        reviewsDidLoad()
    }

    /// True from a rating's tap until its page has loaded (or failed to), so the rating shows a spinner, and the reviews stay collapsed.
    public private(set) var reviewsLoading = false
    @ObservationIgnored private var reviewsLoadTimeout: Task<Void, Never>?

    /// The reviews' page has loaded, or failed to: the spinner stops and the reviews open, in place of the site kept on screen meanwhile.
    public func reviewsDidLoad() {
        reviewsLoadTimeout?.cancel()
        reviewsLoadTimeout = nil
        reviewsLoading = false
        shownReviews = nil
    }

    /// A page that never finishes must not hold the spinner forever, so the reviews open after this long regardless.
    private func startReviewsTimeout() {
        reviewsLoadTimeout?.cancel()
        reviewsLoadTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled else { return }
            self?.reviewsDidLoad()
        }
    }

    /// Closes the trailer after the full-screen trailer's X, which gave its own haptic, so the Trailer button stays silent.
    public func closeTrailerQuietly() {
        trailerQuietCloses += 1
        trailer.close()
    }

    /// The trailer button's tap: loads the title's trailer into the page, or closes it while it plays. A YouTube video is checked
    /// with YouTube before it is tried in the page's embedded player. Reviews opened from a rating stay open, under the trailer.
    public func toggleTrailer() {
        trailer.toggle(TrailerLoader.Source(
            plan: { [weak self] in
                guard let self else { return TrailerPlan(trailers: []) }
                return await self.trailerPlan()
            },
            embedCheck: { [weak self] videoID in
                guard let self else { return YouTubeEmbedCheck.Answer(allowsEmbedding: false) }
                return await YouTubeEmbedCheck(client: self.services.client).check(videoID: videoID)
            }))
    }

    /// The trailers to try, best first: the iTunes preview and the addon's direct links, then the best YouTube trailers (see
    /// `TrailerCatalog.playbackOrder`).
    public func trailerPlan() async -> TrailerPlan {
        // A tap made while the page loads waits for the details and the trailers they lead to, rather than finding none.
        if !hasCheckedTrailerSources {
            await waitForDetails()
            if !Task.isCancelled { await loadTrailerSources() }
        }
        return TrailerPlan(trailers: TrailerCatalog.playbackOrder(previews: itunesTrailer.map { [$0] } ?? [], addonYouTubeIDs: detail.trailers,
                                                          addonURLs: detail.trailerURLs, tmdb: tmdbVideos))
    }

    public var subtitle: String {
        [detail.preview.releaseInfo, detail.preview.runtime, detail.preview.imdbRating.map { "★ \(ScoreText.wholeScore($0))" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Episodes in watching order: regular seasons, then specials, then any episode the addon gave no season.
    private var watchingOrder: [Video] {
        detail.seasons.flatMap { detail.episodes(inSeason: $0) } + detail.videos.filter { $0.season == nil }
    }

    private var movieIdentity: String { movieRequest.identity }

    /// The identity `request(for:)` gives an episode. Built here so a loop over every episode does not look up each next episode.
    private func episodeIdentity(_ video: Video) -> String {
        "\(detail.type.isEmpty ? "series" : detail.type)/\(video.id)"
    }

    /// Started but not watched.
    private func isUnfinished(_ identity: String) -> Bool {
        guard let record = savedProgress[identity] else { return false }
        return !record.isWatched && record.position > 0
    }

    private func lastUpdate(_ video: Video) -> Date {
        savedProgress[episodeIdentity(video)]?.updatedAt ?? .distantPast
    }
}
