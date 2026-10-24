import Foundation

/// One entry of `resources`: either the string `"stream"` or `{ "name": "stream", "types": [...], "idPrefixes": [...] }`.
public struct ResourceDescriptor: Sendable, Equatable, Codable {
    public var name: String
    public var types: [String]?
    public var idPrefixes: [String]?

    public init(name: String, types: [String]? = nil, idPrefixes: [String]? = nil) {
        self.name = name
        self.types = types
        self.idPrefixes = idPrefixes
    }

    private enum Keys: String, CodingKey { case name, types, idPrefixes }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw DroppedItem(reason: "empty resource name") }
            self.init(name: trimmed)
            return
        }
        let container = try decoder.container(keyedBy: Keys.self)
        guard let name = container.string(.name) else { throw DroppedItem(reason: "resource without name") }
        self.init(name: name, types: container.optionalStringArray(.types), idPrefixes: container.optionalStringArray(.idPrefixes))
    }
}

/// One entry of a catalog's `extra` array (`{ "name": "genre", "options": [...], "isRequired": true }`).
public struct ExtraDescriptor: Sendable, Equatable, Hashable, Codable {
    public var name: String
    public var isRequired: Bool
    public var options: [String]
    public var optionsLimit: Int?

    public init(name: String, isRequired: Bool = false, options: [String] = [], optionsLimit: Int? = nil) {
        self.name = name
        self.isRequired = isRequired
        self.options = options
        self.optionsLimit = optionsLimit
    }

    private enum Keys: String, CodingKey { case name, isRequired, options, optionsLimit }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        guard let name = container.string(.name) else { throw DroppedItem(reason: "extra without name") }
        self.init(name: name,
                  isRequired: container.bool(.isRequired),
                  options: container.stringArray(.options),
                  optionsLimit: container.int(.optionsLimit))
    }
}

public struct CatalogDescriptor: Sendable, Equatable, Hashable, Codable {
    public var type: String
    public var id: String
    public var name: String
    public var extra: [ExtraDescriptor]

    public init(type: String, id: String, name: String? = nil, extra: [ExtraDescriptor] = []) {
        self.type = type
        self.id = id
        self.name = name ?? id
        self.extra = extra
    }

    private enum Keys: String, CodingKey { case type, id, name, extra, extraSupported, extraRequired, genres }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        guard let type = container.string(.type), let id = container.string(.id) else {
            throw DroppedItem(reason: "catalog without type or id")
        }
        var extra: [ExtraDescriptor] = container.lossyArray(.extra)
        // Legacy manifests: extraSupported / extraRequired are plain name lists.
        let required = Set(container.stringArray(.extraRequired))
        for name in container.stringArray(.extraSupported) where !extra.contains(where: { $0.name == name }) {
            extra.append(ExtraDescriptor(name: name, isRequired: required.contains(name)))
        }
        for name in required where !extra.contains(where: { $0.name == name }) {
            extra.append(ExtraDescriptor(name: name, isRequired: true))
        }
        // Legacy: a top-level `genres` list is the option list of the genre filter.
        let genres = container.stringArray(.genres)
        if !genres.isEmpty {
            if let index = extra.firstIndex(where: { $0.name == "genre" }) {
                if extra[index].options.isEmpty { extra[index].options = genres }
            } else {
                extra.append(ExtraDescriptor(name: "genre", options: genres))
            }
        }
        self.init(type: type, id: id, name: container.string(.name), extra: extra)
    }

    /// `type/id`: unique within one addon, even when two types share an id.
    public var key: String { "\(type)/\(id)" }

    public func extra(named name: String) -> ExtraDescriptor? { extra.first { $0.name == name } }

    public var supportsSearch: Bool { extra(named: "search") != nil }

    /// Usable for search: offers `search` and requires nothing else (a catalog that also requires `genre` can't be searched blind).
    public var isSearchable: Bool { supportsSearch && requiredExtraNames.allSatisfy { $0 == "search" } }
    public var supportsSkip: Bool { extra(named: "skip") != nil }
    public var genreOptions: [String] { extra(named: "genre")?.options ?? [] }
    public var requiredExtraNames: [String] { extra.filter(\.isRequired).map(\.name) }

    /// A catalog can be shown as a plain row (Board / Discover) only when nothing it requires needs user input.
    public var isBrowsable: Bool { requiredExtraNames.isEmpty }
}

public struct ManifestBehaviorHints: Sendable, Equatable, Codable {
    public var configurable: Bool
    public var configurationRequired: Bool
    public var adult: Bool
    public var p2p: Bool

    public init(configurable: Bool = false, configurationRequired: Bool = false, adult: Bool = false, p2p: Bool = false) {
        self.configurable = configurable
        self.configurationRequired = configurationRequired
        self.adult = adult
        self.p2p = p2p
    }

    private enum Keys: String, CodingKey { case configurable, configurationRequired, adult, p2p }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        self.init(configurable: container.bool(.configurable),
                  configurationRequired: container.bool(.configurationRequired),
                  adult: container.bool(.adult),
                  p2p: container.bool(.p2p))
    }
}

/// A Stremio addon manifest, decoded leniently. Use `validate()` to find out whether it is installable.
public struct Manifest: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var resources: [ResourceDescriptor]
    /// Top-level `types`; when missing or empty it is derived from resource-level and catalog types.
    public var types: [String]
    public var catalogs: [CatalogDescriptor]
    public var idPrefixes: [String]?
    public var logo: URL?
    public var background: URL?
    public var behaviorHints: ManifestBehaviorHints

    public init(id: String, name: String, version: String = "", description: String? = nil,
                resources: [ResourceDescriptor] = [], types: [String] = [], catalogs: [CatalogDescriptor] = [],
                idPrefixes: [String]? = nil, logo: URL? = nil, background: URL? = nil,
                behaviorHints: ManifestBehaviorHints = .init()) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.resources = resources
        self.types = types
        self.catalogs = catalogs
        self.idPrefixes = idPrefixes
        self.logo = logo
        self.background = background
        self.behaviorHints = behaviorHints
    }

    private enum Keys: String, CodingKey {
        case id, name, version, description, resources, types, catalogs, idPrefixes, logo, background, behaviorHints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let resources: [ResourceDescriptor] = container.lossyArray(.resources)
        let catalogs: [CatalogDescriptor] = container.lossyArray(.catalogs)
        var types = container.stringArray(.types)
        if types.isEmpty {
            var derived: [String] = []
            for type in resources.flatMap({ $0.types ?? [] }) + catalogs.map(\.type) where !derived.contains(type) {
                derived.append(type)
            }
            types = derived
        }
        self.init(id: container.string(.id) ?? "",
                  name: container.string(.name) ?? "",
                  version: container.string(.version) ?? "",
                  description: container.string(.description),
                  resources: resources,
                  types: types,
                  catalogs: catalogs,
                  idPrefixes: container.optionalStringArray(.idPrefixes),
                  logo: container.url(.logo),
                  background: container.url(.background),
                  behaviorHints: container.object(.behaviorHints) ?? .init())
    }
}

// MARK: - Routing (PLAN §4)

extension Manifest {
    /// True when this addon lists `resource` for `type` and, if prefixes apply, `id` starts with one of them.
    /// Resource-level `types` / `idPrefixes` win over top-level ones. An absent or empty prefix list matches every id.
    public func supports(_ resource: ResourceKind, type: String, id: String) -> Bool {
        for descriptor in resources where descriptor.name == resource.rawValue {
            // A manifest that declares no types anywhere is treated as accepting every type.
            let types = nonEmpty(descriptor.types) ?? self.types
            guard types.isEmpty || types.contains(type) else { continue }
            if let prefixes = nonEmpty(descriptor.idPrefixes) ?? nonEmpty(idPrefixes) {
                if prefixes.contains(where: { id.hasPrefix($0) }) { return true }
                continue
            }
            return true
        }
        return false
    }

    /// Catalogs count as provided when the addon lists `catalog` or declares any: the Stremio core treats a non-empty
    /// `catalogs` array as enough, and many addons leave `resources` out.
    public func provides(_ resource: ResourceKind) -> Bool {
        if resource == .catalog, !catalogs.isEmpty { return true }
        return resources.contains { $0.name == resource.rawValue }
    }

    /// Catalogs that can be shown as rows for one type.
    public func browsableCatalogs(type: String? = nil) -> [CatalogDescriptor] {
        guard provides(.catalog) else { return [] }
        return catalogs.filter { $0.isBrowsable && (type == nil || $0.type == type) }
    }

    public var searchableCatalogs: [CatalogDescriptor] {
        guard provides(.catalog) else { return [] }
        return catalogs.filter(\.isSearchable)
    }

    private func nonEmpty(_ values: [String]?) -> [String]? {
        guard let values, !values.isEmpty else { return nil }
        return values
    }
}

// MARK: - Validation

public struct ManifestIssue: Sendable, Equatable, Hashable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }
    public enum Code: String, Sendable {
        case missingID, missingName, missingVersion, noResources, noUsableResources
        case unknownResource, catalogResourceWithoutCatalogs, configurationRequired
    }

    public let severity: Severity
    public let code: Code
    public let message: String

    public var description: String { "\(severity.rawValue): \(message)" }
}

extension Manifest {
    private static let knownResources = Set(ResourceKind.allCases.map(\.rawValue))

    /// Errors make a manifest uninstallable; warnings are shown but do not block installation.
    public func validate() -> [ManifestIssue] {
        var issues: [ManifestIssue] = []
        func error(_ code: ManifestIssue.Code, _ message: String) { issues.append(.init(severity: .error, code: code, message: message)) }
        func warn(_ code: ManifestIssue.Code, _ message: String) { issues.append(.init(severity: .warning, code: code, message: message)) }

        if id.isEmpty { error(.missingID, "The manifest has no id.") }
        if name.isEmpty { error(.missingName, "The manifest has no name.") }
        if version.isEmpty { warn(.missingVersion, "The manifest has no version.") }
        // Declared catalogs are enough to install, even when `resources` is missing or lists nothing usable (see `provides`).
        if catalogs.isEmpty {
            if resources.isEmpty {
                error(.noResources, "The manifest lists no resources.")
            } else if !resources.contains(where: { ResourceKind(rawValue: $0.name)?.isUsedInV1 == true }) {
                error(.noUsableResources, "This addon offers none of catalogs, metadata, streams or subtitles.")
            }
        }
        for descriptor in resources where !Self.knownResources.contains(descriptor.name) {
            warn(.unknownResource, "Unknown resource “\(descriptor.name)” is ignored.")
        }
        if provides(.catalog) && catalogs.isEmpty {
            warn(.catalogResourceWithoutCatalogs, "The manifest offers catalogs but lists none.")
        }
        if behaviorHints.configurationRequired {
            warn(.configurationRequired, "This addon asks to be configured before use; configure it on its own page, then install its configured URL.")
        }
        return issues
    }

    public var isInstallable: Bool { !validate().contains { $0.severity == .error } }
}
