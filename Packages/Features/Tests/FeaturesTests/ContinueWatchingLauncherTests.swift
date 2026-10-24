import Foundation
import StremioKit
import Testing
@testable import Features

/// A Continue Watching card's tap: with Auto Pick on its streams load on Home with a spinner on that card only; with it off the title's
/// page opens, as before.
@MainActor
@Suite struct ContinueWatchingLauncherTests {
    private let movie = StreamRequest(type: "movie", id: "tt1375666", title: "Inception")
    private let episode = StreamRequest(type: "series", id: "tt0903747:2:5", title: "Breaking Bad", season: 2, episode: 5)

    private func launcher(autoPick: Bool) -> ContinueWatchingLauncher {
        ContinueWatchingLauncher(autoPickIsOn: { autoPick })
    }

    private func open(_ launcher: ContinueWatchingLauncher, _ request: StreamRequest) async -> ContinueWatchingLauncher.Route? {
        await launcher.open(itemID: request.identity, request: request, preview: MetaPreview(id: request.id, type: request.type),
                            sourceID: "continue//\(request.id)")
    }

    @Test func withAutoPickOnTheStreamsLoadOnHome() async throws {
        let launcher = launcher(autoPick: true)
        #expect(await open(launcher, episode) == .resolveHere)
        let launch = try #require(launcher.launch)
        #expect(launch.request == episode, "exactly the item Continue Watching resumes")
        #expect(launcher.isResolving)
    }

    @Test func withAutoPickOffTheTitlesPageOpensAsBefore() async {
        let launcher = launcher(autoPick: false)
        #expect(await open(launcher, movie) == .openTitle)
        #expect(launcher.launch == nil, "nothing loads on Home")
        #expect(!launcher.isResolving)
        #expect(!launcher.isLoading(movie.identity))
    }

    /// The switch is changed away from Home. The choice is read once and kept, so a tap does not wait on the settings, and read again
    /// when Home shows.
    @Test func theSavedChoiceIsReadAgainWhenHomeShows() async {
        let saved = Saved()
        let launcher = ContinueWatchingLauncher(autoPickIsOn: { saved.read() })
        #expect(await open(launcher, movie) == .openTitle)
        saved.autoPick = true
        await launcher.refreshAutoPick()
        #expect(await open(launcher, movie) == .resolveHere)
        #expect(saved.reads == 2, "read on the first tap and when Home showed, not on every tap")
    }

    @Test func onlyTheTappedCardSpins() async {
        let launcher = launcher(autoPick: true)
        _ = await open(launcher, movie)
        #expect(launcher.isLoading(movie.identity))
        #expect(!launcher.isLoading(episode.identity), "the other cards look as they did")
    }

    @Test func otherTapsAreIgnoredWhileTheStreamsLoad() async throws {
        let launcher = launcher(autoPick: true)
        _ = await open(launcher, movie)
        let first = try #require(launcher.launch)
        #expect(await open(launcher, episode) == nil)
        #expect(await open(launcher, movie) == nil, "nor does a second tap on the same card start it again")
        #expect(launcher.launch?.id == first.id)
    }

    @Test func aTapWhileAnotherIsBeingRoutedIsIgnored() async {
        let gate = Gate()
        let launcher = ContinueWatchingLauncher(autoPickIsOn: {
            await gate.wait()
            return false
        })
        let first = Task { await open(launcher, movie) }
        while !gate.isWaiting { await Task.yield() }
        #expect(await open(launcher, episode) == nil, "one title page opens, not two")
        gate.open()
        #expect(await first.value == .openTitle)
    }

    @Test func aStartedStreamStopsTheSpinnerAndKeepsItsPicker() async throws {
        let launcher = launcher(autoPick: true)
        _ = await open(launcher, movie)
        let launch = try #require(launcher.launch)
        #expect(!launcher.finish(launch.id, started: true), "the title's page does not open")
        #expect(!launcher.isResolving)
        #expect(!launcher.isLoading(movie.identity))
        #expect(launcher.launch?.id == launch.id, "the player it opened belongs to it")
        launcher.cancel()
        #expect(launcher.launch?.id == launch.id, "leaving Home for the player does not close it")
        #expect(await open(launcher, episode) == .resolveHere, "the cards take taps again")
        #expect(launcher.launch?.request == episode)
    }

    @Test func whenNothingCanStartTheTitlesPageOpensWithTheStreams() async throws {
        let launcher = launcher(autoPick: true)
        _ = await open(launcher, movie)
        let launch = try #require(launcher.launch)
        #expect(launcher.finish(launch.id, started: false))
        #expect(launcher.launch == nil)
        #expect(!launcher.isResolving)
    }

    @Test func leavingHomeCallsTheLoadOff() async throws {
        let launcher = launcher(autoPick: true)
        _ = await open(launcher, movie)
        let launch = try #require(launcher.launch)
        launcher.cancel()
        #expect(launcher.launch == nil)
        #expect(!launcher.isResolving)
        #expect(!launcher.finish(launch.id, started: true), "a picker called off reports nothing")
        #expect(!launcher.finish(launch.id, started: false), "and opens no page")
    }

    @Test func aReportFromAnEarlierCardChangesNothing() async throws {
        let launcher = launcher(autoPick: true)
        _ = await open(launcher, movie)
        let earlier = try #require(launcher.launch)
        _ = launcher.finish(earlier.id, started: true)
        _ = await open(launcher, episode)
        let current = try #require(launcher.launch)
        #expect(!launcher.finish(earlier.id, started: false))
        #expect(launcher.isLoading(episode.identity))
        #expect(launcher.launch?.id == current.id)
    }
}

/// Holds the saved Auto Pick choice back until the test lets it answer.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

/// The saved Auto Pick choice, counting how often it is read.
@MainActor
private final class Saved {
    var autoPick = false
    private(set) var reads = 0

    func read() -> Bool {
        reads += 1
        return autoPick
    }
}
