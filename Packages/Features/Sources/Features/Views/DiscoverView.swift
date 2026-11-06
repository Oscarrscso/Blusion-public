#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

struct DiscoverView: View {
    @State private var model: DiscoverViewModel
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape
    @Environment(AppRouter.self) private var router
    let onOpenAddons: () -> Void
    /// The id of the page's content, which its scroll goes back to when its tab's item is tapped.
    private static let topID = "discover.top"

    init(services: AppServices, onOpenAddons: @escaping () -> Void) {
        _model = State(initialValue: DiscoverViewModel(services: services))
        self.onOpenAddons = onOpenAddons
    }

    var body: some View {
        Group {
            #if targetEnvironment(macCatalyst)
            if model.hasSources { macPage } else { scrollPage }
            #else
            scrollPage
            #endif
        }
        .task { await model.loadSources() }
        // The side margin is the gap between cards, on everything on the page (see `LayoutMetrics.gridPage`).
        .environment(\.layoutMetrics, metrics.gridPage)
    }

    #if targetEnvironment(macCatalyst)
    /// The Mac's page: the filters, the grid and its status in one UIKit scroll (see `MacGridPage`), so a long grid scrolls smoothly.
    private var macPage: some View {
        var parts: [MacGridPage.Part] = [.full(id: "filters", view: AnyView(filters))]
        if !model.visibleItems.isEmpty {
            parts.append(.grid(MacTitleGrid(id: "results", items: model.visibleItems, fillsWidth: true,
                                            onLastAppear: { Task { await model.loadMore() } }, spacingAfter: metrics.shelfSpacing) { _, item in
                AnyView(MediaCardLink(item: item).stretched())
            }))
        } else if model.items.isEmpty, model.state == .idle || model.state == .loadingFirstPage {
            // The first page's placeholders in the grid's own layout, so the titles land where they stand, at the same size.
            parts.append(.placeholders(id: "placeholders"))
        }
        parts.append(.full(id: "status", view: AnyView(VStack(alignment: .leading, spacing: metrics.shelfSpacing) { resultsStatus })))
        return MacGridPage(parts: parts, scrollToTop: router.tabTapRevisions[.discover, default: 0])
            .screenBackground()
            .navigationTitle("")
            .macRootNavigation()
            .pageTabBar(hidden: isPhoneInLandscape)
            .accessibilityIdentifier("discover.scroll")
    }
    #endif

    private var scrollPage: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
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
            .scrollIndicators(.visible, axes: .vertical)
            .scrollIndicatorsFlash(onAppear: true)
            .trackLandscapeTabScroll()
            .screenBackground()
            .browsePageTopMargin()
            .navigationTitle("")
            .macRootNavigation()
            .pageTabBar(hidden: isPhoneInLandscape)
            #if !targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            #endif
            .accessibilityIdentifier("discover.scroll")
            // A tap on Discover's tab item goes back to its first page, and scrolls it to the top.
            .onChange(of: router.tabTapRevisions[.discover, default: 0]) { _, _ in
                withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo(Self.topID, anchor: .top) }
            }
        }
    }

    /// `isPhoneLandscape` is also true on an iPad turned sideways, so the device is checked as well.
    private var isPhoneInLandscape: Bool { isPhoneLandscape && UIDevice.current.userInterfaceIdiom == .phone }

    /// Discover supplies the controls; BrowseFilterBar owns their layout on both platforms.
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
        if let rating = model.minimumRating {
            chips.append(ActiveFilterChip(id: "rating", label: "Rating \(LibraryFiltering.minimumRatingText(rating))") {
                model.minimumRating = nil
            })
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
            model.minimumRating = nil
            if model.selectedGenre != nil { Task { await model.select(genre: nil) } }
        }) {
            // Filters first, then the order, the same as the Library: two even rows on iPhone, one on Mac.
            let genres = model.genres
            Menu {
                Picker("Genre", selection: Binding<String?> { model.selectedGenre } set: { genre in Task { await model.select(genre: genre) } }) {
                    Text("Any").tag(String?.none)
                    ForEach(genres, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            } label: {
                FilterMenuLabel("Genre", systemImage: "tag", isActive: model.selectedGenre != nil,
                                minHeight: BrowseFilterBar<EmptyView>.menuHeight)
            }
            .disabled(genres.isEmpty)
            .accessibilityIdentifier("discover.genreMenu")
            Menu {
                ReleaseYearOptions(minimumYear: $model.minimumYear, maximumYear: $model.maximumYear,
                                   identifier: "discover.filter.year")
            } label: {
                FilterMenuLabel("Year", systemImage: "calendar", isActive: model.minimumYear != nil || model.maximumYear != nil,
                                minHeight: BrowseFilterBar<EmptyView>.menuHeight)
            }
            .accessibilityIdentifier("discover.filter.year")
            Menu {
                RatingPicker(threshold: $model.minimumRating)
            } label: {
                FilterMenuLabel("Rating", systemImage: "star.fill", isActive: model.minimumRating != nil,
                                minHeight: BrowseFilterBar<EmptyView>.menuHeight)
            }
            .accessibilityIdentifier("discover.filter.rating")
            Menu {
                Picker("Sort by", selection: $model.sort) {
                    ForEach(CatalogListSort.allCases.filter { $0 != .shuffle }) {
                        Label($0.title, systemImage: $0.systemImage).tag($0)
                    }
                }
            } label: {
                FilterMenuLabel(model.sort.title, systemImage: "arrow.up.arrow.down", isActive: model.sort != .original,
                                minHeight: BrowseFilterBar<EmptyView>.menuHeight)
            }
            .accessibilityLabel("Sort by \(model.sort.title)")
            .accessibilityIdentifier("discover.sort")
        }
        .onChange(of: model.selectedGenre) { _, _ in Haptics.play(.choices) }
        .onChange(of: model.selectedType) { _, _ in Haptics.play(.choices) }
        .onChange(of: model.minimumYear) { _, _ in Haptics.play(.choices) }
        .onChange(of: model.minimumRating) { _, _ in Haptics.play(.choices) }
        .onChange(of: model.sort) { _, _ in Haptics.play(.choices) }
    }

    @ViewBuilder
    private var results: some View {
        if !model.visibleItems.isEmpty {
            // On Mac the posters span the filters' width, from the first filter's leading edge to the last one's trailing edge.
            MediaGrid(items: model.visibleItems, onLastAppear: { Task { await model.loadMore() } }, fillsWidth: true)
        }
        resultsStatus
    }

    /// What the page shows besides the grid: a message when nothing matches, the first page's placeholders, an error, or the spinner.
    @ViewBuilder
    private var resultsStatus: some View {
        if model.visibleItems.isEmpty, !model.items.isEmpty {
            // Keep reading when the loaded titles do not match the local filters.
            EmptyStateView("No titles match", systemImage: "line.3.horizontal.decrease.circle", message: "Try removing a filter.")
                .task(id: model.items.count) { if model.canLoadMore { await model.loadMore() } }
        }
        switch model.state {
        case .idle, .loadingFirstPage:
            // The grid's own placeholders, so the titles land where they stand, at the same size. The Mac's page lays them out in its
            // own grid instead (see `macPage`).
            #if targetEnvironment(macCatalyst)
            EmptyView()
            #else
            if model.items.isEmpty { MediaGridPlaceholder(aspect: .poster, fillsWidth: true) }
            #endif
        case .failed(let error):
            if model.isOffline {
                OfflineBanner()
            } else {
                InlineErrorView(error.shortDescription, retry: { Task { await model.reload() } })
                    .padding(.horizontal, metrics.gridPageMargin)
            }
        case .loaded:
            if model.items.isEmpty { EmptyStateView("Nothing here yet", systemImage: "film", message: "Try another genre or remove a filter.") }
        case .loadingMore:
            Spinner().frame(maxWidth: .infinity)
        }
    }
}
#endif
