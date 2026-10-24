import Foundation
import StremioKit

#if os(macOS) || os(Linux)

/// Gives tests a running mock addon. Uses the one `verify.sh` started (MOCK_ADDON_CATALOG_URL / MOCK_ADDON_STREAM_URL) when present,
/// otherwise spawns `node Tools/MockAddon/server.js` on free ports and lets it die with the test process (`--watch-stdin`).
public final class MockServer: @unchecked Sendable {
    public struct LaunchError: Error, CustomStringConvertible {
        public let description: String
        public init(description: String) { self.description = description }
    }

    public let catalog: URL
    public let stream: URL
    /// How long `flag-slow` takes on this server.
    public let slowDelay: TimeInterval
    private let process: Process?
    private let stdin: Pipe?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: MockServer?

    private init(catalog: URL, stream: URL, slowDelay: TimeInterval, process: Process?, stdin: Pipe?) {
        self.catalog = catalog
        self.stream = stream
        self.slowDelay = slowDelay
        self.process = process
        self.stdin = stdin
    }

    public static func shared() throws -> MockServer {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let server = try launch()
        cached = server
        return server
    }

    /// True when `Tools/MockAddon/make-fixtures.sh` (needs ffmpeg) has written the media the tests stream or sniff. Tests that play
    /// real containers gate on this with `.enabled(if:)`, so a host without ffmpeg skips them instead of failing or hanging.
    /// Subtitles are served from `subtitles.js` and the DTS file is optional, so neither is required.
    public static var hasMediaFixtures: Bool {
        let fixtures = repoRoot.appendingPathComponent("Tools/MockAddon/fixtures/generated")
        guard ["sample.mp4", "sample-ac3.mkv", "hls/index.m3u8"].allSatisfy({
            FileManager.default.fileExists(atPath: fixtures.appendingPathComponent($0).path)
        }), let playlist = try? String(contentsOf: fixtures.appendingPathComponent("hls/index.m3u8"), encoding: .utf8) else { return false }
        let segments = playlist.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }
        return !segments.isEmpty && segments.allSatisfy {
            FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("hls/\($0)").path)
        }
    }

    /// The repo root, found from this file's path: …/Packages/StremioKit/Sources/StremioKitTestSupport/MockServer.swift.
    private static var repoRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root
    }

    private static func launch() throws -> MockServer {
        let env = ProcessInfo.processInfo.environment
        if let c = env["MOCK_ADDON_CATALOG_URL"], let s = env["MOCK_ADDON_STREAM_URL"], let catalog = URL(string: c), let stream = URL(string: s) {
            let delay = (Double(env["MOCK_DELAY_MS"] ?? "") ?? 3000) / 1000
            return MockServer(catalog: catalog, stream: stream, slowDelay: delay, process: nil, stdin: nil)
        }

        let script = repoRoot.appendingPathComponent("Tools/MockAddon/server.js")
        guard FileManager.default.fileExists(atPath: script.path) else { throw LaunchError(description: "mock server script not found at \(script.path)") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path, "--catalog-port", "0", "--stream-port", "0", "--watch-stdin"]
        var childEnv = env
        childEnv["MOCK_DELAY_MS"] = "3000"
        process.environment = childEnv
        let out = Pipe()
        let input = Pipe()
        process.standardOutput = out
        process.standardInput = input
        process.standardError = FileHandle.standardError
        try process.run()

        var buffer = Data()
        while !buffer.contains(UInt8(ascii: "\n")) {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { throw LaunchError(description: "mock server exited before it was ready") }
            buffer.append(chunk)
        }
        guard let line = buffer.split(separator: UInt8(ascii: "\n")).first,
              let json = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let c = json["catalog"] as? String, let s = json["stream"] as? String,
              let catalog = URL(string: c), let stream = URL(string: s) else { throw LaunchError(description: "unexpected mock server output") }
        return MockServer(catalog: catalog, stream: stream, slowDelay: 3, process: process, stdin: input)
    }

    /// `<origin>/flag-a/flag-b/<token>`; flags switch on misbehaviour, the token stands in for a user secret.
    public func catalogBase(flags: [String] = [], token: String? = nil) -> URL { url(catalog, flags: flags, token: token) }

    public func streamBase(flags: [String] = [], token: String? = nil) -> URL { url(stream, flags: flags, token: token) }

    public func catalogManifestURL(flags: [String] = [], token: String? = nil) -> URL {
        catalogBase(flags: flags, token: token).appendingPathComponent("manifest.json")
    }

    public func streamManifestURL(flags: [String] = [], token: String? = nil) -> URL {
        streamBase(flags: flags, token: token).appendingPathComponent("manifest.json")
    }

    private func url(_ origin: URL, flags: [String], token: String?) -> URL {
        var url = origin
        for flag in flags { url.appendPathComponent("flag-\(flag)") }
        if let token { url.appendPathComponent(token) }
        return url
    }
}
#endif
