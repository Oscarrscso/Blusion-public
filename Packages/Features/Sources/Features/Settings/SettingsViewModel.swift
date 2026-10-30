import Foundation
import Observation
import PlayerKit
import StremioKit

/// Settings: default subtitle language, preferred quality, streaming server, clear data.
@MainActor
@Observable
public final class SettingsViewModel {
    public struct Option<Value: Hashable>: Hashable, Identifiable {
        public let label: String
        public let value: Value
        public var id: String { label }
    }

    public static let resolutionOptions: [Option<Int?>] = [
        .init(label: "Best available", value: nil), .init(label: "4K (2160p)", value: 2160), .init(label: "1080p", value: 1080),
        .init(label: "720p", value: 720), .init(label: "480p", value: 480),
    ]

    public static var languageOptions: [Option<String?>] {
        [.init(label: "Off", value: nil)] + LanguageCodes.all.map { .init(label: $0.name, value: $0.code) }
    }

    public static let continueWatchingRefreshOptions: [Option<Int>] = [
        .init(label: "Manually", value: 0), .init(label: "Every minute", value: 60),
        .init(label: "Every 5 minutes", value: 300), .init(label: "Every 15 minutes", value: 900),
        .init(label: "Every 30 minutes", value: 1800),
    ]

    public private(set) var settings = PlaybackSettings()
    public var serverURLText = ""
    /// The Trakt client ID as typed. `commitTraktClientID()` saves it.
    public var traktClientIDText = ""
    public var omdbAPIKeyText = ""
    public var tmdbReadTokenText = ""
    public var openSubtitlesAPIKeyText = ""
    public var openSubtitlesUsernameText = ""
    public var openSubtitlesPasswordText = ""
    /// Every installed addon, disabled ones included.
    public private(set) var installedAddonCount = 0
    /// Each installed addon's name, for the Addon Speed row's summary.
    public private(set) var addonNames: [UUID: String] = [:]
    public private(set) var lastMessage: String?
    /// OMDb requests this device has sent today (UTC). `refreshOMDbUsage()` updates it.
    public private(set) var omdbRequestsToday = 0
    public static let omdbDailyLimit = OMDbUsage.dailyLimit

    private let services: AppServices
    private let reset: DataResetService

    public init(services: AppServices) {
        self.services = services
        self.reset = DataResetService(services: services)
    }

    public var fallbackEngineLinked: Bool { services.fallbackEngineLinked }
    public var serverURLMessage: String? { PlaybackSettings.validationMessage(forServerURL: serverURLText) }

    public func load() async {
        settings = await services.settings.load()
        #if canImport(UIKit)
        Haptics.apply(settings.haptics)
        #endif
        serverURLText = settings.streamingServerURL ?? ""
        traktClientIDText = settings.traktClientID ?? ""
        omdbAPIKeyText = settings.omdbAPIKey ?? ""
        tmdbReadTokenText = settings.tmdbReadToken ?? ""
        openSubtitlesAPIKeyText = settings.openSubtitlesAPIKey ?? ""
        openSubtitlesUsernameText = settings.openSubtitlesUsername ?? ""
        openSubtitlesPasswordText = settings.openSubtitlesPassword ?? ""
        services.posterRatings.isEnabled = settings.showsPosterRatings
        services.posterRatings.showsColouredLogos = settings.showsColouredRatingLogos
        let addons = await services.registry.addons
        installedAddonCount = addons.count
        addonNames = Dictionary(addons.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        refreshOMDbUsage()
    }

    public func refreshOMDbUsage() {
        omdbRequestsToday = OMDbUsage.shared.today()
    }

    public func setPreferredResolution(_ value: Int?) async {
        settings = await services.settings.load()
        settings.preferredResolution = value
        await services.settings.save(settings)
    }

    public func setSubtitleLanguage(_ code: String?) async {
        settings = await services.settings.load()
        settings.subtitleLanguage = code
        await services.settings.save(settings)
    }

    /// Player preferences (subtitle, audio, picture and gesture defaults). The player saves changes made during playback the same way.
    public func updatePlayer(_ change: (inout PlayerPreferences) -> Void) async {
        settings = await services.settings.load()
        change(&settings.player)
        await services.settings.save(settings)
    }

    /// The Haptics page's tuning. Saved as it changes and applied at once, so the next tap is the one being tuned.
    public func updateHaptics(_ change: (inout HapticPreferences) -> Void) async {
        settings = await services.settings.load()
        change(&settings.haptics)
        await services.settings.save(settings)
        #if canImport(UIKit)
        Haptics.apply(settings.haptics)
        #endif
    }

    /// Saves the OpenSubtitles API key and login as typed; blank fields remove them.
    public func commitOpenSubtitles() async {
        settings = await services.settings.load()
        func trimmed(_ text: String) -> String? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        settings.openSubtitlesAPIKey = trimmed(openSubtitlesAPIKeyText)
        settings.openSubtitlesUsername = trimmed(openSubtitlesUsernameText)
        settings.openSubtitlesPassword = trimmed(openSubtitlesPasswordText)
        await services.settings.save(settings)
        let saved = await services.settings.load()
        lastMessage = saved.openSubtitlesAPIKey == settings.openSubtitlesAPIKey
            ? "OpenSubtitles saved." : "The OpenSubtitles key could not be saved to secure storage. Try again."
    }

    /// No "file's default": the player picks English when nothing else is chosen (`PlayerPreferences.defaultAudioLanguage`).
    public static var audioLanguageOptions: [Option<String?>] {
        LanguageCodes.all.map { .init(label: $0.name, value: $0.code) }
    }

    public func setFallbackEngineEnabled(_ enabled: Bool) async {
        settings = await services.settings.load()
        settings.fallbackEngineEnabled = enabled
        await services.settings.save(settings)
    }

    public func setPlayerPreference(_ value: PlayerPreference) async {
        settings = await services.settings.load()
        settings.playerPreference = value
        await services.settings.save(settings)
    }

    public func setAutoPlayBestStream(_ value: Bool) async {
        settings = await services.settings.load()
        settings.autoPlayBestStream = value
        await services.settings.save(settings)
    }

    public func setAutoPickSource(_ value: StreamSourcePreference) async {
        settings = await services.settings.load()
        settings.autoPickSource = value
        await services.settings.save(settings)
    }

    public func setContinueWatchingRefreshSeconds(_ value: Int) async {
        settings = await services.settings.load()
        settings.continueWatchingRefreshSeconds = value
        await services.settings.save(settings)
    }

    /// Also switches the poster ratings in the store the posters read.
    public func setShowsPosterRatings(_ value: Bool) async {
        settings = await services.settings.load()
        settings.showsPosterRatings = value
        services.posterRatings.isEnabled = value
        await services.settings.save(settings)
    }

    /// Also switches the rating logos in the store they read, so posters and detail rows change at once.
    public func setShowsColouredRatingLogos(_ value: Bool) async {
        settings = await services.settings.load()
        settings.showsColouredRatingLogos = value
        services.posterRatings.showsColouredLogos = value
        await services.settings.save(settings)
    }

    /// Saves the Trakt client ID as typed, without surrounding spaces. A blank field removes it.
    public func commitTraktClientID() async {
        settings = await services.settings.load()
        let trimmed = traktClientIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.traktClientID = trimmed.isEmpty ? nil : trimmed
        await services.settings.save(settings)
    }

    public func commitReviewCredentials() async {
        settings = await services.settings.load()
        let omdb = omdbAPIKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tmdb = tmdbReadTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.omdbAPIKey = omdb.isEmpty ? nil : omdb
        settings.tmdbReadToken = tmdb.isEmpty ? nil : tmdb
        await services.settings.save(settings)
        let saved = await services.settings.load()
        await services.posterRatings.setReviewServices(
            omdb: saved.omdbAPIKey.map { OMDbRatings(client: services.client, apiKey: $0) },
            tmdb: saved.tmdbReadToken.map { TMDbRatings(client: services.client, readAccessToken: $0) }, refreshCache: true)
        if saved.omdbAPIKey == settings.omdbAPIKey, saved.tmdbReadToken == settings.tmdbReadToken {
            lastMessage = "Review services saved. Ratings will refresh as you browse."
        } else {
            lastMessage = "Review credentials could not be saved to secure storage. Try saving them again."
        }
    }

    public func refreshRatings() async {
        await services.posterRatings.refresh()
        lastMessage = "Ratings will refresh as you browse."
    }

    /// Saves the streaming server field if it is empty or valid; otherwise leaves the stored value alone.
    public func commitServerURL() async {
        guard serverURLMessage == nil else { return }
        settings = await services.settings.load()
        let trimmed = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.streamingServerURL = trimmed.isEmpty ? nil : trimmed
        await services.settings.save(settings)
    }

    public func clear(_ scope: DataResetService.Scope) async {
        lastMessage = await reset.clear(scope)
        if scope == .settings || scope == .everything { await load() }
    }

    public static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        // The commit the app was built from; an unexpanded "$(...)" means a build made without the install script.
        let tag = info?["BlusionBuildTag"] as? String ?? ""
        let commit = tag.isEmpty || tag.hasPrefix("$(") ? "" : " · \(tag)"
        return "\(version) (\(build))\(commit)"
    }
}
