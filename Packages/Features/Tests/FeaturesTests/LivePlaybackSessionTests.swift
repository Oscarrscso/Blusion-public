import Foundation
import SwiftUI
import Testing
import PlayerKit
import PlayerKitTestSupport
import StremioKit
import StremioKitTestSupport
@testable import Features

/// The app-level playback session: backgrounding keeps it on the air, a dismissal releases it, and a screen rebuilt for the same
/// plan rejoins the session it started instead of beginning a second player.
@MainActor
@Suite struct LivePlaybackSessionTests {
    private let request = StreamRequest(type: "movie", id: "tt1", title: "Movie")

    private func plan(_ id: String = "tt1") -> PlaybackPlan {
        PlaybackPlan(request: request, candidates: [
            PlaybackCandidate(id: id, title: "Stream", addonName: "A", route: .native(URL(string: "https://e.example.com/a.mp4")!))
        ])
    }

    private func services() async throws -> AppServices {
        let transport = StubTransport { request, _ in StubTransport.response(Data(#"{"streams":[]}"#.utf8), for: request) }
        let (registry, client) = try await makeStubbedRegistry(manifests: [], transport: transport)
        return AppServices(registry: registry, client: client, settings: InMemorySettingsStore(), makeEngine: { _ in nil })
    }

    // MARK: holding and releasing

    @Test func presentingPutsTheSessionOnTheBooksAndAForeignOneGoes() async throws {
        let live = LivePlaybackSession()
        let first = PlayerViewModel(plan: plan(), services: try await services())
        let second = PlayerViewModel(plan: plan("tt2"), services: try await services())
        live.present(first)
        #expect(live.model === first)
        live.present(second)
        #expect(live.model === second)
        // The replaced session was released, so it is not handed back again.
        try await Task.sleep(for: .milliseconds(10))
        #expect(await first.isClosed)
        live.forget(second)
        #expect(live.model == nil)
    }

    @Test func aRebuiltScreenRejoinsItsOwnSessionForTheSamePlan() async throws {
        let live = LivePlaybackSession()
        let model = PlayerViewModel(plan: plan(), services: try await services())
        await model.start()
        #expect(model.isSessionLive)
        live.present(model)
        #expect(live.session(for: model.plan) === model)
        // Another plan gets no session; after close, its own plan gets none either.
        #expect(live.session(for: plan("tt2")) == nil)
        await model.close()
        live.forget(model)
        #expect(live.session(for: model.plan) == nil)
    }

    @Test func startingTwiceMakesOneSession() async throws {
        // A screen that reappears (a rebuild, a repeated start) must not begin a second engine for a session already going.
        let made = EngineCounter()
        let transport = StubTransport { request, _ in StubTransport.response(Data(#"{"streams":[]}"#.utf8), for: request) }
        let (registry, client) = try await makeStubbedRegistry(manifests: [], transport: transport)
        let model = PlayerViewModel(plan: plan(), services: AppServices(registry: registry, client: client,
            settings: InMemorySettingsStore(), makeEngine: { _ in
                made.count += 1
                return MockEngine(.plays(duration: 120))
            }))
        await model.start()
        await model.start()
        let count = made.count
        await model.start()
        #expect(made.count == count)
        #expect(model.isPlaying)
        await model.close()
        #expect(!model.isSessionLive)
    }

    // MARK: backgrounding versus dismissal

    @Test func aDisappearanceStopsPlaybackOnlyWhenTheAppIsActive() {
        #expect(LivePlaybackSession.closesOnDisappear(scenePhase: .active))
        // Backgrounding and locking leave the session on the air.
        #expect(!LivePlaybackSession.closesOnDisappear(scenePhase: .background))
        #expect(!LivePlaybackSession.closesOnDisappear(scenePhase: .inactive))
    }
}

/// Counts the engines a session's coordinator made.
@MainActor
final class EngineCounter: @unchecked Sendable {
    var count = 0
}
