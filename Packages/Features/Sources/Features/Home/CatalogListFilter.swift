import Foundation
import StremioKit

/// How the grid behind "See All" orders what it has loaded. `original` keeps the source's own order.
public enum CatalogListSort: String, CaseIterable, Identifiable, Sendable, Codable {
    case original
    case rating
    case newest
    case oldest
    case title
    case shuffle

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: "Default"
        case .rating: "Top Rated"
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .title: "A–Z"
        case .shuffle: "Shuffle"
        }
    }

    public var systemImage: String {
        switch self {
        case .original: "list.bullet"
        case .rating: "star"
        case .newest: "arrow.down"
        case .oldest: "arrow.up"
        case .title: "textformat"
        case .shuffle: "shuffle"
        }
    }
}

/// A release window offered above the decades: the last few years, counted back from this one.
public enum CatalogListRecent: Int, CaseIterable, Identifiable, Sendable {
    case thisYear = 0
    case lastFive = 4
    case lastTen = 9

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .thisYear: "This Year"
        case .lastFive: "Last 5 Years"
        case .lastTen: "Last 10 Years"
        }
    }

    public func years(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Int> {
        let year = calendar.component(.year, from: now)
        return (year - rawValue)...year
    }
}

/// What the grid behind "See All" shows of what it has loaded: its order, and the type, release years and rating it is narrowed to. Every
/// choice works on the loaded titles, so it applies to any source, addon, TMDB or Trakt alike.
public struct CatalogListFilter: Equatable, Sendable {
    public var sort: CatalogListSort = .original
    /// "movie" or "series"; nil shows both.
    public var type: String?
    public var minimumYear: Int?
    public var maximumYear: Int?
    /// Out of 10, against the IMDb rating the source sent.
    public var minimumRating: Double?

    public init(sort: CatalogListSort = .original, type: String? = nil, minimumYear: Int? = nil, maximumYear: Int? = nil,
                minimumRating: Double? = nil) {
        self.sort = sort
        self.type = type
        self.minimumYear = minimumYear
        self.maximumYear = maximumYear
        self.minimumRating = minimumRating
    }

    /// A narrowing choice is on. The order is not a filter: it never hides a title.
    public var isFiltering: Bool { type != nil || minimumYear != nil || maximumYear != nil || minimumRating != nil }

    public mutating func clearFilters() {
        type = nil
        minimumYear = nil
        maximumYear = nil
        minimumRating = nil
    }

    /// The release window's label for its menu, or nil when any year shows.
    public func yearLabel(now: Date = Date(), calendar: Calendar = .current) -> String? {
        for recent in CatalogListRecent.allCases {
            let range = recent.years(now: now, calendar: calendar)
            if minimumYear == range.lowerBound, maximumYear == range.upperBound { return recent.title }
        }
        switch (minimumYear, maximumYear) {
        case let (low?, high?) where high == low + 9 && low % 10 == 0: return "\(low)s"
        case let (low?, high?): return low == high ? "\(low)" : "\(low)–\(high)"
        case let (low?, nil): return "From \(low)"
        case let (nil, high?): return "Until \(high)"
        case (nil, nil): return nil
        }
    }
}

/// Pure functions behind the grid's filter, so they can be tested without a view or a source.
public enum CatalogListFiltering {
    public static func matches(_ item: MetaPreview, _ filter: CatalogListFilter) -> Bool {
        if let type = filter.type, item.type.lowercased() != type { return false }
        if filter.minimumYear != nil || filter.maximumYear != nil {
            guard let year = LibraryFiltering.year(from: item.releaseInfo) else { return false }
            if let low = filter.minimumYear, year < low { return false }
            if let high = filter.maximumYear, year > high { return false }
        }
        if let minimum = filter.minimumRating {
            guard let rating = item.imdbRating, rating >= minimum else { return false }
        }
        return true
    }

    /// The items that pass the filter, in its order. `shuffleRank` places each item when the order is Shuffle; an item it has no rank for
    /// goes after the ranked ones, in loaded order. Titles missing what an order needs (a rating, a year) go last, in loaded order.
    public static func apply(_ filter: CatalogListFilter, to items: [MetaPreview], shuffleRank: [String: Int] = [:]) -> [MetaPreview] {
        let kept = items.enumerated().filter { matches($0.element, filter) }
        let ordered: [(offset: Int, element: MetaPreview)]
        switch filter.sort {
        case .original:
            ordered = kept
        case .rating:
            ordered = kept.sorted { compare($0.element.imdbRating, $1.element.imdbRating, descending: true) ?? ($0.offset < $1.offset) }
        case .newest:
            ordered = kept.sorted { compare(year($0.element), year($1.element), descending: true) ?? ($0.offset < $1.offset) }
        case .oldest:
            ordered = kept.sorted { compare(year($0.element), year($1.element), descending: false) ?? ($0.offset < $1.offset) }
        case .title:
            ordered = kept.sorted {
                let order = $0.element.name.localizedStandardCompare($1.element.name)
                return order == .orderedSame ? $0.offset < $1.offset : order == .orderedAscending
            }
        case .shuffle:
            ordered = kept.sorted {
                let left = shuffleRank[$0.element.identity] ?? Int.max, right = shuffleRank[$1.element.identity] ?? Int.max
                return left == right ? $0.offset < $1.offset : left < right
            }
        }
        return ordered.map(\.element)
    }

    /// Fresh shuffle ranks for `items`, numbered from `start`.
    public static func shuffleRanks<G: RandomNumberGenerator>(for items: [MetaPreview], from start: Int = 0,
                                                              using generator: inout G) -> [String: Int] {
        var ranks: [String: Int] = [:]
        for (index, item) in items.shuffled(using: &generator).enumerated() { ranks[item.identity] = start + index }
        return ranks
    }

    private static func year(_ item: MetaPreview) -> Int? { LibraryFiltering.year(from: item.releaseInfo) }

    /// Nil when the two tie, so the caller keeps loaded order. A missing value sorts after any present one.
    private static func compare<T: Comparable>(_ left: T?, _ right: T?, descending: Bool) -> Bool? {
        switch (left, right) {
        case let (l?, r?): return l == r ? nil : (descending ? l > r : l < r)
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return nil
        }
    }
}
