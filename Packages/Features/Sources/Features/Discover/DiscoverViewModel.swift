import Foundation
import Observation
import StremioKit

/// Discover: combine every installed catalog, filter and sort titles, and paginate each source.
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
    /// Nil combines all content types.
    public private(set) var selectedType: String?
    public private(set) var selectedGenre: String?
    public var showsAllTypes: Bool { selectedType == nil }
    public private(set) var items: [MetaPreview] = []
    public private(set) var state: State = .idle
    public private(set) var canLoadMore = false
    public var isOffline: Bool { state == .failed(.offline) }
    public var sort: CatalogListSort = .original
    public var minimumRating: Double?

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

    public init(services: AppServices) {
        self.services = services
    }

    public var genres: [String] {
        var all: [String] = []
        for genre in visibleSources.flatMap(\.catalog.genreOptions) where !all.contains(genre) { all.append(genre) }
        return all
    }
    public var hasSources: Bool { !sources.isEmpty }

    /// Sort and filter the loaded titles using the same rules as a catalog's See All page.
    public var visibleItems: [MetaPreview] {
        CatalogListFiltering.apply(CatalogListFilter(sort: sort, minimumYear: minimumYear,
                                                    maximumYear: maximumYear, minimumRating: minimumRating), to: items)
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

    /// Every catalog of the selected type, or every installed catalog on All.
    public var visibleSources: [CatalogSource] {
        guard let selectedType else { return sources }
        return sources.filter { $0.type == selectedType }
    }

    public func loadSources() async {
        let refreshed = await services.browse.catalogSources()
        guard !Task.isCancelled else { return }
        let changed = refreshed != sources
        sources = refreshed
        if let selectedType, !types.contains(selectedType) { self.selectedType = nil }
        if let genre = selectedGenre, !genres.contains(genre) { selectedGenre = nil }
        if changed || state == .idle || state == .loadingFirstPage { await reload() }
    }

    /// Type choices narrow the catalogs being combined; they never select an individual catalog.
    public func select(type: String) async {
        guard types.contains(type) else { return }
        selectedType = type
        if let genre = selectedGenre, !genres.contains(genre) { selectedGenre = nil }
        await reload()
    }

    public func selectAllTypes() async {
        selectedType = nil
        await reload()
    }

    /// `nil` clears the filter.
    public func select(genre: String?) async {
        selectedGenre = genre
        await reload()
    }

    public func reload() async {
        guard !Task.isCancelled else { return }
        generation += 1
        let current = generation
        items = []
        canLoadMore = false
        cursors = visibleSources.map { source in
            Cursor(source: source, hasMore: selectedGenre.map { genre in
                source.catalog.genreOptions.isEmpty || source.catalog.genreOptions.contains(genre)
            } ?? true)
        }
        guard !sources.isEmpty else {
            state = .idle
            return
        }
        state = .loadingFirstPage
        await loadMixedPage(generation: current)
    }

    /// Each catalog keeps its own raw skip count, independently of duplicate or filtered titles.
    public func loadMore() async {
        guard canLoadMore, state == .loaded else { return }
        let current = generation
        state = .loadingMore
        await loadMixedPage(generation: current)
    }

    /// Reads a page from every catalog and interleaves their titles, removing duplicates across sources. A catalog that fails is skipped; the mix only fails when none answers.
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
            let error = AddonError.from(failure)
            if Task.isCancelled || error == .cancelled {
                state = items.isEmpty ? .idle : .loaded
            } else {
                state = items.isEmpty ? .failed(error) : .loaded
            }
            return
        }
        for (index, page) in pages {
            cursors[index].received += page.count
            cursors[index].hasMore = !page.isEmpty && cursors[index].source.catalog.supportsSkip
        }
        var known = Set(items.map(\.identity))
        let ordered = pages.keys.sorted().map { index in
            let page = pages[index] ?? []
            // Addons without a genre parameter are filtered locally; skip still counts the complete page above.
            guard let genre, cursors[index].source.catalog.extra(named: "genre") == nil else { return page }
            return page.filter { $0.genres.contains { $0.localizedCaseInsensitiveCompare(genre) == .orderedSame } }
        }
        for position in 0..<(ordered.map(\.count).max() ?? 0) {
            for page in ordered where position < page.count && known.insert(page[position].identity).inserted { items.append(page[position]) }
        }
        canLoadMore = cursors.contains(where: \.hasMore)
        state = .loaded
    }

}
