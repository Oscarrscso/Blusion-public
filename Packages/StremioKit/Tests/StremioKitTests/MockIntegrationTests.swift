import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

/// PLAN M2 acceptance, against the local mock addon over real HTTP.
@Suite struct MockIntegrationTests {
    let token = "tok_SECRET_9f3a1c"

    private func server() throws -> MockServer { try MockServer.shared() }

    private func client(_ server: MockServer, timeout: TimeInterval? = nil, sink: MemoryLogSink? = nil) -> AddonClient {
        AddonClient(configuration: AddonClientConfiguration(timeout: timeout ?? (server.slowDelay + 4), maxRetries: 2, retryBackoff: 0.05),
                    logger: sink.map { AddonLogger(sink: $0) } ?? .silent)
    }

    private func topCatalog(_ client: AddonClient, _ addon: InstalledAddon) async throws -> [MetaPreview] {
        try await client.catalog(base: addon.baseURL, type: "movie", id: "mock-top")
    }

    // MARK: isolation

    @Test func aSlowAddonDoesNotDelayAFastOne() async throws {
        let server = try server()
        let client = client(server)
        let fast = TestAddons.catalogAddon(base: server.catalogBase(), name: "Fast")
        let slow = TestAddons.catalogAddon(base: server.catalogBase(flags: ["slow"]), name: "Slow")
        let started = Date()
        var arrivals: [(name: String, at: TimeInterval, ok: Bool)] = []
        for await response in FanOut.run(over: [slow, fast], operation: { try await topCatalog(client, $0) }) {
            arrivals.append((response.addon.name, elapsed(since: started), response.value != nil))
        }
        #expect(arrivals.map(\.name) == ["Fast", "Slow"], "the fast addon answers first even though it was listed second")
        #expect(arrivals[0].at < server.slowDelay * 0.6, "fast answered in \(arrivals[0].at)s")
        #expect(arrivals[1].at >= server.slowDelay * 0.9)
        #expect(arrivals.allSatisfy { $0.ok })
    }

    @Test func aTimedOutAddonFailsAloneAndInTime() async throws {
        let server = try server()
        let client = client(server, timeout: server.slowDelay / 3)
        let fast = TestAddons.catalogAddon(base: server.catalogBase(), name: "Fast")
        let slow = TestAddons.catalogAddon(base: server.catalogBase(flags: ["slow"]), name: "Slow")
        let started = Date()
        let responses = await FanOut.run(over: [slow, fast], operation: { try await topCatalog(client, $0) }).collect()
        #expect(responses.count == 2)
        #expect(responses.first { $0.addon.name == "Fast" }?.value?.count == 4)
        #expect(responses.first { $0.addon.name == "Slow" }?.error == .timeout)
        #expect(elapsed(since: started) < server.slowDelay, "the fan-out finished at the deadline, not when the slow addon did")
    }

    @Test func failuresStayIsolatedToTheirAddon() async throws {
        let server = try server()
        let client = client(server)
        let cases: [(flag: String, expected: AddonError)] = [
            ("err500", .http(status: 500)),
            ("badjson", .invalidJSON),
            ("big", .responseTooLarge(limit: AddonClientConfiguration.default.maxBytes)),
            ("redirectloop", .tooManyRedirects),
        ]
        var addons = [TestAddons.catalogAddon(base: server.catalogBase(), name: "Healthy")]
        for (flag, _) in cases { addons.append(TestAddons.catalogAddon(base: server.catalogBase(flags: [flag]), name: flag)) }
        let responses = await FanOut.run(over: addons, operation: { try await topCatalog(client, $0) }).collect()
        #expect(responses.count == addons.count)
        #expect(responses.first { $0.addon.name == "Healthy" }?.value?.map(\.id) == ["mock:movie1", "mock:movie2", "mock:movie3", "mock:nometa1"],
                "the healthy addon is unaffected, and the item without an id is dropped")
        for (flag, expected) in cases {
            #expect(responses.first { $0.addon.name == flag }?.error == expected, "\(flag)")
        }
    }

    @Test func redirectsAreFollowedToTheRealResource() async throws {
        let server = try server()
        let addon = TestAddons.catalogAddon(base: server.catalogBase(flags: ["redirect"]))
        let metas = try await topCatalog(client(server), addon)
        #expect(metas.count == 4)
    }

    @Test func oversizedBodiesAreCutOffEarly() async throws {
        let server = try server()
        let small = AddonClient(configuration: AddonClientConfiguration(timeout: 10, maxBytes: 64 * 1024, maxRetries: 0))
        let started = Date()
        await #expect(throws: AddonError.responseTooLarge(limit: 64 * 1024)) {
            try await small.catalog(base: server.catalogBase(flags: ["big"]), type: "movie", id: "mock-top")
        }
        #expect(elapsed(since: started) < 5)
    }

    @Test func nullsAndNumbersAsStringsDecode() async throws {
        let server = try server()
        let client = client(server)
        let nulls = try await topCatalog(client, TestAddons.catalogAddon(base: server.catalogBase(flags: ["nulls"])))
        #expect(nulls.count == 4)
        #expect(nulls.prefix(3).allSatisfy { $0.genres.isEmpty && $0.poster == nil }, "null genres and posters become empty / nil")
        let strnums = try await topCatalog(client, TestAddons.catalogAddon(base: server.catalogBase(flags: ["strnums"])))
        #expect(strnums.first?.imdbRating != nil, "a string rating is parsed")
        #expect(strnums.first?.releaseInfo?.count == 4, "a numeric year becomes text")
        let nullStreams = try await client.streams(base: server.streamBase(flags: ["nulls"]), type: "movie", id: "mock:movie1")
        #expect(nullStreams.count == 10, "a stream without a source and a null entry are dropped")
    }

    // MARK: secrets

    @Test func capturedLogsContainNoTokens() async throws {
        let server = try server()
        let sink = MemoryLogSink()
        let client = client(server, timeout: server.slowDelay / 3, sink: sink)
        let flags: [[String]] = [[], ["err500"], ["badjson"], ["big"], ["redirect"], ["redirectloop"], ["slow"], ["nulls"]]
        let addons = flags.enumerated().map { index, flags in
            TestAddons.catalogAddon(base: server.catalogBase(flags: flags, token: token), name: "A\(index)")
        }
        _ = await FanOut.run(over: addons, operation: { try await topCatalog(client, $0) }).collect()
        _ = try? await client.fetchManifest(at: AddonURLNormaliser.normalise(server.catalogManifestURL(flags: ["badmanifest"], token: token).absoluteString))
        #expect(sink.lines.count > 8, "there is something to inspect")
        for line in sink.lines {
            #expect(!line.contains(token), "token leaked: \(line)")
            #expect(!line.contains("/catalog/"), "path leaked: \(line)")
        }
    }

    // MARK: resources

    @Test func catalogPagingGenreAndSearch() async throws {
        let server = try server()
        let client = client(server)
        let base = server.catalogBase()
        let page1 = try await client.catalog(base: base, type: "movie", id: "mock-movies")
        let page2 = try await client.catalog(base: base, type: "movie", id: "mock-movies", extras: [ExtraParam("skip", "20")])
        let page3 = try await client.catalog(base: base, type: "movie", id: "mock-movies", extras: [ExtraParam("skip", "40")])
        let counts: [Int] = [page1.count, page2.count, page3.count]
        #expect(counts == [20, 20, 5])
        #expect(Set(page1.map(\.id)).isDisjoint(with: page2.map(\.id)))
        let action = try await client.catalog(base: base, type: "movie", id: "mock-movies", extras: [ExtraParam("genre", "Action")])
        #expect(!action.isEmpty && action.allSatisfy { $0.genres.contains("Action") })
        let found = try await client.catalog(base: base, type: "movie", id: "mock-movies", extras: [ExtraParam("search", "movie 12")])
        #expect(found.map(\.id) == ["mock:movie12"])
        let both = try await client.catalog(base: base, type: "movie", id: "mock-movies", extras: [ExtraParam("genre", "Action"), ExtraParam("skip", "5")])
        #expect(both.allSatisfy { $0.genres.contains("Action") })
    }

    @Test func metaDetailAndFallbackCases() async throws {
        let server = try server()
        let client = client(server)
        let base = server.catalogBase()
        let movie = try await client.meta(base: base, type: "movie", id: "mock:movie3")
        #expect(movie.name == "Mock Movie 3")
        #expect(movie.cast == ["Mock Actor A", "Mock Actor B"])
        await #expect(throws: AddonError.notFound) { try await client.meta(base: base, type: "movie", id: "mock:nometa1") }
        let series = try await client.meta(base: base, type: "series", id: "mock:series1")
        #expect(series.seasons == [1, 2])
        #expect(series.episodes(inSeason: 2).map(\.id) == ["mock:series1:2:1", "mock:series1:2:2", "mock:series1:2:3"])
    }

    @Test func streamsAndSubtitles() async throws {
        let server = try server()
        let client = client(server)
        let base = server.streamBase()
        let all = try await client.streams(base: base, type: "movie", id: "mock:movie1")
        #expect(all.count == 10)
        #expect(try await client.streams(base: base, type: "movie", id: "mock:movie2").count == 1)
        #expect(try await client.streams(base: base, type: "series", id: "mock:series1:1:1").count == 2)
        let protected = try #require(all.first { $0.name == "Mock Protected" })
        #expect(protected.behaviorHints.proxyHeaders?.request == ["X-Mock-Token": "abc"])
        let subs = try await client.subtitles(base: base, type: "movie", id: "mock:movie1",
                                              extras: [ExtraParam("videoHash", "abc"), ExtraParam("filename", "My Movie (2020).mp4")])
        #expect(subs.map(\.lang) == ["eng", "spa"])
    }

    @Test func prefixOfAJSONBodyIsTruncatedWhenTheServerIgnoresRange() async throws {
        let server = try server()
        let (data, _) = try await client(server).prefix(of: server.catalogBase(flags: ["big"]).appendingPathComponent("catalog/movie/mock-top.json"), bytes: 4096)
        #expect(data.count == 4096, "the 6 MB body was cut at the limit, not rejected")
    }

    @Test(.enabled(if: MockServer.hasMediaFixtures, "needs generated media: run Tools/MockAddon/make-fixtures.sh (ffmpeg)"))
    func mediaPrefixesIdentifyTheContainers() async throws {
        let server = try server()
        let client = client(server)
        let media = server.stream.appendingPathComponent("media")
        let mkv = try await client.prefix(of: media.appendingPathComponent("blob/mkv"), bytes: 64)
        try requireFixture(mkv.data)
        #expect(Array(mkv.data.prefix(4)) == [0x1A, 0x45, 0xDF, 0xA3])
        #expect(mkv.contentType == "application/octet-stream")
        let mp4 = try await client.prefix(of: media.appendingPathComponent("blob/mp4"), bytes: 64)
        #expect(String(decoding: mp4.data.dropFirst(4).prefix(4), as: UTF8.self) == "ftyp")
        let hls = try await client.prefix(of: media.appendingPathComponent("blob/hls"), bytes: 64)
        #expect(String(decoding: hls.data.prefix(7), as: UTF8.self) == "#EXTM3U")
    }

    private func requireFixture(_ data: Data) throws {
        if data.isEmpty { throw MockServer.LaunchError(description: "media fixtures missing: run Tools/MockAddon/make-fixtures.sh") }
    }
}
