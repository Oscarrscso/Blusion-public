import Foundation
import Testing
import StremioKit
import PlayerKitTestSupport
@testable import PlayerKit

/// PLAN M8 leak pass (host half) for the playback stack: coordinator, engines, progress session.
@MainActor
@Suite struct LeakTests {
    #if canImport(AVFoundation)
    @Test func anInvalidatedHeaderLoaderReleasesItsSessionAndDelegate() async throws {
        weak var reference: HeaderResourceLoader?
        autoreleasepool {
            let loader = HeaderResourceLoader(headers: ["User-Agent": "test"])
            reference = loader
            loader.invalidate()
        }
        try await waitUntil { reference == nil }
    }
    #endif
    private let request = StreamRequest(type: "movie", id: "tt1", title: "Movie")

    private func candidate(_ name: String) -> PlaybackCandidate {
        PlaybackCandidate(id: name, title: name, addonName: "A", route: .native(URL(string: "https://e.example.com/\(name).mp4")!))
    }

    @Test func aStoppedCoordinatorAndItsEnginesAreReleased() async throws {
        let leaked = try await survivors { () async throws -> [(String, AnyObject)] in
            var engines: [(String, AnyObject)] = []
            let store = InMemoryProgressStore()
            let session = ProgressSession(request: request, previous: nil, store: store)
            let plan = PlaybackPlan(request: request, candidates: [candidate("a"), candidate("b")])
            let coordinator = PlaybackCoordinator(plan: plan, startupTimeout: .seconds(2), progress: session, makeEngine: { candidate in
                let engine = MockEngine(candidate.id == "a" ? .failsToLoad(PlaybackFailure(.network, "boom")) : .plays(duration: 30))
                engines.append(("MockEngine \(candidate.id)", engine))
                return engine
            })
            await coordinator.start()
            #expect(coordinator.phase == .playing, "failed over from a to b")
            await coordinator.stop()
            return engines + [("PlaybackCoordinator", coordinator), ("ProgressSession", session)]
        }
        #expect(leaked.isEmpty, "still alive: \(leaked)")
    }

    @Test func aFallbackEngineAndItsBackendAreReleasedAfterStop() async throws {
        let leaked = try await survivors { () async throws -> [(String, AnyObject)] in
            let backend = MockBackend()
            let engine = FallbackEngine(backend: backend)
            engine.load(PlaybackItem(url: URL(string: "https://e.example.com/m.mkv")!, title: "MKV"))
            engine.play()
            try await waitUntil { engine.state.status == .playing }
            engine.stop()
            return [("FallbackEngine", engine), ("MockBackend", backend)]
        }
        #expect(leaked.isEmpty, "still alive: \(leaked)")
    }

    @Test func aStateStreamDoesNotKeepItsEngineAlive() async throws {
        let leaked = try await survivors { () async throws -> [(String, AnyObject)] in
            let engine = MockEngine(.plays(duration: 10))
            let listening = Task { for await _ in engine.makeStateStream() {} }
            engine.load(PlaybackItem(url: URL(string: "https://e.example.com/a.mp4")!, title: "A"))
            try await waitUntil { engine.state.status == .ready }
            engine.stop()
            listening.cancel()
            await listening.value
            return [("MockEngine", engine)]
        }
        #expect(leaked.isEmpty, "still alive: \(leaked)")
    }
}
