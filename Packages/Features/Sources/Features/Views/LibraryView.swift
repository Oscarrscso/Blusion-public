#if canImport(UIKit)
import SwiftUI
import PlayerKit
import StremioKit
import UIKit

struct LibraryView: View {
    @State private var model: LibraryViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.isLandscape) private var isLandscape
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape
    @Environment(TitleActions.self) private var actions: TitleActions?
    @Environment(PosterRatingsStore.self) private var ratings: PosterRatingsStore?
    @Environment(AppRouter.self) private var router
    let services: AppServices
    let onOpenAddons: () -> Void
    /// The id of the page's content, which its scroll goes back to when its tab's item is tapped.
    private static let topID = "library.top"

    init(services: AppServices, onOpenAddons: @escaping () -> Void) {
        self.services = services
        _model = State(initialValue: LibraryViewModel(services: services))
        self.onOpenAddons = onOpenAddons
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    pageTitle
                    filters
                    VStack(alignment: .leading, spacing: metrics.shelfSpacing) {
                        if model.showsDownloads {
                            DownloadsView(services: services, filter: model.downloadFilter, clearFilters: { model.clearFilters() })
                        } else if !model.hasLoaded {
                            SkeletonRow()
                        } else if model.isEmpty {
                            EmptyStateLayout(title: "Your library is empty", systemImage: "books.vertical",
                                             message: "Titles you save, and anything you start watching, show up here.") {
                                Button("Find something to watch", action: onOpenAddons)
                                    .buttonStyle(.primaryActionCompact)
                                    .accessibilityIdentifier("library.empty.action")
                            }
                            .accessibilityIdentifier("library.empty")
                        } else {
                            if !model.hasMatches {
                                EmptyStateLayout(title: "No titles match", systemImage: "line.3.horizontal.decrease.circle",
                                                 message: "Try removing a filter.") {
                                    Button("Clear Filters") { model.clearFilters() }
                                        .buttonStyle(.primaryActionCompact)
                                        .accessibilityIdentifier("library.noMatches.clear")
                                }
                                .accessibilityIdentifier("library.noMatches")
                            } else {
                                if !model.saved.isEmpty { savedSection }
                                if !model.watched.isEmpty { watchedSection }
                            }
                        }
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
            .task(id: router.opensDownloads) {
                // A long press on a Download button opens Library's Downloads page, from the top of the Library.
                guard router.opensDownloads, router.tab == .library else { return }
                router.libraryPath = NavigationPath()
                model.showsDownloads = true
                router.opensDownloads = false
            }
            .toolbar(isPhoneInLandscape ? .hidden : .automatic, for: .tabBar)
            #if !targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            #endif
            .task { model.attachRatings(ratings) }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await model.refresh()
                    await actions?.refresh()
                    do {
                        try await Task.sleep(for: .seconds(300))
                    } catch {
                        return
                    }
                }
            }
            .onChange(of: actions?.savedIdentities) { Task { await model.load() } }
            .onChange(of: actions?.watchedIdentities) { Task { await model.load() } }
            .accessibilityIdentifier("library.list")
            // A tap on Library's tab item goes back to its first page, and scrolls it to the top.
            .onChange(of: router.tabTapRevisions[.library, default: 0]) { _, _ in
                withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo(Self.topID, anchor: .top) }
            }
        }
    }

    /// The page's title, drawn in the content so the navigation bar stays free of text. A phone in landscape has no room for a title
    /// above the grid, so it is left out there; the tab bar still names the page.
    @ViewBuilder
    private var pageTitle: some View {
        if !isPhoneInLandscape {
            Text("Library")
                .font(Theme.Typography.largeTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, metrics.pageMargin)
                .padding(.bottom, metrics.headerSpacing)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// `isPhoneLandscape` is also true on an iPad turned sideways, so the device is checked as well.
    private var isPhoneInLandscape: Bool { isPhoneLandscape && UIDevice.current.userInterfaceIdiom == .phone }

    /// The type selector: All, Movies, Series and Downloads. Then the menus and chips of the page in view. The Library shows its Year, Rating
    /// and Sort; Downloads shows Status, Year and Sort. Each page keeps its own selection, so switching never changes the other's. The block
    /// is the one Discover shares (see `BrowseFilterBar`), so the pages look the same.
    private var filters: some View {
        @Bindable var model = model
        let kinds: [LibraryKind] = [.movie, .series]
        let kindIndex = kinds.firstIndex(where: { model.filter.kinds.contains($0) }).map { $0 + 1 } ?? 0
        let downloadsIndex = kinds.count + 1
        return BrowseFilterBar(kinds: .init(titles: ["All"] + kinds.map(\.title) + ["Downloads"], selection: Binding {
            model.showsDownloads ? downloadsIndex : kindIndex
        } set: { index in
            model.showsDownloads = index == downloadsIndex
            // Picking Downloads leaves the Library's type choice as it was, so returning to the Library restores it.
            if index <= kinds.count { model.filter.kinds = index > 0 ? [kinds[index - 1]] : [] }
        }, identifier: "library.filter.kind", symbols: ["square.grid.2x2", "film", "tv", "arrow.down.circle"]), chips: filterChips,
        identifier: "library", clearAll: { model.clearFilters() }) {
            if model.showsDownloads {
                Menu {
                    Picker("Status", selection: $model.downloadFilter.status) {
                        ForEach(DownloadStatusFilter.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    let status = model.downloadFilter.status
                    filterLabel(status == .all ? "Status" : status.title, systemImage: "arrow.down.circle", isActive: status != .all)
                }
                .accessibilityIdentifier("library.downloads.filter.status")
                Menu {
                    ReleaseYearOptions(minimumYear: $model.downloadFilter.minimumYear, maximumYear: $model.downloadFilter.maximumYear,
                                       identifier: "library.downloads.filter.year")
                } label: {
                    filterLabel("Year", systemImage: "calendar",
                                isActive: model.downloadFilter.minimumYear != nil || model.downloadFilter.maximumYear != nil)
                }
                .accessibilityIdentifier("library.downloads.filter.year")
                Menu {
                    Picker("Sort by", selection: $model.downloadFilter.sort) {
                        ForEach(DownloadSort.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    filterLabel(model.downloadFilter.sort.title, systemImage: "arrow.up.arrow.down",
                                isActive: model.downloadFilter.sort != .recentlyAdded)
                }
                .accessibilityLabel("Sort by \(model.downloadFilter.sort.title)")
                .accessibilityIdentifier("library.downloads.sort")
            } else {
                Menu {
                    ReleaseYearOptions(minimumYear: $model.filter.minimumYear, maximumYear: $model.filter.maximumYear,
                                       identifier: "library.filter.year")
                } label: {
                    filterLabel("Year", systemImage: "calendar", isActive: model.filter.minimumYear != nil || model.filter.maximumYear != nil)
                }
                .accessibilityIdentifier("library.filter.year")
                Menu {
                    RatingPicker(threshold: $model.filter.minimumRating)
                } label: {
                    filterLabel("Rating", systemImage: "star.fill", isActive: model.filter.minimumRating != nil)
                }
                .accessibilityIdentifier("library.filter.rating")
                Menu {
                    Picker("Sort by", selection: $model.filter.sort) {
                        ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    filterLabel(model.filter.sort.title, systemImage: "arrow.up.arrow.down", isActive: model.filter.sort != .recentlyAdded)
                }
                .accessibilityLabel("Sort by \(model.filter.sort.title)")
                .accessibilityIdentifier("library.sort")
            }
        }
        .onChange(of: model.filter) { _, _ in Haptics.selection() }
        .onChange(of: model.downloadFilter) { _, _ in Haptics.selection() }
        .accessibilityIdentifier("library.filters")
    }

    /// The chips of the page in view: the Library's filters, or the Downloads' status and years.
    private var filterChips: [ActiveFilterChip] {
        if model.showsDownloads {
            return model.downloadFilter.chips.map { chip in ActiveFilterChip(id: chip.id, label: chip.label) { model.removeDownloadFilter(chip) } }
        }
        return model.filter.chips.map { chip in ActiveFilterChip(id: chip.id, label: chip.label) { model.removeFilter(chip) } }
    }

    private func filterLabel(_ title: String, systemImage: String? = nil, tint: Color = .primary, isActive: Bool = false) -> some View {
        FilterMenuLabel(title, systemImage: systemImage, tint: tint, isActive: isActive, minHeight: BrowseFilterBar<EmptyView>.menuHeight)
    }

    private var savedSection: some View {
        LazyVGrid(columns: metrics.gridColumns(for: .poster, inLandscape: isLandscape), spacing: metrics.cardSpacing) {
            ForEach(model.saved) { item in
                MediaCardLink(item: item.preview).stretched()
                    .accessibilityIdentifier("library.saved.\(item.id)")
            }
        }
        .padding(.horizontal, metrics.pageMargin)
    }

    private var watchedSection: some View {
        VStack(alignment: .leading, spacing: metrics.headerSpacing) {
            SectionHeader("Watched").padding(.horizontal, metrics.pageMargin)
            LazyVGrid(columns: metrics.gridColumns(for: .poster, inLandscape: isLandscape), spacing: metrics.cardSpacing) {
                ForEach(model.watched) { card in
                    // A show's card names its latest episode and counts the episodes watched; a movie's card is just the movie, as it was.
                    MediaCardLink(item: card.preview, showsTitle: card.isShow ? true : nil, subtitle: card.episodeLine).stretched()
                        .overlay(alignment: .topTrailing) {
                            Badge(card.isShow ? "\(card.watchedCount) watched" : "Watched", systemImage: "checkmark").padding(6)
                        }
                        .accessibilityIdentifier("library.watched.\(card.id)")
                        // On iPhone a held poster plays (see `MediaCardLink`); the title's page clears its watched mark. The Mac keeps
                        // the menu, which a right click opens.
                        #if targetEnvironment(macCatalyst)
                        .contextMenu {
                            Button(card.isShow ? "Mark Watched Episodes as Unwatched" : "Mark as Unwatched") {
                                Task { await model.markUnwatched(card); await actions?.refresh() }
                            }
                        }
                        #endif
                }
            }
            .padding(.horizontal, metrics.pageMargin)
        }
    }

}

/// The minimum rating, shown out of 100. Each title is rated by its best available score, so the menu names no site.
struct RatingPicker: View {
    @Binding var threshold: Double?

    var body: some View {
        Picker("At least", selection: $threshold) {
            Text("Any").tag(Double?.none)
            ForEach([5.0, 6, 7, 8, 9, 10], id: \.self) { value in
                Text(LibraryFiltering.minimumRatingText(value)).tag(Double?.some(value))
            }
        }
        .accessibilityIdentifier("library.filter.rating.threshold")
    }
}

/// Release years in ten-year spans, "1920 - 1929" up to "2020 - 2029", shared by the Library and Discover. Choosing a span sets both ends
/// of the year filter to it; "Any" clears it. `identifier` names the spans: each is "<identifier>.<start year>".
struct ReleaseYearOptions: View {
    @Binding var minimumYear: Int?
    @Binding var maximumYear: Int?
    let identifier: String
    private static let starts = Array(stride(from: 1920, through: 2020, by: 10))

    var body: some View {
        Button { setSpan(nil) } label: {
            choice("Any", isOn: minimumYear == nil && maximumYear == nil)
        }
        ForEach(Self.starts, id: \.self) { start in
            Button { setSpan(start) } label: {
                choice("\(start) - \(start + 9)", isOn: minimumYear == start && maximumYear == start + 9)
            }
            .accessibilityIdentifier("\(identifier).\(start)")
        }
    }

    private func setSpan(_ start: Int?) {
        minimumYear = start
        maximumYear = start.map { $0 + 9 }
    }

    @ViewBuilder private func choice(_ title: String, isOn: Bool) -> some View {
        if isOn { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
#endif
