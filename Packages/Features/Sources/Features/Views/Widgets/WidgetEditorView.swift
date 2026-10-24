#if canImport(UIKit)
import StremioKit
import SwiftUI

/// The editor for a widget that is not a row: a collection (its title and tiles), Continue Watching (its title), or one this version
/// cannot show (kept, with a note). A row, spotlight or banner, new or existing, is made and changed in `WidgetBuilderView`, which this
/// view shows for it. Adding and editing differ only in the title, the button ("Add" or "Save") and whether the widget already exists.
struct WidgetEditorView: View {
    enum Mode { case create, edit }

    let model: WidgetsManagerViewModel
    let services: AppServices
    let mode: Mode
    @State private var widget: HomeWidget
    /// False while the title follows the source's name (the field then shows it as a placeholder).
    @State private var titleIsCustom = true
    @State private var showsTileSource = false
    @State private var editedTile: CollectionItem?
    @Environment(\.dismiss) private var dismiss

    /// Edits `widget`.
    init(widget: HomeWidget, model: WidgetsManagerViewModel, services: AppServices) {
        self.model = model
        self.services = services
        mode = .edit
        _widget = State(initialValue: widget)
    }

    /// Makes a new row, spotlight or banner, which `WidgetBuilderView` builds from its own default source.
    init(model: WidgetsManagerViewModel, services: AppServices) {
        self.model = model
        self.services = services
        mode = .create
        _widget = State(initialValue: HomeWidget(title: "", content: .row(RowConfiguration(source: .unsupported(kind: "")))))
    }

    private static func row(of widget: HomeWidget) -> RowConfiguration? {
        switch widget.content {
        case .row(let row), .hero(let row), .banner(let row): return row
        case .collection, .continueWatching, .unsupported: return nil
        }
    }

    var body: some View {
        if WidgetEditorView.row(of: widget) != nil {
            WidgetBuilderView(mode: mode == .create ? .create : .edit, widget: mode == .create ? nil : widget, manager: model,
                              services: services)
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            switch widget.content {
            case .collection(let tiles):
                titleSection
                tilesSection(tiles)
            case .continueWatching:
                titleSection
            case .row, .hero, .banner:
                // Never drawn here: `WidgetBuilderView` shows these.
                EmptyView()
            case .unsupported:
                Section {
                    Text("Blusion can't show this kind of row yet, so it has no settings here. It is kept so your layout stays intact.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            // Continue Watching has no removal: Home shows it whether the layout lists it or not (see the widgets page).
            if mode == .edit, WidgetsManagerViewModel.isRemovable(widget) {
                Section {
                    Button("Remove Widget", role: .destructive) {
                        Task { await model.remove(id: widget.id); dismiss() }
                    }
                    .accessibilityIdentifier("widgetEditor.remove")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .readableColumn()
        .screenBackground()
        .navigationTitle(mode == .create ? "New Widget" : "Edit Widget")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(mode == .create ? "Add" : "Save", action: commit)
                    .accessibilityIdentifier("widgetEditor.save")
            }
            if case .collection = widget.content { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
            // An existing widget, as saved, as text for Import Widgets.
            if mode != .create, let saved = model.widgets.first(where: { $0.id == widget.id }), !HomeLayout.isContinueWatching(saved),
               let text = WidgetsManagerViewModel.exportJSON(of: saved) {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: text, preview: SharePreview(saved.title)) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Export Widget")
                        .accessibilityIdentifier("widgetEditor.export")
                }
            }
        }
        .sheet(isPresented: $showsTileSource) {
            NavigationStack {
                WidgetSourcePicker(model: model, genresOnly: true, showsCancel: true) { choice, genre in
                    var reference = choice.reference
                    reference.genre = genre
                    applySource(.addonCatalog(reference), tileTitle: genre ?? choice.title)
                    showsTileSource = false
                }
            }
        }
        .sheet(item: $editedTile) { tile in
            NavigationStack {
                CollectionTileEditor(tile: tile) { changed in
                    guard case .collection(var tiles) = widget.content, let index = tiles.firstIndex(where: { $0.id == changed.id }) else { return }
                    tiles[index] = changed
                    widget.content = .collection(tiles)
                    editedTile = nil
                }
            }
        }
    }

    // MARK: Saving

    private func commit() {
        let saved = widget
        Task {
            if mode == .create { await model.add(saved) } else { await model.update(saved) }
            dismiss()
        }
    }

    // MARK: Tiles

    /// Adds a source to the collection as a tile named `tileTitle`, or after the source's own name.
    private func applySource(_ source: WidgetSource, tileTitle: String? = nil) {
        guard case .collection(var tiles) = widget.content else { return }
        tiles.append(CollectionItem(title: tileTitle ?? model.autoTitle(for: source), sources: [source]))
        widget.content = .collection(tiles)
    }

    /// The field shows only a title the user typed; an empty field means "named after the source", which the placeholder shows.
    private var titleBinding: Binding<String> {
        Binding {
            titleIsCustom ? widget.title : ""
        } set: { text in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                titleIsCustom = false
            } else {
                titleIsCustom = true
                widget.title = text
            }
        }
    }

    // MARK: Sections

    private var titleSection: some View {
        Section("Title") {
            TextField("Widget title (optional)", text: titleBinding).accessibilityIdentifier("widgetEditor.title")
            Toggle("Hide title on Home", isOn: $widget.hideTitle)
        }
    }

    private func tilesSection(_ tiles: [CollectionItem]) -> some View {
        Section("Tiles") {
            ForEach(tiles) { tile in
                Button { editedTile = tile } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tile.title)
                        if let source = tile.sources.first {
                            Text(model.describe(source)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                #if targetEnvironment(macCatalyst)
                .contextMenu {
                    Button(role: .destructive) {
                        // One tile: the first that matches this row in full, so a tile sharing an id with another is not taken instead.
                        var remaining = tiles
                        if let index = remaining.firstIndex(of: tile) { remaining.remove(at: index) }
                        widget.content = .collection(remaining)
                    } label: { Label("Delete", systemImage: "trash") }
                }
                #endif
            }
            .onDelete { offsets in widget.content = .collection(tiles.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)) }
            .onMove { offsets, destination in
                var moved = tiles
                moved.move(fromOffsets: offsets, toOffset: destination)
                widget.content = .collection(moved)
            }
            Button("Add Tile") { showsTileSource = true }
        }
    }
}

private struct CollectionTileEditor: View {
    @State private var tile: CollectionItem
    @State private var imageURL: String
    let save: (CollectionItem) -> Void
    @Environment(\.dismiss) private var dismiss

    init(tile: CollectionItem, save: @escaping (CollectionItem) -> Void) {
        _tile = State(initialValue: tile)
        _imageURL = State(initialValue: tile.imageURL?.absoluteString ?? "")
        self.save = save
    }

    var body: some View {
        Form {
            TextField("Title", text: $tile.title)
            Toggle("Hide title", isOn: $tile.hideTitle)
            Picker("Shape", selection: $tile.imageAspect) {
                ForEach(WidgetPresentation.AspectRatio.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            TextField("Image URL (optional)", text: $imageURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        }
        .scrollContentBackground(.hidden)
        .readableColumn()
        .screenBackground()
        .navigationTitle("Edit Tile")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let text = imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    tile.imageURL = text.isEmpty ? nil : URL(string: text)
                    save(tile)
                }
            }
        }
    }
}
#endif
