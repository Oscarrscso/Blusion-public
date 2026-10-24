import Foundation

/// The picker's data, built incrementally as addons answer. Pure value type: every mutation re-derives the visible, de-duplicated,
/// ranked list, so ordering never depends on the order in which addons happened to reply.
public struct StreamListing: Sendable, Equatable {
    public struct Group: Sendable, Equatable, Identifiable {
        public let addon: AddonSummary
        public let streams: [RankedStream]
        public var id: UUID { addon.id }
    }

    public struct Failure: Sendable, Equatable, Identifiable {
        public let addon: AddonSummary
        public let error: AddonError
        public var id: UUID { addon.id }
    }

    public struct HiddenHint: Sendable, Equatable, Identifiable {
        public let reason: HiddenReason
        public let count: Int
        public var id: String { reason.rawValue }
        public var text: String { "\(count) \(count == 1 ? "stream" : "streams") hidden: \(reason.hint)" }
    }

    public struct SniffTarget: Sendable, Equatable {
        public let key: String
        public let url: URL
        public let headers: [String: String]
    }

    private struct Entry: Equatable {
        let addon: AddonSummary
        let addonIndex: Int
        let indexInAddon: Int
        let stream: AddonStream
        let quality: StreamQuality
        let key: String
    }

    public private(set) var pending: [AddonSummary]
    public private(set) var failures: [Failure] = []
    /// Visible streams, de-duplicated and ranked best first.
    public private(set) var items: [RankedStream] = []
    public private(set) var hidden: [HiddenHint] = []
    public private(set) var config: PolicyConfiguration
    public private(set) var preferences: RankingPreferences

    private var entries: [Entry] = []
    private var containers: [String: MediaContainer] = [:]
    private var sniffed: Set<String> = []
    private var order: [UUID]

    public init(asking addons: [AddonSummary], config: PolicyConfiguration = .init(), preferences: RankingPreferences = .init()) {
        self.pending = addons
        self.order = addons.map(\.id)
        self.config = config
        self.preferences = preferences
    }

    public var isLoading: Bool { !pending.isEmpty }
    public var isEmpty: Bool { items.isEmpty }

    /// Visible streams grouped by addon, addons in the user's order, streams in rank order.
    public var groups: [Group] {
        order.compactMap { id in
            let streams = items.filter { $0.addon.id == id }
            return streams.isEmpty ? nil : Group(addon: streams[0].addon, streams: streams)
        }
    }

    /// The best stream the user can start, in Blusion or in the app they chose. Ranking decides between the two kinds.
    public var best: RankedStream? { items.first { $0.route.isWatchable } }

    /// Every stream Blusion's own player can play, best first: the coordinator's auto-advance list.
    public var playable: [RankedStream] { items.filter { $0.route.isPlayable } }

    // MARK: Updates

    public mutating func apply(_ response: AddonResponse<[AddonStream]>) {
        pending.removeAll { $0.id == response.addon.id }
        switch response.result {
        case .failure(let error):
            failures.removeAll { $0.addon.id == response.addon.id }
            failures.append(Failure(addon: response.addon, error: error))
        case .success(let streams):
            if !order.contains(response.addon.id) { order.append(response.addon.id) }
            let addonIndex = order.firstIndex(of: response.addon.id) ?? order.count
            entries.removeAll { $0.addon.id == response.addon.id }
            for (index, stream) in streams.enumerated() {
                entries.append(Entry(addon: response.addon, addonIndex: addonIndex, indexInAddon: index, stream: stream,
                                     quality: StreamQuality.parse(stream),
                                     key: StreamIdentity.key(for: stream)))
            }
        }
        rebuild()
    }

    public mutating func setContainer(_ container: MediaContainer?, forKey key: String) {
        sniffed.insert(key)
        guard let container, containers[key] != container else { return }
        containers[key] = container
        rebuild()
    }

    public mutating func update(config: PolicyConfiguration? = nil, preferences: RankingPreferences? = nil) {
        guard config.map({ $0 != self.config }) == true || preferences.map({ $0 != self.preferences }) == true else { return }
        if let config { self.config = config }
        if let preferences { self.preferences = preferences }
        rebuild()
    }

    /// Direct URLs whose format can't be told from the filename or extension and haven't been sniffed yet.
    /// (Streams with a known extension are not probed: it spares addon CDNs, and debrid links, needless requests.)
    public var sniffTargets: [SniffTarget] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard !sniffed.contains(entry.key), seen.insert(entry.key).inserted else { return nil }
            guard case .direct(let url) = entry.stream.source,
                  ContainerSniffer.container(url: url, filename: entry.stream.behaviorHints.filename) == nil else { return nil }
            return SniffTarget(key: entry.key, url: url, headers: entry.stream.behaviorHints.proxyHeaders?.request ?? [:])
        }
    }

    // MARK: Derivation

    private mutating func rebuild() {
        var best: [String: RankedStream] = [:]
        var firstSeen: [String] = []
        var hiddenCounts: [HiddenReason: Int] = [:]

        for entry in entries {
            let quality = entry.quality
            let container = containers[entry.key]
            let route = PlaybackPolicy.route(for: entry.stream, container: container, quality: quality, config: config)
            if case .hidden(let reason) = route {
                hiddenCounts[reason, default: 0] += 1
                continue
            }
            let candidate = RankedStream(id: entry.key, stream: entry.stream, addon: entry.addon, alsoProvidedBy: [], quality: quality,
                                         container: container, route: route, addonIndex: entry.addonIndex, indexInAddon: entry.indexInAddon)
            if var existing = best[entry.key] {
                if StreamRanking.isOrdered(candidate, before: existing, preferences: preferences) {
                    var winner = candidate
                    winner.alsoProvidedBy = existing.alsoProvidedBy + [existing.addon]
                    best[entry.key] = winner
                } else {
                    existing.alsoProvidedBy.append(entry.addon)
                    best[entry.key] = existing
                }
            } else {
                best[entry.key] = candidate
                firstSeen.append(entry.key)
            }
        }
        items = StreamRanking.sorted(firstSeen.compactMap { best[$0] }, preferences: preferences)
        hidden = HiddenReason.allCasesInOrder.compactMap { reason in hiddenCounts[reason].map { HiddenHint(reason: reason, count: $0) } }
    }
}

extension HiddenReason {
    static let allCasesInOrder: [HiddenReason] = [.needsStreamingServer, .usenetOrArchive]
}
