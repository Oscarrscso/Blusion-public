#if canImport(UIKit)
import StremioKit
import SwiftUI

extension WidgetPresentation.AspectRatio {
    var cardAspect: CardAspect {
        switch self {
        case .poster: .poster
        case .wide: .wide
        case .square: .square
        }
    }
}

extension WidgetPresentation.CardStyle {
    var cardSize: CardSize {
        switch self {
        case .small: .small
        case .medium: .medium
        case .large: .large
        }
    }
}

/// A `.row` widget: a titled row of cards once its items have loaded. Until then, and when it has nothing to show, the same header
/// sits over a placeholder, a message or a retry, so the layout does not move when the cards arrive.
struct WidgetRow: View {
    let section: HomeViewModel.Section
    let row: RowConfiguration
    let onRetry: () -> Void
    /// Turns Better Posters on or off for this row, from its menu. Nil when the layout is automatic, where the menu offers nothing.
    let onSetBetterPosters: ((Bool) -> Void)?
    /// Removes this row from the layout, from its menu, as the widgets page does.
    let onRemove: () -> Void
    /// Opens this row in the widget editor, from its menu.
    let onEdit: () -> Void
    /// Puts a copy of this row straight after it, from its menu.
    var onDuplicate: (() -> Void)?
    /// The row as text for Import Widgets, shared from its menu.
    var exportText: String?
    @Environment(AppRouter.self) private var router
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        rowBody
            .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var rowBody: some View {
        let widget = section.widget
        let presentation = row.presentation
        if case .loaded(let items) = section.state, !items.isEmpty {
            let shelf = MediaRow(widget.title, hideTitle: widget.hideTitle, onSeeAll: {
                Haptics.tap()
                router.homePath.append(seeAllRequest)
            }) {
                ForEach(Array(items.enumerated()), id: \.element.identity) { index, item in
                    MediaCardLink(item: item, aspect: presentation.aspectRatio.cardAspect, size: presentation.cardStyle.cardSize,
                                  showsRating: presentation.showsRatings, usesBetterPosters: presentation.usesBetterPosters)
                        .overlay(alignment: .topLeading) {
                            if presentation.showsRank { RankBadge(position: index + 1) }
                        }
                }
            }
            // Long-pressing a poster row's shelf (its title or the space around the cards) offers the row's posters setting. A card keeps its
            // own hold: on iPhone it plays the card, so the row's menu is kept off the cards there; the Mac's cards have their own menu.
            #if targetEnvironment(macCatalyst)
            shelf.contextMenu { rowMenu }
            #else
            shelf.shelfMenu { rowMenu }
            #endif
        } else {
            Group {
                switch section.state {
                case .idle, .loading:
                    RowPlaceholder(header: widget.hideTitle ? .none : .title(widget.title), aspect: presentation.aspectRatio.cardAspect,
                                   size: presentation.cardStyle.cardSize)
                case .failed(let error):
                    RowFrame(title: widget.title, hideTitle: widget.hideTitle) {
                        InlineErrorView(error.shortDescription, retry: onRetry)
                            .padding(.horizontal, metrics.pageMargin)
                    }
                case .loaded:
                    RowFrame(title: widget.title, hideTitle: widget.hideTitle) {
                        if let issue = section.issue {
                            IssueMessage(issue: issue)
                        } else {
                            Text("Nothing here yet")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, metrics.pageMargin)
                        }
                    }
                }
            }
            // A row that is still loading, failed or empty can be edited or removed too, so a broken row does not stay on Home. Its menu
            // opens across the whole row, not only over the text it shows.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .contextMenu { widgetActions(for: widget, onEdit: onEdit, onDuplicate: onDuplicate, exportText: exportText, onRemove: onRemove) }
        }
    }

    /// The row's menu: its posters setting on a poster row, then what every widget's menu offers.
    @ViewBuilder
    private var rowMenu: some View {
        let widget = section.widget
        let presentation = row.presentation
        if presentation.aspectRatio == .poster, let onSetBetterPosters {
            Toggle("Better Posters", isOn: Binding(get: { presentation.usesBetterPosters }, set: onSetBetterPosters))
                .accessibilityIdentifier("board.betterPosters.\(widget.id)")
            Divider()
        }
        widgetActions(for: widget, onEdit: onEdit, onDuplicate: onDuplicate, exportText: exportText, onRemove: onRemove)
    }

    private var seeAllRequest: CatalogListRequest {
        CatalogListRequest(title: section.widget.title, sources: [row.source], presentation: row.presentation)
    }

    /// The catalog's id for an addon row, which is what UI tests look for; the widget's id for the other kinds of row.
    private var identifier: String {
        if case .addonCatalog(let reference) = row.source { return "board.row.\(reference.catalogID)" }
        return "board.row.\(section.widget.id)"
    }
}

/// The long-press menu every Home widget shares, after its own items: its editor, then its removal, set apart from it. Removal has no
/// confirmation, as the widgets page's does. Nil `onRemove` leaves removal out, for a widget Home always shows.
@ViewBuilder
func widgetActions(for widget: HomeWidget, onEdit: @escaping () -> Void, onDuplicate: (() -> Void)? = nil,
                   exportText: String? = nil, onRemove: (() -> Void)?) -> some View {
    Button("Edit Widget", systemImage: "square.and.pencil", action: onEdit)
        .accessibilityIdentifier("board.editWidget.\(widget.id)")
    if let onDuplicate {
        Button("Duplicate Widget", systemImage: "plus.square.on.square", action: onDuplicate)
            .accessibilityIdentifier("board.duplicateWidget.\(widget.id)")
    }
    // The widget as text that Import Widgets reads back, through the share sheet.
    if let exportText {
        ShareLink("Export Widget", item: exportText, preview: SharePreview(widget.title))
            .accessibilityIdentifier("board.exportWidget.\(widget.id)")
    }
    if let onRemove {
        Divider()
        Button("Remove Widget", role: .destructive, action: onRemove)
            .accessibilityIdentifier("board.removeWidget.\(widget.id)")
    }
}

/// The position of a card in a numbered row, drawn over the card's top-left corner.
struct RankBadge: View {
    let position: Int

    var body: some View {
        Text("\(position)")
            .font(.system(size: 44, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 2)
            .padding(.leading, 6)
            .padding(.top, 2)
            .allowsHitTesting(false)
            .accessibilityLabel("Number \(position)")
            .accessibilityIdentifier("board.rank.\(position)")
    }
}

/// A `.unsupported` widget: a Fusion row type this version cannot show. Kept in the layout, with its title and a plain message.
struct UnsupportedWidgetRow: View {
    let widget: HomeWidget
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        RowFrame(title: widget.title, hideTitle: widget.hideTitle) {
            Text("Blusion can't show this kind of row yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, metrics.pageMargin)
        }
        // Its menu opens across the whole row, as a row's does, not only over the text.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityIdentifier("board.unsupported.\(widget.id)")
    }
}

/// A `.collection` widget: tiles that each open a grid of their sources.
struct CollectionRow: View {
    let widget: HomeWidget
    let items: [CollectionItem]
    /// The photos of genre tiles without a picture of their own, by `HomeViewModel.tilePhotoKey`.
    var photos: [String: URL] = [:]
    @Environment(AppRouter.self) private var router

    var body: some View {
        if !items.isEmpty {
            // The genre shelf's header opens the Search tab's category browser, which lists the same genres.
            MediaRow(widget.title, hideTitle: widget.hideTitle,
                     onSeeAll: widget.id == "auto.genres" ? { router.showSearchBrowse() } : nil) {
                ForEach(items) { item in
                    NavigationLink(value: CatalogListRequest(title: item.title, sources: item.sources, presentation: WidgetPresentation())) {
                        CollectionTile(title: item.title, imageURL: item.imageURL ?? photos[HomeViewModel.tilePhotoKey(widgetID: widget.id, tile: item)],
                                       aspect: item.imageAspect.cardAspect, hideTitle: item.hideTitle)
                    }
                    .buttonStyle(PressableCardStyle.poster)
                    .titleTapHaptic()
                }
            }
            .accessibilityIdentifier("board.row.\(widget.id)")
        }
    }
}

/// The titles to resume, as wide cards with their progress. Each opens its streams, where the player resumes.
struct ContinueWatchingRow: View {
    let items: [ContinueWatchingEntry]
    let state: HomeViewModel.ContinueState
    let retry: () -> Void
    let onRemove: (ContinueWatchingEntry) -> Void
    let onMarkWatched: (ContinueWatchingEntry) -> Void
    var title = "Continue"
    var hideTitle = false
    /// Starts a card's stream from Home when Auto Pick is on. Nil opens the title's page, as with Auto Pick off.
    var launcher: ContinueWatchingLauncher?
    @Environment(AppRouter.self) private var router
    @Environment(\.layoutMetrics) private var metrics
    @State private var kind = ContinueKind.all

    var body: some View {
        let shown = items.filter { kind.includes($0.request) }
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                if !hideTitle {
                    HStack(spacing: Theme.Spacing.s) {
                        Button {
                            if let first = shown.first {
                                withAnimation(.snappy(duration: 0.28)) { proxy.scrollTo(first.id, anchor: .leading) }
                            }
                        } label: {
                            Text(title)
                        }
                        .buttonStyle(.plain)
                        .font(Theme.Typography.shelfTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .accessibilityAddTraits(.isHeader)
                        // The kind selector sits right beside the title, as the chevron does after a row title.
                        if !items.isEmpty { ContinueKindSwitch(selection: $kind) }
                        Spinner(isAnimating: state == .loading)
                            .controlSize(.small)
                            .scaleEffect(0.75)
                            .opacity(state == .loading ? 1 : 0)
                            .accessibilityLabel("Refreshing Continue")
                            .accessibilityHidden(state != .loading)
                        if !items.isEmpty {
                            if case .failed(let message) = state {
                                Button(action: retry) { Image(systemName: "arrow.clockwise") }
                                    .glassCircleButton(.small)
                                    .accessibilityLabel(message + " Retry")
                                    .help(message)
                            } else if state == .disconnected {
                                Button { router.showSettings() } label: { Image(systemName: "person.crop.circle.badge.exclamationmark") }
                                    .glassCircleButton(.small)
                                    .accessibilityLabel("Sign in to Trakt")
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, metrics.pageMargin)
                }
                if !shown.isEmpty {
                    MediaRow(title, hideTitle: true) {
                        ForEach(shown) { item in
                            let artworkID = ContentID(item.request.id).baseID
                            ProgressCard(title: item.request.title, subtitle: item.subtitle, episodeName: item.episodeName,
                                         artwork: MetahubArtwork.background(imdbID: artworkID) ?? item.request.poster,
                                         logo: MetahubArtwork.logo(imdbID: artworkID), fraction: item.fraction,
                                         duration: item.request.expectedDuration)
                            .continueWatchingHold(preview: MetaPreview(id: artworkID, type: item.request.type,
                                                                      name: item.request.seriesName ?? item.request.title,
                                                                      poster: item.request.poster, releaseInfo: item.request.year),
                                                  request: item.request, itemID: item.id, launcher: launcher,
                                                  onMarkWatched: { onMarkWatched(item) }, onRemove: { onRemove(item) })
                            .id(item.id)
                            .accessibilityIdentifier("board.continue.\(item.id)")
                        }
                    }
                } else if !items.isEmpty {
                    // Hold the rail's height, so switching to an empty kind does not move the page below.
                    Text(kind == .all ? "Nothing in progress" : "Nothing in \(kind.title.lowercased()) in progress")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: metrics.continueCardWidth / CardAspect.wide.ratio, alignment: .top)
                        .padding(.horizontal, metrics.pageMargin)
                } else {
                    emptyState
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, metrics.pageMargin)
                }
            }
            .animation(.snappy(duration: 0.28), value: kind)
            .accessibilityIdentifier("board.continueWatching")
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch state {
        case .loading:
            EmptyView()
        case .disconnected:
            HStack {
                Text("Sign in to Trakt to see paused movies and episodes.")
                Spacer(minLength: 8)
                Button("Sign In") { router.showSettings() }.buttonStyle(.glass).pointerFeedback()
            }
        case .failed(let message):
            InlineErrorView(message, retry: retry)
        case .ready:
            Text("No paused movies or episodes on Trakt.")
        }
    }
}

/// The grey stand-in for a row while its items load: the header (or a bar where the title will be), then card shapes of the
/// size and height a real card has, so the rows below do not move when the row fills in.
struct RowPlaceholder: View {
    enum Header {
        case title(String)
        /// A grey bar of a title's height, for a loading screen that does not know the row's name yet.
        case bar
        case none
    }

    let header: Header
    let aspect: CardAspect
    let size: CardSize
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.isLandscape) private var isLandscape

    var body: some View {
        let landscape = isLandscape && aspect == .poster
        let displayedAspect: CardAspect = landscape ? .wide : aspect
        let width = landscape ? (metrics.landscapePosterWidth * size.scale).rounded() : size.width(for: aspect, metrics: metrics)
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            switch header {
            case .title(let title):
                SectionHeader(title).padding(.horizontal, metrics.pageMargin)
            case .bar:
                Capsule()
                    .fill(Theme.surfaceStrong)
                    .frame(width: 150, height: 20)
                    .padding(.horizontal, metrics.pageMargin)
            case .none:
                EmptyView()
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Theme.cardSpacing) {
                    ForEach(0..<6, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            RoundedRectangle(cornerRadius: displayedAspect.cornerRadius, style: .continuous)
                                .fill(Theme.surfaceStrong)
                                .frame(width: width, height: width / displayedAspect.ratio)
                                .mediaArtwork(cornerRadius: displayedAspect.cornerRadius)
                            if !landscape {
                                VStack(alignment: .leading, spacing: 4) {
                                    Capsule().fill(Theme.surfaceStrong).frame(width: width * 0.75, height: 10)
                                    Capsule().fill(Theme.surfaceStrong).frame(width: width * 0.4, height: 8)
                                }
                                .frame(height: 34, alignment: .top)
                            }
                        }
                    }
                }
                .shimmering()
            }
            .shelfIndicators()
            .scrollDisabled(true)
            .contentMargins(.horizontal, metrics.pageMargin, for: .scrollContent)
            .scrollClipDisabled()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

/// A row's header over whatever stands in for its cards: a message, a retry or nothing to show.
private struct RowFrame<Content: View>: View {
    let title: String
    let hideTitle: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if !hideTitle {
                SectionHeader(title).padding(.horizontal, metrics.pageMargin)
            }
            content()
        }
    }
}

/// Why a row has no items, in one plain sentence. Names no addon, host or catalog: the row's title already says what it is.
struct IssueMessage: View {
    let issue: WidgetSourceError
    @Environment(AppRouter.self) private var router
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if issue == .needsTraktClientID {
                Button("Open Settings") { router.showSettings() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .pointerFeedback()
                    .accessibilityIdentifier("home.openSettings")
            }
        }
        .padding(.horizontal, metrics.pageMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `WidgetSourceError.message` names the host of a missing addon, which Home never shows.
    private var text: String {
        if case .addonMissing = issue { return "The addon for this row isn't installed or is turned off." }
        return issue.message
    }
}
#endif
