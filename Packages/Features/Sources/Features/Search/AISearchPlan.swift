import Foundation
import StremioKit

/// A bounded set of database searches, not titles invented by the language model.
public struct AISearchPlan: Sendable, Equatable {
    public struct Person: Sendable, Equatable {
        public enum Role: String, Sendable { case cast, director, writer, creator }
        public var name: String
        public var role: Role
        public init(name: String, role: Role) { self.name = name; self.role = role }
    }

    public var filters: DescribedSearch
    public var titleQueries: [String]
    public var referenceTitles: [String]
    public var people: [Person]
    public var companies: [String]
    public var language: String?
    public var excludedTopics: [String]
    public var requiresSemanticRanking: Bool
    public var unwatchedOnly: Bool
    /// The lexical fallback can still find factual matches, but an inference failure must remain retryable.
    var interpretationFailed = false
    /// Set when the words ask for nothing beyond facts and topics: titles TMDb has tagged with every requested topic then need no
    /// synopsis check by the model, which is slow and was rejecting real heist comedies for "funny heist movies".
    var trustsTopicMatches = false
    /// What a synopsis must show beyond the database's facts, in the search's own words ("dark gritty", "less depressing"). The model
    /// checking candidates is told this outright, since it otherwise took any title whose genre and years fit.
    var judgement = ""
    /// Set when the search's own words stand in as its title because the model named none, so only an exact match ends the search.
    var titlesFromWords = false
    /// Set when the model gave back words that do not read as a title as one: only a title of that name or its sequels counts.
    var titleSequelsOnly = false

    public init(filters: DescribedSearch, titleQueries: [String] = [], referenceTitles: [String] = [], people: [Person] = [],
                companies: [String] = [], language: String? = nil, excludedTopics: [String] = [], unwatchedOnly: Bool = false,
                requiresSemanticRanking: Bool = true) {
        self.filters = filters
        self.titleQueries = Array(titleQueries.prefix(2))
        self.referenceTitles = Array(referenceTitles.prefix(2))
        self.people = Array(people.prefix(3))
        self.companies = Array(companies.prefix(2))
        let code = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.language = code?.count == 2 && code?.allSatisfy(\.isLetter) == true ? code : nil
        self.excludedTopics = Array(excludedTopics.prefix(2))
        self.requiresSemanticRanking = requiresSemanticRanking
        self.unwatchedOnly = unwatchedOnly
    }

    /// Separate movie and TV queries map genres to each medium's IDs (878 versus 10765, for example). When the search names no kind,
    /// a kind without one of the requested genres is not asked: TMDb has no TV horror, thriller, romance or history, and the TV query
    /// dropped the genre and returned any popular series (The Mentalist for "slow burn psychological horror"). Series queries leave
    /// out talk, news and reality TV, which no description here asks for ("80s dark gritty" listed Wheel of Fortune). When the words
    /// name no kind, they also leave out cartoons from TV's merged genres, unless animation is asked for: "Sci-Fi & Fantasy" put
    /// Pokémon and Ranma ½ in "dark atmospheric sci-fi". "Sci-fi series" keeps them.
    func queries(keywords: [TMDbDiscoverQuery.Named], excluded: [TMDbDiscoverQuery.Named] = [],
                 companies: [TMDbDiscoverQuery.Named] = []) -> [TMDbDiscoverQuery] {
        var kinds = filters.kind.map { [$0] } ?? [.movie, .series]
        if filters.kind == nil {
            let covered = kinds.filter { kind in filters.genres.allSatisfy { TMDbDiscoverQuery.genre(named: $0, kind: kind) != nil } }
            kinds = covered.isEmpty ? [.movie] : covered
        }
        return kinds.map { kind in
            var search = filters
            search.kind = kind
            var query = search.query(keywords: keywords)
            query.language = language
            query.excludedKeywords = excluded
            query.companies = companies
            if kind == .series {
                var left = Self.nonFictionTV
                if filters.kind == nil, query.genres.contains(where: { Self.mergedTVGenres.contains($0.id) }),
                   !query.genres.contains(where: { $0.id == 16 }) {
                    left.append(TMDbDiscoverQuery.Named(id: 16, name: "Animation"))
                }
                query.excludedGenres += left.filter { genre in !query.excludedGenres.contains(genre) }
            }
            return query
        }
    }

    static let nonFictionTV = [TMDbDiscoverQuery.Named(id: 10763, name: "News"), TMDbDiscoverQuery.Named(id: 10764, name: "Reality"),
                               TMDbDiscoverQuery.Named(id: 10767, name: "Talk")]
    /// TV genres that stand for two film genres: Action & Adventure, Sci-Fi & Fantasy.
    static let mergedTVGenres: Set<Int> = [10759, 10765]
}

/// Facts attached only to search candidates; never written into a title's synopsis or saved metadata.
public struct AISearchCandidate: Sendable {
    public let item: MetaPreview
    public let evidence: String
    public let metadata: TMDbSearchMetadata?
    public init(item: MetaPreview, evidence: String, metadata: TMDbSearchMetadata? = nil) {
        self.item = item; self.evidence = evidence; self.metadata = metadata
    }
}

public struct AISearchUpdate: Sendable {
    public enum Issue: Sendable, Equatable {
        case needsTMDbToken, database, ranking

        public var text: String {
            switch self {
            case .needsTMDbToken: "Add a TMDB Read Access Token in Settings to use AI Search."
            case .database: "Some search data couldn't load. Try again."
            case .ranking: "On-device AI couldn't check some matches. Try again."
            }
        }
    }

    public enum Stage: Sendable, Equatable {
        case interpreting, filters, titles, people, similar, themes, ranking, complete
        public var text: String {
            switch self {
            case .interpreting: "Understanding your search…"
            case .filters: "Finding matches for your filters…"
            case .titles: "Checking titles…"
            case .people: "Checking cast, crew and studios…"
            case .similar: "Finding related films and series…"
            case .themes: "Searching themes, settings and tone…"
            case .ranking: "Checking more matches on your device…"
            case .complete: "Search complete"
            }
        }
    }
    public let items: [MetaPreview]
    public let stage: Stage
    public let issue: Issue?

    public init(items: [MetaPreview], stage: Stage, issue: Issue? = nil) {
        self.items = items
        self.stage = stage
        self.issue = issue
    }
}
