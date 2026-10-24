import Foundation
import PlayerKit
import StremioKit
import StremioKitTestSupport
import Testing
@testable import Features

@MainActor
@Suite struct PlaybackHandoffCenterTests {
    private let film = StreamRequest(type: "movie", id: "tt1", title: "Film", expectedDuration: 7200)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func services(progress: [WatchProgress] = []) -> AppServices {
        let client = makeClient(StubTransport(data: Data()))
        let registry = AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client)
        return AppServices(registry: registry, client: client, progress: InMemoryProgressStore(progress))
    }

    private func center(_ services: AppServices) -> PlaybackHandoffCenter {
        let fixed = now
        return PlaybackHandoffCenter(services: services, now: { fixed })
    }

    /// What the picker stores when it hands a stream to Infuse.
    private func handOff(_ request: StreamRequest, token: String = "tok", in services: AppServices) async {
        await services.handoffs.save(PlaybackHandoff(id: token, request: request, player: .infuse, startedAt: now))
    }

    private func callback(_ text: String) throws -> URL { try #require(URL(string: text)) }

    @Test func aFinishedCallbackRecordsWhereTheViewerStopped() async throws {
        let services = services()
        await handOff(film, in: services)
        let handled = await center(services).handle(try callback("blusion://x-callback-url/handoff/tok/finished?position=1234"))
        #expect(handled)
        let saved = await services.progress.progress(for: "movie/tt1")
        #expect(saved?.position == 1234 && saved?.duration == 7200 && saved?.isWatched == false)
        #expect(saved?.title == "Film" && saved?.contentID == "tt1" && saved?.updatedAt == now)
        #expect(ProgressRecorder.resumePosition(for: saved) == 1234, "the next play resumes there")
    }

    @Test func aStopNearTheEndMarksTheTitleWatched() async throws {
        let services = services()
        await handOff(film, in: services)
        _ = await center(services).handle(try callback("blusion://x-callback-url/handoff/tok/finished?position=6480"))
        let saved = await services.progress.progress(for: "movie/tt1")
        #expect(saved?.isWatched == true, "90% is the watched threshold")
    }

    @Test func aTitleWithAnUnknownLengthKeepsItsPositionButCannotBeWatched() async throws {
        let services = services()
        let unknown = StreamRequest(type: "movie", id: "tt2", title: "Unknown")
        await handOff(unknown, in: services)
        _ = await center(services).handle(try callback("blusion://x-callback-url/handoff/tok/finished?position=500"))
        let saved = await services.progress.progress(for: "movie/tt2")
        #expect(saved?.position == 500 && saved?.duration == 0 && saved?.isWatched == false)
    }

    @Test func anUnknownLengthUsesTheLengthAnEarlierSessionMeasured() async throws {
        let earlier = WatchProgress(id: "movie/tt2", type: "movie", contentID: "tt2", title: "Unknown", position: 100, duration: 5400,
                                    isWatched: false, updatedAt: now)
        let services = services(progress: [earlier])
        await handOff(StreamRequest(type: "movie", id: "tt2", title: "Unknown"), in: services)
        _ = await center(services).handle(try callback("blusion://x-callback-url/handoff/tok/finished?position=5000"))
        let saved = await services.progress.progress(for: "movie/tt2")
        #expect(saved?.duration == 5400 && saved?.isWatched == true, "5000 of 5400 seconds is past the threshold")
    }

    @Test func aWatchedMarkSurvivesAStopEarlierInTheTitle() async throws {
        let watched = WatchProgress(id: "movie/tt1", type: "movie", contentID: "tt1", title: "Film", position: 7000, duration: 7200,
                                    isWatched: true, updatedAt: now)
        let services = services(progress: [watched])
        await handOff(film, in: services)
        _ = await center(services).handle(try callback("blusion://x-callback-url/handoff/tok/finished?position=100"))
        let saved = await services.progress.progress(for: "movie/tt1")
        #expect(saved?.isWatched == true && saved?.position == 100)
    }

    @Test func aFinishWithoutAPositionOrWithANegativeOneSavesNothing() async throws {
        let services = services()
        await handOff(film, token: "a", in: services)
        await handOff(film, token: "b", in: services)
        let handler = center(services)
        let missing = await handler.handle(try callback("blusion://x-callback-url/handoff/a/finished"))
        let negative = await handler.handle(try callback("blusion://x-callback-url/handoff/b/finished?position=-4"))
        #expect(missing && negative)
        let saved = await services.progress.progress(for: "movie/tt1")
        #expect(saved == nil)
    }

    @Test func aFailureSavesNothing() async throws {
        let services = services()
        await handOff(film, in: services)
        let failure = try callback("blusion://x-callback-url/handoff/tok/failed?errorCode=404&errorMessage=Not%20found")
        let handled = await center(services).handle(failure)
        #expect(handled)
        let saved = await services.progress.progress(for: "movie/tt1")
        #expect(saved == nil)
    }

    @Test func aTokenBlusionDoesNotKnowIsStillOursAndSavesNothing() async throws {
        let services = services()
        let handled = await center(services).handle(try callback("blusion://x-callback-url/handoff/unknown/finished?position=900"))
        #expect(handled)
        let all = await services.progress.all()
        #expect(all.isEmpty)
    }

    @Test func anotherURLIsNotOursAndLeavesTheHandOffAlone() async throws {
        let services = services()
        await handOff(film, in: services)
        let handled = await center(services).handle(try callback("https://example.com/handoff/tok/finished?position=900"))
        #expect(!handled, "the caller may try other handlers")
        let stillWaiting = await services.handoffs.take(id: "tok")
        #expect(stillWaiting != nil)
    }

    @Test func aHandOffIsRemovedOnceItIsHandled() async throws {
        let services = services()
        await handOff(film, in: services)
        let handler = center(services)
        _ = await handler.handle(try callback("blusion://x-callback-url/handoff/tok/finished?position=100"))
        let remaining = await services.handoffs.take(id: "tok")
        #expect(remaining == nil)
        // A repeated callback records nothing new.
        await services.progress.remove("movie/tt1")
        _ = await handler.handle(try callback("blusion://x-callback-url/handoff/tok/finished?position=100"))
        let repeated = await services.progress.progress(for: "movie/tt1")
        #expect(repeated == nil)
    }

    @Test func aTitleOfUnknownLengthShowsInContinueWatching() async throws {
        let services = services()
        await handOff(StreamRequest(type: "movie", id: "tt3", title: "Stopped"), token: "t3", in: services)
        _ = await center(services).handle(try callback("blusion://x-callback-url/handoff/t3/finished?position=300"))
        let items = LibraryViewModel.continueWatching(from: await services.progress.all())
        #expect(items.map(\.contentID) == ["tt3"], "a zero-length item resumes where it stopped, so it is worth showing")
    }

    @Test func savingABookmarkCannotWriteWatchProgress() async throws {
        let services = services()
        await services.handoffs.save(PlaybackHandoff(id: "saved", request: film, player: .infuse, startedAt: now, action: .save))
        _ = await center(services).handle(try callback("blusion://x-callback-url/handoff/saved/finished?position=7000"))
        #expect(await services.progress.progress(for: film.identity) == nil)
    }

    @Test func aLateCallbackCannotOverwriteNewerProgress() async throws {
        let newer = WatchProgress(id: film.identity, type: film.type, contentID: film.id, title: film.title,
                                  position: 3000, duration: 7200, isWatched: false, updatedAt: now.addingTimeInterval(1))
        let services = services(progress: [newer])
        await handOff(film, in: services)
        _ = await center(services).handle(try callback("blusion://x-callback-url/handoff/tok/finished?position=1000"))
        #expect(await services.progress.progress(for: film.identity) == newer)
    }

    @Test func aKnownRuntimeTakesPrecedenceOverAnAddonEstimate() async throws {
        let measured = WatchProgress(id: film.identity, type: film.type, contentID: film.id, title: film.title,
                                     position: 100, duration: 5400, isWatched: false, updatedAt: now)
        let services = services(progress: [measured])
        await handOff(film, in: services)
        _ = await center(services).handle(try callback("blusion://x-callback-url/handoff/tok/finished?position=5000"))
        let saved = await services.progress.progress(for: film.identity)
        #expect(saved?.duration == 5400 && saved?.isWatched == true)
    }
}
