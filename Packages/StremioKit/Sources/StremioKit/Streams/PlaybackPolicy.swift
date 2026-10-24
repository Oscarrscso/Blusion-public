import Foundation

public struct PolicyConfiguration: Sendable, Equatable {
    /// True once a fallback engine (M6) is linked and enabled.
    public var fallbackEngineAvailable: Bool
    /// A second fallback engine is linked and in use, so a stream the first one cannot start is tried once in the full-featured engine
    /// (`FallbackReason.fullFeaturedEngine`).
    public var backupEngineAvailable: Bool
    /// A user-supplied Stremio-compatible streaming server. Without one, `infoHash` streams are hidden (ADR-004).
    public var streamingServerURL: URL?
    /// Whether streams go to Blusion's own player or are handed to another player app.
    public var playerPreference: PlayerPreference
    /// The player apps installed on this device. Streams are only handed to one of these: the app itself can't be asked from here.
    public var installedPlayers: Set<ExternalPlayer>
    /// This device decodes AV1 in hardware, so AVPlayer can play AV1 (A17 Pro, M3 and later). Otherwise AV1 goes to the fallback engine.
    public var decodesAV1InHardware: Bool

    public init(fallbackEngineAvailable: Bool = false, backupEngineAvailable: Bool = false, streamingServerURL: URL? = nil,
                playerPreference: PlayerPreference = .builtIn, installedPlayers: Set<ExternalPlayer> = [], decodesAV1InHardware: Bool = false) {
        self.fallbackEngineAvailable = fallbackEngineAvailable
        self.backupEngineAvailable = backupEngineAvailable
        self.streamingServerURL = streamingServerURL
        self.playerPreference = playerPreference
        self.installedPlayers = installedPlayers
        self.decodesAV1InHardware = decodesAV1InHardware
    }
}

public enum FallbackReason: Sendable, Equatable {
    case container(MediaContainer)
    case audioCodec
    case videoCodec
    case unknownFormat
    /// The full-featured fallback engine (mpv) specifically: for full subtitle styling, or a second try after the first fallback engine
    /// could not start the stream.
    case fullFeaturedEngine
}

public enum HiddenReason: String, Sendable, Equatable, Hashable {
    case needsStreamingServer
    case usenetOrArchive

    public var hint: String {
        switch self {
        case .needsStreamingServer: return "needs a streaming server (Settings) or an addon that returns direct links"
        case .usenetOrArchive: return "uses a download format Blusion doesn't support"
        }
    }
}

public enum PlaybackRoute: Sendable, Equatable {
    /// AVPlayer.
    case native(URL)
    /// The fallback engine (MKV, DTS, …).
    case fallback(URL, FallbackReason)
    /// Plays in another app the user chose (Infuse). The URL is the stream itself.
    case handoff(ExternalPlayer, URL)
    /// Opened outside the app (YouTube, external links).
    case external(URL)
    /// Playable in principle, but no engine for it is available: shown as "unsupported format", with the next stream offered.
    case unsupported(MediaContainer?)
    /// Not shown at all (a hint is shown instead).
    case hidden(HiddenReason)

    /// The URL Blusion plays itself. nil for a hand-off: another app plays that one (see `handoffTarget`).
    public var playableURL: URL? {
        switch self {
        case .native(let url), .fallback(let url, _): return url
        default: return nil
        }
    }

    /// The app and the stream of a hand-off.
    public var handoffTarget: (player: ExternalPlayer, url: URL)? {
        if case .handoff(let player, let url) = self { return (player, url) }
        return nil
    }

    /// Blusion or another app the user chose can play it: the streams the picker offers as "play".
    public var isWatchable: Bool {
        switch self {
        case .native, .fallback, .handoff: return true
        case .external, .unsupported, .hidden: return false
        }
    }

    /// Blusion's own player can play it. Auto-advance and binge selection only use in-app playable streams.
    public var isPlayable: Bool { playableURL != nil }
    public var isHidden: Bool {
        if case .hidden = self { return true }
        return false
    }

    /// Lower sorts first: native and hand-offs (quality decides between them), fallback, unsupported, external, hidden. Links to web pages
    /// (aggregators' summaries, for instance) sort below the streams the user can actually play.
    public var sortClass: Int {
        switch self {
        case .native, .handoff: return 0
        case .fallback: return 1
        case .unsupported: return 2
        case .external: return 3
        case .hidden: return 4
        }
    }
}

/// PLAN §4 stream handling policy, with the `notWebReady` refinement from ADR-003.
public enum PlaybackPolicy {
    public static func route(for stream: AddonStream, container: MediaContainer?, quality: StreamQuality, config: PolicyConfiguration) -> PlaybackRoute {
        switch stream.source {
        case .direct(let url):
            return directRoute(url, stream: stream, container: container, quality: quality, config: config)
        case .torrent:
            guard let url = playbackURL(for: stream, config: config) else { return .hidden(.needsStreamingServer) }
            return directRoute(url, stream: stream, container: container, quality: quality, config: config)
        case .youtube(let id):
            guard let url = URL(string: "https://www.youtube.com/watch?v=\(id)") else { return .hidden(.usenetOrArchive) }
            return .external(url)
        case .external(let url):
            return .external(url)
        case .archive:
            return .hidden(.usenetOrArchive)
        }
    }

    /// The URL a stream plays from, when Blusion can hand it on: a direct link, or a torrent file on the configured streaming server.
    /// nil for YouTube, external pages, archives and torrents without a server.
    public static func playbackURL(for stream: AddonStream, config: PolicyConfiguration) -> URL? {
        switch stream.source {
        case .direct(let url):
            return url
        case .torrent(let hash, let index, _):
            guard let server = config.streamingServerURL else { return nil }
            return StreamingServerRoute.url(server: server, infoHash: hash, fileIndex: index)
        case .youtube, .external, .archive:
            return nil
        }
    }

    /// Blusion's own route comes first. The preference may then hand the stream to Infuse, when Infuse is installed. Infuse fetches the
    /// stream itself and cannot send request headers, so a stream that needs them stays in Blusion.
    private static func directRoute(_ url: URL, stream: AddonStream, container sniffed: MediaContainer?, quality: StreamQuality,
                                    config: PolicyConfiguration) -> PlaybackRoute {
        let inApp = inAppRoute(url, stream: stream, container: sniffed, quality: quality, config: config)
        let wantsHandoff: Bool
        switch config.playerPreference {
        case .builtIn:
            wantsHandoff = false
        case .infuse:
            wantsHandoff = true
        case .infuseWhenNeeded:
            if case .unsupported = inApp { wantsHandoff = true } else { wantsHandoff = false }
        }
        let headers = stream.behaviorHints.proxyHeaders?.request ?? [:]
        guard wantsHandoff, let player = config.playerPreference.externalPlayer, config.installedPlayers.contains(player),
              player.canPlay(streamURL: url, headers: headers) else {
            return inApp
        }
        return .handoff(player, url)
    }

    private static func inAppRoute(_ url: URL, stream: AddonStream, container sniffed: MediaContainer?, quality: StreamQuality,
                                   config: PolicyConfiguration) -> PlaybackRoute {
        let known = sniffed ?? ContainerSniffer.container(url: url, filename: stream.behaviorHints.filename)
        if quality.videoIsUndecodable { return .unsupported(known) }
        if let known {
            guard known.isNativelyPlayable else { return fallback(url, .container(known), known: known, config: config) }
            if quality.audioNeedsFallbackEngine { return fallback(url, .audioCodec, known: known, config: config) }
            // Without the fallback engine AVPlayer still gets the try, as it did before.
            if videoNeedsEngine(quality, config) { return .fallback(url, .videoCodec) }
            return .native(url)
        }
        // Nothing says what this is. Audio or video we can't decode, or `notWebReady` (a hint, not a verdict: ADR-003) tips it to the fallback
        // engine; otherwise try AVPlayer. If AVPlayer cannot open it, the coordinator retries the same stream in the fallback engine.
        if quality.audioNeedsFallbackEngine { return fallback(url, .audioCodec, known: nil, config: config) }
        if videoNeedsEngine(quality, config) { return .fallback(url, .videoCodec) }
        if stream.behaviorHints.notWebReady { return fallback(url, .unknownFormat, known: nil, config: config) }
        return .native(url)
    }

    /// The video AVPlayer cannot decode on this device, and an engine is there to play it.
    private static func videoNeedsEngine(_ quality: StreamQuality, _ config: PolicyConfiguration) -> Bool {
        quality.videoNeedsFallbackEngine(decodesAV1InHardware: config.decodesAV1InHardware) && config.fallbackEngineAvailable
    }

    private static func fallback(_ url: URL, _ reason: FallbackReason, known: MediaContainer?, config: PolicyConfiguration) -> PlaybackRoute {
        config.fallbackEngineAvailable ? .fallback(url, reason) : .unsupported(known)
    }
}

/// UNVERIFIED (ADR-004): turns an `infoHash` into a URL on a user-supplied Stremio-compatible streaming server.
public enum StreamingServerRoute {
    public static func url(server: URL, infoHash: String, fileIndex: Int?) -> URL? {
        guard let scheme = server.scheme?.lowercased(), scheme == "http" || scheme == "https", server.host != nil else { return nil }
        let hash = infoHash.lowercased()
        let isHex = hash.count == 40 && hash.allSatisfy { $0.isHexDigit }
        let isBase32 = hash.count == 32 && hash.allSatisfy { ("a"..."z").contains($0) || ("2"..."7").contains($0) }
        guard isHex || isBase32 else { return nil }
        var base = server.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: "\(base)/\(hash)/\(fileIndex ?? -1)")
    }
}
