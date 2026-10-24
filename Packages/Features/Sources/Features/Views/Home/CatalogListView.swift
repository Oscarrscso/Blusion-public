#if canImport(UIKit)
import StremioKit
import SwiftUI

/// The grid behind "See All", a collection tile or a genre: the titles of the request's sources, loading the next page as the user
/// scrolls. The items already on screen stay while a refresh runs.
struct CatalogListView: View {
    let request: CatalogListRequest
    @State private var model: CatalogListViewModel
    /// The first load starts once; coming back to this screen keeps what is loaded instead of asking the addon again.
    @State private var hasStarted = false

    init(request: CatalogListRequest, services: AppServices) {
        self.request = request
        _model = State(initialValue: CatalogListViewModel(request: request, services: services))
    }

    var body: some View {
        ScrollView {
            content
                .padding(.vertical, Theme.Spacing.l)
        }
        .screenBackground()
        .navigationTitle(request.title)
        .navigationBarTitleDisplayMode(.large)
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            await model.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            emptyContent
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                if case .failed(let error) = model.state {
                    InlineErrorView(error.message, retry: retry)
                        .padding(.horizontal, Theme.screenPadding)
                }
                MediaGrid(items: model.items, aspect: request.presentation.aspectRatio.cardAspect,
                          showsRating: request.presentation.showsRatings, onLastAppear: { Task { await model.loadMore() } },
                          usesBetterPosters: request.presentation.usesBetterPosters)
                    .accessibilityIdentifier("catalogList.grid")
                if model.state == .loadingMore {
                    Spinner()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.l)
                }
            }
        }
    }

    /// Nothing loaded yet: placeholders while it loads, the failure with a retry, or the empty state when the addon had nothing.
    @ViewBuilder
    private var emptyContent: some View {
        switch model.state {
        case .loading, .loadingMore:
            // The grid's own placeholders, so the titles land where they stand, at the same size.
            MediaGridPlaceholder(aspect: request.presentation.aspectRatio.cardAspect)
        case .loaded:
            EmptyStateView("Nothing here yet", systemImage: "square.stack", message: "This list is empty right now.")
                .frame(maxWidth: .infinity, minHeight: 360)
        case .failed(let error):
            InlineErrorView(error.message, retry: retry)
                .padding(.horizontal, Theme.screenPadding)
        }
    }

    private func retry() {
        Task { await model.load() }
    }
}
#endif
