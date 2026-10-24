import Foundation
import StremioKit

/// Where the app opens. Normally `home`; a launch argument can ask for another screen, which is how UI tests and
/// `scripts/snapshot.sh` reach a screen without tapping through the app.
///
/// Text forms (the `BLUSION_ROUTE` environment variable):
/// `home`, `discover`, `library`, `search`, `search:<query>`, `detail:<type>:<id>`, `streams:<type>:<id>`,
/// `settings`, `addons`, `widgets`, `gallery`, `gallery:<section>`, `player`.
public struct LaunchRoute: Sendable, Equatable {
    /// The tab bar, in order: Home, Discover, Library, Settings, Search. Widgets is a tab on Mac only, at the bottom of its sidebar.
    public enum Tab: String, Sendable, Hashable, CaseIterable {
        case home, discover, library, settings, search, widgets
    }

    /// Settings, or one of the screens inside it. They open on the Settings tab.
    public enum Sheet: String, Sendable, Equatable {
        case settings, addons, widgets
    }

    public var tab: Tab
    /// Typed into the search field on arrival.
    public var searchQuery: String?
    /// Pushed onto the Home stack on arrival.
    public var detail: MetaPreview?
    public var streams: StreamRequest?
    public var sheet: Sheet?
    /// The component gallery, optionally opened on one of its sections.
    public var showsGallery: Bool
    public var gallerySection: String?
    /// The player on a public sample stream, for looking at its controls without a stream addon.
    public var showsPlayerDemo: Bool

    public init(tab: Tab = .home, searchQuery: String? = nil, detail: MetaPreview? = nil, streams: StreamRequest? = nil,
                sheet: Sheet? = nil, showsGallery: Bool = false, gallerySection: String? = nil, showsPlayerDemo: Bool = false) {
        self.tab = tab
        self.searchQuery = searchQuery
        self.detail = detail
        self.streams = streams
        self.sheet = sheet
        self.showsGallery = showsGallery
        self.gallerySection = gallerySection
        self.showsPlayerDemo = showsPlayerDemo
    }

    public static let home = LaunchRoute()

    /// nil for text that is not a route. Ids keep their colons (`detail:series:tt1:1:2` is type `series`, id `tt1:1:2`).
    public static func parse(_ text: String?) -> LaunchRoute? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let parts = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let argument = parts.dropFirst().joined(separator: ":")
        switch parts[0].lowercased() {
        case "search":
            return LaunchRoute(tab: .search, searchQuery: argument.isEmpty ? nil : argument)
        case "detail":
            guard parts.count == 3, !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
            return LaunchRoute(detail: MetaPreview(id: parts[2], type: parts[1]))
        case "streams":
            guard parts.count == 3, !parts[1].isEmpty else { return nil }
            // `streams:movie:tt1?title=Film&poster=https://…` names the title and its artwork, as Detail does when it opens the picker.
            let idAndQuery = parts[2].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let id = idAndQuery.first, !id.isEmpty else { return nil }
            let query = idAndQuery.count == 2 ? URLComponents(string: "?" + idAndQuery[1])?.queryItems : nil
            func value(_ name: String) -> String? { query?.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
            return LaunchRoute(streams: StreamRequest(type: parts[1], id: id, title: value("title") ?? id,
                                                      poster: value("poster").flatMap(URL.init(string:))))
        case "settings", "addons", "widgets":
            return LaunchRoute(sheet: Sheet(rawValue: parts[0].lowercased()))
        case "gallery":
            return LaunchRoute(showsGallery: true, gallerySection: argument.isEmpty ? nil : argument)
        case "player":
            return LaunchRoute(showsPlayerDemo: true)
        default:
            return Tab(rawValue: parts[0].lowercased()).map { LaunchRoute(tab: $0) }
        }
    }
}
