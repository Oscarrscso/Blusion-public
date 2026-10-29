import Foundation

/// User preferences that affect which stream is picked and how it plays (PLAN M7 surfaces them in Settings).
public struct PlaybackSettings: Sendable, Equatable, Codable {
    /// Preferred vertical resolution (e.g. 1080). nil = best available.
    public var downloadsAllowCellular: Bool = false
    public var downloadsDeleteWhenWatched: Bool = false
    public var preferredResolution: Int?
    /// Default subtitle language as an ISO 639-2 or 639-1 code (`eng`, `en`). nil = subtitles off by default.
    public var subtitleLanguage: String?
    /// A Stremio-compatible streaming server (ADR-004). A URL can embed credentials, so it is stored as a secret.
    public var streamingServerURL: String?
    /// Lets the user turn the fallback engine off (it is also off when no engine is linked).
    public var fallbackEngineEnabled: Bool
    /// The Trakt API client ID the user supplies, needed to read Trakt lists. Stored as a secret, never shipped with the app.
    public var traktClientID: String?
    /// Optional review-service credentials, stored in the Keychain.
    public var omdbAPIKey: String?
    public var tmdbReadToken: String?
    /// Whether streams play in Blusion or are handed to another player app (Infuse).
    public var playerPreference: PlayerPreference
    /// IMDb and Letterboxd ratings on posters.
    public var showsPosterRatings: Bool
    /// Rating logos keep their brand colours. Off by default: they then take the text colour, so they match the rest of the screen.
    public var showsColouredRatingLogos: Bool
    /// Play starts the best stream at once instead of showing the list of streams first.
    public var autoPlayBestStream: Bool
    /// Seconds between Trakt playback refreshes. Zero is manual; nil uses the five-minute default for older saved settings.
    public var continueWatchingRefreshSeconds: Int?
    /// Episode cards on a title page are as wide as the text above them, instead of the fixed card width. Off by default.
    public var matchesEpisodeWidthToText: Bool
    /// What Auto Pick waits for before it chooses: every addon by default (see `AutoPickWait`).
    public var autoPickWait: AutoPickWait
    /// Whether Auto Pick goes for Usenet streams, debrid streams, or lets quality decide (see `StreamSourcePreference`).
    public var autoPickSource: StreamSourcePreference
    /// Subtitle, audio, picture and gesture preferences for the built-in player.
    public var player: PlayerPreferences
    /// OpenSubtitles.com: an API key from the user's own (free) developer account, and optionally their login, which raises the
    /// daily download allowance. Stored as secrets.
    public var openSubtitlesAPIKey: String?
    public var openSubtitlesUsername: String?
    public var openSubtitlesPassword: String?

    public init(preferredResolution: Int? = nil, subtitleLanguage: String? = nil, streamingServerURL: String? = nil, fallbackEngineEnabled: Bool = true,
                traktClientID: String? = nil, playerPreference: PlayerPreference = .infuseWhenNeeded, showsPosterRatings: Bool = true,
                autoPlayBestStream: Bool = false, omdbAPIKey: String? = nil, tmdbReadToken: String? = nil,
                continueWatchingRefreshSeconds: Int? = 300, showsColouredRatingLogos: Bool = false, matchesEpisodeWidthToText: Bool = false,
                autoPickWait: AutoPickWait = .allAddons, autoPickSource: StreamSourcePreference = .balanced, player: PlayerPreferences = PlayerPreferences(),
                openSubtitlesAPIKey: String? = nil, openSubtitlesUsername: String? = nil, openSubtitlesPassword: String? = nil) {
        self.player = player
        self.openSubtitlesAPIKey = openSubtitlesAPIKey
        self.openSubtitlesUsername = openSubtitlesUsername
        self.openSubtitlesPassword = openSubtitlesPassword
        self.matchesEpisodeWidthToText = matchesEpisodeWidthToText
        self.autoPickWait = autoPickWait
        self.autoPickSource = autoPickSource
        self.preferredResolution = preferredResolution
        self.subtitleLanguage = subtitleLanguage
        self.streamingServerURL = streamingServerURL
        self.fallbackEngineEnabled = fallbackEngineEnabled
        self.traktClientID = traktClientID
        self.playerPreference = playerPreference
        self.showsPosterRatings = showsPosterRatings
        self.showsColouredRatingLogos = showsColouredRatingLogos
        self.autoPlayBestStream = autoPlayBestStream
        self.omdbAPIKey = omdbAPIKey
        self.tmdbReadToken = tmdbReadToken
        self.continueWatchingRefreshSeconds = continueWatchingRefreshSeconds
    }

    public var serverURL: URL? {
        guard let text = streamingServerURL?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// Why `streamingServerURL` can't be used, or nil when it is empty or fine. Shown in Settings as the user types.
    public static func validationMessage(forServerURL text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), url.host != nil else {
            return "Enter a full address such as http://192.168.1.10:11470"
        }
        guard scheme == "http" || scheme == "https" else { return "The address must start with http:// or https://" }
        return nil
    }

    public var rankingPreferences: RankingPreferences {
        RankingPreferences(preferredResolution: preferredResolution, sourcePreference: autoPickSource)
    }

    /// `decodesAV1InHardware` has no default: a caller that left it out would send AV1 to the engine on capable chips.
    public func policy(fallbackEngineLinked: Bool, backupEngineLinked: Bool = false, decodesAV1InHardware: Bool) -> PolicyConfiguration {
        PolicyConfiguration(fallbackEngineAvailable: fallbackEngineLinked && fallbackEngineEnabled,
                            backupEngineAvailable: fallbackEngineLinked && fallbackEngineEnabled && backupEngineLinked && player.advancedEngine == .aether,
                            streamingServerURL: serverURL, playerPreference: playerPreference, decodesAV1InHardware: decodesAV1InHardware)
    }
}

public protocol SettingsStore: Sendable {
    func load() async -> PlaybackSettings
    func save(_ settings: PlaybackSettings) async
}

public actor InMemorySettingsStore: SettingsStore {
    private var settings: PlaybackSettings

    public init(_ settings: PlaybackSettings = PlaybackSettings()) {
        self.settings = settings
    }

    public func load() async -> PlaybackSettings { settings }

    public func save(_ settings: PlaybackSettings) async { self.settings = settings }
}
