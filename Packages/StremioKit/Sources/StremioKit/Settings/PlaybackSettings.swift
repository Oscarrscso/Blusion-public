import Foundation

/// User preferences that affect which stream is picked and how it plays (PLAN M7 surfaces them in Settings).
/// Where a poster's disc or streamer brand sits ("Mark position"). A corner the ratings already use keeps it in their pill.
public enum PosterMarkPlacement: String, Sendable, Equatable, Codable, CaseIterable {
    case withRatings, topLeading, topTrailing, bottomLeading, bottomTrailing

    public var label: String {
        switch self {
        case .withRatings: "With ratings"
        case .topLeading: "Top left"
        case .topTrailing: "Top right"
        case .bottomLeading: "Bottom left"
        case .bottomTrailing: "Bottom right"
        }
    }
}

/// How hard automatic choices save data (Settings → Streams → Data Saver).
public enum DataSaverLevel: String, Sendable, Equatable, CaseIterable, Identifiable {
    case off, on, ultra

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Off"
        case .on: "On"
        case .ultra: "Ultra"
        }
    }
}

public struct PlaybackSettings: Sendable, Equatable, Codable {
    /// Preferred vertical resolution (e.g. 1080). nil = best available.
    public var downloadsAllowCellular: Bool = false
    public var downloadsDeleteWhenWatched: Bool = false
    public var preferredResolution: Int?
    /// Data Saver: automatic choices keep to 1080p or below and prefer efficient encodes to REMUXes and outsized files. Off by default.
    public var dataSaver: Bool = false
    /// Ultra Saver, with `dataSaver` on: automatic choices keep to 720p or below and favour the smallest good encodes. Off by default.
    public var ultraSaver: Bool = false
    /// Default subtitle language as an ISO 639-2 or 639-1 code (`eng`, `en`). nil = subtitles off by default.
    public var subtitleLanguage: String?
    /// A Stremio-compatible streaming server (ADR-004). A URL can embed credentials, so it is stored as a secret.
    public var streamingServerURL: String?
    /// Lets the user turn the fallback engine off (it is also off when no engine is linked).
    public var fallbackEngineEnabled: Bool
    /// The Trakt API client ID, needed to read Trakt lists. The app supplies its own; stored as a secret.
    public var traktClientID: String?
    /// Optional review-service credentials, stored in the Keychain.
    public var omdbAPIKey: String?
    public var tmdbReadToken: String?
    /// Whether streams play in Blusion or are handed to another player app (Infuse).
    public var playerPreference: PlayerPreference
    /// IMDb and Letterboxd ratings on posters.
    public var showsPosterRatings: Bool
    /// Rating logos keep their brand colours. On by default; off, they take the text colour, so they match the rest of the screen.
    public var showsColouredRatingLogos: Bool
    /// Poster cards use 1200-pixel hero artwork; details reuse it while loading the full-resolution image.
    public var usesHeroPosters: Bool = false
    /// Film posters carry a 4K or Blu-ray mark beside their ratings when Best Blurays names that disc as the film's best. On by default:
    /// each film is looked up on bestblurays.com.
    public var showsBestDiscOnPosters: Bool = true
    /// Where a poster's disc or streamer brand sits: in the ratings pill, or on its own in a corner. Top right by default.
    public var posterMarkPlacement: PosterMarkPlacement = .topTrailing
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
    /// The listener's own tuning of the app's haptics (see `HapticPreferences` and the Haptics page in Settings).
    public var haptics: HapticPreferences
    /// OpenSubtitles.com: an API key from the user's own (free) developer account, and optionally their login, which raises the
    /// daily download allowance. Stored as secrets.
    public var openSubtitlesAPIKey: String?
    public var openSubtitlesUsername: String?
    public var openSubtitlesPassword: String?

    public init(preferredResolution: Int? = nil, subtitleLanguage: String? = nil, streamingServerURL: String? = nil, fallbackEngineEnabled: Bool = true,
                traktClientID: String? = nil, playerPreference: PlayerPreference = .infuseWhenNeeded, showsPosterRatings: Bool = true,
                autoPlayBestStream: Bool = false, omdbAPIKey: String? = nil, tmdbReadToken: String? = nil,
                continueWatchingRefreshSeconds: Int? = 300, showsColouredRatingLogos: Bool = true, matchesEpisodeWidthToText: Bool = false,
                autoPickWait: AutoPickWait = .allAddons, autoPickSource: StreamSourcePreference = .balanced, player: PlayerPreferences = PlayerPreferences(),
                openSubtitlesAPIKey: String? = nil, openSubtitlesUsername: String? = nil, openSubtitlesPassword: String? = nil,
                haptics: HapticPreferences = HapticPreferences()) {
        self.player = player
        self.haptics = haptics
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

    public var rankingPreferences: RankingPreferences { rankingPreferences(for: nil) }

    /// Data Saver as one choice: off, on, or Ultra Saver.
    public var dataSaverLevel: DataSaverLevel {
        get { dataSaver ? (ultraSaver ? .ultra : .on) : .off }
        set {
            dataSaver = newValue != .off
            ultraSaver = newValue == .ultra
        }
    }

    /// Settings' ranking, or a quality chosen for one play. Highest ranks by quality alone; Data Saver keeps to 1080p or below, and
    /// Ultra Saver to 720p.
    public func rankingPreferences(for quality: PlayQuality?) -> RankingPreferences {
        let savesMoreData = quality.map { $0 == .ultraSaver } ?? (dataSaverLevel == .ultra)
        let savesData = quality.map(\.savesData) ?? dataSaver
        var resolution = quality == .highest ? nil : preferredResolution
        if savesData {
            let cap = savesMoreData ? RankingPreferences.ultraSaverResolution : RankingPreferences.dataSaverResolution
            resolution = min(resolution ?? cap, cap)
        }
        return RankingPreferences(preferredResolution: resolution, sourcePreference: autoPickSource, savesData: savesData,
                                  savesMoreData: savesMoreData)
    }

    /// `decodesAV1InHardware` has no default: a caller that left it out would send AV1 to the engine on capable chips.
    public func policy(fallbackEngineLinked: Bool, backupEngineLinked: Bool = false, decodesAV1InHardware: Bool) -> PolicyConfiguration {
        PolicyConfiguration(fallbackEngineAvailable: fallbackEngineLinked && fallbackEngineEnabled,
                            backupEngineAvailable: fallbackEngineLinked && fallbackEngineEnabled && backupEngineLinked && player.advancedEngine == .aether,
                            streamingServerURL: serverURL, playerPreference: playerPreference, decodesAV1InHardware: decodesAV1InHardware)
    }
}

public typealias SettingsMutation = @MainActor @Sendable (inout PlaybackSettings) -> Void

public protocol SettingsStore: Sendable {
    func load() async -> PlaybackSettings
    func save(_ settings: PlaybackSettings) async
    func update(_ change: @escaping SettingsMutation) async -> PlaybackSettings
}

public extension SettingsStore {
    func update(_ change: @escaping SettingsMutation) async -> PlaybackSettings {
        var value = await load()
        await change(&value)
        await save(value)
        return value
    }
}

/// One queue for every settings writer in the app. Each mutation reads only after the preceding save finishes.
@MainActor
public final class QueuedSettingsStore: SettingsStore {
    private let base: any SettingsStore
    private var pending: Task<PlaybackSettings, Never>?

    public nonisolated init(base: any SettingsStore) { self.base = base }

    public func load() async -> PlaybackSettings {
        _ = await pending?.value
        return await base.load()
    }

    public func save(_ settings: PlaybackSettings) async {
        _ = await update { $0 = settings }
    }

    public func update(_ change: @escaping SettingsMutation) async -> PlaybackSettings {
        let previous = pending
        let base = base
        let task = Task { @MainActor in
            _ = await previous?.value
            var value = await base.load()
            change(&value)
            await base.save(value)
            return value
        }
        pending = task
        return await task.value
    }
}

public actor InMemorySettingsStore: SettingsStore {
    private var settings: PlaybackSettings

    public init(_ settings: PlaybackSettings = PlaybackSettings()) {
        self.settings = settings
    }

    public func load() async -> PlaybackSettings { settings }

    public func save(_ settings: PlaybackSettings) async { self.settings = settings }
}
