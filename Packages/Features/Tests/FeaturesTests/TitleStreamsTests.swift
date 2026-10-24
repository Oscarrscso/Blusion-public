import Foundation
import StremioKit
import Testing
@testable import Features

/// The title page's streams. With Auto Pick on, the stream it starts never shows the list: the spinner stops and the details stay. With it
/// off, or when Auto Pick has nothing to start, the streams take the details' place once ready, as before.
@Suite struct TitleStreamsTests {
    private let movie = StreamRequest(type: "movie", id: "tt1375666", title: "Inception")
    private let episode = StreamRequest(type: "series", id: "tt0903747:2:5", title: "Breaking Bad", season: 2, episode: 5)

    @Test func playSpinsUntilTheStreamsAreReadyThenTheyShow() {
        var streams = TitleStreams()
        streams.show(movie, from: .play)
        #expect(streams.loadingTrigger == .play)
        #expect(streams.loadingRequest == movie)
        #expect(!streams.showsStreams)
        let revealed = streams.reveal()
        #expect(revealed)
        #expect(streams.showsStreams, "Auto Pick off, or nothing to start: the list takes the details' place, as before")
        #expect(streams.loadingTrigger == nil)
        #expect(streams.loadingRequest == nil)
    }

    @Test func theEpisodeSwitcherLoadsTheNextEpisodeInPlaceWithoutTheDetailsComingBack() {
        let next = StreamRequest(type: "series", id: "tt0903747:2:6", title: "Breaking Bad", season: 2, episode: 6)
        var streams = TitleStreams()
        streams.switchEpisode(to: next)
        #expect(streams.request == nil, "with no streams shown there is nothing to switch")
        streams.show(episode, from: .episode)
        streams.switchEpisode(to: next)
        #expect(streams.request == episode, "still loading: the switcher is not on screen yet")
        _ = streams.reveal()
        let before = streams.pickerID
        streams.switchEpisode(to: next)
        #expect(streams.request == next)
        #expect(streams.showsStreams, "the list stays on the page while the episode's streams load")
        #expect(streams.loadingTrigger == nil && streams.loadingRequest == nil, "no control on the page spins")
        #expect(streams.pickerID != before, "the episode gets a picker of its own")
        streams.switchEpisode(to: episode)
        #expect(streams.request == episode && streams.showsStreams, "and back again")
    }

    @Test func aSecondTapWhileTheyLoadCallsThemOff() {
        var streams = TitleStreams()
        streams.show(movie, from: .play)
        streams.show(movie, from: .play)
        #expect(streams.request == nil)
        #expect(streams.loadingTrigger == nil)
    }

    /// With Auto Pick on, the list never appears: once it has started a stream, a later "ready" reveals nothing.
    @Test(arguments: [StreamTrigger.play, .shuffle, .episode])
    func aStreamAutoPickStartedNeverShowsTheList(trigger: StreamTrigger) {
        var streams = TitleStreams()
        streams.show(episode, from: trigger)
        #expect(streams.loadingTrigger == trigger)
        streams.startedAutomatically()
        #expect(streams.loadingTrigger == nil, "the spinner stops")
        #expect(streams.loadingRequest == nil, "the episodes take taps again")
        let revealed = streams.reveal()
        #expect(!revealed)
        #expect(!streams.showsStreams, "the details stay")
    }

    @Test func afterAutoPickStartedAStreamPlayPicksAgain() {
        var streams = TitleStreams()
        streams.show(movie, from: .play)
        let first = streams.pickerID
        streams.startedAutomatically()
        streams.show(movie, from: .play)
        #expect(streams.request == movie, "a tap picks again rather than calling anything off")
        #expect(streams.loadingTrigger == .play)
        #expect(streams.pickerID != first, "with a picker of its own")
        let revealed = streams.reveal()
        #expect(revealed)
        #expect(streams.showsStreams)
    }

    @Test func aContinueWatchingCardOpensThePageAsIfPlayWasTapped() {
        var streams = TitleStreams()
        streams.open(episode)
        #expect(streams.loadingTrigger == .play)
        #expect(streams.loadingRequest == episode)
        streams.startedAutomatically()
        let revealed = streams.reveal()
        #expect(!revealed)
        #expect(!streams.showsStreams)
    }

    @Test func eachItemHasItsOwnPicker() {
        var streams = TitleStreams()
        streams.show(movie, from: .play)
        let movieID = streams.pickerID
        streams.close()
        streams.show(episode, from: .episode)
        #expect(streams.pickerID != movieID)
    }

    @Test func closingShowsTheDetailsAgain() {
        var streams = TitleStreams()
        streams.show(movie, from: .play)
        _ = streams.reveal()
        streams.close()
        #expect(streams.request == nil)
        #expect(!streams.showsStreams)
        #expect(streams.loadingTrigger == nil)
        let revealed = streams.reveal()
        #expect(!revealed)
    }

    @Test func autoPickStartingAfterTheListShowsChangesNothing() {
        var streams = TitleStreams()
        streams.show(movie, from: .play)
        _ = streams.reveal()
        streams.startedAutomatically()
        #expect(streams.showsStreams)
        #expect(!streams.hasStarted)
    }
}
