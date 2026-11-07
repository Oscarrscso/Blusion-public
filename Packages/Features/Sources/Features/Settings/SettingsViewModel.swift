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
    private var mutationRevision = 0

    private func update(_ change: @escaping SettingsMutation) async {
        mutationRevision += 1
        let revision = mutationRevision
        let saved = await services.settings.update(change)
        if revision == mutationRevision { settings = saved }
    }

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
        openSubtitlesAPIKeyText = settings.openSubtitlesAPIKey ?? ""
        openSubtitlesUsernameText = settings.openSubtitlesUsername ?? ""
        openSubtitlesPasswordText = settings.openSubtitlesPassword ?? ""
        services.posterRatings.isEnabled = settings.showsPosterRatings
        services.posterRatings.showsColouredLogos = settings.showsColouredRatingLogos
        services.posterRatings.showsBestDisc = settings.showsBestDiscOnPosters
        services.posterRatings.markPlacement = settings.posterMarkPlacement
        let addons = await services.registry.addons
        installedAddonCount = addons.count
        addonNames = Dictionary(addons.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        refreshOMDbUsage()
    }

    public func refreshOMDbUsage() {
        omdbRequestsToday = OMDbUsage.shared.today()
    }

    public func setPreferredResolution(_ value: Int?) async {
        await update { $0.preferredResolution = value }
    }

    public func setDataSaver(_ value: Bool) async {
        await update { $0.dataSaver = value }
    }

    public func setDataSaverLevel(_ level: DataSaverLevel) async {
        await update { $0.dataSaverLevel = level }
    }

    public func setSubtitleLanguage(_ code: String?) async {
        await update { $0.subtitleLanguage = code }
    }

    /// Player preferences (subtitle, audio, picture and gesture defaults). The player saves changes made during playback the same way.
    public func updatePlayer(_ change: @escaping @MainActor @Sendable (inout PlayerPreferences) -> Void) async {
        await update { change(&$0.player) }
    }

    /// The Haptics page's tuning. Saved as it changes and applied at once, so the next tap is the one being tuned.
    public func updateHaptics(_ change: @escaping @MainActor @Sendable (inout HapticPreferences) -> Void) async {
        await update { change(&$0.haptics) }
        #if canImport(UIKit)
        Haptics.apply(settings.haptics)
        #endif
    }

    /// Saves the OpenSubtitles API key and login as typed; blank fields remove them.
    public func commitOpenSubtitles() async {
        func trimmed(_ text: String) -> String? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let key = trimmed(openSubtitlesAPIKeyText)
        let username = trimmed(openSubtitlesUsernameText)
        let password = trimmed(openSubtitlesPasswordText)
        await update {
            $0.openSubtitlesAPIKey = key
            $0.openSubtitlesUsername = username
            $0.openSubtitlesPassword = password
        }
        let saved = await services.settings.load()
        lastMessage = saved.openSubtitlesAPIKey == key
            ? "OpenSubtitles saved." : "The OpenSubtitles key could not be saved to secure storage. Try again."
    }

    /// No "file's default": the player picks English when nothing else is chosen (`PlayerPreferences.defaultAudioLanguage`).
    public static var audioLanguageOptions: [Option<String?>] {
        LanguageCodes.all.map { .init(label: $0.name, value: $0.code) }
    }

    public func setFallbackEngineEnabled(_ enabled: Bool) async {
        await update { $0.fallbackEngineEnabled = enabled }
    }

    public func setPlayerPreference(_ value: PlayerPreference) async {
        await update { $0.playerPreference = value }
    }

    public func setAutoPlayBestStream(_ value: Bool) async {
        await update { $0.autoPlayBestStream = value }
    }

    public func setAutoPickSource(_ value: StreamSourcePreference) async {
        await update { $0.autoPickSource = value }
    }

    public func setContinueWatchingRefreshSeconds(_ value: Int) async {
        await update { $0.continueWatchingRefreshSeconds = value }
    }

    /// Also switches the poster ratings in the store the posters read.
    public func setShowsPosterRatings(_ value: Bool) async {
        await update { $0.showsPosterRatings = value }
        services.posterRatings.isEnabled = settings.showsPosterRatings
    }

    /// Also switches the rating logos in the store they read, so posters and detail rows change at once.
    public func setShowsColouredRatingLogos(_ value: Bool) async {
        await update { $0.showsColouredRatingLogos = value }
        services.posterRatings.showsColouredLogos = settings.showsColouredRatingLogos
    }

    /// Also switches the disc marks in the store the posters read.
    public func setShowsBestDiscOnPosters(_ value: Bool) async {
        await update { $0.showsBestDiscOnPosters = value }
        services.posterRatings.showsBestDisc = settings.showsBestDiscOnPosters
    }

    /// Also moves the marks on the posters on screen.
    public func setPosterMarkPlacement(_ value: PosterMarkPlacement) async {
        await update { $0.posterMarkPlacement = value }
        services.posterRatings.markPlacement = settings.posterMarkPlacement
    }

    public func setUsesHeroPosters(_ value: Bool) async {
        await update { $0.usesHeroPosters = value }
    }

    public func refreshRatings() async {
        await services.posterRatings.refresh()
        lastMessage = "Ratings will refresh as you browse."
    }

    /// Saves the streaming server field if it is empty or valid; otherwise leaves the stored value alone.
    public func commitServerURL() async {
        guard serverURLMessage == nil else { return }
        let trimmed = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        await update { $0.streamingServerURL = trimmed.isEmpty ? nil : trimmed }
    }

    /// Clears the last confirmation, so a page opened later does not show another page's message.
    public func clearMessage() {
        lastMessage = nil
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
