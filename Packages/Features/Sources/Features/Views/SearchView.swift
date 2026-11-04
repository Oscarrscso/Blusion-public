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
    private let initialQuery: String?
    /// The id of the page's content, which its scroll goes back to when its tab's item is tapped.
    private static let topID = "search.top"

    init(services: AppServices, initialQuery: String? = nil) {
        _model = State(initialValue: SearchViewModel(services: services, history: services.searchHistory))
        self.initialQuery = initialQuery
    }

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: metrics.shelfSpacing) {
                    #if targetEnvironment(macCatalyst)
                    TextField("Shows, Movies, and More", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSearchFocused)
                        .submitLabel(.search)
                        .onSubmit { Task { await model.submit() } }
                        .padding(.horizontal, metrics.pageMargin)
                    #endif
                    if model.isOffline {
                        OfflineBanner()
                    } else if !model.failures.isEmpty {
                        WrappingStack { ForEach(model.failures) { ErrorChip(text: $0.text) } }
                            .padding(.horizontal, metrics.pageMargin)
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
            // Coming from another tab, Search starts on an empty field.
            .onChange(of: router.searchBrowseRevision) { model.query = "" }
            // A title opened from a search was recorded as a recent search; the list reads them again.
            .onChange(of: router.recentSearchRevision) { model.reloadRecents() }
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
            .onChange(of: model.query) { model.queryDidChange() }
            .onSubmit(of: .search) { Task { await model.submit() } }
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

    /// Two across on a phone, as many as fit on a wide window.
    private var categoryColumns: [GridItem] {
        metrics.isRegular
            ? [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: Theme.Spacing.s)]
            : Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.s), count: 2)
    }

    private var browse: some View {
        VStack(alignment: .leading, spacing: metrics.shelfSpacing) {
            if !model.recentQueries.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    HStack {
                        SectionHeader("Recent Searches")
                        Button("Clear", systemImage: "xmark") {
                            Haptics.play(.buttons)
                            model.clearRecents()
                        }
                            .labelStyle(.titleOnly)
                            .buttonStyle(.borderless)
                            .help("Clear")
                            .accessibilityIdentifier("search.clearRecents")
                    }
                    .padding(.horizontal, metrics.pageMargin)
                    ForEach(model.recentQueries, id: \.self) { query in
                        Button {
                            model.query = query
                            Task { await model.submit() }
                        } label: {
                            // The inset is part of the label, so the whole row from edge to edge answers a tap, not only the text.
                            Label(query, systemImage: "clock")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.horizontal, metrics.pageMargin)
                                .contentShape(Rectangle())
                                .pointerInteraction(cornerRadius: Theme.Radius.card)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search.recent.\(query)")
                        .contextMenu {
                            Button("Remove", role: .destructive) { model.removeRecent(query) }
                        }
                    }
                }
            }
            if model.browseGenres.isEmpty {
                EmptyStateView("Search", systemImage: "magnifyingglass")
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    SectionHeader("Categories")
                    // Compact rows on the page's own surface, each with its category's glyph in a small coloured badge: calmer than a
                    // wall of picture-sized colour tiles, and twice as many fit on a screen.
                    LazyVGrid(columns: categoryColumns, spacing: Theme.Spacing.s) {
                        ForEach(model.browseGenres) { genre in
                            NavigationLink(value: CatalogListRequest(title: genre.name, sources: [genre.source])) {
                                CategoryRow(title: genre.name)
                            }
                            .buttonStyle(PressableCardStyle(lifts: false))
                            .titleTapHaptic()
                            .accessibilityIdentifier("search.genre.\(genre.name)")
                        }
                    }
                }
                .padding(.horizontal, metrics.pageMargin)
            }
        }
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
            .padding(.horizontal, metrics.pageMargin)
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
                .padding(.horizontal, metrics.pageMargin)
                .accessibilityIdentifier("search.ai.retry")
            }
        }
    }

}

/// One category on the Search page: its glyph in a small badge of its colour, its name, and a chevron.
private struct CategoryRow: View {
    let title: String

    var body: some View {
        let accent = CollectionTile.accent(for: title)
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: accent.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(accent.colour.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .cardSurface(cornerRadius: Theme.Radius.card + 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }
}
#endif
