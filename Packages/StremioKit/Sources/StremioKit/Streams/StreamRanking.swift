import Foundation

/// A stream together with everything the picker and the coordinator need to know about it.
public struct RankedStream: Sendable, Equatable, Identifiable {
    /// De-duplication key: the same file offered by two addons has one id.
    public let id: String
    public let stream: AddonStream
    public let addon: AddonSummary
    /// Other addons that offered the same file.
    public var alsoProvidedBy: [AddonSummary]
    public let quality: StreamQuality
    public let container: MediaContainer?
    public let route: PlaybackRoute
    public let addonIndex: Int
    public let indexInAddon: Int

    public var title: String { stream.displayName }
    public var bingeContext: BingeContext? { stream.behaviorHints.bingeGroup.map { BingeContext(bingeGroup: $0, addonID: addon.id) } }

    /// The same stream with another route: what the picker would do with it in Blusion's own player, for instance.
    public func rerouted(_ route: PlaybackRoute) -> RankedStream {
        RankedStream(id: id, stream: stream, addon: addon, alsoProvidedBy: alsoProvidedBy, quality: quality, container: container, route: route,
                     addonIndex: addonIndex, indexInAddon: indexInAddon)
    }
}

public struct RankingPreferences: Sendable, Equatable {
    /// When set, streams closest to this resolution win (ties go to the higher one). When nil, higher is better.
    public var preferredResolution: Int?

    public init(preferredResolution: Int? = nil) {
        self.preferredResolution = preferredResolution
    }
}

public enum StreamIdentity {
    /// Same URL (ignoring scheme case, host case and fragment) or same torrent file => same stream.
    public static func key(for source: StreamSource) -> String {
        switch source {
        case .direct(let url): return "url:" + normalised(url)
        case .torrent(let hash, let index, _): return "torrent:\(hash.lowercased()):\(index ?? -1)"
        case .youtube(let id): return "youtube:\(id)"
        case .external(let url): return "external:" + normalised(url)
        case .archive(let kind): return "archive:\(kind)"
        }
    }

    /// The key of a whole stream. Playable sources are the same stream whenever the source is the same. Links are different:
    /// aggregating addons send many notes (statistics, removal reasons, errors) that all point at one web page, and each note is
    /// worth keeping, so a link's name is part of its identity.
    public static func key(for stream: AddonStream) -> String {
        guard case .external = stream.source else { return key(for: stream.source) }
        return key(for: stream.source) + "|" + stream.displayName
    }

    private static func normalised(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        return components.string ?? url.absoluteString
    }
}

/// Watchable streams first, then Blu-ray REMUX priority, route, resolution and the remaining release facts.
public enum StreamRanking {
    public static func sorted(_ items: [RankedStream], preferences: RankingPreferences = .init()) -> [RankedStream] {
        items.sorted { isOrdered($0, before: $1, preferences: preferences) }
    }

    public static func isOrdered(_ a: RankedStream, before b: RankedStream, preferences: RankingPreferences = .init()) -> Bool {
        if a.route.isWatchable != b.route.isWatchable { return a.route.isWatchable }
        if !a.route.isWatchable, a.route.sortClass != b.route.sortClass { return a.route.sortClass < b.route.sortClass }
        if a.quality.releasePriority != b.quality.releasePriority { return a.quality.releasePriority > b.quality.releasePriority }
        if a.route.sortClass != b.route.sortClass { return a.route.sortClass < b.route.sortClass }
        let (ra, rb) = (resolutionKey(a.quality.resolution, preferences), resolutionKey(b.quality.resolution, preferences))
        if ra != rb { return ra < rb }
        let (sa, sb) = (a.quality.source?.rank ?? -1, b.quality.source?.rank ?? -1)
        if sa != sb { return sa > sb }
        let (za, zb) = (a.quality.sizeBytes ?? -1, b.quality.sizeBytes ?? -1)
        if za != zb { return za > zb }
        if a.addonIndex != b.addonIndex { return a.addonIndex < b.addonIndex }
        return a.indexInAddon < b.indexInAddon
    }

    /// Smaller sorts first. Unknown resolution always sorts after any known one.
    private static func resolutionKey(_ resolution: Int?, _ preferences: RankingPreferences) -> Int {
        guard let resolution else { return Int.max }
        guard let preferred = preferences.preferredResolution else { return -resolution }
        // distance first, then prefer the higher resolution on ties (encoded in the low bit of a doubled distance)
        return abs(resolution - preferred) * 2 + (resolution >= preferred ? 0 : 1)
    }
}

public struct BingeContext: Sendable, Equatable, Hashable, Codable {
    public var bingeGroup: String
    public var addonID: UUID?

    public init(bingeGroup: String, addonID: UUID? = nil) {
        self.bingeGroup = bingeGroup
        self.addonID = addonID
    }
}

public enum BingeSelection {
    /// The stream to auto-select for the next episode: one in the same `bingeGroup`, best-ranked first, preferring the same addon.
    /// `nil` when nothing matches, so the picker is shown instead.
    public static func pick(from ranked: [RankedStream], continuing previous: BingeContext?) -> RankedStream? {
        guard let previous else { return nil }
        let candidates = StreamAvailability.automaticCandidates(from: ranked.filter {
            $0.route.isPlayable && $0.stream.behaviorHints.bingeGroup == previous.bingeGroup
        })
        return candidates.first { $0.addon.id == previous.addonID } ?? candidates.first
    }
}
