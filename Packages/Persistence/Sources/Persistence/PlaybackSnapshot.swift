import Foundation
import PlayerKit
import StremioKit

/// The live player's readable session state, for the snapshot store to refresh what it saved: position, pause, tracks and the
/// picture. No stream URL or header is in it: the store keeps the stream's identity, and a fresh listing locates the file again.
public struct PlaybackSaveState: Sendable, Equatable {
    public var position: TimeInterval
    public var duration: TimeInterval?
    public var isPaused: Bool
    public var audioTrack: SnapshotTrack?
    public var subtitleTrack: SnapshotTrack?
    /// The subtitles deliberately off, which a restore keeps even when a fresh engine would default them on.
    public var subtitlesOff: Bool?
    public var layout: VideoLayout
    public var processing: VideoProcessing

    public init(position: TimeInterval = 0, duration: TimeInterval? = nil, isPaused: Bool = false, audioTrack: SnapshotTrack? = nil,
                subtitleTrack: SnapshotTrack? = nil, subtitlesOff: Bool? = nil, layout: VideoLayout? = nil,
                processing: VideoProcessing? = nil) {
        self.position = position
        self.duration = duration
        self.isPaused = isPaused
        self.audioTrack = audioTrack
        self.subtitleTrack = subtitleTrack
        self.subtitlesOff = subtitlesOff
        self.layout = layout ?? VideoLayout()
        self.processing = processing ?? VideoProcessing()
    }
}

/// One chosen track, matched by its name and language against a fresh engine's numbered tracks (a fresh engine numbers its tracks its
/// own way, as `TrackPick` does between engines).
public struct SnapshotTrack: Codable, Sendable, Equatable, Hashable {
    public var title: String
    public var language: String?
    public var isForced: Bool
    public var isHearingImpaired: Bool
    /// Loaded from a file rather than found in the media, so a restore re-adds it instead of re-selecting it.
    public var isExternal: Bool

    public init(title: String, language: String? = nil, isForced: Bool = false, isHearingImpaired: Bool = false, isExternal: Bool = false) {
        self.title = title
        self.language = language
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.isExternal = isExternal
    }

    public init(_ track: MediaTrack) {
        self.init(title: track.title, language: track.language, isForced: track.isForced, isHearingImpaired: track.isHearingImpaired,
                  isExternal: track.isExternal)
    }
}

/// The stable identity of a stream, enough to recognise it again in a fresh listing without ever saving the link itself: a torrent's
/// `infoHash`, an id, and for debrid links the file's host, path, name and size. The query and fragment of a URL are dropped, so a
/// token or key a link carries was never saved, and a refreshed link for the same file still matches.
public struct PlaybackStreamIdentity: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable { case direct, torrent, youtube, external }

    public var kind: Kind
    public var infoHash: String?
    public var fileIndex: Int?
    public var youtubeID: String?
    /// Direct and external links: host and path only, never the query or fragment.
    public var urlPath: String?
    /// What the addon says the file is: the stronger hint when a debrid link's host or path changes between answers.
    public var filename: String?
    public var videoSize: Int64?
    public var videoHash: String?
    public var streamName: String?

    /// Lowercases a hash on the way in, so a copy saved by an earlier build still matches (torrents' case never carries meaning).
    public init(kind: Kind, infoHash: String? = nil, fileIndex: Int? = nil, youtubeID: String? = nil, urlPath: String? = nil,
                filename: String? = nil, videoSize: Int64? = nil, videoHash: String? = nil, streamName: String? = nil) {
        self.kind = kind
        self.infoHash = infoHash?.lowercased()
        self.fileIndex = fileIndex
        self.youtubeID = youtubeID
        self.urlPath = urlPath
        self.filename = filename
        self.videoSize = videoSize
        self.videoHash = videoHash
        self.streamName = streamName
    }

    /// Off the wire it is decoded through the normal `init` (hashes still lowercase, nothing else transformed).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: (try container.decode(Kind.self, forKey: .kind)),
                  infoHash: try container.decodeIfPresent(String.self, forKey: .infoHash),
                  fileIndex: try container.decodeIfPresent(Int.self, forKey: .fileIndex),
                  youtubeID: try container.decodeIfPresent(String.self, forKey: .youtubeID),
                  urlPath: try container.decodeIfPresent(String.self, forKey: .urlPath),
                  filename: try container.decodeIfPresent(String.self, forKey: .filename),
                  videoSize: try container.decodeIfPresent(Int64.self, forKey: .videoSize),
                  videoHash: try container.decodeIfPresent(String.self, forKey: .videoHash),
                  streamName: try container.decodeIfPresent(String.self, forKey: .streamName))
    }

    private enum CodingKeys: String, CodingKey {
        case kind, infoHash, fileIndex, youtubeID, urlPath, filename, videoSize, videoHash, streamName
    }

    /// The stream's identity, without its link or headers. nil for a source Blusion never plays back (an nzb or archive).
    public static func make(for stream: AddonStream) -> PlaybackStreamIdentity? {
        let hints = Self.hints(for: stream)
        func identity(_ kind: Kind) -> PlaybackStreamIdentity {
            var made = PlaybackStreamIdentity(kind: kind, streamName: hints.name)
            made.filename = hints.filename
            made.videoSize = hints.videoSize
            made.videoHash = hints.videoHash
            return made
        }
        switch stream.source {
        case .direct(let url):
            var made = identity(.direct)
            made.urlPath = sanitized(url)
            return made
        case .torrent(let hash, let index, _):
            var made = identity(.torrent)
            made.infoHash = hash.lowercased()
            made.fileIndex = index
            return made
        case .youtube(let id):
            var made = identity(.youtube)
            made.youtubeID = id
            return made
        case .external(let url):
            var made = identity(.external)
            made.urlPath = sanitized(url)
            return made
        case .archive:
            return nil
        }
    }

    private static func hints(for stream: AddonStream) -> (name: String, filename: String?, videoSize: Int64?, videoHash: String?) {
        (stream.name ?? stream.description?.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Stream",
         stream.behaviorHints.filename, stream.behaviorHints.videoSize, stream.behaviorHints.videoHash)
    }

    /// The identity of a player's candidate, whose id is the stream's deduplication key: `url:`, `torrent:`, `youtube:` or
    /// `external:`. A candidate built without one (a preview or a test) is identified by its playable link. nil for an archive.
    public init?(candidate: PlaybackCandidate) {
        let scheme = candidate.id.firstIndex(of: ":").map { String(candidate.id[..<$0]) }
        let rest = candidate.id.firstIndex(of: ":").map { candidate.id[candidate.id.index(after: $0)...] } ?? ""
        switch scheme {
        case "url", "external":
            guard !rest.isEmpty, let url = URL(string: String(rest)), let path = Self.sanitized(url) else { return nil }
            self.init(kind: scheme == "url" ? .direct : .external, urlPath: path, filename: candidate.filename,
                      videoSize: candidate.videoSize, videoHash: candidate.videoHash, streamName: candidate.title)
        case "torrent":
            let fields = rest.split(separator: ":", omittingEmptySubsequences: false)
            guard let hash = fields.first, !hash.isEmpty else { return nil }
            let index = fields.count > 1 ? Int(fields[1]) : nil
            self.init(kind: .torrent, infoHash: String(hash), fileIndex: index, filename: candidate.filename,
                      videoSize: candidate.videoSize, videoHash: candidate.videoHash, streamName: candidate.title)
        case "youtube":
            guard !rest.isEmpty else { return nil }
            self.init(kind: .youtube, youtubeID: String(rest), filename: candidate.filename, videoSize: candidate.videoSize,
                      videoHash: candidate.videoHash, streamName: candidate.title)
        default:
            guard let url = candidate.route.playableURL, let path = Self.sanitized(url) else { return nil }
            self.init(kind: .direct, urlPath: path, filename: candidate.filename, videoSize: candidate.videoSize,
                      videoHash: candidate.videoHash, streamName: candidate.title)
        }
    }

    /// Host and path, so a link's credentials in its query or fragment were never saved. nil for a link without a host.
    public static func sanitized(_ url: URL) -> String? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        let text = components?.string
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// The same file, offered by a fresh answer: exact identities decide, and for a debrid link whose path changed, the file's own
    /// facts (name and size, or its video hash) do. Different files never match. Torrent hashes never carry meaning, so they match in
    /// either case.
    public func matches(_ fresh: AddonStream) -> Bool {
        guard let other = Self.make(for: fresh), other.kind == kind else { return false }
        switch kind {
        case .direct:
            if let urlPath, other.urlPath == urlPath { return true }
            if let videoHash, let otherHash = other.videoHash, videoHash.caseInsensitiveCompare(otherHash) == .orderedSame { return true }
            if let filename, filename == other.filename,
               let videoSize, videoSize == other.videoSize { return true }
            return false
        case .torrent:
            let hash = infoHash?.lowercased(), otherHash = other.infoHash?.lowercased()
            return hash != nil && hash == otherHash
                && (fileIndex == nil || other.fileIndex == nil || fileIndex == other.fileIndex)
        case .youtube:
            return youtubeID != nil && youtubeID == other.youtubeID
        case .external:
            return urlPath != nil && urlPath == other.urlPath
        }
    }
}

/// The state to walk back into after the app was left or killed: what was watched, which stream it was, where it stopped and how the
/// scene was set. It never carries a link or a header: the store describes the stream, and a fresh listing finds it again (its source
/// URLs and their credentials expire anyway).
public struct PlaybackSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// What was watched. Any addon can answer this request again, so this with `stream` is how the same stream is located.
    public var request: StreamRequest
    /// The stream's stable identity, without the link or its headers.
    public var stream: PlaybackStreamIdentity
    /// The addon that provided the stream, preferred again on restore (its UUID, since manifest URLs may carry a token).
    public var addonID: String?
    public var addonName: String?
    public var position: TimeInterval
    public var duration: TimeInterval?
    public var wasPaused: Bool
    public var audioTrack: SnapshotTrack?
    public var subtitleTrack: SnapshotTrack?
    public var subtitlesOff: Bool
    public var layout: VideoLayout?
    public var processing: VideoProcessing?
    public var savedAt: Date

    public init(version: Int = PlaybackSnapshot.currentVersion, request: StreamRequest, stream: PlaybackStreamIdentity,
                addonID: String? = nil, addonName: String? = nil, position: TimeInterval = 0, duration: TimeInterval? = nil,
                wasPaused: Bool = false, audioTrack: SnapshotTrack? = nil, subtitleTrack: SnapshotTrack? = nil, subtitlesOff: Bool = false,
                layout: VideoLayout? = nil, processing: VideoProcessing? = nil, savedAt: Date = Date()) {
        self.version = version
        self.request = request
        self.stream = stream
        self.addonID = addonID
        self.addonName = addonName
        self.position = position
        self.duration = duration
        self.wasPaused = wasPaused
        self.audioTrack = audioTrack
        self.subtitleTrack = subtitleTrack
        self.subtitlesOff = subtitlesOff
        self.layout = layout
        self.processing = processing
        self.savedAt = savedAt
    }

    /// The snapshot for a stream the picker is starting. `state` says where the session resumes and what it hands over; a nil one is
    /// a fresh start. nil result: the stream is not one Blusion can walk back into (an archive source).
    public init?(ranked: RankedStream, request: StreamRequest, state: PlaybackSaveState? = nil, savedAt: Date = Date()) {
        guard let stream = PlaybackStreamIdentity.make(for: ranked.stream) else { return nil }
        self.init(request: request, stream: stream, addonID: ranked.addon.id.uuidString, addonName: ranked.addon.name,
                  position: state?.position ?? 0, duration: state?.duration, wasPaused: state?.isPaused ?? false,
                  audioTrack: state.flatMap(\.audioTrack), subtitleTrack: state.flatMap(\.subtitleTrack),
                  subtitlesOff: state?.subtitlesOff ?? false, layout: state?.layout, processing: state?.processing, savedAt: savedAt)
    }

    // MARK: restore

    /// The stream in a fresh listing that is the same file as this one, playable again under the policy it is listed with,
    /// preferring the same addon (it or an aggregator offering the same file), then any addon that offers the same file.
    /// nil when the same stream cannot be located again: the addon is gone, or no answer offers this file.
    public func match(in items: [RankedStream]) -> RankedStream? {
        let matches = items.filter { $0.route.isWatchable && stream.matches($0.stream) }
        return matches.first { $0.addon.id.uuidString == addonID }
            ?? matches.first { $0.alsoProvidedBy.contains { $0.id.uuidString == addonID } }
            ?? matches.first
    }

    /// Watched through, within `threshold` of its end: nothing left to resume, so the session sets itself aside.
    public func isEffectivelyFinished(threshold: Double = 0.92) -> Bool {
        guard let duration, duration > 0, position > 0, position.isFinite, duration.isFinite else { return false }
        return (position / duration) >= threshold || position >= duration - 15
    }

    /// Refreshes a saved session with the live player's current state, keeping its stream identity.
    public mutating func apply(_ state: PlaybackSaveState) {
        position = state.position
        duration = state.duration
        wasPaused = state.isPaused
        audioTrack = state.audioTrack
        subtitleTrack = state.subtitleTrack
        subtitlesOff = state.subtitlesOff ?? false
        layout = state.layout
        processing = state.processing
    }

    /// Tolerant of older and newer copies: every field but the identity pair has a default, and unbeknownst keys are skipped.
    private enum CodingKeys: String, CodingKey {
        case version, request, stream, addonID, addonName, position, duration, wasPaused, audioTrack, subtitleTrack, subtitlesOff,
             layout, processing, savedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(version: (try? container.decode(Int.self, forKey: .version)) ?? PlaybackSnapshot.currentVersion,
                  request: try container.decode(StreamRequest.self, forKey: .request),
                  stream: try container.decode(PlaybackStreamIdentity.self, forKey: .stream),
                  addonID: try container.decodeIfPresent(String.self, forKey: .addonID),
                  addonName: try container.decodeIfPresent(String.self, forKey: .addonName),
                  position: (try? container.decode(TimeInterval.self, forKey: .position)) ?? 0,
                  duration: try? container.decodeIfPresent(TimeInterval.self, forKey: .duration),
                  wasPaused: (try? container.decode(Bool.self, forKey: .wasPaused)) ?? false,
                  audioTrack: try container.decodeIfPresent(SnapshotTrack.self, forKey: .audioTrack),
                  subtitleTrack: try container.decodeIfPresent(SnapshotTrack.self, forKey: .subtitleTrack),
                  subtitlesOff: (try? container.decode(Bool.self, forKey: .subtitlesOff)) ?? false,
                  layout: try container.decodeIfPresent(VideoLayout.self, forKey: .layout),
                  processing: try container.decodeIfPresent(VideoProcessing.self, forKey: .processing),
                  savedAt: (try container.decodeIfPresent(Date.self, forKey: .savedAt)) ?? Date())
    }
}

/// The live player's hook to take a saved session over on restore. `PlayerViewModel` conforms, once its side of the wiring is in: a
/// restore hands it the same position, pause state, track choices and picture settings the session left off with.
@MainActor
public protocol PlaybackSnapshotResuming: AnyObject {
    func resumePlayback(from snapshot: PlaybackSnapshot)
}

/// The live player's readable session state, so its snapshot can be refreshed with where the viewer actually is while it plays
/// (position, tracks and picture), rather than the state at its start.
@MainActor
public protocol PlaybackSnapshotRecording: AnyObject {
    var saveState: PlaybackSaveState { get }
}
