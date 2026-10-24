import Foundation
import Observation
import StremioKit

/// Search: debounced, fans out to every searchable addon, and shows per-addon error chips instead of failing as a whole.
/// Results come per addon (`sections`) and per content type (`groups`, what the screen shows).
@MainActor
@Observable
public final class SearchViewModel {
    public struct Section: Identifiable, Equatable {
        public let addon: AddonSummary
        public var items: [MetaPreview]
        public var id: UUID { addon.id }
    }

    /// The results of one content type across every addon: one row on the Search screen.
    public struct Group: Identifiable, Equatable {
        public let type: String
        public let title: String
        public var items: [MetaPreview]
        public var id: String { type }
    }

    public struct Failure: Identifiable, Equatable {
        public let addon: AddonSummary
        public let error: AddonError
        public var id: UUID { addon.id }
        public var text: String { "\(addon.name): \(error.shortDescription)" }
    }

    public enum Phase: Equatable {
        case idle
        case searching
        case done
    }

    /// Independent of the normal addon search; the AI row keeps showing a spinner until its own work ends.
    public private(set) var aiPhase: Phase = .idle
    public private(set) var aiStage: AISearchUpdate.Stage = .interpreting
    public private(set) var aiIssue: AISearchUpdate.Issue?
    private var aiRequestID = UUID()

    /// A genre of one catalog, offered on the idle Search page. `source` opens that catalog filtered to the genre.
    public struct GenreShortcut: Identifiable, Hashable, Sendable {
        public let name: String
        public let source: WidgetSource
        public var id: String { name }

        public init(name: String, source: WidgetSource) {
            self.name = name
            self.source = source
        }
    }

    public var query = ""
    public private(set) var sections: [Section] = []
    public private(set) var failures: [Failure] = []
    public private(set) var phase: Phase = .idle
    /// False when no enabled addon offers a searchable catalog. A search then does no network work. See `refreshAvailability()`.
    public private(set) var hasSearchableAddons = true
    /// Genres to browse from the idle Search page. Filled by `refreshAvailability()`.
    public private(set) var browseGenres: [GenreShortcut] = []
    /// The last titles opened from Search, newest first, at most 4. Kept in the history store.
    public private(set) var recentQueries: [String]

    private static let maxRecents = 4
    private static let maxGenres = 16

    private let services: AppServices
    private let debounce: Duration
    private let history: any SearchHistoryStore
    private var task: Task<Void, Never>?
    private var activeTerm: String?
    /// Search availability changes when returning from Settings, not on each new query.
    private var availabilityLoaded = false
    /// Titles TMDb has for a search typed as a description, in their own row. Empty for a search that reads like a title.
    public private(set) var describedItems: [MetaPreview] = []
    private let describer: DescribedSearchService
    private var aiTask: Task<Void, Never>?
    /// Titles the on-device model picked for a "what should I watch?" search, from real candidates, each with its reason.
    public private(set) var picks: [WatchPick] = []
    /// Nil where the on-device model is not available: such a search is then read as a description.
    private let picker: WatchPicker?

    /// Never label a TMDb-only fallback as on-device model output.
    public var aiAvailable: Bool { picker != nil || describer.ranker != nil }

    /// `history` keeps the recent searches. Without one they live only as long as this model.
    public init(services: AppServices, debounce: Duration = .milliseconds(300), history: (any SearchHistoryStore)? = nil,
                describer: DescribedSearchService? = nil, picker: WatchPicker? = nil, usesLivePicker: Bool = true) {
        let store = history ?? InMemorySearchHistoryStore()
        self.services = services
        self.describer = describer ?? .live(services)
        self.picker = picker ?? (usesLivePicker ? WatchPicker.live(services) : nil)
        self.debounce = debounce
        self.history = store
        self.recentQueries = Self.normalised(store.load())
    }

    public var hasResults: Bool { sections.contains { !$0.items.isEmpty } || !describedItems.isEmpty || !picks.isEmpty }
    /// Nothing came back and every addon failed because the device is offline.
    public var isOffline: Bool { !hasResults && Connectivity.isOffline(failures.map(\.error)) }
    /// "No results" needs an addon that could have answered; with none installed the screen says so instead.
    public var showsNoResults: Bool { phase == .done && aiPhase == .done && !hasResults && failures.isEmpty && aiIssue == nil }
    public var showsNoSearchableAddons: Bool { !hasSearchableAddons }

    /// Results across all addons, grouped by content type: movie first, then series, then other types in order of first appearance.
    /// Within a group items keep addon order (the user's order) then the addon's own order; duplicates (same `identity`) appear once.
    public var groups: [Group] {
        var seen = Set<String>()
        var order: [String] = []
        var itemsByType: [String: [MetaPreview]] = [:]
        for section in sections {
            for item in section.items where seen.insert(item.identity).inserted {
                let type = Self.groupType(item.type)
                if itemsByType[type] == nil { order.append(type) }
                itemsByType[type, default: []].append(item)
            }
        }
        let leading = ["movie", "series"]
        let types = leading.filter { itemsByType[$0] != nil } + order.filter { !leading.contains($0) }
        return types.map { Group(type: $0, title: ContentTypeName.plural($0), items: itemsByType[$0] ?? []) }
    }

    /// Asks whether any enabled addon can search, and reads the browse genres. Call when the Search screen appears; every search checks again.
    public func refreshAvailability() async {
        recentQueries = Self.normalised(history.load())
        let addons = await services.browse.searchableAddons()
        hasSearchableAddons = !addons.isEmpty
        let sources = await services.browse.catalogSources()
        browseGenres = Self.genreShortcuts(in: sources)
        availabilityLoaded = true
    }

    /// Forgets one recent search. Case-insensitive, like the de-duplication.
    public func removeRecent(_ query: String) {
        let key = Self.key(query)
        recentQueries.removeAll { Self.key($0) == key }
        history.save(recentQueries)
    }

    public func clearRecents() {
        recentQueries = []
        history.save([])
    }

    /// Call whenever the query changes. Cancel old work immediately and debounce both search paths.
    public func queryDidChange() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty, activeTerm == term, phase == .searching || aiPhase == .searching { return }
        task?.cancel()
        aiTask?.cancel()
        activeTerm = nil
        aiRequestID = UUID()
        guard !term.isEmpty else { reset(); return }
        sections = []
        failures = []
        describedItems = []
        picks = []
        phase = .searching
        aiPhase = .searching
        aiStage = .interpreting
        aiIssue = nil
        task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.run(term)
        }
    }

    /// The keyboard's Search button skips the debounce but still starts both paths.
    public func submit() async {
        guard !Task.isCancelled else { return }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { task?.cancel(); reset(); return }
        // Submitting while the same debounced search is already running must not restart expensive on-device inference.
        if activeTerm == term, phase == .searching || aiPhase == .searching {
            await task?.value
            return
        }
        task?.cancel()
        aiTask?.cancel()
        aiRequestID = UUID()
        sections = []
        failures = []
        describedItems = []
        picks = []
        phase = .searching
        aiPhase = .searching
        aiStage = .interpreting
        aiIssue = nil
        let search = Task { [weak self] in
            guard let self else { return }
            await self.run(term)
        }
        task = search
        await withTaskCancellationHandler {
            await search.value
        } onCancel: {
            search.cancel()
        }
    }

    /// Test and accessibility helper: the addon search can finish before the on-device model.
    public func waitUntilDone() async {
        await task?.value
        await aiTask?.value
    }

    private func reset() {
        aiTask?.cancel()
        aiRequestID = UUID()
        sections = []
        failures = []
        describedItems = []
        picks = []
        phase = .idle
        aiPhase = .idle
        aiIssue = nil
        activeTerm = nil
    }

    /// Loads the on-device model while Search is on screen, so a first search does not wait for it to load.
    public func prewarmAI() {
        guard aiAvailable else { return }
        Task.detached(priority: .utility) { OnDeviceDescriptionInterpreter.prewarm() }
    }

    /// Retry only AI work, retaining the normal search rows.
    public func retryAI() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        aiPhase = .searching
        searchAI(term)
    }

    /// Every nonempty search runs on-device AI, even a single name like "Dune".
    /// One plan covers title, metadata, people, similarity and semantic searches with cumulative updates.
    private func searchAI(_ term: String) {
        aiTask?.cancel()
        let describer = describer
        let requestID = UUID()
        aiRequestID = requestID
        aiStage = .interpreting
        aiIssue = nil
        aiTask = Task { [weak self] in
            let items = await describer.titles(for: term) { [weak self] update in
                guard !Task.isCancelled else { return }
                await self?.applyAIUpdate(update, term: term, requestID: requestID)
            }
            guard !Task.isCancelled, let self, self.aiRequestID == requestID,
                  self.query.trimmingCharacters(in: .whitespacesAndNewlines) == term else { return }
            self.describedItems = items
            self.aiStage = .complete
            self.aiPhase = .done
        }
    }

    private func applyAIUpdate(_ update: AISearchUpdate, term: String, requestID: UUID) {
        guard aiRequestID == requestID, query.trimmingCharacters(in: .whitespacesAndNewlines) == term else { return }
        // The service emits stage updates before and after a batch; avoid re-rendering identical result cards.
        if describedItems != update.items { describedItems = update.items }
        if aiStage != update.stage { aiStage = update.stage }
        if aiIssue != update.issue { aiIssue = update.issue }
    }

    private func run(_ term: String) async {
        guard !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines) == term else { return }
        activeTerm = term
        sections = []
        failures = []
        describedItems = []
        picks = []
        searchAI(term)
        if !availabilityLoaded { await refreshAvailability() }
        guard !Task.isCancelled else { return }
        guard hasSearchableAddons else {
            phase = .done
            return
        }
        let order = await services.registry.addons.map(\.id)
        let stream = await services.browse.search(term, incremental: true)
        for await response in stream {
            guard !Task.isCancelled else { return }
            switch response.result {
            case .success(let items):
                insert(Section(addon: response.addon, items: items), order: order)
            case .failure(let error):
                failures.append(Failure(addon: response.addon, error: error))
            }
        }
        guard !Task.isCancelled else { return }
        phase = .done
    }

    /// Reads the recents again, for when a title was opened from Search and its name was recorded (see `recording(_:into:)`).
    public func reloadRecents() {
        recentQueries = Self.normalised(history.load())
    }

    /// The recents with a title added at the top, in place of an older copy of it. A title opened from Search is what is recorded, not
    /// the letters typed on the way to it.
    public static func recording(_ title: String, into queries: [String]) -> [String] {
        normalised([title] + queries)
    }

    /// Keeps sections in the user's addon order, whatever order the addons answer in.
    private func insert(_ section: Section, order: [UUID]) {
        // Addon library entries are raw files, so keep them out of Search's title results.
        let section = Section(addon: section.addon, items: section.items.filter { Self.groupType($0.type) != "library" })
        if let index = sections.firstIndex(where: { $0.id == section.id }) {
            sections[index] = section
            return
        }
        func rank(_ id: UUID) -> Int { order.firstIndex(of: id) ?? Int.max }
        let index = sections.firstIndex { rank($0.addon.id) > rank(section.addon.id) } ?? sections.endIndex
        sections.insert(section, at: index)
    }

    /// The grouping key for an item's type: lower-case and trimmed, "other" when the addon sent no type.
    private static func groupType(_ type: String) -> String {
        let key = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key.isEmpty ? "other" : key
    }

    /// Up to 16 genres of one catalog: the first movie catalog that has genre options, else the first catalog that has any.
    /// Blank and repeated genres are left out, since each one is an id in the Search page.
    static func genreShortcuts(in sources: [CatalogSource]) -> [GenreShortcut] {
        let withGenres = sources.filter { !$0.catalog.genreOptions.isEmpty }
        guard let source = withGenres.first(where: { $0.catalog.type == "movie" }) ?? withGenres.first else { return [] }
        var seen = Set<String>()
        let names = source.catalog.genreOptions.filter { name in
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert(name).inserted
        }
        return names.prefix(maxGenres).map { name in
            GenreShortcut(name: name, source: .addonCatalog(AddonCatalogReference(
                manifestID: nil, host: source.addon.host, catalogType: source.catalog.type, catalogID: source.catalog.id, genre: name)))
        }
    }

    /// Recent searches as stored: trimmed, no blanks, one copy of each (the first one kept), at most 8.
    private static func normalised(_ queries: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for query in queries {
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(key(term)).inserted else { continue }
            result.append(term)
            if result.count == maxRecents { break }
        }
        return result
    }

    /// How two recent searches are compared: case-insensitively.
    private static func key(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
