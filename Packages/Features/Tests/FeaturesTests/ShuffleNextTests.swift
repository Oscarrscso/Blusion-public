import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import Features

/// Shuffle picks its episode ahead: the first one's streams are looked up as the page opens, and the button names the next one.
@MainActor
@Suite struct ShuffleNextTests {
    private func series(_ videos: String, id: String = "tt7100001") async throws -> (DetailViewModel, StubTransport) {
        let json = #"{"meta":{"id":"\#(id)","type":"series","name":"Show","videos":[\#(videos)]}}"#
        let streams = #"{"streams":[{"name":"A","url":"https://a.example.com/1.mp4"}]}"#
        let transport = StubTransport { request, _ in
            let body = request.url?.path.contains("/stream/") == true ? streams : json
            return StubTransport.response(Data(body.utf8), for: request)
        }
        let manifest = Manifest(id: "test.shuffle", name: "Stub", version: "1",
                                resources: [ResourceDescriptor(name: "meta"), ResourceDescriptor(name: "stream")], types: ["series"])
        let (registry, client) = try await makeStubbedRegistry(manifests: [manifest], transport: transport)
        let model = DetailViewModel(preview: MetaPreview(id: id, type: "series", name: "Show"), services: AppServices(registry: registry, client: client))
        await model.load()
        return (model, transport)
    }

    private func episode(_ number: Int, aired: Bool = true) -> String {
        let date = aired ? "2001-01-01T00:00:00.000Z" : "2999-01-01T00:00:00.000Z"
        return #"{"id":"tt7100001:1:\#(number)","title":"Episode \#(number)","season":1,"episode":\#(number),"released":"\#(date)"}"#
    }

    @Test func theFirstShuffleIsTheEpisodePickedAheadAndItsStreamsAreLookedUp() async throws {
        let (model, transport) = try await series((1...6).map { episode($0) }.joined(separator: ","))
        model.prepareShuffle()
        let ahead = try #require(model.shuffleNext)
        try await waitUntil { transport.requests.contains { $0.url?.path.contains("/stream/") == true } }
        #expect(transport.requests.contains { $0.url?.path.contains(ahead.id) == true }, "its streams were asked for ahead")
        let first = model.takeShuffle()
        #expect(first?.id == ahead.id, "the first tap plays the episode named beside the button")
        let next = try #require(model.shuffleNext)
        #expect(next.id != ahead.id, "the next one is a different episode, named at once")
    }

    @Test func picksAreOnlyEpisodesThatHaveAired() async throws {
        let (model, _) = try await series([episode(1), episode(2, aired: false)].joined(separator: ","))
        model.prepareShuffle()
        for _ in 0..<10 {
            #expect(model.takeShuffle()?.id == "tt7100001:1:1")
        }
        #expect(model.shuffleNext?.id == "tt7100001:1:1", "with one aired episode, it is the next one too")
    }

    @Test func preparingTwiceLooksUpOnce() async throws {
        let (model, transport) = try await series((1...4).map { episode($0) }.joined(separator: ","))
        model.prepareShuffle()
        let first = model.shuffleNext
        model.prepareShuffle()
        #expect(model.shuffleNext == first)
        try await waitUntil { transport.requests.contains { $0.url?.path.contains("/stream/") == true } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.requests.filter { $0.url?.path.contains("/stream/") == true }.count == 1)
    }

    @Test func comingBackLooksTheSameEpisodeUpAgainUntilShuffleIsTapped() async throws {
        let (model, transport) = try await series((1...4).map { episode($0) }.joined(separator: ","))
        model.prepareShuffle()
        let ahead = try #require(model.shuffleNext)
        model.releaseStreamPrefetch()
        model.prepareShuffle()
        #expect(model.shuffleNext?.id == ahead.id, "the same episode, still named")
        try await waitUntil { transport.requests.contains { $0.url?.path.contains(ahead.id) == true } }
        _ = model.takeShuffle()
        model.releaseStreamPrefetch()
        let count = transport.requests.count
        model.prepareShuffle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.requests.count == count, "after a tap, later picks load as Play does")
    }
}
