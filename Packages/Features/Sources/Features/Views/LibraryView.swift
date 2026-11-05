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
        Group {
            #if targetEnvironment(macCatalyst)
            macPage
            #else
            scrollPage
            #endif
        }
        .task(id: router.opensDownloads) {
            // A long press on a Download button opens Library's Downloads page, from the top of the Library.
            guard router.opensDownloads, router.tab == .library else { return }
            router.libraryPath = NavigationPath()
            model.showsDownloads = true
            router.opensDownloads = false
        }
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
    }

    #if targetEnvironment(macCatalyst)
    /// The Mac's page: the filters and the Saved and Watched grids in one UIKit scroll (see `MacGridPage`), so a long library scrolls smoothly.
    private var macPage: some View {
        var parts: [MacGridPage.Part] = [.full(id: "filters", view: AnyView(filters))]
        if model.showsDownloads {
            parts.append(.full(id: "downloads", view: AnyView(
                DownloadsView(services: services, filter: model.downloadFilter, clearFilters: { model.clearFilters() }))))
        } else if !model.hasLoaded {
            parts.append(.full(id: "loading", view: AnyView(SkeletonRow())))
        } else if model.isEmpty || !model.hasMatches {
            parts.append(.full(id: "empty", view: AnyView(emptyState)))
        } else {
            if !model.saved.isEmpty {
                let saved = model.saved
                parts.append(.grid(MacTitleGrid(id: "saved", items: saved.map(\.preview), spacingAfter: metrics.shelfSpacing) { index, _ in
                    AnyView(savedCard(saved[index]))
                }))
            }
            if !model.watched.isEmpty {
                let watched = model.watched
                parts.append(.full(id: "watchedHeader", view: AnyView(SectionHeader("Watched").padding(.horizontal, metrics.pageMargin)),
                                   spacingAfter: metrics.headerSpacing))
                parts.append(.grid(MacTitleGrid(id: "watched", items: watched.map(\.preview)) { index, _ in
                    AnyView(watchedCard(watched[index]))
                }))
            }
        }
        return MacGridPage(parts: parts, scrollToTop: router.tabTapRevisions[.library, default: 0])
            .screenBackground()
            .navigationTitle("")
            .macRootNavigation()
            .pageTabBar(hidden: isPhoneInLandscape)
    }
    #endif

    private var scrollPage: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    filters
                    VStack(alignment: .leading, spacing: metrics.shelfSpacing) {
                        if model.showsDownloads {
                            DownloadsView(services: services, filter: model.downloadFilter, clearFilters: { model.clearFilters() })
                        } else if !model.hasLoaded {
                            SkeletonRow()
                        } else if model.isEmpty || !model.hasMatches {
                            emptyState
                        } else {
                            if !model.saved.isEmpty { savedSection }
                            if !model.watched.isEmpty { watchedSection }
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
            .macRootNavigation()
            .pageTabBar(hidden: isPhoneInLandscape)
            #if !targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            #endif
            // A tap on Library's tab item goes back to its first page, and scrolls it to the top.
            .onChange(of: router.tabTapRevisions[.library, default: 0]) { _, _ in
                withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo(Self.topID, anchor: .top) }
            }
        }
    }

    /// `isPhoneLandscape` is also true on an iPad turned sideways, so the device is checked as well.
    private var isPhoneInLandscape: Bool { isPhoneLandscape && UIDevice.current.userInterfaceIdiom == .phone }

    /// The type selector: All, Movies, Series and Downloads. Then the menus and chips of the page in view. The Library shows its Genre, Year,
    /// Rating and Sort; Downloads shows Type, Status, Year and Sort. Each page keeps its own selection, so switching never changes the
    /// other's. The block is the one Discover shares (see `BrowseFilterBar`), so the pages look the same.
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
                    Picker("Type", selection: $model.downloadFilter.kind) {
                        Text("Any").tag(LibraryKind?.none)
                        ForEach(kinds) { Text($0.title).tag(LibraryKind?.some($0)) }
                    }
                } label: {
                    filterLabel(model.downloadFilter.kind?.title ?? "Type", systemImage: "film",
                                isActive: model.downloadFilter.kind != nil)
                }
                .accessibilityIdentifier("library.downloads.filter.kind")
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
                let genres = model.availableGenres
                Menu {
                    Picker("Genre", selection: Binding<String?> { model.filter.genres.first } set: { genre in model.filter.genres = genre.map { [$0] } ?? [] }) {
                        Text("Any").tag(String?.none)
                        ForEach(genres, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                } label: {
                    filterLabel("Genre", systemImage: "tag", isActive: !model.filter.genres.isEmpty)
                }
                .disabled(genres.isEmpty)
                .accessibilityIdentifier("library.filter.genre")
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
        .onChange(of: model.filter) { _, _ in Haptics.play(.choices) }
        .onChange(of: model.downloadFilter) { _, _ in Haptics.play(.choices) }
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

    /// An empty library, or one whose filters match nothing.
    @ViewBuilder
    private var emptyState: some View {
        if model.isEmpty {
            EmptyStateLayout(title: "Your library is empty", systemImage: "books.vertical",
                             message: "Titles you save, and anything you start watching, show up here.") {
                Button("Find something to watch", action: onOpenAddons)
                    .buttonStyle(.primaryActionCompact)
                    .accessibilityIdentifier("library.empty.action")
            }
            .accessibilityIdentifier("library.empty")
        } else {
            EmptyStateLayout(title: "No titles match", systemImage: "line.3.horizontal.decrease.circle",
                             message: "Try removing a filter.") {
                Button("Clear Filters") { model.clearFilters() }
                    .buttonStyle(.primaryActionCompact)
                    .accessibilityIdentifier("library.noMatches.clear")
            }
            .accessibilityIdentifier("library.noMatches")
        }
    }

    private var savedSection: some View {
        LazyVGrid(columns: metrics.gridColumns(for: .poster, inLandscape: isLandscape), spacing: metrics.cardSpacing) {
            ForEach(model.saved) { savedCard($0) }
        }
        .padding(.horizontal, metrics.pageMargin)
    }

    private func savedCard(_ item: StremioKit.LibraryItem) -> some View {
        MediaCardLink(item: item.preview).stretched()
            .accessibilityIdentifier("library.saved.\(item.id)")
    }

    private var watchedSection: some View {
        VStack(alignment: .leading, spacing: metrics.headerSpacing) {
            SectionHeader("Watched").padding(.horizontal, metrics.pageMargin)
            LazyVGrid(columns: metrics.gridColumns(for: .poster, inLandscape: isLandscape), spacing: metrics.cardSpacing) {
                ForEach(model.watched) { watchedCard($0) }
            }
            .padding(.horizontal, metrics.pageMargin)
        }
    }

    /// A show's card names its latest episode and counts the episodes watched; a movie's card is just the movie, as it was.
    private func watchedCard(_ card: WatchedCard) -> some View {
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

#endif
