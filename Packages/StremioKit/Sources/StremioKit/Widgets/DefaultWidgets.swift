import Foundation

/// The Home layout for a user who never customised it. It is built from the browsable catalogs of the enabled addons, in the user's
/// order. Ids are deterministic, so the layout is the same from one launch to the next.
public enum DefaultWidgets {
    public static func make(for addons: [InstalledAddon], maxRows: Int = 14) -> [HomeWidget] {
        let entries = considered(addons)
        guard let first = entries.first else { return [] }
        let spotlight = entries.first { $0.catalog.type == "movie" } ?? first
        var rows = entries.prefix(max(maxRows, 0)).map { rowWidget($0) }
        if let genres = genreWidget(entries) {
            // Right after the second row; at the end when there are fewer than two.
            rows.insert(genres, at: min(2, rows.count))
        }
        let hero = HomeWidget(id: "auto.hero", title: "Spotlight", hideTitle: true,
                              content: .hero(RowConfiguration(source: .addonCatalog(spotlight.reference()), limit: 8)))
        let continueWatching = HomeWidget(id: HomeLayout.continueWatchingID, title: "Continue", content: .continueWatching)
        return [hero, continueWatching] + rows
    }

    /// "Popular" + "movie" -> "Popular Movies". A name that already contains the type word (any case) is left alone ("Netflix Movies").
    public static func rowTitle(catalogName: String, type: String) -> String {
        let name = catalogName.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = typeWord(type)
        guard !word.isEmpty else { return name }
        guard !name.isEmpty else { return word }
        if name.lowercased().contains(word.lowercased()) { return name }
        return "\(name) \(word)"
    }

    private static func typeWord(_ type: String) -> String {
        switch type.lowercased() {
        case "movie": return "Movies"
        case "series": return "Series"
        case "tv": return "Live TV"
        case "channel": return "Channels"
        case "anime": return "Anime"
        default: return type.prefix(1).uppercased() + type.dropFirst()
        }
    }

    /// A catalog of an enabled addon that a row can show. Two addons with the same manifest id offer the same catalogs,
    /// so only the first one (the one a reference resolves to) is used.
    private struct Entry {
        let addon: InstalledAddon
        let catalog: CatalogDescriptor

        var rowID: String { "auto.row.\(addon.manifest.id).\(catalog.type).\(catalog.id)" }

        func reference(genre: String? = nil) -> AddonCatalogReference {
            AddonCatalogReference(manifestID: addon.manifest.id, host: addon.displayHost, catalogType: catalog.type, catalogID: catalog.id, genre: genre)
        }
    }

    private static func considered(_ addons: [InstalledAddon]) -> [Entry] {
        var seen = Set<String>()
        var entries: [Entry] = []
        for addon in addons where addon.isEnabled {
            for catalog in addon.manifest.catalogs where catalog.isBrowsable {
                let entry = Entry(addon: addon, catalog: catalog)
                if seen.insert(entry.rowID).inserted { entries.append(entry) }
            }
        }
        return entries
    }

    private static func rowWidget(_ entry: Entry) -> HomeWidget {
        HomeWidget(id: entry.rowID,
                   title: rowTitle(catalogName: entry.catalog.name, type: entry.catalog.type),
                   content: .row(RowConfiguration(source: .addonCatalog(entry.reference()), limit: 20)))
    }

    /// Browse-by-genre tiles from the first catalog that offers at least four genres: one tile per genre, the first twelve.
    private static func genreWidget(_ entries: [Entry]) -> HomeWidget? {
        for entry in entries {
            var seen = Set<String>()
            let genres = entry.catalog.genreOptions.filter { seen.insert($0).inserted }
            guard genres.count >= 4 else { continue }
            let tiles = genres.prefix(12).map { genre in
                CollectionItem(id: "auto.genre.\(genre)", title: genre, hideTitle: false, imageAspect: .wide, imageURL: nil,
                               sources: [.addonCatalog(entry.reference(genre: genre))])
            }
            return HomeWidget(id: "auto.genres", title: "Browse by Genre", content: .collection(Array(tiles)))
        }
        return nil
    }
}
