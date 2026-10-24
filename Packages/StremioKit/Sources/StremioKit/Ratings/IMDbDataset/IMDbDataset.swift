import Foundation

/// One title's row of IMDb's `title.ratings.tsv.gz`: the average rating out of 10 and the number of votes behind it.
public struct IMDbRating: Sendable, Equatable {
    public let imdbID: String
    public let rating: Double
    public let votes: Int

    public init(imdbID: String, rating: Double, votes: Int) {
        self.imdbID = imdbID
        self.rating = rating
        self.votes = votes
    }
}

/// What the local copy of the dataset holds, for Settings.
public struct IMDbDatasetStatus: Sendable, Equatable {
    public var titleCount: Int
    /// When new data was last installed.
    public var updatedAt: Date?
    /// When the server last confirmed that this copy is the current one.
    public var checkedAt: Date?
    /// Bytes the database takes on disk, its `-wal` and `-shm` files included. Nil when the files can't be read.
    public var fileSize: Int64?

    public init(titleCount: Int, updatedAt: Date?, checkedAt: Date?, fileSize: Int64? = nil) {
        self.titleCount = titleCount
        self.updatedAt = updatedAt
        self.checkedAt = checkedAt
        self.fileSize = fileSize
    }
}

/// How one `refreshIfNeeded` call ended.
public enum IMDbDatasetRefresh: Sendable, Equatable {
    /// Checked less than a day ago, a failed attempt is being waited out, or another refresh is running.
    case skipped
    /// The server said the local copy is still current.
    case notModified
    /// A new copy replaced the old one.
    case updated(titles: Int)
    case episodeIndexUpdated
    /// Nothing changed: the old copy (if any) is still in use.
    case failed(String)
}

/// IMDb's public ratings dataset, kept on the device. Lookups never touch the network.
///
/// The data is IMDb's, supplied for personal and non-commercial use (https://developer.imdb.com/non-commercial-datasets/). It stays in
/// the app's own storage, out of backups, and is never shared or redistributed.
public protocol IMDbDataset: Sendable {
    func rating(for imdbID: String) async -> IMDbRating?
    func episodeIDs(for seriesID: String, season: Int) async -> [Int: String]
    func status() async -> IMDbDatasetStatus?
    /// Downloads a newer copy when the last check is over a day old. Safe to call often; it returns at once when nothing is due.
    func refreshIfNeeded() async -> IMDbDatasetRefresh
}

public extension IMDbDataset {
    func episodeIDs(for seriesID: String, season: Int) async -> [Int: String] { [:] }
}

/// The words IMDb asks for next to its data, and the terms the data comes with.
public enum IMDbAttribution {
    public static let notice = "Information courtesy of IMDb (https://www.imdb.com)."
    public static let terms = "IMDb ratings are used for personal, non-commercial purposes only, under IMDb's conditions of use."
    public static let url = URL(string: "https://www.imdb.com")
    public static let termsURL = URL(string: "https://developer.imdb.com/non-commercial-datasets/")
}
