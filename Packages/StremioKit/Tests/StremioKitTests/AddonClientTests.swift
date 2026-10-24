import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import StremioKit
import StremioKitTestSupport

@Suite struct AddonClientTests {
    let url = URL(string: "https://addon.example.com/SECRET-TOKEN/catalog/movie/top.json")!

    private func fixture(_ name: String) throws -> Data { try Fixture.data("responses/\(name).json") }

    @Test func successSendsAnonymousJSONRequest() async throws {
        let transport = StubTransport(data: Data("{}".utf8))
        let result = try await makeClient(transport).get(url)
        #expect(result.response.statusCode == 200)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == StremioKitInfo.userAgent)
        #expect(request.value(forHTTPHeaderField: "Accept")?.contains("application/json") == true)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func extraHeadersAreSent() async throws {
        let transport = StubTransport(data: Data())
        _ = try await makeClient(transport).get(url, headers: ["X-Test": "1"])
        #expect(transport.requests.first?.value(forHTTPHeaderField: "X-Test") == "1")
    }

    @Test func notFoundIsNotRetried() async {
        let transport = StubTransport(data: Data(), status: 404)
        await #expect(throws: AddonError.notFound) { try await makeClient(transport).get(url) }
        #expect(transport.callCount == 1)
    }

    @Test func clientErrorsAreNotRetried() async {
        let transport = StubTransport(data: Data(), status: 403)
        await #expect(throws: AddonError.http(status: 403)) { try await makeClient(transport).get(url) }
        #expect(transport.callCount == 1)
    }

    @Test func serverErrorsAreRetriedThenSucceed() async throws {
        let transport = StubTransport { request, call in
            call < 3 ? StubTransport.response(Data(), status: 503, for: request) : StubTransport.response(Data("ok".utf8), for: request)
        }
        let result = try await makeClient(transport).get(url)
        #expect(String(decoding: result.data, as: UTF8.self) == "ok")
        #expect(transport.callCount == 3)
    }

    @Test func persistentServerErrorsStopAfterBoundedRetries() async {
        let transport = StubTransport(data: Data(), status: 500)
        await #expect(throws: AddonError.http(status: 500)) { try await makeClient(transport, retries: 2).get(url) }
        #expect(transport.callCount == 3, "first attempt plus two retries")
        let none = StubTransport(data: Data(), status: 500)
        await #expect(throws: AddonError.http(status: 500)) { try await makeClient(none, retries: 0).get(url) }
        #expect(none.callCount == 1)
    }

    @Test func transportTimeoutsAreRetriedAndReported() async {
        let transport = StubTransport { _, _ in throw URLError(.timedOut) }
        await #expect(throws: AddonError.timeout) { try await makeClient(transport).get(url) }
        #expect(transport.callCount == 3)
    }

    @Test func overallDeadlineStopsAHangingRequest() async throws {
        let transport = StubTransport { _, _ in
            try await Task.sleep(for: .seconds(30))
            throw URLError(.timedOut)
        }
        let started = Date()
        await #expect(throws: AddonError.timeout) { try await makeClient(transport, timeout: 0.3).get(url) }
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(transport.callCount == 1)
    }

    @Test func deadlineCoversRetriesAndBackoff() async {
        let transport = StubTransport(data: Data(), status: 500)
        let started = Date()
        await #expect(throws: AddonError.timeout) { try await makeClient(transport, timeout: 0.5, retries: 10, backoff: 0.2).get(url) }
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(transport.callCount < 11, "the deadline, not the retry cap, ended it")
    }

    @Test func streamRequestsGetTheirOwnLongerDeadline() async throws {
        let body = try fixture("streams-all-kinds")
        let transport = StubTransport { request, _ in
            try await Task.sleep(for: .milliseconds(600))
            return StubTransport.response(body, for: request)
        }
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: 0.2, streamTimeout: 1.5, maxRetries: 0, retryBackoff: 0.01),
                                 transport: transport)
        let base = URL(string: "https://addon.example.com")!
        await #expect(throws: AddonError.timeout) { try await client.catalog(base: base, type: "movie", id: "top") }
        let streams = try await client.streams(base: base, type: "movie", id: "tt1")
        #expect(streams.count == 8, "a 0.6 s answer misses the 0.2 s catalog deadline but meets the 1.5 s stream deadline")
        #expect(transport.callCount == 2)
    }

    @Test func cancellingTheCallerCancelsTheRequest() async {
        let transport = StubTransport { _, _ in
            try await Task.sleep(for: .seconds(30))
            return HTTPResult(data: Data(), response: HTTPResponseInfo(statusCode: 200))
        }
        let client = makeClient(transport, timeout: 30)
        let target = url
        let task = Task { try await client.get(target) }
        try? await Task.sleep(for: .milliseconds(80))
        task.cancel()
        let started = Date()
        let outcome = await task.result
        #expect(Date().timeIntervalSince(started) < 2)
        if case .failure(let error) = outcome { #expect(error as? AddonError == .cancelled) } else { Issue.record("expected cancellation") }
    }

    @Test func nonHTTPSchemesNeverReachTheTransport() async {
        let transport = StubTransport(data: Data())
        for text in ["ftp://example.com/x.json", "file:///etc/passwd", "javascript:alert(1)"] {
            await #expect(throws: AddonError.invalidURL) { try await makeClient(transport).get(URL(string: text)!) }
        }
        #expect(transport.callCount == 0)
    }

    @Test func prefixAsksForARangeAndAllowsTruncation() async throws {
        let transport = StubTransport(data: Data([0x1A, 0x45, 0xDF, 0xA3]), status: 206, headers: ["content-type": "application/octet-stream"])
        let result = try await makeClient(transport).prefix(of: url, bytes: 64)
        #expect(result.data == Data([0x1A, 0x45, 0xDF, 0xA3]))
        #expect(result.contentType == "application/octet-stream")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Range") == "bytes=0-63")
        #expect(transport.limits.first == FetchLimits(maxBytes: 64, truncateAtLimit: true, maxRedirects: 5))
    }

    // MARK: typed requests

    @Test func catalogBuildsTheRightURLAndDecodes() async throws {
        let transport = StubTransport(data: try fixture("catalog-basic"))
        let base = URL(string: "https://addon.example.com/SECRET-TOKEN")!
        let metas = try await makeClient(transport).catalog(base: base, type: "movie", id: "top", extras: [ExtraParam("genre", "Action"), ExtraParam("skip", "20")])
        #expect(metas.count == 2)
        #expect(transport.requests.first?.url?.absoluteString == "https://addon.example.com/SECRET-TOKEN/catalog/movie/top/genre=Action&skip=20.json")
    }

    @Test func streamsAndSubtitlesDecode() async throws {
        let base = URL(string: "https://addon.example.com")!
        let streams = try await makeClient(StubTransport(data: try fixture("streams-all-kinds"))).streams(base: base, type: "movie", id: "tt1")
        #expect(streams.count == 8)
        let client = makeClient(StubTransport(data: try fixture("subtitles-basic")))
        let subs = try await client.subtitles(base: base, type: "movie", id: "tt1", extras: [ExtraParam("videoHash", "abc")])
        #expect(subs.count == 2)
    }

    @Test func metaFallsBackToNotFoundWhenMissing() async throws {
        let base = URL(string: "https://addon.example.com")!
        await #expect(throws: AddonError.notFound) {
            try await makeClient(StubTransport(data: try fixture("meta-missing"))).meta(base: base, type: "movie", id: "tt1")
        }
        let detail = try await makeClient(StubTransport(data: try fixture("meta-movie"))).meta(base: base, type: "movie", id: "tt0000001")
        #expect(detail.name == "One")
    }

    @Test func invalidJSONBodiesAreReportedAsInvalidJSON() async {
        let base = URL(string: "https://addon.example.com")!
        await #expect(throws: AddonError.invalidJSON) {
            try await makeClient(StubTransport(data: Data("<html>oops</html>".utf8))).catalog(base: base, type: "movie", id: "top")
        }
    }

    @Test func manifestValidationFailuresExplainThemselves() async throws {
        let location = try AddonURLNormaliser.normalise("https://addon.example.com/manifest.json")
        let bad = StubTransport(data: try Fixture.data("manifests/14-invalid-no-id.json"))
        do {
            _ = try await makeClient(bad).fetchManifest(at: location)
            Issue.record("expected invalidManifest")
        } catch let error as AddonError {
            guard case .invalidManifest(let reasons) = error else { Issue.record("wrong error \(error)"); return }
            #expect(reasons == ["The manifest has no id."])
        }
        let good = try await makeClient(StubTransport(data: try Fixture.data("manifests/10-cinemeta-like.json"))).fetchManifest(at: location)
        #expect(good.id == "org.example.cinemeta")
        #expect(bad.callCount == 1)
    }

    // MARK: secrets

    @Test func logsNeverContainTheTokenOnSuccessOrFailure() async throws {
        let sink = MemoryLogSink()
        let logger = AddonLogger(sink: sink)
        let ok = makeClient(StubTransport(data: Data("{}".utf8)), logger: logger)
        _ = try await ok.get(url)
        let failing = makeClient(StubTransport(data: Data(), status: 500), logger: logger)
        _ = try? await failing.get(url)
        let hanging = makeClient(StubTransport { _, _ in throw URLError(.cannotConnectToHost) }, logger: logger)
        _ = try? await hanging.get(url)
        #expect(!sink.lines.isEmpty)
        for line in sink.lines {
            #expect(!line.contains("SECRET-TOKEN"), "leaked in: \(line)")
            #expect(!line.contains("/catalog/movie"), "path leaked in: \(line)")
        }
        #expect(sink.lines.contains { $0.contains("addon.example.com") })
    }

    @Test func errorsMapWithoutCarryingURLs() {
        #expect(AddonError.from(URLError(.timedOut)) == .timeout)
        #expect(AddonError.from(URLError(.cancelled)) == .cancelled)
        #expect(AddonError.from(URLError(.notConnectedToInternet)) == .offline)
        #expect(AddonError.from(URLError(.badURL)) == .invalidURL)
        #expect(AddonError.from(URLError(.httpTooManyRedirects)) == .tooManyRedirects)
        #expect(AddonError.from(CancellationError()) == .cancelled)
        #expect(AddonError.from(AddonError.notFound) == .notFound)
        #expect(AddonError.from(URLError(.cannotConnectToHost)) == .network("urlerror.\(URLError.Code.cannotConnectToHost.rawValue)"))
        struct Other: Error, CustomStringConvertible { let description = "https://leak.example.com/SECRET" }
        #expect(AddonError.from(Other()) == .network("error"))
    }

    @Test func redirectPolicy() throws {
        let https = URL(string: "https://a.example.com/x")!
        #expect(RedirectPolicy.allows(from: https, to: URL(string: "https://b.example.com/y")!))
        #expect(!RedirectPolicy.allows(from: https, to: URL(string: "http://b.example.com/y")!), "no downgrade to plaintext on the internet")
        #expect(RedirectPolicy.allows(from: https, to: URL(string: "http://192.168.1.5/y")!), "LAN hosts are fine")
        #expect(RedirectPolicy.allows(from: URL(string: "http://a.example.com")!, to: URL(string: "http://b.example.com")!))
        #expect(!RedirectPolicy.allows(from: https, to: URL(string: "file:///etc/passwd")!))
        #expect(!RedirectPolicy.allows(from: https, to: URL(string: "ftp://b.example.com")!))
        #expect(RedirectPolicy.allows(from: nil, to: https))
    }
}
