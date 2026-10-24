import Foundation
import StremioKit

public struct SubtitleOption: Sendable, Equatable, Identifiable {
    public enum Source: Sendable, Equatable {
        case stream
        case addon(String)
        /// A file the user opened.
        case local
        case openSubtitles
    }

    /// What the file holds, from its name or address. `unknown` files are parsed as text and sniffed.
    public enum FileFormat: String, Sendable, Equatable {
        case srt, vtt, ass, pgs, vobsub, unknown

        /// Picture subtitles or styled ones: drawn best (or only) by an engine with `.engineSubtitles`.
        public var prefersEngine: Bool { self == .ass || self == .pgs || self == .vobsub }

        public static func detect(_ url: URL, name: String? = nil) -> FileFormat {
            let candidates = [name.map { ($0 as NSString).pathExtension }, url.pathExtension,
                              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "format" }?.value]
            for ext in candidates.compactMap({ $0?.lowercased() }) {
                switch ext {
                case "srt": return .srt
                case "vtt", "webvtt": return .vtt
                case "ass", "ssa": return .ass
                case "sup", "pgs": return .pgs
                case "idx", "sub": return .vobsub
                default: continue
                }
            }
            return .unknown
        }
    }

    public let id: String
    /// Canonical ISO 639-2 code (`eng`).
    public let language: String
    public let title: String
    public let url: URL
    public let source: Source
    public let format: FileFormat
    public let isForced: Bool
    public let isHearingImpaired: Bool

    public init(id: String, language: String, title: String, url: URL, source: Source, format: FileFormat? = nil,
                isForced: Bool? = nil, isHearingImpaired: Bool? = nil) {
        self.id = id
        self.language = language
        self.title = title
        self.url = url
        self.source = source
        self.format = format ?? FileFormat.detect(url)
        let text = "\(id) \(title) \(url.lastPathComponent)"
        self.isForced = isForced ?? SubtitleOption.marks(text, #"\bforced\b|\bforeign[ ._-]?parts?\b"#)
        self.isHearingImpaired = isHearingImpaired ?? SubtitleOption.marks(text, #"\b(sdh|cc|hi|hoh)\b|hearing[ ._-]?impaired"#)
    }

    /// The file names tags in words: "Movie.2020.en.forced.srt", "English SDH".
    static func marks(_ text: String, _ pattern: String) -> Bool {
        let spaced = text.replacingOccurrences(of: #"[._\-\[\]()]"#, with: " ", options: .regularExpression)
        return spaced.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Finds and loads external subtitles: those bundled with the stream, and those from addons that offer the `subtitles` resource.
public final class SubtitleService: Sendable {
    private let registry: AddonRegistry
    private let client: AddonClient

    public init(registry: AddonRegistry, client: AddonClient) {
        self.registry = registry
        self.client = client
    }

    /// Asks every addon that supports `subtitles` for this request, in parallel, passing the stream's hash, size and filename when known.
    public func fetch(for candidate: PlaybackCandidate, request: StreamRequest) async -> AsyncStream<AddonResponse<[SubtitleItem]>> {
        let addons = await registry.addons(for: .subtitles, type: request.type, id: request.id)
        var extras: [ExtraParam] = []
        if let hash = candidate.videoHash { extras.append(ExtraParam("videoHash", hash)) }
        if let size = candidate.videoSize { extras.append(ExtraParam("videoSize", String(size))) }
        if let filename = candidate.filename { extras.append(ExtraParam("filename", filename)) }
        let client = self.client
        let finalExtras = extras
        return FanOut.run(over: addons) { addon in
            try await client.subtitles(base: addon.baseURL, type: request.type, id: request.id, extras: finalExtras)
        }
    }

    /// Options from stream-bundled subtitles.
    public static func options(from streamSubtitles: [SubtitleItem]) -> [SubtitleOption] {
        streamSubtitles.map { option(from: $0, source: .stream) }
    }

    public static func options(from items: [SubtitleItem], addon: String) -> [SubtitleOption] {
        items.map { option(from: $0, source: .addon(addon)) }
    }

    private static func option(from item: SubtitleItem, source: SubtitleOption.Source) -> SubtitleOption {
        let language = LanguageCodes.normalise(item.lang)
        var title = LanguageCodes.displayName(item.lang)
        if case .addon(let name) = source { title += " · \(name)" }
        return SubtitleOption(id: "\(item.id)|\(item.url.absoluteString)", language: language, title: title, url: item.url, source: source)
    }

    /// Appends `new` options, dropping any whose URL is already present.
    public static func merge(_ existing: [SubtitleOption], _ new: [SubtitleOption]) -> [SubtitleOption] {
        var seen = Set(existing.map(\.url))
        return existing + new.filter { seen.insert($0.url).inserted }
    }

    /// The option matching the preferred language; stream-bundled subtitles win over addon ones, then list order. Forced-only files are
    /// passed over (they would leave most dialogue untranslated), and SDH files are taken or passed over as `prefersSDH` says.
    public static func defaultOption(in options: [SubtitleOption], preferredLanguage: String?, prefersSDH: Bool = false) -> SubtitleOption? {
        guard let preferredLanguage, !preferredLanguage.isEmpty else { return nil }
        let matching = options.filter { LanguageCodes.matches($0.language, preferred: preferredLanguage) && !$0.isForced }
        let preferred = matching.filter { $0.isHearingImpaired == prefersSDH }
        for pool in [preferred, matching] {
            if let pick = pool.first(where: { $0.source == .stream }) ?? pool.first { return pick }
        }
        return nil
    }

    /// Downloads (capped at 8 MB, as styled files embed fonts) or reads a local file, and parses it.
    public func load(_ option: SubtitleOption) async throws -> SubtitleTimeline {
        SubtitleTimeline(cues: try SubtitleParser.parse(data: try await data(for: option)).cues)
    }

    /// The file's bytes, for the app's own drawing (text or PGS pictures).
    public func data(for option: SubtitleOption, maxBytes: Int = 8 * 1024 * 1024) async throws -> Data {
        if option.url.isFileURL {
            let data = try Data(contentsOf: option.url, options: .mappedIfSafe)
            guard data.count <= maxBytes else { throw SubtitleError.tooLarge }
            return data
        }
        return try await client.get(option.url, limits: FetchLimits(maxBytes: maxBytes)).data
    }
}
