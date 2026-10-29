import Foundation
import PlayerKit
import StremioKit

/// "Clear data" in Settings. Each scope is independent; `everything` is all of them and also removes every addon (and so its Keychain URL).
public struct DataResetService: Sendable {
    public enum Scope: Sendable, Equatable, CaseIterable {
        case history, library, downloads, settings, widgets, addons, everything

        public var title: String {
            switch self {
            case .downloads: return "Downloads"
            case .history: return "Watch history"
            case .library: return "Saved titles"
            case .settings: return "Settings"
            case .widgets: return "Home layout"
            case .addons: return "All addons"
            case .everything: return "Everything"
            }
        }

        public var warning: String {
            switch self {
            case .downloads: return "Removes downloaded videos and subtitles."
            case .history: return "Removes your watch progress and watched marks. Continue will be empty."
            case .library: return "Removes every saved title from your library."
            case .settings: return "Resets playback and ratings preferences, account credentials and the streaming server."
            case .widgets: return "Puts Home back to the automatic layout. Your widgets are removed."
            case .addons: return "Removes every installed addon and its saved link. You'll need to add them again."
            case .everything: return "Removes watch history, saved titles, downloads, settings, your Home layout and all addons."
            }
        }
    }

    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    /// Returns a sentence describing what was cleared.
    @discardableResult
    public func clear(_ scope: Scope) async -> String {
        switch scope {
        case .downloads:
            await services.downloads?.deleteAll()
        case .history:
            await services.progress.clear()
        case .library:
            await services.library.clear()
        case .settings:
            await services.settings.save(PlaybackSettings())
            await services.downloads?.preferencesChanged()
            await services.traktAccount.clearCredentials()
            await services.traktSync.signedOut()
            await services.posterRatings.setReviewServices(tmdb: nil)
            await MainActor.run {
                services.posterRatings.isEnabled = PlaybackSettings().showsPosterRatings
                services.posterRatings.showsColouredLogos = PlaybackSettings().showsColouredRatingLogos
            }
            await services.widgetContent.invalidate()
        case .widgets:
            await services.widgets.save(nil)
            await services.widgetShuffle.clear()
            await services.widgetContent.forgetEverything()
        case .addons:
            for addon in await services.registry.addons { try? await services.registry.remove(id: addon.id) }
            await services.widgetContent.forgetEverything()
            await services.addonSpeed.clear()
        case .everything:
            for each in [Scope.history, .library, .downloads, .settings, .widgets, .addons] { await clear(each) }
            services.searchHistory.save([])
            await services.posterRatings.forgetAll()
            await services.handoffs.clear()
            await services.traktSync.reset()
        }
        return "\(scope.title) cleared."
    }
}
