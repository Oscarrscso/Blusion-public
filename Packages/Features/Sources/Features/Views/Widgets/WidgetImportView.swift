#if canImport(UIKit)
import SwiftUI

/// Imports widgets from pasted JSON or a URL. The action sits in the top bar, so a long paste never pushes it off the screen; the pasted
/// text scrolls inside an editor of fixed height.
struct WidgetImportView: View {
    let model: WidgetsManagerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var fromURL = false
    @State private var text = ""
    @State private var mode = WidgetsManagerViewModel.ImportMode.append

    private var canImport: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isWorking }

    var body: some View {
        Form {
            Picker("Import from", selection: $fromURL) {
                Text("Paste JSON").tag(false)
                Text("From URL").tag(true)
            }
            .pickerStyle(.segmented)
            Picker("Import mode", selection: $mode) {
                Text("Add to My Widgets").tag(WidgetsManagerViewModel.ImportMode.append)
                Text("Replace My Widgets").tag(WidgetsManagerViewModel.ImportMode.replace)
            }
            if let message = model.message, model.messageIsError {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
            if fromURL {
                TextField("https://example.com/widgets.json", text: $text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("widgetImport.url")
            } else {
                Button("Paste", systemImage: "doc.on.clipboard") { text = UIPasteboard.general.string ?? "" }
                // A fixed height: a long paste scrolls inside the editor instead of growing the form.
                TextEditor(text: $text).font(.system(.footnote, design: .monospaced)).frame(height: 240)
                    .accessibilityIdentifier("widgetImport.text")
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Import Widgets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if model.isWorking {
                    Spinner()
                } else {
                    Button(mode == .replace ? "Replace" : "Add") {
                        Task {
                            if fromURL { await model.importFromURL(text, mode: mode) } else { await model.importJSON(text, mode: mode) }
                            if !model.messageIsError { dismiss() }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!canImport)
                    .accessibilityIdentifier("widgetImport.submit")
                }
            }
        }
    }
}
#endif
