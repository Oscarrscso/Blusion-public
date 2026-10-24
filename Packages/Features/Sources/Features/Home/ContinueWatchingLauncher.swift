import Foundation
import Observation
import StremioKit

/// What a tap on a Continue Watching card does. With Auto Pick on, the card's streams load on Home, with a spinner on that card only, and
/// the stream Auto Pick chooses starts as Play's does; the title's page does not open. With Auto Pick off, the card opens the title's page
/// with its streams, as before. When Auto Pick starts nothing, the title's page opens with the streams, as Play leaves them then.
@MainActor
@Observable
final class ContinueWatchingLauncher {
    enum Route: Equatable {
        /// The streams load here, on Home, and the tapped card spins.
        case resolveHere
        /// The title's page opens with the streams, as it does without Auto Pick.
        case openTitle
    }

    /// The card whose streams are loading or have started on Home, and what they are for.
    struct Launch: Identifiable, Equatable {
        let id = UUID()
        let itemID: String
        let request: StreamRequest
        let preview: MetaPreview
        let sourceID: String
    }

    /// The streams loading or started for a card. Kept once a stream has started: the player it opened, or an alert about it, belongs to
    /// the picker that loaded them, so that picker stays until the next card is tapped.
    private(set) var launch: Launch?
    /// True from the tap until a stream starts, the title's page opens, or Home is left. Other cards take no taps meanwhile.
    private(set) var isResolving = false
    /// True while a tap waits for the saved Auto Pick choice, so a second tap does not open a second page.
    private var isChecking = false
    /// The saved Auto Pick choice as last read. Home reads it again each time it shows (`refreshAutoPick`), so a tap does not wait on
    /// reading the settings; only a tap before the first read does.
    private var savedAutoPick: Bool?
    /// Reads the saved Auto Pick choice: the switch beside Auto Pick in the streams.
    private let autoPickIsOn: @MainActor () async -> Bool

    init(autoPickIsOn: @escaping @MainActor () async -> Bool) {
        self.autoPickIsOn = autoPickIsOn
    }

    /// Reads the saved Auto Pick choice again. The switch is changed away from Home, so Home calls this as it shows.
    func refreshAutoPick() async {
        savedAutoPick = await autoPickIsOn()
    }

    /// True for the card whose streams are loading: only that card spins.
    func isLoading(_ itemID: String) -> Bool {
        isResolving && launch?.itemID == itemID
    }

    /// A tap on a card. Nil while a card's streams are loading, or while an earlier tap is still being routed: the tap is ignored.
    func open(itemID: String, request: StreamRequest, preview: MetaPreview, sourceID: String) async -> Route? {
        guard !isResolving, !isChecking else { return nil }
        let autoPick: Bool
        if let savedAutoPick {
            autoPick = savedAutoPick
        } else {
            isChecking = true
            defer { isChecking = false }
            autoPick = await autoPickIsOn()
            savedAutoPick = autoPick
        }
        guard autoPick else { return .openTitle }
        launch = Launch(itemID: itemID, request: request, preview: preview, sourceID: sourceID)
        isResolving = true
        return .resolveHere
    }

    /// The picker for `id` started a stream (`started`), or had nothing to start. True when the title's page should now open with the
    /// streams. A launch that is no longer current, because Home was left or another card was tapped, changes nothing.
    func finish(_ id: UUID, started: Bool) -> Bool {
        guard isResolving, launch?.id == id else { return false }
        isResolving = false
        if !started { launch = nil }
        return !started
    }

    /// Home was left while a card's streams were loading: they are called off, and nothing starts.
    func cancel() {
        guard isResolving else { return }
        isResolving = false
        launch = nil
    }
}
