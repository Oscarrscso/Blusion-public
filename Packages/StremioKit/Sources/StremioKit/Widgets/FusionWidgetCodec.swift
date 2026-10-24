import Foundation

public enum WidgetImportError: Error, Equatable, Sendable {
    /// More than 2 MB; refused before parsing.
    case tooLarge
    /// Not JSON, or neither a Fusion widget export nor a bare list of collection tiles.
    case notWidgetJSON
    /// The right shape, but no widget could be read.
    case empty

    public var message: String {
        switch self {
        case .tooLarge: return "This file is larger than 2 MB, so Blusion can't import it."
        case .notWidgetJSON: return "This isn't a Fusion widget file. Choose a JSON export from Fusion."
        case .empty: return "The file has no widgets Blusion can read."
        }
    }
}

/// Reads and writes Fusion's widget exports. Import is lenient: a bad widget or tile is skipped and counted, never fatal.
public enum FusionWidgetCodec {
    public struct ImportResult: Sendable, Equatable {
        public var widgets: [HomeWidget]
        /// Widgets, and collection tiles inside a kept widget, that could not be read and were skipped.
        public var skipped: Int
        /// Hosts of addons the import refers to that are not installed, de-duplicated, in order of appearance.
        public var missingAddonHosts: [String]
        /// The manifest URLs of those missing addons, so the UI can offer to install them right now. SECRETS: never persist or log them.
        public var missingAddonLinks: [String]

        public init(widgets: [HomeWidget], skipped: Int, missingAddonHosts: [String], missingAddonLinks: [String]) {
            self.widgets = widgets
            self.skipped = skipped
            self.missingAddonHosts = missingAddonHosts
            self.missingAddonLinks = missingAddonLinks
        }
    }

    private static let maxBytes = 2 * 1024 * 1024

    /// Accepts `{ "widgets": [...] }` (any Fusion export) or a bare array, which becomes one "Collections" widget.
    /// `addons` decides which addon links the import can use; the rest are reported as missing.
    public static func decode(_ data: Data, installed addons: [InstalledAddon]) throws -> ImportResult {
        guard data.count <= maxBytes else { throw WidgetImportError.tooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw WidgetImportError.notWidgetJSON
        }
        var importer = Importer(addons: addons)
        let widgets: [HomeWidget]
        if let entries = root as? [Any] {
            if let tiles = importer.tiles(entries) {
                widgets = [HomeWidget(title: "Collections", content: .collection(tiles))]
            } else {
                importer.skipped += 1
                widgets = []
            }
        } else if let object = root as? [String: Any], let entries = object["widgets"] as? [Any] {
            widgets = entries.compactMap { importer.widget($0) }
        } else {
            throw WidgetImportError.notWidgetJSON
        }
        guard !widgets.isEmpty else { throw WidgetImportError.empty }
        return ImportResult(widgets: widgets, skipped: importer.skipped, missingAddonHosts: importer.missingHosts, missingAddonLinks: importer.missingLinks)
    }

    /// `{"exportType":"fusionWidgets","exportVersion":1,"widgets":[...]}`, pretty-printed with sorted keys.
    public static func encode(_ widgets: [HomeWidget]) throws -> Data {
        let root: [String: Any] = ["exportType": "fusionWidgets", "exportVersion": 1, "widgets": widgets.map { encodeWidget($0) }]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: Decoding

    /// Carries the counters and the missing-addon lists through one import.
    private struct Importer {
        let addons: [InstalledAddon]
        var skipped = 0
        var missingHosts: [String] = []
        var missingLinks: [String] = []

        /// One widget, or nil when it cannot be read or its type is unknown (counted as skipped).
        mutating func widget(_ value: Any) -> HomeWidget? {
            guard let object = value as? [String: Any], let type = Read.text(object["type"]) else {
                skipped += 1
                return nil
            }
            let content: HomeWidget.Content
            switch type {
            case "row.classic", "row.classic.numbered", "blusion.hero", "hero.banner":
                guard let row = rowConfiguration(object, numbered: type == "row.classic.numbered") else {
                    skipped += 1
                    return nil
                }
                switch type {
                case "blusion.hero": content = .hero(row)
                case "hero.banner": content = .banner(row)
                default: content = .row(row)
                }
            case "collection.row":
                guard let tiles = collection(object) else {
                    skipped += 1
                    return nil
                }
                content = .collection(tiles)
            case "blusion.continueWatching":
                content = .continueWatching
            default:
                // A type this version cannot show is kept as a placeholder, so the layout round-trips and Home can say so.
                content = .unsupported(type: type)
            }
            return HomeWidget(id: Read.text(object["id"]) ?? UUID().uuidString, title: Read.text(object["title"]) ?? "",
                              hideTitle: Read.flag(object["hideTitle"]) ?? false, content: content)
        }

        /// A row or hero needs a readable data source; everything else falls back to a default.
        mutating func rowConfiguration(_ object: [String: Any], numbered: Bool = false) -> RowConfiguration? {
            guard let source = source(object["dataSource"], label: Read.text(object["title"]) ?? "") else { return nil }
            var presentation = Read.presentation(object["presentation"])
            presentation.showsRank = numbered
            return RowConfiguration(source: source, presentation: presentation,
                                    limit: Read.integer(object["limit"]) ?? 20, cacheTTL: Read.integer(object["cacheTTL"]) ?? 3600)
        }

        mutating func collection(_ object: [String: Any]) -> [CollectionItem]? {
            guard let dataSource = object["dataSource"] as? [String: Any], Read.text(dataSource["kind"]) == "collection",
                  let payload = dataSource["payload"] as? [String: Any], let entries = payload["items"] as? [Any] else { return nil }
            return tiles(entries)
        }

        /// The readable tiles, in order. Unreadable tiles are counted only when at least one tile survives; a collection
        /// without any readable tile is skipped as a whole by the caller.
        mutating func tiles(_ entries: [Any]) -> [CollectionItem]? {
            var tiles: [CollectionItem] = []
            var dropped = 0
            for entry in entries {
                if let item = tile(entry) {
                    tiles.append(item)
                } else {
                    dropped += 1
                }
            }
            guard !tiles.isEmpty else { return nil }
            skipped += dropped
            return tiles.withUniqueIDs()
        }

        mutating func tile(_ value: Any) -> CollectionItem? {
            guard let object = value as? [String: Any] else { return nil }
            let title = Read.text(object["title"]) ?? Read.text(object["name"]) ?? ""
            let sources = ((object["dataSources"] as? [Any]) ?? []).compactMap { source($0, label: title) }
            return CollectionItem(id: Read.text(object["id"]) ?? UUID().uuidString,
                                  title: title,
                                  hideTitle: Read.flag(object["hideTitle"]) ?? false,
                                  imageAspect: Read.aspectRatio(object["imageAspect"] ?? object["layout"]) ?? .wide,
                                  imageURL: Read.httpURL(object["imageURL"]) ?? Read.httpURL(object["backgroundImageURL"]),
                                  sources: sources)
        }

        /// A data source, or nil when it is unreadable (no kind, or an addon catalog without a catalog id). `label` is the title of the
        /// widget or tile that holds the source, which a Fusion TMDb list names its filters by.
        mutating func source(_ value: Any?, label: String) -> WidgetSource? {
            guard let object = value as? [String: Any], let kind = Read.text(object["kind"]) else { return nil }
            let payload = object["payload"] as? [String: Any] ?? [:]
            switch kind {
            case "addonCatalog": return addonCatalog(payload)
            case "traktList": return traktList(payload) ?? .unsupported(kind: kind)
            case "blusion.traktFeed": return traktFeed(payload) ?? .unsupported(kind: kind)
            case "blusion.tmdbDiscover": return tmdbDiscover(payload) ?? .unsupported(kind: kind)
            // Fusion's own TMDb kind. Its exports carry no filters, so the list is read from its title; a `query` written by Blusion wins.
            case "tmdbDiscover": return tmdbDiscover(payload) ?? .tmdbDiscover(TMDbDiscoverQuery.inferred(fromTitle: label))
            default: return .unsupported(kind: kind)
            }
        }

        mutating func addonCatalog(_ payload: [String: Any]) -> WidgetSource? {
            guard let identifier = Read.text(payload["catalogId"]) else { return nil }
            // `catalogId` is "<type>::<id>", split on the first "::". Without it, the whole string is the id.
            var catalogType = Read.text(payload["catalogType"])
            var catalogID = identifier
            if let range = identifier.range(of: "::") {
                let prefix = identifier[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty { catalogType = prefix }
                catalogID = String(identifier[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let type = catalogType, !catalogID.isEmpty else { return nil }
            let addon = addonIdentity(Read.text(payload["addonId"]))
            return .addonCatalog(AddonCatalogReference(manifestID: addon.manifestID, host: addon.host, catalogType: type,
                                                       catalogID: catalogID, genre: Read.text(payload["genre"])))
        }

        func traktList(_ payload: [String: Any]) -> WidgetSource? {
            guard let username = Read.text(payload["username"]), let slug = Read.text(payload["listSlug"]) else { return nil }
            return .traktList(TraktListReference(username: username, listSlug: slug, listName: Read.text(payload["listName"]) ?? slug,
                                                 traktID: Read.integer(payload["traktId"]),
                                                 sort: Read.text(payload["blusionSort"]).flatMap(TraktListSort.init(rawValue:)),
                                                 isPrivate: (payload["blusionPrivate"] as? Bool) == true ? true : nil))
        }

        /// A Trakt feed by its `feed` name. Blusion writes these; an unknown name is unsupported rather than guessed.
        func traktFeed(_ payload: [String: Any]) -> WidgetSource? {
            guard let name = Read.text(payload["feed"]), let feed = TraktFeed(rawValue: name) else { return nil }
            return .traktFeed(feed)
        }

        /// A TMDb discover list: the query as a JSON object under `query`. Anything else reads as unsupported.
        func tmdbDiscover(_ payload: [String: Any]) -> WidgetSource? {
            guard let object = payload["query"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: object),
                  let query = try? JSONDecoder().decode(TMDbDiscoverQuery.self, from: data) else { return nil }
            return .tmdbDiscover(query)
        }

        /// The manifest id and display host of an imported `addonId`; the widget keeps nothing else. A link to an addon that is not
        /// installed is also recorded in `missingLinks`, for the UI's install offer only.
        mutating func addonIdentity(_ text: String?) -> (manifestID: String?, host: String?) {
            guard let text else { return (nil, nil) }
            if text.hasPrefix("blusion:") {
                let manifestID = String(text.dropFirst("blusion:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !manifestID.isEmpty else { return (nil, nil) }
                return (manifestID, addons.first(where: { $0.manifest.id == manifestID })?.displayHost)
            }
            // Anything without a scheme, slash or dot is a placeholder such as `YOUR_AIOMETADATA`, not a link.
            guard Read.looksLikeLink(text), let location = try? AddonURLNormaliser.normalise(text) else { return (nil, nil) }
            if let installed = addons.first(where: { $0.manifestURL == location.manifestURL }) {
                return (installed.manifest.id, installed.displayHost)
            }
            let host = location.manifestURL.host ?? "unknown host"
            if !missingHosts.contains(host) { missingHosts.append(host) }
            if !missingLinks.contains(text) { missingLinks.append(text) }
            return (nil, host)
        }
    }

    /// Fail-soft readers for JSON values: numbers may arrive as strings, flags as text, and anything else is nil.
    private enum Read {
        static func text(_ value: Any?) -> String? {
            let raw: String
            switch value {
            case let string as String: raw = string
            case let number as NSNumber: raw = number.stringValue
            default: return nil
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        static func flag(_ value: Any?) -> Bool? {
            switch value {
            case let number as NSNumber:
                switch number.intValue {
                case 0: return false
                case 1: return true
                default: return nil
                }
            case let string as String:
                switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "yes", "1": return true
                case "false", "no", "0": return false
                default: return nil
                }
            default: return nil
            }
        }

        static func integer(_ value: Any?) -> Int? {
            switch value {
            case let number as NSNumber:
                return wholeNumber(number.doubleValue)
            case let string as String:
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if let whole = Int(trimmed) { return whole }
                return Double(trimmed).flatMap(wholeNumber)
            default: return nil
            }
        }

        private static func wholeNumber(_ value: Double) -> Int? {
            guard value.isFinite, abs(value) < 1e15 else { return nil }
            return Int(value)
        }

        static func aspectRatio(_ value: Any?) -> WidgetPresentation.AspectRatio? {
            guard let name = text(value)?.lowercased() else { return nil }
            switch name {
            case "poster": return .poster
            case "wide", "landscape": return .wide
            case "square": return .square
            default: return nil
            }
        }

        static func cardStyle(_ value: Any?) -> WidgetPresentation.CardStyle? {
            guard let name = text(value)?.lowercased() else { return nil }
            return WidgetPresentation.CardStyle(rawValue: name)
        }

        static func presentation(_ value: Any?) -> WidgetPresentation {
            let object = value as? [String: Any] ?? [:]
            let badges = object["badges"] as? [String: Any] ?? [:]
            return WidgetPresentation(aspectRatio: aspectRatio(object["aspectRatio"]) ?? .poster,
                                      cardStyle: cardStyle(object["cardStyle"]) ?? .medium,
                                      showsRatings: flag(badges["ratings"]) ?? true,
                                      showsProviders: flag(badges["providers"]) ?? false,
                                      usesBetterPosters: flag(object["blusionBetterPosters"]) ?? false)
        }

        static func httpURL(_ value: Any?) -> URL? {
            guard let text = text(value) else { return nil }
            return LenientURL.parse(text)
        }

        static func looksLikeLink(_ text: String) -> Bool {
            text.contains("://") || text.contains("/") || text.contains(".")
        }
    }

    // MARK: Encoding

    private static func encodeWidget(_ widget: HomeWidget) -> [String: Any] {
        var object: [String: Any] = ["id": widget.id, "title": widget.title, "hideTitle": widget.hideTitle]
        switch widget.content {
        case .row(let row):
            object["type"] = row.presentation.showsRank ? "row.classic.numbered" : "row.classic"
            encodeRow(row, into: &object)
        case .hero(let row):
            object["type"] = "blusion.hero"
            encodeRow(row, into: &object)
        case .banner(let row):
            object["type"] = "hero.banner"
            encodeRow(row, into: &object)
        case .unsupported(let type):
            object["type"] = type
        case .collection(let tiles):
            object["type"] = "collection.row"
            let payload: [String: Any] = ["items": tiles.map { encodeTile($0) }]
            object["dataSource"] = ["kind": "collection", "payload": payload] as [String: Any]
        case .continueWatching:
            object["type"] = "blusion.continueWatching"
        }
        return object
    }

    private static func encodeRow(_ row: RowConfiguration, into object: inout [String: Any]) {
        let badges: [String: Any] = ["providers": row.presentation.showsProviders, "ratings": row.presentation.showsRatings]
        var presentation: [String: Any] = [
            "aspectRatio": row.presentation.aspectRatio.rawValue,
            "cardStyle": row.presentation.cardStyle.rawValue,
            "badges": badges,
        ]
        // Blusion's own key, written only when it is on: Fusion ignores it, and a file without it reads as off.
        if row.presentation.usesBetterPosters { presentation["blusionBetterPosters"] = true }
        object["limit"] = row.limit
        object["cacheTTL"] = row.cacheTTL
        object["presentation"] = presentation
        object["dataSource"] = encodeSource(row.source)
    }

    private static func encodeTile(_ tile: CollectionItem) -> [String: Any] {
        var object: [String: Any] = [
            "id": tile.id,
            "title": tile.title,
            "hideTitle": tile.hideTitle,
            "imageAspect": tile.imageAspect.rawValue,
            "dataSources": tile.sources.map { encodeSource($0) },
        ]
        if let imageURL = tile.imageURL { object["imageURL"] = imageURL.absoluteString }
        return object
    }

    /// The addon's URL is never written: the id is `blusion:<manifestID>`, or a placeholder when the addon is not known.
    private static func encodeSource(_ source: WidgetSource) -> [String: Any] {
        switch source {
        case .addonCatalog(let reference):
            var payload: [String: Any] = [
                "addonId": reference.manifestID.map { "blusion:\($0)" } ?? "YOUR_ADDON",
                "catalogId": "\(reference.catalogType)::\(reference.catalogID)",
                "catalogType": reference.catalogType,
            ]
            if let genre = reference.genre { payload["genre"] = genre }
            return ["kind": "addonCatalog", "payload": payload]
        case .traktList(let list):
            var payload: [String: Any] = ["listName": list.listName, "listSlug": list.listSlug, "username": list.username]
            if let traktID = list.traktID {
                payload["traktId"] = traktID
            } else {
                payload["traktId"] = NSNull()
            }
            // Blusion's own keys: Fusion ignores them, and a file without them reads as the list's own order, public.
            if let sort = list.sort { payload["blusionSort"] = sort.rawValue }
            if list.needsAccount { payload["blusionPrivate"] = true }
            return ["kind": "traktList", "payload": payload]
        case .traktFeed(let feed):
            return ["kind": "blusion.traktFeed", "payload": ["feed": feed.rawValue]]
        case .tmdbDiscover(let query):
            var payload: [String: Any] = [:]
            if let object = queryObject(query) { payload["query"] = object }
            return ["kind": "blusion.tmdbDiscover", "payload": payload]
        case .unsupported(let kind):
            return ["kind": kind, "payload": [String: Any]()]
        }
    }

    /// The query as a JSON object, or nil when it cannot be encoded.
    private static func queryObject(_ query: TMDbDiscoverQuery) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(query) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
