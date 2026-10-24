import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import StremioKit
import StremioKitTestSupport

@Suite struct OpenSubtitlesClientTests {
    private let key = "KEY-123"

    private static let emptySearch = Data(#"{"total_count":0,"data":[]}"#.utf8)
    /// A search that finds one subtitle, file 456: the file the download tests ask for.
    private static let oneResult = Data(#"{"total_count":1,"data":[{"id":"9","attributes":{"language":"en","files":[{"file_id":456}]}}]}"#.utf8)
    private static let downloadAnswer = Data(#"{"link":"https://dl.example.com/x.srt","file_name":"x.srt","remaining":99,"reset_time":"later"}"#.utf8)
    private static let loginAnswer = Data(#"{"token":"tok-1","status":200}"#.utf8)

    private func makeSubject(_ transport: StubTransport, credentials: OpenSubtitlesCredentials? = nil) -> OpenSubtitlesClient {
        OpenSubtitlesClient(client: makeClient(transport), credentials: credentials ?? OpenSubtitlesCredentials(apiKey: key), transport: transport)
    }

    /// The result of a search that finds file 456. Its own transport, so it does not count in the test's requests.
    private func sampleResult() async throws -> OpenSubtitlesResult {
        let results = try await makeSubject(StubTransport(data: Self.oneResult))
            .search(imdbID: "tt1", season: nil, episode: nil, languages: [], movieHash: nil)
        return try #require(results.first)
    }

    /// Query parameters as `name=value`, in the order they were sent.
    private func queryItems(_ request: URLRequest?) -> [String] {
        guard let url = request?.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [] }
        return items.map { "\($0.name)=\($0.value ?? "")" }
    }

    private func jsonBody(_ request: URLRequest?) throws -> [String: Any] {
        let body = try #require(request?.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: - Search

    @Test func aMovieSearchSendsTheIMDbNumberWithoutTheTT() async throws {
        let transport = StubTransport(data: Self.emptySearch)
        _ = try await makeSubject(transport).search(imdbID: "tt0111161", season: nil, episode: nil, languages: ["pt-BR", "en"],
                                                    movieHash: "ABCDEF0123456789")
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString.hasPrefix("https://api.opensubtitles.com/api/v1/subtitles?") == true)
        #expect(queryItems(request) == ["imdb_id=111161", "languages=en,pt-br", "moviehash=abcdef0123456789", "order_by=download_count"])
    }

    @Test func anEpisodeSearchAsksByTheSeriesNumberSeasonAndEpisode() async throws {
        let transport = StubTransport(data: Self.emptySearch)
        _ = try await makeSubject(transport).search(imdbID: "tt0944947", season: 1, episode: 2, languages: [], movieHash: nil)
        let request = try #require(transport.requests.first)
        #expect(queryItems(request) == ["episode_number=2", "order_by=download_count", "parent_imdb_id=944947", "season_number=1"])
    }

    @Test func languagesAreLowercasedDeduplicatedAndSorted() async throws {
        let transport = StubTransport(data: Self.emptySearch)
        _ = try await makeSubject(transport).search(imdbID: "tt1", season: nil, episode: nil, languages: ["Fr", " en ", "pt-BR", "EN"],
                                                    movieHash: nil)
        #expect(queryItems(transport.requests.first).contains("languages=en,fr,pt-br"))
    }

    @Test func aSearchSendsTheKeyInAHeaderAndNotInTheURL() async throws {
        let transport = StubTransport(data: Self.emptySearch)
        _ = try await makeSubject(transport).search(imdbID: "tt1", season: nil, episode: nil, languages: [], movieHash: nil)
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Api-Key") == key)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Blusion v1.0")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.url?.absoluteString.contains(key) == false)
    }

    @Test func resultsSortHashMatchesFirstThenHumanTranslationsThenDownloads() async throws {
        let answer = Data(#"""
        {"total_count": 6, "data": [
          {"id": "1", "attributes": {"language": "en", "release": "A", "download_count": 10, "machine_translated": false, "ai_translated": false,
            "moviehash_match": true, "hearing_impaired": false, "foreign_parts_only": false, "format": "srt",
            "files": [{"file_id": 1, "file_name": "a.srt"}]}},
          {"id": "2", "attributes": {"language": "en", "release": "B", "download_count": 1000, "machine_translated": true,
            "moviehash_match": true, "format": null, "files": [{"file_id": 2, "file_name": "b.srt"}]}},
          {"id": "3", "attributes": {"language": "en", "release": "C", "download_count": 500, "moviehash_match": false,
            "files": [{"file_id": 3}]}},
          {"id": "4", "attributes": {"language": "en", "release": "D", "download_count": 900, "files": [{"file_id": 4}]}},
          {"id": "5", "attributes": {"language": "en", "release": "E", "download_count": 9999, "ai_translated": true, "files": [{"file_id": 5}]}},
          {"id": "6", "attributes": {"language": "en", "release": "F", "download_count": 99999, "files": []}}
        ]}
        """#.utf8)
        let transport = StubTransport(data: answer)
        let results = try await makeSubject(transport).search(imdbID: "tt1", season: nil, episode: nil, languages: [], movieHash: nil)
        #expect(results.map(\.fileID) == [1, 2, 4, 3, 5], "hash matches, then non-machine, then downloads; a result without files is skipped")
        let first = try #require(results.first)
        #expect(first.id == "1" && first.fileName == "a.srt" && first.format == "srt" && first.matchesHash && !first.isMachineTranslated)
        #expect(first.isHearingImpaired == false && first.isForeignPartsOnly == false && first.downloadCount == 10 && first.release == "A")
        #expect(results[1].format == nil && results[1].isMachineTranslated)
        #expect(results.last?.isMachineTranslated == true, "ai_translated counts as machine translated")
    }

    @Test func aSearchWithNoDigitsInTheIDSendsNothing() async throws {
        let transport = StubTransport(data: Self.emptySearch)
        let results = try await makeSubject(transport).search(imdbID: "tt", season: nil, episode: nil, languages: [], movieHash: nil)
        #expect(results.isEmpty && transport.callCount == 0)
    }

    @Test func anUndocumentedAnswerIsADecodingError() async {
        let transport = StubTransport(data: Data("<html>".utf8))
        await #expect(throws: OpenSubtitlesError.decoding) {
            try await makeSubject(transport).search(imdbID: "tt1", season: nil, episode: nil, languages: [], movieHash: nil)
        }
    }

    // MARK: - Download

    @Test func aDownloadWithoutAnAccountIsAnonymous() async throws {
        let result = try await sampleResult()
        let transport = StubTransport { request, _ in StubTransport.response(Self.downloadAnswer, for: request) }
        let download = try await makeSubject(transport).download(result)
        #expect(download.url == URL(string: "https://dl.example.com/x.srt"))
        #expect(download.fileName == "x.srt" && download.remaining == 99)
        #expect(transport.callCount == 1, "no login without a username and password")
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/download")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Api-Key") == key)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(try jsonBody(request)["file_id"] as? Int == 456)
    }

    @Test func aUsernameWithoutAPasswordStaysAnonymous() async throws {
        let result = try await sampleResult()
        let transport = StubTransport { request, _ in StubTransport.response(Self.downloadAnswer, for: request) }
        _ = try await makeSubject(transport, credentials: OpenSubtitlesCredentials(apiKey: key, username: "sample-user")).download(result)
        #expect(transport.callCount == 1)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func withAnAccountTheClientLogsInOnceAndSendsTheBearerToken() async throws {
        let result = try await sampleResult()
        let transport = StubTransport { request, _ in
            if request.url?.path == "/api/v1/login" { return StubTransport.response(Self.loginAnswer, for: request) }
            return StubTransport.response(Self.downloadAnswer, for: request)
        }
        let subject = makeSubject(transport, credentials: OpenSubtitlesCredentials(apiKey: key, username: "sample-user", password: "pw"))
        _ = try await subject.download(result)
        _ = try await subject.download(result)

        #expect(transport.requests.map { $0.url?.path } == ["/api/v1/login", "/api/v1/download", "/api/v1/download"])
        let login = try #require(transport.requests.first)
        #expect(login.httpMethod == "POST")
        #expect(login.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(login.value(forHTTPHeaderField: "Api-Key") == key)
        let loginBody = try jsonBody(login)
        #expect(loginBody["username"] as? String == "sample-user" && loginBody["password"] as? String == "pw")
        #expect(transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer tok-1")
        #expect(transport.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer tok-1")
    }

    @Test func aRefusedTokenIsReplacedOnceAndTheDownloadRetried() async throws {
        let result = try await sampleResult()
        let transport = StubTransport { request, call in
            if request.url?.path == "/api/v1/login" {
                return StubTransport.response(Data(#"{"token":"tok-\#(call)"}"#.utf8), for: request)
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-1" {
                return StubTransport.response(Data(), status: 401, for: request)
            }
            return StubTransport.response(Self.downloadAnswer, for: request)
        }
        let subject = makeSubject(transport, credentials: OpenSubtitlesCredentials(apiKey: key, username: "sample-user", password: "pw"))
        let download = try await subject.download(result)
        #expect(download.url == URL(string: "https://dl.example.com/x.srt"))
        #expect(transport.requests.map { $0.url?.path } == ["/api/v1/login", "/api/v1/download", "/api/v1/login", "/api/v1/download"])
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-3")
    }

    @Test func aTokenRefusedAgainAfterTheReloginIsUnauthorizedAndNotRetriedAgain() async throws {
        let result = try await sampleResult()
        let transport = StubTransport { request, _ in
            if request.url?.path == "/api/v1/login" { return StubTransport.response(Self.loginAnswer, for: request) }
            return StubTransport.response(Data(), status: 401, for: request)
        }
        let subject = makeSubject(transport, credentials: OpenSubtitlesCredentials(apiKey: key, username: "sample-user", password: "pw"))
        await #expect(throws: OpenSubtitlesError.unauthorized) { try await subject.download(result) }
        #expect(transport.callCount == 4, "login, download, login, download: then it gives up")
    }

    @Test func aQuotaRefusalCarriesTheResetTime() async throws {
        let result = try await sampleResult()
        let body = Data(#"{"message":"Download limit reached","remaining":0,"reset_time":"2026-10-24 00:00:00"}"#.utf8)
        let refused = StubTransport(data: body, status: 406)
        await #expect(throws: OpenSubtitlesError.quotaExceeded(resetTime: "2026-10-24 00:00:00")) {
            try await makeSubject(refused).download(result)
        }
        let limited = StubTransport(data: Data(), status: 429)
        await #expect(throws: OpenSubtitlesError.quotaExceeded(resetTime: nil)) {
            try await makeSubject(limited).download(result)
        }
        let otherRefusal = StubTransport(data: Data("{}".utf8), status: 406)
        await #expect(throws: OpenSubtitlesError.server(406)) {
            try await makeSubject(otherRefusal).download(result)
        }
    }

    @Test func statusesMapToTheirErrors() async throws {
        let result = try await sampleResult()
        let cases: [(status: Int, error: OpenSubtitlesError)] = [(401, .unauthorized), (403, .unauthorized), (404, .notFound), (503, .server(503))]
        for (status, error) in cases {
            let transport = StubTransport(data: Data(), status: status)
            await #expect(throws: error) {
                try await makeSubject(transport).search(imdbID: "tt1", season: nil, episode: nil, languages: [], movieHash: nil)
            }
            await #expect(throws: error) { try await makeSubject(transport).download(result) }
        }
    }

    @Test func aMissingKeyFailsBeforeAnyRequest() async throws {
        let result = try await sampleResult()
        let transport = StubTransport(data: Self.emptySearch)
        let subject = makeSubject(transport, credentials: OpenSubtitlesCredentials(apiKey: "  ", username: "sample-user", password: "pw"))
        await #expect(throws: OpenSubtitlesError.missingAPIKey) {
            try await subject.search(imdbID: "tt1", season: nil, episode: nil, languages: [], movieHash: nil)
        }
        await #expect(throws: OpenSubtitlesError.missingAPIKey) { try await subject.download(result) }
        #expect(transport.callCount == 0)
    }
}
