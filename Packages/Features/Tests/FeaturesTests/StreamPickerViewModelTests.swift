import Foundation
import PlayerKit
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

@MainActor
@Suite struct StreamPickerViewModelTests {
    private let request = StreamRequest(type: "movie", id: "tt1", title: "Test Movie")
    /// A movie with a year, so hand-off file names have one.
    private let movie = StreamRequest(type: "movie", id: "tt1", title: "Test Movie", year: "2010")

    /// Addon `stubN` answers with `bodies[N]` after `delays[N]`.
    private func services(bodies: [String], delays: [Duration] = [], failing: Set<Int> = [], sniffer: [String: MediaContainer] = [:],
                          settings: PlaybackSettings = PlaybackSettings(), fallbackLinked: Bool = false,
                          progress: [WatchProgress] = []) async throws -> AppServices {
        let transport = StubTransport { request, _ in
            let index = Int(request.url?.host?.dropFirst(4).prefix(while: \.isNumber) ?? "0") ?? 0
            if index < delays.count { try await Task.sleep(for: delays[index]) }
            if failing.contains(index) { return StubTransport.response(Data(), status: 500, for: request) }
            return StubTransport.response(Data(bodies[index].utf8), for: request)
        }
        let (registry, client) = try await makeStubbedRegistry(manifests: bodies.indices.map { streamManifest("addon\($0)") }, transport: transport)
        return AppServices(registry: registry, client: client,
                           streams: StreamService(registry: registry, client: client, sniffer: StubSniffer(sniffer)),
                           settings: InMemorySettingsStore(settings), progress: InMemoryProgressStore(progress), fallbackEngineLinked: fallbackLinked)
    }

    private func body(_ streams: [String]) -> String { #"{"streams":[\#(streams.joined(separator: ","))]}"# }
    private func direct(_ name: String, _ url: String, _ description: String = "") -> String {
        #"{"name":"\#(name)","description":"\#(description)","url":"\#(url)"}"#
    }

    @Test func loadsGroupsAndRanksAcrossAddons() async throws {
        let services = try await services(bodies: [
            body([direct("A 720", "https://a.example.com/1.mp4", "720p"), direct("A 1080", "https://a.example.com/2.mp4", "1080p")]),
            body([direct("B 2160 mkv", "https://b.example.com/1.mkv", "2160p"), direct("B 1080", "https://b.example.com/3.mp4", "1080p")]),
        ])
        let model = StreamPickerViewModel(request: request, services: services)
        #expect(model.isLoading)
        await model.load()
        #expect(!model.isLoading)
        #expect(model.listing.groups.map(\.addon.name) == ["addon0", "addon1"])
        #expect(model.listing.groups[0].streams.map(\.title) == ["A 1080", "A 720"])
        #expect(model.listing.items.map(\.title) == ["A 1080", "B 1080", "A 720", "B 2160 mkv"])
        #expect(model.listing.items.last?.route == .unsupported(.matroska), "no fallback engine linked yet")
        #expect(model.addonSections.flatMap(\.streams) == model.listing.items, "addon labels preserve global ranking")
        #expect(Set(model.addonSections.map(\.id)).count == model.addonSections.count, "repeated addons have distinct section IDs")
    }

    @Test func resultsAppearBeforeTheSlowestAddonAnswers() async throws {
        let services = try await services(bodies: [body([direct("slow", "https://a.example.com/1.mp4")]), body([direct("fast", "https://b.example.com/1.mp4")])],
                                          delays: [.milliseconds(400), .milliseconds(0)])
        let model = StreamPickerViewModel(request: request, services: services)
        let loading = Task { await model.load() }
        try await waitUntil { !model.listing.isEmpty }
        #expect(model.listing.items.map(\.title) == ["fast"])
        #expect(model.listing.isLoading, "the slow addon is still pending")
        #expect(model.isLoading)
        await loading.value
        #expect(Set(model.listing.items.map(\.title)) == ["fast", "slow"])
        #expect(!model.isLoading)
    }

    @Test func ambiguousURLsAreSniffedInTheBackground() async throws {
        let services = try await services(bodies: [body([direct("blob", "https://a.example.com/blob", "1080p")])], sniffer: ["blob": .matroska])
        let model = StreamPickerViewModel(request: request, services: services)
        await model.load()
        try await waitUntil { model.listing.items.first?.container == .matroska }
        #expect(model.listing.items.first?.route == .unsupported(.matroska))
    }

    @Test func automaticSelectionHasAnOverallDeadlineAndKeepsFastResults() async throws {
        let services = try await services(bodies: [body([direct("slow", "https://a.example.com/1.mp4")]), body([direct("fast", "https://b.example.com/1.mp4")])],
                                          delays: [.seconds(6), .zero])
        let model = StreamPickerViewModel(request: request, services: services)
        defer { model.cancelLoading() }
        // Well short of the slow addon's six seconds, and long enough for the fast one to answer while the other suites run beside this
        // one on a busy Mac.
        await model.loadForAutomaticSelection(timeout: .milliseconds(2000))
        #expect(model.isLoading, "the slow addon is still pending")
        #expect(model.listing.best?.title == "fast")
    }

    @Test func aFailingAddonBecomesAFailureEntry() async throws {
        let services = try await services(bodies: [body([]), body([direct("ok", "https://b.example.com/1.mp4")])], failing: [0])
        let model = StreamPickerViewModel(request: request, services: services)
        await model.load()
        #expect(model.listing.failures.map(\.error) == [.http(status: 500)])
        #expect(model.listing.items.count == 1)
        #expect(!model.showsNothingFound)
    }

    @Test func emptyAnswersMeanNothingFoundNotNobodyCanAnswer() async throws {
        let services = try await services(bodies: [body([])])
        let model = StreamPickerViewModel(request: request, services: services)
        await model.load()
        #expect(model.showsNothingFound)
        #expect(!model.nobodyCanAnswer)
    }

    @Test func noInstalledStreamAddonMeansNobodyCanAnswer() async throws {
        let client = makeClient(StubTransport(data: Data()))
        let registry = AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client)
        let model = StreamPickerViewModel(request: request, services: AppServices(registry: registry, client: client))
        await model.load()
        #expect(model.nobodyCanAnswer)
        #expect(!model.showsNothingFound)
        #expect(!model.isLoading)
    }

    // MARK: best Blu-ray edition

    private let darkKnightPage = #"""
    <html><head><title>The Dark Knight (2008) 4K Blu-ray Guide</title>
    <script type="application/ld+json">{"sameAs":["https://www.imdb.com/title/tt0468569"]}</script></head><body>
    <section><h2><a href="/labels/wb">WB</a> <a href="/tag/4k-blu-ray">4K Blu-ray</a></h2>
    <p>Best English-friendly &amp; video release<!-- --> · updated 4 months ago</p>
    <p>UHD tiers</p><a><span>Solid</span></a><p>Compare the discs</p></section></body></html>
    """#

    private func bestBlurayModel(_ transport: StubTransport, preview: MetaPreview? = nil) -> StreamPickerViewModel {
        let client = makeClient(transport, retries: 0)
        let services = AppServices(registry: AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client),
                                   client: client, bestBlurays: BestBluraysClient(client: client))
        return StreamPickerViewModel(request: StreamRequest(movie: preview ?? MetaPreview(id: "tt0468569", type: "movie", name: "The Dark Knight", releaseInfo: "2008")),
                                     services: services)
    }

    @Test func aFilmFindsItsBestEditionOnceAndKeepsTheAnswer() async throws {
        let page = darkKnightPage
        let transport = StubTransport { request, _ in
            let path = request.url?.path ?? ""
            let body = path == "/films" ? #"<a href="/film/1810-the-dark-knight-rises-2012">r</a><a href="/film/652-the-dark-knight-2008">k</a>"# : page
            return StubTransport.response(Data(body.utf8), for: request)
        }
        let model = bestBlurayModel(transport)
        #expect(model.canFindBestEdition && model.bestEdition == .idle)
        await model.findBestEdition()
        guard case .found(let edition) = model.bestEdition else { Issue.record("expected an edition, got \(model.bestEdition)"); return }
        #expect(edition.release == "WB 4K Blu-ray" && edition.uhdTier == "Solid" && edition.is4K)
        #expect(transport.requests.compactMap { $0.url?.path } == ["/films", "/film/652-the-dark-knight-2008"], "year 2008 came from the preview")
        await model.findBestEdition()
        #expect(transport.callCount == 2, "an answer is kept while the stream picker is open")
    }

    @Test func aFailedLookupCanBeAskedAgain() async throws {
        let page = darkKnightPage
        let transport = StubTransport { request, call in
            if call == 1 { throw AddonError.offline }
            let body = request.url?.path == "/films" ? #"<a href="/film/652-the-dark-knight-2008">k</a>"# : page
            return StubTransport.response(Data(body.utf8), for: request)
        }
        let model = bestBlurayModel(transport)
        await model.findBestEdition()
        guard case .failed(let text) = model.bestEdition else { Issue.record("expected a failure, got \(model.bestEdition)"); return }
        #expect(!text.isEmpty)
        await model.findBestEdition()
        guard case .found = model.bestEdition else { Issue.record("expected an edition, got \(model.bestEdition)"); return }
    }

    @Test func onlyFilmsWithAnIMDbIDOfferTheLookup() async {
        let transport = StubTransport(data: Data())
        #expect(!bestBlurayModel(transport, preview: MetaPreview(id: "tt0903747", type: "series", name: "Breaking Bad")).canFindBestEdition)
        #expect(!bestBlurayModel(transport, preview: MetaPreview(id: "kitsu:1", type: "movie", name: "Anime")).canFindBestEdition)
        #expect(bestBlurayModel(transport, preview: MetaPreview(id: "tt1375666", type: "movie", name: "Inception")).canFindBestEdition)
        await bestBlurayModel(transport, preview: MetaPreview(id: "tt0903747", type: "series", name: "Breaking Bad")).findBestEdition()
        await bestBlurayModel(transport, preview: MetaPreview(id: "kitsu:1", type: "movie", name: "Anime")).findBestEdition()
        #expect(transport.callCount == 0)
    }

    @Test(arguments: [true, false])
    func bestEditionAndStreamsLoadIndependently(slowLookup: Bool) async throws {
        let page = darkKnightPage
        let streams = body([direct("1080p", "https://a.example.com/movie.mp4")])
        let transport = StubTransport { request, _ in
            let isAddon = request.url?.host == "stub0.example.com"
            if (isAddon && !slowLookup) || (!isAddon && slowLookup && request.url?.path == "/films") {
                try await Task.sleep(for: .milliseconds(400))
            }
            let body = isAddon ? streams : request.url?.path == "/films" ? #"<a href="/film/652-the-dark-knight-2008">k</a>"# : page
            return StubTransport.response(Data(body.utf8), for: request)
        }
        let (registry, client) = try await makeStubbedRegistry(manifests: [streamManifest("addon")], transport: transport)
        let model = StreamPickerViewModel(request: StreamRequest(type: "movie", id: "tt0468569", title: "The Dark Knight", year: "2008"),
                                          services: AppServices(registry: registry, client: client))
        let loading = Task { await model.load() }
        let lookup = Task { await model.findBestEdition() }
        if slowLookup {
            try await waitUntil { !model.isLoading }
            #expect(model.bestEdition == .loading)
            guard case .play? = await model.playBest() else { Issue.record("expected playback before the lookup finishes"); return }
        } else {
            try await waitUntil {
                if case .found = model.bestEdition { return true }
                return false
            }
            #expect(model.isLoading && model.listing.isEmpty)
        }
        await loading.value
        await lookup.value
        #expect(!model.isLoading)
        guard case .found = model.bestEdition else { Issue.record("expected an edition"); return }
    }

    // MARK: choosing

    @Test func choosingAPlayableStreamBuildsAPlanWithAlternativesInRankOrder() async throws {
        let services = try await services(bodies: [body([direct("720", "https://a.example.com/1.mp4", "720p"), direct("1080", "https://a.example.com/2.mp4", "1080p"),
                                                         direct("mkv", "https://a.example.com/3.mkv", "2160p")])])
        let model = StreamPickerViewModel(request: request, services: services)
        await model.load()
        let chosen = try #require(model.listing.items.first { $0.title == "720" })
        guard case .play(let plan)? = await model.choose(chosen) else { Issue.record("expected a plan"); return }
        #expect(plan.request == request)
        #expect(plan.candidates.map(\.title) == ["720", "1080"], "the choice first, then the other playable streams; the unsupported one is not offered")
        #expect(plan.candidates.allSatisfy { $0.route.isPlayable })
        guard case .play(let best)? = await model.playBest() else { Issue.record("expected a plan"); return }
        #expect(best.candidates.first?.title == "1080")
    }

    @Test func unsupportedStreamsOfferTheNextPlayableOne() async throws {
        let services = try await services(bodies: [body([direct("mkv", "https://a.example.com/1.mkv", "2160p"), direct("mp4", "https://a.example.com/2.mp4", "1080p")])])
        let model = StreamPickerViewModel(request: request, services: services)
        await model.load()
        let unsupported = try #require(model.listing.items.first { $0.title == "mkv" })
        guard case .unsupported(let next)? = await model.choose(unsupported) else { Issue.record("expected unsupported"); return }
        #expect(next?.title == "mp4")
    }

    @Test func withTheFallbackEngineLinkedMKVIsPlayable() async throws {
        let services = try await services(bodies: [body([direct("mkv", "https://a.example.com/1.mkv", "2160p")])], fallbackLinked: true)
        let model = StreamPickerViewModel(request: request, services: services)
        await model.load()
        let first = try #require(model.listing.items.first)
        guard case .play(let plan)? = await model.choose(first) else { Issue.record("expected a plan"); return }
        #expect(plan.candidates.first?.route == .fallback(URL(string: "https://a.example.com/1.mkv")!, .container(.matroska)))
    }

    @Test func settingsCanDisableTheFallbackEngine() async throws {
        let services = try await services(bodies: [body([direct("mkv", "https://a.example.com/1.mkv")])], settings: PlaybackSettings(fallbackEngineEnabled: false), fallbackLinked: true)
        let model = StreamPickerViewModel(request: request, services: services)
        await model.load()
        #expect(model.listing.items.first?.route == .unsupported(.matroska))
    }

    @Test func externalLinksOpenOutsideTheApp() async throws {
        let services = try await services(bodies: [body([#"{"name":"YT","ytId":"abc123"}"#, #"{"name":"Site","externalUrl":"https://example.com/w"}"#])])
        let model = StreamPickerViewModel(request: request, services: services)
        await model.load()
        var urls: [URL] = []
        for item in model.listing.items {
            if case .openExternal(let url)? = await model.choose(item) { urls.append(url) }
        }
        #expect(Set(urls) == [URL(string: "https://www.youtube.com/watch?v=abc123")!, URL(string: "https://example.com/w")!])
    }

    @Test func linksToWebPagesHaveTheirOwnGroupAndTheAddonGroupsHoldTheStreams() async throws {
        let services = try await services(bodies: [body([#"{"name":"Removal Reasons","externalUrl":"https://example.com/summary"}"#,
                                                         direct("1080", "https://a.example.com/2.mp4", "1080p")])])
        let model = StreamPickerViewModel(request: request, services: services)
        await model.load()
        #expect(model.links.map(\.title) == ["Removal Reasons"])
        #expect(model.addonSections.map { $0.streams.map(\.title) } == [["1080"]])
        #expect(model.listing.items.map(\.title) == ["1080", "Removal Reasons"], "links rank below playable streams")
    }

    @Test func onlyTheTwoBestRankedYouTubeLinksAreOffered() async throws {
        let services = try await services(bodies: [body([#"{"name":"YT 1","ytId":"aaa"}"#, #"{"name":"Site","externalUrl":"https://example.com/w"}"#,
                                                         #"{"name":"YT 2","ytId":"bbb"}"#, #"{"name":"YT 3","ytId":"ccc"}"#])])
        let model = StreamPickerViewModel(request: request, services: services)
        await model.load()
        let isYouTube = { (item: RankedStream) -> Bool in
            if case .youtube = item.stream.source { return true }
            return false
        }
        let youTubeInRankOrder = model.listing.items.filter(isYouTube).map(\.title)
        #expect(youTubeInRankOrder.count == 3, "all three are playable links to the picker's listing")
        #expect(model.links.filter(isYouTube).map(\.title) == Array(youTubeInRankOrder.prefix(2)), "the two best ranked are kept")
        #expect(model.links.contains { $0.title == "Site" }, "a link to a web page is not limited")
        #expect(model.links.count == 3)
    }

    @Test func torrentsShowUpOnceAStreamingServerIsConfigured() async throws {
        let torrent = #"{"name":"T","infoHash":"0123456789abcdef0123456789abcdef01234567","fileIdx":2}"#
        let without = try await services(bodies: [body([torrent])])
        let hidden = StreamPickerViewModel(request: request, services: without)
        await hidden.load()
        #expect(hidden.listing.items.isEmpty && hidden.listing.hidden.first?.reason == .needsStreamingServer)
        #expect(hidden.showsNothingFound)

        let with = try await services(bodies: [body([torrent])], settings: PlaybackSettings(streamingServerURL: "http://192.168.1.9:11470"))
        let shown = StreamPickerViewModel(request: request, services: with)
        await shown.load()
        #expect(shown.listing.best?.route.playableURL?.absoluteString == "http://192.168.1.9:11470/0123456789abcdef0123456789abcdef01234567/2")
    }

    @Test func preferredResolutionFromSettingsReRanks() async throws {
        let streams = [direct("uhd", "https://a.example.com/1.mp4", "2160p"), direct("hd", "https://a.example.com/2.mp4", "720p")]
        let services = try await services(bodies: [body(streams)], settings: PlaybackSettings(preferredResolution: 720))
        let model = StreamPickerViewModel(request: request, services: services)
        await model.load()
        #expect(model.listing.items.map(\.title) == ["hd", "uhd"])
    }

    @Test func playBestFollowsThePreferredResolution() async throws {
        // An explicit preferred resolution decides play best, even where the quality score prefers the larger 4K release.
        let streams = [direct("uhd", "https://a.example.com/1.mp4", "2160p WEB-DL 40 GB"), direct("hd", "https://a.example.com/2.mp4", "720p WEB-DL 3 GB")]
        let services = try await services(bodies: [body(streams)], settings: PlaybackSettings(preferredResolution: 720))
        let model = StreamPickerViewModel(request: request, services: services)
        await model.load()
        guard case .play(let plan)? = await model.playBest() else { Issue.record("expected a plan"); return }
        #expect(plan.candidates.first?.title == "hd")
    }

    @Test func bingeGroupContinuityPicksTheMatchingStream() async throws {
        let withGroup = { (name: String, url: String, group: String) in #"{"name":"\#(name)","url":"\#(url)","behaviorHints":{"bingeGroup":"\#(group)"}}"# }
        let services = try await services(bodies: [body([withGroup("other", "https://a.example.com/1.mp4", "g-other"), withGroup("match", "https://a.example.com/2.mp4", "g-1080")])])
        let model = StreamPickerViewModel(request: request, services: services)
        await model.load()
        guard case .play(let plan)? = await model.bingeChoice(continuing: BingeContext(bingeGroup: "g-1080")) else { Issue.record("expected a plan"); return }
        #expect(plan.candidates.first?.title == "match")
        #expect(plan.candidates.first?.bingeContext?.bingeGroup == "g-1080")
        let unknownGroup = await model.bingeChoice(continuing: BingeContext(bingeGroup: "nope"))
        #expect(unknownGroup == nil)
        let noContext = await model.bingeChoice(continuing: nil)
        #expect(noContext == nil)
    }

    @Test func candidatesCarryHeadersSubtitlesAndHashes() async throws {
        let stream = #"{"name":"P","url":"https://a.example.com/p.mp4","#
            + #""subtitles":[{"id":"s","url":"https://a.example.com/s.srt","lang":"eng"}],"#
            + #""behaviorHints":{"proxyHeaders":{"request":{"Referer":"https://r.example.com"}},"videoHash":"abc","videoSize":12345,"filename":"p.mp4"}}"#
        let services = try await services(bodies: [body([stream])])
        let model = StreamPickerViewModel(request: request, services: services)
        await model.load()
        guard case .play(let plan)? = await model.playBest() else { Issue.record("expected a plan"); return }
        let candidate = try #require(plan.candidates.first)
        #expect(candidate.headers == ["Referer": "https://r.example.com"])
        #expect(candidate.subtitles.map(\.lang) == ["eng"])
        #expect(candidate.videoHash == "abc" && candidate.videoSize == 12345 && candidate.filename == "p.mp4")
        #expect(candidate.addonName == "addon0")
    }

    @Test func retryReloads() async throws {
        let services = try await services(bodies: [body([direct("x", "https://a.example.com/1.mp4")])])
        let model = StreamPickerViewModel(request: request, services: services)
        await model.load()
        await model.retry()
        #expect(model.listing.items.count == 1)
    }

    // MARK: always picking the best stream

    @Test func theAlwaysPickPreferenceDefaultsToOff() async throws {
        let services = try await services(bodies: [body([])])
        let model = StreamPickerViewModel(request: request, services: services)
        #expect(!model.autoPlaysBestStream)
        await model.loadAutoPlayPreference()
        #expect(!model.autoPlaysBestStream)
    }

    @Test func theAlwaysPickPreferenceIsSavedKeepingTheOtherSettings() async throws {
        let services = try await services(bodies: [body([])], settings: PlaybackSettings(preferredResolution: 720))
        let model = StreamPickerViewModel(request: request, services: services)
        await model.setAutoPlaysBestStream(true)
        #expect(model.autoPlaysBestStream)
        let saved = await services.settings.load()
        #expect(saved.autoPlayBestStream, "the choice is written to the saved settings")
        #expect(saved.preferredResolution == 720, "the other settings survive the save")
    }

    @Test func aNewPickerReadsTheSavedAlwaysPickPreference() async throws {
        let services = try await services(bodies: [body([])], settings: PlaybackSettings(preferredResolution: 720))
        let first = StreamPickerViewModel(request: request, services: services)
        await first.setAutoPlaysBestStream(true)
        let reopened = StreamPickerViewModel(request: request, services: services)
        await reopened.loadAutoPlayPreference()
        #expect(reopened.autoPlaysBestStream)
        await reopened.setAutoPlaysBestStream(false)
        let cleared = await services.settings.load()
        #expect(!cleared.autoPlayBestStream && cleared.preferredResolution == 720)
        let again = StreamPickerViewModel(request: request, services: services)
        await again.loadAutoPlayPreference()
        #expect(!again.autoPlaysBestStream, "switching it off persists too")
    }

    // MARK: another player

    private func url(_ text: String) -> URL { URL(string: text)! }

    private func query(_ link: URL) -> [URLQueryItem] {
        URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    private func value(_ name: String, in items: [URLQueryItem]) -> String? {
        items.first { $0.name == name }?.value
    }

    /// A picker that knows which player apps are installed. Routing depends on that, so it is set before the picker loads.
    private func picker(_ request: StreamRequest, _ services: AppServices, installed: Set<ExternalPlayer> = [.infuse]) -> StreamPickerViewModel {
        let model = StreamPickerViewModel(request: request, services: services)
        model.setInstalledPlayers(installed)
        return model
    }

    @Test func infuseTakesAnMKVWithTheResumePointAFileNameAndAStoredHandoff() async throws {
        let saved = WatchProgress(id: "movie/tt1", type: "movie", contentID: "tt1", title: "Test Movie", position: 1234.7, duration: 7200,
                                  isWatched: false, updatedAt: Date())
        let services = try await services(bodies: [body([direct("mkv", "https://a.example.com/Movie%20One.mkv", "2160p")])],
                                          settings: PlaybackSettings(playerPreference: .infuse), progress: [saved])
        let model = picker(movie, services)
        await model.load()
        let item = try #require(model.listing.items.first)
        guard case .openInPlayer(let player, let link)? = await model.choose(item) else { Issue.record("expected a hand-off"); return }
        #expect(player == .infuse)
        #expect(link.scheme == "infuse")
        let items = query(link)
        #expect(value("url", in: items) == "https://a.example.com/Movie%20One.mkv")
        #expect(value("position", in: items) == "1234", "resumes where the viewer stopped, rounded down")
        #expect(value("filename", in: items) == "Test-Movie-2010.mkv")
        let callback = try #require(value("x-success", in: items))
        let token = try #require(ExternalPlayerCallback.parse(url(callback))?.token)
        let stored = await services.handoffs.take(id: token)
        #expect(stored?.request == movie && stored?.player == .infuse, "the hand-off is remembered for the callback")
    }

    @Test func withBlusionAloneAnMKVIsUnsupportedAndOfferedToInfuse() async throws {
        let services = try await services(bodies: [body([direct("mkv", "https://a.example.com/1.mkv", "2160p")])],
                                          settings: PlaybackSettings(playerPreference: .builtIn))
        let model = picker(movie, services)
        await model.load()
        let item = try #require(model.listing.items.first)
        #expect(item.route == .unsupported(.matroska))
        #expect(model.alternativePlayers(for: item) == [.infuse])
        let choice = await model.choose(item)
        guard case .unsupported? = choice else { Issue.record("expected unsupported"); return }
    }

    @Test func aPlayerThatIsNotInstalledIsNeverRoutedToOrOffered() async throws {
        let services = try await services(bodies: [body([direct("mkv", "https://a.example.com/1.mkv", "2160p")])],
                                          settings: PlaybackSettings(playerPreference: .infuseWhenNeeded))
        let model = picker(movie, services, installed: [])
        await model.load()
        let item = try #require(model.listing.items.first)
        #expect(item.route == .unsupported(.matroska), "with no Infuse on the device, the MKV stays unsupported")
        #expect(model.alternativePlayers(for: item).isEmpty)
    }

    @Test func infuseWhenNeededHandsTheMKVOverOnlyWhenInfuseIsInstalled() async throws {
        let services = try await services(bodies: [body([direct("mkv", "https://a.example.com/1.mkv", "2160p")])],
                                          settings: PlaybackSettings(playerPreference: .infuseWhenNeeded))
        let without = picker(movie, services, installed: [])
        await without.load()
        #expect(without.listing.items.first?.route == .unsupported(.matroska))

        let with = picker(movie, services, installed: [.infuse])
        await with.load()
        let item = try #require(with.listing.items.first)
        #expect(item.route == .handoff(.infuse, url("https://a.example.com/1.mkv")))
        #expect(with.listing.best?.title == item.title, "a hand-off can be the best stream")
    }

    @Test func aStreamWithRequestHeadersIsNeverOfferedToInfuse() async throws {
        let guarded = #"{"name":"guarded","url":"https://a.example.com/1.mkv","behaviorHints":{"proxyHeaders":{"request":{"Referer":"https://r.example.com"}}}}"#
        let services = try await services(bodies: [body([guarded])], settings: PlaybackSettings(playerPreference: .infuse))
        let model = picker(movie, services)
        await model.load()
        let item = try #require(model.listing.items.first)
        #expect(item.route == .unsupported(.matroska), "Infuse can't send the headers, so the stream stays with Blusion")
        #expect(model.alternativePlayers(for: item).isEmpty)
        let handoff = await model.handoffChoice(for: item, player: .infuse)
        #expect(handoff == nil)
    }

    @Test func inInfuseModeAnMP4CanStillPlayInBlusion() async throws {
        let services = try await services(bodies: [body([direct("mp4", "https://a.example.com/1.mp4", "1080p")])],
                                          settings: PlaybackSettings(playerPreference: .infuse))
        let model = picker(movie, services)
        await model.load()
        let item = try #require(model.listing.items.first)
        #expect(item.route == .handoff(.infuse, url("https://a.example.com/1.mp4")))
        #expect(model.alternativePlayers(for: item).isEmpty, "the route already is Infuse")
        guard case .play(let plan)? = model.inAppChoice(for: item) else { Issue.record("expected an in-app plan"); return }
        #expect(plan.candidates.first?.route == .native(url("https://a.example.com/1.mp4")))
    }

    @Test func inInfuseModeAnMKVWithoutTheFallbackEngineHasNoInAppPlay() async throws {
        let services = try await services(bodies: [body([direct("mkv", "https://a.example.com/1.mkv")])],
                                          settings: PlaybackSettings(playerPreference: .infuse))
        let model = picker(movie, services)
        await model.load()
        let item = try #require(model.listing.items.first)
        #expect(model.inAppChoice(for: item) == nil, "Blusion can't play it, so there is nothing to fall back to")
    }

    @Test func playBestOpensTheBestStreamInInfuseWhenInfuseRanksFirst() async throws {
        let services = try await services(bodies: [body([direct("1080", "https://a.example.com/2.mp4", "1080p"),
                                                         direct("4K", "https://a.example.com/1.mkv", "2160p")])],
                                          settings: PlaybackSettings(playerPreference: .infuse))
        let model = picker(movie, services)
        await model.load()
        guard case .openInPlayer(let player, let link)? = await model.playBest() else { Issue.record("expected a hand-off"); return }
        #expect(player == .infuse)
        #expect(value("url", in: query(link)) == "https://a.example.com/1.mkv")
        #expect(value("filename", in: query(link)) == "Test-Movie-2010.mkv")
    }

    @Test func autoPickSkipsUncachedRemuxBeforeApplyingResolutionPreferenceAndRetries() async throws {
        let services = try await services(bodies: [body([
            direct("[TB download] REMUX", "https://a.example.com/wait.mp4", "2160p BluRay REMUX"),
            direct("[TB+] Ready", "https://a.example.com/ready.mp4", "1080p WEB-DL")
        ])], settings: PlaybackSettings(preferredResolution: 2160))
        let model = picker(movie, services)
        await model.load()
        guard case .play(let plan)? = await model.autoPickBest() else { Issue.record("expected ready playback"); return }
        #expect(plan.candidates.map(\.title) == ["[TB+] Ready"])
        #expect(model.bestToPlay?.title == "[TB+] Ready")
        #expect(model.recommendedStream?.title == "[TB+] Ready")
    }

    @Test(arguments: ["[TB download]", "[RD download]", "⏳ TB", "Uncached", "Not cached", "Cached: false"])
    func uncachedStreamsRequireManualSelection(_ marker: String) async throws {
        let services = try await services(bodies: [body([direct(marker, "https://a.example.com/wait.mp4", "2160p REMUX")])])
        let model = picker(movie, services)
        await model.load()
        let automatic = await model.autoPickBest()
        #expect(automatic == nil && model.bestToPlay == nil && model.recommendedStream == nil)
        #expect(model.autoPickMessage != nil)
        let item = try #require(model.listing.items.first)
        guard case .play? = await model.choose(item) else { Issue.record("manual selection must stay available"); return }
    }

    @Test func cachedStreamsLeadUnknownAvailabilityAndBingeNeverStartsUncached() async throws {
        let services = try await services(bodies: [body([
            direct("Unknown REMUX", "https://a.example.com/unknown.mp4", "2160p BluRay REMUX"),
            direct("[RD+] Ready", "https://a.example.com/ready.mp4", "1080p WEB-DL"),
            #"{"name":"[TB download] Next","url":"https://a.example.com/wait.mp4","behaviorHints":{"bingeGroup":"series"}}"#
        ])])
        let model = picker(movie, services)
        await model.load()
        #expect(model.recommendedStream?.title == "[RD+] Ready")
        let next = await model.bingeChoice(continuing: BingeContext(bingeGroup: "series"))
        #expect(next == nil, "show the picker instead of downloading an uncached next episode")
    }

    @Test func theRecommendedStreamIsTheOneAutoPickStarts() async throws {
        let services = try await services(bodies: [body([direct("1080", "https://a.example.com/2.mp4", "1080p"),
                                                         direct("4K", "https://a.example.com/1.mkv", "2160p")])],
                                          settings: PlaybackSettings(playerPreference: .infuse))
        let model = picker(movie, services)
        #expect(model.recommendedStream == nil, "no mark while the addons are still answering")
        await model.load()
        let recommended = try #require(model.recommendedStream)
        _ = await model.autoPickBest()
        #expect(model.autoPickedStream?.id == recommended.id, "the mark in the list is the stream Auto Pick starts")
    }

    @Test func remuxLeadsTheListBestMatchAndAutoPick() async throws {
        let remuxURL = "https://a.example.com/remux.mkv"
        let services = try await services(bodies: [
            body([direct("web", "https://a.example.com/web.mkv", "2160p WEB-DL HEVC Dolby Vision 10bit TrueHD Atmos 7.1 60 GB")]),
            body([direct("remux", remuxURL, "1080p BluRay REMUX AAC 2 GB")])
        ], settings: PlaybackSettings(playerPreference: .infuse))
        let model = picker(movie, services)
        await model.load()
        let first = try #require(model.addonSections.first?.streams.first)
        #expect(first.quality.isRemux)
        #expect(model.recommendedStream?.id == first.id)
        #expect(model.bestToPlay?.id == first.id)
        guard case .openInPlayer(_, let link)? = await model.autoPickBest() else {
            Issue.record("expected an Infuse hand-off"); return
        }
        #expect(model.autoPickedStream?.id == first.id)
        #expect(value("url", in: query(link)) == remuxURL)
    }

    @Test func autoPickKeepsBuiltInPlayerEvenWhenInfuseIsInstalled() async throws {
        let services = try await services(
            bodies: [body([direct("4K REMUX", "https://a.example.com/movie.mkv", "2160p BluRay REMUX")])],
            settings: PlaybackSettings(playerPreference: .builtIn), fallbackLinked: true
        )
        let model = picker(movie, services)
        await model.load()
        guard case .play(let plan)? = await model.autoPickBest() else {
            Issue.record("Auto Pick must use Blusion, not Infuse"); return
        }
        #expect(plan.candidates.first?.title == "4K REMUX")
        #expect(model.recommendedStream?.id == model.autoPickedStream?.id)
    }

    @Test func autoPickUsesFallbackEngineBeforeInfuseWhenPreferred() async throws {
        let services = try await services(
            bodies: [body([direct("MKV", "https://a.example.com/movie.mkv", "2160p")])],
            settings: PlaybackSettings(playerPreference: .infuseWhenNeeded), fallbackLinked: true
        )
        let model = picker(movie, services)
        await model.load()
        guard case .play? = await model.autoPickBest() else {
            Issue.record("Fallback-capable Blusion must handle the MKV"); return
        }
    }

    @Test func autoPickOnlyHandsOffWhenPolicyRequiresIt() async throws {
        let services = try await services(
            bodies: [body([direct("MKV", "https://a.example.com/movie.mkv", "2160p")])],
            settings: PlaybackSettings(playerPreference: .infuseWhenNeeded)
        )
        let model = picker(movie, services)
        await model.load()
        guard case .openInPlayer(let player, _)? = await model.autoPickBest() else {
            Issue.record("An unsupported MKV may use Infuse when fallback is selected"); return
        }
        #expect(player == .infuse)
    }

    @Test func aReleaseNameDoesNotLendItsDottedEndingAsTheExtension() async throws {
        // Real addons send release names as the file name, with no extension: the file's extension comes from the URL instead.
        let release = "Breaking.Bad.S01E01.Pilot.2160p.NF.WEB-DL.DD+5.1.H.265-playWEB"
        let stream = #"{"name":"R","url":"https://a.example.com/files/release.mkv","behaviorHints":{"filename":"\#(release)"}}"#
        let services = try await services(bodies: [body([stream])], settings: PlaybackSettings(playerPreference: .infuse))
        let model = picker(movie, services)
        await model.load()
        let item = try #require(model.listing.items.first)
        guard case .openInPlayer(_, let link)? = await model.choose(item) else { Issue.record("expected a hand-off"); return }
        #expect(value("filename", in: query(link)) == "Test-Movie-2010.mkv", "265-playWEB is not a video extension, so the URL's mkv is used")
    }

    @Test func aFilenameHintWithAVideoExtensionNamesTheFile() async throws {
        let stream = #"{"name":"R","url":"https://a.example.com/download?id=7","behaviorHints":{"filename":"Film.Release.2010.1080p.MP4"}}"#
        let services = try await services(bodies: [body([stream])], settings: PlaybackSettings(playerPreference: .infuse))
        let model = picker(movie, services)
        await model.load()
        let item = try #require(model.listing.items.first)
        guard case .openInPlayer(_, let link)? = await model.choose(item) else { Issue.record("expected a hand-off"); return }
        #expect(value("filename", in: query(link)) == "Test-Movie-2010.mp4")
    }

    @Test func aFileNameWithNoVideoExtensionAnywhereDefaultsToMP4() async throws {
        let stream = #"{"name":"R","url":"https://a.example.com/download/abc","behaviorHints":{"filename":"Release-playWEB"}}"#
        let services = try await services(bodies: [body([stream])], settings: PlaybackSettings(playerPreference: .infuse))
        let model = picker(movie, services)
        await model.load()
        let item = try #require(model.listing.items.first)
        guard case .openInPlayer(_, let link)? = await model.choose(item) else { Issue.record("expected a hand-off"); return }
        #expect(value("filename", in: query(link)) == "Test-Movie-2010.mp4")
    }

    @Test func anEpisodeIsNamedAfterItsSeries() async throws {
        let episode = StreamRequest(type: "series", id: "tt9:2:5", title: "Show · Pilot", season: 2, episode: 5, seriesName: "Show", year: "2008")
        let services = try await services(bodies: [body([direct("mkv", "https://a.example.com/e.mkv", "1080p")])],
                                          settings: PlaybackSettings(playerPreference: .infuse))
        let model = picker(episode, services)
        await model.load()
        let item = try #require(model.listing.items.first)
        guard case .openInPlayer(_, let link)? = await model.choose(item) else { Issue.record("expected a hand-off"); return }
        #expect(value("filename", in: query(link)) == "Show-S02-E05.mkv")
    }

    @Test func theSubtitleInTheUsersLanguageGoesWithTheHandOff() async throws {
        let stream = #"{"name":"S","url":"https://a.example.com/1.mkv","subtitles":[{"id":"fr","url":"https://a.example.com/fr.srt","lang":"fre"},{"id":"en","url":"https://a.example.com/en.srt","lang":"eng"}]}"#
        let services = try await services(bodies: [body([stream])], settings: PlaybackSettings(subtitleLanguage: "en", playerPreference: .infuse))
        let model = picker(movie, services)
        await model.load()
        let item = try #require(model.listing.items.first)
        guard case .openInPlayer(_, let link)? = await model.choose(item) else { Issue.record("expected a hand-off"); return }
        #expect(value("sub", in: query(link)) == "https://a.example.com/en.srt")
    }

    @Test func noSubtitleIsSentWhenTheSettingIsOff() async throws {
        let stream = #"{"name":"S","url":"https://a.example.com/1.mkv","subtitles":[{"id":"en","url":"https://a.example.com/en.srt","lang":"eng"}]}"#
        let services = try await services(bodies: [body([stream])], settings: PlaybackSettings(playerPreference: .infuse))
        let model = picker(movie, services)
        await model.load()
        let item = try #require(model.listing.items.first)
        let handoff = await model.handoffChoice(for: item, player: .infuse)
        guard case .openInPlayer(_, let link)? = handoff else { Issue.record("expected a hand-off"); return }
        #expect(value("sub", in: query(link)) == nil)
    }

    @Test func onlyDirectStreamsCanGoToAnotherPlayer() async throws {
        let services = try await services(bodies: [body([#"{"name":"YT","ytId":"abc123"}"#])], settings: PlaybackSettings(playerPreference: .infuse))
        let model = picker(movie, services)
        await model.load()
        let item = try #require(model.listing.items.first)
        #expect(model.alternativePlayers(for: item).isEmpty)
        let handoff = await model.handoffChoice(for: item, player: .infuse)
        #expect(handoff == nil)
    }
}
