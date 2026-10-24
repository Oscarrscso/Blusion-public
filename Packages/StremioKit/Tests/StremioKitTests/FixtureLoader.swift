import Foundation

enum Fixture {
    static func url(_ path: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(path)
    }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: url(path))
    }

    /// File names (sorted) in a fixture directory, e.g. "manifests".
    static func names(in directory: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url(directory).path).filter { $0.hasSuffix(".json") }.sorted()
    }
}

/// Deterministic generator so mutation and fuzz tests are reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
