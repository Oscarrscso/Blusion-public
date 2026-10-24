import Foundation
import StremioKit

/// The rows of a title page's Information, each a label and a value: its release (a series' first and last air dates), runtime, genres,
/// director or creators and writers, studios and a series' network, countries, original language and title, a series' seasons and status,
/// budget and box office, age rating, and the average of its ratings. Blank rows are left out.
public enum TitleInformation {
    public struct Row: Equatable, Sendable {
        public let label: String
        public let value: String
    }

    /// The rows in order, without the blank ones.
    public static func rows(detail: MetaDetail, facts: TMDbTitleFacts?, certification: String?, averageRating: String?) -> [Row] {
        let isSeries = detail.type == "series"
        let preview = detail.preview
        var rows: [(String, String?)] = []
        if isSeries, let first = date(facts?.firstAired) {
            rows.append(("First aired", first))
            // A series still running has no last air date worth showing as its end.
            if facts?.status != "Returning Series" { rows.append(("Last aired", date(facts?.lastAired))) }
        } else {
            // The addon's own text, a year or a range of years, when TMDb has no date.
            rows.append(("Released", date(facts?.releaseDate) ?? preview.releaseInfo))
        }
        rows.append(("Runtime", preview.runtime))
        rows.append(("Genres", preview.genres.joined(separator: ", ")))
        rows.append(("Director", detail.director.joined(separator: ", ")))
        rows.append((plural("Creator", facts?.creators.count ?? 0), list(facts?.creators)))
        rows.append(("Writers", detail.writers.joined(separator: ", ")))
        rows.append((plural("Studio", facts?.studios.count ?? 0), list(facts?.studios)))
        rows.append((plural("Network", facts?.networks.count ?? 0), list(facts?.networks)))
        rows.append((plural("Country", facts?.countries.count ?? 0, plural: "Countries"), list(facts?.countries)))
        rows.append(("Original language", facts?.originalLanguage))
        rows.append(("Original title", facts?.originalTitle))
        if isSeries { rows.append(("Seasons", seasons(facts))) }
        // A movie's status is worth a line only before it is out ("In Production", "Post Production").
        if isSeries || facts?.status != "Released" { rows.append(("Status", facts?.status)) }
        rows.append(("Budget", money(facts?.budget)))
        rows.append(("Box office", money(facts?.revenue)))
        rows.append(("Age rating", certification))
        rows.append(("Average rating", averageRating))
        return rows.compactMap { label, value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return Row(label: label, value: value)
        }
    }

    /// Up to three names, comma separated.
    private static func list(_ names: [String]?) -> String? {
        names.map { $0.prefix(3).joined(separator: ", ") }
    }

    private static func plural(_ word: String, _ count: Int, plural: String? = nil) -> String {
        count > 1 ? (plural ?? word + "s") : word
    }

    /// "3 seasons, 24 episodes", or whichever of the two TMDb has.
    private static func seasons(_ facts: TMDbTitleFacts?) -> String? {
        let parts = [facts?.seasonCount.map { $0 == 1 ? "1 season" : "\($0) seasons" },
                     facts?.episodeCount.map { $0 == 1 ? "1 episode" : "\($0) episodes" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// US dollars in short: "$160M", "$1.2B".
    private static func money(_ dollars: Int?) -> String? {
        guard let dollars else { return nil }
        let value = Double(dollars)
        // A unit is used from the value that rounds up to it, so $999.95M reads $1B rather than $1,000M.
        let units: [(size: Double, name: String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        let unit = units.first { value >= $0.size * 0.99995 }
        let scaled = unit.map { value / $0.size } ?? value
        return "$" + scaled.formatted(.number.precision(.fractionLength(0...1))) + (unit?.name ?? "")
    }

    /// A "yyyy-MM-dd" date as the device writes dates ("16 Jul 2010"); nil when it is not one.
    private static func date(_ text: String?) -> String? {
        guard let text, let day = try? Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().parse(text) else { return nil }
        return day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
    }
}
