import Foundation
import Testing
@testable import StremioKit

@Suite final class SyncedWidgetStoreTests {
    /// The shared file both devices see, as a folder in iCloud Drive would be.
    private final class SharedFile: SharedLayoutCopy, @unchecked Sendable {
        private let lock = NSLock()
        private var contents: Data?
        func read() throws -> Data? { lock.withLock { contents } }
        func write(_ data: Data) throws { lock.withLock { contents = data } }
    }

    /// No folder chosen.
    private struct NoFolder: SharedLayoutCopy {
        struct Unreachable: Error {}
        func read() throws -> Data? { throw Unreachable() }
        func write(_ data: Data) throws { throw Unreachable() }
    }

    private var suites: [String] = []

    deinit {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
    }

    /// A throwaway suite for one device, so tests never touch the app's own defaults.
    private func defaults() throws -> UserDefaults {
        let name = "test.\(UUID().uuidString)"
        suites.append(name)
        return try #require(UserDefaults(suiteName: name))
    }

    private func row(_ id: String) -> HomeWidget {
        HomeWidget(id: id, title: id, content: .row(RowConfiguration(source: .traktList(TraktListReference(username: "u", listSlug: id, listName: id)),
            limit: 30)))
    }

    /// A save writes the shared copy in the background; a look from the same device waits for that write.
    private func settle(_ store: SyncedWidgetStore) async {
        _ = await store.takeInSharedLayout()
    }

    @Test func aDeviceJoiningLaterTakesInTheSharedLayoutOverItsOwn() async throws {
        let file = SharedFile()
        let macDefaults = try defaults()
        await DefaultsWidgetStore(defaults: macDefaults).save([row("mac")])
        let phone = SyncedWidgetStore(defaults: try defaults(), shared: file)
        let mac = SyncedWidgetStore(defaults: macDefaults, shared: file)
        await phone.save([row("a"), row("b")])
        await settle(phone)
        let changed = await mac.takeInSharedLayout()
        #expect(changed)
        #expect(await mac.load()?.map(\.id) == ["a", "b"])
    }

    @Test func aLaterSaveOnEitherDeviceReachesTheOther() async throws {
        let file = SharedFile()
        let phone = SyncedWidgetStore(defaults: try defaults(), shared: file)
        let mac = SyncedWidgetStore(defaults: try defaults(), shared: file)
        await phone.save([row("a")])
        await settle(phone)
        _ = await mac.takeInSharedLayout()
        await mac.save([row("c")])
        await settle(mac)
        let changed = await phone.takeInSharedLayout()
        #expect(changed)
        #expect(await phone.load()?.map(\.id) == ["c"])
        let changedAgain = await phone.takeInSharedLayout()
        #expect(!changedAgain, "nothing was saved since")
    }

    @Test func goingBackToTheAutomaticLayoutReachesTheOtherDevice() async throws {
        let file = SharedFile()
        let phone = SyncedWidgetStore(defaults: try defaults(), shared: file)
        let mac = SyncedWidgetStore(defaults: try defaults(), shared: file)
        await phone.save([row("a")])
        await settle(phone)
        _ = await mac.takeInSharedLayout()
        await phone.save(nil)
        await settle(phone)
        let changed = await mac.takeInSharedLayout()
        #expect(changed)
        #expect(await mac.load() == nil)
    }

    @Test func onlyADeviceWithItsOwnLayoutStartsTheSharedLayout() async throws {
        let file = SharedFile()
        let automatic = SyncedWidgetStore(defaults: try defaults(), shared: file)
        _ = await automatic.takeInSharedLayout()
        #expect(try file.read() == nil, "the automatic layout must not reset another device's layout")
        let customisedDefaults = try defaults()
        await DefaultsWidgetStore(defaults: customisedDefaults).save([row("a")])
        let customised = SyncedWidgetStore(defaults: customisedDefaults, shared: file)
        let changed = await customised.takeInSharedLayout()
        #expect(!changed)
        #expect(try file.read() != nil)
    }

    @Test func withNoFolderTheLayoutStaysOnThisDevice() async throws {
        let store = SyncedWidgetStore(defaults: try defaults(), shared: NoFolder())
        await store.save([row("a")])
        let changed = await store.takeInSharedLayout()
        #expect(!changed)
        #expect(await store.load()?.map(\.id) == ["a"])
    }
}
