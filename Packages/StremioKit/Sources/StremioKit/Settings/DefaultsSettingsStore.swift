import Foundation

/// Persists `PlaybackSettings`: plain preferences in `UserDefaults`; the streaming server URL (it may embed credentials), the Trakt client
/// ID and the TMDb credential live in a `SecretStore`.
public final class DefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    public enum Keys {
        public static let preferredResolution = "settings.preferredResolution"
        public static let subtitleLanguage = "settings.subtitleLanguage"
        public static let fallbackEngineEnabled = "settings.fallbackEngineEnabled"
        public static let playerPreference = "settings.playerPreference"
        public static let showsPosterRatings = "settings.showsPosterRatings"
        public static let showsColouredRatingLogos = "settings.showsColouredRatingLogos"
        public static let matchesEpisodeWidthToText = "settings.matchesEpisodeWidthToText"
        public static let autoPlayBestStream = "settings.autoPlayBestStream"
        public static let autoPickWait = "settings.autoPickWait"
        public static let continueWatchingRefreshSeconds = "settings.continueWatchingRefreshSeconds"
        public static let serverSecret = "settings.streamingServerURL"
        public static let traktClientSecret = "settings.traktClientID"
        public static let tmdbReadToken = "settings.tmdbReadToken"
        public static let omdbAPIKey = "settings.omdbAPIKey"
        public static let player = "settings.player"
        public static let openSubtitlesAPIKey = "settings.openSubtitlesAPIKey"
        public static let openSubtitlesUsername = "settings.openSubtitlesUsername"
        public static let openSubtitlesPassword = "settings.openSubtitlesPassword"
    }

    /// The flag that says the old trailer service's saved key and address have been removed.
    private static let removedTrailerServiceFlag = "settings.removedOriginTrailerService"
    /// The secret and the default an older build of the paid trailer service saved. Only the one-time cleanup reads them.
    private static let legacyOriginSubscriptionKey = "settings.originSubscriptionKey"
    private static let legacyOriginAPIBaseURL = "settings.originAPIBaseURL"

    private let defaults: UserDefaults
    private let secrets: any SecretStore
    private let logger: AddonLogger

    public init(defaults: UserDefaults = .standard, secrets: any SecretStore, logger: AddonLogger = .silent) {
        self.defaults = defaults
        self.secrets = secrets
        self.logger = logger
    }

    /// Blusion once had a paid trailer service; its saved key and address are removed the first time settings load.
    private func removeLegacyTrailerService() async {
        guard !defaults.bool(forKey: Self.removedTrailerServiceFlag) else { return }
        await remove(Self.legacyOriginSubscriptionKey)
        defaults.removeObject(forKey: Self.legacyOriginAPIBaseURL)
        defaults.set(true, forKey: Self.removedTrailerServiceFlag)
    }

    public func load() async -> PlaybackSettings {
        await removeLegacyTrailerService()
        let resolution = defaults.integer(forKey: Keys.preferredResolution)
        let language = defaults.string(forKey: Keys.subtitleLanguage)
        let fallback = defaults.object(forKey: Keys.fallbackEngineEnabled) as? Bool ?? true
        let server = await secret(Keys.serverSecret)
        let traktClientID = await secret(Keys.traktClientSecret)
        let tmdbReadToken = await secret(Keys.tmdbReadToken)
        let omdbAPIKey = await secret(Keys.omdbAPIKey)
        let playerPreference = defaults.string(forKey: Keys.playerPreference).flatMap(PlayerPreference.init(rawValue:)) ?? PlaybackSettings().playerPreference
        let posterRatings = defaults.object(forKey: Keys.showsPosterRatings) as? Bool ?? true
        let player = defaults.data(forKey: Keys.player).flatMap { try? JSONDecoder().decode(PlayerPreferences.self, from: $0) } ?? PlayerPreferences()
        let openSubtitlesAPIKey = await secret(Keys.openSubtitlesAPIKey)
        let openSubtitlesUsername = await secret(Keys.openSubtitlesUsername)
        let openSubtitlesPassword = await secret(Keys.openSubtitlesPassword)
        return PlaybackSettings(preferredResolution: resolution > 0 ? resolution : nil, subtitleLanguage: language?.isEmpty == false ? language : nil,
                                streamingServerURL: server, fallbackEngineEnabled: fallback, traktClientID: traktClientID, playerPreference: playerPreference,
                                showsPosterRatings: posterRatings, autoPlayBestStream: defaults.bool(forKey: Keys.autoPlayBestStream),
                                omdbAPIKey: omdbAPIKey, tmdbReadToken: tmdbReadToken,
                                continueWatchingRefreshSeconds: defaults.object(forKey: Keys.continueWatchingRefreshSeconds) as? Int ?? 300,
                                showsColouredRatingLogos: defaults.bool(forKey: Keys.showsColouredRatingLogos),
                                matchesEpisodeWidthToText: defaults.bool(forKey: Keys.matchesEpisodeWidthToText),
                                autoPickWait: AutoPickWait(storedValue: defaults.string(forKey: Keys.autoPickWait)), player: player,
                                openSubtitlesAPIKey: openSubtitlesAPIKey, openSubtitlesUsername: openSubtitlesUsername,
                                openSubtitlesPassword: openSubtitlesPassword)
    }

    public func save(_ settings: PlaybackSettings) async {
        if let resolution = settings.preferredResolution, resolution > 0 {
            defaults.set(resolution, forKey: Keys.preferredResolution)
        } else {
            defaults.removeObject(forKey: Keys.preferredResolution)
        }
        if let language = settings.subtitleLanguage, !language.isEmpty {
            defaults.set(language, forKey: Keys.subtitleLanguage)
        } else {
            defaults.removeObject(forKey: Keys.subtitleLanguage)
        }
        defaults.set(settings.fallbackEngineEnabled, forKey: Keys.fallbackEngineEnabled)
        defaults.set(settings.playerPreference.rawValue, forKey: Keys.playerPreference)
        defaults.set(settings.showsPosterRatings, forKey: Keys.showsPosterRatings)
        defaults.set(settings.showsColouredRatingLogos, forKey: Keys.showsColouredRatingLogos)
        defaults.set(settings.matchesEpisodeWidthToText, forKey: Keys.matchesEpisodeWidthToText)
        defaults.set(settings.autoPlayBestStream, forKey: Keys.autoPlayBestStream)
        defaults.set(settings.autoPickWait.storedValue, forKey: Keys.autoPickWait)
        defaults.set(settings.continueWatchingRefreshSeconds ?? 300, forKey: Keys.continueWatchingRefreshSeconds)
        if let data = try? JSONEncoder().encode(settings.player) { defaults.set(data, forKey: Keys.player) }
        for (value, key) in [(settings.openSubtitlesAPIKey, Keys.openSubtitlesAPIKey), (settings.openSubtitlesUsername, Keys.openSubtitlesUsername),
                             (settings.openSubtitlesPassword, Keys.openSubtitlesPassword)] {
            if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                await store(trimmed, for: key)
            } else {
                await remove(key)
            }
        }
        if let server = settings.streamingServerURL?.trimmingCharacters(in: .whitespacesAndNewlines), !server.isEmpty {
            await store(server, for: Keys.serverSecret)
        } else {
            await remove(Keys.serverSecret)
        }
        if let traktClientID = settings.traktClientID?.trimmingCharacters(in: .whitespacesAndNewlines), !traktClientID.isEmpty {
            await store(traktClientID, for: Keys.traktClientSecret)
        } else {
            await remove(Keys.traktClientSecret)
        }
        if let tmdb = settings.tmdbReadToken?.trimmingCharacters(in: .whitespacesAndNewlines), !tmdb.isEmpty {
            await store(tmdb, for: Keys.tmdbReadToken)
        } else {
            await remove(Keys.tmdbReadToken)
        }
        if let omdb = settings.omdbAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !omdb.isEmpty {
            await store(omdb, for: Keys.omdbAPIKey)
        } else {
            await remove(Keys.omdbAPIKey)
        }
    }

    /// A failed read is logged with its reason and reads as "not set": the settings screen then shows the field empty.
    private func secret(_ key: String) async -> String? {
        do {
            return try await secrets.get(key)
        } catch {
            logger.log(.error, "secret \(key) could not be read: \(error)")
            return nil
        }
    }

    private func store(_ value: String, for key: String) async {
        do { try await secrets.set(value, for: key) } catch {
            logger.log(.error, "secret \(key) could not be saved: \(error)")
        }
    }

    private func remove(_ key: String) async {
        do { try await secrets.remove(key) } catch {
            logger.log(.error, "secret \(key) could not be removed: \(error)")
        }
    }
}
