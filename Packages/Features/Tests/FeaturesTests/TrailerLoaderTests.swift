import Foundation
import StremioKit
import Testing
@testable import Features

/// A player that counts what it is asked to do.
@MainActor
private final class FakePlayback: TrailerPlayback {
    let duration: TimeInterval?
    var aspectRatio: Double?
    var onFinish: (@MainActor (TrailerPlaybackError?) -> Void)?
    private(set) var playCount = 0
    private(set) var stopCount = 0

    init(duration: TimeInterval? = 90, aspectRatio: Double? = nil) {
        self.duration = duration
        self.aspectRatio = aspectRatio
    }

    func play() { playCount += 1 }
    func stop() { stopCount += 1 }
}

/// How the fake preparer answers one link or one YouTube video.
private enum Answer {
    case ready
    case fails(AddonError)
    /// YouTube will not embed the video: the preparer throws `TrailerPlaybackError.embeddingRefused`.
    case refused
    /// Waits until its task is cancelled, then throws `CancellationError`.
    case waits
    /// Ignores cancellation and finishes after a moment, as a player that is already buffering would.
    case finishesLate
}

@MainActor
private final class FakePreparer: TrailerPreparing {
    /// The answer by link. A link with no answer is ready at once.
    var answers: [String: Answer] = [:]
    /// The answer by YouTube video id. A video with no answer is ready at once.
    var youTubeAnswers: [String: Answer] = [:]
    private(set) var prepared: [URL] = []
    private(set) var preparedYouTube: [String] = []
    private(set) var players: [FakePlayback] = []
    /// The shape every player this preparer makes reports. Nil for a player that reports none.
    var playerAspectRatio: Double?

    func prepare(_ url: URL) async throws -> any TrailerPlayback {
        prepared.append(url)
        return try await answer(answers[url.absoluteString] ?? .ready)
    }

    func prepareYouTube(_ videoID: String) async throws -> any TrailerPlayback {
        preparedYouTube.append(videoID)
        return try await answer(youTubeAnswers[videoID] ?? .ready)
    }

    private func answer(_ answer: Answer) async throws -> any TrailerPlayback {
        switch answer {
        case .ready:
            return makePlayer()
        case .fails(let error):
            throw error
        case .refused:
            throw TrailerPlaybackError.embeddingRefused
        case .waits:
            try await Task.sleep(for: .seconds(60))
            return makePlayer()
        case .finishesLate:
            try? await Task.sleep(for: .milliseconds(200))
            return makePlayer()
        }
    }

    private func makePlayer() -> FakePlayback {
        let player = FakePlayback(aspectRatio: playerAspectRatio)
        players.append(player)
        return player
    }
}

/// Counts what the page's source was asked for.
@MainActor
private final class Calls {
    var planCount = 0
    /// The YouTube video ids the source was asked about, in order.
    var embeddingChecks: [String] = []
}

@MainActor
@Suite struct TrailerLoaderTests {
    private let directLink = "https://cdn.example.com/a.mp4"

    private func direct(_ name: String) -> Trailer {
        Trailer(source: .direct(URL(string: "https://cdn.example.com/\(name).mp4") ?? URL(fileURLWithPath: "/")), isOfficial: true)
    }

    private func youTube(_ id: String) -> Trailer {
        Trailer(source: .youtube(id), isOfficial: true)
    }

    /// A source whose plan is `plan`. The YouTube videos in `refusedVideos` may not be embedded, and `shapes` gives the shape YouTube
    /// reports for a video.
    private func makeSource(_ plan: TrailerPlan, calls: Calls, refusedVideos: Set<String> = [],
                            shapes: [String: Double] = [:]) -> TrailerLoader.Source {
        TrailerLoader.Source(plan: {
            calls.planCount += 1
            return plan
        }, embedCheck: { videoID in
            calls.embeddingChecks.append(videoID)
            return YouTubeEmbedCheck.Answer(allowsEmbedding: !refusedVideos.contains(videoID), aspectRatio: shapes[videoID])
        })
    }

    private func isolatedDurations() throws -> TrailerDurations {
        let suite = "TrailerLoaderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return TrailerDurations(defaults: defaults)
    }

    private func makeLoader(_ preparer: FakePreparer, deadline: Duration = TrailerLoader.loadDeadline) throws -> TrailerLoader {
        TrailerLoader(preparer: preparer, durations: try isolatedDurations(), deadline: deadline)
    }

    // MARK: playing

    @Test func aTapLoadsThenPlaysTheFirstPlayableTrailer() async throws {
        let preparer = FakePreparer()
        let durations = try isolatedDurations()
        let loader = TrailerLoader(preparer: preparer, durations: durations)
        let calls = Calls()
        loader.toggle(makeSource(TrailerPlan(trailers: [direct("a"), direct("b")]), calls: calls))
        #expect(loader.phase == .loading, "the spinner shows at once")
        try await waitUntil { loader.isPlaying }
        #expect(loader.phase == .playing(direct("a")))
        #expect(loader.showsPanel)
        #expect(loader.playback === preparer.players.first)
        #expect(preparer.players.first?.playCount == 1, "played once, when it became ready")
        #expect(preparer.prepared.count == 1)
        #expect(durations.seconds[direct("a").id] == 90, "the length is recorded under the trailer's id")
    }

    @Test func aYouTubeTrailerPlaysInThePageAndIsNotHandedOver() async throws {
        let preparer = FakePreparer()
        let loader = try makeLoader(preparer)
        let calls = Calls()
        loader.toggle(makeSource(TrailerPlan(trailers: [youTube("abc123")]), calls: calls))
        try await waitUntil { loader.isPlaying }
        #expect(loader.phase == .playing(youTube("abc123")))
        #expect(preparer.preparedYouTube == ["abc123"])
        #expect(preparer.prepared.isEmpty)
        #expect(calls.embeddingChecks == ["abc123"], "YouTube is asked first")
        #expect(loader.youTubeHandoff == nil)
        #expect(preparer.players.first?.playCount == 1)
    }

    @Test func directFilesAreTriedBeforeYouTube() async throws {
        let preparer = FakePreparer()
        let loader = try makeLoader(preparer)
        let calls = Calls()
        loader.toggle(makeSource(TrailerPlan(trailers: [direct("a"), youTube("abc123")]), calls: calls))
        try await waitUntil { loader.isPlaying }
        #expect(loader.phase == .playing(direct("a")))
        #expect(calls.embeddingChecks.isEmpty && preparer.preparedYouTube.isEmpty, "the YouTube video is not touched when a file plays")
    }

    @Test func aYouTubeTrailerIsTriedWhenTheDirectFileFails() async throws {
        let preparer = FakePreparer()
        preparer.answers[directLink] = .fails(.network("urlerror.-1005"))
        let loader = try makeLoader(preparer)
        loader.toggle(makeSource(TrailerPlan(trailers: [direct("a"), youTube("abc123")]), calls: Calls()))
        try await waitUntil { loader.isPlaying }
        #expect(loader.phase == .playing(youTube("abc123")))
        #expect(preparer.prepared.count == 1 && preparer.preparedYouTube == ["abc123"])
    }

    @Test func aRefusedYouTubeVideoIsSkippedAndTheNextOnePlays() async throws {
        let preparer = FakePreparer()
        let loader = try makeLoader(preparer)
        let calls = Calls()
        loader.toggle(makeSource(TrailerPlan(trailers: [youTube("bad"), youTube("good")]), calls: calls, refusedVideos: ["bad"]))
        try await waitUntil { loader.isPlaying }
        #expect(loader.phase == .playing(youTube("good")))
        #expect(calls.embeddingChecks == ["bad", "good"])
        #expect(preparer.preparedYouTube == ["good"], "prepareYouTube is never asked for the refused video")
        #expect(loader.youTubeHandoff == nil, "a refused video that is skipped for a playable one is not opened in the YouTube app")
    }

    @Test func whenEveryYouTubeVideoIsRefusedTheFirstIsHandedOver() async throws {
        let preparer = FakePreparer()
        let loader = try makeLoader(preparer)
        loader.toggle(makeSource(TrailerPlan(trailers: [youTube("bad1"), youTube("bad2")]), calls: Calls(),
                                 refusedVideos: ["bad1", "bad2"]))
        try await waitUntil { loader.youTubeHandoff != nil }
        #expect(loader.youTubeHandoff == youTube("bad1"), "the first refused video goes to the YouTube app")
        #expect(loader.phase == .idle && loader.playback == nil && !loader.showsPanel)
        #expect(preparer.preparedYouTube.isEmpty)
    }

    @Test func aRefusalFromThePlayerCountsAsARefusedVideo() async throws {
        let preparer = FakePreparer()
        preparer.youTubeAnswers["bad"] = .refused
        let loader = try makeLoader(preparer)
        loader.toggle(makeSource(TrailerPlan(trailers: [youTube("bad")]), calls: Calls()))
        try await waitUntil { loader.youTubeHandoff != nil }
        #expect(loader.youTubeHandoff == youTube("bad"))
        #expect(loader.phase == .idle)
    }

    @Test func aPlayerRefusalSkipsToTheNextYouTubeVideo() async throws {
        let preparer = FakePreparer()
        preparer.youTubeAnswers["bad"] = .refused
        let loader = try makeLoader(preparer)
        loader.toggle(makeSource(TrailerPlan(trailers: [youTube("bad"), youTube("good")]), calls: Calls()))
        try await waitUntil { loader.isPlaying }
        #expect(loader.phase == .playing(youTube("good")))
        #expect(preparer.preparedYouTube == ["bad", "good"])
        #expect(loader.youTubeHandoff == nil)
    }

    // MARK: failing and retrying

    @Test func aFailingDirectFileFallsThroughToTheNext() async throws {
        let preparer = FakePreparer()
        preparer.answers[directLink] = .fails(.network("urlerror.-1005"))
        let loader = try makeLoader(preparer)
        loader.toggle(makeSource(TrailerPlan(trailers: [direct("a"), direct("b")]), calls: Calls()))
        try await waitUntil { loader.isPlaying }
        #expect(loader.phase == .playing(direct("b")))
        #expect(preparer.prepared.count == 2)
    }

    @Test func nothingPlayableShowsAMessageAndTheNextTapTriesAgain() async throws {
        let preparer = FakePreparer()
        preparer.answers[directLink] = .fails(.network("x"))
        let loader = try makeLoader(preparer)
        let calls = Calls()
        let source = makeSource(TrailerPlan(trailers: [direct("a")]), calls: calls)
        loader.toggle(source)
        try await waitUntil { loader.phase == .failed("The trailer couldn't be played.") }
        #expect(loader.showsPanel && !loader.isPlaying, "the failure line is shown in the panel")
        preparer.answers[directLink] = nil
        loader.toggle(source)
        try await waitUntil { loader.isPlaying }
        #expect(calls.planCount == 2, "a failed load is tried again on the next tap")
    }

    @Test func aTitleWithNoTrailerSaysSo() async throws {
        let loader = try makeLoader(FakePreparer())
        loader.toggle(makeSource(TrailerPlan(trailers: []), calls: Calls()))
        try await waitUntil { loader.phase == .failed("No trailer could be found.") }
    }

    @Test func theFailureMessagesFollowTheCause() {
        let played = "The trailer couldn't be played."
        let offline = "You're offline. The trailer can't load."
        #expect(TrailerLoader.message(for: .offline, tried: 0) == offline)
        #expect(TrailerLoader.message(for: .offline, tried: 2) == offline, "offline wins over anything else")
        #expect(TrailerLoader.message(for: .http(status: 401), tried: 0) == "No trailer could be found.", "nothing was tried at all")
        #expect(TrailerLoader.message(for: .http(status: 403), tried: 1) == played)
        #expect(TrailerLoader.message(for: .network("x"), tried: 1) == played)
        #expect(TrailerLoader.message(for: nil, tried: 0) == "No trailer could be found.")
    }

    // MARK: how a playing trailer ends

    @Test func aPlayerThatEndsClosesThePanel() async throws {
        let preparer = FakePreparer()
        let loader = try makeLoader(preparer)
        loader.toggle(makeSource(TrailerPlan(trailers: [direct("a")]), calls: Calls()))
        try await waitUntil { loader.isPlaying }
        let player = try #require(preparer.players.first)
        player.onFinish?(nil)
        #expect(loader.phase == .idle && loader.playback == nil && !loader.showsPanel)
        #expect(player.stopCount == 1, "the ended player is released")
    }

    @Test func aPlayerThatCannotGoOnShowsTheFailureLine() async throws {
        let preparer = FakePreparer()
        let loader = try makeLoader(preparer)
        loader.toggle(makeSource(TrailerPlan(trailers: [direct("a")]), calls: Calls()))
        try await waitUntil { loader.isPlaying }
        let player = try #require(preparer.players.first)
        player.onFinish?(.unplayable)
        #expect(loader.phase == .failed("The trailer couldn't be played."))
        #expect(player.stopCount == 1)
    }

    @Test func aPlayerThatYouTubeRefusesMidwayIsHandedOver() async throws {
        let preparer = FakePreparer()
        let loader = try makeLoader(preparer)
        loader.toggle(makeSource(TrailerPlan(trailers: [youTube("abc123")]), calls: Calls()))
        try await waitUntil { loader.isPlaying }
        let player = try #require(preparer.players.first)
        player.onFinish?(.embeddingRefused)
        #expect(loader.youTubeHandoff == youTube("abc123"), "the YouTube app opens it instead")
        #expect(loader.phase == .idle && loader.playback == nil)
    }

    // MARK: deadline

    @Test func aLoadThatTakesTooLongFailsWithTheDeadlineMessage() async throws {
        let preparer = FakePreparer()
        preparer.answers[directLink] = .waits
        let loader = try makeLoader(preparer, deadline: .milliseconds(100))
        let calls = Calls()
        let source = makeSource(TrailerPlan(trailers: [direct("a")]), calls: calls)
        loader.toggle(source)
        try await waitUntil { loader.phase == .failed("The trailer took too long to load.") }
        #expect(loader.playback == nil && !loader.isPlaying)
        #expect(preparer.players.isEmpty, "the load that was given up never plays")

        preparer.answers[directLink] = nil
        loader.toggle(source)
        #expect(loader.phase == .loading, "a tap after the deadline starts a fresh load")
        try await waitUntil { loader.isPlaying }
        #expect(loader.phase == .playing(direct("a")))
        #expect(calls.planCount == 2)
    }

    @Test func aLoadThatFinishesInTimeIsNotTouchedByTheDeadlineAfterwards() async throws {
        let preparer = FakePreparer()
        let loader = try makeLoader(preparer, deadline: .milliseconds(150))
        loader.toggle(makeSource(TrailerPlan(trailers: [direct("a")]), calls: Calls()))
        try await waitUntil { loader.isPlaying }
        try await Task.sleep(for: .milliseconds(300))
        #expect(loader.phase == .playing(direct("a")), "past the deadline, the playing trailer stays")
        #expect(preparer.players.first?.stopCount == 0)
    }

    // MARK: closing and leaving

    @Test func aTapWhilePlayingClosesThePlayer() async throws {
        let preparer = FakePreparer()
        let loader = try makeLoader(preparer)
        let source = makeSource(TrailerPlan(trailers: [direct("a")]), calls: Calls())
        loader.toggle(source)
        try await waitUntil { loader.isPlaying }
        loader.toggle(source)
        #expect(loader.phase == .idle && loader.playback == nil && !loader.isFullScreen)
        #expect(preparer.players.first?.stopCount == 1, "closing pauses and releases the player")
    }

    @Test func closingKeepsAFailureLine() async throws {
        let preparer = FakePreparer()
        preparer.answers[directLink] = .fails(.network("x"))
        let loader = try makeLoader(preparer)
        loader.toggle(makeSource(TrailerPlan(trailers: [direct("a")]), calls: Calls()))
        try await waitUntil { loader.phase == .failed("The trailer couldn't be played.") }
        loader.close()
        #expect(loader.phase == .failed("The trailer couldn't be played."), "only a playing trailer closes to idle")
    }

    @Test func leavingThePageCancelsALoadThatIsStillPreparing() async throws {
        let preparer = FakePreparer()
        preparer.answers[directLink] = .waits
        let loader = try makeLoader(preparer)
        loader.toggle(makeSource(TrailerPlan(trailers: [direct("a")]), calls: Calls()))
        try await waitUntil { preparer.prepared.count == 1 }
        loader.cancel()
        #expect(loader.phase == .idle)
        try await Task.sleep(for: .milliseconds(50))
        #expect(loader.phase == .idle && loader.playback == nil)
        #expect(preparer.players.isEmpty)
    }

    @Test func leavingThePageWhileTheSourceIsStillPlanningPlaysNothing() async throws {
        let preparer = FakePreparer()
        let loader = try makeLoader(preparer)
        let planned = direct("a")
        let source = TrailerLoader.Source(plan: {
            try? await Task.sleep(for: .milliseconds(100))
            return TrailerPlan(trailers: [planned])
        }, embedCheck: { _ in YouTubeEmbedCheck.Answer(allowsEmbedding: true) })
        loader.toggle(source)
        #expect(loader.phase == .loading)
        loader.cancel()
        try await Task.sleep(for: .milliseconds(250))
        #expect(loader.phase == .idle && loader.playback == nil && !loader.isPlaying)
        #expect(preparer.prepared.isEmpty && preparer.players.isEmpty, "the plan's trailer is never prepared")
    }

    @Test func aPlayerThatFinishesAfterLeavingIsStoppedAndNeverShown() async throws {
        let preparer = FakePreparer()
        preparer.answers[directLink] = .finishesLate
        let loader = try makeLoader(preparer)
        loader.toggle(makeSource(TrailerPlan(trailers: [direct("a")]), calls: Calls()))
        try await waitUntil { preparer.prepared.count == 1 }
        loader.cancel()
        try await waitUntil { preparer.players.first?.stopCount == 1 }
        #expect(preparer.players.first?.playCount == 0, "never played")
        #expect(loader.phase == .idle && loader.playback == nil, "never shown")
    }

    // MARK: shape

    @Test func thePlayersShapeIsTheLoadersWhenThePlayerHasOne() async throws {
        let preparer = FakePreparer()
        preparer.playerAspectRatio = 1.0
        let loader = try makeLoader(preparer)
        loader.toggle(makeSource(TrailerPlan(trailers: [youTube("abc123")]), calls: Calls(), shapes: ["abc123": 1.7]))
        try await waitUntil { loader.isPlaying }
        #expect(loader.aspectRatio == 1.0, "the player's own shape is used over YouTube's answer")
    }

    @Test func aYouTubeTrailerWithoutAPlayersShapeUsesTheCheckAnswer() async throws {
        let loader = try makeLoader(FakePreparer())
        loader.toggle(makeSource(TrailerPlan(trailers: [youTube("abc123")]), calls: Calls(), shapes: ["abc123": 1.7]))
        try await waitUntil { loader.isPlaying }
        #expect(loader.aspectRatio == 1.7)
    }

    @Test func aDirectFileWithoutAPlayersShapeHasNoShape() async throws {
        let loader = try makeLoader(FakePreparer())
        loader.toggle(makeSource(TrailerPlan(trailers: [direct("a")]), calls: Calls(), shapes: ["abc123": 1.7]))
        try await waitUntil { loader.isPlaying }
        #expect(loader.aspectRatio == nil, "a file has no answer from YouTube, so the panel is 16:9")
    }

    @Test func theShapeIsForgottenWhenThePlayerCloses() async throws {
        let preparer = FakePreparer()
        preparer.playerAspectRatio = 0.5625
        let loader = try makeLoader(preparer)
        let source = makeSource(TrailerPlan(trailers: [direct("a")]), calls: Calls())
        loader.toggle(source)
        try await waitUntil { loader.isPlaying }
        #expect(loader.aspectRatio == 0.5625)
        loader.toggle(source)
        #expect(loader.aspectRatio == nil, "closing sets the shape back to nil")
    }

    @Test func theShapeIsForgottenWhenThePageIsLeft() async throws {
        let loader = try makeLoader(FakePreparer())
        loader.toggle(makeSource(TrailerPlan(trailers: [youTube("abc123")]), calls: Calls(), shapes: ["abc123": 1.3]))
        try await waitUntil { loader.isPlaying }
        #expect(loader.aspectRatio == 1.3)
        loader.cancel()
        #expect(loader.aspectRatio == nil)
    }
}
