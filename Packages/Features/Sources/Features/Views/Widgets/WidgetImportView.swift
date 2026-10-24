#if canImport(UIKit)
import SwiftUI

struct WidgetImportView: View {
    let model: WidgetsManagerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var fromURL = false
    @State private var text = ""
    @State private var mode = WidgetsManagerViewModel.ImportMode.append

    var body: some View {
        Form {
            Picker("Import from", selection: $fromURL) {
                Text("Paste JSON").tag(false)
                Text("From URL").tag(true)
            }
            .pickerStyle(.segmented)
            if fromURL {
                TextField("https://example.com/widgets.json", text: $text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("widgetImport.url")
            } else {
                TextEditor(text: $text).font(.system(.footnote, design: .monospaced)).frame(minHeight: 180)
                    .accessibilityIdentifier("widgetImport.text")
                Button("Paste") { text = UIPasteboard.general.string ?? "" }
            }
            Picker("Import mode", selection: $mode) {
                Text("Add to My Widgets").tag(WidgetsManagerViewModel.ImportMode.append)
                Text("Replace My Widgets").tag(WidgetsManagerViewModel.ImportMode.replace)
            }
            Section {
                Button("Import") {
                    Task {
                        if fromURL { await model.importFromURL(text, mode: mode) } else { await model.importJSON(text, mode: mode) }
                        if !model.messageIsError { dismiss() }
                    }
                }
                .buttonStyle(.primaryAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
                .accessibilityIdentifier("widgetImport.submit")
                if let message = model.message, model.messageIsError { Text(message).font(.footnote).foregroundStyle(.orange) }
            } footer: {
                Text("Works with widget exports from Fusion and with links to a JSON file.")
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Import Widgets")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}
#endif
