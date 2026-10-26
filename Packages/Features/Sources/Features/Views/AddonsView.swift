#if canImport(UIKit)
import SwiftUI
import StremioKit
#if canImport(UIKit)
import UIKit
#endif

struct AddonsView: View {
    @State private var model: AddonsViewModel
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var openURL
    /// The addon being renamed, and the name typed so far.
    @State private var renamingID: UUID?
    @State private var renameText = ""

    init(services: AppServices) {
        _model = State(initialValue: AddonsViewModel(services: services))
    }

    var body: some View {
        @Bindable var model = model
        List {
            installSection(model: $model.installText)
            if model.addons.isEmpty {
                emptySection
            } else {
                installedSection
            }
        }
        .scrollContentBackground(.hidden)
        .readableColumn()
        .screenBackground()
        .navigationTitle("Addons")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.addons.isEmpty { ToolbarItem(placement: .primaryAction) { EditButton() } }
        }
        .navigationDestination(for: UUID.self) { id in
            if let addon = model.addons.first(where: { $0.id == id }) {
                AddonDetailView(model: model, addon: addon)
            }
        }
        .task { await model.observe() }
        .onChange(of: router.addonInstallText, initial: true) {
            if let link = router.addonInstallText {
                model.prefill(link: link)
                router.addonInstallText = nil
            }
        }
        .accessibilityIdentifier("addons.list")
        .alert("Rename Addon", isPresented: isRenaming) {
            TextField("Name", text: $renameText)
                .accessibilityIdentifier("addons.renameField")
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let id = renamingID { Task { await model.rename(renameText, id: id) } }
            }
            .accessibilityIdentifier("addons.renameSave")
        } message: {
            Text("Leave it empty to use the addon's own name.")
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })
    }

    private func installSection(model text: Binding<String>) -> some View {
        Section {
            TextField("https:// or stremio:// link", text: text)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { Task { await model.install() } }
                .accessibilityIdentifier("addons.installField")
            HStack {
                #if canImport(UIKit)
                Button("Paste") { if let text = UIPasteboard.general.string { model.installText = text } }
                    .accessibilityIdentifier("addons.pasteButton")
                #endif
                Spacer()
                Button {
                    Task { await model.install() }
                } label: {
                    if model.isInstalling { Spinner() } else { Text("Install") }
                }
                .buttonStyle(.primaryActionCompact)
                .disabled(!model.canInstall)
                .accessibilityIdentifier("addons.installButton")
            }
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("addons.error")
            }
            if let name = model.lastInstalledName {
                Label("Installed \(name)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("addons.success")
            }
        } header: {
            Text("Add an addon")
        }
    }

    private var emptySection: some View {
        Section {
            Text("Paste a link above, or add Cinemeta for catalogs and search.")
                .accessibilityIdentifier("addons.emptyText")
            VStack(alignment: .leading, spacing: 6) {
                Text("Suggested: \(AddonsViewModel.suggestion.name)").font(.headline)
                Text(AddonsViewModel.suggestion.detail).font(.footnote).foregroundStyle(.secondary)
                Button("Install \(AddonsViewModel.suggestion.name)") { Task { await model.installSuggested() } }
                    .buttonStyle(.glassCapsule)
                    .accessibilityIdentifier("addons.installSuggested")
            }
        } header: {
            Text("Nothing installed")
        }
    }

    private var installedSection: some View {
        Section {
            ForEach(model.addons) { addon in
                HStack(spacing: Theme.Spacing.m) {
                    NavigationLink(value: addon.id) {
                        HStack(spacing: Theme.Spacing.m) {
                            if let logo = addon.manifest.logo {
                                ArtworkImage(url: logo, maxPixelSize: 132)
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            } else {
                                Image(systemName: "puzzlepiece.extension")
                                    .frame(width: 44, height: 44)
                                    .background(Theme.surfaceStrong, in: RoundedRectangle(cornerRadius: 10))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(addon.name).font(.headline)
                                Text("\(addon.manifest.version.isEmpty ? "" : "v\(addon.manifest.version) · ")\(addon.displayHost)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(model.capabilities(of: addon).joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Toggle("Enabled", isOn: Binding(get: { addon.isEnabled }, set: { value in
                        Haptics.selection()
                        Task { await model.setEnabled(value, id: addon.id) }
                    }))
                        .labelsHidden()
                        .accessibilityLabel("\(addon.name) enabled")
                        .accessibilityIdentifier("addons.toggle.\(addon.name)")
                }
                .accessibilityIdentifier("addons.row.\(addon.name)")
                .swipeActions {
                    Button(role: .destructive) { Task { await model.remove(id: addon.id) } } label: { Label("Remove", systemImage: "trash") }
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = addon.manifestURL.absoluteString
                        Haptics.tap()
                    } label: { Label("Copy Link", systemImage: "doc.on.doc") }
                    .accessibilityIdentifier("addons.menu.copyLink.\(addon.name)")
                    Button {
                        renameText = addon.name
                        renamingID = addon.id
                    } label: { Label("Rename", systemImage: "pencil") }
                    .accessibilityIdentifier("addons.menu.rename.\(addon.name)")
                    if addon.manifest.behaviorHints.configurable, let url = addon.configureURL {
                        Button { openURL(url) } label: { Label("Configure", systemImage: "gearshape") }
                            .accessibilityIdentifier("addons.menu.configure.\(addon.name)")
                    }
                    Divider()
                    Button(role: .destructive) { Task { await model.remove(id: addon.id) } } label: { Label("Remove", systemImage: "trash") }
                        .accessibilityIdentifier("addons.menu.remove.\(addon.name)")
                }
            }
            .onMove { offsets, destination in Task { await model.move(fromOffsets: offsets, toOffset: destination) } }
            .onDelete { offsets in
                let ids = offsets.map { model.addons[$0].id }
                Task { for id in ids { await model.remove(id: id) } }
            }
        } header: {
            Text("Installed")
        }
    }
}

struct AddonDetailView: View {
    let model: AddonsViewModel
    let addon: InstalledAddon
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let details = model.details(for: addon)
        List {
            Section("About") {
                LabeledContent("Name", value: details.name)
                if !details.version.isEmpty { LabeledContent("Version", value: details.version) }
                LabeledContent("Host", value: details.host)
                if let description = details.description { Text(description).font(.footnote) }
            }
            if !details.warnings.isEmpty {
                Section("Notes") { ForEach(details.warnings, id: \.self) { Label($0, systemImage: "info.circle") } }
            }
            Section("Provides") {
                LabeledContent("Resources", value: details.resources.joined(separator: ", "))
                if !details.types.isEmpty { LabeledContent("Types", value: details.types.joined(separator: ", ")) }
                if !details.idPrefixes.isEmpty { LabeledContent("Id prefixes", value: details.idPrefixes.joined(separator: ", ")) }
                ForEach(details.catalogs, id: \.self) { Text($0) }
            }
            Section("Manifest") {
                Text(details.manifestJSON)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("addonDetail.manifest")
            }
            Section {
                Button("Remove addon", role: .destructive) {
                    Task {
                        await model.remove(id: addon.id)
                        dismiss()
                    }
                }
                .accessibilityIdentifier("addonDetail.remove")
            }
        }
        .scrollContentBackground(.hidden)
        .readableColumn()
        .screenBackground()
        .navigationTitle(details.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
