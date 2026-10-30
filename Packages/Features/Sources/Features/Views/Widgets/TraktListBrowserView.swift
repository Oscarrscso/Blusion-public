#if canImport(UIKit)
import StremioKit
import SwiftUI

/// The New Widget screen for a Trakt list: a title, how the list is ordered, and a browser of lists and users. Choosing a list sets
/// the widget's source; Add (or Save, when editing) makes the Home carousel. It is the editor's own state, not a second editor.
struct TraktListBrowserView: View {
    let navigationTitle: String
    let actionTitle: String
    @Binding var title: String
    let titlePlaceholder: String
    @Binding var sort: TraktListSort?
    let selectedID: Int?
    let canAdd: Bool
    let select: (TraktListSummary) -> Void
    let commit: () -> Void

    @State private var browser: TraktBrowserViewModel
    @Environment(\.layoutMetrics) private var metrics

    init(services: AppServices, navigationTitle: String, actionTitle: String, title: Binding<String>, titlePlaceholder: String,
         sort: Binding<TraktListSort?>, selectedID: Int?, canAdd: Bool, select: @escaping (TraktListSummary) -> Void,
         commit: @escaping () -> Void) {
        self.navigationTitle = navigationTitle
        self.actionTitle = actionTitle
        _title = title
        self.titlePlaceholder = titlePlaceholder
        _sort = sort
        self.selectedID = selectedID
        self.canAdd = canAdd
        self.select = select
        self.commit = commit
        _browser = State(initialValue: TraktBrowserViewModel(services: services))
    }

    var body: some View {
        @Bindable var browser = browser
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if let user = browser.browsedUser { userHeader(user) }
                results
            }
            .padding(.top, Theme.Spacing.s)
        }
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
        // Margin, not padding: the last row scrolls fully clear of the tab bar and the mini-player.
        .contentMargins(.bottom, Theme.Spacing.xxl, for: .scrollContent)
        // The controls stay put while results scroll; the system's edge effect keeps rows legible under them.
        .safeAreaInset(edge: .top, spacing: 0) { controls }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollDismissesKeyboard(.interactively)
        .searchable(text: $browser.query, prompt: browser.tab == .lists ? "Search Trakt lists…" : "Search Trakt users…")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .refreshable { await browser.load(refresh: true) }
        .task(id: browser.request) {
            // A typed query waits for a pause; a tap on a tab or a chip loads at once.
            if !browser.trimmedQuery.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await browser.load()
        }
        .onChange(of: browser.tab) { browser.leaveUser() }
        .screenBackground()
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(actionTitle, action: commit)
                    .disabled(!canAdd)
                    .accessibilityIdentifier("widgetEditor.save")
            }
        }
        .environment(\.layoutMetrics, browserMetrics)
        .accessibilityIdentifier("traktBrowser")
    }

    /// The browser's page margin is the content margin, as on Home, so the chips fit the width inside the same 16pt margins as the controls above them.
    private var browserMetrics: LayoutMetrics {
        var browserMetrics = metrics
        browserMetrics.pageMargin = metrics.contentMargin
        return browserMetrics
    }

    // MARK: Sections

    /// Three rows, each its own full-width stack: title with Sort, the Lists/Users selector, and the scope chips, which fit the width
    /// inside the same 16pt margins as the rows above. Nothing shares a row with the chips, so they cannot be covered.
    private var controls: some View {
        @Bindable var browser = browser
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                titleField
                sortMenu
                    .frame(width: 128)
                    .disabled(browser.showsUsers)
            }
            .padding(.horizontal, metrics.contentMargin)
            QualitySelector(titles: TraktBrowserViewModel.Tab.allCases.map(\.rawValue), selection: Binding {
                TraktBrowserViewModel.Tab.allCases.firstIndex(of: browser.tab) ?? 0
            } set: { browser.tab = TraktBrowserViewModel.Tab.allCases[$0] },
                            symbols: ["list.bullet.rectangle", "person.2"], accessibilityID: "traktBrowser.tab")
                .padding(.horizontal, metrics.contentMargin)
            if browser.tab == .lists && browser.trimmedQuery.isEmpty && browser.browsedUser == nil { scopeChips }
        }
        .padding(.vertical, Theme.Spacing.s)
        // Solid, up under the navigation bar: the rows scroll out of sight beneath the controls. With nothing behind them the rows showed
        // through and between the glass buttons.
        .background { Theme.background.ignoresSafeArea(edges: .top) }
        .onChange(of: sort) { _, _ in Haptics.selection() }
    }

    private var titleField: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "textformat").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(titlePlaceholder.isEmpty ? "Widget title (optional)" : titlePlaceholder, text: $title)
                .font(.subheadline)
                .submitLabel(.done)
                .accessibilityIdentifier("widgetEditor.title")
        }
        .padding(.horizontal, Theme.Spacing.m)
        .frame(maxWidth: .infinity, minHeight: Self.controlHeight)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    /// The height of the title field and the Sort menu: a compact row, since three rows of controls stand above the results.
    private static let controlHeight: CGFloat = 36

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                Text("List Default").tag(TraktListSort?.none)
                ForEach(TraktListSort.allCases) { option in Text(option.title).tag(TraktListSort?.some(option)) }
            }
        } label: {
            FilterMenuLabel(sort?.title ?? "Sort", systemImage: "arrow.up.arrow.down", isActive: sort != nil, minHeight: Self.controlHeight)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(sort?.title ?? "list default")")
        .accessibilityIdentifier("traktBrowser.sort")
    }

    private var scopeChips: some View {
        @Bindable var browser = browser
        let scopes = TraktBrowserViewModel.ListScope.allCases.filter { $0 != .mine }
        return ChipRow(fittingColumns: scopes.count) {
            ForEach(scopes) { scope in
                GlassChip(scope.rawValue, isSelected: browser.scope == scope, fillsWidth: true, isTall: false) { browser.scope = scope }
            }
        }
        .accessibilityIdentifier("traktBrowser.scope")
    }

    private func userHeader(_ user: TraktUserSummary) -> some View {
        Button {
            browser.leaveUser()
        } label: {
            Label("Lists by @\(user.username)", systemImage: "chevron.left")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(GlassCapsuleButtonStyle())
        .padding(.horizontal, metrics.contentMargin)
        .accessibilityIdentifier("traktBrowser.userBack")
    }

    @ViewBuilder
    private var results: some View {
        switch browser.phase {
        case .idle:
            if browser.tab == .users {
                EmptyStateView("Find a Trakt user", systemImage: "person.2",
                               message: "Search by name to browse someone's public lists. Searching users needs your Trakt sign-in.")
                    .frame(minHeight: 260)
            }
        case .loading:
            VStack(spacing: Theme.Spacing.s) {
                ForEach(0..<7, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(Theme.surface)
                        .frame(height: 68)
                }
            }
            .padding(.horizontal, metrics.contentMargin)
            .shimmering()
            .accessibilityLabel("Loading")
        case .needsSignIn(let message):
            EmptyStateView("Sign in to Trakt", systemImage: "person.crop.circle.badge.exclamationmark", message: message)
                .frame(minHeight: 260)
        case .failed(let message):
            InlineErrorView(message) { Task { await browser.load(refresh: true) } }
                .padding(.horizontal, metrics.contentMargin)
        case .loaded:
            if browser.isEmpty {
                EmptyStateView("Nothing here", systemImage: "list.bullet.rectangle", message: browser.emptyMessage)
                    .frame(minHeight: 260)
            } else {
                rows
            }
        }
    }

    private var rows: some View {
        LazyVStack(spacing: Theme.Spacing.s) {
            if browser.showsUsers {
                ForEach(browser.users) { user in
                    Button {
                        Haptics.selection()
                        browser.browse(user: user)
                    } label: { TraktUserRow(user: user) }
                        .buttonStyle(.plain)
                        .onAppear { if user.id == LazyLoadLookahead.triggerElement(in: browser.users)?.id { Task { await browser.loadMore() } } }
                        .accessibilityIdentifier("traktBrowser.user.\(user.username)")
                }
            } else {
                ForEach(browser.lists) { list in
                    Button {
                        Haptics.selection()
                        select(list)
                    } label: { TraktListRow(list: list, isSelected: list.id == selectedID) }
                        .buttonStyle(.plain)
                        .onAppear { if list.id == LazyLoadLookahead.triggerElement(in: browser.lists)?.id { Task { await browser.loadMore() } } }
                        .accessibilityIdentifier("traktBrowser.list.\(list.slug)")
                }
            }
            if browser.isLoadingMore { Spinner().padding(Theme.Spacing.l) }
        }
        .padding(.horizontal, metrics.contentMargin)
    }
}

/// A Trakt list as a compact Liquid Glass row: name, creator with item count and likes, and a two-line description.
struct TraktListRow: View {
    let list: TraktListSummary
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            Image(systemName: list.isPrivate ? "lock.rectangle.stack" : "list.bullet.rectangle")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(list.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("@\(list.username)").lineLimit(1)
                    Label("\(list.itemCount)", systemImage: "film.stack")
                    Label("\(list.likes)", systemImage: "heart")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                if !list.description.isEmpty {
                    Text(TraktListRow.plain(list.description))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .glassCardSurface(cornerRadius: Theme.Radius.card)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(.white.opacity(0.8), lineWidth: 1.5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .pointerInteraction(cornerRadius: Theme.Radius.card)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Trakt descriptions are Markdown; a row shows them as running text.
    static func plain(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "#", with: "")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}

private struct TraktUserRow: View {
    let user: TraktUserSummary

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "person.crop.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName ?? "@\(user.username)").font(.subheadline.weight(.semibold)).lineLimit(1)
                if user.displayName != nil { Text("@\(user.username)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if user.isVIP { Badge("VIP") }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .glassCardSurface(cornerRadius: Theme.Radius.card)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .pointerInteraction(cornerRadius: Theme.Radius.card)
        .accessibilityElement(children: .combine)
    }
}
#endif
