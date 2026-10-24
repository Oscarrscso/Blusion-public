import Foundation

public struct ProxyHeaders: Sendable, Equatable, Hashable, Codable {
    public var request: [String: String]
    public var response: [String: String]

    public init(request: [String: String] = [:], response: [String: String] = [:]) {
        self.request = request
        self.response = response
    }

    private enum Keys: String, CodingKey { case request, response }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        self.init(request: container.stringMap(.request), response: container.stringMap(.response))
    }

    public var isEmpty: Bool { request.isEmpty && response.isEmpty }
}

public struct StreamBehaviorHints: Sendable, Equatable, Hashable, Codable {
    public var notWebReady: Bool
    public var bingeGroup: String?
    public var proxyHeaders: ProxyHeaders?
    public var videoHash: String?
    public var videoSize: Int64?
    public var filename: String?
    public var countryWhitelist: [String]

    public init(notWebReady: Bool = false, bingeGroup: String? = nil, proxyHeaders: ProxyHeaders? = nil, videoHash: String? = nil,
                videoSize: Int64? = nil, filename: String? = nil, countryWhitelist: [String] = []) {
        self.notWebReady = notWebReady
        self.bingeGroup = bingeGroup
        self.proxyHeaders = proxyHeaders
        self.videoHash = videoHash
        self.videoSize = videoSize
        self.filename = filename
        self.countryWhitelist = countryWhitelist
    }

    private enum Keys: String, CodingKey {
        case notWebReady, bingeGroup, proxyHeaders, videoHash, videoSize, filename, countryWhitelist
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let headers: ProxyHeaders? = container.object(.proxyHeaders)
        self.init(notWebReady: container.bool(.notWebReady),
                  bingeGroup: container.string(.bingeGroup),
                  proxyHeaders: (headers?.isEmpty ?? true) ? nil : headers,
                  videoHash: container.string(.videoHash),
                  videoSize: container.scalar(.videoSize)?.intValue.map(Int64.init),
                  filename: container.string(.filename),
                  countryWhitelist: container.stringArray(.countryWhitelist))
    }
}

/// What a stream actually points at. Exactly one source per stream (precedence: url, infoHash, ytId, externalUrl, archive/usenet).
public enum StreamSource: Sendable, Equatable, Hashable {
    case direct(URL)
    case torrent(infoHash: String, fileIndex: Int?, sources: [String])
    case youtube(String)
    case external(URL)
    /// nzb, rar, zip, 7zip, tgz, tar forms. Parsed so they can be filtered out; unsupported in v1.
    case archive(kind: String)
}

/// One entry of a stream response. (Not named `Stream`: that collides with Foundation.)
public struct AddonStream: Sendable, Equatable, Hashable, Codable {
    public var name: String?
    /// `description`, or the legacy `title`.
    public var description: String?
    public var source: StreamSource
    public var subtitles: [SubtitleItem]
    public var behaviorHints: StreamBehaviorHints

    public init(name: String? = nil, description: String? = nil, source: StreamSource,
                subtitles: [SubtitleItem] = [], behaviorHints: StreamBehaviorHints = .init()) {
        self.name = name
        self.description = description
        self.source = source
        self.subtitles = subtitles
        self.behaviorHints = behaviorHints
    }

    private enum Keys: String, CodingKey {
        case name, description, title, url, infoHash, fileIdx, sources, ytId, externalUrl, subtitles, behaviorHints
        case nzbUrl, rarUrls, zipUrls, sevenZipUrls = "7zipUrls", tgzUrls, tarUrls
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let source: StreamSource
        if let url = container.url(.url) {
            source = .direct(url)
        } else if let hash = container.string(.infoHash)?.lowercased() {
            source = .torrent(infoHash: hash, fileIndex: container.int(.fileIdx), sources: container.stringArray(.sources))
        } else if let id = container.string(.ytId) {
            source = .youtube(id)
        } else if let external = container.url(.externalUrl) {
            source = .external(external)
        } else if let kind = [Keys.nzbUrl, .rarUrls, .zipUrls, .sevenZipUrls, .tgzUrls, .tarUrls].first(where: { container.contains($0) }) {
            source = .archive(kind: kind.rawValue)
        } else {
            throw DroppedItem(reason: "stream without a recognised source")
        }
        self.init(name: container.string(.name),
                  description: container.string(.description) ?? container.string(.title),
                  source: source,
                  subtitles: container.lossyArray(.subtitles),
                  behaviorHints: container.object(.behaviorHints) ?? .init())
    }

    /// Flat encoding that decodes back to the same value (used by tests and caches).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        switch source {
        case .direct(let url): try container.encode(url, forKey: .url)
        case .torrent(let hash, let index, let sources):
            try container.encode(hash, forKey: .infoHash)
            try container.encodeIfPresent(index, forKey: .fileIdx)
            try container.encode(sources, forKey: .sources)
        case .youtube(let id): try container.encode(id, forKey: .ytId)
        case .external(let url): try container.encode(url, forKey: .externalUrl)
        case .archive(let kind): try container.encode("", forKey: Keys(rawValue: kind) ?? .nzbUrl)
        }
        try container.encode(subtitles, forKey: .subtitles)
        try container.encode(behaviorHints, forKey: .behaviorHints)
    }

    /// Display title: addon-provided name, then first line of the description.
    public var displayName: String {
        name ?? description?.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Stream"
    }
}
