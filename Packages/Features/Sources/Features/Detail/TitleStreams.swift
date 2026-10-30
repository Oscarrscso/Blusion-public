import Foundation
import StremioKit

/// What asked for a title's streams on its page: Play, Shuffle or an episode's card. Only that control shows a spinner while they load,
/// and the others take no taps until they are ready.
enum StreamTrigger: Equatable {
    case play, shuffle, episode
}

/// The streams a title's page has picked: the item, what asked for it, and whether they have taken the details' place. With Auto Pick on,
/// the stream it chooses starts without the streams ever being shown; the spinner stops, the details stay, and the next tap picks again.
struct TitleStreams: Equatable {
    /// The item whose streams are on the page, loading or shown. Nil shows the details.
    private(set) var request: StreamRequest?
    /// What asked for them: only that control spins while they load.
    private(set) var trigger: StreamTrigger?
    /// True once the addons have all answered (and Auto Pick, when on, had nothing to start): the streams take the details' place.
    private(set) var isReady = false
    /// True once Auto Pick has started a stream from them. They are never shown then, nothing spins, and every control takes taps again.
    private(set) var hasStarted = false
    /// Counts the picks made after a stream started, so each gets a picker of its own.
    private var restarts = 0

    /// True once the streams have taken the details' place.
    var showsStreams: Bool { request != nil && isReady }

    /// What asked for the streams that are still loading, or nil when none are.
    var loadingTrigger: StreamTrigger? { request != nil && !isReady && !hasStarted ? trigger : nil }

    /// The item whose streams are still loading, or nil when none are.
    var loadingRequest: StreamRequest? { isReady || hasStarted ? nil : request }

    /// Tells the page's stream pickers apart: a new item, or a pick made after a stream started, gets a new one.
    var pickerID: String { "\(request?.id ?? "-")|\(restarts)" }

    /// Play, Shuffle or an episode's card was tapped. Its streams load, with a spinner on that control only; a second tap while they load
    /// calls them off. After Auto Pick has started a stream, a tap picks again.
    mutating func show(_ request: StreamRequest, from trigger: StreamTrigger) {
        isReady = false
        if hasStarted {
            hasStarted = false
            restarts += 1
            self.request = request
            self.trigger = trigger
            return
        }
        self.request = self.request == nil ? request : nil
        self.trigger = self.request == nil ? nil : trigger
    }

    /// The streams' episode switcher moved to another episode: its streams load in place of these, as its card would load them. The list
    /// stays on the page with its loading state, so the details do not come back while they load, and nothing else spins. Nothing
    /// happens while no streams are shown.
    mutating func switchEpisode(to request: StreamRequest) {
        guard showsStreams else { return }
        self.request = request
        trigger = .episode
        hasStarted = false
    }

    /// A Continue Watching card opened the page on this item: as if Play had been tapped, so Play spins.
    mutating func open(_ request: StreamRequest) {
        if self.request != nil { restarts += 1 }
        self.request = request
        trigger = .play
        isReady = false
        hasStarted = false
    }

    /// The streams are ready to show. False when there is nothing to reveal: none are picked, they already show, or Auto Pick started a
    /// stream from them.
    mutating func reveal() -> Bool {
        guard request != nil, !isReady, !hasStarted else { return false }
        isReady = true
        return true
    }

    /// Auto Pick started a stream from the picked streams: the spinner stops and the details stay.
    mutating func startedAutomatically() {
        guard request != nil, !isReady else { return }
        hasStarted = true
    }

    /// Takes the streams away and shows the details again.
    mutating func close() {
        request = nil
        trigger = nil
        isReady = false
        hasStarted = false
    }
}
