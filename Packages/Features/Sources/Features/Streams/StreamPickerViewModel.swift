import Foundation
import Observation
import PlayerKit
import StremioKit

/// Stream picker: results appear grouped by addon as each one answers; ambiguous URLs are probed in the background.
@MainActor
@Observable
public final class StreamPickerViewModel {
    public enum Choice: Equatable {
        case play(PlaybackPlan)
        case openExternal(URL)
        /// The stream goes to another player app: open this link, which starts it there.
        case openInPlayer(ExternalPlayer, URL)
        /// The format needs an engine this build doesn't have. The picker offers the next stream.
        case unsupported(next: RankedStream?)
    }

    /// A consecutive run from one addon in the ranked list. An addon may have several sections to preserve release order.
    public struct AddonSection: Identifiable, Equatable {
        public let addon: AddonSummary
        public let streams: [RankedStream]
        public var id: String { streams.first?.id ?? addon.id.uuidString }
    }

    public let request: StreamRequest
    public private(set) var listing: StreamListing {
        didSet {
            if listing.items != oldValue.items || listing.isLoading != oldValue.isLoading { refreshDerivedListing() }
        }
    }
    /// True when no installed addon can answer this request at all (as opposed to "still loading" or "nothing found").
    public private(set) var nobodyCanAnswer = false
    public private(set) var settings = PlaybackSettings()
    /// The saved choice to start the best stream at once whenever streams are opened. The picker's switch shows it and changes it.
    public private(set) var autoPlaysBestStream = false
    public private(set) var hasLoaded = false
    public private(set) var isAutoPicking = false
    public private(set) var autoPickMessage: String?
    public private(set) var autoPickedStream: RankedStream?
    /// What "Play best" starts when Auto Pick has nothing to hand over, preserving release priority and player compatibility.
    public private(set) var bestToPlay: RankedStream?

    private let services: AppServices
    private var sniffTasks: [Task<Void, Never>] = []
    private var loadingTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var bestAssessment: AutoStreamRanking.Assessment?
    /// The player apps on this device, as the view reported them. Kept here so a load after it still routes with them.
    private var installedPlayers: Set<ExternalPlayer> = []
    /// The addon Auto Pick waits for (see `AutoPickWait`), read as the streams load with Auto Pick's switch on. Nil waits for every addon,
    /// as Auto Pick always has.
    private var waitTarget: UUID?
    /// Set for a picker that starts the best stream on opening whatever Auto Pick's switch says (a held poster): it then waits for the
    /// addon Auto Pick waits for, as with the switch on.
    public var startsAutomaticallyAnyway = false

    /// Extensions a file can carry for Infuse to name it by. Release names often end in something else ("...H.265-playWEB"), so only these
    /// count as the file's extension.
    private static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "webm", "wmv", "flv", "mpg", "mpeg"]

    public init(request: StreamRequest, services: AppServices) {
        self.request = request
        self.services = services
        self.listing = StreamListing(asking: [])
    }

    public var isLoading: Bool { !hasLoaded || listing.isLoading }
    /// Nothing found, and every addon that was asked failed because the device is offline.
    public var isOffline: Bool { hasLoaded && listing.isEmpty && Connectivity.isOffline(listing.failures.map(\.error)) }
    public var showsNothingFound: Bool { hasLoaded && !listing.isLoading && listing.isEmpty && !nobodyCanAnswer && !isOffline }

    /// Ranked streams with addon labels, without regrouping lower-quality releases ahead of higher-quality ones.
    public private(set) var addonSections: [AddonSection] = []

    /// Links to addon web pages, displayed separately from playable streams.
    public private(set) var links: [RankedStream] = []

    private func refreshDerivedListing() {
        var runs: [[RankedStream]] = []
        for item in listing.items where !Self.isLink(item) {
            if runs.last?.last?.addon.id == item.addon.id {
                runs[runs.count - 1].append(item)
            } else {
                runs.append([item])
            }
        }
        addonSections = runs.map { AddonSection(addon: $0[0].addon, streams: $0) }
        links = Self.linksToOffer(in: listing.items)
        // The player's routing policy has already applied the saved preference. Auto Pick must
        // rank only these watchable routes, not bypass the preference with an Infuse handoff.
        let candidates = automaticCandidates
        bestAssessment = listing.isLoading ? nil : AutoStreamRanking.best(from: candidates, duration: request.expectedDuration)
        bestToPlay = bestAssessment?.item ?? candidates.first
    }

    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        settings = await services.settings.load()
        waitTarget = settings.autoPlayBestStream || startsAutomaticallyAnyway ? await automaticWaitTarget() : nil
        let (asked, responses) = await services.streams.fetch(request)
        guard !Task.isCancelled, generation == loadGeneration else { return }
        var config = settings.policy(fallbackEngineLinked: services.fallbackEngineLinked, backupEngineLinked: services.aetherEngineLinked,
                                     decodesAV1InHardware: services.decodesAV1InHardware)
        config.installedPlayers = installedPlayers
        listing = StreamListing(asking: asked, config: config, preferences: settings.rankingPreferences)
        nobodyCanAnswer = asked.isEmpty
        hasLoaded = true
        guard !asked.isEmpty else { return }

        await withTaskCancellationHandler {
            var requested = Set<String>()
            for await response in responses {
                guard !Task.isCancelled, generation == loadGeneration else { return }
                listing.apply(response)
                let targets = listing.sniffTargets.filter { requested.insert($0.key).inserted }
                if !targets.isEmpty { startSniffing(targets) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.loadGeneration == generation else { return }
                self?.cancelSniffing()
            }
        }
    }

    /// Reads the saved choice to start the best stream at once, so the picker's switch shows the saved state each time it opens.
    public func loadAutoPlayPreference() async {
        settings = await services.settings.load()
        autoPlaysBestStream = settings.autoPlayBestStream
    }

    /// Saves the choice to start the best stream at once, keeping the other settings. It only saves: the picker starts nothing itself.
    public func setAutoPlaysBestStream(_ value: Bool) async {
        autoPlaysBestStream = value
        if !value { waitTarget = nil }
        settings = await services.settings.load()
        settings.autoPlayBestStream = value
        await services.settings.save(settings)
    }

    /// Automatic playback has a total selection deadline; slower answers still improve the open picker. When Auto Pick waits for one
    /// addon (see `AutoPickWait`), the wait ends once that addon has a stream to start; `stopsForWaitTarget` false keeps the whole window,
    /// for the next episode, which looks for a stream continuing the last one.
    public func loadForAutomaticSelection(timeout: Duration = .seconds(5), stopsForWaitTarget: Bool = true) async {
        if !hasLoaded, loadingTask == nil {
            loadingTask = Task { [weak self] in
                guard let self else { return }
                await self.load()
            }
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while isLoading, !(stopsForWaitTarget && waitTargetHasAnswered()), ContinuousClock.now < deadline,
              !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        if Task.isCancelled { cancelLoading() }
    }

    public func cancelLoading() {
        loadGeneration += 1
        if listing.isLoading { hasLoaded = false }
        loadingTask?.cancel()
        loadingTask = nil
        cancelSniffing()
    }

    // MARK: best Blu-ray edition

    /// Where a lookup of this film's best Blu-ray edition on bestblurays.com stands.
    public enum BestEditionState: Equatable {
        case idle
        case loading
        case found(BestBlurayEdition)
        /// The site has a page for the film but has named no best release on it yet.
        case listedWithoutEdition(title: String, url: URL)
        /// The site has no page for the film; the link searches it for the title.
        case notListed(searchURL: URL)
        case failed(String)
    }

    public private(set) var bestEdition: BestEditionState = .idle

    /// The lookup is for films: the site is a guide to films' discs.
    public var canFindBestEdition: Bool { request.type == "movie" && LetterboxdRatings.isIMDbID(request.id) }

    /// Reads the film's page on bestblurays.com. Done once per stream picker: an answer is kept, and only a failure asks again.
    public func findBestEdition() async {
        guard canFindBestEdition else { return }
        switch bestEdition {
        case .loading, .found, .listedWithoutEdition, .notListed: return
        case .idle, .failed: break
        }
        bestEdition = .loading
        do {
            let result = try await services.bestBlurays.bestEdition(imdbID: request.id, title: request.title, year: request.year)
            guard !Task.isCancelled else {
                bestEdition = .idle
                return
            }
            switch result {
            case .edition(let edition): bestEdition = .found(edition)
            case .pageWithoutEdition(let title, let url): bestEdition = .listedWithoutEdition(title: title, url: url)
            case .noPage(let searchURL): bestEdition = .notListed(searchURL: searchURL)
            }
        } catch {
            // Leaving the stream picker cancels the lookup; it can run again when the page returns.
            bestEdition = Task.isCancelled ? .idle : .failed(AddonError.from(error).shortDescription)
        }
    }

    /// The player apps installed on this device. Streams are only handed to these. The view asks once, when the picker opens.
    public func setInstalledPlayers(_ players: Set<ExternalPlayer>) {
        installedPlayers = players
        var config = listing.config
        config.installedPlayers = players
        listing.update(config: config)
    }

    private func startSniffing(_ targets: [StreamListing.SniffTarget]) {
        let results = services.streams.sniff(targets)
        let generation = loadGeneration
        sniffTasks.append(Task { [weak self] in
            for await result in results {
                guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
                if let container = result.container { self.listing.setContainer(container, forKey: result.key) }
            }
        })
    }

    private func cancelSniffing() {
        sniffTasks.forEach { $0.cancel() }
    }

    /// What happens when the user taps a stream.
    public func choose(_ item: RankedStream) async -> Choice? {
        switch item.route {
        case .native, .fallback:
            return PlaybackPlan.make(request: request, chosen: item, from: listing).map(Choice.play)
        case .handoff(let player, _):
            return await handoffChoice(for: item, player: player)
        case .external(let url):
            return .openExternal(url)
        case .unsupported:
            return .unsupported(next: nextPlayable(after: item))
        case .hidden:
            return nil
        }
    }

    /// The best stream the user can start, in Blusion or in the app they chose, for a one-tap "Play best".
    public func playBest() async -> Choice? {
        guard let best = bestToPlay else { return nil }
        return await choose(best)
    }

    /// Called by Auto Pick and automatic playback. Uses the selected player policy,
    /// so choosing Blusion never silently switches to Infuse.
    public func autoPickBest() async -> Choice? {
        guard !isAutoPicking else { return nil }
        isAutoPicking = true
        autoPickMessage = nil
        defer { isAutoPicking = false }
        // Wait for the chosen addon when applicable; it must have a stream playable
        // through the saved policy, rather than merely one Infuse could accept.
        while isLoading, !waitTargetHasAnswered() {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
        }
        guard !Task.isCancelled else { return nil }
        let assessment = isLoading ? AutoStreamRanking.best(from: automaticCandidates, duration: request.expectedDuration) : bestAssessment
        guard let pick = assessment else {
            autoPickMessage = "No playable streams were found."
            return nil
        }
        guard !Task.isCancelled else { return nil }
        autoPickedStream = pick.item
        return await choose(pick.item)
    }

    /// The stream Auto Pick would start, marked in the list before anyone asks for it. Nil while the addons are still answering, so the
    /// mark does not jump from one release to another as they arrive.
    public var recommendedStream: RankedStream? {
        guard !isLoading else { return nil }
        return bestAssessment?.item
    }

    /// What kind of stream Auto Pick would start, as its button says it: "4K · REMUX". Nil while the addons are still answering and when
    /// there is nothing Auto Pick can start, like `recommendedStream`.
    public var recommendedStreamLabel: String? {
        guard !isLoading, let pick = bestAssessment else { return nil }
        let sharpness = pick.item.quality.resolutionLabel ?? "stream"
        return "\(sharpness) · \(pick.isRemux ? "REMUX" : pick.item.quality.source?.rawValue ?? "release")"
    }

    /// Auto Pick and the recommendation use the same set of routes as ordinary Play.
    /// Respect an explicit resolution preference and avoid mixing lower-ranked route classes.
    private var automaticCandidates: [RankedStream] {
        let watchable = listing.items.filter { $0.route.isWatchable }
        if settings.rankingPreferences.preferredResolution != nil { return Array(watchable.prefix(1)) }
        guard let first = watchable.first else { return [] }
        return watchable.filter { $0.route.sortClass == first.route.sortClass }
    }

    /// The addon Auto Pick waits for under the saved choice: one the user named, Auto's fastest, or nil for every addon.
    private func automaticWaitTarget() async -> UUID? {
        guard settings.autoPickWait != .allAddons else { return nil }
        let enabled = await services.registry.addons.filter(\.isEnabled).map(\.id)
        let current = await services.addonSpeed.autoPick()
        let target = AddonSpeedChoice.target(for: settings.autoPickWait, enabled: enabled, results: await services.addonSpeed.results(),
                                             preferredResolution: settings.preferredResolution, current: current)
        // Auto's pick is kept, so the next load only moves from it to an addon that is clearly faster.
        if settings.autoPickWait == .fastest, target != current { await services.addonSpeed.setAutoPick(target) }
        return target
    }

    /// True once the chosen addon answers with a stream the saved player can start.
    /// When it fails or has no watchable streams we continue waiting for other addons.
    private func waitTargetHasAnswered() -> Bool {
        guard let waitTarget, hasLoaded, !listing.pending.contains(where: { $0.id == waitTarget }) else { return false }
        return listing.items.contains { item in
            (item.addon.id == waitTarget || item.alsoProvidedBy.contains { $0.id == waitTarget })
                && item.route.isWatchable
        }
    }

    /// The first stream Blusion plays itself after `item`: what "Try the next stream" plays.
    public func nextPlayable(after item: RankedStream) -> RankedStream? {
        guard let index = listing.items.firstIndex(where: { $0.id == item.id }) else { return listing.playable.first }
        return listing.items[(index + 1)...].first { $0.route.isPlayable } ?? listing.playable.first
    }

    /// For binge-watching: the stream continuing the previous episode's group, if this listing has one.
    public func bingeChoice(continuing previous: BingeContext?) async -> Choice? {
        guard let pick = BingeSelection.pick(from: listing.items, continuing: previous) else { return nil }
        return await choose(pick)
    }

    /// The hand-off for `item` in `player`, remembered in the hand-off store so the callback can be recorded.
    /// nil when the player cannot take this stream (not an http(s) URL, or it needs request headers).
    public func handoffChoice(for item: RankedStream, player: ExternalPlayer) async -> Choice? {
        let headers = item.stream.behaviorHints.proxyHeaders?.request ?? [:]
        guard let streamURL = PlaybackPolicy.playbackURL(for: item.stream, config: listing.config),
              player.canPlay(streamURL: streamURL, headers: headers) else { return nil }
        let saved = await services.progress.progress(for: request.identity)
        guard !Task.isCancelled else { return nil }
        let token = UUID().uuidString
        let link = ExternalPlaybackRequest(streamURL: streamURL,
                                           position: Self.wholeSeconds(ProgressRecorder.resumePosition(for: saved)),
                                           filename: fileName(for: item, streamURL: streamURL),
                                           subtitleURL: subtitleURL(for: item),
                                           successCallback: ExternalPlayerCallback.successURL(token: token),
                                           errorCallback: ExternalPlayerCallback.errorURL(token: token))
        guard let url = player.playURL(for: link) else { return nil }
        await services.handoffs.save(PlaybackHandoff(id: token, request: request, player: player))
        guard !Task.isCancelled else { await discardHandoff(for: url); return nil }
        return .openInPlayer(player, url)
    }

    /// Saving is available for eligible streams regardless of which player is preferred for playback.
    public func savingPlayer(for item: RankedStream) -> ExternalPlayer? {
        guard let streamURL = PlaybackPolicy.playbackURL(for: item.stream, config: listing.config) else { return nil }
        return ExternalPlayer.allCases.first { player in
            installedPlayers.contains(player)
                && player.canPlay(streamURL: streamURL, headers: item.stream.behaviorHints.proxyHeaders?.request ?? [:])
        }
    }

    /// Bookmark saves use success/error callbacks; downloads only request an error callback.
    /// Infuse must stay in front while transferring, and its save-success callback does not mean
    /// the file finished downloading.
    /// https://support.firecore.com/hc/en-us/articles/215090997-API-for-Third-Party-Apps-Services
    public func saveLink(for item: RankedStream, download: Bool = false) async -> URL? {
        guard !Task.isCancelled, let player = savingPlayer(for: item),
              let streamURL = PlaybackPolicy.playbackURL(for: item.stream, config: listing.config),
              player.canPlay(streamURL: streamURL, headers: item.stream.behaviorHints.proxyHeaders?.request ?? [:]) else { return nil }
        let token = UUID().uuidString
        guard let url = player.saveURL(for: ExternalPlaybackRequest(streamURL: streamURL, filename: fileName(for: item, streamURL: streamURL),
            subtitleURL: subtitleURL(for: item), successCallback: download ? nil : ExternalPlayerCallback.successURL(token: token),
            errorCallback: ExternalPlayerCallback.errorURL(token: token)), download: download) else { return nil }
        await services.handoffs.save(PlaybackHandoff(id: token, request: request, player: player, action: download ? .download : .save))
        guard !Task.isCancelled else { await discardHandoff(for: url); return nil }
        return url
    }

    /// The callback token in an outgoing link, used to match confirmations and discard launches iOS refused.
    public static func handoffToken(in link: URL) -> String? {
        guard let text = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "x-success" || $0.name == "x-error" })?.value,
              let callback = URL(string: text) else { return nil }
        return ExternalPlayerCallback.parse(callback)?.token
    }

    public func discardHandoff(for link: URL) async {
        guard let token = Self.handoffToken(in: link) else { return }
        _ = await services.handoffs.take(id: token)
    }

    /// Installed players that could take this stream as an alternative to its default route (the row's context menu and the "unsupported
    /// format" alert use them). Empty when the route already is a hand-off to that player.
    public func alternativePlayers(for item: RankedStream) -> [ExternalPlayer] {
        guard let streamURL = PlaybackPolicy.playbackURL(for: item.stream, config: listing.config) else { return [] }
        let headers = item.stream.behaviorHints.proxyHeaders?.request ?? [:]
        return ExternalPlayer.allCases.filter { player in
            listing.config.installedPlayers.contains(player) && item.route.handoffTarget?.player != player
                && player.canPlay(streamURL: streamURL, headers: headers)
        }
    }

    /// Plays the stream in Blusion even though it would be handed off, when Blusion itself can play it. nil when it cannot.
    public func inAppChoice(for item: RankedStream) -> Choice? {
        var builtIn = listing.config
        builtIn.playerPreference = .builtIn
        let route = PlaybackPolicy.route(for: item.stream, container: item.container, quality: item.quality, config: builtIn)
        guard route.isPlayable else { return nil }
        return PlaybackPlan.make(request: request, chosen: item.rerouted(route), from: listing).map(Choice.play)
    }

    public func retry() async {
        cancelLoading()
        sniffTasks = []
        hasLoaded = false
        await load()
    }

    // MARK: details

    private static func isLink(_ item: RankedStream) -> Bool {
        if case .external = item.route { return true }
        return false
    }

    /// How many YouTube links the picker offers. Addons give no view counts, so the two best-ranked stand in for the most watched.
    static let maxYouTubeLinks = 2

    /// The links to offer, in ranked order: at most `maxYouTubeLinks` YouTube streams (the first ones, since `items` is ranked best first),
    /// and every other link as it is. The YouTube streams past that are dropped.
    static func linksToOffer(in items: [RankedStream]) -> [RankedStream] {
        var youTubeOffered = 0
        return items.filter { item in
            guard isLink(item) else { return false }
            guard case .youtube = item.stream.source else { return true }
            youTubeOffered += 1
            return youTubeOffered <= maxYouTubeLinks
        }
    }

    /// Whole seconds, rounded down. nil when there is less than a second to resume from.
    private static func wholeSeconds(_ seconds: TimeInterval) -> Int? {
        guard seconds.isFinite, seconds >= 1, seconds < TimeInterval(Int.max) else { return nil }
        return Int(seconds)
    }

    /// The name Infuse gets: the series for an episode, the title for a movie, with the extension the file has.
    private func fileName(for item: RankedStream, streamURL: URL) -> String {
        ExternalPlayerCallback.filename(title: request.seriesName ?? request.title, year: request.year, season: request.season,
                                        episode: request.episode, fileExtension: fileExtension(for: item, streamURL: streamURL))
    }

    /// The file's extension, taken from the first of these that is a video extension: the addon's filename hint, the stream's path, the container
    /// Blusion knows. nil when none of them says (the name then defaults to mp4).
    private func fileExtension(for item: RankedStream, streamURL: URL) -> String? {
        let hint = item.stream.behaviorHints.filename
        if let hint, let ext = Self.videoExtension(of: (hint as NSString).pathExtension) { return ext }
        if let ext = Self.videoExtension(of: streamURL.pathExtension) { return ext }
        return (item.container ?? ContainerSniffer.container(url: streamURL, filename: hint))?.fileExtension
    }

    private static func videoExtension(of ext: String) -> String? {
        let lowered = ext.lowercased()
        return videoExtensions.contains(lowered) ? lowered : nil
    }

    /// The stream's own subtitle in the user's language, when the settings name one and the stream offers it.
    private func subtitleURL(for item: RankedStream) -> URL? {
        guard let language = settings.subtitleLanguage, !language.isEmpty else { return nil }
        return item.stream.subtitles.first { LanguageCodes.matches($0.lang, preferred: language) }?.url
    }
}
