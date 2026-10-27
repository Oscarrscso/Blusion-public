#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

struct DiscoverView: View {
    @State private var model: DiscoverViewModel
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape
    @Environment(PosterRatingsStore.self) private var ratings: PosterRatingsStore?
    @Environment(AppRouter.self) private var router
    let onOpenAddons: () -> Void
    /// The id of the page's content, which its scroll goes back to when its tab's item is tapped.
    private static let topID = "discover.top"

    init(services: AppServices, onOpenAddons: @escaping () -> Void) {
        _model = State(initialValue: DiscoverViewModel(services: services))
        self.onOpenAddons = onOpenAddons
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    pageTitle
                    if model.hasSources {
                        filters
                        VStack(alignment: .leading, spacing: metrics.shelfSpacing) {
                            results
                        }
                    } else {
                        EmptyAddonsView(onOpenAddons: onOpenAddons)
                    }
                }
                .padding(.bottom, Theme.Spacing.l)
                .id(Self.topID)
            }
            .trackLandscapeTabScroll()
            .screenBackground()
            .browsePageTopMargin()
            .navigationTitle("")
            .toolbar(isPhoneInLandscape ? .hidden : .automatic, for: .tabBar)
            #if !targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            #endif
            .task { await model.loadSources() }
            .accessibilityIdentifier("discover.scroll")
            // A tap on Discover's tab item goes back to its first page, and scrolls it to the top.
            .onChange(of: router.tabTapRevisions[.discover, default: 0]) { _, _ in
                withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo(Self.topID, anchor: .top) }
            }
        }
    }

    /// The page's title, drawn in the content so the navigation bar stays free of text. A phone in landscape has no room for a title
    /// above the grid, so it is left out there; the tab bar still names the page.
    @ViewBuilder
    private var pageTitle: some View {
        if !isPhoneInLandscape {
            Text("Discover")
                .font(Theme.Typography.largeTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, metrics.pageMargin)
                .padding(.bottom, metrics.headerSpacing)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// `isPhoneLandscape` is also true on an iPad turned sideways, so the device is checked as well.
    private var isPhoneInLandscape: Bool { isPhoneLandscape && UIDevice.current.userInterfaceIdiom == .phone }

    /// The filter block the Library shares (see `BrowseFilterBar`): the type control, shown for Movies and Series when both exist,
    /// then the Year, Catalog and Genre menus, then a chip for the year span and one for the genre. Clearing them all reloads only
    /// for the genre, since the year span filters what is already loaded.
    private var filters: some View {
        @Bindable var model = model
        // Movies and Series only: the other catalogue types stay out of the type control.
        let types = model.types.filter { ["movie", "series"].contains($0.lowercased()) }
        var chips: [ActiveFilterChip] = []
        if let year = model.yearSpanLabel {
            chips.append(ActiveFilterChip(id: "year", label: year) {
                model.minimumYear = nil
                model.maximumYear = nil
            })
        }
        if let genre = model.selectedGenre {
            chips.append(ActiveFilterChip(id: "genre", label: genre) { Task { await model.select(genre: nil) } })
        }
        return BrowseFilterBar(kinds: types.count > 1 ? .init(titles: ["All", "Movies", "Series"], selection: Binding {
            model.showsAllTypes ? 0 : model.selectedType?.lowercased() == "series" ? 2 : 1
        } set: { index in
            guard index > 0 else { Task { await model.selectAllTypes() }; return }
            let type = index == 2 ? "series" : "movie"
            guard let selected = types.first(where: { $0.lowercased() == type }) else { return }
            Task { await model.select(type: selected) }
        }, identifier: "discover.filter.type") : nil, chips: chips, identifier: "discover", clearAll: {
            model.minimumYear = nil
            model.maximumYear = nil
            if model.selectedGenre != nil { Task { await model.select(genre: nil) } }
        }) {
            Menu {
                ReleaseYearOptions(minimumYear: $model.minimumYear, maximumYear: $model.maximumYear, identifier: "discover.filter.year")
            } label: {
                FilterMenuLabel("Year", systemImage: "calendar", isActive: model.minimumYear != nil || model.maximumYear != nil,
                                minHeight: BrowseFilterBar<EmptyView>.menuHeight)
            }
            .accessibilityIdentifier("discover.filter.year")
            Menu {
                ForEach(model.visibleSources) { source in
                    Button("\(source.title) · \(source.addon.name)") { Task { await model.select(source: source) } }
                }
            } label: {
                FilterMenuLabel(model.selectedSource?.title ?? "Catalog", systemImage: "square.stack",
                                minHeight: BrowseFilterBar<EmptyView>.menuHeight)
            }
            .accessibilityIdentifier("discover.catalogMenu")
            if !model.genres.isEmpty {
                Menu {
                    Button("All genres") { Task { await model.select(genre: nil) } }
                    ForEach(model.genres, id: \.self) { genre in
                        Button {
                            Task { await model.select(genre: genre) }
                        } label: {
                            if model.selectedGenre == genre { Label(genre, systemImage: "checkmark") } else { Text(genre) }
                        }
                    }
                } label: {
                    FilterMenuLabel(model.selectedGenre ?? "Genre", systemImage: "tag", isActive: model.selectedGenre != nil,
                                    minHeight: BrowseFilterBar<EmptyView>.menuHeight)
                }
                .accessibilityIdentifier("discover.genreMenu")
            }
        }
        .sensoryFeedback(.selection, trigger: model.selectedGenre)
        .sensoryFeedback(.selection, trigger: model.selectedSource)
        .sensoryFeedback(.selection, trigger: model.minimumYear)
    }

    @ViewBuilder
    private var results: some View {
        if !model.visibleItems.isEmpty {
            // On Mac the posters span the filters' width, from the first filter's leading edge to the last one's trailing edge.
            MediaGrid(items: model.visibleItems, onLastAppear: { Task { await model.loadMore() } }, fillsWidth: true)
        } else if !model.items.isEmpty {
            // Every title loaded so far is outside the year span: keep reading until one fits, or the catalogue ends.
            EmptyStateView("No titles match", systemImage: "line.3.horizontal.decrease.circle", message: "Try another year.")
                .task(id: model.items.count) { if model.canLoadMore { await model.loadMore() } }
        }
        switch model.state {
        case .idle, .loadingFirstPage:
            // The grid's own placeholders, so the titles land where they stand, at the same size.
            if model.items.isEmpty { MediaGridPlaceholder(aspect: .poster, fillsWidth: true) }
        case .failed(let error):
            if model.isOffline {
                OfflineBanner()
            } else {
                InlineErrorView(error.shortDescription, retry: { Task { await model.reload() } })
                    .padding(.horizontal, metrics.pageMargin)
            }
        case .loaded:
            if model.items.isEmpty { EmptyStateView("Nothing here yet", systemImage: "film", message: "Try another category or genre.") }
        case .loadingMore:
            Spinner().frame(maxWidth: .infinity)
        }
    }
}
#endif
