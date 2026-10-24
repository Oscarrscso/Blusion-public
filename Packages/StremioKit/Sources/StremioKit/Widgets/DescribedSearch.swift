import Foundation

/// What a search typed as a description asks for ("a dark, atmospheric sci-fi film from before 2010 with great reviews"), as the
/// on-device model or the keyword reader understands it. It becomes a TMDb discover query, so every title it finds is a real one.
public struct DescribedSearch: Sendable, Equatable {
    /// Films, series, or nil for either.
    public var kind: TMDbDiscoverQuery.Kind?
    /// Genre names such as "Science Fiction" or "thriller", read with the widgets' genre table.
    public var genres: [String]
    public var excludedGenres: [String]
    public var earliestYear: Int?
    public var latestYear: Int?
    /// Moods and themes, such as "dark" or "time travel": looked up as TMDb keywords, any of which may match.
    public var moods: [String]
    /// TMDb's community score, 0 to 10.
    public var minimumScore: Double?
    public var minimumRuntime: Int?
    public var maximumRuntime: Int?

    public init(kind: TMDbDiscoverQuery.Kind? = nil, genres: [String] = [], excludedGenres: [String] = [], earliestYear: Int? = nil,
                latestYear: Int? = nil, moods: [String] = [], minimumScore: Double? = nil, minimumRuntime: Int? = nil,
                maximumRuntime: Int? = nil) {
        self.kind = kind
        self.genres = genres
        self.excludedGenres = excludedGenres
        self.earliestYear = earliestYear
        self.latestYear = latestYear
        self.moods = moods
        self.minimumScore = minimumScore
        self.minimumRuntime = minimumRuntime
        self.maximumRuntime = maximumRuntime
    }

    /// This reading, with the years, runtimes and lowest score that `words` states outright taking the place of this one's. The keyword
    /// reader reads "before 2010" or "under two hours" exactly, where the on-device model sometimes puts a year at the wrong end.
    public func correcting(with words: DescribedSearch) -> DescribedSearch {
        var corrected = self
        if words.earliestYear != nil || words.latestYear != nil {
            corrected.earliestYear = words.earliestYear
            corrected.latestYear = words.latestYear
        }
        if words.maximumRuntime != nil { corrected.maximumRuntime = words.maximumRuntime }
        if words.minimumRuntime != nil { corrected.minimumRuntime = words.minimumRuntime }
        if corrected.minimumScore == nil { corrected.minimumScore = words.minimumScore }
        // A model sometimes misses explicit relationship/story topics, such as "about brothers".
        // Preserve those concrete subjects even when it inferred only a broad Comedy genre.
        for mood in words.moods where !corrected.moods.contains(where: { $0.caseInsensitiveCompare(mood) == .orderedSame }) {
            if Self.storyTopics.contains(mood) { corrected.moods.insert(mood, at: 0) }
        }
        corrected.moods = Array(corrected.moods.prefix(Self.maxMoods))
        // Explicit genre wording must win over an inferred genre: "funny movies about brothers"
        // is Comedy, not an unspecified Romance simply because both mention relationships.
        if !words.genres.isEmpty { corrected.genres = words.genres }
        for genre in words.excludedGenres where !corrected.excludedGenres.contains(genre) { corrected.excludedGenres.append(genre) }
        corrected.genres.removeAll { corrected.excludedGenres.contains($0) }
        return corrected
    }

    /// The most moods looked up as keywords: each is one TMDb request.
    public static let maxMoods = 3

    /// Whether nothing was understood: such a description finds nothing better than the title search beside it.
    public var isEmpty: Bool {
        genres.isEmpty && excludedGenres.isEmpty && earliestYear == nil && latestYear == nil && moods.isEmpty && minimumScore == nil
            && minimumRuntime == nil && maximumRuntime == nil
    }

    /// The TMDb query, with the moods given as the keywords TMDb found for them. Genres TMDb does not have for the kind are dropped; a
    /// score asks for enough votes that the score means something, both TMDb's own. Pure: nothing is requested.
    public func query(keywords: [TMDbDiscoverQuery.Named]) -> TMDbDiscoverQuery {
        let kind = kind ?? .movie
        func named(_ names: [String]) -> [TMDbDiscoverQuery.Named] {
            var found: [TMDbDiscoverQuery.Named] = []
            for name in names {
                guard let genre = TMDbDiscoverQuery.genre(named: name, kind: kind), !found.contains(genre) else { continue }
                found.append(genre)
            }
            return found
        }
        var earliest = earliestYear
        var latest = latestYear
        if let from = earliest, let to = latest, from > to { (earliest, latest) = (to, from) }
        // Both kinds are asked for only when every genre is the same one for films and TV: discover asks TV with the films' genre ids,
        // and TV has none for science fiction, thriller, horror and others.
        let sameForBoth = (genres + excludedGenres).allSatisfy {
            TMDbDiscoverQuery.genre(named: $0, kind: .movie)?.id == TMDbDiscoverQuery.genre(named: $0, kind: .series)?.id
        }
        // A score given out of 100 is read out of 10.
        let score = minimumScore.map { $0 > 10 ? $0 / 10 : $0 }
        return TMDbDiscoverQuery(kind: kind, ordering: .popular, genres: named(genres), keywords: Array(keywords.prefix(Self.maxMoods)),
                                 minimumScore: score.map { min(max($0, 0), 10) },
                                 minimumVotes: minimumScore == nil ? 50 : 300,
                                 minimumRuntime: minimumRuntime, maximumRuntime: maximumRuntime,
                                 releasedFrom: earliest.map { "\($0)-01-01" }, releasedTo: latest.map { "\($0)-12-31" },
                                 excludedGenres: named(excludedGenres), spansBothKinds: self.kind == nil && sameForBoth,
                                 usesTMDbScores: true)
    }
}

// MARK: - Reading a description without the model

extension DescribedSearch {
    /// Whether the text reads like a description rather than a title: words a description uses ("film", "from", "before", "with", a
    /// genre, a mood, a decade), two of them in four words or more. A three-word search needs three, or two with a decade, so "80s dark
    /// gritty" reads as a description while "The Dark Knight Rises", "War of the Worlds" or "Scary Movie 2" stay title searches.
    public static func readsLikeDescription(_ text: String) -> Bool {
        if isFilterOnly(text) { return true }
        let words = words(text)
        guard words.count >= 3 else { return false }
        let joined = " " + words.joined(separator: " ") + " "
        let cues = words.filter { descriptionWords.contains($0) || moodWords.contains($0) || decade($0) != nil }.count
            + TMDbDiscoverQuery.genreNames(in: joined).count
        if words.count >= 4 { return cues >= 2 }
        return cues >= 3 || (cues >= 2 && words.contains { decade($0) != nil })
    }

    /// Only fully explicit filter requests can be shown before semantic ranking finishes.
    /// Unrecognised words keep a request semantic: "90s comedy about brothers" must still prove the story subject.
    public static func isFilterOnly(_ text: String) -> Bool {
        let search = reading(text)
        guard !search.isEmpty, search.moods.isEmpty else { return false }
        let allowed: Set<String> = [
            "a", "an", "the", "and", "film", "films", "movie", "movies", "tv", "series", "show", "shows",
            "from", "in", "before", "after", "since", "with", "under", "minutes", "minute", "min", "mins",
            "hours", "hour", "two", "great", "good", "reviews", "highly", "rated", "best", "acclaimed", "short",
            "action", "adventure", "animation", "animated", "comedy", "comedies", "funny", "hilarious", "comedic",
            "crime", "documentary", "documentaries", "drama", "family", "fantasy", "history", "historical", "horror",
            "mystery", "romance", "romantic", "science", "fiction", "sci", "fi", "scifi", "thriller", "war", "western"
        ]
        return words(text).allSatisfy { allowed.contains($0) || decade($0) != nil || Int($0) != nil }
    }

    /// The filters a description names, read word by word: films or series, genres, a decade or "before/after/since" a year, "great
    /// reviews", "under two hours", and mood words. Used where the on-device model is not available.
    public static func reading(_ text: String) -> DescribedSearch {
        let words = words(text)
        let joined = " " + words.joined(separator: " ") + " "
        var search = DescribedSearch()
        let namesTV = words.contains(where: { ["tv", "series", "show", "shows", "television"].contains($0) })
        let namesFilms = words.contains(where: { ["movie", "movies", "film", "films"].contains($0) })
        search.kind = namesTV == namesFilms ? (namesTV ? nil : .movie) : (namesTV ? .series : .movie)
        search.genres = TMDbDiscoverQuery.genreNames(in: joined)
        for clue in TMDbDiscoverQuery.genreClues {
            guard let genre = clue.movie else { continue }
            if clue.phrases.contains(where: { phrase in
                ["no", "not", "without", "excluding", "except"].contains { joined.contains(" \($0) \(phrase) ") }
            }) {
                search.excludedGenres.append(genre.name)
                search.genres.removeAll { $0 == genre.name }
            }
        }
        if words.contains(where: { ["funny", "hilarious", "comedic"].contains($0) }),
           !search.genres.contains("Comedy") {
            search.genres.append("Comedy")
        }
        for (index, word) in words.enumerated() {
            if let start = decade(word) {
                search.earliestYear = start
                search.latestYear = start + 9
            } else if let year = Int(word), (1900...2100).contains(year), index > 0 {
                switch words[index - 1] {
                case "before", "pre": search.latestYear = year - 1
                case "after", "since", "post": search.earliestYear = year + (words[index - 1] == "after" ? 1 : 0)
                case "from", "in": search.earliestYear = year; search.latestYear = year
                default: break
                }
            }
        }
        if joined.contains(" great reviews ") || joined.contains(" good reviews ") || joined.contains(" highly rated ")
            || words.contains(where: { ["acclaimed", "masterpiece", "best"].contains($0) }) {
            search.minimumScore = 7.5
        }
        if joined.contains(" under two hours ") || joined.contains(" under 2 hours ") || joined.contains(" short ") {
            search.maximumRuntime = 120
        } else if let index = words.firstIndex(of: "under"), index + 2 < words.count, let minutes = Int(words[index + 1]),
                  ["minutes", "mins", "min"].contains(words[index + 2]) {
            search.maximumRuntime = minutes
        }
        // Prioritise the requested story subject over broad tones. TMDb keyword searches
        // for a relationship are much more useful than generic "funny" or "dark" keywords.
        let subjects = words.filter { storyTopics.contains($0) }
        let tones = words.filter { moodWords.contains($0) }
        search.moods = Array((subjects + tones).reduce(into: [String]()) { output, term in
            if !output.contains(term) { output.append(term) }
        }.prefix(maxMoods))
        return search
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().filter { $0 != "'" && $0 != "\u{2019}" }.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// The first year of "1990s" or "90s", else nil.
    private static func decade(_ word: String) -> Int? {
        guard word.hasSuffix("s"), let value = Int(word.dropLast()), value % 10 == 0 else { return nil }
        switch word.count {
        case 3: return value >= 30 ? 1900 + value : 2000 + value
        case 5 where value >= 1900: return value
        default: return nil
        }
    }

    private static let descriptionWords: Set<String> = [
        "film", "films", "movie", "movies", "show", "shows", "series", "something", "anything", "before", "after", "since", "with",
        "about", "where", "set", "reviews", "rated", "featuring", "starring", "under", "less", "more", "vibe", "vibes", "feel",
    ]

    /// Mood words the keyword reader passes on as TMDb keywords.
    private static let storyTopics: Set<String> = [
        "brother", "brothers", "sibling", "siblings", "sister", "sisters", "father", "fathers", "mother", "mothers",
        "family", "families", "friendship", "friends", "revenge", "betrayal", "isolation", "paranoia", "kidnapping",
        "heist", "robbery", "time", "travel", "memory", "amnesia",
    ]

    private static let moodWords: Set<String> = [
        "dark", "atmospheric", "gritty", "bleak", "uplifting", "heartwarming", "funny", "scary", "creepy", "tense", "violent", "slow",
        "cerebral", "twisty", "surreal", "nostalgic", "melancholic", "melancholy", "cozy", "quirky", "epic", "dystopian", "psychological",
    ]
}

// MARK: - Genres by name

extension TMDbDiscoverQuery {
    /// The genre a name means for a kind, read with the widgets' table ("sci-fi", "Science Fiction" and "scifi" are all one), or TMDb's
    /// genre of that exact name. Nil when the kind has no such genre.
    public static func genre(named name: String, kind: Kind) -> Named? {
        let phrase = " " + phraseWords(name).joined(separator: " ") + " "
        for clue in genreClues where clue.phrases.contains(where: { phrase.contains(" \($0) ") }) {
            return kind == .movie ? clue.movie : clue.series
        }
        let wanted = name.lowercased()
        return genreClues.lazy.compactMap { kind == .movie ? $0.movie : $0.series }.first { $0.name.lowercased() == wanted }
    }

    /// Every word the genre table reads as a genre ("horror", "sci", "fi", "comedies").
    public static let genreWords: Set<String> = {
        var words = Set<String>()
        for clue in genreClues {
            for phrase in clue.phrases { words.formUnion(phrase.split(separator: " ").map(String.init)) }
        }
        return words
    }()

    /// The genre names a text uses, in the table's order, as films name them.
    static func genreNames(in text: String) -> [String] {
        genreClues.filter { clue in clue.phrases.contains { text.contains(" \($0) ") } }.compactMap { $0.movie?.name }
    }

    /// Whether a text names any genre.
    static func namesGenre(in text: String) -> Bool { !genreNames(in: text).isEmpty }

    private static func phraseWords(_ text: String) -> [String] {
        text.lowercased().filter { $0 != "'" && $0 != "\u{2019}" }.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
