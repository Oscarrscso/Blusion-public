import Foundation
import Observation
import StremioKit

/// What a grid screen shows: a title, the sources its items come from and how its cards look. A navigation value.
public struct CatalogListRequest: Hashable, Sendable {
    public var title: String
    public var sources: [WidgetSource]
    public var presentation: WidgetPresentation

    public init(title: String, sources: [WidgetSource], presentation: WidgetPresentation = WidgetPresentation()) {
        self.title = title
        self.sources = sources
        self.presentation = presentation
    }
}

/// The grid behind "See All", a collection tile or a genre. One source pages 50 at a time; several sources load once, merged.
@MainActor
@Observable
public final class CatalogListViewModel {
    public enum State: Equatable {
        case loading
        case loaded
        case loadingMore
        case failed(WidgetSourceError)
    }

    public let request: CatalogListRequest
    public private(set) var items: [MetaPreview] = []
    public private(set) var state: State = .loading
    public private(set) var canLoadMore = false
    /// Loaded, and nothing to show. A failed load is not empty.
    public var isEmpty: Bool { state == .loaded && items.isEmpty }

    nonisolated static let pageSize = 50
    nonisolated static let mergedLimit = 100

    private let services: AppServices
    private var generation = 0
    /// Raw items received so far: the protocol's `skip` counts what the addon sent, not what is left after de-duplication.
    private var receivedCount = 0

    public init(request: CatalogListRequest, services: AppServices) {
        self.request = request
        self.services = services
    }

    /// Refresh must ask the sources again, even when their cached page has not expired.
    public func refresh() async {
        await services.posterRatings.refresh()
        await services.widgetContent.invalidate()
        await load()
    }

    /// Loads the first page, or the merged list for several sources. Items already on screen stay until the new ones arrive.
    public func load() async {
        generation += 1
        let current = generation
        let sources = request.sources
        receivedCount = 0
        canLoadMore = false
        state = .loading
        guard !sources.isEmpty else {
            items = []
            state = .loaded
            return
        }
        do {
            let page: [MetaPreview]
            if sources.count == 1 {
                page = try await services.widgetContent.items(for: sources[0], limit: CatalogListViewModel.pageSize, skip: 0)
            } else {
                page = try await services.widgetContent.items(for: sources, limit: CatalogListViewModel.mergedLimit)
            }
            guard current == generation else { return }
            items = CatalogListViewModel.appending(page, to: [])
            receivedCount = CatalogListViewModel.advance(0, by: page, source: sources.count == 1 ? sources[0] : nil)
            canLoadMore = sources.count == 1 && !page.isEmpty
            state = .loaded
        } catch {
            guard current == generation else { return }
            state = .failed(CatalogListViewModel.widgetError(error))
        }
    }

    /// Call when the last item scrolls into view. Does nothing while a load runs, after an empty page, or for several sources.
    public func loadMore() async {
        let sources = request.sources
        guard canLoadMore, state == .loaded, sources.count == 1, let source = sources.first else { return }
        let current = generation
        state = .loadingMore
        do {
            let page = try await services.widgetContent.items(for: source, limit: CatalogListViewModel.pageSize, skip: receivedCount)
            guard current == generation else { return }
            receivedCount = CatalogListViewModel.advance(receivedCount, by: page, source: source)
            items = CatalogListViewModel.appending(page, to: items)
            canLoadMore = !page.isEmpty
            state = .loaded
        } catch {
            guard current == generation else { return }
            // Keeps what is there; scrolling to the end again tries the page once more.
            state = .loaded
        }
    }

    /// Where the next page starts. An addon's `skip` counts the items it sent, which is the page's length. A Trakt source is asked by page
    /// number, and Trakt drops entries it cannot show (no IMDb id), so a short page still used up a whole page of the list.
    private static func advance(_ received: Int, by page: [MetaPreview], source: WidgetSource?) -> Int {
        guard let source, source.usesTrakt else { return received + page.count }
        return received + pageSize
    }

    /// `page` added after `list`, leaving out any item whose type and id are already in it.
    private static func appending(_ page: [MetaPreview], to list: [MetaPreview]) -> [MetaPreview] {
        var seen = Set(list.map(\.identity))
        return list + page.filter { seen.insert($0.identity).inserted }
    }

    private static func widgetError(_ error: Error) -> WidgetSourceError {
        (error as? WidgetSourceError) ?? .addon(AddonError.from(error))
    }
}
