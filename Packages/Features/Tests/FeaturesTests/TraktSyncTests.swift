import Foundation
import Testing
import PlayerKit
import StremioKit
import StremioKitTestSupport
@testable import Features

/// A Trakt account that remembers what is sent to it, so two devices can sync through it as the iPhone and the Mac do.
private final class FakeTrakt: @unchecked Sendable {
    struct Paused: Equatable {
        var id: Int
        var identity: String
        var progress: Double
        var at: Date
    }

    private let lock = NSLock()
    private let clock: TestClock
    private var listed: [String: Date] = [:]
    private var owned: [String: Date] = [:]
    private var watches: [String: [Date]] = [:]
    private var paused: [Paused] = []
    private var changed: [String: Date] = [:]
    private var nextPausedID = 1
    private var log: [String] = []
    private var isOffline = false
    private var refusals: [String: Int] = [:]
    private var lostAnswers: Set<String> = []
    private var hooks: [String: @Sendable () async -> Void] = [:]

    init(clock: TestClock) { self.clock = clock }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // What the tests arrange and read.
    var watchlist: Set<String> { locked { Set(listed.keys) } }
    var collection: Set<String> { locked { Set(owned.keys) } }
    var playback: [Paused] { locked { paused } }
    var requests: [String] { locked { log } }
    func plays(_ identity: String) -> Int { locked { watches[identity]?.count ?? 0 } }
    func forgetRequests() { locked { log = [] } }
    func goOffline(_ offline: Bool) { locked { isOffline = offline } }
    /// Answers one kind of request (such as `POST /sync/watchlist`) with this status until cleared with nil.
    func refuse(_ request: String, status: Int?) { locked { refusals[request] = status } }
    /// Takes the change at `path` but loses the answer on the way back, as a timeout does.
    func loseAnswers(for path: String, _ lose: Bool) { locked { if lose { lostAnswers.insert(path) } else { lostAnswers.remove(path) } } }
    func list(_ identity: String, at date: Date) { locked { listed[identity] = date; changed["watchlist"] = clock.now } }
    func unlist(_ identity: String) { locked { listed[identity] = nil; changed["watchlist"] = clock.now } }
    func unlistEverythingSilently() { locked { listed = [:] } }
    func collect(_ identity: String, at date: Date) { locked { owned[identity] = date; changed["collection"] = clock.now } }
    func watch(_ identity: String, at date: Date) { locked { watches[identity, default: []].append(date); changed["watched"] = clock.now } }
    func pause(_ identity: String, progress: Double, at date: Date) {
        locked {
            paused.append(Paused(id: nextPausedID, identity: identity, progress: progress, at: date))
            nextPausedID += 1
        }
    }

    /// Runs `body` once, while the next request of this kind (such as `POST /sync/history`) is out: after Trakt took it, before its
    /// answer arrives.
    func whileOut(_ request: String, _ body: @escaping @Sendable () async -> Void) { locked { hooks[request] = body } }

    var transport: StubTransport {
        StubTransport { [self] request, _ in
            let result = try answer(request)
            let hook = locked { hooks.removeValue(forKey: "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")") }
            await hook?()
            return result
        }
    }

    private static let token = #"{"access_token":"access","refresh_token":"refresh","expires_in":604800,"created_at":1700000000}"#

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parts(_ identity: String) -> (type: String, imdb: String, season: Int?, episode: Int?) {
        let type = String(identity.split(separator: "/")[0])
        let content = identity.split(separator: "/")[1].split(separator: ":").map(String.init)
        return (type, content[0], content.count > 2 ? Int(content[1]) : nil, content.count > 2 ? Int(content[2]) : nil)
    }

    private static func json(_ value: Any, status: Int = 200, for request: URLRequest) -> HTTPResult {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
        return HTTPResult(data: data, response: HTTPResponseInfo(statusCode: status, headers: [:], url: request.url))
    }

    private func answer(_ request: URLRequest) throws -> HTTPResult {
        try locked {
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            if path.hasPrefix("/oauth/") { return StubTransport.response(Data(Self.token.utf8), for: request) }
            log.append("\(method) \(path)")
            if isOffline { throw AddonError.offline }
            if let status = refusals["\(method) \(path)"] { return Self.json([:] as [String: Any], status: status, for: request) }
            let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            let result = respond(method: method, path: path, body: body, request: request)
            if lostAnswers.contains(path) { throw AddonError.timeout }
            return result
        }
    }

    /// The identities a sync body names: movies and shows by IMDb id, episodes under their show.
    private static func identities(in body: [String: Any]) -> [(identity: String, at: Date?)] {
        var found: [(String, Date?)] = []
        let date: ([String: Any]) -> Date? = { ($0["watched_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } }
        for movie in body["movies"] as? [[String: Any]] ?? [] {
            if let imdb = (movie["ids"] as? [String: String])?["imdb"] { found.append(("movie/\(imdb)", date(movie))) }
        }
        for show in body["shows"] as? [[String: Any]] ?? [] {
            guard let imdb = (show["ids"] as? [String: String])?["imdb"] else { continue }
            guard let seasons = show["seasons"] as? [[String: Any]] else {
                found.append(("series/\(imdb)", nil))
                continue
            }
            for season in seasons {
                for episode in season["episodes"] as? [[String: Any]] ?? [] {
                    found.append(("series/\(imdb):\(season["number"] as? Int ?? 0):\(episode["number"] as? Int ?? 0)", date(episode)))
                }
            }
        }
        return found
    }

    private func respond(method: String, path: String, body: [String: Any], request: URLRequest) -> HTTPResult {
        let media: (String) -> [String: Any] = { identity in
            let parts = Self.parts(identity)
            return ["title": "Title \(parts.imdb)", "year": 2020, "ids": ["imdb": parts.imdb], "runtime": 100]
        }
        switch (method, path) {
        case ("GET", "/sync/last_activities"):
            var movies: [String: String] = [:]
            if let date = changed["watchlist"] { movies["watchlisted_at"] = Self.iso(date) }
            if let date = changed["collection"] { movies["collected_at"] = Self.iso(date) }
            if let date = changed["watched"] { movies["watched_at"] = Self.iso(date) }
            return Self.json(["movies": movies], for: request)
        case ("GET", "/sync/watchlist"):
            return Self.json(listed.sorted { $0.key < $1.key }.map { identity, date -> [String: Any] in
                [Self.parts(identity).type == "movie" ? "movie" : "show": media(identity), "listed_at": Self.iso(date)]
            }, for: request)
        case ("GET", "/sync/collection/movies"):
            return Self.json(owned.filter { $0.key.hasPrefix("movie/") }.sorted { $0.key < $1.key }.map { identity, date -> [String: Any] in
                ["movie": media(identity), "collected_at": Self.iso(date)]
            }, for: request)
        case ("GET", "/sync/collection/shows"):
            return Self.json(owned.filter { $0.key.hasPrefix("series/") }.sorted { $0.key < $1.key }.map { identity, date -> [String: Any] in
                ["show": media(identity), "last_collected_at": Self.iso(date)]
            }, for: request)
        case ("GET", "/sync/watched/movies"):
            return Self.json(watches.filter { $0.key.hasPrefix("movie/") && !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { identity, dates -> [String: Any] in
                ["movie": media(identity), "last_watched_at": Self.iso(dates.max() ?? .distantPast)]
            }, for: request)
        case ("GET", "/sync/watched/shows"):
            let episodes = watches.filter { $0.key.hasPrefix("series/") && !$0.value.isEmpty }.sorted { $0.key < $1.key }
            return Self.json(episodes.map { identity, dates -> [String: Any] in
                let parts = Self.parts(identity)
                return ["show": media(identity), "seasons": [["number": parts.season ?? 0, "episodes": [
                    ["number": parts.episode ?? 0, "last_watched_at": Self.iso(dates.max() ?? .distantPast)]]]]]
            }, for: request)
        case ("POST", "/sync/watchlist"):
            let named = Self.identities(in: body)
            for item in named { listed[item.identity] = clock.now }
            changed["watchlist"] = clock.now
            return Self.json(["added": ["movies": named.count]], for: request)
        case ("POST", "/sync/watchlist/remove"):
            let named = Self.identities(in: body)
            for item in named { listed[item.identity] = nil }
            changed["watchlist"] = clock.now
            return Self.json(["deleted": ["movies": named.count]], for: request)
        case ("POST", "/sync/history"):
            let named = Self.identities(in: body)
            for item in named { watches[item.identity, default: []].append(item.at ?? clock.now) }
            changed["watched"] = clock.now
            return Self.json(["added": ["movies": named.count]], for: request)
        case ("POST", "/sync/history/remove"):
            let named = Self.identities(in: body)
            for item in named { watches[item.identity] = nil }
            changed["watched"] = clock.now
            return Self.json(["deleted": ["movies": named.count]], for: request)
        case ("GET", "/sync/playback"):
            return Self.json(paused.map { row -> [String: Any] in
                let parts = Self.parts(row.identity)
                var entry: [String: Any] = ["id": row.id, "progress": row.progress, "paused_at": Self.iso(row.at)]
                if let season = parts.season, let episode = parts.episode {
                    entry["type"] = "episode"
                    entry["show"] = media(row.identity)
                    entry["episode"] = ["season": season, "number": episode, "title": "Episode", "runtime": 50]
                } else {
                    entry["type"] = "movie"
                    entry["movie"] = media(row.identity)
                }
                return entry
            }, for: request)
        case ("POST", "/scrobble/pause"):
            var identity = ""
            if let movie = body["movie"] as? [String: Any], let imdb = (movie["ids"] as? [String: String])?["imdb"] {
                identity = "movie/\(imdb)"
            } else if let show = body["show"] as? [String: Any], let imdb = (show["ids"] as? [String: String])?["imdb"],
                      let episode = body["episode"] as? [String: Int] {
                identity = "series/\(imdb):\(episode["season"] ?? 0):\(episode["number"] ?? 0)"
            }
            paused.removeAll { $0.identity == identity }
            paused.append(Paused(id: nextPausedID, identity: identity, progress: body["progress"] as? Double ?? 0, at: clock.now))
            nextPausedID += 1
            return Self.json(["action": "pause"], status: 201, for: request)
        default:
            if method == "DELETE", path.hasPrefix("/sync/playback/"), let id = Int(path.split(separator: "/").last ?? "") {
                paused.removeAll { $0.id == id }
                return Self.json([:] as [String: Any], status: 204, for: request)
            }
            return Self.json([:] as [String: Any], status: 404, for: request)
        }
    }
}

/// The time, moved by the tests.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_100)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        date += seconds
        lock.unlock()
    }
}

/// One device: its own stores and sync state, signed in to the shared account.
private struct Device {
    let plainLibrary = InMemoryLibraryStore()
    let plainProgress = InMemoryProgressStore()
    let state = InMemoryTraktSyncStateStore()
    let account: TraktAccount
    let sync: TraktSync
    let library: SyncedLibraryStore
    let progress: SyncedProgressStore

    init(trakt: FakeTrakt, clock: TestClock, signedIn: Bool = true) async throws {
        let settings = InMemorySettingsStore(PlaybackSettings(traktClientID: "client"))
        account = TraktAccount(settings: settings, secrets: InMemorySecretStore(), transport: trakt.transport,
                               now: { Date(timeIntervalSince1970: 1_700_000_001) })
        if signedIn {
            try await account.saveClientSecret("secret")
            let code = #"{"device_code":"device","user_code":"ABCD1234","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":5}"#
            _ = try await account.checkAuthorization(try JSONDecoder().decode(TraktDeviceCode.self, from: Data(code.utf8)))
        }
        sync = TraktSync(account: account, library: plainLibrary, progress: plainProgress, store: state, now: { clock.now })
        library = SyncedLibraryStore(base: plainLibrary, sync: sync)
        progress = SyncedProgressStore(base: plainProgress, sync: sync)
    }

    /// The device after a relaunch: the same stores and saved state, a new engine.
    func relaunched(clock: TestClock) -> TraktSync {
        TraktSync(account: account, library: plainLibrary, progress: plainProgress, store: state, now: { clock.now })
    }

    func saved() async -> Set<String> { Set(await plainLibrary.all().map(\.id)) }
    func watched() async -> Set<String> { Set(await plainProgress.all().filter(\.isWatched).map(\.id)) }
}

@Suite struct TraktSyncTests {
    private let clock = TestClock()

    private func title(_ imdb: String, type: String = "movie", at date: Date) -> LibraryItem {
        LibraryItem(preview: MetaPreview(id: imdb, type: type, name: "Title \(imdb)"), addedAt: date)
    }

    private func mark(_ identity: String, at date: Date) -> WatchProgress {
        let content = String(identity.split(separator: "/")[1])
        let parts = content.split(separator: ":")
        return WatchProgress(id: identity, type: String(identity.split(separator: "/")[0]), contentID: content, title: "T", position: 0,
                             duration: 0, isWatched: true, updatedAt: date, season: parts.count > 2 ? Int(parts[1]) : nil,
                             episode: parts.count > 2 ? Int(parts[2]) : nil)
    }

    private func position(_ identity: String, _ seconds: TimeInterval, of duration: TimeInterval = 6000, at date: Date) -> WatchProgress {
        WatchProgress(id: identity, type: "movie", contentID: String(identity.split(separator: "/")[1]), title: "T", position: seconds,
                      duration: duration, isWatched: false, updatedAt: date)
    }

    // MARK: Saved titles across two devices

    @Test func aSavedTitleReachesTheOtherDeviceAndRemovingItThereRemovesItHere() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        let mac = try await Device(trakt: trakt, clock: clock)

        await phone.library.add(title("tt1", at: clock.now))
        #expect(await phone.sync.pendingCount() == 1)
        let sent = try await phone.sync.sync()
        #expect(sent.savedSent == 1 && trakt.watchlist == ["movie/tt1"])
        // The phone reads the watchlist back, as it does by itself shortly after sending.
        try await phone.sync.sync()

        let pulled = try await mac.sync.sync()
        #expect(pulled.savedAdded == 1)
        #expect(await mac.saved() == ["movie/tt1"])
        #expect(await mac.plainLibrary.all().first?.addedAt == clock.now, "the title keeps the date Trakt listed it")

        clock.advance(61)
        await mac.library.remove("movie/tt1")
        try await mac.sync.sync()
        #expect(trakt.watchlist.isEmpty)

        clock.advance(61)
        let removed = try await phone.sync.sync()
        #expect(removed.savedRemoved == 1)
        #expect(await phone.saved().isEmpty, "a title removed on the Mac leaves the phone")
        #expect(await phone.sync.pendingCount() == 0, "what Trakt removed is not sent back as a removal")
    }

    @Test func aTitleThisDeviceNeverSentIsKeptWhenTraktDoesNotListIt() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        await phone.plainLibrary.add(title("tt1", at: clock.now))
        await phone.plainLibrary.add(title("kitsu:7", at: clock.now))
        try await phone.sync.sync(force: true)
        #expect(await phone.saved() == ["movie/tt1", "movie/kitsu:7"], "missing from Trakt is not the same as removed on Trakt")
        #expect(trakt.watchlist.isEmpty, "nothing is sent that the user did not ask to send")

        try await phone.sync.sync(force: true, sendingLocalOnly: true)
        #expect(trakt.watchlist == ["movie/tt1"], "the Sync button sends what Trakt never had; a title without an IMDb id cannot go")
    }

    // MARK: Deletion events

    @Test func aRemovedTitleIsNotBroughtBackByTraktsOlderEntryButIsByANewerOne() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        trakt.list("movie/tt1", at: clock.now)
        try await phone.sync.sync()
        #expect(await phone.saved() == ["movie/tt1"])

        // The removal never reaches Trakt: it refuses it for good, so the queue lets it go.
        clock.advance(61)
        trakt.refuse("POST /sync/watchlist/remove", status: 422)
        await phone.library.remove("movie/tt1")
        try await phone.sync.sync()
        #expect(await phone.sync.pendingCount() == 0)
        #expect(trakt.watchlist == ["movie/tt1"], "Trakt still lists it")

        clock.advance(61)
        let again = try await phone.sync.sync(force: true)
        #expect(again.savedAdded == 0)
        #expect(await phone.saved().isEmpty, "an import of the older entry does not resurrect the title")

        // Listed again later, on another device: that is newer than the removal here.
        clock.advance(61)
        trakt.list("movie/tt1", at: clock.now)
        let revived = try await phone.sync.sync()
        #expect(revived.savedAdded == 1)
        #expect(await phone.saved() == ["movie/tt1"])
    }

    // MARK: The queue

    @Test func changesMadeOfflineWaitInTheQueueAndSurviveARelaunch() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        trakt.goOffline(true)
        await phone.library.add(title("tt1", at: clock.now))
        await phone.progress.save(mark("movie/tt2", at: clock.now))
        await #expect(throws: TraktAccountError.self) { try await phone.sync.sync() }
        #expect(await phone.sync.pendingCount() == 2)
        #expect(trakt.watchlist.isEmpty)

        let relaunched = phone.relaunched(clock: clock)
        #expect(await relaunched.pendingCount() == 2, "the queue is on disk, not in memory")
        trakt.goOffline(false)
        let summary = try await relaunched.sync()
        #expect(summary.savedSent == 1 && summary.watchedSent == 1)
        #expect(trakt.watchlist == ["movie/tt1"] && trakt.plays("movie/tt2") == 1)
        #expect(await relaunched.pendingCount() == 0)
    }

    @Test func aChangeUndoneBeforeItLeftSendsNothingAndTheLatestChangeReplacesTheEarlier() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        await phone.library.add(title("tt1", at: clock.now))
        await phone.library.remove("movie/tt1")
        #expect(await phone.sync.pendingCount() == 0, "saved and removed before either left: nothing to send")

        await phone.progress.save(mark("movie/tt2", at: clock.now))
        await phone.progress.remove("movie/tt2")
        #expect(await phone.sync.pendingCount() == 0)

        await phone.progress.save(position("movie/tt3", 600, at: clock.now))
        await phone.progress.save(position("movie/tt3", 1800, at: clock.now))
        #expect(await phone.sync.pendingCount() == 1, "one position per title, the newest")
        clock.advance(TraktSync.playbackSettle + 1)
        try await phone.sync.sync()
        #expect(trakt.playback.map(\.progress) == [30])
        #expect(trakt.requests.filter { $0 == "POST /scrobble/pause" }.count == 1)
    }

    @Test func aPositionWaitsUntilPlaybackHasSettled() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        await phone.progress.save(position("movie/tt1", 600, at: clock.now))
        try await phone.sync.sync()
        #expect(trakt.playback.isEmpty, "still playing: not sent yet")
        #expect(await phone.sync.pendingCount() == 1)
    }

    @Test func aLostAnswerIsRetriedWithoutCountingTheWatchTwice() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        trakt.loseAnswers(for: "/sync/history", true)
        await phone.progress.save(mark("movie/tt1", at: clock.now))
        await #expect(throws: TraktAccountError.self) { try await phone.sync.sync() }
        #expect(trakt.plays("movie/tt1") == 1, "Trakt took it; only the answer was lost")
        #expect(await phone.sync.pendingCount() == 1, "the phone cannot know, so it keeps the change")

        // Retried at once, well inside the minute in which Trakt's change dates are not normally asked for again.
        trakt.loseAnswers(for: "/sync/history", false)
        try await phone.sync.sync()
        #expect(trakt.plays("movie/tt1") == 1, "the retry reads Trakt first, finds the watch there and does not add a second play")
        #expect(await phone.sync.pendingCount() == 0)
        #expect(await phone.watched() == ["movie/tt1"])
    }

    @Test func aChangeUndoneWhileItsRequestIsOutIsStillUndoneOnTrakt() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        await phone.progress.save(mark("movie/tt1", at: clock.now))
        await phone.library.add(title("tt2", at: clock.now))
        trakt.whileOut("POST /sync/history") { await phone.progress.remove("movie/tt1") }
        trakt.whileOut("POST /sync/watchlist") { await phone.library.remove("movie/tt2") }
        try await phone.sync.sync()
        #expect(trakt.plays("movie/tt1") == 1 && trakt.watchlist == ["movie/tt2"], "both requests had already reached Trakt")
        #expect(await phone.sync.pendingCount() == 2, "so undoing them is queued, not cancelled against a change Trakt now has")
        try await phone.sync.sync()
        #expect(trakt.plays("movie/tt1") == 0 && trakt.watchlist.isEmpty)
        #expect(await phone.sync.pendingCount() == 0)
    }

    @Test func clearingTheHistoryHereReadsTraktAgainBeforeAnyWatchIsSent() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        trakt.watch("movie/tt1", at: clock.now)
        try await phone.sync.sync()
        await phone.progress.clear()
        await phone.progress.save(mark("movie/tt1", at: clock.now))
        try await phone.sync.sync()
        #expect(trakt.plays("movie/tt1") == 1, "Trakt already has this watch; it is not counted a second time")
        #expect(await phone.sync.pendingCount() == 0)
    }

    @Test func aRefusedChangeIsDroppedAndTheTitleStaysHere() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        trakt.refuse("POST /sync/watchlist", status: 420)
        await phone.library.add(title("tt1", at: clock.now))
        try await phone.sync.sync()
        #expect(await phone.sync.pendingCount() == 0, "a full watchlist will refuse it again, so it is not retried for ever")
        clock.advance(61)
        try await phone.sync.sync(force: true)
        #expect(await phone.saved() == ["movie/tt1"], "never having reached Trakt, it is not taken for a title removed there")
    }

    @Test func aSignInProblemKeepsTheQueueUntouched() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        try await phone.sync.sync()
        trakt.refuse("POST /sync/watchlist", status: 401)
        await phone.library.add(title("tt1", at: clock.now))
        await #expect(throws: TraktAccountError.network(.http(status: 401))) { try await phone.sync.sync() }
        #expect(await phone.sync.pendingCount() == 1)
        trakt.refuse("POST /sync/watchlist", status: nil)
        try await phone.sync.sync()
        #expect(trakt.watchlist == ["movie/tt1"])
    }

    // MARK: Watched marks

    @Test func clearingAWatchedMarkReachesTraktAndTheOtherDevice() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        let mac = try await Device(trakt: trakt, clock: clock)
        await phone.progress.save([mark("movie/tt1", at: clock.now), mark("series/tt9:1:2", at: clock.now)])
        try await phone.sync.sync()
        try await phone.sync.sync()
        #expect(trakt.plays("movie/tt1") == 1 && trakt.plays("series/tt9:1:2") == 1)
        try await mac.sync.sync()
        #expect(await mac.watched() == ["movie/tt1", "series/tt9:1:2"])

        clock.advance(61)
        await mac.progress.remove("series/tt9:1:2")
        try await mac.sync.sync()
        #expect(trakt.plays("series/tt9:1:2") == 0)

        clock.advance(61)
        let summary = try await phone.sync.sync()
        #expect(summary.watchedRemoved == 1)
        #expect(await phone.watched() == ["movie/tt1"], "the episode unmarked on the Mac is unmarked on the phone")
    }

    @Test func anOlderWatchOnTraktDoesNotRestoreAClearedMarkButANewerOneDoes() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        trakt.watch("movie/tt1", at: clock.now)
        try await phone.sync.sync()
        #expect(await phone.watched() == ["movie/tt1"])

        clock.advance(61)
        trakt.refuse("POST /sync/history/remove", status: 422)
        await phone.progress.remove("movie/tt1")
        try await phone.sync.sync()
        clock.advance(61)
        try await phone.sync.sync(force: true)
        #expect(await phone.watched().isEmpty, "the watch Trakt still has is older than the mark being cleared here")

        clock.advance(61)
        trakt.watch("movie/tt1", at: clock.now)
        try await phone.sync.sync()
        #expect(await phone.watched() == ["movie/tt1"], "watched again since: that is newer than the clearing")
    }

    // MARK: Watchlist and collection

    @Test func collectionTitlesAreReadAndNeverWritten() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        trakt.collect("movie/tt5", at: clock.now)
        try await phone.sync.sync()
        #expect(await phone.saved() == ["movie/tt5"], "a collected title shows as saved")

        clock.advance(61)
        try await phone.sync.sync(force: true, sendingLocalOnly: true)
        #expect(trakt.watchlist.isEmpty, "being in the collection does not put it on the watchlist")

        clock.advance(61)
        await phone.library.remove("movie/tt5")
        #expect(await phone.sync.pendingCount() == 0, "removing it here sends nothing: it was never on the watchlist")
        try await phone.sync.sync(force: true)
        #expect(await phone.saved().isEmpty, "and the collection does not bring it back")
        #expect(trakt.collection == ["movie/tt5"], "the collection itself is untouched")
        #expect(!trakt.requests.contains { $0.hasPrefix("POST /sync/collection") })
    }

    @Test func aTitleLeavingTheWatchlistStaysWhileTheCollectionHoldsIt() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        trakt.list("movie/tt1", at: clock.now)
        trakt.collect("movie/tt1", at: clock.now)
        try await phone.sync.sync()
        clock.advance(61)
        trakt.unlist("movie/tt1")
        let summary = try await phone.sync.sync()
        #expect(summary.savedRemoved == 0)
        #expect(await phone.saved() == ["movie/tt1"])
    }

    // MARK: Safety

    @Test func anAnswerThatWouldEmptyALargeLibraryIsNotBelievedQuietlyButAForcedSyncBelievesIt() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        let count = TraktSync.largestQuietRemoval + 5
        for number in 1...count { trakt.list("movie/tt\(number)", at: clock.now) }
        try await phone.sync.sync()
        #expect(await phone.saved().count == count)

        clock.advance(TraktSync.fullPullInterval + 1)
        trakt.unlistEverythingSilently()
        let quiet = try await phone.sync.sync()
        #expect(quiet.savedRemoved == 0)
        #expect(await phone.saved().count == count, "an empty list could be a failing server, so nothing is removed for it")

        let forced = try await phone.sync.sync(force: true)
        #expect(forced.savedRemoved == count)
        #expect(await phone.saved().isEmpty, "the user asked: Trakt's empty watchlist is taken at its word")
    }

    @Test func nothingIsFetchedAgainWhileTraktsChangeDatesStandStill() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        trakt.list("movie/tt1", at: clock.now)
        try await phone.sync.sync()
        trakt.forgetRequests()
        try await phone.sync.sync()
        #expect(trakt.requests.isEmpty, "within a minute Trakt is not asked at all")
        clock.advance(61)
        try await phone.sync.sync()
        #expect(trakt.requests == ["GET /sync/last_activities"], "after that, one small request says nothing changed")
    }

    // MARK: Paused positions

    @Test func aTitleTakenOffContinueWatchingIsHiddenAtOnceAndRemovedFromTrakt() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        trakt.pause("movie/tt1", progress: 40, at: clock.now)
        trakt.pause("movie/tt2", progress: 10, at: clock.now)
        let remote = try await phone.account.playback()
        #expect(await phone.sync.visiblePlayback(remote).count == 2)

        clock.advance(10)
        await phone.sync.playbackRemoved("movie/tt1")
        #expect(await phone.sync.visiblePlayback(remote).map(\.id) == ["movie/tt2"], "hidden before Trakt has removed it")
        try await phone.sync.sync()
        #expect(trakt.playback.map(\.identity) == ["movie/tt2"])
        #expect(await phone.sync.pendingCount() == 0)
    }

    @Test func traktsPositionsAreKeptHereWithoutBeingSentBack() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        // Paused elsewhere at 40%, here at 10% earlier: Trakt's is newer.
        await phone.plainProgress.save(position("movie/tt1", 600, at: clock.now))
        // Here at the same place as Trakt: nothing to take.
        await phone.plainProgress.save(position("movie/tt2", 1205, of: 6020, at: clock.now))
        clock.advance(30)
        trakt.pause("movie/tt1", progress: 40, at: clock.now)
        trakt.pause("movie/tt2", progress: 20, at: clock.now)
        await phone.sync.storeRemotePlayback(try await phone.account.playback())
        #expect(await phone.plainProgress.progress(for: "movie/tt1")?.position == 2400)
        #expect(await phone.plainProgress.progress(for: "movie/tt2")?.duration == 6020, "the same place keeps this file's own length")
        #expect(await phone.sync.pendingCount() == 0, "what came from Trakt is not a change to send to Trakt")
    }

    // MARK: Signed out, and what cannot sync

    @Test func signedOutNothingIsQueuedButRemovalsAreStillRemembered() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock, signedIn: false)
        await phone.library.add(title("tt1", at: clock.now))
        await phone.library.remove("movie/tt1")
        await phone.progress.save(mark("movie/tt2", at: clock.now))
        #expect(await phone.sync.pendingCount() == 0)
        #expect(try await phone.sync.sync() == TraktSync.Summary(), "signed out, a sync does nothing")
        #expect(trakt.requests.isEmpty)
        #expect(await phone.state.load().removedSaved["movie/tt1"] != nil)
    }

    @Test func signingOutDropsTheQueueAndWhatWasKnownOfTraktButKeepsRemovals() async throws {
        let trakt = FakeTrakt(clock: clock)
        let phone = try await Device(trakt: trakt, clock: clock)
        trakt.list("movie/tt1", at: clock.now)
        trakt.collect("movie/tt5", at: clock.now)
        try await phone.sync.sync()
        #expect(await phone.state.load().collected == ["movie/tt5"])
        await phone.library.remove("movie/tt1")
        await phone.library.add(title("tt2", at: clock.now))
        #expect(await phone.sync.pendingCount() == 2)
        await phone.sync.signedOut()
        let state = await phone.state.load()
        #expect(state.operations.isEmpty && state.syncedSaved.isEmpty && state.activities == nil)
        #expect(state.collected.isEmpty, "another account's sync must not remove a title for having left this one's collection")
        #expect(await phone.saved().contains("movie/tt5"), "the title itself stays")
        #expect(state.removedSaved["movie/tt1"] != nil)
    }

    @Test func onlyIMDbMoviesShowsAndEpisodesBecomeOperations() {
        let date = Date(timeIntervalSince1970: 0)
        #expect(TraktSyncOperation(kind: .save, identity: "movie/tt1", at: date) != nil)
        #expect(TraktSyncOperation(kind: .save, identity: "series/tt1", at: date) != nil)
        #expect(TraktSyncOperation(kind: .save, identity: "movie/kitsu:1", at: date) == nil)
        #expect(TraktSyncOperation(kind: .save, identity: "tv/tt1", at: date) == nil)
        #expect(TraktSyncOperation(kind: .save, identity: "series/tt1:1:2", at: date) == nil, "an episode is not saved; its show is")
        #expect(TraktSyncOperation(kind: .watched, identity: "series/tt1:1:2", at: date) != nil)
        #expect(TraktSyncOperation(kind: .watched, identity: "series/tt1", at: date) == nil, "a show is watched one episode at a time")
        #expect(TraktSyncOperation(kind: .progress, identity: "movie/tt1", at: date, progress: 5)?.id == "playback|movie/tt1")
    }

    @Test func aStateFileFromAnEarlierBuildDecodesWithWhatItHas() throws {
        let state = try JSONDecoder().decode(TraktSyncState.self, from: Data(#"{"removedSaved":{"movie/tt1":0}}"#.utf8))
        #expect(state.removedSaved.count == 1 && state.operations.isEmpty && state.syncedSaved.isEmpty)
    }
}
