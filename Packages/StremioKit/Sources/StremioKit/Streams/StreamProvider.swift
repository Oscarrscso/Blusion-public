import Foundation

/// A streaming service a web release came from, read from the tag its name or file name carries ("NF", "AMZN") or from the service's own
/// name. Heuristic, like the rest of `StreamQuality`: addons put it in free text.
public enum StreamProvider: String, Sendable, Equatable, Hashable, CaseIterable {
    case netflix, primeVideo, appleTV, disneyPlus, hboMax, hulu, paramountPlus, peacock, crunchyroll

    /// The service's name as a viewer reads it.
    public var name: String {
        switch self {
        case .netflix: "Netflix"
        case .primeVideo: "Prime Video"
        case .appleTV: "Apple TV+"
        case .disneyPlus: "Disney+"
        case .hboMax: "HBO Max"
        case .hulu: "Hulu"
        case .paramountPlus: "Paramount+"
        case .peacock: "Peacock"
        case .crunchyroll: "Crunchyroll"
        }
    }

    /// The words that name each service, its release tag or its own name, tested against lowercased text. The first rule that matches wins.
    /// A bare "Amazon" or "Peacock" is left out: both are ordinary words in film titles, so they name a service only with its brand.
    private static let rules: [(pattern: String, value: StreamProvider)] = [
        (#"\bnf\b|\bnetflix\b"#, .netflix),
        (#"\bamzn\b|\bamazon[ .]?prime\b|\bprime[ .\-]?video\b"#, .primeVideo),
        (#"\batvp\b|\bapple[ .]?tv(?![a-z0-9])"#, .appleTV),
        (#"\bdsnp\b|\bdisney(?:\+|[ .]?plus)"#, .disneyPlus),
        (#"\bhmax\b|\bhbo[ .]?max\b"#, .hboMax),
        (#"\bhulu\b"#, .hulu),
        (#"\bpmtp\b|\bparamount(?:\+|[ .]?plus)"#, .paramountPlus),
        (#"\bpcok\b|\bpeacock[ .]?tv\b"#, .peacock),
        // "CR" is Crunchyroll's tag only when a web release follows it ("CR WEB-DL").
        (#"\bcrunchyroll\b|\bcr(?=[ .\-]+web)"#, .crunchyroll),
    ]

    /// The rules compiled once, in order.
    private static let expressions: [(expression: NSRegularExpression, value: StreamProvider)] = rules.compactMap { rule in
        (try? NSRegularExpression(pattern: rule.pattern)).map { (expression: $0, value: rule.value) }
    }

    /// The service the texts name, or nil when none does. The texts are read in the order given, and an earlier text decides over a later
    /// one: a name or file name that names a service wins over a description that may name another.
    public static func detect(in texts: [String?]) -> StreamProvider? {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let lowered = text.lowercased()
            let range = NSRange(lowered.startIndex..., in: lowered)
            if let rule = expressions.first(where: { $0.expression.firstMatch(in: lowered, range: range) != nil }) {
                return rule.value
            }
        }
        return nil
    }
}

extension StreamProvider {
    /// The services offered as catalogs on Search and in a Streaming Services collection. Hulu is left out: it shows Disney+'s logo, as
    /// it streams from the Disney+ app.
    public static let browsable: [StreamProvider] = [.netflix, .hboMax, .disneyPlus, .primeVideo, .appleTV, .paramountPlus, .peacock,
                                                     .crunchyroll]

    /// TMDb's watch-provider ids for the service, any of which matches. TMDb lists HBO Max, Prime Video and Peacock under more than one.
    public var tmdbProviderIDs: [Int] {
        switch self {
        case .netflix: [8]
        case .primeVideo: [9, 119]
        case .appleTV: [350]
        case .disneyPlus: [337]
        case .hboMax: [1899, 384]
        case .hulu: [15]
        case .paramountPlus: [531]
        case .peacock: [386, 387]
        case .crunchyroll: [283]
        }
    }

    /// Everything TMDb lists on the service in the device's region, films and series together, most popular first. This is the form a
    /// tile or row saves; `catalogRequest(for:)` turns it into what TMDb is asked.
    public var catalogSource: WidgetSource {
        .tmdbDiscover(TMDbDiscoverQuery(providers: providerNames, spansBothKinds: true))
    }

    /// What TMDb is asked for a service's catalog, or the query itself when it is no service's. A service lists only the titles none of
    /// the other browsable services also streams, so the services do not repeat each other's popular titles. Peacock is asked in the US,
    /// the only region TMDb lists it in. Saved tiles and rows keep `catalogSource`, so they ask this way without being saved again.
    static func catalogRequest(for query: TMDbDiscoverQuery) -> TMDbDiscoverQuery {
        guard let service = browsable.first(where: { $0.catalogSource == .tmdbDiscover(query) }) else { return query }
        var request = query
        request.excludedProviders = browsable.filter { $0 != service }.flatMap(\.providerNames)
        if service == .peacock { request.region = "US" }
        return request
    }

    /// The service's TMDb provider ids, named for the service.
    private var providerNames: [TMDbDiscoverQuery.Named] {
        tmdbProviderIDs.map { TMDbDiscoverQuery.Named(id: $0, name: name) }
    }

    /// The service a collection tile names, when its title is the service's name ("Netflix", "HBO Max"), whatever its case.
    public init?(tileTitle: String) {
        let title = tileTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let match = Self.allCases.first(where: { $0.name.lowercased() == title }) else { return nil }
        self = match
    }
}
