import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

@Suite struct StreamListingTests {
    private let a = S.addon("Alpha")
    private let b = S.addon("Beta")
    private let c = S.addon("Gamma")

    private func listing(_ addons: [AddonSummary], config: PolicyConfiguration = .init(), preferences: RankingPreferences = .init()) -> StreamListing {
        StreamListing(asking: addons, config: config, preferences: preferences)
    }

    // MARK: incremental loading

    @Test func startsLoadingAndFillsInAsAddonsAnswer() {
        var l = listing([a, b])
        #expect(l.isLoading && l.isEmpty && l.best == nil)
        l.apply(S.response(b, [S.direct("Beta 720p", "https://b.example.com/x.mp4")]))
        #expect(l.pending.map(\.name) == ["Alpha"])
        #expect(l.items.map(\.title) == ["Beta 720p"], "the first answer is usable while Alpha is still pending")
        #expect(l.isLoading)
        l.apply(S.response(a, [S.direct("Alpha 1080p", "https://a.example.com/x.mp4")]))
        #expect(!l.isLoading)
        #expect(l.items.map(\.title) == ["Alpha 1080p", "Beta 720p"])
    }

    @Test func failuresAreRecordedPerAddonAndStopTheSpinner() {
        var l = listing([a, b])
        l.apply(S.failure(a, .timeout))
        l.apply(S.response(b, []))
        #expect(!l.isLoading)
        #expect(l.failures.map(\.addon.name) == ["Alpha"])
        #expect(l.failures.first?.error == .timeout)
        #expect(l.isEmpty)
    }

    @Test func groupsFollowAddonOrderWhateverTheArrivalOrder() {
        var l = listing([a, b, c])
        l.apply(S.response(c, [S.direct("g", "https://c.example.com/1.mp4")]))
        l.apply(S.response(a, [S.direct("a", "https://a.example.com/1.mp4")]))
        l.apply(S.response(b, [S.direct("b", "https://b.example.com/1.mp4")]))
        #expect(l.groups.map(\.addon.name) == ["Alpha", "Beta", "Gamma"])
    }

    @Test func answeringTwiceReplacesThatAddonsStreams() {
        var l = listing([a])
        l.apply(S.response(a, [S.direct("old", "https://a.example.com/old.mp4")]))
        l.apply(S.response(a, [S.direct("new", "https://a.example.com/new.mp4")]))
        #expect(l.items.map(\.title) == ["new"])
        l.apply(S.failure(a, .timeout))
        l.apply(S.failure(a, .timeout))
        #expect(l.failures.count == 1)
    }

    @Test func unlistedAddonsStillAppearAfterTheOnesThatWereAsked() {
        var l = listing([a])
        l.apply(S.response(b, [S.direct("b", "https://b.example.com/1.mp4")]))
        #expect(l.groups.map(\.addon.name) == ["Beta"])
    }

    // MARK: ranking and de-duplication

    @Test func nativeBeatsFallbackBeatsUnsupportedRegardlessOfResolution() {
        var l = listing([a], config: PolicyConfiguration(fallbackEngineAvailable: true))
        l.apply(S.response(a, [
            S.direct("4K mkv", "https://a.example.com/1.mkv", description: "2160p"),
            S.direct("720p mp4", "https://a.example.com/2.mp4", description: "720p"),
            S.external("page"),
            S.direct("1080p mp4", "https://a.example.com/3.mp4", description: "1080p"),
        ]))
        #expect(l.items.map(\.title) == ["1080p mp4", "720p mp4", "4K mkv", "page"])
        #expect(l.best?.title == "1080p mp4")
        #expect(l.playable.map(\.title) == ["1080p mp4", "720p mp4", "4K mkv"], "auto-advance candidates: native, then fallback")
    }

    @Test func theSameFileFromTwoAddonsAppearsOnceWithBothCredited() {
        var l = listing([a, b])
        l.apply(S.response(b, [S.direct("B copy", "HTTPS://CDN.Example.com/x.mp4#frag")]))
        l.apply(S.response(a, [S.direct("A copy", "https://cdn.example.com/x.mp4")]))
        #expect(l.items.count == 1)
        #expect(l.items[0].addon.name == "Alpha", "the earlier addon in the user's order wins the tie")
        #expect(l.items[0].alsoProvidedBy.map(\.name) == ["Beta"])
    }

    @Test func torrentsDeduplicateByHashAndFileIndex() {
        let config = PolicyConfiguration(streamingServerURL: URL(string: "http://192.168.1.2:11470"))
        var l = listing([a, b], config: config)
        l.apply(S.response(a, [S.torrent("t0", index: 0), S.torrent("t1", index: 1)]))
        l.apply(S.response(b, [S.torrent("t0 again", index: 0)]))
        #expect(l.items.count == 2)
        #expect(l.items.first { $0.title == "t0" }?.alsoProvidedBy.map(\.name) == ["Beta"])
    }

    @Test func preferencesReRankTheListing() {
        var l = listing([a])
        l.apply(S.response(a, [S.direct("2160", "https://a.example.com/1.mp4", description: "2160p"),
                               S.direct("1080", "https://a.example.com/2.mp4", description: "1080p"),
                               S.direct("720", "https://a.example.com/3.mp4", description: "720p")]))
        #expect(l.items.map(\.title) == ["2160", "1080", "720"])
        l.update(preferences: RankingPreferences(preferredResolution: 1080))
        #expect(l.items.map(\.title) == ["1080", "720", "2160"])
        #expect(l.preferences.preferredResolution == 1080)
    }

    // MARK: hidden streams

    @Test func hiddenStreamsAreCountedNotListed() {
        var l = listing([a])
        l.apply(S.response(a, [S.torrent("t1"), S.torrent("t2", index: 1), S.archive("n"), S.direct("ok", "https://a.example.com/1.mp4")]))
        #expect(l.items.map(\.title) == ["ok"])
        #expect(l.hidden.map(\.reason) == [.needsStreamingServer, .usenetOrArchive])
        #expect(l.hidden.first?.count == 2)
        #expect(l.hidden.first?.text.hasPrefix("2 streams hidden") == true)
        #expect(l.hidden.last?.text.hasPrefix("1 stream hidden") == true)
    }

    @Test func configuringAStreamingServerRevealsTorrents() {
        var l = listing([a])
        l.apply(S.response(a, [S.torrent("t")]))
        #expect(l.items.isEmpty && l.hidden.count == 1)
        l.update(config: PolicyConfiguration(streamingServerURL: URL(string: "http://192.168.1.2:11470")))
        #expect(l.items.map(\.title) == ["t"] && l.hidden.isEmpty)
        #expect(l.best?.route.playableURL?.host == "192.168.1.2")
    }

    // MARK: sniffing

    @Test func onlyAmbiguousURLsAreSniffedAndOnlyOnce() {
        var l = listing([a])
        l.apply(S.response(a, [
            S.direct("known", "https://a.example.com/x.mp4"),
            S.direct("blob", "https://a.example.com/blob", proxy: ["Referer": "https://r.example.com"]),
            S.direct("blob again", "https://a.example.com/blob"),
            S.direct("hinted", "https://a.example.com/dl/1", filename: "x.mkv"),
            S.external("page"),
        ]))
        #expect(l.sniffTargets.map(\.url.absoluteString) == ["https://a.example.com/blob"])
        #expect(l.sniffTargets.first?.headers == ["Referer": "https://r.example.com"], "sniffing carries the stream's request headers")
        let key = l.sniffTargets[0].key
        l.setContainer(nil, forKey: key)
        #expect(l.sniffTargets.isEmpty, "a failed probe is not retried")
    }

    @Test func aSniffedContainerReRoutesAndReRanks() {
        var l = listing([a])
        l.apply(S.response(a, [S.direct("blob", "https://a.example.com/blob", description: "1080p"),
                               S.direct("plain", "https://a.example.com/plain.mp4", description: "720p")]))
        #expect(l.items.map(\.title) == ["blob", "plain"], "optimistically native, and higher resolution")
        l.setContainer(.matroska, forKey: l.sniffTargets[0].key)
        #expect(l.items.map(\.title) == ["plain", "blob"])
        #expect(l.items.last?.route == .unsupported(.matroska))
        #expect(l.items.last?.container == .matroska)
        #expect(l.best?.title == "plain")
    }

    // MARK: hand-offs

    @Test func bestIsAHandOffWhenItRanksFirst() {
        var l = listing([a], config: PolicyConfiguration(playerPreference: .infuse, installedPlayers: [.infuse]))
        l.apply(S.response(a, [S.direct("1080 mp4", "https://a.example.com/1.mp4", description: "1080p"),
                               S.direct("4K mkv", "https://a.example.com/2.mkv", description: "2160p")]))
        #expect(l.items.map(\.title) == ["4K mkv", "1080 mp4"], "with Infuse both are hand-offs, so quality decides")
        #expect(l.best?.title == "4K mkv")
        #expect(l.best?.route.handoffTarget?.player == .infuse)
        #expect(l.playable.isEmpty, "nothing is left for Blusion's own player")
    }

    @Test func infuseWhenNeededLeavesPlayableStreamsForTheAutoAdvanceList() {
        var l = listing([a], config: PolicyConfiguration(playerPreference: .infuseWhenNeeded, installedPlayers: [.infuse]))
        l.apply(S.response(a, [S.direct("1080 mp4", "https://a.example.com/1.mp4", description: "1080p"),
                               S.direct("4K mkv", "https://a.example.com/2.mkv", description: "2160p")]))
        #expect(l.best?.title == "4K mkv", "the hand-off ranks first")
        #expect(l.playable.map(\.title) == ["1080 mp4"], "auto-advance only uses what Blusion plays itself")
    }

    @Test func withoutAnInstalledPlayerTheMKVIsUnsupportedAndNotWatchable() {
        var l = listing([a], config: PolicyConfiguration(playerPreference: .infuseWhenNeeded))
        l.apply(S.response(a, [S.direct("4K mkv", "https://a.example.com/2.mkv", description: "2160p")]))
        #expect(l.items.first?.route == .unsupported(.matroska))
        #expect(l.best == nil)
    }

    @Test func bestIsTheNativeStreamWhenItRanksFirst() {
        var l = listing([a], config: PolicyConfiguration(playerPreference: .infuseWhenNeeded, installedPlayers: [.infuse]))
        l.apply(S.response(a, [S.direct("1080 mp4", "https://a.example.com/1.mp4", description: "1080p"),
                               S.direct("720 mkv", "https://a.example.com/2.mkv", description: "720p")]))
        #expect(l.best?.title == "1080 mp4")
        #expect(l.best?.route.isPlayable == true)
    }

    @Test func bestIsNilWhenOnlyExternalOrUnsupportedStreamsRemain() {
        var l = listing([a])
        l.apply(S.response(a, [S.direct("mkv", "https://a.example.com/1.mkv", description: "2160p"), S.external("page")]))
        #expect(l.best == nil, "unsupported and external streams are not watchable in Blusion's default setup")
    }

    @Test func bingeContextComesFromTheStream() {
        var l = listing([a])
        l.apply(S.response(a, [S.direct("x", "https://a.example.com/1.mp4", bingeGroup: "grp-1080")]))
        #expect(l.items[0].bingeContext == BingeContext(bingeGroup: "grp-1080", addonID: a.id))
    }
}
