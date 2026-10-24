import Foundation
import StremioKit

/// What the on-device model read in a search, before it is checked against the search's own words.
struct ModelReading: Sendable, Equatable {
    var themes: [String] = []
    var excludedTopics: [String] = []
    var titleQueries: [String] = []
    var referenceTitles: [String] = []
    var cast: [String] = []
    var directors: [String] = []
    var writers: [String] = []
    var creators: [String] = []
    var companies: [String] = []
}

/// Turns the model's reading into a search plan, keeping only what the words of the search support. The small on-device model adds
/// things nobody asked for: on 17 Oct it gave "funny heist movies" a 2000–2010 release window, "Japanese samurai films with great
/// reviews" the genres Action, Adventure and War (so TMDb had nothing), "Tom Hanks movies from the 90s" the title Forrest Gump and
/// Toy Story as a reference, and "Harakiri" the genres Drama and War, which hid Harakiri itself. Dates, scores, runtimes, genres,
/// kinds and languages are read from the words alone; titles, people, studios and themes the model names are kept only when the
/// words contain them.
enum AISearchGrounding {
    static func plan(_ reading: ModelReading, for text: String, now: Date = Date()) -> AISearchPlan {
        let people = names(reading.cast, .cast, in: text) + names(reading.directors, .director, in: text)
            + names(reading.writers, .writer, in: text) + names(reading.creators, .creator, in: text)
        let references = referenceTitles(reading.referenceTitles, in: text)
        let titleLike = mightBeTitle(text) && people.isEmpty
        let whole = normalized(text)
        // A title the search wants something like is a reference, never a result ("like Prisoners" never lists Prisoners).
        // One word that cannot be a title ("anime", "westerns") is never searched as one: films called "Anime" were listed first.
        let oneWord = !whole.contains(" ")
        var titles = reading.titleQueries.filter { title in
            guard titleLike || !oneWord || normalized(title) != whole else { return false }
            return (contains(text, title) || (titleLike && isSpelling(title, of: text)))
                && !references.contains { normalized($0) == normalized(title) }
        }
        // Words that could be a title are searched as one unless the model read them as a story topic ("time travel", "heist"),
        // which the theme searches then answer. The model also gives the whole search back as a title, for a description ("sad
        // movies", "best movies of 2023") as for a real one ("Scary Movie", "1917"). Either way the words stand in as the title:
        // a film of that name is shown, and they stay the search's words, so what they ask for is still searched. Searching
        // only for a film called "sad movies" found nothing and ended the search.
        let echoed = titles.contains { normalized($0) == whole }
        let titlesFromWords = echoed || (titleLike && titles.isEmpty && themes(reading.themes, in: text, excluding: []).isEmpty)
        if titlesFromWords, titles.isEmpty { titles = [text] }
        let companies = reading.companies.filter { company in
            contains(text, company) || distinctiveWords(company).contains { words(text).contains($0) }
        }
        // The words that are left once named titles, people and studios are taken out are the search's own requirements.
        let named = (titlesFromWords ? [] : titles) + references + people.map(\.name) + companies
        let rest = remove(named, from: text)
        var filters = DescribedSearch.reading(rest)
        let restWords = words(rest)
        if restWords.isDisjoint(with: kindWords) { filters.kind = nil }
        for genre in impliedGenres(in: restWords) where !filters.genres.contains(genre) { filters.genres.append(genre) }
        if filters.earliestYear == nil, filters.latestYear == nil { (filters.earliestYear, filters.latestYear) = era(in: restWords, now: now) }
        // One bare year is the release year ("best movies of 2023"), once titles that hold a year are taken out.
        let years = restWords.compactMap(Int.init).filter { (1900...2100).contains($0) }
        if filters.earliestYear == nil, filters.latestYear == nil, years.count == 1 { (filters.earliestYear, filters.latestYear) = (years[0], years[0]) }
        let negated = hasNegation(rest)
        let excluded = negated ? reading.excludedTopics.filter { sharesWord($0, with: rest) } : []
        filters.moods = themes(reading.themes + filters.moods, in: rest, excluding: excluded)
        let judged = judgement(in: rest)
        // Words the model left out still count: "mind bending films" is searched for "mind bending", not for any film.
        if filters.moods.isEmpty, !judged.isEmpty, !(titlesFromWords && titleLike) {
            filters.moods = themes([judged], in: rest, excluding: excluded)
        }
        let subjective = !references.isEmpty || !restWords.isDisjoint(with: subjectiveWords) || rest.lowercased().contains("feel-good")
        var plan = AISearchPlan(filters: filters, titleQueries: titles, referenceTitles: references, people: people,
                                companies: companies, language: language(inOrder: rest), excludedTopics: excluded,
                                unwatchedOnly: unwatchedCues.contains { normalized(text).contains($0) },
                                requiresSemanticRanking: subjective || !filters.moods.isEmpty)
        plan.trustsTopicMatches = !subjective
        plan.judgement = judged
        plan.titlesFromWords = titlesFromWords
        // Words that do not read as a title keep only a film of that very name, or its sequels ("Scary Movie 3").
        plan.titleSequelsOnly = echoed && !titleLike
        return plan
    }

    /// The words of the search that only a synopsis can show: what is left once titles, people, studios, kinds, genres, dates,
    /// scores, runtimes, languages and filler are taken out, kept as typed ("feel-good brothers", "less depressing").
    static func judgement(in rest: String) -> String {
        var kept: [String] = []
        var previous = ""
        for token in rest.split(whereSeparator: \.isWhitespace) {
            let parts = normalized(String(token)).split(separator: " ").map(String.init)
            // Who is watching is no part of the story ("with my girlfriend").
            defer { previous = parts.last ?? previous }
            guard !["my", "our", "your", "his", "her", "their"].contains(previous) else { continue }
            guard parts.contains(where: { part in
                !factWords.contains(part) && !TMDbDiscoverQuery.genreWords.contains(part) && languages[part] == nil
                    && Int(part) == nil && !isYearOrDecade(part)
            }) else { continue }
            kept.append(String(token).trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "-"))))
        }
        while let first = kept.first, ["but", "and", "or", "though"].contains(first.lowercased()) { kept.removeFirst() }
        return kept.joined(separator: " ")
    }

    /// Genres to draw candidates from when a search asks for a feel and names no genre ("80s dark gritty" draws on crime and
    /// thrillers, "feel-good films about brothers" on comedies and family films). They pick where to look, never what to keep:
    /// the model still checks every candidate. Two at most, the most often implied first. Empty when nothing implies one.
    static func poolGenres(in text: String) -> [String] {
        let list = normalized(text).split(separator: " ").map(String.init)
        var votes: [String: Int] = [:]
        var order: [String] = []
        let phrases = zip(list, list.dropFirst()).map { "\($0) \($1)" } + list
        for phrase in phrases {
            for genre in moodGenres[phrase] ?? [] {
                if votes[genre] == nil { order.append(genre) }
                votes[genre, default: 0] += 1
            }
        }
        let ranked = order.enumerated().sorted { a, b in
            votes[a.element]! != votes[b.element]! ? votes[a.element]! > votes[b.element]! : a.offset < b.offset
        }
        return Array(ranked.map(\.element).prefix(2))
    }

    private static let moodGenres: [String: [String]] = [
        "dark": ["Thriller", "Crime"], "gritty": ["Crime", "Thriller"], "bleak": ["Drama", "Thriller"], "noir": ["Crime", "Thriller"],
        "violent": ["Crime", "Action"], "tense": ["Thriller"], "suspenseful": ["Thriller"], "intense": ["Thriller", "Action"],
        "slow burn": ["Thriller", "Drama"], "psychological": ["Thriller", "Drama"], "twisty": ["Thriller", "Mystery"],
        "mind bending": ["Science Fiction", "Thriller"], "cerebral": ["Science Fiction", "Drama"], "atmospheric": ["Mystery", "Thriller"],
        "creepy": ["Horror"], "eerie": ["Horror", "Mystery"], "unsettling": ["Horror", "Thriller"], "dystopian": ["Science Fiction"],
        "feel good": ["Comedy", "Family"], "uplifting": ["Drama", "Comedy"], "heartwarming": ["Comedy", "Family"],
        "wholesome": ["Family", "Comedy"], "cozy": ["Comedy", "Family"], "cosy": ["Comedy", "Family"], "quirky": ["Comedy"],
        "sad": ["Drama"], "melancholic": ["Drama"], "melancholy": ["Drama"], "emotional": ["Drama"], "tearjerker": ["Drama"],
        "epic": ["Adventure", "War"], "swashbuckling": ["Adventure"],
    ]

    /// Whether the words could be a title on their own: they ask for no kind, genre, decade, year or language and want nothing
    /// "like" another title. Beyond one word, a feel word or a word that implies a genre ("dark gritty", "space cowboys") makes it a
    /// description too, while one word ("Alien", "Dark") is searched as a title. "funny heist movies" and "classic westerns" are not
    /// titles; "Harakiri" and "Tom Hanks" may be.
    static func mightBeTitle(_ text: String) -> Bool {
        guard !DescribedSearch.readsLikeDescription(text), referenceTitles([], in: text).isEmpty else { return false }
        let list = normalized(text).split(separator: " ").map(String.init)
        // Filler alone ("something to watch tonight") names no title, though one word of it may ("Her", "Us"), and a year alone
        // may be one ("1917").
        guard !list.isEmpty, list.count == 1 || !list.allSatisfy(factWords.contains), Set(list).isDisjoint(with: kindWords),
              language(in: Set(list)) == nil,
              DescribedSearch.reading(text).genres.isEmpty,
              (list.count == 1 && Int(list[0]) != nil) || !list.contains(where: isYearOrDecade) else { return false }
        return list.count == 1 || (Set(list).isDisjoint(with: subjectiveWords) && list.allSatisfy { genreHints[$0] == nil })
    }

    /// Whether a topic word is written with a capital inside the search ("Tom Hanks films"), so it is likely a name only the model
    /// can read, not a story topic.
    static func capitalisesATopic(_ text: String) -> Bool {
        let raw = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let topics = Set(topicWords(in: text))
        return raw.dropFirst().contains { word in
            word.first?.isUppercase == true && topics.contains(normalized(word))
        }
    }

    /// "1994", "80s", "1980s" or "90's".
    private static func isYearOrDecade(_ word: String) -> Bool {
        if let year = Int(word) { return (1900...2100).contains(year) }
        guard word.hasSuffix("s"), let number = Int(word.dropLast()) else { return false }
        return [2, 4].contains(word.count - 1) && number % 10 == 0
    }

    // MARK: Names

    private static func names(_ list: [String], _ role: AISearchPlan.Person.Role, in text: String) -> [AISearchPlan.Person] {
        list.filter { $0.split(separator: " ").count >= 1 && contains(text, $0) }.map { AISearchPlan.Person(name: $0, role: role) }
    }

    /// Reference titles need a "like" in the words ("like Prisoners", "similar to Heat", "in the vein of Alien"). The model's are kept
    /// when the words contain them; without any, the words after the cue up to a "but", a comma or a requirement stand in.
    static func referenceTitles(_ model: [String], in text: String) -> [String] {
        let lower = " " + normalized(text) + " "
        let cues = [" something like ", " anything like ", " similar to ", " in the vein of ", " reminds me of ", " such as ", " like "]
        guard cues.contains(where: { lower.contains($0) }) else { return [] }
        let kept = model.filter { contains(text, $0) }
        // "Feels like a warm hug" describes a feel: a "like" right after feel, look, sound or seem never makes the words after it a
        // title, though a title the model names there stands ("looks like Blade Runner").
        let feelWords: Set<String> = ["feel", "feels", "feeling", "look", "looks", "sound", "sounds", "seem", "seems"]
        var cueRange: Range<String.Index>?
        for cue in cues where cueRange == nil {
            var searched = lower.startIndex..<lower.endIndex
            while let found = lower.range(of: cue, range: searched) {
                let before = lower[..<found.lowerBound].split(separator: " ").last.map(String.init) ?? ""
                if cue != " like " || !feelWords.contains(before) { cueRange = found; break }
                searched = lower.index(after: found.lowerBound)..<lower.endIndex
            }
        }
        guard let range = cueRange else { return Array(kept.prefix(2)) }
        if !kept.isEmpty { return Array(kept.prefix(2)) }
        let stops: Set<String> = ["but", "except", "only", "without", "though", "although", "that", "which", "under", "less", "more",
                                  "with", "from", "before", "after", "and", "or"]
        var picked: [String] = []
        for word in lower[range.upperBound...].split(separator: " ").map(String.init) {
            if stops.contains(word) { break }
            picked.append(word)
        }
        while let last = picked.last, kindWords.contains(last) { picked.removeLast() }
        guard !picked.isEmpty else { return [] }
        // Keep the user's own spelling and capitals.
        let phrase = picked.joined(separator: " ")
        if let found = text.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) { return [String(text[found])] }
        return [phrase]
    }

    // MARK: Themes

    /// The model's themes, and the reader's mood and subject words, kept when they share a word with the search: "Honor and duty"
    /// for "Harakiri" or "character-driven storytelling" for "Tom Hanks movies" are dropped. A genre, a kind or a single word already
    /// inside a longer theme ("time" beside "time travel") is not a theme, and neither is a fact the reader takes ("funny" is Comedy).
    /// Three at most.
    static func themes(_ candidates: [String], in text: String, excluding excluded: [String]) -> [String] {
        let genreWords = TMDbDiscoverQuery.genreWords
        var kept: [String] = []
        for candidate in candidates {
            let theme = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let themeWords = words(theme)
            // A year or a decade is a date the filters hold already ("2023" for "best movies of 2023"), never a theme.
            guard !theme.isEmpty, !themeWords.allSatisfy({ Int($0) != nil || isYearOrDecade($0) }), sharesWord(theme, with: text),
                  !themeWords.isSubset(of: genreWords.union(factWords).union(genreAdjectives)),
                  !excluded.contains(where: { $0.caseInsensitiveCompare(theme) == .orderedSame }),
                  !kept.contains(where: { $0 == theme }) else { continue }
            kept.append(theme)
        }
        let deduped = kept.filter { theme in
            !kept.contains { other in other != theme && words(other).count > words(theme).count && words(theme).isSubset(of: words(other)) }
        }
        return Array(deduped.prefix(DescribedSearch.maxMoods))
    }

    // MARK: Topics

    /// The words left once facts the reader takes are set aside (kinds, genres, years, scores, runtimes, languages, eras and filler):
    /// the topics TMDb's keywords can answer ("heist", "time travel", "samurai"), in the search's order.
    /// A word after "my" or "our" says who is watching ("with my friends"), not what the story is about.
    static func topicWords(in text: String) -> [String] {
        let all = normalized(text).split(separator: " ").map(String.init)
        return all.enumerated().compactMap { index, word in
            if index > 0, ["my", "our", "your", "his", "her", "their"].contains(all[index - 1]) { return nil }
            guard !factWords.contains(word), !TMDbDiscoverQuery.genreWords.contains(word), languages[word] == nil,
                  genreHints[word] == nil, Int(word) == nil, !(word.hasSuffix("s") && Int(word.dropLast()) != nil) else { return nil }
            return word
        }
    }

    /// The topic words as TMDb keyword searches: each adjacent pair ("time travel"), then each word, at most six.
    static func topicPhrases(in text: String) -> [String] {
        let topics = topicWords(in: text)
        let pairs = zip(topics, topics.dropFirst()).map { "\($0) \($1)" }
        var phrases: [String] = []
        for phrase in pairs + topics where !phrases.contains(phrase) { phrases.append(phrase) }
        return Array(phrases.prefix(6))
    }

    /// Whether TMDb's keyword is the topic itself, plurals aside ("brother" for "brothers", "bank robbery" for "bank robberies").
    static func isSameTopic(_ keyword: String, _ phrase: String) -> Bool {
        let a = normalized(keyword).split(separator: " ").map { stems(String($0)) }
        let b = normalized(phrase).split(separator: " ").map { stems(String($0)) }
        return !a.isEmpty && a.count == b.count && zip(a, b).allSatisfy { !$0.isDisjoint(with: $1) }
    }

    /// The topic words no matched keyword covers. Empty means TMDb's keywords answer every topic the search names.
    static func uncoveredTopics(in text: String, by phrases: [String]) -> [String] {
        let covered = Set(phrases.flatMap { normalized($0).split(separator: " ").flatMap { stems(String($0)) } })
        return topicWords(in: text).filter { covered.isDisjoint(with: stems($0)) }
    }

    /// Words that state a fact the reader takes, or carry nothing: never topics.
    private static let factWords: Set<String> = kindWords.union(ignorable).union([
        "funny", "hilarious", "comedic", "great", "good", "reviews", "review", "reviewed", "highly", "rated", "best", "acclaimed",
        "top", "well", "under", "over", "minutes", "minute", "min", "mins", "hours", "hour", "two", "one", "three", "short",
        "classic", "classics", "recent", "latest", "newest", "from", "before", "after", "since", "in", "or", "for", "that", "some",
        "any", "me", "my", "i", "find", "recommend", "please", "to", "on", "at", "by", "is", "are", "set", "no", "not", "without",
        "except", "excluding", "s", "pre", "post", "era", "decade", "year", "years", "old", "older", "new", "newer", "around",
        "watch", "watching", "tonight", "today", "night", "evening", "weekend", "together", "want", "need", "looking", "suggest",
        "something", "anything", "stuff", "things", "like", "similar", "his", "her", "their", "our", "your", "we", "us",
    ])

    // MARK: Words

    static let kindWords: Set<String> = ["film", "films", "movie", "movies", "tv", "series", "show", "shows", "television"]
    private static let ignorable: Set<String> = ["a", "an", "the", "and", "of", "with", "about", "story", "stories", "something"]
    /// Feel words that only say the genre they imply ("scary movies" is horror): no theme of their own to search or check.
    private static let genreAdjectives: Set<String> = ["scary", "spooky", "romantic", "animated", "cartoon", "cartoons"]
    /// Words that ask for a feel rather than a fact. With one of them, every candidate's synopsis is checked by the model.
    static let subjectiveWords: Set<String> = [
        "less", "more", "but", "feel", "feels", "vibe", "vibes", "tone", "mood", "slow", "burn", "uplifting", "depressing", "sad",
        "happy", "wholesome", "heartwarming", "dark", "darker", "light", "lighter", "atmospheric", "gritty", "bleak", "cozy", "quirky",
        "weird", "twisty", "tense", "creepy", "eerie", "moody", "cerebral", "surreal", "nostalgic", "melancholic", "melancholy", "epic",
        "intense", "emotional", "smart", "clever", "beautiful", "stylish", "underrated", "hidden", "gem", "gems",
    ]
    private static let unwatchedCues = ["havent seen", "haven t seen", "not seen", "unwatched", "not watched", "havent watched",
                                        "haven t watched", "new to me"]
    private static let languages: [String: String] = [
        "japanese": "ja", "korean": "ko", "french": "fr", "spanish": "es", "mexican": "es", "italian": "it", "german": "de",
        "chinese": "zh", "mandarin": "zh", "cantonese": "cn", "hindi": "hi", "bollywood": "hi", "swedish": "sv", "danish": "da",
        "norwegian": "no", "russian": "ru", "turkish": "tr", "thai": "th", "portuguese": "pt", "brazilian": "pt", "polish": "pl",
        "persian": "fa", "iranian": "fa", "dutch": "nl", "greek": "el", "arabic": "ar", "hebrew": "he", "israeli": "he",
        "finnish": "fi", "icelandic": "is", "indonesian": "id", "vietnamese": "vi", "tamil": "ta", "telugu": "te",
        // Anime is Japanese animation: the genre comes from the genre words.
        "anime": "ja",
    ]
    private static let genreHints: [String: String] = [
        "scary": "Horror", "spooky": "Horror", "slasher": "Horror", "romantic": "Romance", "anime": "Animation", "cartoon": "Animation",
        "cartoons": "Animation", "animated": "Animation", "cowboy": "Western", "cowboys": "Western", "wizard": "Fantasy",
        "wizards": "Fantasy", "dragons": "Fantasy", "space": "Science Fiction", "alien": "Science Fiction", "aliens": "Science Fiction",
        "robot": "Science Fiction", "robots": "Science Fiction", "cyberpunk": "Science Fiction", "docuseries": "Documentary",
    ]

    static func language(in words: Set<String>) -> String? { words.lazy.compactMap { languages[$0] }.first }
    /// The first language the words name, in the order typed ("korean anime" is Korean).
    static func language(inOrder text: String) -> String? {
        normalized(text).split(separator: " ").lazy.compactMap { languages[String($0)] }.first
    }

    /// Whether every word of the search is a story topic, with no filler, genre, kind or date beside it ("zombies", "time
    /// travel"; not "Toy Story").
    static func isAllTopic(_ text: String) -> Bool {
        let all = normalized(text).split(separator: " ")
        return !all.isEmpty && topicWords(in: text).count == all.count
    }

    private static func impliedGenres(in words: Set<String>) -> [String] {
        Array(Set(words.compactMap { genreHints[$0] })).sorted()
    }

    /// "Classic" is everything before 1980, "recent" or "latest" the last four years. Nil without such a word.
    private static func era(in words: Set<String>, now: Date) -> (Int?, Int?) {
        if !words.isDisjoint(with: ["classic", "classics", "oldies"]) { return (nil, 1979) }
        if !words.isDisjoint(with: ["recent", "latest", "newest"]) {
            return (Calendar(identifier: .gregorian).component(.year, from: now) - 4, nil)
        }
        return (nil, nil)
    }

    static func hasNegation(_ text: String) -> Bool {
        !words(text).isDisjoint(with: ["no", "not", "without", "except", "excluding", "nothing", "never", "avoid"])
    }

    /// Lower case, accents dropped, everything but letters and digits a single space.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
            .filter { $0 != "'" && $0 != "\u{2019}" }
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    static func words(_ text: String) -> Set<String> { Set(normalized(text).split(separator: " ").map(String.init)) }

    /// Whether the words contain the phrase as whole words.
    static func contains(_ text: String, _ phrase: String) -> Bool {
        let wanted = normalized(phrase)
        return !wanted.isEmpty && (" " + normalized(text) + " ").contains(" " + wanted + " ")
    }

    static func stem(_ word: String) -> String {
        if word.count > 4, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    /// The forms a word may have in the singular: "robberies" is "robbery", but "zombies" is "zombie", so a word in "ies" has both.
    static func stems(_ word: String) -> Set<String> {
        if word.count > 4, word.hasSuffix("ies") { return [String(word.dropLast(3)) + "y", String(word.dropLast())] }
        return [stem(word)]
    }

    /// Whether a word is already singular: one of its singular forms is itself.
    static func isSingular(_ word: String) -> Bool { stems(word).contains(word) }

    /// Whether a theme shares a word of three letters or more with the text, plurals aside ("brothers" and "brother").
    static func sharesWord(_ theme: String, with text: String) -> Bool {
        let own = Set(words(text).filter { $0.count >= 3 }.flatMap(stems))
        return words(theme).contains { $0.count >= 3 && !own.isDisjoint(with: stems($0)) }
    }

    /// The words of a studio's name that pick it out ("ghibli" in "Studio Ghibli"), not its "studio" or "pictures".
    private static func distinctiveWords(_ name: String) -> Set<String> {
        words(name).filter { $0.count >= 4 && !["studio", "studios", "pictures", "films", "entertainment", "productions", "animation",
                                                  "company", "media", "television"].contains($0) }
    }

    /// Whether the model's title is the search with its spelling corrected: few letters apart for the length.
    private static func isSpelling(_ title: String, of text: String) -> Bool {
        let a = Array(normalized(title)), b = Array(normalized(text))
        guard !a.isEmpty, !b.isEmpty else { return false }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count] <= max(2, min(a.count, b.count) / 5)
    }

    /// The text with each named title, person or studio taken out as whole words.
    private static func remove(_ phrases: [String], from text: String) -> String {
        // A curly and a straight apostrophe are the same letter here ("Ocean’s Eleven").
        var rest = text.replacingOccurrences(of: "\u{2019}", with: "'")
        for phrase in phrases.map({ $0.replacingOccurrences(of: "\u{2019}", with: "'") })
            where !phrase.trimmingCharacters(in: .whitespaces).isEmpty {
            let pattern = "(?<![[:alnum:]])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![[:alnum:]])"
            rest = rest.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return rest
    }
}
