import Foundation

/// How long artwork on disk is kept and when it is checked for a newer copy. There is no expiry: a picture stays on disk until the cache's
/// size limit pushes the least recently used ones out, so posters are not downloaded again every few days on mobile data. A picture that
/// has been on disk a while is checked quietly in the background, with a conditional request that costs almost nothing when it has not
/// changed, and the newer copy is used the next time it is drawn. BetterPosters draws ratings on its posters, which move, so its posters are
/// checked after a day; other artwork rarely changes and is checked after two weeks.
enum ImageCachePolicy {
    /// The disk cache sizes the Image cache page offers, in megabytes, and the one used until another is chosen.
    static let diskSizeOptions = [256, 512, 1024, 2048]
    static let defaultDiskMegabytes = 1024
    /// Where the chosen size is kept.
    static let diskMegabytesKey = "imageCache.diskMegabytes"

    /// The disk cache's size in bytes for a saved choice: the default when none is saved, or the saved one is not offered.
    static func diskBytes(forSavedMegabytes saved: Int?) -> Int {
        let megabytes = saved.flatMap { diskSizeOptions.contains($0) ? $0 : nil } ?? defaultDiskMegabytes
        return megabytes * 1024 * 1024
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
