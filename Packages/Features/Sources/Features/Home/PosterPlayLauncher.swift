import Foundation
import Observation
import StremioKit

/// Holding a poster for a second plays it: the poster spins while its streams load in a picker that draws nothing, and the stream Play
/// would choose starts at once, in Infuse or here, while the finger is still down. A movie plays itself; a series plays the episode its
/// page's Play button would. Letting go before a stream has started calls everything off, and nothing opens. When nothing can be played,
/// the spinner stops and `failed` runs (an error haptic). One poster at a time.
@MainActor
@Observable
public final class PosterPlayLauncher {
    /// The streams loading, or started, for a held poster.
    struct Launch: Identifiable, Equatable {
        let id = UUID()
        let identity: String
        let request: StreamRequest
        let preview: MetaPreview
    }

    /// The poster held whose stream has not started yet: only it spins.
    private(set) var holding: String?
    /// The poster under a press that became a hold, until a moment after the finger lifts, so the lift is not also taken for a tap. Read only
    /// as a tap ends, never by a view's body, so it redraws nothing.
    @ObservationIgnored private(set) var heldPress: String?
    @ObservationIgnored private var heldPressRelease: Task<Void, Never>?
    /// The streams loading for the held poster. Kept once a stream has started: the player it opened belongs to the picker that loaded
    /// it, so that picker stays until the next hold.
    private(set) var launch: Launch?
    @ObservationIgnored private var resolving: Task<Void, Never>?
    /// What a held poster plays: a movie itself, or a series' next episode. Nil when there is nothing to play.
    @ObservationIgnored private let nextRequest: @MainActor (MetaPreview) async -> StreamRequest?
    /// Runs when a hold found nothing to play.
    @ObservationIgnored private let failed: @MainActor () -> Void

    init(nextRequest: @escaping @MainActor (MetaPreview) async -> StreamRequest?, failed: @escaping @MainActor () -> Void = {}) {
        self.nextRequest = nextRequest
        self.failed = failed
    }

    /// A launcher whose series take the episode their page's Play button would.
    public convenience init(services: AppServices, failed: @escaping @MainActor () -> Void = {}) {
        self.init(nextRequest: { item in await Self.request(for: item, services: services) }, failed: failed)
    }

    /// True for the poster whose streams are being found. The same title in two rows spins in both.
    func isLoading(_ item: MetaPreview) -> Bool { holding == item.identity }

    /// True while the press on `item` is a hold, and for a moment after it lifts: a tap the lift ends is the hold's, not a tap.
    func isHeldPress(_ item: MetaPreview) -> Bool { heldPress == item.identity }

    /// The press on `item` has been held for a second.
    func pressBecameHold(_ item: MetaPreview) {
        heldPressRelease?.cancel()
        heldPress = item.identity
    }

    /// The finger held on `item` lifted. The press stays a hold for a moment, since a tap the lift ends may come just after.
    func holdLifted(_ item: MetaPreview) {
        guard heldPress == item.identity else { return }
        heldPressRelease?.cancel()
        heldPressRelease = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.heldPress == item.identity else { return }
            self.heldPress = nil
        }
    }

    /// The poster has been held for a second: its streams start loading. A hold while another poster's streams load is ignored.
    func begin(_ item: MetaPreview) {
        guard holding == nil else { return }
        reset()
        holding = item.identity
        resolving = Task { [weak self] in
            guard let self else { return }
            let request = await self.nextRequest(item)
            guard !Task.isCancelled, self.holding == item.identity else { return }
            guard let request else {
                self.fail()
                return
            }
            self.launch = Launch(identity: item.identity, request: request, preview: item)
        }
    }

    /// The finger lifted, or the hold was called off. Before a stream has started, the load stops and nothing opens; after, nothing changes.
    func end(_ item: MetaPreview) {
        guard holding == item.identity else { return }
        reset()
    }

    /// The picker for `id` started a stream (`started`), or had nothing it could start. A launch that is no longer current changes nothing.
    func finish(_ id: UUID, started: Bool) {
        guard launch?.id == id, holding != nil else { return }
        if started {
            holding = nil
        } else {
            fail()
        }
    }

    private func fail() {
        reset()
        failed()
    }

    private func reset() {
        resolving?.cancel()
        resolving = nil
        holding = nil
        launch = nil
    }

    /// What holding `item` plays: exactly what its page's Play would. The title is looked up under its IMDb id first when a catalog lists
    /// it under its TMDb number, as its page is; then a movie plays itself, with its details' runtime for the ranking, and a series its next
    /// aired episode, picked from the episodes and what has been watched. Nil for a series with nothing aired to play.
    static func request(for item: MetaPreview, services: AppServices) async -> StreamRequest? {
        let preview = await TMDbPreviewResolver.resolve(item, services: services)
        guard !Task.isCancelled else { return nil }
        let page = DetailViewModel(preview: preview, services: services)
        await page.loadForPlayback()
        guard !Task.isCancelled else { return nil }
        return page.primaryRequest
    }
}
