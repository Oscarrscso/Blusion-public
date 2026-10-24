#if canImport(UIKit)
import StremioKit
import SwiftUI
import UIKit

/// The screen that makes a row, spotlight or banner, or changes a saved one. Its middle is a sentence that describes the widget, whose
/// words are its settings. Under it the settings sit in groups, two across, and the open one has its editor in a panel at the foot
/// of the screen. `WidgetBuilderModel` holds the state and the logic; this view draws it and calls it.
struct WidgetBuilderView: View {
    let manager: WidgetsManagerViewModel
    let services: AppServices
    let mode: WidgetBuilderModel.Mode
    @State private var model: WidgetBuilderModel
    @State private var showsPicker = false
    @State private var showsTraktBrowser = false
    /// True while a text field in the open panel is being edited.
    @State private var isTyping = false
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.dismiss) private var dismiss

    /// Makes a row, spotlight or banner when `widget` is nil (a TMDB list of popular movies), or changes `widget`.
    init(mode: WidgetBuilderModel.Mode, widget: HomeWidget?, manager: WidgetsManagerViewModel, services: AppServices) {
        self.mode = mode
        self.manager = manager
        self.services = services
        _model = State(initialValue: WidgetBuilderModel(mode: mode, widget: widget, manager: manager, services: services))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    if model.needsTMDbToken { tokenNotice }
                    SentenceCard(model: model)
                    PillList(model: model)
                    if mode == .edit { removeButton }
                }
                .padding(.horizontal, metrics.contentMargin)
                .padding(.vertical, Theme.Spacing.m)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            // The open setting's row is brought into view, so it stays clear of the panel at the foot of the screen.
            .onChange(of: model.selectedField) { _, field in
                guard let field else { return }
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(field) }
            }
        }
        .screenBackground()
        .navigationTitle(mode == .create ? "New Widget" : "Edit Widget")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(mode == .create ? "Add" : "Save", action: save)
                    .disabled(!model.canCommit)
                    .accessibilityIdentifier("widgetEditor.save")
            }
            // The widget as saved, as text for Import Widgets.
            if mode != .create, let saved = manager.widgets.first(where: { $0.id == model.widget.id }),
               let text = WidgetsManagerViewModel.exportJSON(of: saved) {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: text, preview: SharePreview(saved.title)) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Export Widget")
                        .accessibilityIdentifier("widgetEditor.export")
                }
            }
            // One Done key for every field of the open panel: the number pad has no return key of its own.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .navigationDestination(isPresented: $showsPicker) {
            WidgetSourcePicker(model: manager, openTraktLists: { showsTraktBrowser = true }, chooseTrakt: { source in
                model.setSource(source)
                showsPicker = false
            }) { choice, _ in
                model.setSource(.addonCatalog(choice.reference))
                showsPicker = false
            }
        }
        .navigationDestination(isPresented: $showsTraktBrowser) {
            TraktListBrowserView(services: services, navigationTitle: mode == .create ? "New Widget" : "Edit Widget",
                                 actionTitle: mode == .create ? "Add" : "Save", title: titleBinding, titlePlaceholder: model.autoTitle,
                                 sort: sortBinding, selectedID: selectedTraktID, canAdd: selectedTraktID != nil,
                                 select: { model.setSource(.traktList($0.reference(sort: model.traktSort))) }, commit: save)
        }
        .task { await model.load() }
    }

    // MARK: Bindings and state

    /// The title the user typed, or "" while it follows the source. Writing blank text makes it follow the source again.
    private var titleBinding: Binding<String> {
        Binding(get: { model.customTitle }, set: { model.setCustomTitle($0) })
    }

    private var sortBinding: Binding<TraktListSort?> {
        Binding(get: { model.traktSort }, set: { model.setTraktSort($0) })
    }

    /// The Trakt list the widget shows, by its Trakt id, so the browser can mark it.
    private var selectedTraktID: Int? {
        if case .traktList(let list) = model.row.source { return list.traktID }
        return nil
    }

    // MARK: Saving

    /// Adds the widget or saves the changes, then leaves the screen.
    private func save() {
        Task {
            await model.commit()
            // Add can be pressed on the Trakt browser, which sits over this screen. That page goes first: asked to leave from under
            // it, this screen stayed, and the only sign of the widget being added was the haptic. Then this screen leaves too, back
            // to the Widgets list, which shows the new row and its Saved mark, as after a widget made here.
            if showsTraktBrowser || showsPicker {
                showsTraktBrowser = false
                showsPicker = false
                try? await Task.sleep(for: .milliseconds(450))
            }
            dismiss()
        }
    }

    // MARK: Parts of the screen

    /// The notice that a TMDB list cannot be read until a TMDB token is saved in Settings.
    private var tokenNotice: some View {
        Text("TMDB lists need a TMDB Read Access Token. Add one in Settings › Review services, or choose another source.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }

    /// Takes the widget off Home and leaves the screen.
    private var removeButton: some View {
        Button("Remove Widget", role: .destructive) {
            Task {
                await model.removeWidget()
                dismiss()
            }
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("widgetEditor.remove")
    }

    /// The open setting's panel, at the foot of the screen. It is a safe-area inset, so it rises with the keyboard by itself.
    private var bottomBar: some View {
        VStack(spacing: Theme.Spacing.s) {
            if let field = model.selectedField {
                WidgetFieldPanel(model: model, field: field, isTyping: $isTyping,
                                 openSourcePicker: { showsPicker = true }, openTraktLists: { showsTraktBrowser = true })
                    // A new identity per setting, so each panel starts with its own fields rather than the last setting's.
                    .id(model.selectedField)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, model.selectedField == nil ? 0 : Theme.Spacing.s)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.25), value: model.selectedField)
    }
}

/// The sentence that describes the widget. Its words wrap like text; its tokens are the settings with a value, each a capsule that opens
/// the setting and, when it can be removed, has a cross that takes the value away. The kind is a dropdown.
private struct SentenceCard: View {
    let model: WidgetBuilderModel

    var body: some View {
        GlassEffectContainer(spacing: Theme.Spacing.s) {
            FlowLayout(spacing: 6) {
                ForEach(pieces) { piece in
                    pieceView(piece)
                }
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Not glass: the tokens inside are glass, and glass on glass does not read.
        .translucentPanelSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("widgetBuilder.sentence")
    }

    /// One drawn piece of the sentence: a word, the kind dropdown or a token. `trailing` is punctuation drawn glued to it.
    private struct Piece: Identifiable {
        enum Content {
            case word(String)
            case kind(TMDbDiscoverQuery.Kind)
            case token(WidgetBuilderModel.Token)
        }

        let id: String
        let content: Content
        var trailing: String?
    }

    /// The sentence as drawn pieces: each word of the plain text on its own, and punctuation glued to the piece before it, so a line never
    /// starts with a comma or a full stop.
    private var pieces: [Piece] {
        var pieces: [Piece] = []
        for item in model.sentence {
            switch item.part {
            case .text(let text) where Self.isPunctuation(text):
                if let last = pieces.indices.last {
                    pieces[last].trailing = (pieces[last].trailing ?? "") + text
                } else {
                    pieces.append(Piece(id: "\(item.id)", content: .word(text)))
                }
            case .text(let text):
                for (index, word) in text.split(whereSeparator: \.isWhitespace).enumerated() {
                    pieces.append(Piece(id: "\(item.id).\(index)", content: .word(String(word))))
                }
            case .kind(let kind):
                pieces.append(Piece(id: "\(item.id)", content: .kind(kind)))
            case .token(let token):
                pieces.append(Piece(id: "\(item.id)", content: .token(token)))
            }
        }
        return pieces
    }

    /// True for text that is only punctuation, such as "," or ".".
    private static func isPunctuation(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy(\.isPunctuation)
    }

    @ViewBuilder
    private func pieceView(_ piece: Piece) -> some View {
        HStack(spacing: 0) {
            switch piece.content {
            case .word(let word):
                Text(word)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
            case .kind(let kind):
                kindMenu(kind)
            case .token(let token):
                tokenView(token)
            }
            if let trailing = piece.trailing {
                Text(trailing)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A token: a capsule that opens its setting, with a cross beside it when the value can be taken away.
    private func tokenView(_ token: WidgetBuilderModel.Token) -> some View {
        HStack(spacing: 0) {
            Button { model.select(token.field) } label: {
                Text(token.text)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            if token.isRemovable {
                Button {
                    Haptics.tap()
                    model.remove(token)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(token.text)")
            }
        }
        .tokenCapsule()
        .overlay {
            if model.selectedField == token.field { Capsule().strokeBorder(.white, lineWidth: 1.5) }
        }
    }

    /// The movie-or-series choice: a capsule that opens a menu of the kinds, the current one checked.
    private func kindMenu(_ kind: TMDbDiscoverQuery.Kind) -> some View {
        Menu {
            ForEach(TMDbDiscoverQuery.Kind.allCases, id: \.self) { option in
                Button { model.setKind(option) } label: {
                    if option == kind {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(kind.noun)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
            }
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .tokenCapsule()
        }
        .menuIndicator(.hidden)
    }
}

/// The settings, grouped under headings by what they decide and set two across in every group, so the whole list is half as long and a
/// setting is found by its group instead of by scrolling. A group with an odd number ends on one full-width row rather than a gap.
private struct PillList: View {
    let model: WidgetBuilderModel

    /// One heading and the settings under it, in the order they are drawn.
    private struct Group: Identifiable {
        let title: String
        /// The colour of the group's symbols, so a setting's job is read from its colour before its name.
        let tint: Color
        let fields: [WidgetBuilderModel.Field]
        var id: String { title }
    }

    /// Every setting belongs to one group. A setting the widget's source does not have is simply not drawn, and a group with none is left out.
    private static let groups = [
        // Where the list comes from: blue, the colour of a link or a source.
        Group(title: "List", tint: .blue, fields: [.source, .ordering, .catalogGenre, .traktSort]),
        // What the titles are about: purple.
        Group(title: "Content", tint: .purple, fields: [.genres, .keywords, .excludedKeywords, .language, .runtime]),
        // Scores: the yellow of a star. They are IMDb's (see `TMDbDiscoverQuery.usesTMDbScores`).
        Group(title: "IMDb Ratings", tint: .yellow, fields: [.score, .votes]),
        // When and where a title can be watched: green, as for something that is available.
        Group(title: "Dates and availability", tint: .green, fields: [.period, .release, .region, .providers]),
        // The people who made it: orange.
        Group(title: "People and studios", tint: .orange, fields: [.cast, .crew, .companies]),
        // How the widget looks on Home: teal.
        Group(title: "Appearance", tint: .teal, fields: [.title, .limit, .style, .cards, .posters]),
    ]

    /// A setting whose own job says more than its group's: Exclude takes titles away, so it is red wherever it sits.
    private static let ownTints: [WidgetBuilderModel.Field: Color] = [.excludedKeywords: .red]
    private static let columns = [GridItem(.flexible(), spacing: Theme.Spacing.s), GridItem(.flexible(), spacing: Theme.Spacing.s)]

    var body: some View {
        let pills = Dictionary(model.pills.map { ($0.field, $0) }, uniquingKeysWith: { first, _ in first })
        let grouped = Set(Self.groups.flatMap(\.fields))
        // A setting added later without a group still shows, at the end, rather than vanishing.
        let ungrouped = model.pills.filter { !grouped.contains($0.field) }
        GlassEffectContainer(spacing: Theme.Spacing.s) {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                ForEach(Self.groups) { group in
                    let shown = group.fields.compactMap { pills[$0] }
                    if !shown.isEmpty { section(group.title, shown, tint: group.tint) }
                }
                if !ungrouped.isEmpty { section("More", ungrouped, tint: .secondary) }
            }
        }
    }

    private func section(_ title: String, _ pills: [WidgetBuilderModel.Pill], tint: Color) -> some View {
        // The pairs fill the grid; an odd one out takes the full width under them.
        let paired = pills.count.isMultiple(of: 2) ? pills : Array(pills.dropLast())
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            // A small dot in the group's colour leads its heading, so the heading and its symbols read as one set.
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Theme.Typography.eyebrow)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, Theme.Spacing.xs)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if !paired.isEmpty {
                LazyVGrid(columns: Self.columns, spacing: Theme.Spacing.s) {
                    ForEach(paired) { pill in row(pill, tint: tint) }
                }
            }
            if paired.count != pills.count, let last = pills.last { row(last, tint: tint) }
        }
    }

    private func row(_ pill: WidgetBuilderModel.Pill, tint: Color) -> some View {
        PillButton(model: model, pill: pill, tint: Self.ownTints[pill.field] ?? tint)
            .id(pill.field)
    }
}

/// One setting in the list: its icon, its name over its value, and a chevron that shows whether its editor is open. A row fills the page's
/// width, or its half of a pair of filters, and is at least as tall as the others, so they line up. A row that cannot be used now is faded
/// and does nothing.
private struct PillButton: View {
    let model: WidgetBuilderModel
    let pill: WidgetBuilderModel.Pill
    /// The symbol's colour, which says what kind of setting this is. The name and the value stay white.
    let tint: Color

    /// The least height of every row, so the rows of the list line up.
    static let minHeight: CGFloat = 52
    private static let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        let isOpen = model.selectedField == pill.field
        Button {
            Haptics.tap()
            model.select(pill.field)
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                // A size at which the widest symbols (three people, the masks) stay inside the box, so no icon runs into its title.
                Image(systemName: pill.systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(pill.title)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(pill.value)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, Theme.Spacing.m)
            .frame(maxWidth: .infinity, minHeight: Self.minHeight)
            .glassEffect(.regular.interactive(), in: Self.shape)
            .overlay {
                if isOpen { Self.shape.strokeBorder(.white, lineWidth: 1.5) }
            }
            .opacity(pill.isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!pill.isEnabled)
        .pointerFeedback()
        .accessibilityLabel("\(pill.title), \(pill.value)")
        .accessibilityIdentifier("widgetBuilder.pill.\(pill.field.rawValue)")
    }
}

private extension View {
    /// The capsule a token and the kind dropdown sit in: interactive glass with the sentence's padding.
    func tokenCapsule() -> some View {
        padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: Capsule())
    }
}
#endif
