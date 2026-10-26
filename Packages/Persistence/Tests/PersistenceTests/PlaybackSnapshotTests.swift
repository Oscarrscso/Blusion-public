import Foundation
import PlayerKit
import StremioKit
import Testing
@testable import Persistence

@Suite struct PlaybackSnapshotTests {
    private let when = Date(timeIntervalSince1970: 1_760_000_000)
    private static let addonID = UUID()

    private let request = StreamRequest(type: "series", id: "tt0360623:2010:1:1", title: "LOKI · S1E1", season: 1, episode: 1,
                                        seriesName: "LOKI", year: "2010")

    private static func stream(name: String = "Finding Nemo 2160p.mkv",
                        url: String? = "https://debrid.example.com/files/12/nemo2160.mkv?token=SECRET&expires=1",
                        infoHash: String? = nil, fileIndex: Int? = nil,
                        filename: String? = "Finding.Nemo.2003.2160p.REMUX.mkv",
                        videoSize: Int64? = 8_800_000_000, videoHash: String? = nil,
                        headers: [String: String] = ["Authorization": "Bearer SECRET", "X-Api-Key": "SECRET"]) -> AddonStream {
        var behaviorHints = StreamBehaviorHints(videoSize: videoSize, filename: filename)
        behaviorHints.videoHash = videoHash
        for (key, value) in headers { behaviorHints.proxyHeaders?.request[key] = value }
        let source: StreamSource = if let infoHash {
            .torrent(infoHash: infoHash, fileIndex: fileIndex, sources: [])
        } else if let url {
            .direct(URL(string: url)!)
        } else {
            .youtube("abcdef12345")
        }
        return AddonStream(name: name, description: "2160p REMUX", source: source, behaviorHints: behaviorHints)
    }

    private func snapshot(_ stream: AddonStream = PlaybackSnapshotTests.stream(), position: TimeInterval = 1_234.5, duration: TimeInterval? = 7_100,
                          tracks: Bool = true) -> PlaybackSnapshot {
        let identity = PlaybackStreamIdentity.make(for: stream)!
        return PlaybackSnapshot(request: request, stream: identity, addonID: Self.addonID.uuidString, addonName: "Debrid",
                                position: position, duration: duration, wasPaused: true,
                                audioTrack: tracks ? SnapshotTrack(title: "English", language: "eng") : nil,
                                subtitleTrack: tracks ? SnapshotTrack(title: "English SDH", language: "eng", isHearingImpaired: true) : nil,
                                subtitlesOff: false, layout: VideoLayout(fit: .fill, zoom: 1.2),
                                processing: VideoProcessing(deinterlace: .off, hdrOutput: .sdr), savedAt: when)
    }

    // MARK: round trip

    @Test func snapshotRoundTrips() throws {
        let round = try JSONDecoder().decode(PlaybackSnapshot.self, from: JSONEncoder().encode(snapshot()))
        #expect(round == snapshot())
    }

    /// An older or newer copy decodes: missing optional fields are defaults, and unknown keys are skipped.
    @Test func olderAndNewerCopiesDecode() throws {
        let older = """
        {"request":{"type":"movie","id":"tt1","title":"Test"},"stream":{"kind":"torrent","infoHash":"ABCDEF0123"}}
        """
        let snapshot = try JSONDecoder().decode(PlaybackSnapshot.self, from: Data(older.utf8))
        #expect(snapshot.version == PlaybackSnapshot.currentVersion)
        #expect(snapshot.request.identity == "movie/tt1")
        #expect(snapshot.stream == PlaybackStreamIdentity(kind: .torrent, infoHash: "ABCDEF0123"), "an older copy is used as it was saved")
        #expect(snapshot.position == 0 && snapshot.wasPaused == false && !snapshot.subtitlesOff)
        #expect(snapshot.audioTrack == nil && snapshot.layout == nil)

        let newer = """
        {"version":1,"request":{"type":"movie","id":"tt1","title":"Test"},"stream":{"kind":"youtube","youtubeID":"abc"},
         "stream_1":9,"position":99,"wasPaused":true,"subtitlesOff":true}
        """
        let forward = try JSONDecoder().decode(PlaybackSnapshot.self, from: Data(newer.utf8))
        #expect(forward.position == 99 && forward.wasPaused && forward.subtitlesOff)
    }

    /// A snapshot refreshed with the live player's state keeps its identity and takes the new choices.
    @Test func refreshedStateKeepsTheIdentity() throws {
        var snapshot = self.snapshot()
        let before = snapshot.stream
        snapshot.apply(PlaybackSaveState(position: 2_500, duration: 7_100, isPaused: true,
                                         subtitleTrack: SnapshotTrack(title: "English", isExternal: true), subtitlesOff: true))
        #expect(snapshot.stream == before && snapshot.addonID == Self.addonID.uuidString)
        #expect(snapshot.position == 2_500 && snapshot.wasPaused && snapshot.subtitlesOff)
        #expect(snapshot.subtitleTrack?.title == "English" && snapshot.audioTrack == nil)
        _ = try JSONDecoder().decode(PlaybackSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(try JSONDecoder().decode(PlaybackSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    }

    // MARK: privacy

    /// Neither links with their expire tokens nor proxy headers ever reach the snapshot: it describes the stream, it does not carry it.
    @Test func snapshotCarriesNoLinkCredentialsOrHeaders() throws {
        let snapshot = self.snapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let json = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
        for secret in ["SECRET", "Bearer", "Authorization", "X-Api-Key", "token=", "expires="] {
            #expect(!json.contains(secret), "the snapshot leaked \(secret)")
        }
        #expect(json.contains("https://debrid.example.com/files/12/nemo2160.mkv"), "host and path locate the file again")
        #expect(!json.contains("?"), "the link's query was stripped")
    }

    // MARK: same-stream matching (AddonStream, id-level; full-listing tests live in Features)

    @Test func anExpiredLinkStillFindsTheSameFile() {
        let identity = PlaybackStreamIdentity.make(for: Self.stream())!
        // A fresh answer for the same path, with a new (different) token in its query.
        #expect(identity.matches(Self.stream(url: "https://debrid.example.com/files/12/nemo2160.mkv?token=REFRESHED")))
        // The addon moved the file to another host and path: its own facts (name, size) say it is the same file.
        #expect(identity.matches(Self.stream(name: "Finding Nemo 2160p.mkv", url: "https://mirror.example.net/a/b/c.mkv?token=FRESH")))
        // A different file with a different link and different facts matches neither.
        #expect(!identity.matches(Self.stream(name: "Other.mkv", url: "https://debrid.example.com/files/9/other.mkv",
                                         filename: "Other.mkv", videoSize: 6_000_000_000)))
        // Not the same kind of source.
        #expect(!identity.matches(Self.stream(name: "Finding Nemo 2160p.mkv", url: nil, infoHash: "ABC", fileIndex: 0)))
    }

    @Test func theSameTorrentMatchesAcrossRename() {
        let identity = PlaybackStreamIdentity.make(for: Self.stream(name: "A mkv", url: nil, infoHash: "ABCDEF0123456789ABCDEF0123456789ABCDEF01",
                                                               fileIndex: 2))!
        #expect(identity.matches(Self.stream(name: "B mkv", url: nil, infoHash: "abcdef0123456789abcdef0123456789abcdef01", fileIndex: 2,
                                        filename: nil, videoSize: nil, videoHash: nil, headers: [:])),
                "the hash decides, the case was normalised")
        #expect(!identity.matches(Self.stream(name: "B mkv", url: nil, infoHash: "ABCDEF0123456789ABCDEF0123456789ABCDEF02", fileIndex: 2,
                                         filename: nil, videoSize: nil, videoHash: nil, headers: [:])), "a different file")
        #expect(!identity.matches(Self.stream(name: "B mkv", url: nil, infoHash: "ABCDEF0123456789ABCDEF0123456789ABCDEF01", fileIndex: 3,
                                         filename: nil, videoSize: nil, videoHash: nil, headers: [:])), "another cut of the same torrent")
        // The file index unknown either side: still the same file.
        #expect(identity.matches(Self.stream(name: "B mkv", url: nil, infoHash: "ABCDEF0123456789ABCDEF0123456789ABCDEF01", fileIndex: nil,
                                        filename: nil, videoSize: nil, videoHash: nil, headers: [:])))
    }

    /// The identity copies only what the addon published about the file, and a source Blusion never plays back has no identity at all.
    @Test func theIdentityTakesOnlyTheFilesPublishedFacts() {
        let identity = PlaybackStreamIdentity.make(for: Self.stream())!
        #expect(identity.urlPath == "https://debrid.example.com/files/12/nemo2160.mkv")
        #expect(identity.filename == "Finding.Nemo.2003.2160p.REMUX.mkv")
        #expect(identity.videoSize == 8_800_000_000)
        #expect(identity.kind == .direct)
        #expect(PlaybackStreamIdentity.make(for: AddonStream(name: "Nzb", source: .archive(kind: "nzbUrl"))) == nil,
                "no archive is ever walkable back into")
        let youtube = PlaybackStreamIdentity.make(for: AddonStream(name: "Yt", source: .youtube("abcd")))
        #expect(youtube?.kind == .youtube && youtube?.youtubeID == "abcd")
        #expect(youtube?.filename == nil && youtube?.videoSize == nil, "a YouTube id needs no file facts")
    }

    // MARK: completion

    @Test func watchedThroughIsEffectivelyFinished() {
        let snapshot = PlaybackSnapshot(request: request, stream: PlaybackStreamIdentity(kind: .direct, urlPath: "https://a.example.com/f.mkv"))
        #expect(!snapshot.isEffectivelyFinished(), "nothing was recorded")
        var watched = snapshot
        watched.position = 7_050
        watched.duration = 7_100
        #expect(watched.isEffectivelyFinished())
        var beginning = snapshot
        beginning.position = 60
        beginning.duration = 7_100
        #expect(!beginning.isEffectivelyFinished())
        var tail = snapshot
        tail.position = 7_090
        tail.duration = 7_100
        #expect(tail.isEffectivelyFinished(), "the very end belongs to a set-aside session too")
        var stretched = snapshot
        stretched.position = 700_000
        stretched.duration = 7_100
        #expect(stretched.isEffectivelyFinished())
    }
}

@Suite struct PlaybackSnapshotStoreTests {
    static let addonID = UUID()

    static func snapshot() -> PlaybackSnapshot {
        let stream = AddonStream(name: "file 2160p", source: .direct(URL(string: "https://debrid.example.com/files/1/f.mkv")!),
                                 behaviorHints: StreamBehaviorHints(videoSize: 1_500_000_000, filename: "f.mkv"))
        return PlaybackSnapshot(
            request: StreamRequest(type: "series", id: "tt0360623:2010:1:1", title: "LOKI · S1E1", season: 1, episode: 1, seriesName: "LOKI"),
            stream: PlaybackStreamIdentity(kind: .direct, urlPath: "https://debrid.example.com/files/1/f.mkv", filename: "f.mkv",
                                           videoSize: 1_500_000_000),
            addonID: PlaybackSnapshotStoreTests.addonID.uuidString, addonName: "Debrid", position: 1_234, duration: 7_100, wasPaused: true,
            audioTrack: SnapshotTrack(title: "English", language: "eng"),
            subtitleTrack: SnapshotTrack(title: "English SDH", language: "eng", isHearingImpaired: true),
            layout: VideoLayout(fit: .fill, zoom: 1.2), processing: VideoProcessing(deinterlace: .off, hdrOutput: .sdr))
    }

    @Test func inMemorySaveLoadAndClear() async throws {
        let store = InMemoryPlaybackSnapshotStore()
        #expect(await store.load() == nil)
        let snapshot = Self.snapshot()
        try await store.save(snapshot)
        #expect(await store.load() == snapshot)
        var replaced = snapshot
        replaced.position = 3_000
        try await store.save(replaced)  // one session at a time, replaced
        #expect(await store.load() == replaced)
        await store.clear()
        #expect(await store.load() == nil)
        await store.clear()
        #expect(await store.load() == nil)
    }
}

#if canImport(Darwin)
@Suite struct FilePlaybackSnapshotStoreTests {
    private func store(fileURL: URL? = nil) -> (FilePlaybackSnapshotStore, URL) {
        let url = fileURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("BlusionPlaybackSnapshot.json")
        return (FilePlaybackSnapshotStore(fileURL: url), url)
    }

    @Test func saveLoadAndClear() async throws {
        let (store, url) = self.store()
        #expect(await store.load() == nil)
        let snapshot = PlaybackSnapshotStoreTests.snapshot()
        try await store.save(snapshot)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(await store.load() == snapshot)
        await store.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await store.load() == nil)
    }

    /// A second store instance (the next launch) reads the same file, and a corrupt file is dropped rather than crashing.
    @Test func theNextLaunchReadsTheSameFileAndACorruptOneIsDropped() async throws {
        let (store, url) = self.store()
        let snapshot = PlaybackSnapshotStoreTests.snapshot()
        try await store.save(snapshot)
        let next = FilePlaybackSnapshotStore(fileURL: url)
        #expect(await next.load() == snapshot)
        try Data("not json".utf8).write(to: url)
        #expect(await next.load() == nil, "the corrupt copy is dropped, not handed back as a session")
        #expect(!FileManager.default.fileExists(atPath: url.path), "the corrupt file was cleared away")
        try await next.save(snapshot)   // saving works again after one
        #expect(await next.load() == snapshot)
    }

    @Test func sessionsAreReplacedNotAppended() async throws {
        let (store, url) = self.store()
        var replaced = PlaybackSnapshotStoreTests.snapshot()
        try await store.save(replaced)
        replaced.position = 3_000
        try await store.save(replaced)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count == 1,
                "one file for one session")
    }
}
#endif
