import Foundation
import Observation
import StremioKit

/// Discover: pick a catalog and genre, scroll, and `skip`-paginate.
@MainActor
@Observable
public final class DiscoverViewModel {
    public enum State: Equatable {
        case idle
        case loadingFirstPage
        case loaded
        case loadingMore
        case failed(AddonError)
    }

    public private(set) var sources: [CatalogSource] = []
    public private(set) var selectedSource: CatalogSource?
    /// The content type of `selectedSource`; nil until a source is selected.
    public private(set) var selectedType: String?
    public private(set) var selectedGenre: String?
    /// True when the type control is on "All": the catalog menu then lists the sources of every type.
    public private(set) var showsAllTypes = false
    public private(set) var items: [MetaPreview] = []
    public private(set) var state: State = .idle
    public private(set) var canLoadMore = false
    public var isOffline: Bool { state == .failed(.offline) }
    /// The release-year span the Year menu chose, inclusive bounds. Titles outside it are hidden from `visibleItems`; nothing is fetched again.
    public var minimumYear: Int?
    public var maximumYear: Int?

    /// The year span as a filter chip words it, the same as the Library's chips ("1990–1999"); nil when no span is set.
    public var yearSpanLabel: String? {
        switch (minimumYear, maximumYear) {
        case let (low?, high?): low == high ? "\(low)" : "\(low)–\(high)"
        case let (low?, nil): "From \(low)"
        case let (nil, high?): "Until \(high)"
        case (nil, nil): nil
        }
    }

    /// One catalog feeding the "All" mix, with how far it has been read.
    private struct Cursor {
        var source: CatalogSource
        var received = 0
        var hasMore = true
    }

    private let services: AppServices
    private var cursors: [Cursor] = []
    private var generation = 0
    /// Raw items received so far: the protocol's `skip` counts items the addon sent, not items left after de-duplication.
    private var receivedCount = 0

    public init(services: AppServices) {
        self.services = services
    }

    public var genres: [String] {
        guard showsAllTypes else { return selectedSource?.catalog.genreOptions ?? [] }
        var all: [String] = []
        for genre in mixSources.flatMap(\.catalog.genreOptions) where !all.contains(genre) { all.append(genre) }
        return all
    }
    public var hasSources: Bool { !sources.isEmpty }

    /// The loaded titles inside the year span, in catalogue order. As in the Library, a title with no known year is hidden while a span is set.
    public var visibleItems: [MetaPreview] {
        guard minimumYear != nil || maximumYear != nil else { return items }
        return items.filter { item in
            guard let year = LibraryFiltering.year(from: item.releaseInfo) else { return false }
            if let minimumYear, year < minimumYear { return false }
            if let maximumYear, year > maximumYear { return false }
            return true
        }
    }

    /// Distinct content types of `sources`: by `ContentTypeName.sortRank`, then by first appearance.
    public var types: [String] {
        var order: [String] = []
        for source in sources where !order.contains(source.type) { order.append(source.type) }
        return order.enumerated().sorted { lhs, rhs in
            let (left, right) = (ContentTypeName.sortRank(lhs.element), ContentTypeName.sortRank(rhs.element))
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The catalogs the "All" mix reads: the selected one and its counterpart of the other type (same addon and name when there is
    /// one, else the same name, else the type's first catalog), movies first.
    var mixSources: [CatalogSource] {
        guard let selected = selectedSource else { return [] }
        return ["movie", "series"].compactMap { type in
            if selected.type.lowercased() == type { return selected }
            let ofType = sources.filter { $0.type.lowercased() == type }
            let name = selected.title.lowercased()
            return ofType.first { $0.addon.id == selected.addon.id && $0.title.lowercased() == name }
                ?? ofType.first { $0.title.lowercased() == name }
                ?? ofType.first
        }
    }

    /// The sources of the selected type; on "All" the movie catalogs (each one brings its series counterpart); every source when no
    /// type is selected.
    public var visibleSources: [CatalogSource] {
        if showsAllTypes {
            let movies = sources.filter { $0.type.lowercased() == "movie" }
            return movies.isEmpty ? sources : movies
        }
        guard let selectedType else { return sources }
        return sources.filter { $0.type == selectedType }
    }

    /// Refreshes the catalog list, keeping the current selection when it still exists.
    /// Otherwise the first type (by `types`) and its first source are selected.
    public func loadSources() async {
        sources = await services.browse.catalogSources()
        if let current = selectedSource, sources.contains(current) { return }
        guard let type = types.first, let first = sources.first(where: { $0.type == type }) else {
            selectedSource = nil
            selectedType = nil
            items = []
            state = .idle
            return
        }
        await select(source: first)
    }

    /// Switches to a content type: selects that type's first source and reloads. Unknown types change nothing.
    public func select(type: String) async {
        showsAllTypes = false
        guard let first = sources.first(where: { $0.type == type }) else { return }
        await select(source: first)
    }

    /// Switches to "All": movies and series of the selected catalog, mixed into one grid.
    public func selectAllTypes() async {
        showsAllTypes = true
        if let selected = selectedSource, selected.type.lowercased() != "movie",
           let movie = sources.first(where: { $0.type.lowercased() == "movie" && $0.title.lowercased() == selected.title.lowercased() }) {
            selectedSource = movie
            selectedType = movie.type
        } else if selectedSource == nil, let first = sources.first {
            selectedSource = first
            selectedType = first.type
        }
        if let genre = selectedGenre, !genres.contains(genre) { selectedGenre = nil }
        await reload()
    }

    public func select(source: CatalogSource) async {
        selectedSource = source
        selectedType = source.type
        if let genre = selectedGenre, !source.catalog.genreOptions.contains(genre) { selectedGenre = nil }
        await reload()
    }

    /// `nil` clears the filter.
    public func select(genre: String?) async {
        selectedGenre = genre
        await reload()
    }

    public func reload() async {
        guard let source = selectedSource else { return }
        generation += 1
        let current = generation
        items = []
        receivedCount = 0
        canLoadMore = false
        state = .loadingFirstPage
        if showsAllTypes {
            cursors = mixSources.map { mixed in
                Cursor(source: mixed, hasMore: selectedGenre.map { mixed.catalog.genreOptions.contains($0) } ?? true)
            }
            await loadMixedPage(generation: current)
            return
        }
        do {
            let page = try await services.browse.page(source, genre: selectedGenre, skip: 0)
            guard current == generation else { return }
            append(page, source: source)
            state = .loaded
        } catch {
            guard current == generation else { return }
            state = .failed(AddonError.from(error))
        }
    }

    /// Call when the last item scrolls into view. Does nothing while a load is running or after an empty page.
    public func loadMore() async {
        guard canLoadMore, state == .loaded, let source = selectedSource else { return }
        let current = generation
        state = .loadingMore
        if showsAllTypes {
            await loadMixedPage(generation: current)
            return
        }
        do {
            let page = try await services.browse.page(source, genre: selectedGenre, skip: receivedCount)
            guard current == generation else { return }
            append(page, source: source)
            state = .loaded
        } catch {
            guard current == generation else { return }
            // Keep what we have; the user can scroll again to retry.
            state = .loaded
        }
    }

    /// Reads the next page of every catalog in the mix at once and interleaves them (movie, series, movie, ...), so neither type
    /// buries the other. A catalog that fails is skipped; the mix only fails when none answers.
    private func loadMixedPage(generation current: Int) async {
        let browse = services.browse
        let genre = selectedGenre
        let pending = cursors.enumerated().filter(\.element.hasMore)
        var pages: [Int: [MetaPreview]] = [:]
        var failure: Error?
        await withTaskGroup(of: (Int, [MetaPreview]?, Error?).self) { group in
            for (index, cursor) in pending {
                group.addTask {
                    do { return (index, try await browse.page(cursor.source, genre: genre, skip: cursor.received), nil) } catch { return (index, nil, error) }
                }
            }
            for await (index, page, error) in group {
                if let page { pages[index] = page } else { failure = error }
            }
        }
        guard current == generation else { return }
        if pages.isEmpty, let failure, !pending.isEmpty {
            state = items.isEmpty ? .failed(AddonError.from(failure)) : .loaded
            return
        }
        for (index, page) in pages {
            cursors[index].received += page.count
            cursors[index].hasMore = !page.isEmpty && cursors[index].source.catalog.supportsSkip
        }
        var known = Set(items.map(\.id))
        let ordered = pages.keys.sorted().map { pages[$0] ?? [] }
        for position in 0..<(ordered.map(\.count).max() ?? 0) {
            for page in ordered where position < page.count && known.insert(page[position].id).inserted { items.append(page[position]) }
        }
        canLoadMore = cursors.contains(where: \.hasMore)
        state = .loaded
    }

    private func append(_ page: [MetaPreview], source: CatalogSource) {
        receivedCount += page.count
        let known = Set(items.map(\.id))
        items.append(contentsOf: page.filter { !known.contains($0.id) })
        canLoadMore = !page.isEmpty && source.catalog.supportsSkip
    }
}
