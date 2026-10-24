import Foundation

/// A catalog of one installed addon, shown as a Board row or a Discover source.
public struct CatalogSource: Sendable, Equatable, Hashable, Identifiable {
    public let addon: AddonSummary
    public let baseURL: URL
    public let catalog: CatalogDescriptor

    public init(addon: AddonSummary, baseURL: URL, catalog: CatalogDescriptor) {
        self.addon = addon
        self.baseURL = baseURL
        self.catalog = catalog
    }

    public var id: String { "\(addon.id.uuidString)/\(catalog.key)" }
    public var type: String { catalog.type }
    public var title: String { catalog.name }
}

/// Browsing across the user's addons: catalog rows, paged catalogs with genre filter, multi-addon search, Detail with fallback.
public final class BrowseService: Sendable {
    public let registry: AddonRegistry
    public let client: AddonClient
    /// Content types the UI shows. `nil`, the default, shows every type an addon offers (movie, series, anime, `tv`, custom types
    /// such as `all`); a set keeps only those types.
    public let visibleTypes: Set<String>?

    public init(registry: AddonRegistry, client: AddonClient, visibleTypes: Set<String>? = nil) {
        self.registry = registry
        self.client = client
        self.visibleTypes = visibleTypes
    }

    /// `nil` means every type is visible.
    static func isVisible(_ type: String, in visible: Set<String>?) -> Bool { visible?.contains(type) ?? true }

    /// Browsable catalogs of enabled addons, in the user's addon order, then the addon's own catalog order.
    public func catalogSources(type: String? = nil) async -> [CatalogSource] {
        let visible = visibleTypes
        return await registry.addons(providing: .catalog).flatMap { addon in
            addon.manifest.browsableCatalogs(type: type).filter { BrowseService.isVisible($0.type, in: visible) }.map {
                CatalogSource(addon: addon.summary, baseURL: addon.baseURL, catalog: $0)
            }
        }
    }

    /// The enabled addons `search` asks, in the user's order: those with a searchable catalog of a visible type.
    /// Empty means search has nothing to ask (for example, only stream addons are installed).
    public func searchableAddons() async -> [AddonSummary] {
        await searchableInstalled().map(\.summary)
    }

    /// One page. `skip` is the number of items already loaded (the protocol's pagination).
    public func page(_ source: CatalogSource, genre: String? = nil, skip: Int = 0) async throws -> [MetaPreview] {
        var extras: [ExtraParam] = []
        if let genre, !genre.isEmpty, source.catalog.extra(named: "genre") != nil { extras.append(ExtraParam("genre", genre)) }
        if skip > 0, source.catalog.supportsSkip { extras.append(ExtraParam("skip", String(skip))) }
        return try await client.catalog(base: source.baseURL, type: source.catalog.type, id: source.catalog.id, extras: extras)
    }

    /// With incremental updates, each addon publishes its merged results as individual catalogs finish.
    /// The default retains one final answer per addon for callers that collect the stream.
    public func search(_ query: String, incremental: Bool = false) async -> AsyncStream<AddonResponse<[MetaPreview]>> {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return AsyncStream { $0.finish() } }
        let addons = await searchableInstalled()
        let client = self.client
        let visible = visibleTypes
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { addonsGroup in
                    for addon in addons {
                        addonsGroup.addTask {
                            let catalogs = Self.searchCatalogs(of: addon.manifest, visible: visible)
                            await withTaskGroup(of: (Int, Result<[MetaPreview], AddonError>).self) { group in
                                for (index, catalog) in catalogs.enumerated() {
                                    group.addTask {
                                        do {
                                            let items = try await client.catalog(base: addon.baseURL, type: catalog.type, id: catalog.id,
                                                                                 extras: [ExtraParam("search", term)])
                                            return (index, .success(items))
                                        } catch { return (index, .failure(AddonError.from(error))) }
                                    }
                                }
                                var pages: [Int: [MetaPreview]] = [:]
                                var firstError: AddonError?
                                var remaining = catalogs.count
                                for await (index, outcome) in group {
                                    guard !Task.isCancelled else { return }
                                    remaining -= 1
                                    switch outcome {
                                    case .success(let items): pages[index] = items
                                    case .failure(let error): firstError = firstError ?? error
                                    }
                                    if !pages.isEmpty, incremental || remaining == 0 {
                                        var seen = Set<String>()
                                        let merged = pages.keys.sorted().flatMap { pages[$0] ?? [] }.filter { seen.insert($0.identity).inserted }
                                        continuation.yield(AddonResponse(addon: addon.summary, result: .success(merged)))
                                    } else if remaining == 0, let firstError {
                                        continuation.yield(AddonResponse(addon: addon.summary, result: .failure(firstError)))
                                    }
                                }
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The addons `search` asks, shared with `searchableAddons()` so the two can never disagree.
    private func searchableInstalled() async -> [InstalledAddon] {
        let visible = visibleTypes
        return await registry.addons(providing: .catalog).filter { !BrowseService.searchCatalogs(of: $0.manifest, visible: visible).isEmpty }
    }

    /// The catalogs `search` asks one addon: its searchable catalogs of a visible type.
    static func searchCatalogs(of manifest: Manifest, visible: Set<String>?) -> [CatalogDescriptor] {
        manifest.searchableCatalogs.filter { isVisible($0.type, in: visible) }
    }

    /// Full metadata for Detail. Asks every addon that supports `meta` for this id at once, and takes the answer of the first addon in the
    /// user's order that has one, as Stremio does: an addon further down that answers sooner waits until those above it have answered or
    /// failed, so an addon that answers for any id cannot replace Cinemeta's details with its own. When none answers, Detail is built from
    /// the catalog preview (`isFallback`).
    public func detail(for preview: MetaPreview) async -> (detail: MetaDetail, isFallback: Bool) {
        let type = preview.type.isEmpty ? "movie" : preview.type
        let addons = await registry.addons(for: .meta, type: type, id: preview.id)
        let client = self.client
        var answers: [Int: MetaDetail] = [:]
        var settled = Set<Int>()
        for await response in FanOut.run(over: addons, operation: { try await client.meta(base: $0.baseURL, type: type, id: preview.id) }) {
            guard let index = addons.firstIndex(where: { $0.summary == response.addon }) else { continue }
            settled.insert(index)
            if let detail = response.value { answers[index] = detail }
            if let detail = Self.firstAnswerInOrder(answers, settled: settled, count: addons.count) { return (detail.filling(from: preview), false) }
        }
        return (.fallback(from: preview), true)
    }

    /// The answer of the first addon, in order, that has one, once every addon before it has answered or failed. Nil while an addon before
    /// the first answer has not settled yet, and when none has an answer.
    static func firstAnswerInOrder<Answer>(_ answers: [Int: Answer], settled: Set<Int>, count: Int) -> Answer? {
        for index in 0..<count {
            guard settled.contains(index) else { return nil }
            if let answer = answers[index] { return answer }
        }
        return nil
    }
}
