// swiftlint:disable line_length
import Foundation
import Testing
import PlayerKit
import StremioKit
import StremioKitTestSupport
@testable import Features

@MainActor
@Suite struct TraktAccountViewModelTests {
    private let when = Date(timeIntervalSince1970: 1700000000)
    private let codeJSON = #"{"device_code":"device","user_code":"ABCD1234","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":5}"#
    private let tokenJSON = #"{"access_token":"access","refresh_token":"refresh","expires_in":604800,"created_at":1700000000}"#
    /// Trakt's change dates: everything changed on 2024-01-01, so a forced sync reads every list.
    private let activitiesJSON = #"{"movies":{"watched_at":"2024-01-01T00:00:00.000Z","watchlisted_at":"2024-01-01T00:00:00.000Z","collected_at":"2024-01-01T00:00:00.000Z"}}"#

    private func services(transport: StubTransport, library: [LibraryItem] = [], progress: [WatchProgress] = [],
                          clientID: String = "test-client") async throws -> AppServices {
        let client = makeClient(StubTransport(data: Data()))
        let registry = AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client)
        let settings = InMemorySettingsStore(PlaybackSettings(traktClientID: clientID))
        let account = TraktAccount(settings: settings, secrets: InMemorySecretStore(), transport: transport, now: { Date(timeIntervalSince1970: 1700000001) })
        try await account.saveClientSecret("secret")
        let code = try JSONDecoder().decode(TraktDeviceCode.self, from: Data(codeJSON.utf8))
        _ = try await account.checkAuthorization(code)
        return AppServices(registry: registry, client: client, settings: settings, progress: InMemoryProgressStore(progress),
                           library: InMemoryLibraryStore(library), traktAccount: account)
    }

    @Test func loadKeepsTheExistingConfiguredClientID() async throws {
        let services = try await services(transport: StubTransport(data: Data(tokenJSON.utf8)))
        var settings = await services.settings.load()
        settings.preferredResolution = 1080
        await services.settings.save(settings)
        let model = TraktAccountViewModel(services: services)
        await model.load()
        #expect(model.isSignedIn && model.isAvailable && model.canSignIn)
        let saved = await services.settings.load()
        #expect(saved.traktClientID == "test-client" && saved.preferredResolution == 1080)
    }

    @Test func aPreviouslyConfiguredClientIDIsPreservedWithItsSignIn() async throws {
        let services = try await services(transport: StubTransport(data: Data(tokenJSON.utf8)), clientID: "client")
        let model = TraktAccountViewModel(services: services)
        await model.load()
        #expect(model.isSignedIn)
        let saved = await services.settings.load()
        #expect(saved.traktClientID == "client")
    }

    @Test func importAddsMissingItemsAndKeepsSavedTitlesAndPlaybackPositions() async throws {
        let tokenJSON = tokenJSON
        let activitiesJSON = activitiesJSON
        let transport = StubTransport { request, _ in
            if request.url?.path == "/oauth/device/token" { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            if request.url?.path == "/sync/last_activities" { return StubTransport.response(Data(activitiesJSON.utf8), for: request) }
            if request.url?.path == "/sync/watchlist" {
                let payload = #"[{"movie":{"title":"Remote","ids":{"imdb":"tt2"}}},{"movie":{"title":"Remote copy","ids":{"imdb":"tt1"}}}]"#
                return StubTransport.response(Data(payload.utf8), for: request)
            }
            if request.url?.path.hasPrefix("/sync/collection/") == true {
                return StubTransport.response(Data("[]".utf8), for: request)
            }
            if request.url?.path == "/sync/watched/movies" {
                let payload = #"[{"movie":{"title":"Remote","ids":{"imdb":"tt2"}},"last_watched_at":"2023-11-14T22:13:20.000Z"}]"#
                return StubTransport.response(Data(payload.utf8), for: request)
            }
            let payload = #"[{"show":{"title":"Series","ids":{"imdb":"tt3"}},"seasons":[{"number":1,"#
                + #""episodes":[{"number":2,"last_watched_at":"2023-11-14T22:13:20Z"}]}]}]"#
            return StubTransport.response(Data(payload.utf8), for: request)
        }
        let saved = LibraryItem(preview: MetaPreview(id: "tt1", type: "movie", name: "Local title"), addedAt: when)
        let partial = WatchProgress(id: "movie/tt2", type: "movie", contentID: "tt2", title: "Local movie", position: 50, duration: 100,
                                    isWatched: false, updatedAt: when)
        let services = try await services(transport: transport, library: [saved], progress: [partial])
        let model = TraktAccountViewModel(services: services)
        await model.importFromTrakt()
        #expect(model.errorMessage == nil)
        #expect(model.message == "Imported 1 saved titles and 2 watched items from Trakt.")
        let library = await services.library.all()
        #expect(Set(library.map(\.id)) == ["movie/tt1", "movie/tt2"])
        #expect(library.first(where: { $0.id == saved.id })?.name == "Local title")
        let progress = await services.progress.progress(for: partial.id)
        #expect(progress?.isWatched == true && progress?.position == 50 && progress?.duration == 100 && progress?.title == "Local movie")
        let episode = await services.progress.progress(for: "series/tt3:1:2")
        #expect(episode?.isWatched == true && episode?.season == 1 && episode?.episode == 2)
        await model.importFromTrakt()
        #expect(model.message == "Imported 0 saved titles and 0 watched items from Trakt.")
    }

    @Test func exportSkipsExistingWatchesAndUnsupportedIDs() async throws {
        let tokenJSON = tokenJSON
        let activitiesJSON = activitiesJSON
        let transport = StubTransport { request, _ in
            if request.url?.path == "/oauth/device/token" { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            if request.url?.path == "/sync/last_activities" { return StubTransport.response(Data(activitiesJSON.utf8), for: request) }
            if request.httpMethod == "POST" {
                let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
                let movies = try #require(body["movies"] as? [[String: Any]])
                #expect(movies.count == 1 && (movies[0]["ids"] as? [String: String])?["imdb"] == "tt2")
                return StubTransport.response(Data(#"{"added":{"movies":1,"episodes":0}}"#.utf8), status: 201, for: request)
            }
            if request.url?.path == "/sync/watched/shows" { return StubTransport.response(Data("[]".utf8), for: request) }
            return StubTransport.response(Data(#"[{"movie":{"title":"Existing","ids":{"imdb":"tt1"}},"last_watched_at":"2023-11-14T22:13:20Z"}]"#.utf8), for: request)
        }
        let library = ["tt1", "tt2", "private-id"].map { LibraryItem(preview: MetaPreview(id: $0, type: "movie", name: $0), addedAt: when) }
        let progress = ["tt1", "tt2", "private-id"].map {
            WatchProgress(id: "movie/\($0)", type: "movie", contentID: $0, title: $0, position: 0, duration: 0, isWatched: true, updatedAt: when)
        }
        let services = try await services(transport: transport, library: library, progress: progress)
        let model = TraktAccountViewModel(services: services)
        await model.sendToTrakt()
        #expect(model.errorMessage == nil && model.message == "Sent 1 saved titles and 1 watched items to Trakt.")
        #expect(transport.requests.filter { $0.httpMethod == "POST" }.map { $0.url?.path } == ["/oauth/device/token", "/sync/watchlist", "/sync/history"])
        #expect(await services.library.all().count == 3)
        #expect(await services.progress.all().count == 3)
    }

    @Test func collectionAndWatchlistMergeWithoutDuplicatesOrMarkingCollectedTitlesWatched() async throws {
        let tokenJSON = tokenJSON
        let activitiesJSON = activitiesJSON
        let transport = StubTransport { request, _ in
            if request.url?.path == "/oauth/device/token" { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            if request.url?.path == "/sync/last_activities" { return StubTransport.response(Data(activitiesJSON.utf8), for: request) }
            if request.url?.path == "/sync/watchlist" {
                return StubTransport.response(Data(#"[{"movie":{"title":"Watch later","ids":{"imdb":"tt1"}}}]"#.utf8), for: request)
            }
            if request.url?.path == "/sync/collection/movies" {
                let payload = #"[{"movie":{"title":"Duplicate","ids":{"imdb":"tt1"}}},{"movie":{"title":"Owned movie","ids":{"imdb":"tt2"}}}]"#
                return StubTransport.response(Data(payload.utf8), for: request)
            }
            if request.url?.path == "/sync/collection/shows" {
                return StubTransport.response(Data(#"[{"show":{"title":"Owned show","ids":{"imdb":"tt3"}}}]"#.utf8), for: request)
            }
            return StubTransport.response(Data("[]".utf8), for: request)
        }
        let services = try await services(transport: transport)
        let model = TraktAccountViewModel(services: services)
        await model.importFromTrakt()
        #expect(model.errorMessage == nil && model.message == "Imported 3 saved titles and 0 watched items from Trakt.")
        let saved = await services.library.all()
        #expect(Set(saved.map(\.id)) == ["movie/tt1", "movie/tt2", "series/tt3"])
        #expect(saved.first(where: { $0.id == "movie/tt1" })?.name == "Watch later")
        #expect(await services.progress.all().isEmpty)
        await model.importFromTrakt()
        #expect(model.message == "Imported 0 saved titles and 0 watched items from Trakt.")
    }

    @Test func failedCollectionFetchDoesNotPartiallyImportTheWatchlist() async throws {
        let tokenJSON = tokenJSON
        let activitiesJSON = activitiesJSON
        let transport = StubTransport { request, _ in
            if request.url?.path == "/oauth/device/token" { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            if request.url?.path == "/sync/last_activities" { return StubTransport.response(Data(activitiesJSON.utf8), for: request) }
            if request.url?.path == "/sync/watchlist" {
                return StubTransport.response(Data(#"[{"movie":{"title":"Watch later","ids":{"imdb":"tt1"}}}]"#.utf8), for: request)
            }
            return StubTransport.response(Data(), status: 503, for: request)
        }
        let services = try await services(transport: transport)
        let model = TraktAccountViewModel(services: services)
        await model.importFromTrakt()
        #expect(model.errorMessage != nil && model.message == nil)
        #expect(await services.library.all().isEmpty)
        #expect(await services.progress.all().isEmpty)
    }

    @Test func emptyLibraryRefreshImportsTraktWithoutSigningOut() async throws {
        let tokenJSON = tokenJSON
        let activitiesJSON = activitiesJSON
        let transport = StubTransport { request, _ in
            if request.url?.path == "/oauth/device/token" { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            if request.url?.path == "/sync/last_activities" { return StubTransport.response(Data(activitiesJSON.utf8), for: request) }
            if request.url?.path == "/sync/watchlist" {
                return StubTransport.response(Data(#"[{"movie":{"title":"Remote","ids":{"imdb":"tt1"}}}]"#.utf8), for: request)
            }
            if request.url?.path == "/sync/collection/shows" {
                return StubTransport.response(Data(#"[{"show":{"title":"Owned show","ids":{"imdb":"tt2"}}}]"#.utf8), for: request)
            }
            if request.url?.path == "/sync/watched/movies" {
                return StubTransport.response(Data(#"[{"movie":{"title":"Watched","ids":{"imdb":"tt3"}},"last_watched_at":"2023-11-14T22:13:20Z"}]"#.utf8), for: request)
            }
            return StubTransport.response(Data("[]".utf8), for: request)
        }
        let services = try await services(transport: transport)
        let model = LibraryViewModel(services: services)
        await model.refresh(now: when)
        #expect(Set(model.saved.map(\.id)) == ["movie/tt1", "series/tt2"])
        #expect(model.watched.map(\.id) == ["movie/tt3"])
        #expect(await services.traktAccount.isSignedIn())

        let calls = transport.callCount
        model.filter.kinds = [.anime]
        #expect(!model.hasMatches && !model.isEmpty)
        await model.refresh(now: when.addingTimeInterval(600))
        #expect(transport.callCount == calls, "a filter with no matches must not trigger another import")
    }

    @Test func emptyLibraryRetriesFailedTraktImportsAfterFiveMinutes() async throws {
        let tokenJSON = tokenJSON
        let activitiesJSON = activitiesJSON
        let watchlistCalls = CallCounter()
        let transport = StubTransport { request, _ in
            if request.url?.path == "/oauth/device/token" { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            if request.url?.path == "/sync/last_activities" { return StubTransport.response(Data(activitiesJSON.utf8), for: request) }
            if request.url?.path == "/sync/watchlist" {
                // Only the first read of the watchlist fails: the import before the five minutes have passed.
                if watchlistCalls.next() == 1 { return StubTransport.response(Data(), status: 503, for: request) }
                return StubTransport.response(Data(#"[{"movie":{"title":"Recovered","ids":{"imdb":"tt1"}}}]"#.utf8), for: request)
            }
            return StubTransport.response(Data("[]".utf8), for: request)
        }
        let model = LibraryViewModel(services: try await services(transport: transport))
        await model.refresh(now: when)
        #expect(model.isEmpty && model.hasLoaded)
        let calls = transport.callCount
        await model.refresh(now: when.addingTimeInterval(299))
        #expect(transport.callCount == calls)
        await model.refresh(now: when.addingTimeInterval(300))
        #expect(model.saved.map(\.id) == ["movie/tt1"])
        #expect(transport.requests.filter { $0.url?.path == "/sync/watchlist" }.count == 2)
    }

    @Test func signedOutEmptyLibraryDoesNotTryToImportTrakt() async throws {
        let transport = StubTransport(data: Data(tokenJSON.utf8))
        let services = try await services(transport: transport)
        await services.traktAccount.signOut()
        let calls = transport.callCount
        let model = LibraryViewModel(services: services)
        await model.refresh(now: when)
        #expect(model.isEmpty && model.hasLoaded)
        #expect(transport.callCount == calls)
    }

    @Test func signOutKeepsLocalLibraryAndHistory() async throws {
        let saved = LibraryItem(preview: MetaPreview(id: "tt1", type: "movie", name: "Movie"), addedAt: when)
        let services = try await services(transport: StubTransport(data: Data(tokenJSON.utf8)), library: [saved])
        let model = TraktAccountViewModel(services: services)
        await model.load()
        #expect(model.isSignedIn)
        await model.signOut()
        #expect(!model.isSignedIn && model.errorMessage == nil)
        #expect(await services.library.all() == [saved])
    }

    @Test func aTitleThatLeftTraktIsRemovedHereAndSaidSo() async throws {
        let tokenJSON = tokenJSON
        let activitiesJSON = activitiesJSON
        let watchlistCalls = CallCounter()
        let transport = StubTransport { request, _ in
            if request.url?.path == "/oauth/device/token" { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            if request.url?.path == "/sync/last_activities" { return StubTransport.response(Data(activitiesJSON.utf8), for: request) }
            if request.url?.path == "/sync/watchlist" {
                // Two titles on the first read; by the second, Trakt has removed the second.
                let payload = watchlistCalls.next() == 1
                    ? #"[{"movie":{"title":"One","ids":{"imdb":"tt1"}}},{"movie":{"title":"Two","ids":{"imdb":"tt2"}}}]"#
                    : #"[{"movie":{"title":"One","ids":{"imdb":"tt1"}}}]"#
                return StubTransport.response(Data(payload.utf8), for: request)
            }
            return StubTransport.response(Data("[]".utf8), for: request)
        }
        let services = try await services(transport: transport)
        let model = TraktAccountViewModel(services: services)
        await model.importFromTrakt()
        #expect(model.message == "Imported 2 saved titles and 0 watched items from Trakt.")
        await model.importFromTrakt()
        #expect(model.errorMessage == nil)
        #expect(model.message == "Imported 0 saved titles and 0 watched items from Trakt. "
                + "Removed 1 saved titles and 0 watched marks that were removed on Trakt.")
        #expect(Set(await services.library.all().map(\.id)) == ["movie/tt1"])
    }

    @Test func aSendThatFailsStaysQueuedAndIsCounted() async throws {
        let tokenJSON = tokenJSON
        let activitiesJSON = activitiesJSON
        let transport = StubTransport { request, _ in
            if request.url?.path == "/oauth/device/token" { return StubTransport.response(Data(tokenJSON.utf8), for: request) }
            if request.url?.path == "/sync/last_activities" { return StubTransport.response(Data(activitiesJSON.utf8), for: request) }
            if request.httpMethod == "POST" { return StubTransport.response(Data(), status: 503, for: request) }
            return StubTransport.response(Data("[]".utf8), for: request)
        }
        let saved = LibraryItem(preview: MetaPreview(id: "tt2", type: "movie", name: "Two"), addedAt: when)
        let services = try await services(transport: transport, library: [saved])
        let model = TraktAccountViewModel(services: services)
        await model.load()
        #expect(model.pendingCount == 0)
        await model.sendToTrakt()
        #expect(model.message == nil && model.errorMessage != nil)
        #expect(model.pendingCount == 1, "the saved title is still waiting to reach Trakt")
        #expect(await services.library.all() == [saved])
    }
}

/// Counts calls, so a stub can answer the first call differently from the later ones.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Counts one more call and returns how many there have been, this one included.
    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
// swiftlint:enable line_length
