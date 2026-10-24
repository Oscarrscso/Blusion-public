import Foundation

/// Letterboxd's average rating from its public page. Its official API requires approved access; this lookup needs no account.
public struct LetterboxdRatings: Sendable {
    /// `https://letterboxd.com`. The literal always parses; the fallback only avoids a force unwrap, and `AddonClient` refuses non-http URLs.
    public static let defaultBaseURL = URL(string: "https://letterboxd.com") ?? URL(fileURLWithPath: "/")

    private let client: AddonClient
    private let baseURL: URL

    public init(client: AddonClient, baseURL: URL = LetterboxdRatings.defaultBaseURL) {
        self.client = client
        self.baseURL = baseURL
    }

    /// The rating, 0...5, or nil when Letterboxd has no rated film for this IMDb id. A malformed id is nil without a request.
    /// Throws `AddonError` when the request fails.
    public func rating(imdbID: String) async throws -> Double? {
        guard Self.isIMDbID(imdbID) else { return nil }
        guard let url = URL(string: "imdb/\(imdbID)/", relativeTo: baseURL)?.absoluteURL else { throw AddonError.invalidURL }
        let result = try await client.get(url, headers: ["Range": "bytes=0-4095"],
                                          limits: FetchLimits(maxBytes: 8192, truncateAtLimit: true), timeout: 6)
        return Self.parseRating(inPagePrefix: result.data)
    }

    /// True for `tt` followed by 5 to 10 digits: the only ids the lookup asks about.
    public static func isIMDbID(_ id: String) -> Bool {
        id.wholeMatch(of: /tt[0-9]{5,10}/) != nil
    }

    /// The rating in the head of a film page, or nil. Pure, so it is tested without any network.
    /// Reads the `twitter:data2` meta tag whatever its attribute order or quote marks.
    public static func parseRating(inPagePrefix data: Data) -> Double? {
        let page = String(decoding: data, as: UTF8.self)
        for tag in page.matches(of: /<meta\s[^>]*>/) {
            guard tag.output.firstMatch(of: /\sname=["']twitter:data2["']/) != nil else { continue }
            guard let content = tag.output.firstMatch(of: /\scontent=["']([^"']*)["']/)?.output.1 else { return nil }
            return rating(fromContent: content)
        }
        return nil
    }

    /// "4.50 out of 5" or a bare "4.5", within 0...5. Other scales and free text give nil.
    private static func rating(fromContent content: Substring) -> Double? {
        guard let match = content.trimmingCharacters(in: .whitespaces).wholeMatch(of: /([0-9]+(?:\.[0-9]+)?)(?:\s+out\s+of\s+5)?/),
              let value = Double(match.output.1), (0...5).contains(value) else { return nil }
        return value
    }
}
