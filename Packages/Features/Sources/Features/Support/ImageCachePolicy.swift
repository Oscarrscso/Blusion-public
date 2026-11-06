import Foundation

/// How long artwork on disk is kept and when it is checked for a newer copy. There is no expiry: a picture stays on disk until the cache's
/// size limit pushes the least recently used ones out, so posters are not downloaded again every few days on mobile data. A picture that
/// has been on disk a while is checked quietly in the background, with a conditional request that costs almost nothing when it has not
/// changed, and the newer copy is used the next time it is drawn. BetterPosters draws ratings on its posters, which move, so its posters are
/// checked after a day; other artwork rarely changes and is checked after two weeks.
enum ImageCachePolicy {
    /// The disk cache sizes Optimisation offers, in megabytes, and the one used until another is chosen.
    static let diskSizeOptions = [256, 512, 1024, 2048]
    static let defaultDiskMegabytes = 1024
    /// Where the chosen size is kept.
    static let diskMegabytesKey = "imageCache.diskMegabytes"

    /// The disk cache's size in bytes for a saved choice: the default when none is saved, or the saved one is not offered.
    static func diskBytes(forSavedMegabytes saved: Int?) -> Int {
        let megabytes = saved.flatMap { diskSizeOptions.contains($0) ? $0 : nil } ?? defaultDiskMegabytes
        return megabytes * 1024 * 1024
    }

    /// The most decoded pictures kept in memory, in bytes: an eighth of the device's memory, at least 256 MB (the limit this replaced, which
    /// full-resolution episode stills outgrew) and at most 1 GB. Pictures on screen are held by their views as well, so going over it only
    /// drops pictures nothing shows, and they are decoded again from disk when next needed. Without it, a Mac with 8 GB kept every hero
    /// (about 21 MB each at 3072 pixels) and still opened since launch until the whole system ran short of memory.
    /// Optimisation's Picture memory moves it: Low holds a sixteenth (128 MB to 512 MB), High a quarter (512 MB to 2 GB).
    static func decodedBytes(physicalMemory: UInt64, level: Int = OptimisationSettings.defaultPictureMemory) -> Int {
        let megabyte: UInt64 = 1024 * 1024
        let (share, floor, ceiling): (UInt64, UInt64, UInt64) = switch level {
        case 1: (16, 128 * megabyte, 512 * megabyte)
        case 3: (4, 512 * megabyte, 2048 * megabyte)
        default: (8, 256 * megabyte, 1024 * megabyte)
        }
        return Int(min(max(physicalMemory / share, floor), ceiling))
    }

    /// How long a picture from `url` is used before it is checked for a newer copy.
    static func refreshAge(for url: URL) -> TimeInterval {
        url.host?.lowercased().hasSuffix("btttr.cc") == true ? 24 * 60 * 60 : 14 * 24 * 60 * 60
    }

    /// Whether a picture last fetched at `fetched` (the response's Date) is due a check at `now`. A response without a date is checked.
    static func isDueForRefresh(url: URL, fetched: Date?, now: Date = Date()) -> Bool {
        guard let fetched else { return true }
        return now.timeIntervalSince(fetched) >= refreshAge(for: url)
    }

    /// The Date header of an HTTP response ("Wed, 14 Oct 2026 21:00:00 GMT"), or nil.
    static func date(fromHeader value: String?) -> Date? {
        guard let value else { return nil }
        return headerDateFormatter.date(from: value)
    }

    static func header(for date: Date) -> String {
        headerDateFormatter.string(from: date)
    }

    /// One formatter for every picture loaded, so reading a date costs no more than a lookup. `DateFormatter` is Sendable: safe to use
    /// from several threads at once.
    private static let headerDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()
}
