import Foundation
import Observation
import StremioKit

/// Why a trailer could not be played.
public enum TrailerPlaybackError: Error, Equatable {
    /// The player could not open the trailer, or it has nothing to show.
    case unplayable
    /// The player did not get ready in time.
    case timedOut
    /// YouTube does not let this video play in an embedded player.
    case embeddingRefused
}

/// A trailer's player once it can start. The page shows it; stopping it pauses it and lets the stream go.
@MainActor
public protocol TrailerPlayback: AnyObject {
    /// The trailer's length in seconds, when the player knows it.
    var duration: TimeInterval? { get }
    /// The picture's width over its height, when the player knows it.
    var aspectRatio: Double? { get }
    /// Called when a trailer that had started stops by itself: with nil when it played to its end, or with the reason it could not go
    /// on. The loader sets it.
    var onFinish: (@MainActor (TrailerPlaybackError?) -> Void)? { get set }
    func play()
    /// Pauses and releases the player. It is not used again.
    func stop()
}

/// Makes the player for a trailer's link, or for a YouTube video, and waits until it can start.
public protocol TrailerPreparing: Sendable {
    /// Gives `url` to the player as it is and returns once enough has buffered to start. Throws when the link cannot be played, and
    /// `CancellationError` when the task is cancelled; either way the player it made is released.
    @MainActor func prepare(_ url: URL) async throws -> any TrailerPlayback
    /// Makes YouTube's embedded player for a video and returns once it is ready to start. Throws
    /// `TrailerPlaybackError.embeddingRefused` when YouTube will not embed it, another error when it cannot be loaded, and
    /// `CancellationError` when cancelled; either way the player it made is released.
    @MainActor func prepareYouTube(_ videoID: String) async throws -> any TrailerPlayback
}

/// The preparer where there is no player (tests, and hosts without AVKit): every trailer fails.
public struct UnavailableTrailerPreparer: TrailerPreparing {
    public init() {}

    @MainActor
    public func prepare(_ url: URL) async throws -> any TrailerPlayback {
        throw AddonError.notFound
    }

    @MainActor
    public func prepareYouTube(_ videoID: String) async throws -> any TrailerPlayback {
        throw AddonError.notFound
    }
}

/// The trailers a tap tries, best first.
public struct TrailerPlan: Sendable {
    public var trailers: [Trailer]

    public init(trailers: [Trailer]) {
        self.trailers = trailers
    }
}

/// The one trailer flow of a title page: the trailer button's tap finds the trailers, prepares the first that can play and shows
/// it in the page's panel. A direct file plays in AVKit's player; a YouTube video plays in YouTube's embedded player, when YouTube
/// allows it. Only one load runs at a time, leaving the page cancels it, and a load that takes longer than `loadDeadline` is given up.
@MainActor
@Observable
public final class TrailerLoader {
    public enum Phase: Equatable {
        case idle
        /// Finding the trailer and buffering it.
        case loading
        /// The trailer is in the inline player.
        case playing(Trailer)
        /// Nothing could be played; another tap tries again.
        case failed(String)
    }

    /// How long one load may take, from the tap until a trailer starts. A load that is still going then is given up.
    static let loadDeadline: Duration = .seconds(30)

    /// Where a page's trailers and their checks come from.
    public struct Source: Sendable {
        public var plan: @MainActor () async -> TrailerPlan
        /// Asks YouTube about the video (its id): whether it may be tried in the embedded player, and the shape of its picture.
        public var embedCheck: @MainActor (String) async -> YouTubeEmbedCheck.Answer

        public init(plan: @escaping @MainActor () async -> TrailerPlan,
                    embedCheck: @escaping @MainActor (String) async -> YouTubeEmbedCheck.Answer) {
            self.plan = plan
            self.embedCheck = embedCheck
        }
    }

    public private(set) var phase: Phase = .idle
    /// The player of the trailer that is playing. Nil in every other phase.
    public private(set) var playback: (any TrailerPlayback)?
    /// A YouTube trailer to open in the YouTube app. It is set only when YouTube will not embed the video and nothing else
    /// played: the YouTube app is the fallback for a video the embedded player cannot play. The page opens it and sets this back
    /// to nil.
    public var youTubeHandoff: Trailer?
    /// The shape of the trailer that is playing, width over height. Nil when it is not known, and the panel is then 16:9.
    public private(set) var aspectRatio: Double?
    /// True while the player is full screen: the page is covered then, not left, so it must not close the player.
    @ObservationIgnored public var isFullScreen = false

    /// True while the page shows the trailer's panel: the player, or the line that says it failed. While the trailer loads only the
    /// trailer button's spinner shows, so the page does not open an empty panel first.
    public var showsPanel: Bool {
        switch phase {
        case .playing, .failed: return true
        case .idle, .loading: return false
        }
    }

    public var isPlaying: Bool {
        if case .playing = phase { return true }
        return false
    }

    private let preparer: any TrailerPreparing
    private let durations: TrailerDurations
    private let deadline: Duration
    /// Counts the loads started. A load whose number is no longer the current one has been cancelled, superseded or timed out, and stops.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Gives up the load it was started with when `loadDeadline` has passed. Cancelled once a load ends.
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?

    public init(preparer: any TrailerPreparing) {
        self.preparer = preparer
        self.durations = .shared
        self.deadline = Self.loadDeadline
    }

    init(preparer: any TrailerPreparing, durations: TrailerDurations, deadline: Duration = TrailerLoader.loadDeadline) {
        self.preparer = preparer
        self.durations = durations
        self.deadline = deadline
    }

    /// The trailer button's tap. Idle or failed: loads the trailer (a failed load is tried again). Loading: nothing, since one load runs at
    /// a time. Playing: closes the player.
    public func toggle(_ source: Source) {
        switch phase {
        case .loading: return
        case .playing: close()
        case .idle, .failed: start(source)
        }
    }

    /// Closes the inline player: pauses it and lets the stream go.
    public func close() {
        playback?.stop()
        playback = nil
        aspectRatio = nil
        isFullScreen = false
        if isPlaying { phase = .idle }
    }

    /// The page is left: a load under way is cancelled, the player is closed and an error is cleared.
    public func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        youTubeHandoff = nil
        close()
        phase = .idle
    }

    private func start(_ source: Source) {
        generation += 1
        let run = generation
        phase = .loading
        task = Task { [weak self] in
            await self?.load(source, run: run)
        }
        deadlineTask?.cancel()
        let deadline = self.deadline
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: deadline) } catch { return }
            self?.timeOut(run: run)
        }
    }

    /// The deadline has passed for the load `run`: it is superseded, so it stops, and the page says it took too long. A load that has
    /// already played or failed is left alone.
    private func timeOut(run: Int) {
        guard run == generation, phase == .loading else { return }
        generation += 1
        task?.cancel()
        task = nil
        deadlineTask = nil
        phase = .failed("The trailer took too long to load.")
    }

    /// One load: the trailers in the plan's order, the first that can be prepared is shown. A YouTube video that YouTube will not embed is
    /// skipped, and the first one skipped is handed to the page when nothing else plays. Every check after an `await` stops a load that has
    /// been cancelled, superseded or timed out.
    private func load(_ source: Source, run: Int) async {
        let plan = await source.plan()
        guard run == generation else { return }
        var failure: AddonError?
        /// The first YouTube trailer that may not be embedded. It is opened in the YouTube app when nothing plays here.
        var refused: Trailer?
        var tried = 0
        for trailer in plan.trailers {
            let player: any TrailerPlayback
            /// The shape YouTube gave the video, when it did. A direct file has none.
            var shape: Double?
            do {
                if let videoID = trailer.youtubeID {
                    let answer = await source.embedCheck(videoID)
                    guard run == generation else { return }
                    guard answer.allowsEmbedding else {
                        refused = refused ?? trailer
                        continue
                    }
                    shape = answer.aspectRatio
                    tried += 1
                    player = try await preparer.prepareYouTube(videoID)
                } else if let url = trailer.directURL {
                    tried += 1
                    player = try await preparer.prepare(url)
                } else {
                    continue
                }
            } catch {
                guard run == generation else { return }
                if (error as? TrailerPlaybackError) == .embeddingRefused { refused = refused ?? trailer }
                failure = AddonError.from(error)
                continue
            }
            guard run == generation else {
                player.stop()
                return
            }
            deadlineTask?.cancel()
            deadlineTask = nil
            if let seconds = player.duration { durations.record(seconds, for: trailer.id) }
            player.onFinish = { [weak self] reason in self?.playbackFinished(reason, trailer: trailer, run: run) }
            aspectRatio = player.aspectRatio ?? shape
            playback = player
            phase = .playing(trailer)
            player.play()
            return
        }
        deadlineTask?.cancel()
        deadlineTask = nil
        if let refused {
            phase = .idle
            youTubeHandoff = refused
            return
        }
        phase = .failed(Self.message(for: failure, tried: tried))
    }

    /// A trailer that had started has stopped by itself. At its end the panel closes. A video YouTube refuses to play inside the page is
    /// handed to the page to open in the YouTube app; any other failure says the trailer could not be played.
    private func playbackFinished(_ reason: TrailerPlaybackError?, trailer: Trailer, run: Int) {
        guard run == generation, isPlaying else { return }
        close()
        if reason == .embeddingRefused {
            youTubeHandoff = trailer
        } else if reason != nil {
            phase = .failed("The trailer couldn't be played.")
        }
    }

    /// What a page says when no trailer could be played. `error` is the last failure, and `tried` counts the trailers that were attempted.
    static func message(for error: AddonError?, tried: Int) -> String {
        if error == .offline { return "You're offline. The trailer can't load." }
        if tried == 0 { return "No trailer could be found." }
        return "The trailer couldn't be played."
    }
}
