import Foundation

// Real-world addons are sloppy: numbers arrive as strings, fields go missing, arrays are null.
// These helpers never throw; a bad value becomes nil / empty and a bad array element is dropped.

/// Any JSON scalar. Used to accept `7.5`, `"7.5"`, `true` or `"true"` where one type is expected.
struct AnyScalar: Decodable {
    enum Value {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
    }

    let value: Value?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let bool = try? container.decode(Bool.self) {
            value = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            value = .int(int)
        } else if let double = try? container.decode(Double.self) {
            value = .double(double)
        } else if let string = try? container.decode(String.self) {
            value = .string(string)
        } else {
            value = nil
        }
    }
}

extension AnyScalar.Value {
    var stringValue: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .double(let value):
            if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
            return String(value)
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return value.isFinite && abs(value) < 1e15 ? Int(value) : nil
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let int = Int(trimmed) { return int }
            if let double = Double(trimmed), double.isFinite, abs(double) < 1e15 { return Int(double) }
            return nil
        case .bool: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value.isFinite ? value : nil
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let double = Double(trimmed), double.isFinite else { return nil }
            return double
        case .bool: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value == 0 ? false : (value == 1 ? true : nil)
        case .double(let value): return value == 0 ? false : (value == 1 ? true : nil)
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
    }
}

/// Wraps an element so that a failing element decodes to nil instead of failing the whole array.
private struct Lossy<Element: Decodable>: Decodable {
    let value: Element?
    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}

extension KeyedDecodingContainer {
    func scalar(_ key: Key) -> AnyScalar.Value? {
        guard contains(key), let decoded = try? decode(AnyScalar.self, forKey: key) else { return nil }
        return decoded.value
    }

    /// Trimmed, non-empty string. Numbers and booleans are stringified.
    func string(_ key: Key) -> String? {
        guard let text = scalar(key)?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    func int(_ key: Key) -> Int? { scalar(key)?.intValue }

    func double(_ key: Key) -> Double? { scalar(key)?.doubleValue }

    func bool(_ key: Key, default fallback: Bool = false) -> Bool { scalar(key)?.boolValue ?? fallback }

    /// http(s) URLs only. `about:blank`, `data:` and garbage become nil.
    func url(_ key: Key) -> URL? {
        guard let text = string(key) else { return nil }
        return LenientURL.parse(text)
    }

    /// null, missing or wrongly typed -> []. Scalars inside the array are stringified; objects are dropped.
    /// A bare string is split on commas (some addons send `"genres": "Action, Drama"`).
    func stringArray(_ key: Key) -> [String] {
        optionalStringArray(key) ?? []
    }

    /// Like `stringArray` but distinguishes "absent / null" (nil) from "present" (possibly empty).
    func optionalStringArray(_ key: Key) -> [String]? {
        guard contains(key) else { return nil }
        if let elements = try? decode([AnyScalar].self, forKey: key) {
            return elements.compactMap { $0.value?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let text = try? decode(String.self, forKey: key) {
            return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        return nil
    }

    /// Drops elements that fail to decode. null, missing or non-array -> [].
    func lossyArray<Element: Decodable>(_ key: Key, of type: Element.Type = Element.self) -> [Element] {
        guard let boxes = try? decodeIfPresent([Lossy<Element>].self, forKey: key) else { return [] }
        return boxes.compactMap(\.value)
    }

    /// Nested object that must not fail its parent.
    func object<Element: Decodable>(_ key: Key, of type: Element.Type = Element.self) -> Element? {
        guard contains(key) else { return nil }
        return try? decode(Element.self, forKey: key)
    }

    /// `{ "k": "v" }` with scalar values stringified; everything else dropped.
    func stringMap(_ key: Key) -> [String: String] {
        guard contains(key), let raw = try? decode([String: AnyScalar].self, forKey: key) else { return [:] }
        var out: [String: String] = [:]
        for (name, scalar) in raw {
            if let value = scalar.value?.stringValue { out[name] = value }
        }
        return out
    }
}

enum LenientURL {
    static func parse(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

/// Thrown by model initialisers for items that must be dropped (they never fail a whole response).
struct DroppedItem: Error {
    let reason: String
}
