import Foundation

public enum DownloadState: String, Codable, Sendable { case queued, downloading, paused, failed, complete }

public struct DownloadSubtitle: Codable, Sendable, Equatable {
    public var path: String
    public var language: String
    public init(path: String, language: String) { self.path = path; self.language = language }
}

/// Only non-secret metadata crosses the persistent-store boundary. Stream identities belong in SecretStore.
public struct DownloadItem: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var request: StreamRequest
    public var addonID: UUID
    public var container: String
    public var usesFallback: Bool
    public var state: DownloadState = .queued
    public var received: Int64 = 0
    public var expected: Int64 = 0
    public var retries: Int = 0
    public var createdAt: Date = Date()
    public var mediaPath: String?
    public var subtitles: [DownloadSubtitle] = []
    public var failure: String?
    public var pendingDeletion: Bool?
    public var mediaDetails: [String: String]?
    public var completedAt: Date?
    public init(id: UUID = UUID(), request: StreamRequest, addonID: UUID, container: MediaContainer, usesFallback: Bool) {
        self.id = id
        // No poster URLs, next-episode restoration or remote stream metadata in a download record.
        self.request = StreamRequest(type: request.type, id: request.id, title: request.title, season: request.season,
                                     episode: request.episode, seriesName: request.seriesName, year: request.year,
                                     expectedDuration: request.expectedDuration)
        self.addonID = addonID
        self.container = container.rawValue
        self.usesFallback = usesFallback
    }
    public var fraction: Double { expected > 0 ? min(1, Double(received) / Double(expected)) : 0 }
    public var hasValidPaths: Bool {
        ([mediaPath].compactMap { $0 } + subtitles.map(\.path)).allSatisfy { DownloadFiles.valid($0, for: id) }
    }
    public static func validRequest(_ request: StreamRequest) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":._-"))
        return [request.type, request.id].allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }
    }
}

public protocol DownloadStore: Sendable {
    func loadAll() async throws -> [DownloadItem]
    func save(_ items: [DownloadItem]) async throws
}

public actor InMemoryDownloadStore: DownloadStore {
    private var items: [DownloadItem] = []
    public init() {}
    public func loadAll() -> [DownloadItem] { items }
    public func save(_ items: [DownloadItem]) { self.items = items }
}

public enum DownloadEligibility {
    public static func container(for item: RankedStream, config: PolicyConfiguration) -> MediaContainer? {
        guard case .direct(let url) = item.stream.source, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let host = url.host?.lowercased() ?? ""
        guard !["youtube.com", "youtu.be", "googlevideo.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        let excluded = ["zip", "rar", "7z", "nzb", "gz", "tar", "m3u8", "m3u"]
        let extensions = [url.pathExtension.lowercased(), ((item.stream.behaviorHints.filename ?? "") as NSString).pathExtension.lowercased()]
        guard !extensions.contains(where: excluded.contains),
              let container = item.container ?? ContainerSniffer.container(url: url, filename: item.stream.behaviorHints.filename),
              container != .hls else { return nil }
        var policy = config
        policy.playerPreference = .builtIn
        guard PlaybackPolicy.route(for: item.stream, container: container, quality: item.quality, config: policy).isPlayable else { return nil }
        return container
    }
    public static func fileExtension(_ container: MediaContainer) -> String {
        switch container {
        case .matroska: return "mkv"
        case .mpegTS: return "ts"
        case .mpegPS: return "mpg"
        default: return container.rawValue
        }
    }
}

public enum DownloadFiles {
    public static func directory() throws -> URL {
        var root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #if targetEnvironment(macCatalyst) || os(macOS)
        root.appendPathComponent(Bundle.main.bundleIdentifier ?? "app.blusion.player", isDirectory: true)
        #endif
        root.appendPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        return root
    }
    public static func valid(_ path: String, for id: UUID) -> Bool {
        guard path.hasPrefix(id.uuidString + "."), !path.contains("/"), !path.contains("\\"), !path.contains("..") else { return false }
        return path.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_")).contains($0) }
    }
    public static func resolve(_ path: String, for id: UUID, in root: URL) -> URL? {
        guard valid(path, for: id) else { return nil }
        let file = root.appendingPathComponent(path)
        guard file.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else { return nil }
        return file
    }
    public static func remove(_ id: UUID, in root: URL) throws {
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where valid(file.lastPathComponent, for: id) { try FileManager.default.removeItem(at: file) }
    }
}
