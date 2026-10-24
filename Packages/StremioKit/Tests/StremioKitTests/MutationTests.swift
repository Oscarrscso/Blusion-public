import Foundation
import Testing
@testable import StremioKit

/// Mutated fixtures must never crash a decoder (PLAN M1). A decoder may throw or return a value; it may not trap.
@Suite struct MutationTests {
    private func allFixtures() throws -> [Data] {
        try ["manifests", "responses"].flatMap { dir in try Fixture.names(in: dir).map { try Fixture.data("\(dir)/\($0)") } }
    }

    private static func replacements() -> [Any] {
        [NSNull(), "", "x", " ", "🎬", "https://example.com/a", "about:blank", 0, -1, 1, 3.5, 1e308, -1e308, true, false,
        [Any](), [NSNull()], [1, "a", NSNull(), [String: Any]()], [String: Any](), ["id": NSNull()], ["name": 1], String(repeating: "A", count: 4096)]
    }

    private func mutate(_ node: Any, rng: inout SplitMix64, depthBudget: Int) -> Any {
        if depthBudget == 0 { return node }
        switch node {
        case var dict as [String: Any]:
            let keys = dict.keys.sorted()
            guard let key = keys.randomElement(using: &rng) else { return dict }
            switch Int.random(in: 0..<5, using: &rng) {
            case 0: dict.removeValue(forKey: key)
            case 1: dict[key] = Self.replacements().randomElement(using: &rng)
            case 2: dict[key] = mutate(dict[key] as Any, rng: &rng, depthBudget: depthBudget - 1)
            case 3: dict[String(key.reversed())] = dict[key]
            default: dict[key] = dict.values.randomElement(using: &rng)
            }
            return dict
        case var array as [Any]:
            guard !array.isEmpty else { return Self.replacements().randomElement(using: &rng) as Any }
            let index = Int.random(in: 0..<array.count, using: &rng)
            switch Int.random(in: 0..<4, using: &rng) {
            case 0: array.remove(at: index)
            case 1: array.insert(array[index], at: index)
            case 2: array[index] = mutate(array[index], rng: &rng, depthBudget: depthBudget - 1)
            default: array[index] = Self.replacements().randomElement(using: &rng) as Any
            }
            return array
        default:
            return Self.replacements().randomElement(using: &rng) as Any
        }
    }

    /// Exercises every public decode and query entry point on `data`.
    private func exercise(_ data: Data) {
        if let manifest = try? ResponseDecoder.manifest(from: data) {
            _ = manifest.validate()
            _ = manifest.isInstallable
            for kind in ResourceKind.allCases { _ = manifest.supports(kind, type: "movie", id: "tt1") }
            _ = manifest.browsableCatalogs()
            _ = manifest.searchableCatalogs
            // Anything we manage to decode must survive our own encoder.
            if let encoded = try? JSONEncoder().encode(manifest) {
                let again = try? JSONDecoder().decode(Manifest.self, from: encoded)
                #expect(again == manifest, "manifest round trip")
            }
        }
        _ = try? ResponseDecoder.catalog(from: data, defaultType: "movie")
        if let meta = try? ResponseDecoder.meta(from: data) {
            _ = meta.seasons
            if let encoded = try? JSONEncoder().encode(meta) {
                #expect((try? JSONDecoder().decode(MetaDetail.self, from: encoded)) == meta, "meta round trip")
            }
        }
        if let streams = try? ResponseDecoder.streams(from: data), let encoded = try? JSONEncoder().encode(["streams": streams]) {
            #expect((try? ResponseDecoder.streams(from: encoded)) == streams, "streams round trip")
        }
        _ = try? ResponseDecoder.subtitles(from: data)
    }

    @Test func structuralMutationsNeverCrash() throws {
        var rng = SplitMix64(seed: 0xDEC0DE)
        var count = 0
        for original in try allFixtures() {
            let tree = try JSONSerialization.jsonObject(with: original, options: [.fragmentsAllowed])
            for _ in 0..<200 {
                var mutated = tree
                for _ in 0..<Int.random(in: 1...3, using: &rng) { mutated = mutate(mutated, rng: &rng, depthBudget: 4) }
                guard JSONSerialization.isValidJSONObject(mutated),
                      let data = try? JSONSerialization.data(withJSONObject: mutated) else { continue }
                exercise(data)
                count += 1
            }
        }
        #expect(count > 3000, "mutation budget was actually spent")
    }

    @Test func byteLevelMutationsNeverCrash() throws {
        var rng = SplitMix64(seed: 0xFACADE)
        var count = 0
        for original in try allFixtures() {
            for _ in 0..<100 {
                var bytes = [UInt8](original)
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: bytes = Array(bytes.prefix(Int.random(in: 0..<bytes.count, using: &rng)))                // truncate
                case 1: for _ in 0..<Int.random(in: 1...5, using: &rng) { bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
                case 2: bytes.insert(contentsOf: [0xFF, 0xFE, 0x00, 0x7B], at: Int.random(in: 0..<bytes.count, using: &rng))
                default: bytes.removeSubrange(Int.random(in: 0..<bytes.count, using: &rng)..<bytes.count)
                }
                exercise(Data(bytes))
                count += 1
            }
        }
        #expect(count >= 2900)
    }

    @Test func pathologicalDocumentsNeverCrash() {
        let deep = String(repeating: "[", count: 600) + String(repeating: "]", count: 600)
        let nestedObjects = String(repeating: #"{"a":"#, count: 300) + "1" + String(repeating: "}", count: 300)
        let hugeNumbers = #"{"metas":[{"id":"x","imdbRating":1e999,"releaseInfo":-1e999,"runtime":123456789012345678901234567890}]}"#
        let nul = "{\"id\":\"a\u{0}b\",\"name\":\"n\",\"resources\":[\"stream\"]}"
        for text in [deep, nestedObjects, hugeNumbers, nul, "{\"id\":\"\\ud800\"}", "\u{FEFF}{}", "{\"a\":1,\"a\":2}"] {
            exercise(Data(text.utf8))
        }
    }
}
