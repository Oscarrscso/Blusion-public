import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

@Suite struct PlaybackPolicyTests {
    private let none = PolicyConfiguration(fallbackEngineAvailable: false)
    private let withFallback = PolicyConfiguration(fallbackEngineAvailable: true)

    private func route(_ stream: AddonStream, container: MediaContainer? = nil, _ config: PolicyConfiguration) -> PlaybackRoute {
        PlaybackPolicy.route(for: stream, container: container, quality: StreamQuality.parse(stream), config: config)
    }

    private func url(_ text: String) -> URL { URL(string: text)! }

    // MARK: direct URLs

    @Test func mp4MovM4vAndHLSPlayNatively() {
        for file in ["a.mp4", "a.m4v", "a.mov", "a.m3u8", "A.MP4"] {
            let stream = S.direct("x", "https://cdn.example.com/\(file)")
            #expect(route(stream, none) == .native(url("https://cdn.example.com/\(file)")), "\(file)")
        }
    }

    @Test func mkvAviAndFriendsNeedTheFallbackEngine() {
        for (file, container) in [("a.mkv", MediaContainer.matroska), ("a.avi", .avi), ("a.webm", .webm), ("a.ts", .mpegTS), ("a.flv", .flv)] {
            let stream = S.direct("x", "https://cdn.example.com/\(file)")
            #expect(route(stream, withFallback) == .fallback(url("https://cdn.example.com/\(file)"), .container(container)), "\(file)")
            #expect(route(stream, none) == .unsupported(container), "\(file) before the fallback engine exists")
        }
    }

    @Test func audioAVPlayerCannotDecodeRoutesToTheFallbackEngine() {
        let stream = S.direct("1080p DTS-HD MA", "https://cdn.example.com/a.mp4")
        #expect(route(stream, withFallback) == .fallback(url("https://cdn.example.com/a.mp4"), .audioCodec))
        #expect(route(stream, none) == .unsupported(.mp4))
        let mixed = S.direct("1080p DTS AAC", "https://cdn.example.com/a.mp4")
        #expect(route(mixed, none) == .native(url("https://cdn.example.com/a.mp4")), "a decodable track exists")
        let hls = S.direct("TrueHD", "https://cdn.example.com/a.m3u8")
        #expect(route(hls, withFallback) == .fallback(url("https://cdn.example.com/a.m3u8"), .audioCodec))
    }

    @Test func av1GoesToTheFallbackEngineOnlyOnChipsWithoutHardwareAV1() {
        // AVPlayer keeps AV1 where the chip decodes it (PiP and AirPlay stay); elsewhere the engine plays it.
        let hardware = PolicyConfiguration(fallbackEngineAvailable: true, decodesAV1InHardware: true)
        let mp4 = S.direct("1080p AV1", "https://cdn.example.com/a.mp4")
        #expect(route(mp4, withFallback) == .fallback(url("https://cdn.example.com/a.mp4"), .videoCodec))
        #expect(route(mp4, hardware) == .native(url("https://cdn.example.com/a.mp4")))
        #expect(route(mp4, none) == .native(url("https://cdn.example.com/a.mp4")), "without the engine AVPlayer still gets the try")
        let h264 = S.direct("1080p x264", "https://cdn.example.com/a.mp4")
        #expect(route(h264, withFallback) == .native(url("https://cdn.example.com/a.mp4")))
        let mkv = S.direct("1080p AV1", "https://cdn.example.com/a.mkv")
        #expect(route(mkv, hardware) == .fallback(url("https://cdn.example.com/a.mkv"), .container(.matroska)), "the container says more")
        let unnamed = S.direct("AV1", "https://cdn.example.com/blob")
        #expect(route(unnamed, withFallback) == .fallback(url("https://cdn.example.com/blob"), .videoCodec))
        #expect(route(unnamed, hardware) == .native(url("https://cdn.example.com/blob")))
        #expect(StreamQuality.parse(from: ["1080p AV1"]).videoNeedsFallbackEngine(decodesAV1InHardware: false))
        #expect(!StreamQuality.parse(from: ["1080p AV1"]).videoNeedsFallbackEngine(decodesAV1InHardware: true))
        #expect(!StreamQuality.parse(from: ["1080p HEVC"]).videoNeedsFallbackEngine(decodesAV1InHardware: false))
    }

    @Test func notWebReadyAloneDoesNotSendNativeContainersToTheFallbackEngine() {
        // ADR-003: upstream's flag means "not https or not MP4" for a browser player, and proxyHeaders requires it.
        let http = S.direct("x", "http://cdn.example.com/a.mp4", notWebReady: true)
        #expect(route(http, none) == .native(url("http://cdn.example.com/a.mp4")))
        let proxied = S.direct("x", "https://cdn.example.com/a.m3u8", notWebReady: true, proxy: ["Referer": "https://example.com"])
        #expect(route(proxied, none) == .native(url("https://cdn.example.com/a.m3u8")))
    }

    @Test func unknownFormatsGoByHintsThenOptimism() {
        let blob = S.direct("x", "https://cdn.example.com/blob")
        #expect(route(blob, none) == .native(url("https://cdn.example.com/blob")), "no hint: try AVPlayer, the coordinator advances on failure")
        let flagged = S.direct("x", "https://cdn.example.com/blob", notWebReady: true)
        #expect(route(flagged, withFallback) == .fallback(url("https://cdn.example.com/blob"), .unknownFormat))
        #expect(route(flagged, none) == .unsupported(nil))
        let dts = S.direct("DTS", "https://cdn.example.com/blob")
        #expect(route(dts, withFallback) == .fallback(url("https://cdn.example.com/blob"), .audioCodec))
    }

    @Test func aSniffedContainerOverridesTheExtension() {
        let lying = S.direct("x", "https://cdn.example.com/a.mp4")
        #expect(route(lying, container: .matroska, withFallback) == .fallback(url("https://cdn.example.com/a.mp4"), .container(.matroska)))
        let blob = S.direct("x", "https://cdn.example.com/blob")
        #expect(route(blob, container: .hls, none) == .native(url("https://cdn.example.com/blob")))
        #expect(route(blob, container: .avi, none) == .unsupported(.avi))
    }

    @Test func filenameHintDecidesWhenTheURLHasNoExtension() {
        let stream = S.direct("x", "https://cdn.example.com/dl/123", filename: "Movie.mkv")
        #expect(route(stream, none) == .unsupported(.matroska))
    }

    // MARK: other sources

    @Test func externalAndYouTubeOpenOutsideTheApp() {
        #expect(route(S.external("x", "https://example.com/watch/1"), none) == .external(url("https://example.com/watch/1")))
        #expect(route(S.youtube("x", "abc_DEF-123"), none) == .external(url("https://www.youtube.com/watch?v=abc_DEF-123")))
    }

    @Test func usenetAndArchiveFormsAreHidden() {
        #expect(route(S.archive("x"), withFallback) == .hidden(.usenetOrArchive))
    }

    @Test func torrentsAreHiddenWithoutAStreamingServer() {
        #expect(route(S.torrent("x"), withFallback) == .hidden(.needsStreamingServer))
        let badHash = PolicyConfiguration(streamingServerURL: url("http://192.168.1.2:11470"))
        #expect(route(S.torrent("x", hash: "not-a-hash"), badHash) == .hidden(.needsStreamingServer))
    }

    @Test func torrentsPlayThroughAConfiguredStreamingServer() {
        let config = PolicyConfiguration(fallbackEngineAvailable: false, streamingServerURL: url("http://192.168.1.2:11470/"))
        #expect(route(S.torrent("x", hash: "0123456789ABCDEF0123456789ABCDEF01234567", index: 3), config)
                == .native(url("http://192.168.1.2:11470/0123456789abcdef0123456789abcdef01234567/3")))
        #expect(route(S.torrent("x", index: nil), config).playableURL?.lastPathComponent == "-1")
        let audio = AddonStream(name: "DTS", source: .torrent(infoHash: "0123456789abcdef0123456789abcdef01234567", fileIndex: 0, sources: []))
        #expect(route(audio, PolicyConfiguration(fallbackEngineAvailable: true, streamingServerURL: url("http://s:1"))).playableURL != nil)
    }

    @Test func streamingServerRouteValidatesItsInputs() {
        let server = url("https://nas.example.com:11470")
        let hex = "0123456789abcdef0123456789abcdef01234567"
        #expect(StreamingServerRoute.url(server: server, infoHash: hex, fileIndex: 0)?.absoluteString == "https://nas.example.com:11470/\(hex)/0")
        #expect(StreamingServerRoute.url(server: url("http://nas.example.com:11470///"), infoHash: hex.uppercased(), fileIndex: 12)?.absoluteString
                == "http://nas.example.com:11470/\(hex)/12")
        let base32 = String(repeating: "abcdefg234", count: 3) + "ab"
        #expect(StreamingServerRoute.url(server: server, infoHash: base32, fileIndex: nil)?.lastPathComponent == "-1")
        #expect(StreamingServerRoute.url(server: server, infoHash: "short", fileIndex: 0) == nil)
        #expect(StreamingServerRoute.url(server: server, infoHash: String(repeating: "z", count: 40), fileIndex: 0) == nil)
        #expect(StreamingServerRoute.url(server: url("ftp://nas.example.com"), infoHash: hex, fileIndex: 0) == nil)
        #expect(StreamingServerRoute.url(server: url("file:///tmp"), infoHash: hex, fileIndex: 0) == nil)
    }

    // MARK: route helpers

    @Test func routeClassesOrderNativeFirstAndHiddenLast() {
        let u = url("https://e.com/a.mp4")
        let routes: [PlaybackRoute] = [.hidden(.usenetOrArchive), .external(u), .unsupported(nil), .fallback(u, .audioCodec), .native(u)]
        #expect(routes.sorted { $0.sortClass < $1.sortClass } == routes.reversed(), "native, fallback, unsupported, external, hidden")
        #expect(PlaybackRoute.handoff(.infuse, u).sortClass == PlaybackRoute.native(u).sortClass)
        #expect(PlaybackRoute.native(u).isPlayable && PlaybackRoute.fallback(u, .audioCodec).isPlayable)
        #expect(!PlaybackRoute.external(u).isPlayable && !PlaybackRoute.unsupported(nil).isPlayable)
        #expect(PlaybackRoute.hidden(.needsStreamingServer).isHidden && !PlaybackRoute.native(u).isHidden)
        #expect(HiddenReason.needsStreamingServer.hint.contains("streaming server"))
    }

    // MARK: player preference

    /// Infuse counts as installed unless a test says otherwise: hand-offs need it.
    private func routed(_ stream: AddonStream, as preference: PlayerPreference, fallback: Bool = false, server: URL? = nil,
                        installed: Set<ExternalPlayer> = [.infuse]) -> PlaybackRoute {
        PlaybackPolicy.route(for: stream, container: nil, quality: StreamQuality.parse(stream),
                             config: PolicyConfiguration(fallbackEngineAvailable: fallback, streamingServerURL: server, playerPreference: preference,
                                                         installedPlayers: installed))
    }

    @Test func aPreferenceForAPlayerThatIsNotInstalledChangesNothing() {
        let mkv = S.direct("x", "https://cdn.example.com/a.mkv")
        let mp4 = S.direct("x", "https://cdn.example.com/a.mp4")
        #expect(routed(mkv, as: .infuseWhenNeeded, installed: []) == .unsupported(.matroska), "no Infuse, so nothing to hand off to")
        #expect(routed(mkv, as: .infuse, installed: []) == .unsupported(.matroska))
        #expect(routed(mp4, as: .infuse, installed: []) == .native(url("https://cdn.example.com/a.mp4")))
        #expect(routed(mkv, as: .infuseWhenNeeded, installed: [.infuse]) == .handoff(.infuse, url("https://cdn.example.com/a.mkv")))
        #expect(PolicyConfiguration().installedPlayers.isEmpty, "nothing is assumed installed")
    }

    @Test func builtInIsTheDefaultAndChangesNothing() {
        let mp4 = S.direct("x", "https://cdn.example.com/a.mp4")
        let mkv = S.direct("x", "https://cdn.example.com/a.mkv")
        #expect(routed(mp4, as: .builtIn) == .native(url("https://cdn.example.com/a.mp4")))
        #expect(routed(mkv, as: .builtIn) == .unsupported(.matroska))
        #expect(routed(mkv, as: .builtIn, fallback: true) == .fallback(url("https://cdn.example.com/a.mkv"), .container(.matroska)))
        #expect(PolicyConfiguration().playerPreference == .builtIn)
    }

    @Test func infuseTakesEveryStreamItCanPlay() {
        let mp4 = S.direct("x", "https://cdn.example.com/a.mp4")
        let mkv = S.direct("x", "https://cdn.example.com/a.mkv")
        #expect(routed(mp4, as: .infuse) == .handoff(.infuse, url("https://cdn.example.com/a.mp4")), "an MP4 AVPlayer could play still goes to Infuse")
        #expect(routed(mkv, as: .infuse) == .handoff(.infuse, url("https://cdn.example.com/a.mkv")))
        #expect(routed(mkv, as: .infuse, fallback: true) == .handoff(.infuse, url("https://cdn.example.com/a.mkv")), "Infuse comes before the fallback engine")
    }

    @Test func infuseKeepsStreamsWithRequestHeadersInBlusion() {
        let proxied = S.direct("x", "https://cdn.example.com/a.mkv", proxy: ["Referer": "https://example.com"])
        #expect(routed(proxied, as: .infuse) == .unsupported(.matroska))
        #expect(routed(proxied, as: .infuse, fallback: true) == .fallback(url("https://cdn.example.com/a.mkv"), .container(.matroska)))
    }

    @Test func infuseWhenNeededOnlyTakesWhatBlusionCannotPlay() {
        let mp4 = S.direct("x", "https://cdn.example.com/a.mp4")
        let mkv = S.direct("x", "https://cdn.example.com/a.mkv")
        let dts = S.direct("1080p DTS", "https://cdn.example.com/a.mp4")
        #expect(routed(mp4, as: .infuseWhenNeeded) == .native(url("https://cdn.example.com/a.mp4")))
        #expect(routed(mkv, as: .infuseWhenNeeded) == .handoff(.infuse, url("https://cdn.example.com/a.mkv")))
        #expect(routed(dts, as: .infuseWhenNeeded) == .handoff(.infuse, url("https://cdn.example.com/a.mp4")), "DTS audio that AVPlayer can't decode")
        #expect(routed(mkv, as: .infuseWhenNeeded, fallback: true) == .fallback(url("https://cdn.example.com/a.mkv"), .container(.matroska)),
                "the fallback engine plays it, so Infuse is not needed")
        let proxied = S.direct("x", "https://cdn.example.com/a.mkv", proxy: ["Referer": "https://example.com"])
        #expect(routed(proxied, as: .infuseWhenNeeded) == .unsupported(.matroska))
    }

    @Test func torrentsReachInfuseOnlyThroughAStreamingServer() {
        let torrent = S.torrent("t", hash: "0123456789abcdef0123456789abcdef01234567", index: 3)
        let server = url("http://192.168.1.2:11470")
        let playable = url("http://192.168.1.2:11470/0123456789abcdef0123456789abcdef01234567/3")
        #expect(routed(torrent, as: .infuse) == .hidden(.needsStreamingServer))
        #expect(routed(torrent, as: .infuse, server: server) == .handoff(.infuse, playable))
        #expect(routed(torrent, as: .infuseWhenNeeded, server: server) == .native(playable), "the server's file is an unknown format, which AVPlayer tries first")
        #expect(routed(torrent, as: .builtIn, server: server) == .native(playable))
    }

    @Test func externalAndYouTubeStreamsNeverChange() {
        for preference in PlayerPreference.allCases {
            #expect(routed(S.youtube("x", "abc123"), as: preference) == .external(url("https://www.youtube.com/watch?v=abc123")), "\(preference)")
            #expect(routed(S.external("x", "https://example.com/w"), as: preference) == .external(url("https://example.com/w")), "\(preference)")
            #expect(routed(S.archive("x"), as: preference) == .hidden(.usenetOrArchive), "\(preference)")
        }
    }

    @Test func aHandoffIsWatchableButNotPlayableInBlusion() {
        let handoff = PlaybackRoute.handoff(.infuse, url("https://cdn.example.com/a.mkv"))
        #expect(handoff.isWatchable && !handoff.isPlayable && handoff.playableURL == nil)
        #expect(handoff.handoffTarget?.player == .infuse && handoff.handoffTarget?.url == url("https://cdn.example.com/a.mkv"))
        #expect(PlaybackRoute.native(url("https://e.com/a.mp4")).handoffTarget == nil)
        #expect(handoff.sortClass == PlaybackRoute.native(url("https://e.com/a.mp4")).sortClass, "quality decides between a hand-off and a native stream")
        #expect(!PlaybackRoute.external(url("https://e.com/w")).isWatchable && !PlaybackRoute.unsupported(.avi).isWatchable)
        #expect(PlaybackRoute.fallback(url("https://e.com/a.mkv"), .audioCodec).isWatchable)
    }

    @Test func playbackURLIsTheStreamItselfWhenBlusionCanReachIt() {
        let direct = S.direct("x", "https://cdn.example.com/a.mkv")
        #expect(PlaybackPolicy.playbackURL(for: direct, config: PolicyConfiguration()) == url("https://cdn.example.com/a.mkv"))
        #expect(PlaybackPolicy.playbackURL(for: S.youtube("x"), config: PolicyConfiguration()) == nil)
        #expect(PlaybackPolicy.playbackURL(for: S.external("x"), config: PolicyConfiguration()) == nil)
        #expect(PlaybackPolicy.playbackURL(for: S.torrent("x"), config: PolicyConfiguration()) == nil, "no streaming server")
    }
}
