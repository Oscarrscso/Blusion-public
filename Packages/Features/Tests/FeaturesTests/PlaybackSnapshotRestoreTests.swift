import Foundation
import Persistence
import PlayerKit
import StremioKit
import StremioKitTestSupport
import Testing
@testable import Features

/// The previous viewing session (plan 2B): saved when a stream starts in Blusion, walked back into when the app is opened again, and
/// set aside when it was closed or watched through. Never a different stream, never a lost position, never a saved link or header.
@MainActor
@Suite struct PlaybackSnapshotRestoreTests {
    private let request = StreamRequest(type: "movie", id: "tt1", title: "Test Movie", year: "2010")
    private static let filename = "Test.Movie.2010.2160p.REMUX.mp4"
    private static let size: Int64 = 8_800_000_000

    private func services(bodies: [String], progress: [WatchProgress] = []) async throws -> AppServices {
        let transport = StubTransport { request, _ in
            let index = Int(request.url?.host?.dropFirst(4).prefix(while: \.isNumber) ?? "0") ?? 0
            return StubTransport.response(Data(bodies[index].utf8), for: request)
        }
        let (registry, client) = try await makeStubbedRegistry(manifests: bodies.indices.map { streamManifest("addon\($0)") },
                                                               transport: transport)
        return AppServices(registry: registry, client: client, settings: InMemorySettingsStore(),
                           progress: InMemoryProgressStore(progress))
    }

    private func body(_ streams: [String]) -> String { #"{"streams":[\#(streams.joined(separator: ","))]}"# }

    /// A direct stream with the file facts addons publish (name and size), which locate it again when a fresh answer carries a new link.
    private func direct(_ name: String, _ url: String, filename: String = Self.filename, size: Int64 = PlaybackSnapshotRestoreTests.size,
                        proxy: [String: String] = ["Authorization": "Bearer SECRET"]) -> String {
        let hints = proxy.isEmpty ? ""
            : #","behaviorHints":{"filename":"\#(filename)","videoSize":\#(size),"proxyHeaders":{"request":\#(Self.headers(proxy))}}"#
        return #"{"name":"\#(name)","description":"2160p REMUX","url":"\#(url)"\#(hints)}"#
    }

    private static func headers(_ headers: [String: String]) -> String {
        let pairs = headers.map { #""\#($0)":"\#($1)""# }.sorted().joined(separator: ",")
        return "{\(pairs)}"
    }

    // MARK: saving on start

    @Test func startingAStreamSavesTheSession() async throws {
        let store = InMemoryPlaybackSnapshotStore()
        let services = try await services(bodies: [body([direct("4K REMUX", "https://a.example.com/1/f.mkv?token=one")])])
        let picker = StreamPickerViewModel(request: request, services: services, snapshotStore: store)
        await picker.load()
        let item = try #require(picker.listing.items.first)
        _ = try #require(await picker.choose(item) != nil, "the stream starts")
        await picker.saveResumeSnapshot(for: item)

        let saved = try #require(await store.load())
        #expect(saved.request.identity == request.identity)
        #expect(saved.stream.kind == .direct)
        #expect(saved.stream.urlPath == "https://a.example.com/1/f.mkv", "the link itself, with its token, was never saved")
        #expect(saved.wasPaused == false && saved.audioTrack == nil, "nothing was chosen yet at the start")
    }

    @Test func aStreamHandedOutsideBlusionSavesNoSession() async throws {
        let store = InMemoryPlaybackSnapshotStore()
        let external = #"{"name":"Links","externalUrl":"https://example.com/watch"}"#
        let services = try await services(bodies: [body([external])])
        let picker = StreamPickerViewModel(request: request, services: services, snapshotStore: store)
        await picker.load()
        await picker.saveResumeSnapshot(for: try #require(picker.listing.items.first))
        #expect(await store.load() == nil, "a stream in another player app has no session to walk back into")
    }

    // MARK: walking back in

    @Test func theRelaunchWalksBackIntoTheSameStream() async throws {
        let store = InMemoryPlaybackSnapshotStore()
        let first = try await services(bodies: [body([direct("4K REMUX", "https://a.example.com/1/f.mkv?token=EXPIRED")])],
                                       progress: [WatchProgress(id: request.identity, type: request.type, contentID: request.id,
                                                                title: request.title, poster: nil, position: 1_200, duration: 7_100,
                                                                isWatched: false, updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                                                season: nil, episode: nil)])
        let before = StreamPickerViewModel(request: request, services: first, snapshotStore: store)
        await before.load()
        await before.saveResumeSnapshot(for: try #require(before.listing.items.first))

        // The app is killed and relaunched: the fresh answer carries a new (different) link for the same file, and one other stream.
        let next = try await services(bodies: [body([direct("4K REMUX", "https://debrid.example.net/x2/f.mkv?token=FRESH"),
                                                     direct("Other file", "https://b.example.com/2/other.mkv", filename: "Other.mkv",
                                                            size: 7_000_000_000)])])
        let after = StreamPickerViewModel(request: request, services: next, snapshotStore: store)
        await after.load()
        await after.loadSessionResume()

        let matched = try #require(after.matchedResumeStream(), "the same file, on its new link")
        #expect(after.automaticStartCandidate == matched, "the start resumes the session's own stream")
        let handed = try #require(after.resumeHandoff(for: matched))
        #expect(handed.stream.urlPath == "https://a.example.com/1/f.mkv")
        #expect(handed.position == 1_200, "the resume position of the session, as progress had it")
        #expect(after.resumeHandoff(for: try #require(after.listing.items.first(where: { $0.id != matched.id }))) == nil,
                "another stream is not handed a session")
    }

    /// A link that expired is not a problem, because the store never carried one: only the file's own facts.
    @Test func anExpiredLinkIsRefreshedByAskingAgain() {
        let fresh = AddonStream(name: "4K REMUX", source: .direct(URL(string: "https://debrid.example.net/x2/f.mkv?token=FRESH")!),
                                behaviorHints: StreamBehaviorHints(videoSize: Self.size, filename: Self.filename))
        var identity = PlaybackStreamIdentity(kind: .direct, urlPath: "https://a.example.com/1/f.mkv", filename: Self.filename,
                                              videoSize: Self.size)
        #expect(identity.matches(fresh))
        identity.filename = nil
        #expect(!identity.matches(fresh), "no link and no facts: not the same stream")
    }

    @Test func anUnrecoverableSessionShowsTheListInsteadOfStartingAnother() async throws {
        let store = InMemoryPlaybackSnapshotStore()
        let first = try await services(bodies: [body([direct("4K REMUX", "https://a.example.com/1/f.mkv")])])
        let before = StreamPickerViewModel(request: request, services: first, snapshotStore: store)
        await before.load()
        await before.saveResumeSnapshot(for: try #require(before.listing.items.first))

        // Relaunched: the addon no longer offers that file, only another one. Whatever the viewer does, the position stays.
        let next = try await services(bodies: [body([direct("Other file", "https://a.example.com/2/other.mkv?token=FRESH",
                                                            filename: "Other.mkv", size: 7_000_000_000)])])
        let after = StreamPickerViewModel(request: request, services: next, snapshotStore: store)
        await after.load()
        await after.loadSessionResume()
        #expect(after.resumeSnapshot != nil, "the position is still kept")
        #expect(after.matchedResumeStream() == nil)
        #expect(after.automaticStartCandidate == nil, "no other stream starts by itself")
        #expect(await store.load() != nil)
    }

    @Test func aSessionForAnotherTitleIsNotWalkedInto() async throws {
        let store = InMemoryPlaybackSnapshotStore()
        try await store.save(Self.snapshot(request: StreamRequest(type: "movie", id: "tt2", title: "Another Movie")))
        let services = try await services(bodies: [body([direct("4K REMUX", "https://a.example.com/1/f.mkv?token=t")])])
        let picker = StreamPickerViewModel(request: request, services: services, snapshotStore: store)
        await picker.load()
        await picker.loadSessionResume()
        #expect(picker.resumeSnapshot == nil)
        #expect(await store.load() != nil, "the other title's session is untouched")
    }

    @Test func aWatchedSessionIsSetAsideOnLoad() async throws {
        let store = InMemoryPlaybackSnapshotStore()
        var finished = Self.snapshot(request: request)
        finished.position = 7_050
        finished.duration = 7_100
        try await store.save(finished)
        let services = try await services(bodies: [body([direct("4K REMUX", "https://a.example.com/1/f.mkv")])])
        let picker = StreamPickerViewModel(request: request, services: services, snapshotStore: store)
        await picker.load()
        await picker.loadSessionResume()
        #expect(picker.resumeSnapshot == nil)
        #expect(await store.load() == nil, "watched through: nothing to walk back into")
    }

    // MARK: set aside

    @Test func anExplicitCloseSetsTheSessionAside() async throws {
        let store = InMemoryPlaybackSnapshotStore()
        let services = try await services(bodies: [body([direct("4K REMUX", "https://a.example.com/1/f.mkv")])])
        let picker = StreamPickerViewModel(request: request, services: services, snapshotStore: store)
        await picker.load()
        await picker.saveResumeSnapshot(for: try #require(picker.listing.items.first))
        #expect(await store.load() != nil)
        await picker.clearSessionResume()
        #expect(await store.load() == nil)
        #expect(picker.resumeSnapshot == nil)
    }

    private static func snapshot(request: StreamRequest) -> PlaybackSnapshot {
        PlaybackSnapshot(request: request, stream: PlaybackStreamIdentity(kind: .direct, urlPath: "https://a.example.com/1/f.mkv",
                                                                          filename: filename, videoSize: size), position: 600,
                         duration: 7_100)
    }
}
