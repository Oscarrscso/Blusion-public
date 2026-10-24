#if canImport(AVFoundation)
import AVFoundation
import Foundation
import StremioKit
import StremioKitTestSupport
import Testing
@testable import PlayerKit

/// Runs on macOS (CI) against the mock addon's generated media. Not run on the Linux host. These are the first real exercise of AVEngine
/// and of the ADR-005 header route.
@MainActor
@Suite(.serialized) struct AVEngineTests {
    private func media(_ path: String) throws -> URL {
        try MockServer.shared().stream.appendingPathComponent("media/\(path)")
    }

    /// An engine with its sound off, so a test that plays a clip never sounds through the Mac's speakers.
    private func silentEngine() -> AVEngine {
        let engine = AVEngine()
        engine.setMuted(true)
        return engine
    }

    /// Waits until `condition(state)` holds for a state from the engine, or fails the test after `timeout`.
    private func wait(_ engine: AVEngine, timeout: TimeInterval = 30, _ condition: @escaping @Sendable (PlaybackState) -> Bool) async -> PlaybackState? {
        let stream = engine.makeStateStream()
        return await withTaskGroup(of: PlaybackState?.self) { group in
            group.addTask {
                for await state in stream where condition(state) { return state }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @Test(.enabled(if: MockServer.hasMediaFixtures, "needs generated media: run Tools/MockAddon/make-fixtures.sh (ffmpeg)"))
    func playsTheMockMP4AndTheClockAdvances() async throws {
        let engine = silentEngine()
        engine.load(PlaybackItem(url: try media("sample.mp4"), title: "mp4"))
        engine.play()
        let playing = await wait(engine) { $0.status == .playing }
        #expect(playing != nil, "reached .playing")
        let advanced = await wait(engine) { $0.position >= 1.0 }
        #expect(advanced != nil, "position passed 1 s")
        #expect(abs((engine.state.duration ?? 0) - 10) < 0.6, "duration is about 10 s")
        engine.stop()
    }

    @Test(.enabled(if: MockServer.hasMediaFixtures, "needs generated media: run Tools/MockAddon/make-fixtures.sh (ffmpeg)"))
    func seekLandsWithinOneSecond() async throws {
        let engine = silentEngine()
        engine.load(PlaybackItem(url: try media("sample.mp4"), title: "mp4"))
        engine.play()
        _ = await wait(engine) { $0.status == .playing }
        engine.pause()
        await engine.seek(to: 5)
        #expect(abs(engine.state.position - 5) < 1.0)
        engine.stop()
    }

    @Test(.enabled(if: MockServer.hasMediaFixtures, "needs generated media: run Tools/MockAddon/make-fixtures.sh (ffmpeg)"))
    func startPositionIsApplied() async throws {
        let engine = silentEngine()
        engine.load(PlaybackItem(url: try media("sample.mp4"), title: "mp4", startPosition: 4))
        engine.play()
        let state = await wait(engine) { $0.status == .playing && $0.position >= 4 }
        #expect(state != nil)
        engine.stop()
    }

    @Test(.enabled(if: MockServer.hasMediaFixtures, "needs generated media: run Tools/MockAddon/make-fixtures.sh (ffmpeg)"))
    func playsHLS() async throws {
        let engine = silentEngine()
        engine.load(PlaybackItem(url: try media("hls/index.m3u8"), title: "hls"))
        engine.play()
        #expect(await wait(engine) { $0.status == .playing && $0.position >= 1.0 } != nil)
        engine.stop()
    }

    @Test(.enabled(if: MockServer.hasMediaFixtures, "needs generated media: run Tools/MockAddon/make-fixtures.sh (ffmpeg)"))
    func reachesTheEnd() async throws {
        let engine = silentEngine()
        engine.load(PlaybackItem(url: try media("sample.mp4"), title: "mp4", startPosition: 8.5))
        engine.play()
        #expect(await wait(engine) { $0.status == .ended } != nil)
        engine.stop()
    }

    @Test func aMissingFileFails() async throws {
        let engine = silentEngine()
        engine.load(PlaybackItem(url: try media("does-not-exist.mp4"), title: "missing"))
        engine.play()
        let failed = await wait(engine) { $0.failure != nil }
        #expect(failed?.failure != nil)
        #expect(failed?.failure?.message.contains("does-not-exist") == false, "failure text never carries the URL")
        engine.stop()
    }

    @Test(.enabled(if: MockServer.hasMediaFixtures, "needs generated media: run Tools/MockAddon/make-fixtures.sh (ffmpeg)"))
    func aProtectedStreamPlaysOnlyWithItsHeader() async throws {
        let url = try media("protected.mp4")
        let withHeader = silentEngine()
        withHeader.load(PlaybackItem(url: url, headers: ["X-Mock-Token": "abc"], title: "protected"))
        withHeader.play()
        #expect(await wait(withHeader) { $0.status == .playing && $0.position >= 0.5 } != nil, "ADR-005 route B delivers the header")
        withHeader.stop()

        let without = silentEngine()
        without.load(PlaybackItem(url: url, title: "protected"))
        without.play()
        #expect(await wait(without, timeout: 20) { $0.failure != nil } != nil, "without the header the mock answers 403")
        without.stop()
    }
}
#endif
