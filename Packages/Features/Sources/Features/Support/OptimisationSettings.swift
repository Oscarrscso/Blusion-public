import Foundation

/// Settings → Performance: how far ahead Blusion loads, what it readies before it is asked, how much artwork it holds and downloads at
/// once, and whether it does less while the device is in Low Power Mode. Lazy load itself is `LazyLoadLookahead`. Every value is a
/// device-local setting (UserDefaults only, never synced); the Mac reads the same keys. The defaults are the app's behaviour before these
/// settings existed, except saving power, which is on.
enum OptimisationSettings {
    struct Option: Identifiable, Hashable {
        let label: String
        let value: Int
        var id: Int { value }
    }

    // MARK: Home preloading

    /// Titles of the rows below Home's screen loaded before they scroll in (see `HomeViewModel.loadRowsBelow`).
    static let homePreloadKey = "settings.homePreloadTitles"
    /// Home follows the Lazy load slider, as it did before it had a setting of its own.
    static let homePreloadMatchesLazyLoad = -1
    static let homePreloadOptions = [Option(label: "Same as lists", value: homePreloadMatchesLazyLoad), Option(label: "Off", value: 0),
                                     Option(label: "Near · 12 titles", value: 12), Option(label: "Balanced · 24 titles", value: 24),
                                     Option(label: "Far · 48 titles", value: 48)]

    /// Home's titles ahead for a saved choice and Lazy load level, held to Lazy load's nearest while saving power.
    static func homeTitles(saved: Int, level: Int, savesPower: Bool = OptimisationSettings.savesPower()) -> Int {
        let titles = saved == homePreloadMatchesLazyLoad ? LazyLoadLookahead.titles(atLevel: level) : max(0, saved)
        return savesPower ? min(titles, LazyLoadLookahead.levels[0].titles) : titles
    }

    static func homeTitlesAhead(in defaults: UserDefaults = .standard) -> Int {
        homeTitles(saved: defaults.object(forKey: homePreloadKey) as? Int ?? homePreloadMatchesLazyLoad,
                   level: LazyLoadLookahead.level(in: defaults), savesPower: savesPower(in: defaults))
    }

    // MARK: Streams

    /// A title page looks up the Play button's streams as it opens, so Play starts sooner.
    static let prefetchesStreamsKey = "settings.prefetchesStreams"
    /// The stream picker readies the first stream listed in the background, muted and paused, in case it is the one played.
    static let readiesFirstStreamKey = "settings.readiesFirstStream"

    static func prefetchesStreams(in defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: prefetchesStreamsKey) as? Bool ?? true) && !savesPower(in: defaults)
    }

    static func readiesFirstStream(in defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: readiesFirstStreamKey) as? Bool ?? true) && !savesPower(in: defaults)
    }

    // MARK: Pictures

    /// How much decoded artwork is held in memory (see `ImageCachePolicy.decodedBytes`).
    static let pictureMemoryKey = "imageCache.memoryLevel"
    static let defaultPictureMemory = 2
    static let pictureMemoryOptions = [Option(label: "Low", value: 1), Option(label: "Balanced", value: 2), Option(label: "High", value: 3)]

    static func pictureMemory(in defaults: UserDefaults = .standard) -> Int {
        let saved = defaults.object(forKey: pictureMemoryKey) as? Int ?? defaultPictureMemory
        return pictureMemoryOptions.contains { $0.value == saved } ? saved : defaultPictureMemory
    }

    /// How many pictures download at once. A title's logo may take one more, so it never waits behind posters.
    static let downloadSlotsKey = "imageCache.downloadSlots"
    static let defaultDownloadSlots = 5
    static let downloadSlotOptions = [Option(label: "3", value: 3), Option(label: "5", value: 5), Option(label: "8", value: 8)]
    /// The most pictures at once while saving power.
    static let powerSavingDownloadSlots = 3

    static func downloadSlots(in defaults: UserDefaults = .standard) -> Int {
        let saved = defaults.object(forKey: downloadSlotsKey) as? Int ?? defaultDownloadSlots
        let slots = downloadSlotOptions.contains { $0.value == saved } ? saved : defaultDownloadSlots
        return savesPower(in: defaults) ? min(slots, powerSavingDownloadSlots) : slots
    }

    // MARK: Power

    /// While the device is in Low Power Mode, Lazy load and Home keep their nearest, nothing is readied early and fewer pictures download
    /// at once.
    static let savesPowerKey = "settings.savesPowerInLowPowerMode"

    static func savesPowerInLowPowerMode(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: savesPowerKey) as? Bool ?? true
    }

    /// True while Low Power Mode is on and the setting saves power then.
    static func savesPower(in defaults: UserDefaults = .standard) -> Bool {
        savesPowerInLowPowerMode(in: defaults) && ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    // MARK: All of them

    static let allKeys = [LazyLoadLookahead.defaultsKey, homePreloadKey, prefetchesStreamsKey, readiesFirstStreamKey, pictureMemoryKey,
                          downloadSlotsKey, savesPowerKey]
}
