import Foundation

/// The user's Home layout. `nil` means the user never customised Home, so `DefaultWidgets` applies.
public protocol WidgetStore: Sendable {
    /// nil means the user never customised Home: show `DefaultWidgets` for the current addons.
    func load() async -> [HomeWidget]?
    /// nil goes back to the automatic layout.
    func save(_ widgets: [HomeWidget]?) async
}

public actor InMemoryWidgetStore: WidgetStore {
    private var widgets: [HomeWidget]?

    public init(_ widgets: [HomeWidget]? = nil) {
        self.widgets = widgets
    }

    public func load() async -> [HomeWidget]? { widgets }

    public func save(_ widgets: [HomeWidget]?) async { self.widgets = widgets }
}

/// Stores the layout as JSON in `UserDefaults`, wrapped as `{ "version": 1, "widgets": [...] }`. Unreadable data loads as nil.
/// A widget this build cannot read (written by a newer build, or edited by hand) is left out of the layout but kept in storage: each save
/// writes it back after the widget that came before it, so a build that can read it later finds it where it was.
public final class DefaultsWidgetStore: WidgetStore, @unchecked Sendable {
    public static let key = "home.widgets.v1"

    private static let currentVersion = 1

    private struct Envelope: Codable {
        var version: Int
        var widgets: [Entry]
    }

    /// One saved widget: one this build reads, or one it cannot, kept with the values it was saved with.
    private enum Entry: Codable {
        case widget(HomeWidget)
        case unreadable(SavedJSON)

        /// Never throws: one entry whose values cannot be represented is kept as null, so it does not take the other widgets with it.
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let widget = try? container.decode(HomeWidget.self) {
                self = .widget(widget)
            } else {
                self = .unreadable((try? container.decode(SavedJSON.self)) ?? .null)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .widget(let widget): try container.encode(widget)
            case .unreadable(let json): try container.encode(json)
            }
        }
    }

    /// Any JSON value, so an entry this build cannot read is written back with the same values. Whole numbers in the Int64 range keep their exact value.
    private enum SavedJSON: Codable {
        case null
        case bool(Bool)
        case integer(Int64)
        case number(Double)
        case string(String)
        case array([SavedJSON])
        case object([String: SavedJSON])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Int64.self) {
                self = .integer(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([SavedJSON].self) {
                self = .array(value)
            } else {
                self = .object(try container.decode([String: SavedJSON].self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .integer(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() async -> [HomeWidget]? {
        guard let envelope = readEnvelope() else { return nil }
        return envelope.widgets.compactMap { entry -> HomeWidget? in
            guard case .widget(let widget) = entry else { return nil }
            return widget.readingSavedTMDbFilters().withUniqueTileIDs()
        }
    }

    public func save(_ widgets: [HomeWidget]?) async {
        guard let widgets else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        // An unreadable entry stays after the last widget before it that is still in the layout, or first when there is none.
        let present = Set(widgets.map(\.id))
        var unreadable: [String?: [Entry]] = [:]
        var anchor: String?
        for entry in readEnvelope()?.widgets ?? [] {
            switch entry {
            case .widget(let widget):
                if present.contains(widget.id) { anchor = widget.id }
            case .unreadable:
                unreadable[anchor, default: []].append(entry)
            }
        }
        var entries = unreadable.removeValue(forKey: nil) ?? []
        for widget in widgets {
            entries.append(.widget(widget))
            entries += unreadable.removeValue(forKey: widget.id) ?? []
        }
        guard let data = try? JSONEncoder().encode(Envelope(version: Self.currentVersion, widgets: entries)) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// The saved envelope, or nil when there is none, it cannot be read, or it is another version.
    private func readEnvelope() -> Envelope? {
        guard let data = defaults.data(forKey: Self.key),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Self.currentVersion else { return nil }
        return envelope
    }
}
