#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

struct SearchView: View {
    @State private var model: SearchViewModel
    @State private var selectedType = "all"
    @State private var isSearchPresented = false
    @FocusState private var isSearchFocused: Bool
    @Environment(AppRouter.self) private var router
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape
    @Environment(\.appAppearance) private var appearance
    private let services: AppServices
    private let initialQuery: String?
    /// The id of the page's content, which its scroll goes back to when its tab's item is tapped.
    private static let topID = "search.top"

    init(services: AppServices, initialQuery: String? = nil) {
        _model = State(initialValue: SearchViewModel(services: services, history: services.searchHistory))
        self.services = services
        self.initialQuery = initialQuery
    }

    /// The standard page, or the editorial one (the Arthouse preset), over the same search.
    var body: some View {
        Group {
            if appearance.showsEditorialPages {
                EditorialSearchPage(model: model, services: services, results: resultItems, isLoading: isLoadingResults,
                                    selectedType: $selectedType)
            } else {
                // The side margin is the gap between cards, on everything on the page (see `LayoutMetrics.gridPage`).
                standardPage
                    .environment(\.layoutMetrics, metrics.gridPage)
            }
        }
        // Coming from another tab, Search starts on an empty field.
        .onChange(of: router.searchBrowseRevision) { model.query = "" }
        .onChange(of: model.query) { model.queryDidChange() }
        .task {
            await model.refreshAvailability()
            model.prewarmAI()
        }
        .onChange(of: router.tab) { old, _ in
            if old == .settings { Task { await model.refreshAvailability() } }
        }
        .task {
            guard let initialQuery, model.query.isEmpty else { return }
            model.query = initialQuery
            await model.submit()
        }
    }

    private var standardPage: some View {
        @Bindable var model = model
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: metrics.shelfSpacing) {
                    #if targetEnvironment(macCatalyst)
                    TextField("Shows, Movies, and More", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSearchFocused)
                        .submitLabel(.search)
                        .onSubmit { Task { await model.submit() } }
                        .padding(.horizontal, metrics.gridPageMargin)
                    #endif
                    if model.isOffline {
                        OfflineBanner()
                    } else if !model.failures.isEmpty {
                        WrappingStack { ForEach(model.failures) { ErrorChip(text: $0.text) } }
                            .padding(.horizontal, metrics.gridPageMargin)
                            .accessibilityIdentifier("search.failures")
                    }
                    if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if model.showsNoSearchableAddons {
                            EmptyStateView("No addon can search", systemImage: "magnifyingglass",
                                           actionTitle: "Open Addons", action: { router.showAddons() })
                                .accessibilityIdentifier("search.noSearchableAddons")
                        } else {
                            browse
                        }
                    } else {
                        results
                    }
                }
                .padding(.vertical, Theme.Spacing.l)
                .id(Self.topID)
            }
            .scrollIndicators(.visible, axes: .vertical)
            .scrollIndicatorsFlash(onAppear: true)
            // Any scroll of the page puts the keyboard away, so a swipe down clears the view of the results.
            .trackLandscapeTabScroll()
            .scrollDismissesKeyboard(.immediately)
            .screenBackground()
            .navigationTitle(isPhoneInLandscape ? "" : "Search")
            .macRootNavigation()
            .pageTabBar(hidden: isPhoneInLandscape)
            #if !targetEnvironment(macCatalyst)
            .searchable(text: $model.query, isPresented: $isSearchPresented,
                        placement: .navigationBarDrawer(displayMode: .always), prompt: "Shows, Movies, and More")
            .searchFocused($isSearchFocused)
            #endif
            // Every arrival on Search, and every tap on its button, puts the cursor in the field and brings the keyboard up. The field
            // stays where it is, under the title.
            .onChange(of: router.searchFocusRevision, initial: true) { focusField() }
            // Search's active toolbar must leave with its root page, rather than follow a pushed destination.
            .onChange(of: router.searchPath.count) { _, count in
                if count > 0 {
                    isSearchFocused = false
                    isSearchPresented = false
                }
            }
            .onSubmit(of: .search) { Task { await model.submit() } }
            .accessibilityIdentifier("search.results")
            // A tap on Search's tab item goes back to its first page, and scrolls it to the top.
            .onChange(of: router.tabTapRevisions[.search, default: 0]) { _, _ in
                withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo(Self.topID, anchor: .top) }
            }
        }
    }

    /// `isPhoneLandscape` is also true on an iPad turned sideways, so the device is checked as well. A phone in landscape shows the
    /// search field without a title above it.
    private var isPhoneInLandscape: Bool { isPhoneLandscape && UIDevice.current.userInterfaceIdiom == .phone }

    /// Puts the cursor in the field. The field is not there in the frame the tab changes, so the focus is asked for again a moment later.
    private func focusField() {
        guard router.tab == .search, router.searchPath.isEmpty else { return }
        isSearchPresented = true
        isSearchFocused = true
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard router.tab == .search, router.searchPath.isEmpty else { return }
            isSearchPresented = true
            isSearchFocused = true
        }
    }

    /// The idle page: the streaming services, each opening everything it streams, then the categories.
    private var browse: some View {
        VStack(alignment: .leading, spacing: metrics.shelfSpacing) {
            tileSection("Streaming Services") {
                ForEach(StreamProvider.browsable, id: \.self) { provider in
                    NavigationLink(value: CatalogListRequest(title: provider.name, sources: [provider.catalogSource])) {
                        CollectionTile(title: provider.name, provider: provider).stretched()
                    }
                    .buttonStyle(PressableCardStyle.poster)
                    .titleTapHaptic()
                    .accessibilityIdentifier("search.service.\(provider.rawValue)")
                }
            }
            if !model.categories.isEmpty {
                tileSection("Categories") {
                    // Picture tiles, as on Home's genre shelf. A genre without a picture shows its colour placeholder.
                    ForEach(model.categories) { genre in
                        NavigationLink(value: CatalogListRequest(title: genre.name, sources: genre.sources)) {
                            CollectionTile(title: genre.name, imageURL: genre.imageURL).stretched()
                        }
                        .buttonStyle(PressableCardStyle.poster)
                        .titleTapHaptic()
                        .accessibilityIdentifier("search.genre.\(genre.name)")
                    }
                }
            }
        }
    }

    private func tileSection(_ title: String, @ViewBuilder tiles: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title)
            LazyVGrid(columns: metrics.wideGridColumns, spacing: metrics.cardSpacing) { tiles() }
        }
        .padding(.horizontal, metrics.gridPageMargin)
    }

    private var resultItems: [MetaPreview] {
        if selectedType == "ai" { return model.describedItems }
        let items = model.groups.flatMap(\.items)
        // Add semantic matches after title matches, showing each title only once.
        var seen = Set(items.map(\.identity))
        let combined = items + model.describedItems.filter { seen.insert($0.identity).inserted }
        return combined.filter {
            selectedType == "all" || $0.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == selectedType
        }
    }

    private var isLoadingResults: Bool {
        selectedType == "ai"
            ? model.aiPhase == .searching
            : model.phase == .searching || model.aiPhase == .searching
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: metrics.shelfSpacing) {
            Picker("Results", selection: $selectedType) {
                Text("All").tag("all")
                Text("Movies").tag("movie")
                Text("Series").tag("series")
                if model.aiAvailable { Text("AI").tag("ai") }
            }
            .pickerStyle(.segmented)
            .navigationAlignedWidth(margin: metrics.gridPageMargin)
            .accessibilityIdentifier("search.filters")

            if !resultItems.isEmpty {
                MediaGrid(items: resultItems, fillsWidth: true)
            } else if isLoadingResults {
                MediaGridPlaceholder(aspect: .poster, fillsWidth: true)
            } else if !model.isOffline, model.failures.isEmpty || selectedType == "ai" {
                EmptyStateView("No results", systemImage: "magnifyingglass")
                    .accessibilityIdentifier("search.empty")
            }

            if isLoadingResults {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Searching")
                    .accessibilityIdentifier("search.loading")
            }

            if selectedType == "all" || selectedType == "ai",
               model.aiPhase == .done, let issue = model.aiIssue {
                HStack {
                    Text(LocalizedStringKey(issue.text))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { model.retryAI() }
                }
                .padding(.horizontal, metrics.gridPageMargin)
                .accessibilityIdentifier("search.ai.retry")
            }
        }
    }

}
#endif
