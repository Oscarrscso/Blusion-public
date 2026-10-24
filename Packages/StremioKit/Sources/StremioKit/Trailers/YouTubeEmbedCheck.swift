import Foundation

/// Asks YouTube, before a player is made, whether a video may be played in an embedded player, and how its picture is shaped. It reads
/// YouTube's public oEmbed answer for the video, which needs no key.
public struct YouTubeEmbedCheck: Sendable {
    /// What YouTube says about one video.
    public struct Answer: Sendable, Equatable {
        /// False only when YouTube says the video cannot be embedded or is not there. True when it can be embedded, and also when no answer
        /// could be had, so the player itself decides.
        public let allowsEmbedding: Bool
        /// The picture's width over its height as YouTube gives it, nil when YouTube gave none.
        public let aspectRatio: Double?

        public init(allowsEmbedding: Bool, aspectRatio: Double? = nil) {
            self.allowsEmbedding = allowsEmbedding
            self.aspectRatio = aspectRatio
        }
    }

    let client: AddonClient

    public init(client: AddonClient) { self.client = client }

    /// False only when YouTube says the video cannot be embedded or is not there: 400, 401, 403 or 404. True when it can be embedded,
    /// and also when no answer could be had (offline, a timeout, any other failure), so the player itself decides.
    public func allowsEmbedding(videoID: String) async -> Bool {
        await check(videoID: videoID).allowsEmbedding
    }

    /// Whether the video may be embedded (see `allowsEmbedding(videoID:)`), and the shape of its picture when YouTube's answer has one.
    public func check(videoID: String) async -> Answer {
        guard let url = Self.url(videoID: videoID) else { return Answer(allowsEmbedding: false) }
        do {
            let result = try await client.get(url, headers: [:], limits: FetchLimits(maxBytes: 64 * 1024, maxRedirects: 2), timeout: 5)
            return Answer(allowsEmbedding: true, aspectRatio: Self.aspectRatio(from: result.data))
        } catch {
            guard let addonError = error as? AddonError else { return Answer(allowsEmbedding: true) }
            switch addonError {
            case .notFound: return Answer(allowsEmbedding: false)
            case .http(let status): return Answer(allowsEmbedding: ![400, 401, 403, 404].contains(status))
            default: return Answer(allowsEmbedding: true)
            }
        }
    }

    /// The picture's width over its height from an oEmbed answer, which gives the player's `width` and `height` as numbers (or as numeric
    /// text). Nil when either is missing, not a number, or not greater than zero.
    static func aspectRatio(from data: Data) -> Double? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let width = number(object["width"]), let height = number(object["height"]),
              width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return width / height
    }

    /// A JSON number, or text that holds one.
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// The oEmbed address for a video, or nil unless `videoID` is a well-formed YouTube id (`Trailer.isYouTubeID`):
    /// `https://www.youtube.com/oembed?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3D<id>&format=json`.
    static func url(videoID: String) -> URL? {
        guard Trailer.isYouTubeID(videoID) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/oembed"
        // The watch address goes in as one percent-encoded value. The id is already known to hold only plain characters.
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "url", value: "https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3D\(videoID)"),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components.url
    }
}
