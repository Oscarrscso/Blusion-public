import Foundation

/// One row of Home. This is Blusion's own storage format; `FusionWidgetCodec` reads and writes Fusion's JSON.
public struct HomeWidget: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var hideTitle: Bool
    public var content: Content

    public init(id: String = UUID().uuidString, title: String, hideTitle: Bool = false, content: Content) {
        self.id = id
        self.title = title
        self.hideTitle = hideTitle
        self.content = content
    }

    public enum Content: Sendable, Codable, Equatable, Hashable {
        /// A large paging spotlight fed by one source (Blusion only).
        case hero(RowConfiguration)
        /// Fusion `hero.banner`: a large featured landscape title over a row of smaller cards.
        case banner(RowConfiguration)
        /// Fusion `row.classic`.
        case row(RowConfiguration)
        /// Fusion `collection.row`: tiles that each open a grid.
        case collection([CollectionItem])
        /// The user's in-progress titles (Blusion only).
        case continueWatching
        /// A Fusion widget type this version cannot show (for example a calendar). Kept, with its type, so an imported layout survives
        /// and the UI can say so. Its contents are not kept: they may carry addon links.
        case unsupported(type: String)
    }
}

/// A row's source, how many items it loads, how long a loaded page is reused and how its cards look.
public struct RowConfiguration: Sendable, Codable, Equatable, Hashable {
    public var source: WidgetSource
    public var presentation: WidgetPresentation
    /// Items per page, clamped to 1...100 by `init`.
    public var limit: Int
    /// Seconds a loaded page is reused, clamped to 0...86_400 by `init`.
    public var cacheTTL: Int
    /// When the row's items take a new random order. Nil follows the widgets page's setting (`WidgetShuffleSettings`), which is off
    /// unless changed. Written only when set, so a saved or imported widget reads as it did.
    public var shuffle: WidgetShuffle?
    /// Set when the row takes its items from a source picked at random, which Home then shows in place of `source` (see
    /// `WidgetShuffling.pickingSources`). Written only when set.
    public var randomSource: RandomSource?

    public init(source: WidgetSource, presentation: WidgetPresentation = WidgetPresentation(), limit: Int = 20, cacheTTL: Int = 3600,
                shuffle: WidgetShuffle? = nil, randomSource: RandomSource? = nil) {
        self.source = source
        self.presentation = presentation
        self.limit = min(max(limit, 1), 100)
        self.cacheTTL = min(max(cacheTTL, 0), 86_400)
        self.shuffle = shuffle
        self.randomSource = randomSource
    }

    private enum CodingKeys: String, CodingKey { case source, presentation, limit, cacheTTL, shuffle, randomSource }

    /// Clamps stored values the same way `init` does, so an edited or newer file cannot break paging.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(source: try container.decode(WidgetSource.self, forKey: .source),
                  presentation: try container.decodeIfPresent(WidgetPresentation.self, forKey: .presentation) ?? WidgetPresentation(),
                  limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? 20,
                  cacheTTL: try container.decodeIfPresent(Int.self, forKey: .cacheTTL) ?? 3600,
                  // A shuffle or random source this version cannot read (written by a newer one) is left out, not the whole widget.
                  shuffle: (try? container.decodeIfPresent(WidgetShuffle.self, forKey: .shuffle)) ?? nil,
                  randomSource: (try? container.decodeIfPresent(RandomSource.self, forKey: .randomSource)) ?? nil)
    }
}

/// How a row's cards look. The defaults are Blusion's poster grid.
public struct WidgetPresentation: Sendable, Codable, Equatable, Hashable {
    public enum AspectRatio: String, Sendable, Codable, CaseIterable { case poster, wide, square }
    public enum CardStyle: String, Sendable, Codable, CaseIterable { case small, medium, large }

    public var aspectRatio: AspectRatio
    public var cardStyle: CardStyle
    public var showsRatings: Bool
    public var showsProviders: Bool
    /// A numbered (top-N) row: each card carries its position, 1 first. Fusion's `row.classic.numbered`.
    public var showsRank: Bool
    /// Poster cards take their artwork from the BetterPosters addon, falling back to the title's own poster.
    public var usesBetterPosters: Bool

    public init(aspectRatio: AspectRatio = .poster, cardStyle: CardStyle = .medium, showsRatings: Bool = true, showsProviders: Bool = false,
                showsRank: Bool = false, usesBetterPosters: Bool = false) {
        self.aspectRatio = aspectRatio
        self.cardStyle = cardStyle
        self.showsRatings = showsRatings
        self.showsProviders = showsProviders
        self.showsRank = showsRank
        self.usesBetterPosters = usesBetterPosters
    }

    private enum CodingKeys: String, CodingKey { case aspectRatio, cardStyle, showsRatings, showsProviders, showsRank, usesBetterPosters }

    /// `showsRank` and `usesBetterPosters` are missing from files written before they existed, so they default to off.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(aspectRatio: try container.decode(AspectRatio.self, forKey: .aspectRatio),
                  cardStyle: try container.decode(CardStyle.self, forKey: .cardStyle),
                  showsRatings: try container.decode(Bool.self, forKey: .showsRatings),
                  showsProviders: try container.decode(Bool.self, forKey: .showsProviders),
                  showsRank: try container.decodeIfPresent(Bool.self, forKey: .showsRank) ?? false,
                  usesBetterPosters: try container.decodeIfPresent(Bool.self, forKey: .usesBetterPosters) ?? false)
    }
}

/// One tile of a collection row. Its sources are merged into one grid when the tile opens.
public struct CollectionItem: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var hideTitle: Bool
    public var imageAspect: WidgetPresentation.AspectRatio
    public var imageURL: URL?
    public var sources: [WidgetSource]

    public init(id: String = UUID().uuidString, title: String, hideTitle: Bool = false, imageAspect: WidgetPresentation.AspectRatio = .wide,
                imageURL: URL? = nil, sources: [WidgetSource] = []) {
        self.id = id
        self.title = title
        self.hideTitle = hideTitle
        self.imageAspect = imageAspect
        self.imageURL = imageURL
        self.sources = sources
    }
}

/// Where a row's items come from.
public enum WidgetSource: Sendable, Codable, Equatable, Hashable {
    case addonCatalog(AddonCatalogReference)
    /// A public Trakt list, read with the Trakt client ID the user set in Settings.
    case traktList(TraktListReference)
    /// A Trakt feed (trending or popular movies or shows). Public, so only the client ID is needed. Blusion-only in Fusion files.
    case traktFeed(TraktFeed)
    /// A list TMDb builds from filters, read with the TMDB Read Access Token the user set in Settings. Blusion-only in Fusion files.
    case tmdbDiscover(TMDbDiscoverQuery)
    /// A kind this version cannot load (for example `anilistCatalog`). Kept so an imported widget survives; the UI says so.
    case unsupported(kind: String)
}

/// A catalog of an installed addon, named without the addon's URL (which is a secret).
public struct AddonCatalogReference: Sendable, Codable, Equatable, Hashable {
    /// The addon manifest's `id`, e.g. `com.linvo.cinemeta`; nil when unknown.
    public var manifestID: String?
    /// Display only: where the widget's addon lives, e.g. `example.com`.
    public var host: String?
    public var catalogType: String
    public var catalogID: String
    /// Optional genre filter, sent as the catalog's `genre` extra.
    public var genre: String?

    public init(manifestID: String? = nil, host: String? = nil, catalogType: String, catalogID: String, genre: String? = nil) {
        self.manifestID = manifestID
        self.host = host
        self.catalogType = catalogType
        self.catalogID = catalogID
        self.genre = genre
    }

    /// The installed, enabled addon and catalog this points at. Preference order: the addon whose manifest id is `manifestID` and that
    /// has the catalog (same id and type); then any enabled addon with that catalog; then a catalog matching only by id. Within each
    /// step the `manifestID` addon is looked at first. nil when nothing matches.
    public func resolve(in addons: [InstalledAddon]) -> (addon: InstalledAddon, catalog: CatalogDescriptor)? {
        let enabled = addons.filter(\.isEnabled)
        let candidates = enabled.filter { $0.manifest.id == manifestID } + enabled.filter { $0.manifest.id != manifestID }
        let exact: (CatalogDescriptor) -> Bool = { $0.id == self.catalogID && $0.type == self.catalogType }
        let byID: (CatalogDescriptor) -> Bool = { $0.id == self.catalogID }
        for matches in [exact, byID] {
            for addon in candidates {
                if let catalog = addon.manifest.catalogs.first(where: matches) { return (addon, catalog) }
            }
        }
        return nil
    }
}

/// A Trakt list: `https://trakt.tv/users/<username>/lists/<listSlug>`.
public struct TraktListReference: Sendable, Codable, Equatable, Hashable {
    public var username: String
    public var listSlug: String
    public var listName: String
    public var traktID: Int?
    /// How the widget orders the list; nil keeps the list's own order. Saved layouts from before sorting have no value.
    public var sort: TraktListSort?
    /// True for a list that is not public (one of the user's own), which is read with their Trakt sign-in. Missing means public.
    public var isPrivate: Bool?

    public init(username: String, listSlug: String, listName: String, traktID: Int? = nil, sort: TraktListSort? = nil, isPrivate: Bool? = nil) {
        self.username = username
        self.listSlug = listSlug
        self.listName = listName
        self.traktID = traktID
        self.sort = sort
        self.isPrivate = isPrivate
    }

    /// True when only the signed-in owner can read this list.
    public var needsAccount: Bool { isPrivate == true }
}

extension WidgetSource {
    /// True for a Trakt list or feed, which needs the Trakt client ID.
    public var usesTrakt: Bool {
        switch self {
        case .traktList, .traktFeed: return true
        case .addonCatalog, .tmdbDiscover, .unsupported: return false
        }
    }
}
