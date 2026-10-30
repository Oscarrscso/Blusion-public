#if canImport(UIKit)
import StremioKit
import SwiftUI
import UIKit

/// The grid behind "See All", a collection tile or a genre: the titles of the request's sources, loading the next page as the user
/// scrolls. The items already on screen stay while a refresh runs.
struct CatalogListView: View {
    let request: CatalogListRequest
    @State private var model: CatalogListViewModel
    /// The first load starts once; coming back to this screen keeps what is loaded instead of asking the addon again.
    @State private var hasStarted = false
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape
    @Environment(LandscapeTabBarState.self) private var landscapeTabs: LandscapeTabBarState?
    @Environment(AppRouter.self) private var router

    init(request: CatalogListRequest, services: AppServices) {
        self.request = request
        _model = State(initialValue: CatalogListViewModel(request: request, services: services))
    }

    var body: some View {
        ScrollView {
            content
                .padding(.bottom, Theme.Spacing.l)
        }
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
        // A phone in landscape has no navigation bar here, so the filters and grid use the full height behind the floating Back control.
        .trackLandscapeTabScroll()
        .screenBackground()
        .browsePageTopMargin()
        .navigationTitle(isPhoneInLandscape ? "" : request.title)
        .toolbarVisibility(isPhoneInLandscape ? .hidden : .automatic, for: .navigationBar)
        .toolbar(isPhoneInLandscape ? .hidden : .automatic, for: .tabBar)
        .onAppear { landscapeTabs?.showPageTitle(request.title) }
        .onDisappear {
            // A detail covers this destination without replacing it. Keep the title for the root navigation state to restore on return.
            if !router.showsTitlePage, landscapeTabs?.pageTitle == request.title { landscapeTabs?.clearPageTitle() }
        }
        .navigationBarTitleDisplayMode(isPhoneInLandscape ? .inline : .large)
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            await model.load()
        }
    }

    /// `isPhoneLandscape` is also true on an iPad turned sideways, so the device is checked as well. A phone in landscape has no navigation
    /// bar on this page: Back sits above Home and the title beside Home.
    private var isPhoneInLandscape: Bool { isPhoneLandscape && UIDevice.current.userInterfaceIdiom == .phone }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            emptyContent
        } else {
            VStack(alignment: .leading, spacing: 0) {
                filters
                if case .failed(let error) = model.state {
                    InlineErrorView(error.message, retry: retry)
                        .padding(.horizontal, Theme.screenPadding)
                        .padding(.bottom, Theme.Spacing.l)
                }
                if model.visibleItems.isEmpty, model.state != .loadingMore {
                    EmptyStateLayout(title: "No titles match", systemImage: "line.3.horizontal.decrease.circle",
                                     message: "Try removing a filter.") {
                        Button("Clear Filters") { model.filter.clearFilters() }
                            .buttonStyle(.primaryActionCompact)
                            .accessibilityIdentifier("catalogList.noMatches.clear")
                    }
                    .accessibilityIdentifier("catalogList.noMatches")
                } else {
                    MediaGrid(items: model.visibleItems, aspect: request.presentation.aspectRatio.cardAspect,
                              showsRating: request.presentation.showsRatings, onLastAppear: { Task { await model.loadMore() } },
                              usesBetterPosters: request.presentation.usesBetterPosters)
                        .accessibilityIdentifier("catalogList.grid")
                }
                if model.state == .loadingMore {
                    Spinner()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.l)
                }
            }
        }
    }

    /// Order, shuffle, type, release window and rating, in the filter block the Library and Discover share (`BrowseFilterBar`), so
    /// restyling that block restyles this one too. Every choice works on what is loaded, so it suits any source.
    private var filters: some View {
        @Bindable var model = model
        let types = model.loadedTypes
        var chips: [ActiveFilterChip] = []
        if let year = model.filter.yearLabel() {
            chips.append(ActiveFilterChip(id: "year", label: year) { model.filter.minimumYear = nil; model.filter.maximumYear = nil })
        }
        if let rating = model.filter.minimumRating {
            chips.append(ActiveFilterChip(id: "rating", label: "Rating \(LibraryFiltering.minimumRatingText(rating))") {
                model.filter.minimumRating = nil
            })
        }
        let mixed = types.contains("movie") && types.contains("series")
        return BrowseFilterBar(kinds: mixed ? .init(titles: ["All", "Movies", "Series"], selection: Binding {
            model.filter.type == "movie" ? 1 : model.filter.type == "series" ? 2 : 0
        } set: { index in
            model.filter.type = index == 1 ? "movie" : index == 2 ? "series" : nil
        }, identifier: "catalogList.filter.type") : nil, chips: chips, identifier: "catalogList", clearAll: { model.filter.clearFilters() }) {
            Menu {
                Picker("Sort by", selection: $model.filter.sort) {
                    ForEach(CatalogListSort.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                if model.filter.sort == .shuffle {
                    Divider()
                    Button("Shuffle Again", systemImage: "shuffle") { model.reshuffle() }
                        .accessibilityIdentifier("catalogList.sort.reshuffle")
                }
            } label: {
                menuLabel(model.filter.sort.title, systemImage: model.filter.sort == .shuffle ? "shuffle" : "arrow.up.arrow.down",
                          isActive: model.filter.sort != .original)
            }
            .accessibilityLabel("Sort by \(model.filter.sort.title)")
            .accessibilityIdentifier("catalogList.sort")
            Menu {
                Button { model.filter.minimumYear = nil; model.filter.maximumYear = nil } label: {
                    choice("Any Time", isOn: model.filter.minimumYear == nil && model.filter.maximumYear == nil)
                }
                Section {
                    ForEach(CatalogListRecent.allCases) { recent in
                        let range = recent.years()
                        Button {
                            model.filter.minimumYear = range.lowerBound
                            model.filter.maximumYear = range.upperBound
                        } label: {
                            choice(recent.title, isOn: model.filter.minimumYear == range.lowerBound && model.filter.maximumYear == range.upperBound)
                        }
                        .accessibilityIdentifier("catalogList.filter.year.recent.\(recent.rawValue)")
                    }
                }
                Section("Decades") {
                    ForEach(Array(stride(from: 2020, through: 1920, by: -10)), id: \.self) { start in
                        Button {
                            model.filter.minimumYear = start
                            model.filter.maximumYear = start + 9
                        } label: {
                            choice("\(start)s", isOn: model.filter.minimumYear == start && model.filter.maximumYear == start + 9)
                        }
                        .accessibilityIdentifier("catalogList.filter.year.\(start)")
                    }
                }
            } label: {
                menuLabel(model.filter.yearLabel() ?? "Any Time", systemImage: "calendar",
                          isActive: model.filter.minimumYear != nil || model.filter.maximumYear != nil)
            }
            .accessibilityIdentifier("catalogList.filter.year")
            Menu {
                RatingPicker(threshold: $model.filter.minimumRating)
            } label: {
                menuLabel(model.filter.minimumRating.map(LibraryFiltering.minimumRatingText) ?? "Rating", systemImage: "star.fill",
                          isActive: model.filter.minimumRating != nil)
            }
            .accessibilityIdentifier("catalogList.filter.rating")
        }
        .onChange(of: model.filter) { _, _ in Haptics.selection() }
        .task(id: model.filter) { await model.fillForFilter() }
        .accessibilityIdentifier("catalogList.filters")
    }

    private func menuLabel(_ title: String, systemImage: String, isActive: Bool) -> some View {
        FilterMenuLabel(title, systemImage: systemImage, isActive: isActive, minHeight: BrowseFilterBar<EmptyView>.menuHeight)
    }

    @ViewBuilder private func choice(_ title: String, isOn: Bool) -> some View {
        if isOn { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    /// Nothing loaded yet: placeholders while it loads, the failure with a retry, or the empty state when the addon had nothing.
    @ViewBuilder
    private var emptyContent: some View {
        switch model.state {
        case .loading, .loadingMore:
            VStack(alignment: .leading, spacing: 0) {
                // Keep the filter bar in its final position during the first load. Its default “Auto” sort is already usable, and the
                // posters replace placeholders without being pushed down when the controls arrive.
                filters
                MediaGridPlaceholder(aspect: request.presentation.aspectRatio.cardAspect)
            }
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
