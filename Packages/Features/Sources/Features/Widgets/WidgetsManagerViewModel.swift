import Foundation
import Observation
import StremioKit

/// Settings › Widgets: the widgets that make up Home, edited in place, plus Fusion-compatible import and export.
@MainActor
@Observable
public final class WidgetsManagerViewModel {
    /// A catalog the user can pick as a row's source.
    public struct CatalogChoice: Identifiable, Hashable, Sendable {
        /// Without a genre.
        public let reference: AddonCatalogReference
        /// "Popular Movies" (`DefaultWidgets.rowTitle`).
        public let title: String
        public let addonName: String
        /// The catalog's genre options.
        public let genres: [String]

        /// `<manifestID>/<type>/<catalogID>`.
        public var id: String { "\(reference.manifestID ?? "")/\(reference.catalogType)/\(reference.catalogID)" }
    }

    public enum ImportMode: Sendable, Hashable { case append, replace }

    /// Why a Trakt list link could not be added. `message` is one plain sentence for the user.
    public enum TraktLinkError: Error, Equatable, Sendable {
        case needsClientID
        case notAListLink
        case failed(String)

        public var message: String {
            switch self {
            case .needsClientID: return "Add your Trakt API Client ID under Settings → Trakt first."
            case .notAListLink: return "That isn't a Trakt list link. Paste an address like trakt.tv/users/name/lists/list-name."
            case .failed(let reason): return "Trakt couldn't read this list (\(reason))."
            }
        }
    }

    /// An import that refers to addons which are not installed, waiting for the user's decision.
    public struct PendingImport: Equatable, Sendable {
        public let widgetCount: Int
        public let missingAddonHosts: [String]
    }

    /// One setting of a widget, such as "Card shape: Poster", as the Widgets list reveals it under the widget's row.
    public struct WidgetDetail: Identifiable, Equatable, Sendable {
        public let id: Int
        public let label: String
        public let value: String
    }

    public private(set) var widgets: [HomeWidget] = []
    public private(set) var isCustomised = false
    public private(set) var catalogChoices: [CatalogChoice] = []
    public private(set) var pendingImport: PendingImport?
    public private(set) var isWorking = false
    /// One sentence about the last action ("Imported 8 widgets.", "That isn't a widget export.") or nil.
    public private(set) var message: String?
    public private(set) var messageIsError = false
    /// Goes up by one each time a widget is added or changed, so a view can confirm the save (see `savedHUD(trigger:)`).
    public private(set) var saveRevision = 0

    /// The same limit `FusionWidgetCodec` enforces, applied to the download as well.
    private static let maxImportBytes = 2 * 1024 * 1024

    private let services: AppServices
    /// The installed addons as of the last read. `describe` cannot await, so it works from this.
    private var installedAddons: [InstalledAddon] = []
    /// An import waiting for addons. Kept in memory only: its text holds addon links, which are secrets.
    private var pendingData: Data?
    private var pendingMode: ImportMode?
    private var pendingLinks: [String] = []

    public init(services: AppServices) {
        self.services = services
    }

    // MARK: Loading and editing

    /// The saved widgets, or the automatic layout when none are saved.
    public func load() async {
        let saved = await services.widgets.load()
        let addons = await readAddons()
        // A saved layout that breaks Home's rules (its showcase out of place, a second showcase, or no Continue Watching) is put right as
        // it is shown, and saved once. The automatic layout keeps them already.
        let shown = saved.map { HomeLayout.normalised($0) } ?? DefaultWidgets.make(for: addons)
        widgets = shown
        isCustomised = saved != nil
        if let saved, shown != saved { await services.widgets.save(shown) }
    }

    /// Whether a widget is Home's showcase: a spotlight.
    nonisolated public static func isShowcase(_ widget: HomeWidget) -> Bool {
        HomeLayout.isShowcase(widget)
    }

    /// Continue Watching and the showcase are one of a kind, so they are not duplicated.
    nonisolated public static func isDuplicable(_ widget: HomeWidget) -> Bool {
        !HomeLayout.isContinueWatching(widget) && !HomeLayout.isShowcase(widget)
    }

    /// `list` with a copy of the widget `id` straight after it: the same kind, title, source, filters and look, under `newID`. Nil when
    /// the list has no such widget, or it is one that is not duplicated.
    nonisolated public static func duplicating(_ id: String, in list: [HomeWidget],
                                               newID: String = UUID().uuidString) -> [HomeWidget]? {
        guard let index = list.firstIndex(where: { $0.id == id }), isDuplicable(list[index]) else { return nil }
        var copy = list[index]
        copy.id = newID
        var result = list
        result.insert(copy, at: index + 1)
        return result
    }

    /// Continue Watching is not removed: Home shows it whether the layout lists it or not, so removing it would only move it above the
    /// showcase. It is moved like any other widget.
    nonisolated public static func isRemovable(_ widget: HomeWidget) -> Bool {
        !HomeLayout.isContinueWatching(widget)
    }

    /// The list as it is saved now, or nil when the change must not be made. Another manager or an editor may have saved since this one
    /// loaded, and a change from an older copy would save over those edits, so every change starts here. Nothing saved while this list
    /// was customised means the layout was reset elsewhere: this list becomes the automatic one, and the change is refused.
    private func savedList() async -> [HomeWidget]? {
        guard let saved = await services.widgets.load() else {
            guard isCustomised else { return widgets }
            let addons = await readAddons()
            widgets = DefaultWidgets.make(for: addons)
            isCustomised = false
            changedElsewhere()
            return nil
        }
        // Read with Home's rules kept, as `load` shows it, so a change compares like with like.
        let normal = HomeLayout.normalised(saved)
        widgets = normal
        isCustomised = true
        return normal
    }

    /// The change was made from a list that has since changed elsewhere. Nothing is saved, and the list now shows the saved one.
    private func changedElsewhere() {
        report("These widgets changed elsewhere. Try again.", isError: true)
    }

    /// The widgets page's shuffle settings: the schedule for every widget without its own, and whether Home's widgets are shuffled too.
    public private(set) var shuffle = WidgetShuffleSettings()

    /// Reads the shuffle settings.
    public func loadShuffle() async {
        shuffle = await services.widgetShuffle.settings()
    }

    /// Saves the shuffle settings. Turning the schedule off stops shuffling Home's widgets too.
    public func setShuffle(_ settings: WidgetShuffleSettings) async {
        var settings = settings
        if settings.schedule == .off { settings.shufflesOrder = false }
        shuffle = settings
        await services.widgetShuffle.save(settings)
    }

    /// Appended at the end. A widget whose id the list already uses gets a new one.
    public func add(_ widget: HomeWidget) async {
        guard let current = await savedList() else { return }
        let fresh = WidgetsManagerViewModel.withFreshIDs([widget], existing: current)
        // A showcase is kept to one, and at the top: a second one is not added.
        if fresh.contains(where: WidgetsManagerViewModel.isShowcase), current.contains(where: WidgetsManagerViewModel.isShowcase) {
            report("Home has a showcase already, and it stays at the top.", isError: true)
            return
        }
        await commit(current + fresh)
        saveRevision += 1
    }

    /// Replaces the widget with the same id. An unknown id changes nothing, and says why.
    public func update(_ widget: HomeWidget) async {
        guard var list = await savedList() else { return }
        guard let index = list.firstIndex(where: { $0.id == widget.id }) else {
            report("This widget was removed elsewhere, so the change was not saved.", isError: true)
            return
        }
        if WidgetsManagerViewModel.isShowcase(widget),
           list.contains(where: { $0.id != widget.id && WidgetsManagerViewModel.isShowcase($0) }) {
            report("Home has a showcase already, and it stays at the top.", isError: true)
            return
        }
        list[index] = widget
        await commit(list)
        saveRevision += 1
    }

    /// Puts a copy of the widget straight after it, and saves. Home lists its widgets in the same saved order.
    public func duplicate(id: String) async {
        guard let current = await savedList() else { return }
        guard current.contains(where: { $0.id == id }) else {
            report("This widget was removed elsewhere, so it was not duplicated.", isError: true)
            return
        }
        guard let list = WidgetsManagerViewModel.duplicating(id, in: current) else { return }
        await commit(list)
        saveRevision += 1
    }

    public func remove(id: String) async {
        guard let current = await savedList() else { return }
        guard let widget = current.first(where: { $0.id == id }), WidgetsManagerViewModel.isRemovable(widget) else { return }
        await commit(current.filter { $0.id != id })
    }

    public func remove(atOffsets offsets: IndexSet) async {
        let shown = widgets.map(\.id)
        guard let current = await savedList() else { return }
        guard current.map(\.id) == shown else { changedElsewhere(); return }
        let kept = current.enumerated()
            .filter { !offsets.contains($0.offset) || !WidgetsManagerViewModel.isRemovable($0.element) }
            .map(\.element)
        guard kept.count < current.count else { return }
        await commit(kept)
    }

    /// SwiftUI `onMove` shape: the widgets at `offsets` end up before `destination`, an index into the list as it is now.
    public func move(fromOffsets offsets: IndexSet, toOffset destination: Int) async {
        let shown = widgets.map(\.id)
        guard let current = await savedList() else { return }
        guard current.map(\.id) == shown else { changedElsewhere(); return }
        let moved = offsets.filter { current.indices.contains($0) }
        guard !moved.isEmpty else { return }
        let moving = moved.map { current[$0] }
        // The showcase is pinned at the top: it cannot be moved.
        guard !moving.contains(where: WidgetsManagerViewModel.isShowcase) else { return }
        var list = current.enumerated().filter { !moved.contains($0.offset) }.map(\.element)
        let insertion = destination - moved.filter { $0 < destination }.count
        list.insert(contentsOf: moving, at: min(max(insertion, 0), list.count))
        await commit(list)
    }

    /// Forgets the saved list: Home goes back to the automatic layout for the installed addons.
    public func resetToAutomatic() async {
        let addons = await readAddons()
        widgets = DefaultWidgets.make(for: addons)
        isCustomised = false
        clearMessage()
        await services.widgets.save(nil)
        await services.widgetContent.invalidate()
    }

    /// The public Trakt list a pasted link names, read from Trakt so the row gets its real name.
    public func traktList(fromLink text: String) async throws -> TraktListReference {
        guard let parts = TraktClient.listReference(fromLink: text) else { throw TraktLinkError.notAListLink }
        let clientID = await TraktClient.clientID(in: services.settings)
        guard !clientID.isEmpty else { throw TraktLinkError.needsClientID }
        do {
            let info = try await services.trakt.listInfo(username: parts.username, listSlug: parts.listSlug, clientID: clientID)
            return TraktListReference(username: parts.username, listSlug: parts.listSlug, listName: info.name, traktID: info.traktID)
        } catch {
            throw TraktLinkError.failed(AddonError.from(error).shortDescription.lowercased())
        }
    }

    // MARK: Import and export

    /// Reads Fusion's widget JSON. `.replace` swaps the whole list; `.append` adds to its end.
    public func importJSON(_ text: String, mode: ImportMode) async {
        await importData(Data(text.utf8), mode: mode)
    }

    /// Downloads a widget file from an http(s) link, then imports it like `importJSON`.
    public func importFromURL(_ text: String, mode: ImportMode) async {
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            report("That isn't a web link. Paste an address that starts with https://.", isError: true)
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await services.client.get(url, limits: FetchLimits(maxBytes: WidgetsManagerViewModel.maxImportBytes))
            await importData(result.data, mode: mode)
        } catch {
            report("Couldn't download the widget file (\(AddonError.from(error).shortDescription.lowercased())).", isError: true)
        }
    }

    /// Installs the addons a pending import needs, then saves the import now that its links resolve.
    public func installMissingAddonsAndFinishImport() async {
        guard let data = pendingData, let mode = pendingMode else { return }
        let links = pendingLinks
        isWorking = true
        var installed = 0
        var failed = 0
        for link in links {
            do {
                try await services.registry.install(from: link)
                installed += 1
            } catch RegistryError.alreadyInstalled {
                continue
            } catch {
                failed += 1
            }
        }
        isWorking = false
        await finishImport(data, mode: mode, installed: installed, failed: failed)
    }

    /// Saves the pending import as it is. Widgets whose addon is missing say so on Home.
    public func finishImportWithoutAddons() async {
        guard let data = pendingData, let mode = pendingMode else { return }
        await finishImport(data, mode: mode, installed: 0, failed: 0)
    }

    public func cancelImport() {
        clearPending()
    }

    /// The current widgets as Fusion-compatible JSON text (pretty printed), or nil if encoding fails.
    public func exportJSON() -> String? {
        guard let data = try? FusionWidgetCodec.encode(widgets) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// One widget as the same JSON text, which Import Widgets reads back as that one widget. Nil if encoding fails.
    nonisolated public static func exportJSON(of widget: HomeWidget) -> String? {
        guard let data = try? FusionWidgetCodec.encode([widget]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes an import off the main actor. Addons it needs that are not installed hold it until the user decides; otherwise it is saved.
    private func importData(_ data: Data, mode: ImportMode) async {
        clearPending()
        let addons = await readAddons()
        let result: FusionWidgetCodec.ImportResult
        do {
            result = try await Task.detached { try FusionWidgetCodec.decode(data, installed: addons) }.value
        } catch {
            report(WidgetsManagerViewModel.refusal(error), isError: true)
            return
        }
        guard result.missingAddonLinks.isEmpty else {
            // The links are secrets: they stay in memory, and only their hosts are shown.
            pendingData = data
            pendingMode = mode
            pendingLinks = result.missingAddonLinks
            pendingImport = PendingImport(widgetCount: result.widgets.count, missingAddonHosts: result.missingAddonHosts)
            clearMessage()
            return
        }
        guard let added = await store(result, mode: mode) else { return }
        report(WidgetsManagerViewModel.importSummary(count: added, skipped: result.skipped), isError: false)
    }

    /// Decodes a pending import again, now that its addons may be installed, and saves it.
    private func finishImport(_ data: Data, mode: ImportMode, installed: Int, failed: Int) async {
        clearPending()
        let addons = await readAddons()
        do {
            let result = try await Task.detached { try FusionWidgetCodec.decode(data, installed: addons) }.value
            guard let added = await store(result, mode: mode) else { return }
            report(WidgetsManagerViewModel.importSummary(count: added, skipped: result.skipped, installed: installed, failed: failed), isError: false)
        } catch {
            report(WidgetsManagerViewModel.refusal(error), isError: true)
        }
    }

    /// Saves what an import read, and returns how many widgets it brought in.
    private func store(_ result: FusionWidgetCodec.ImportResult, mode: ImportMode) async -> Int? {
        // Only an append builds on the saved list, so a replace is not held back by a list reset elsewhere.
        var current: [HomeWidget] = []
        if mode == .append {
            guard let saved = await savedList() else { return nil }
            current = saved
        }
        // Home has one Continue Watching: an append does not add a second.
        let incoming = current.contains(where: HomeLayout.isContinueWatching)
            ? result.widgets.filter { !HomeLayout.isContinueWatching($0) } : result.widgets
        let imported = WidgetsManagerViewModel.withFreshIDs(incoming, existing: current)
        await commit(mode == .append ? current + imported : imported)
        return imported.count
    }

    // MARK: Describing sources and widgets

    /// "Popular Movies · Cinemeta", "Trakt list · Daily Picks by tvgeniekodi", "Not supported (anilistCatalog)",
    /// "Catalog from example.com (addon not installed)".
    public func describe(_ source: WidgetSource) -> String {
        switch source {
        case .addonCatalog(let reference):
            guard let match = reference.resolve(in: installedAddons) else {
                guard let host = reference.host else { return "Catalog (addon not installed)" }
                return "Catalog from \(host) (addon not installed)"
            }
            var parts = [DefaultWidgets.rowTitle(catalogName: match.catalog.name, type: match.catalog.type)]
            if let genre = reference.genre, !genre.isEmpty { parts.append(genre) }
            parts.append(match.addon.name)
            return parts.joined(separator: " · ")
        case .traktList(let list):
            let sort = list.sort.map { " · \($0.title)" } ?? ""
            return "Trakt list · \(list.listName) by \(list.username)\(sort)"
        case .traktFeed(let feed):
            return "Trakt · \(feed.title)"
        case .tmdbDiscover(let query):
            return query.summary
        case .unsupported(let kind):
            return "Not supported (\(kind))"
        }
    }

    /// A short summary for a widget's row in the manager list: "Row · Popular Movies · Cinemeta", "Collection · 12 tiles", and so on.
    public func summary(of widget: HomeWidget) -> String {
        switch widget.content {
        case .row(let row): return "Row · \(describe(row.source))"
        case .hero(let row): return "Spotlight · \(describe(row.source))"
        case .banner(let row): return "Banner · \(describe(row.source))"
        case .collection(let tiles): return "Collection · \(WidgetsManagerViewModel.plural(tiles.count, "tile"))"
        case .continueWatching: return "Continue"
        case .unsupported(let type): return "Can't show yet · \(type)"
        }
    }

    /// Every setting of a widget, in the order the editor shows them, for the Widgets list to reveal under its row. A collection lists each
    /// tile with its sources.
    public func details(of widget: HomeWidget) -> [WidgetDetail] {
        var lines: [(label: String, value: String)] = [("Type", WidgetsManagerViewModel.kindName(of: widget))]
        switch widget.content {
        case .row(let row), .hero(let row), .banner(let row):
            let presentation = row.presentation
            lines += [
                ("Source", describe(row.source)),
                ("Items", "\(row.limit)"),
                ("Card shape", WidgetsManagerViewModel.name(of: presentation.aspectRatio)),
                ("Card size", WidgetsManagerViewModel.name(of: presentation.cardStyle)),
                ("Ratings", WidgetsManagerViewModel.yesNo(presentation.showsRatings)),
                ("Providers", WidgetsManagerViewModel.yesNo(presentation.showsProviders)),
                ("Numbered", WidgetsManagerViewModel.yesNo(presentation.showsRank)),
                ("Better Posters", WidgetsManagerViewModel.yesNo(presentation.usesBetterPosters)),
                ("Saved for", WidgetsManagerViewModel.savedText(seconds: row.cacheTTL)),
            ]
        case .collection(let tiles):
            lines.append(("Tiles", WidgetsManagerViewModel.plural(tiles.count, "tile")))
            for tile in tiles {
                let sources = tile.sources.map { describe($0) }.joined(separator: " + ")
                lines.append((tile.title.isEmpty ? "Untitled tile" : tile.title, sources.isEmpty ? "No source" : sources))
            }
        case .continueWatching:
            lines.append(("Shows", "Titles in progress, from Trakt and this device"))
        case .unsupported:
            lines.append(("Status", "Blusion can't show this kind of row yet."))
        }
        lines.append(("Title", widget.hideTitle ? "Hidden" : "Shown"))
        return lines.enumerated().map { WidgetDetail(id: $0.offset, label: $0.element.label, value: $0.element.value) }
    }

    private static func kindName(of widget: HomeWidget) -> String {
        switch widget.content {
        case .row(let row): return row.presentation.showsRank ? "Numbered row" : "Row"
        case .hero: return "Spotlight"
        case .banner: return "Banner"
        case .collection: return "Collection"
        case .continueWatching: return "Continue Watching"
        case .unsupported(let type): return "Not supported (\(type))"
        }
    }

    private static func name(of ratio: WidgetPresentation.AspectRatio) -> String {
        switch ratio {
        case .poster: return "Poster"
        case .wide: return "Wide"
        case .square: return "Square"
        }
    }

    private static func name(of style: WidgetPresentation.CardStyle) -> String {
        switch style {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    /// How long a loaded page is kept: "1 hour", "5 minutes", or "Not saved" when it is always asked again.
    private static func savedText(seconds: Int) -> String {
        if seconds == 0 { return "Not saved" }
        if seconds % 3600 == 0 { return plural(seconds / 3600, "hour") }
        if seconds % 60 == 0 { return plural(seconds / 60, "minute") }
        return plural(seconds, "second")
    }

    /// The name a source gives a widget unless the user types another: the genre or catalog title, the Trakt list or feed name.
    public func autoTitle(for source: WidgetSource) -> String {
        switch source {
        case .addonCatalog(let reference):
            if let genre = reference.genre, !genre.isEmpty { return genre }
            guard let match = reference.resolve(in: installedAddons) else { return "" }
            return DefaultWidgets.rowTitle(catalogName: match.catalog.name, type: match.catalog.type)
        case .traktList, .traktFeed:
            return WidgetsManagerViewModel.traktTitle(source)
        case .tmdbDiscover(let query):
            return query.title
        case .unsupported:
            return ""
        }
    }

    /// The genres a catalog offers as a filter; empty when it has none or its addon is not installed.
    public func genres(for source: WidgetSource) -> [String] {
        guard case .addonCatalog(let reference) = source, let match = reference.resolve(in: installedAddons) else { return [] }
        return match.catalog.genreOptions
    }

    // MARK: Making widgets

    /// A row of one catalog, optionally filtered to a genre. Gets a new id.
    public static func makeRow(title: String, choice: CatalogChoice, genre: String? = nil, presentation: WidgetPresentation = WidgetPresentation(),
                               limit: Int = 20) -> HomeWidget {
        let row = RowConfiguration(source: .addonCatalog(catalogReference(choice, genre: genre)), presentation: presentation, limit: limit)
        return HomeWidget(title: title, content: .row(row))
    }

    /// A row of a Trakt list or feed, titled as the list or feed is named.
    public static func makeTraktRow(_ source: WidgetSource) -> HomeWidget {
        HomeWidget(title: traktTitle(source), content: .row(RowConfiguration(source: source)))
    }

    /// The large paging spotlight of a Trakt list or feed.
    public static func makeTraktSpotlight(_ source: WidgetSource) -> HomeWidget {
        HomeWidget(title: traktTitle(source), hideTitle: true, content: .hero(RowConfiguration(source: source, limit: 8)))
    }

    /// The featured banner of a Trakt list: its first title large, the rest in a row below.
    public static func makeTraktBanner(_ source: WidgetSource) -> HomeWidget {
        HomeWidget(title: traktTitle(source), content: .banner(RowConfiguration(source: source, limit: 20)))
    }

    /// The name a Trakt list or feed is shown under, or "Trakt" for any other source.
    public static func traktTitle(_ source: WidgetSource) -> String {
        switch source {
        case .traktList(let list): return list.listName
        case .traktFeed(let feed): return feed.title
        case .addonCatalog, .tmdbDiscover, .unsupported: return "Trakt"
        }
    }

    /// The large paging spotlight of one catalog, as the automatic layout makes it.
    public static func makeHero(choice: CatalogChoice, genre: String? = nil) -> HomeWidget {
        let row = RowConfiguration(source: .addonCatalog(catalogReference(choice, genre: genre)), limit: 8)
        return HomeWidget(title: choice.title, hideTitle: true, content: .hero(row))
    }

    /// The featured banner of one catalog, as the add sheet makes it.
    public static func makeBanner(choice: CatalogChoice, genre: String? = nil) -> HomeWidget {
        let row = RowConfiguration(source: .addonCatalog(catalogReference(choice, genre: genre)), limit: 20)
        return HomeWidget(title: choice.title, content: .banner(row))
    }

    /// A collection with one tile per genre of the catalog. Each tile opens that genre's grid.
    public static func makeGenreCollection(title: String, choice: CatalogChoice) -> HomeWidget {
        var seen = Set<String>()
        let tiles = choice.genres.filter { seen.insert($0).inserted }.map { genre in
            CollectionItem(id: "\(choice.id)/\(genre)", title: genre, imageAspect: .wide, sources: [.addonCatalog(catalogReference(choice, genre: genre))])
        }
        return HomeWidget(title: title, content: .collection(tiles))
    }

    // MARK: Helpers

    private static func catalogReference(_ choice: CatalogChoice, genre: String?) -> AddonCatalogReference {
        var reference = choice.reference
        if let genre, !genre.isEmpty { reference.genre = genre }
        return reference
    }

    /// Every browsable catalog of the enabled addons, in the user's addon order. Addons that share a manifest id offer each catalog once.
    private static func choices(in addons: [InstalledAddon]) -> [CatalogChoice] {
        var seen = Set<String>()
        var choices: [CatalogChoice] = []
        for addon in addons where addon.isEnabled {
            for catalog in addon.manifest.browsableCatalogs() {
                let reference = AddonCatalogReference(manifestID: addon.manifest.id, host: addon.displayHost, catalogType: catalog.type,
                                                      catalogID: catalog.id)
                let choice = CatalogChoice(reference: reference, title: DefaultWidgets.rowTitle(catalogName: catalog.name, type: catalog.type),
                                           addonName: addon.name, genres: catalog.genreOptions)
                if seen.insert(choice.id).inserted { choices.append(choice) }
            }
        }
        return choices
    }

    /// The widgets with ids unused in `existing` and in the list itself. A repeated id gets a new one.
    private static func withFreshIDs(_ list: [HomeWidget], existing: [HomeWidget]) -> [HomeWidget] {
        var taken = Set(existing.map(\.id))
        return list.map { widget in
            var fresh = widget
            if !taken.insert(widget.id).inserted { fresh.id = UUID().uuidString }
            return fresh
        }
    }

    /// "Imported 8 widgets, skipped 2." After an install: "Imported 8 widgets and installed 1 addon. 1 addon couldn't be installed."
    private static func importSummary(count: Int, skipped: Int, installed: Int = 0, failed: Int = 0) -> String {
        var text = "Imported \(plural(count, "widget"))"
        if installed > 0 { text += " and installed \(plural(installed, "addon"))" }
        if skipped > 0 { text += ", skipped \(skipped)" }
        text += "."
        if failed > 0 { text += " \(plural(failed, "addon")) couldn't be installed." }
        return text
    }

    private static func refusal(_ error: Error) -> String {
        (error as? WidgetImportError)?.message ?? "That isn't a widget export."
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(count == 1 ? noun : noun + "s")"
    }

    /// Shows and saves a new list. The first change to the automatic layout saves the whole layout with the change.
    private func commit(_ list: [HomeWidget]) async {
        // Every saved layout keeps Home's rules: the showcase first and alone (an import's other showcases become banners), and Continue
        // Watching in the list.
        let normal = HomeLayout.normalised(list)
        widgets = normal
        isCustomised = true
        clearMessage()
        await services.widgets.save(normal)
        await services.widgetContent.invalidate()
    }

    /// Reads the installed addons, and the catalog choices they offer. Called wherever an install or import may have changed them.
    private func readAddons() async -> [InstalledAddon] {
        let addons = await services.registry.addons
        installedAddons = addons
        catalogChoices = WidgetsManagerViewModel.choices(in: addons)
        return addons
    }

    private func report(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }

    private func clearMessage() {
        message = nil
        messageIsError = false
    }

    private func clearPending() {
        pendingImport = nil
        pendingData = nil
        pendingMode = nil
        pendingLinks = []
    }
}
