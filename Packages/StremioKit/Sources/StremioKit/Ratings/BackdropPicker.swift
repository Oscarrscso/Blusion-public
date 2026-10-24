import Foundation

/// A backdrop a metadata service offers for a title, with the fields `BackdropPicker` ranks it by.
public struct BackdropCandidate: Sendable, Hashable {
    public let url: URL
    /// The ISO 639-1 language tag. Nil for a textless image.
    public let language: String?
    public let voteAverage: Double?
    public let voteCount: Int?
    public let width: Int?

    public init(url: URL, language: String?, voteAverage: Double?, voteCount: Int?, width: Int?) {
        self.url = url
        self.language = language
        self.voteAverage = voteAverage
        self.voteCount = voteCount
        self.width = width
    }
}

/// Chooses the hero backdrop of a title. Textless images come first, since a title card with words on it makes a poor hero. English-tagged
/// images follow, then any other language. Within a tier the highest rated wins, ties go to the most votes, then the widest image.
/// The answer does not depend on the order of the candidates.
public enum BackdropPicker {
    /// The URL of the best candidate, or nil when there are none. Callers fall back to their default artwork then.
    public static func best(_ candidates: [BackdropCandidate]) -> URL? {
        candidates.min { lhs, rhs in
            let a = rank(lhs), b = rank(rhs)
            if a.tier != b.tier { return a.tier < b.tier }
            if a.rating != b.rating { return a.rating > b.rating }
            if a.votes != b.votes { return a.votes > b.votes }
            if a.width != b.width { return a.width > b.width }
            return lhs.url.absoluteString < rhs.url.absoluteString
        }?.url
    }

    /// Lower tiers are better: 0 textless, 1 English, 2 any other language. A missing or non-finite rating counts as 0.
    private static func rank(_ candidate: BackdropCandidate) -> (tier: Int, rating: Double, votes: Int, width: Int) {
        let tag = candidate.language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let tier = tag.isEmpty ? 0 : (tag == "en" ? 1 : 2)
        let rating: Double
        if let average = candidate.voteAverage, average.isFinite { rating = average } else { rating = 0 }
        return (tier, rating, candidate.voteCount ?? 0, candidate.width ?? 0)
    }
}
