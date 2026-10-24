import Foundation

public struct SubtitleItem: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var id: String
    public var url: URL
    /// Usually ISO 639-2 (`eng`), sometimes ISO 639-1 (`en`) or a free-form name.
    public var lang: String

    public init(id: String, url: URL, lang: String) {
        self.id = id
        self.url = url
        self.lang = lang
    }

    private enum Keys: String, CodingKey { case id, url, lang }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        guard let url = container.url(.url) else { throw DroppedItem(reason: "subtitle without url") }
        let lang = container.string(.lang) ?? "und"
        self.init(id: container.string(.id) ?? url.absoluteString, url: url, lang: lang)
    }
}
