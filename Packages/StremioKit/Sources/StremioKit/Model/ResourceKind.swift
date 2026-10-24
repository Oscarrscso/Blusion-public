import Foundation

/// The five protocol resources (PLAN §4).
public enum ResourceKind: String, Sendable, CaseIterable, Codable {
    case catalog
    case meta
    case stream
    case subtitles
    case addonCatalog = "addon_catalog"

    /// Resources the v1 app uses. `addon_catalog` is parsed but not browsed.
    public var isUsedInV1: Bool { self != .addonCatalog }
}
