import Foundation

/// The release filter of a TMDB widget picks whole years. Its From is 1 January of the year picked and its To is 31 December of it, saved as
/// "yyyy-MM-dd" as before, so TMDB is asked exactly as it was. A widget saved with other days keeps them, and shows their year, until its
/// filter is changed.
enum ReleaseYears {
    /// The first year offered: TMDB's oldest films are from the 1870s.
    static let firstYear = 1874
    /// How many years past this one are offered, for titles announced ahead.
    static let yearsAhead = 10

    /// The year a "yyyy-MM-dd" date names, or nil for any other text.
    static func year(of text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let year = Int(parts[0]), Int(parts[1]) != nil, Int(parts[2]) != nil else { return nil }
        return year
    }

    /// The From date for `year`: its first day.
    static func from(_ year: Int) -> String { String(format: "%04ld-01-01", year) }

    /// The To date for `year`: its last day.
    static func to(_ year: Int) -> String { String(format: "%04ld-12-31", year) }

    /// The date to save when `picked` is chosen for an end that shows `shown`. Nil when it is the year already shown, so a saved day is kept
    /// until another year is picked.
    static func edit(shown: Int, picked: Int, date: (Int) -> String) -> String? {
        picked == shown ? nil : date(picked)
    }

    /// The year it is now, in the Gregorian calendar, so the locale cannot change it.
    static func current(now: Date = Date()) -> Int {
        Calendar(identifier: .gregorian).component(.year, from: now)
    }

    /// The years to choose from, newest first: from the first year to some years ahead, and a saved year outside them as well.
    static func offered(now: Date = Date(), including saved: Int? = nil) -> [Int] {
        var years = Array(firstYear...(current(now: now) + yearsAhead))
        if let saved, !years.contains(saved) { years.append(saved) }
        return years.sorted(by: >)
    }

    /// The years as a widget's description says them: "2010 to 2020", "in 2015", "from 2010" or "up to 2020". Nil when neither is set. Text
    /// that is not a date is said as it is.
    static func text(from: String?, to: String?) -> String? {
        let low = from.map { year(of: $0).map(String.init) ?? $0 }
        let high = to.map { year(of: $0).map(String.init) ?? $0 }
        switch (low, high) {
        case let (low?, high?): return low == high ? "in \(low)" : "\(low) to \(high)"
        case let (low?, nil): return "from \(low)"
        case let (nil, high?): return "up to \(high)"
        case (nil, nil): return nil
        }
    }
}
