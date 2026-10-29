import Foundation
import StremioKit

/// Where a download stands, for the Downloads page's status menu. Queued transfers count as downloading.
public enum DownloadStatusFilter: String, CaseIterable, Sendable, Identifiable {
    case all, downloaded, downloading, paused, failed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All"
        case .downloaded: "Downloaded"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .failed: "Failed"
        }
    }

    public func matches(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: true
        case .downloaded: item.state == .complete
        case .downloading: item.state == .downloading || item.state == .queued
        case .paused: item.state == .paused
        case .failed: item.state == .failed
        }
    }
}

public enum DownloadSort: String, CaseIterable, Sendable, Identifiable {
    case recentlyAdded, title, year

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .recentlyAdded: "Recently added"
        case .title: "Title"
        case .year: "Year"
        }
    }
}

/// One active filter on the Downloads page, as a chip. `target` is what removing it clears.
public struct DownloadFilterChip: Identifiable, Equatable, Sendable {
    public enum Target: Equatable, Sendable { case status, years }

    public let target: Target
    public let label: String

    public var id: String {
        switch target {
        case .status: "status"
        case .years: "years"
        }
    }
}

/// The Downloads page's filters and sort. It is kept apart from the Library's `LibraryFilter`, so each page keeps its own selection.
public struct DownloadFilter: Equatable, Sendable {
    public var status: DownloadStatusFilter = .all
    /// Inclusive bounds on the release year. A download with no known year is excluded while either bound is set.
    public var minimumYear: Int?
    public var maximumYear: Int?
    public var sort: DownloadSort = .recentlyAdded

    public init() {}

    /// Removes every filter and keeps the sort.
    public mutating func clearFilters() {
        status = .all
        minimumYear = nil
        maximumYear = nil
    }

    public mutating func remove(_ target: DownloadFilterChip.Target) {
        switch target {
        case .status: status = .all
        case .years:
            minimumYear = nil
            maximumYear = nil
        }
    }

    /// One chip per active filter: the status, then the year span.
    public var chips: [DownloadFilterChip] {
        var chips: [DownloadFilterChip] = []
        if status != .all { chips.append(DownloadFilterChip(target: .status, label: status.title)) }
        if minimumYear != nil || maximumYear != nil {
            chips.append(DownloadFilterChip(target: .years, label: LibraryFiltering.yearSpanLabel(from: minimumYear, to: maximumYear)))
        }
        return chips
    }
}

/// Pure functions behind the Downloads page's filter and sort, so they can be tested without a view.
public enum DownloadFiltering {
    /// The year a download's title was released in, from the request's release string.
    public static func year(of item: DownloadItem) -> Int? {
        LibraryFiltering.year(from: item.request.year)
    }

    public static func apply(_ filter: DownloadFilter, to items: [DownloadItem]) -> [DownloadItem] {
        sorted(items.filter { matches($0, filter) }, by: filter.sort)
    }

    public static func matches(_ item: DownloadItem, _ filter: DownloadFilter) -> Bool {
        guard filter.status.matches(item) else { return false }
        if filter.minimumYear != nil || filter.maximumYear != nil {
            guard let released = year(of: item) else { return false }
            if let low = filter.minimumYear, released < low { return false }
            if let high = filter.maximumYear, released > high { return false }
        }
        return true
    }

    /// Sorts by one key. Titles group an episodes' show together in episode order; a missing year sorts last.
    public static func sorted(_ items: [DownloadItem], by sort: DownloadSort) -> [DownloadItem] {
        items.sorted { lhs, rhs in
            switch sort {
            case .recentlyAdded:
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            case .year:
                let (left, right) = (year(of: lhs) ?? Int.min, year(of: rhs) ?? Int.min)
                if left != right { return left > right }
            case .title:
                break
            }
            let byTitle = lhs.request.title.localizedStandardCompare(rhs.request.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            let (leftSeason, rightSeason) = (lhs.request.season ?? 0, rhs.request.season ?? 0)
            if leftSeason != rightSeason { return leftSeason < rightSeason }
            let (leftEpisode, rightEpisode) = (lhs.request.episode ?? 0, rhs.request.episode ?? 0)
            if leftEpisode != rightEpisode { return leftEpisode < rightEpisode }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
