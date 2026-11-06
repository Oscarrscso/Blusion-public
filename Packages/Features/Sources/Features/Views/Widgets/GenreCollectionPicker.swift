#if canImport(UIKit)
import StremioKit
import SwiftUI

/// Adds a genre collection, one tile per genre: first the catalog whose genres the tiles open, then which of its genres, all ticked to start.
/// With one catalog that has genres, its genres show at once.
struct GenreCollectionPicker: View {
    let model: WidgetsManagerViewModel
    /// The catalog and the ticked genres, in the catalog's order.
    let add: (WidgetsManagerViewModel.CatalogChoice, [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    /// "Movie Genres" or "Series Genres" for a catalog of one of those, else "Genres", so two collections are told apart on the widgets page.
    static func title(for choice: WidgetsManagerViewModel.CatalogChoice) -> String {
        switch choice.reference.catalogType.lowercased() {
        case "movie", "series": "\(ContentTypeName.singular(choice.reference.catalogType)) Genres"
        default: "Genres"
        }
    }

    private var choices: [WidgetsManagerViewModel.CatalogChoice] { model.catalogChoices.filter { !$0.genres.isEmpty } }

    var body: some View {
        if choices.count == 1, let only = choices.first {
            GenreSelection(choice: only, showsCancel: true, add: add)
        } else {
            List {
                ForEach(choices.filter { query.isEmpty || "\($0.title) \($0.addonName)".localizedCaseInsensitiveContains(query) }) { choice in
                    NavigationLink {
                        GenreSelection(choice: choice, showsCancel: false, add: add)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(choice.title)
                            Text(choice.addonName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("genreCollection.catalog.\(choice.id)")
                }
            }
            .scrollIndicators(.visible, axes: .vertical)
            .scrollIndicatorsFlash(onAppear: true)
            .searchable(text: $query, prompt: "Find a catalog")
            .navigationTitle("Choose Catalog")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .screenBackground()
            .accessibilityIdentifier("genreCollection.catalogs")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// A catalog's genres, each ticked or not, with Add for the ticked ones.
private struct GenreSelection: View {
    let choice: WidgetsManagerViewModel.CatalogChoice
    /// True at the sheet's root, which needs its own way out; pushed, it has Back.
    let showsCancel: Bool
    let add: (WidgetsManagerViewModel.CatalogChoice, [String]) -> Void
    @State private var selected: Set<String>
    @Environment(\.dismiss) private var dismiss

    init(choice: WidgetsManagerViewModel.CatalogChoice, showsCancel: Bool,
         add: @escaping (WidgetsManagerViewModel.CatalogChoice, [String]) -> Void) {
        self.choice = choice
        self.showsCancel = showsCancel
        self.add = add
        _selected = State(initialValue: Set(choice.genres))
    }

    private var allSelected: Bool { selected.count == Set(choice.genres).count }

    var body: some View {
        List {
            Section {
                Button(allSelected ? "Deselect All" : "Select All") {
                    Haptics.play(.choices)
                    selected = allSelected ? [] : Set(choice.genres)
                }
                .accessibilityIdentifier("genreCollection.selectAll")
            }
            Section {
                ForEach(choice.genres, id: \.self) { genre in
                    Button {
                        Haptics.play(.choices)
                        if selected.contains(genre) { selected.remove(genre) } else { selected.insert(genre) }
                    } label: {
                        HStack {
                            Text(genre).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.tint)
                                .opacity(selected.contains(genre) ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(selected.contains(genre) ? .isSelected : [])
                    .accessibilityIdentifier("genreCollection.genre.\(genre)")
                }
            }
        }
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
        .navigationTitle(choice.title)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .screenBackground()
        .accessibilityIdentifier("genreCollection.genres")
        .toolbar {
            if showsCancel { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { add(choice, choice.genres.filter(selected.contains)) }
                    .disabled(selected.isEmpty)
                    .accessibilityIdentifier("genreCollection.add")
            }
        }
    }
}
#endif
