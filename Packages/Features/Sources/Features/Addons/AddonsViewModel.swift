import Foundation
import Observation
import StremioKit

public struct SuggestedAddon: Sendable, Equatable {
    public let name: String
    public let detail: String
    public let manifestURL: String
    /// The id in the addon's manifest, for recognising it once installed.
    public let manifestID: String

    /// Stremio's official metadata addon: catalogs, search and metadata, no streams.
    public static let cinemeta = SuggestedAddon(name: "Cinemeta", detail: "Official catalogs and metadata (no streams)",
                                                manifestURL: "https://v3-cinemeta.strem.io/manifest.json", manifestID: "com.linvo.cinemeta")
}

/// What the "view manifest" screen shows. Never includes the addon's URL (it may embed a token), only its host.
public struct AddonDetails: Sendable, Equatable {
    public let name: String
    public let version: String
    public let description: String?
    public let host: String
    public let resources: [String]
    public let types: [String]
    public let catalogs: [String]
    public let idPrefixes: [String]
    public let warnings: [String]
    public let manifestJSON: String
}

/// Addons screen: install by URL or paste, remove, reorder, enable, inspect.
@MainActor
@Observable
public final class AddonsViewModel {
    /// Offered on the empty state. It is also the addon `DefaultAddonSeeder` installs on first launch.
    public static let suggestion = SuggestedAddon.cinemeta

    public private(set) var addons: [InstalledAddon] = []
    public var installText = ""
    public private(set) var isInstalling = false
    public private(set) var errorMessage: String?
    public private(set) var lastInstalledName: String?

    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    public var canInstall: Bool { !installText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isInstalling }

    /// Keeps `addons` in sync with the registry. Run from a view's `.task`.
    public func observe() async {
        for await current in await services.registry.updates() { addons = current }
    }

    public func install() async {
        guard canInstall else { return }
        await install(from: installText) { [self] in installText = "" }
    }

    public func installSuggested() async {
        await install(from: Self.suggestion.manifestURL, onSuccess: {})
    }

    private func install(from input: String, onSuccess: @MainActor () -> Void) async {
        isInstalling = true
        errorMessage = nil
        lastInstalledName = nil
        defer { isInstalling = false }
        do {
            let addon = try await services.registry.install(from: input)
            lastInstalledName = addon.name
            onSuccess()
        } catch let error as RegistryError {
            errorMessage = error.message
        } catch {
            errorMessage = "Couldn't install the addon."
        }
    }

    public func clearMessages() {
        errorMessage = nil
        lastInstalledName = nil
    }

    /// Puts a link the app was opened with into the install field, for the user to confirm, and clears old messages.
    public func prefill(link: String) {
        installText = link
        clearMessages()
    }

    /// What an addon offers, as short labels in a fixed order. Only what is true is listed.
    public func capabilities(of addon: InstalledAddon) -> [String] {
        let manifest = addon.manifest
        var labels: [String] = []
        if !manifest.catalogs.isEmpty { labels.append("Catalogs") }
        if !manifest.searchableCatalogs.isEmpty { labels.append("Search") }
        if manifest.provides(.meta) { labels.append("Metadata") }
        if manifest.provides(.stream) { labels.append("Streams") }
        if manifest.provides(.subtitles) { labels.append("Subtitles") }
        return labels
    }

    public func remove(id: UUID) async {
        await perform { try await $0.remove(id: id) }
    }

    public func setEnabled(_ enabled: Bool, id: UUID) async {
        await perform { try await $0.setEnabled(enabled, id: id) }
    }

    /// Blank clears the custom name, so the manifest's own name shows again.
    public func rename(_ name: String, id: UUID) async {
        await perform { try await $0.rename(name, id: id) }
    }

    public func move(fromOffsets offsets: IndexSet, toOffset destination: Int) async {
        await perform { try await $0.move(fromOffsets: offsets, toOffset: destination) }
    }

    private func perform(_ action: (AddonRegistry) async throws -> Void) async {
        do { try await action(services.registry) } catch let error as RegistryError {
            errorMessage = error.message
        } catch {
            errorMessage = "Something went wrong."
        }
    }

    public func details(for addon: InstalledAddon) -> AddonDetails {
        let manifest = addon.manifest
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(manifest)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return AddonDetails(
            name: addon.name,
            version: manifest.version,
            description: manifest.description,
            host: addon.displayHost,
            resources: manifest.resources.map(\.name),
            types: manifest.types,
            catalogs: manifest.catalogs.map { "\($0.name) (\($0.type))" },
            idPrefixes: manifest.idPrefixes ?? [],
            warnings: manifest.validate().filter { $0.severity == .warning }.map(\.message),
            manifestJSON: json)
    }
}
