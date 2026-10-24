import Foundation
import PlayerKit
import StremioKit

/// One card in the Library's Watched section. A movie has a card of its own. A show has one card for all of its watched episodes,
/// named for the show and showing its latest episode, so its poster is not repeated for every episode watched.
public struct WatchedCard: Identifiable, Equatable, Sendable {
    /// `movie/tt1` or `series/tt1`: the title's identity, shared by every watched record of it.
    public let id: String
    /// The title as the card names it and opens it: a show's name and poster, not an episode's.
    public let preview: MetaPreview
    /// The most recently watched record of the title: the movie, or a show's latest episode.
    public let latest: WatchProgress
    /// Every watched record of the title, most recently watched first. A movie has one.
    public let watched: [WatchProgress]

    public var isShow: Bool { latest.type == "series" }

    /// How many records of the title are watched: a show's episodes, or 1 for a movie.
    public var watchedCount: Int { watched.count }

    /// "S2E5 · Episode title" for a show's latest episode. Nil for a movie.
    public var episodeLine: String? {
        guard isShow else { return nil }
        var parts: [String] = []
        if let season = latest.season, let episode = latest.episode { parts.append("S\(season)E\(episode)") }
        if let name = WatchedCards.episodeName(in: latest.title) { parts.append(name) }
        return parts.isEmpty ? nil : parts.joined(separator: WatchedCards.separator)
    }
}

/// Groups the Library's watched records into its Watched cards. Pure, so the grouping can be tested without a view or a store.
public enum WatchedCards {
    /// The cards for the watched entries a filter kept. A card takes the place of its title's first entry, so the cards keep the
    /// order the filter sorted the entries in.
    public static func cards(from entries: [LibraryEntry]) -> [WatchedCard] {
        var keys: [String] = []
        var records: [String: [WatchProgress]] = [:]
        var saved: [String: LibraryItem] = [:]
        for entry in entries {
            guard let record = entry.progress else { continue }
            let key = titleKey(of: record)
            if records[key] == nil { keys.append(key) }
            records[key, default: []].append(record)
            saved[key] = saved[key] ?? entry.item
        }
        return keys.compactMap { key in
            guard let watched = records[key]?.sorted(by: { $0.updatedAt > $1.updatedAt }), let latest = watched.first else { return nil }
            return WatchedCard(id: key, preview: preview(of: latest, saved: saved[key]), latest: latest, watched: watched)
        }
    }

    /// The name a record is known by: a show's name for an episode, the record's own title for anything else.
    static func name(of record: WatchProgress) -> String {
        record.type == "series" ? showName(in: record.title) : record.title
    }

    /// The show or movie a record belongs to: `movie/tt1`, or `series/tt1` for every episode of the show.
    static func titleKey(of record: WatchProgress) -> String {
        LibraryItem.identity(type: record.type, contentID: record.seriesID ?? record.contentID)
    }

    /// A show's name, from an episode's title, which is "Show · Episode" (see `StreamRequest(episode:of:)`). The whole title when it has no
    /// separator.
    static func showName(in title: String) -> String {
        title.components(separatedBy: separator).first ?? title
    }

    /// An episode's name, from a title "Show · Episode". Nil when the title has none.
    static func episodeName(in title: String) -> String? {
        let parts = title.components(separatedBy: separator)
        guard parts.count > 1 else { return nil }
        let name = parts.dropFirst().joined(separator: separator)
        return name.isEmpty ? nil : name
    }

    /// The separator between a show's name and an episode's, and between the parts of an episode line.
    static let separator = " · "

    /// The saved title's preview when there is one, so the card names and opens the title as the rest of the Library does.
    private static func preview(of latest: WatchProgress, saved: LibraryItem?) -> MetaPreview {
        if let saved { return saved.preview }
        return MetaPreview(id: latest.seriesID ?? latest.contentID, type: latest.type, name: name(of: latest), poster: latest.poster)
    }
}
