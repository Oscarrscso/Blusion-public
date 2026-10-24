// swiftlint:disable line_length
import Foundation
import Testing
import StremioKitTestSupport
@testable import StremioKit

@Suite struct TraktAccountTests: Sendable {
    private let codeJSON = #"{"device_code":"device","user_code":"ABCD1234","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":5}"#
    private let tokenJSON = #"{"access_token":"access","refresh_token":"refresh","expires_in":604800,"created_at":1700000000}"#
    private let movieJSON = #"{"movie":{"title":"Movie","year":2020,"ids":{"imdb":"tt1"}},"last_watched_at":"2023-11-14T22:13:20.000Z"}"#

    private func account(_ transport: StubTransport, secrets: InMemorySecretStore = InMemorySecretStore()) async throws -> TraktAccount {
        let settings = InMemorySettingsStore(PlaybackSettings(traktClientID: "client"))
        let account = TraktAccount(settings: settings, secrets: secrets, transport: transport, now: { Date(timeIntervalSince1970: 1700000001) })
        try await account.saveClientSecret("secret")
        return account
    }

    private func signIn(_ account: TraktAccount) async throws {
        let code = try JSONDecoder().decode(TraktDeviceCode.self, from: Data(codeJSON.utf8))
        let result = try await account.checkAuthorization(code)
        #expect(result == .signedIn)
    }

    @Test func deviceRequestsAndTokensStayInTheSecretStore() async throws {
        let transport = StubTransport { request, _ in
            let json = request.url?.path == "/oauth/device/code" ? codeJSON : tokenJSON
            return StubTransport.response(Data(json.utf8), for: request)
        }
        let secrets = InMemorySecretStore()
        let account = try await account(transport, secrets: secrets)
        let code = try await account.beginSignIn()
        #expect(code.userCode == "ABCD1234" && code.interval == 5)
        let result = try await account.checkAuthorization(code)
        #expect(result == .signedIn)
        #expect(await account.isSignedIn())
        let request = try #require(transport.requests.last)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        #expect(request.httpMethod == "POST")
        #expect(body == ["code": "device", "client_id": "client", "client_secret": "secret"])
        let snapshot = await secrets.snapshot
        #expect(snapshot[TraktAccount.Keys.clientSecret] == "secret")
        #expect(snapshot[TraktAccount.Keys.token]?.contains("access") == true)
        await account.clearCredentials()
        let cleared = await secrets.snapshot
        #expect(cleared.isEmpty)
        #expect(!(await account.isSignedIn()))
    }

    @Test func pendingSlowDownAndDeniedCodesAreRecognized() async throws {
        for (status, expected) in [(400, TraktAuthorizationResult.pending), (429, .slowDown)] {
            let account = try await account(StubTransport(data: Data(), status: status))
            let code = try JSONDecoder().decode(TraktDeviceCode.self, from: Data(codeJSON.utf8))
            #expect(try await account.checkAuthorization(code) == expected)
            #expect(!(await account.isSignedIn()))
        }
        for (status, error) in [(404, TraktAccountError.invalidCode), (409, .invalidCode), (410, .expiredCode), (418, .denied)] {
            let account = try await account(StubTransport(data: Data(), status: status))
            let code = try JSONDecoder().decode(TraktDeviceCode.self, from: Data(codeJSON.utf8))
            await #expect(throws: error) { try await account.checkAuthorization(code) }
        }
    }

    @Test func credentialsAndSignInAreRequiredWithoutMakingRequests() async throws {
        let transport = StubTransport(data: Data())
        let settings = InMemorySettingsStore()
        let account = TraktAccount(settings: settings, secrets: InMemorySecretStore(), transport: transport)
        await #expect(throws: TraktAccountError.needsCredentials) { try await account.beginSignIn() }
        await settings.save(PlaybackSettings(traktClientID: "client"))
        try await account.saveClientSecret("secret")
        await #expect(throws: TraktAccountError.needsSignIn) { try await account.watchlist() }
        #expect(transport.callCount == 0)
    }

    @Test func watchlistPaginationAndWatchedEpisodesMapToAddonIdentities() async throws {
        let transport = StubTransport { request, _ in
            if request.url?.path == "/oauth/device/token" { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
            #expect(request.value(forHTTPHeaderField: "trakt-api-key") == "client")
            #expect(request.value(forHTTPHeaderField: "trakt-api-version") == "2")
            if request.url?.path == "/sync/watchlist" {
                let second = request.url?.query?.contains("page=2") == true
                let json = second ? #"[{"show":{"title":"Show","ids":{"imdb":"tt2"}}}]"# : "[\(movieJSON)]"
                return StubTransport.response(Data(json.utf8), for: request, headers: ["x-pagination-page-count": "2"])
            }
            if request.url?.path == "/sync/watched/movies" { return StubTransport.response(Data("[\(movieJSON)]".utf8), for: request) }
            let payload = #"[{"show":{"title":"Show","ids":{"imdb":"tt2"}},"seasons":[{"number":2,"episodes":[{"number":3,"last_watched_at":"2023-11-14T22:13:20Z"}]}]}]"#
            return StubTransport.response(Data(payload.utf8), for: request)
        }
        let account = try await account(transport)
        try await signIn(account)
        let watchlist = try await account.watchlist()
        #expect(watchlist.map(\.id) == ["tt1", "tt2"])
        #expect(watchlist.map(\.type) == ["movie", "series"])
        let watched = try await account.watched()
        #expect(watched.map(\.identity) == ["movie/tt1", "series/tt2:2:3"])
        #expect(watched.last?.watchedAt == Date(timeIntervalSince1970: 1700000000))
    }

    @Test func collectionPagesMoviesAndMapsCollectedShowsWithoutWatchDates() async throws {
        let transport = StubTransport { request, _ in
            if request.url?.path == "/oauth/device/token" { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
            if request.url?.path == "/sync/collection/movies" {
                let second = request.url?.query?.contains("page=2") == true
                let json = second
                    ? #"[{"movie":{"title":"Second","ids":{"imdb":"tt2"}}},{"movie":{"title":"No IMDb","ids":{"trakt":3}}}]"#
                    : #"[{"movie":{"title":"First","year":2020,"ids":{"imdb":"tt1"}},"collected_at":"2023-11-14T22:13:20Z"}]"#
                return StubTransport.response(Data(json.utf8), for: request, headers: ["x-pagination-page-count": "2"])
            }
            #expect(request.url?.path == "/sync/collection/shows")
            let payload = #"[{"show":{"title":"Show","ids":{"imdb":"tt3"}},"seasons":[{"number":1,"episodes":[{"number":2,"collected_at":"2023-11-14T22:13:20Z"}]}]}]"#
            return StubTransport.response(Data(payload.utf8), for: request)
        }
        let account = try await account(transport)
        try await signIn(account)
        let collection = try await account.collection()
        #expect(collection.map(\.id) == ["tt1", "tt2", "tt3"])
        #expect(collection.map(\.type) == ["movie", "movie", "series"])
        #expect(collection.first?.releaseInfo == "2020")
        #expect(transport.callCount == 4)
    }

    @Test func expiredTokensRefreshBeforeReadingAndSignOutRevokes() async throws {
        let transport = StubTransport { request, call in
            if call == 1 { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            if request.url?.path == "/oauth/token" {
                let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
                #expect(body["grant_type"] == "refresh_token" && body["refresh_token"] == "refresh")
                let payload = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":604800,"created_at":1800000000}"#
                return StubTransport.response(Data(payload.utf8), for: request)
            }
            if request.url?.path == "/oauth/revoke" { return StubTransport.response(Data("{}".utf8), for: request) }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
            return StubTransport.response(Data("[]".utf8), for: request)
        }
        let account = TraktAccount(settings: InMemorySettingsStore(PlaybackSettings(traktClientID: "client")), secrets: InMemorySecretStore(),
                                   transport: transport, now: { Date(timeIntervalSince1970: 1800000001) })
        try await account.saveClientSecret("secret")
        try await signIn(account)
        _ = try await account.watchlist()
        #expect(transport.requests.map { $0.url?.path } == ["/oauth/device/token", "/oauth/token", "/sync/watchlist"])
        await account.signOut()
        #expect(!(await account.isSignedIn()))
        #expect(transport.requests.last?.url?.path == "/oauth/revoke")
    }

    @Test func playbackRowsKeepTraktsIDAndRemovingOneDeletesOnlyThatRecord() async throws {
        let row = #"""
        [{"id":42,"progress":40,"paused_at":"2023-11-14T22:13:20.000Z","type":"movie",
          "movie":{"title":"Movie","year":2020,"ids":{"imdb":"tt1"},"runtime":100}}]
        """#
        let transport = StubTransport { request, call in
            if call == 1 { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            return StubTransport.response(Data(row.utf8), for: request)
        }
        let account = try await account(transport)
        try await signIn(account)
        let items = try await account.playback()
        #expect(items.map(\.playbackID) == [42])
        try await account.removePlayback(id: 42)
        let request = try #require(transport.requests.last)
        #expect(request.httpMethod == "DELETE" && request.url?.path == "/sync/playback/42")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
    }

    @Test func changedSecretsInvalidateTokensAndChangedClientIDCannotReuseThem() async throws {
        let transport = StubTransport(data: Data(tokenJSON.utf8))
        let settings = InMemorySettingsStore(PlaybackSettings(traktClientID: "client"))
        let account = TraktAccount(settings: settings, secrets: InMemorySecretStore(), transport: transport)
        try await account.saveClientSecret("secret")
        try await signIn(account)
        await settings.save(PlaybackSettings(traktClientID: "other"))
        #expect(!(await account.isSignedIn()))
        await #expect(throws: TraktAccountError.credentialsChanged) { try await account.watchlist() }
        try await account.saveClientSecret("changed")
        await #expect(throws: TraktAccountError.needsSignIn) { try await account.watchlist() }
        #expect(transport.callCount == 1)
    }

    @Test func exportsUseOnlyIMDbIDsAndReportActualAddedCounts() async throws {
        let transport = StubTransport { request, call in
            if call == 1 { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            let movies = try #require(body["movies"] as? [[String: Any]])
            #expect(movies.count == 1)
            #expect((movies[0]["ids"] as? [String: String])?["imdb"] == "tt1")
            if request.url?.path == "/sync/history" { #expect(movies[0]["watched_at"] as? String == "2023-11-14T22:13:20Z") }
            let payload = #"{"added":{"movies":1,"shows":0,"episodes":0},"existing":{"movies":0},"not_found":{"movies":[]}}"#
            return StubTransport.response(Data(payload.utf8), status: 201, for: request)
        }
        let account = try await account(transport)
        try await signIn(account)
        let items = [MetaPreview(id: "tt1", type: "movie", name: "Movie"), MetaPreview(id: "private-id", type: "movie", name: "Other")]
        #expect(try await account.addToWatchlist(items) == 1)
        #expect(try await account.addToHistory(items.map { TraktWatchedItem(preview: $0, watchedAt: Date(timeIntervalSince1970: 1700000000)) }) == 1)
        #expect(transport.callCount == 3)
    }

    /// The recorded request body as sorted-key JSON, so tests can compare the exact payload.
    private func canonicalBody(_ request: URLRequest) throws -> String {
        let object = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    @Test func watchlistEntriesPageAndCarryListedDates() async throws {
        let transport = StubTransport { request, call in
            if call == 1 { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            if request.url?.query?.contains("page=2") == true {
                let json = #"[{"show":{"title":"Show","ids":{"imdb":"tt2"}},"listed_at":"2023-11-15T00:00:00Z"},{"movie":{"title":"Undated","ids":{"imdb":"tt3"}}}]"#
                return StubTransport.response(Data(json.utf8), for: request)
            }
            let json = #"[{"movie":{"title":"Movie","year":2020,"ids":{"imdb":"tt1"}},"listed_at":"2023-11-14T22:13:20.000Z"}]"#
            return StubTransport.response(Data(json.utf8), for: request, headers: ["x-pagination-page-count": "2"])
        }
        let account = try await account(transport)
        try await signIn(account)
        let entries = try await account.watchlistEntries()
        #expect(entries.map(\.identity) == ["movie/tt1", "series/tt2", "movie/tt3"])
        #expect(entries.map(\.addedAt) == [Date(timeIntervalSince1970: 1700000000), Date(timeIntervalSince1970: 1700006400), nil])
        #expect(transport.requests.dropFirst().map { $0.url?.path } == ["/sync/watchlist", "/sync/watchlist"])
        #expect(transport.requests.dropFirst().map { $0.url?.query } == ["page=1&limit=100&extended=full", "page=2&limit=100&extended=full"])
        #expect(try await account.watchlist() == entries.map(\.preview))
    }

    @Test func collectionEntriesDateMoviesByCollectedAtAndShowsByLastCollectedAt() async throws {
        let transport = StubTransport { request, call in
            if call == 1 { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            if request.url?.path == "/sync/collection/movies" {
                let json = #"[{"movie":{"title":"Movie","ids":{"imdb":"tt1"}},"collected_at":"2023-11-14T22:13:20Z"}]"#
                return StubTransport.response(Data(json.utf8), for: request)
            }
            let json = #"[{"show":{"title":"Show","ids":{"imdb":"tt2"}},"collected_at":"2020-01-01T00:00:00Z","last_collected_at":"2023-11-15T00:00:00.000Z"}]"#
            return StubTransport.response(Data(json.utf8), for: request)
        }
        let account = try await account(transport)
        try await signIn(account)
        let entries = try await account.collectionEntries()
        #expect(entries.map(\.identity) == ["movie/tt1", "series/tt2"])
        #expect(entries.map(\.addedAt) == [Date(timeIntervalSince1970: 1700000000), Date(timeIntervalSince1970: 1700006400)])
        #expect(transport.requests.dropFirst().map { $0.url?.path } == ["/sync/collection/movies", "/sync/collection/shows"])
        #expect(transport.requests.dropFirst().map { $0.url?.query } == ["page=1&limit=100&extended=full", "extended=full"])
    }

    @Test func removeFromWatchlistSendsIMDbIDsOnlyAndReportsDeletedCount() async throws {
        let transport = StubTransport { request, call in
            if call == 1 { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            let payload = #"{"deleted":{"movies":1,"shows":1,"episodes":0},"not_found":{"movies":[],"shows":[]}}"#
            return StubTransport.response(Data(payload.utf8), for: request)
        }
        let account = try await account(transport)
        try await signIn(account)
        let items = [MetaPreview(id: "tt1", type: "movie", name: "Movie"), MetaPreview(id: "private-id", type: "movie", name: "Other"),
                     MetaPreview(id: "tt2", type: "series", name: "Show")]
        #expect(try await account.removeFromWatchlist(items) == 2)
        let request = try #require(transport.requests.last)
        #expect(request.httpMethod == "POST" && request.url?.path == "/sync/watchlist/remove")
        #expect(try canonicalBody(request) == #"{"movies":[{"ids":{"imdb":"tt1"}}],"shows":[{"ids":{"imdb":"tt2"}}]}"#)

        let before = transport.callCount
        #expect(try await account.removeFromWatchlist([]) == 0)
        #expect(try await account.removeFromWatchlist([MetaPreview(id: "private-id", type: "movie")]) == 0)
        #expect(transport.callCount == before)
    }

    @Test func removeFromHistorySendsTitlesAndEpisodesWithoutWatchDates() async throws {
        let transport = StubTransport { request, call in
            if call == 1 { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            let payload = #"{"deleted":{"movies":1,"episodes":3},"not_found":{"movies":[],"episodes":[]}}"#
            return StubTransport.response(Data(payload.utf8), for: request)
        }
        let account = try await account(transport)
        try await signIn(account)
        let watchedAt = Date(timeIntervalSince1970: 1700000000)
        let items = [
            TraktWatchedItem(preview: MetaPreview(id: "tt2", type: "series", name: "Show"), watchedAt: watchedAt, season: 2, episode: 1),
            TraktWatchedItem(preview: MetaPreview(id: "tt1", type: "movie", name: "Movie"), watchedAt: watchedAt),
            TraktWatchedItem(preview: MetaPreview(id: "tt2", type: "series", name: "Show"), watchedAt: watchedAt, season: 1, episode: 1),
            TraktWatchedItem(preview: MetaPreview(id: "tt2", type: "series", name: "Show"), watchedAt: watchedAt, season: 2, episode: 3),
            TraktWatchedItem(preview: MetaPreview(id: "private-id", type: "series", name: "Other"), watchedAt: watchedAt, season: 1, episode: 1),
            TraktWatchedItem(preview: MetaPreview(id: "tt2", type: "series", name: "Show"), watchedAt: watchedAt, season: 1),
        ]
        #expect(try await account.removeFromHistory(items) == 4)
        let request = try #require(transport.requests.last)
        #expect(request.httpMethod == "POST" && request.url?.path == "/sync/history/remove")
        let expected = #"{"movies":[{"ids":{"imdb":"tt1"}}],"shows":[{"ids":{"imdb":"tt2"},"seasons":[{"episodes":[{"number":1}],"number":1},{"episodes":[{"number":1},{"number":3}],"number":2}]}]}"#
        #expect(try canonicalBody(request) == expected)

        let before = transport.callCount
        #expect(try await account.removeFromHistory([]) == 0)
        #expect(try await account.removeFromHistory([TraktWatchedItem(preview: MetaPreview(id: "tt2", type: "series"), watchedAt: watchedAt, season: 1)]) == 0)
        #expect(transport.callCount == before)
    }

    @Test func savePlaybackSendsIMDbMoviesAndEpisodesWithClampedProgress() async throws {
        let transport = StubTransport { request, call in
            if call == 1 { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            return StubTransport.response(Data("{}".utf8), status: 201, for: request)
        }
        let account = try await account(transport)
        try await signIn(account)
        let watchedAt = Date(timeIntervalSince1970: 1700000000)
        let movie = TraktWatchedItem(preview: MetaPreview(id: "tt1", type: "movie", name: "Movie"), watchedAt: watchedAt)
        let episode = TraktWatchedItem(preview: MetaPreview(id: "tt2", type: "series", name: "Show"), watchedAt: watchedAt, season: 2, episode: 3)
        try await account.savePlayback(movie, progress: 40)
        try await account.savePlayback(episode, progress: 150)
        try await account.savePlayback(movie, progress: -5)
        let scrobbles = Array(transport.requests.dropFirst())
        #expect(scrobbles.allSatisfy { $0.httpMethod == "POST" && $0.url?.path == "/scrobble/pause" })
        #expect(try scrobbles.map { try canonicalBody($0) } == [
            #"{"movie":{"ids":{"imdb":"tt1"}},"progress":40}"#,
            #"{"episode":{"number":3,"season":2},"progress":100,"show":{"ids":{"imdb":"tt2"}}}"#,
            #"{"movie":{"ids":{"imdb":"tt1"}},"progress":0}"#,
        ])

        let before = transport.callCount
        try await account.savePlayback(TraktWatchedItem(preview: MetaPreview(id: "private-id", type: "movie"), watchedAt: watchedAt), progress: 10)
        try await account.savePlayback(TraktWatchedItem(preview: MetaPreview(id: "tt2", type: "series"), watchedAt: watchedAt, season: 2), progress: 10)
        #expect(transport.callCount == before)
    }

    @Test func savePlaybackTreatsConflictAsSavedAndOtherFailuresAsErrors() async throws {
        let transport = StubTransport { request, call in
            if call == 1 { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            return StubTransport.response(Data(), status: call == 2 ? 409 : 500, for: request)
        }
        let account = try await account(transport)
        try await signIn(account)
        let movie = TraktWatchedItem(preview: MetaPreview(id: "tt1", type: "movie", name: "Movie"), watchedAt: Date(timeIntervalSince1970: 1700000000))
        try await account.savePlayback(movie, progress: 10)
        await #expect(throws: TraktAccountError.network(.http(status: 500))) { try await account.savePlayback(movie, progress: 10) }
    }

    @Test func lastActivitiesTakeTheLatestDatePerGroupAndTolerateMissingSections() async throws {
        let full = #"""
        {"movies":{"watchlisted_at":"2023-11-14T22:13:20.000Z","collected_at":"2023-11-14T22:13:20Z","watched_at":"2023-11-15T00:00:00.000Z","paused_at":"2023-11-16T00:00:00.000Z"},
         "episodes":{"watchlisted_at":"2023-11-10T00:00:00Z","collected_at":"2023-12-01T00:00:00Z","watched_at":"2023-11-20T00:00:00Z","paused_at":"2023-11-01T00:00:00Z"},
         "shows":{"watchlisted_at":"2024-01-01T00:00:00Z"},
         "seasons":{"watchlisted_at":"2023-11-12T00:00:00Z"},
         "watchlist":{"updated_at":"2023-11-11T00:00:00Z"}}
        """#
        let sparse = #"{"watchlist":{"updated_at":"2023-11-11T00:00:00Z"},"movies":{"watched_at":"2023-11-15T00:00:00.000Z"}}"#
        let answers = [full, sparse, "{}", "not json"]
        let transport = StubTransport { request, call in
            if call == 1 { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            return StubTransport.response(Data(answers[call - 2].utf8), for: request)
        }
        let account = try await account(transport)
        try await signIn(account)
        #expect(try await account.lastActivities() == TraktLastActivities(watchlist: Date(timeIntervalSince1970: 1704067200),
                                                                          collection: Date(timeIntervalSince1970: 1701388800),
                                                                          watched: Date(timeIntervalSince1970: 1700438400),
                                                                          playback: Date(timeIntervalSince1970: 1700092800)))
        #expect(transport.requests.last?.url?.path == "/sync/last_activities")
        #expect(try await account.lastActivities() == TraktLastActivities(watchlist: Date(timeIntervalSince1970: 1699660800),
                                                                          watched: Date(timeIntervalSince1970: 1700006400)))
        #expect(try await account.lastActivities() == TraktLastActivities())
        await #expect(throws: TraktAccountError.invalidResponse) { try await account.lastActivities() }
    }

    @Test func onlyTimeoutsOfflineAndBusyOrFailingTraktAreTransient() {
        let transient: [TraktAccountError] = [
            .network(.timeout), .network(.offline), .network(.network("urlerror.-1005")), .network(.cancelled),
            .network(.http(status: 408)), .network(.http(status: 429)), .network(.http(status: 500)), .network(.http(status: 503)),
            .network(.http(status: 599)),
        ]
        let refused: [TraktAccountError] = [
            .network(.http(status: 401)), .network(.http(status: 404)), .network(.http(status: 420)), .network(.http(status: 422)),
            .network(.http(status: 499)), .network(.http(status: 600)), .network(.invalidURL), .network(.invalidJSON),
            .needsCredentials, .needsSignIn, .credentialsChanged, .invalidResponse,
        ]
        for error in transient { #expect(error.isTransient, "\(error) should be transient") }
        for error in refused { #expect(!error.isTransient, "\(error) should not be transient") }
    }
}
// swiftlint:enable line_length
