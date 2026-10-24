import Foundation

/// A title the user saved. Carries enough of the catalog preview to draw a poster without asking an addon again.
public struct LibraryItem: Sendable, Codable, Equatable, Identifiable {
    /// `type/contentID`, e.g. `movie/tt1`.
    public var id: String
    public var type: String
    public var contentID: String
    public var name: String
    public var poster: URL?
    public var releaseInfo: String?
    public var addedAt: Date
    /// Genre names as the addon sent them at save time. Empty for titles saved before genres were kept.
    public var genres: [String]
    /// The addon's IMDb rating at save time, when it sent one.
    public var imdbRating: Double?

    public init(id: String, type: String, contentID: String, name: String, poster: URL? = nil, releaseInfo: String? = nil, addedAt: Date,
                genres: [String] = [], imdbRating: Double? = nil) {
        self.id = id
        self.type = type
        self.contentID = contentID
        self.name = name
        self.poster = poster
        self.releaseInfo = releaseInfo
        self.addedAt = addedAt
        self.genres = genres
        self.imdbRating = imdbRating
    }

    public init(preview: MetaPreview, addedAt: Date = Date()) {
        let type = preview.type.isEmpty ? "movie" : preview.type
        self.init(id: Self.identity(type: type, contentID: preview.id), type: type, contentID: preview.id, name: preview.name,
                  poster: preview.poster, releaseInfo: preview.releaseInfo, addedAt: addedAt, genres: preview.genres,
                  imdbRating: preview.imdbRating)
    }

    public static func identity(type: String, contentID: String) -> String { "\(type)/\(contentID)" }

    /// A preview good enough to open Detail.
    public var preview: MetaPreview {
        MetaPreview(id: contentID, type: type, name: name, poster: poster, releaseInfo: releaseInfo, imdbRating: imdbRating, genres: genres)
    }

    private enum CodingKeys: String, CodingKey { case id, type, contentID, name, poster, releaseInfo, addedAt, genres, imdbRating }

    /// Items encoded before genres and ratings were kept decode with none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(String.self, forKey: .id), type: try container.decode(String.self, forKey: .type),
                  contentID: try container.decode(String.self, forKey: .contentID), name: try container.decode(String.self, forKey: .name),
                  poster: try container.decodeIfPresent(URL.self, forKey: .poster),
                  releaseInfo: try container.decodeIfPresent(String.self, forKey: .releaseInfo),
                  addedAt: try container.decode(Date.self, forKey: .addedAt),
                  genres: try container.decodeIfPresent([String].self, forKey: .genres) ?? [],
                  imdbRating: try container.decodeIfPresent(Double.self, forKey: .imdbRating))
    }
}

public protocol LibraryStore: Sendable {
    /// Most recently added first.
    func all() async -> [LibraryItem]
    func contains(_ id: String) async -> Bool
    func add(_ item: LibraryItem) async
    func add(_ items: [LibraryItem]) async
    func remove(_ id: String) async
    func clear() async
}

public extension LibraryStore {
    func add(_ items: [LibraryItem]) async { for item in items { await add(item) } }
}

public actor InMemoryLibraryStore: LibraryStore {
    private var items: [String: LibraryItem] = [:]

    public init(_ initial: [LibraryItem] = []) {
        for item in initial { items[item.id] = item }
    }

    public func all() async -> [LibraryItem] { items.values.sorted { $0.addedAt > $1.addedAt } }
    public func contains(_ id: String) async -> Bool { items[id] != nil }
    public func add(_ item: LibraryItem) async { items[item.id] = item }
    public func add(_ additions: [LibraryItem]) async { for item in additions { items[item.id] = item } }
    public func remove(_ id: String) async { items[id] = nil }
    public func clear() async { items = [:] }
}
