import Foundation

/// What Best Blurays (bestblurays.com, a community-edited guide) names as the best release of one film.
public struct BestBlurayEdition: Sendable, Equatable {
    /// "The Dark Knight (2008)".
    public var filmTitle: String
    public var pageURL: URL
    /// The release as the page names it: "WB 4K Blu-ray", "Criterion Blu-ray and UK Dogwoof Blu-ray probably similar".
    public var release: String
    /// What the release is best at, in the page's words: "Best English-friendly & video release".
    public var heading: String
    /// "updated 4 months ago".
    public var updated: String?
    public var videoNotes: String?
    /// The page's 4K quality tier ("Solid", "Excellent"), for films with a 4K release.
    public var uhdTier: String?
    /// A release the page says is on its way.
    public var upcoming: String?
    /// The page's own score for the film, out of 5.
    public var siteRating: Double?

    public init(filmTitle: String, pageURL: URL, release: String, heading: String, updated: String? = nil, videoNotes: String? = nil,
                uhdTier: String? = nil, upcoming: String? = nil, siteRating: Double? = nil) {
        self.filmTitle = filmTitle
        self.pageURL = pageURL
        self.release = release
        self.heading = heading
        self.updated = updated
        self.videoNotes = videoNotes
        self.uhdTier = uhdTier
        self.upcoming = upcoming
        self.siteRating = siteRating
    }

    /// True when the best release is a 4K disc.
    public var is4K: Bool { release.localizedCaseInsensitiveContains("4K") }
}

/// The answer to "what is the best edition of this film?".
public enum BestBlurayResult: Sendable, Equatable {
    case edition(BestBlurayEdition)
    /// The site has a page for the film but has not named a best release on it yet.
    case pageWithoutEdition(title: String, url: URL)
    /// The site has no page for the film.
    case noPage(searchURL: URL)
}

/// Looks a film up on Best Blurays by reading its public pages, once, when the viewer asks. The site has no API, so this reads the
/// search page for the film's title, picks the page for that title and year, and confirms it is the same film by the IMDb id the
/// page carries. At most four requests, each bounded in size. Pages the site's robots.txt allows (`/films`, `/film/…`).
public struct BestBluraysClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://www.bestblurays.com") ?? URL(fileURLWithPath: "/")
    private static let userAgent = "Blusion/1.0 (personal media player; looks up one film when asked)"
    /// The part of a page that names the best release sits within the first 70 KB; the rest is the cast and release tables.
    private static let pageLimit = FetchLimits(maxBytes: 192 * 1024, truncateAtLimit: true)

    private let client: AddonClient
    private let baseURL: URL

    public init(client: AddonClient, baseURL: URL = BestBluraysClient.defaultBaseURL) {
        self.client = client
        self.baseURL = baseURL
    }

    /// The best edition of the film. Throws `AddonError` when a request fails.
    /// - Parameters:
    ///   - imdbID: the film's IMDb id, which tells two films with the same title apart.
    ///   - title: the film's title as the catalog has it.
    ///   - year: its release year, four digits, when known.
    public func bestEdition(imdbID: String, title: String, year: String?) async throws -> BestBlurayResult {
        let searchURL = try Self.searchURL(for: title, baseURL: baseURL)
        let search = try await fetch(searchURL)
        let candidates = Self.rank(Self.filmLinks(in: search), title: title, year: year).prefix(3)
        let wantedSlug = Self.slug(title)
        for candidate in candidates {
            guard let pageURL = URL(string: candidate.path, relativeTo: baseURL)?.absoluteURL else { continue }
            let page = Self.parseFilm(html: try await fetch(pageURL), pageURL: pageURL)
            // The IMDb id settles it. A page with no id is accepted only when its address matches the title and year exactly.
            let sameFilm = page.imdbID.map { $0 == imdbID } ?? (candidate.slug == wantedSlug && candidate.year == year)
            guard sameFilm else { continue }
            if let edition = page.edition { return .edition(edition) }
            return .pageWithoutEdition(title: page.title ?? title, url: pageURL)
        }
        return .noPage(searchURL: searchURL)
    }

    private func fetch(_ url: URL) async throws -> String {
        let result = try await client.get(url, headers: ["Accept": "text/html", "User-Agent": Self.userAgent],
                                          limits: Self.pageLimit, timeout: 12)
        return String(decoding: result.data, as: UTF8.self)
    }

    // MARK: - Finding the film's page

    static func searchURL(for title: String, baseURL: URL) throws -> URL {
        var parts = URLComponents(url: baseURL.appendingPathComponent("films"), resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "title", value: title)]
        guard let url = parts?.url else { throw AddonError.invalidURL }
        return url
    }

    struct Candidate: Equatable {
        var path: String
        var slug: String
        var year: String?
    }

    /// The film pages a search lists, in the order the site lists them, each once: `/film/652-the-dark-knight-2008`.
    static func filmLinks(in html: String) -> [Candidate] {
        var seen = Set<String>()
        var found: [Candidate] = []
        for match in html.matches(of: /href="(\/film\/[0-9]+-([a-z0-9\-]*?)(?:-([0-9]{4}))?)"/) {
            let path = String(match.output.1)
            guard seen.insert(path).inserted else { continue }
            found.append(Candidate(path: path, slug: String(match.output.2), year: match.output.3.map(String.init)))
        }
        return found
    }

    /// The same film first: the page for this title and year, then other pages of that year, then other pages of that title.
    static func rank(_ candidates: [Candidate], title: String, year: String?) -> [Candidate] {
        let wanted = slug(title)
        func score(_ candidate: Candidate) -> Int {
            let sameSlug = candidate.slug == wanted
            let sameYear = year != nil && candidate.year == year
            switch (sameSlug, sameYear) {
            case (true, true): return 0
            case (false, true): return 1
            case (true, false): return 2
            case (false, false): return 3
            }
        }
        return candidates.enumerated().sorted { (score($0.element), $0.offset) < (score($1.element), $1.offset) }.map(\.element)
    }

    /// How the site writes a title into an address: lower case, apostrophes dropped, anything else that is not a letter or digit a hyphen.
    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var slug = ""
        var pendingHyphen = false
        for character in folded where character != "'" && character != "\u{2019}" {
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingHyphen, !slug.isEmpty { slug.append("-") }
                pendingHyphen = false
                slug.append(character)
            } else {
                pendingHyphen = true
            }
        }
        return slug
    }

    // MARK: - Reading a film's page

    struct ParsedFilm: Equatable {
        var imdbID: String?
        var title: String?
        var edition: BestBlurayEdition?
    }

    /// Reads the part of a film page that names the best release. Pure, so it is tested against saved pages, without a network.
    static func parseFilm(html: String, pageURL: URL) -> ParsedFilm {
        let imdbID = html.firstMatch(of: /imdb\.com\/title\/(tt[0-9]+)/).map { String($0.output.1) }
        let rawTitle = html.firstMatch(of: /<title>([^<]*)<\/title>/).map { BestBluraysText.clean(String($0.output.1)) }
        let title = rawTitle.map { name in
            name.replacingOccurrences(of: " 4K Blu-ray Guide", with: "").replacingOccurrences(of: " Blu-ray Guide", with: "")
        }
        let tokens = BestBluraysText.tokens(in: html)
        guard let headingIndex = tokens.firstIndex(where: { $0.hasPrefix("Best ") && $0.contains(" release") }) else {
            return ParsedFilm(imdbID: imdbID, title: title, edition: nil)
        }
        // "Best English-friendly & video release · updated 4 months ago"
        let headingParts = tokens[headingIndex].components(separatedBy: " · ")
        let heading = headingParts[0].trimmingCharacters(in: .whitespaces)
        var updated = headingParts.dropFirst().first { $0.hasPrefix("updated") }

        // The release is the heading just above that line.
        let before = tokens[..<headingIndex]
        let markerIndex = before.lastIndex(of: BestBluraysText.headingMarker)
        let releaseTokens = markerIndex.map { Array(before[before.index(after: $0)...]) } ?? []
        var release = BestBluraysText.sentence(releaseTokens)
        // Since October 2026 the site names the release under the heading, not above it, and dates it on a line of its own.
        var rest = headingIndex + 1
        if release.isEmpty, rest < tokens.count, !BestBluraysText.startsSection(tokens[rest]) {
            release = tokens[rest]
            rest += 1
        }
        let rating = markerIndex.flatMap { index -> Double? in
            before[..<index].suffix(6).reversed().compactMap { token -> Double? in
                token.wholeMatch(of: /[0-9]\.[0-9]/).flatMap { Double(String($0.output)) }
            }.first
        }
        guard !release.isEmpty else { return ParsedFilm(imdbID: imdbID, title: title, edition: nil) }

        // Then, until the table of releases: notes, a tier, and anything upcoming.
        enum Section { case none, notes, tier, upcoming, other }
        var section = Section.none
        var notes: [String] = []
        var tier: [String] = []
        var upcoming: [String] = []
        for token in tokens[rest...] {
            if token == "Compare the discs" || token == "Overview" { break }
            if token.hasPrefix("Updated ") {
                if updated == nil { updated = "u" + token.dropFirst() }
            } else if token.hasPrefix("Video notes") {
                section = .notes
                let rest = token.dropFirst("Video notes".count).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                if !rest.isEmpty { notes.append(rest) }
            } else if token == "UHD tiers" {
                section = .tier
            } else if token.hasPrefix("Upcoming") {
                section = .upcoming
                let rest = token.dropFirst("Upcoming".count).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                if !rest.isEmpty { upcoming.append(rest) }
            } else if token.hasPrefix("Best ") || token.hasPrefix("Audio notes") || token.hasPrefix("Additional") {
                section = .other
            } else {
                switch section {
                case .notes: notes.append(token)
                case .tier: if tier.isEmpty { tier.append(token) }   // the word after "UHD tiers"; the lines after it are per-disc remarks
                case .upcoming: upcoming.append(token)
                case .none, .other: break
                }
            }
        }
        let edition = BestBlurayEdition(
            filmTitle: title ?? "", pageURL: pageURL, release: release, heading: heading, updated: updated,
            videoNotes: notes.isEmpty ? nil : BestBluraysText.sentence(notes),
            uhdTier: tier.first, upcoming: upcoming.isEmpty ? nil : BestBluraysText.sentence(upcoming), siteRating: rating)
        return ParsedFilm(imdbID: imdbID, title: title, edition: edition)
    }
}

/// Turns a page's HTML into the runs of text a person reads, without a parser: tags are dropped, block tags end a run, inline tags
/// (links, spans, emphasis) do not, comments and scripts vanish, and entities are decoded.
enum BestBluraysText {
    /// Stands in the token list where an `<h2>` begins, so the heading's text can be told from the text before it.
    static let headingMarker = "\u{1}h2"

    /// Whether a run of text after the best-release heading starts one of its sections rather than naming the release.
    static func startsSection(_ token: String) -> Bool {
        token == headingMarker || token == "UHD tiers" || token == "Compare the discs" || token == "Overview"
            || ["Video notes", "Updated ", "Upcoming", "Best ", "Audio notes", "Additional"].contains { token.hasPrefix($0) }
    }

    private static let inlineTags: Set<String> = ["a", "span", "em", "strong", "b", "i", "u", "small", "sup", "sub", "mark", "abbr", "code", "wbr", "time", "cite"]

    static func tokens(in html: String) -> [String] {
        let scalars = Array(html.unicodeScalars)
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        var index = 0

        func flush() {
            let text = clean(String(current))
            if !text.isEmpty { tokens.append(text) }
            current = String.UnicodeScalarView()
        }
        func hasPrefix(_ prefix: String, at start: Int) -> Bool {
            let wanted = Array(prefix.unicodeScalars)
            guard start + wanted.count <= scalars.count else { return false }
            return zip(wanted, scalars[start...]).allSatisfy { $0 == $1 }
        }
        /// The position just after the next `marker` at or beyond `start`, or the end. The marker is turned into scalars once.
        func skip(past marker: String, from start: Int) -> Int {
            let wanted = Array(marker.unicodeScalars)
            guard let first = wanted.first else { return start }
            var cursor = start
            while cursor + wanted.count <= scalars.count {
                if scalars[cursor] == first, zip(wanted, scalars[cursor...]).allSatisfy({ $0 == $1 }) { return cursor + wanted.count }
                cursor += 1
            }
            return scalars.count
        }

        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "<" else {
                current.append(scalar)
                index += 1
                continue
            }
            if hasPrefix("<!--", at: index) {
                index = skip(past: "-->", from: index + 4)
                continue
            }
            // A tag: its name, then everything up to the closing ">", skipping over quoted attribute values.
            var cursor = index + 1
            let isClosing = cursor < scalars.count && scalars[cursor] == "/"
            if isClosing { cursor += 1 }
            var name = ""
            while cursor < scalars.count, scalars[cursor].properties.isAlphabetic || ("0"..."9").contains(scalars[cursor]) {
                name.unicodeScalars.append(scalars[cursor])
                cursor += 1
            }
            var quote: Unicode.Scalar?
            while cursor < scalars.count {
                let character = scalars[cursor]
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    break
                }
                cursor += 1
            }
            index = min(cursor + 1, scalars.count)
            let lowered = name.lowercased()
            if !isClosing, lowered == "script" || lowered == "style" {
                flush()
                index = skip(past: "</\(lowered)>", from: index)
                continue
            }
            if !inlineTags.contains(lowered) {
                flush()
                if lowered == "h2", !isClosing { tokens.append(headingMarker) }
            }
        }
        flush()
        return tokens
    }

    /// Entities decoded and runs of white space (the non-breaking space included) made one space.
    static func clean(_ text: String) -> String {
        decodeEntities(text).split(whereSeparator: { $0.isWhitespace || $0 == "\u{00A0}" }).joined(separator: " ")
    }

    /// Text runs read as one passage: joined by spaces, with no space left before punctuation that follows a link or span.
    static func sentence(_ parts: [String]) -> String {
        var text = parts.joined(separator: " ")
        for mark in [" .", " ,", " ;", " :", " !", " ?", " \u{2019}", " )"] {
            text = text.replacingOccurrences(of: mark, with: String(mark.dropFirst()))
        }
        return text.replacingOccurrences(of: "( ", with: "(").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…",
        "rsquo": "\u{2019}", "lsquo": "\u{2018}", "rdquo": "\u{201D}", "ldquo": "\u{201C}", "middot": "·",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            let tail = rest[rest.index(after: ampersand)...]
            guard let semicolon = tail.prefix(10).firstIndex(of: ";") else {
                result.append("&")
                rest = tail
                continue
            }
            let entity = String(tail[..<semicolon])
            if let replacement = named[entity] {
                result += replacement
            } else if entity.hasPrefix("#"), let value = entity.dropFirst().first == "x" || entity.dropFirst().first == "X"
                        ? UInt32(entity.dropFirst(2), radix: 16) : UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(value) {
                result.unicodeScalars.append(scalar)
            } else {
                result += "&\(entity);"
            }
            rest = tail[tail.index(after: semicolon)...]
        }
        return result + rest
    }
}
