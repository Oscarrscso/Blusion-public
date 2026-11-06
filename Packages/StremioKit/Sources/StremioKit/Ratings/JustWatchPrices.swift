import Foundation

/// A title's prices to rent and to buy in one country: what each store asks for each picture quality. Also the services it streams on.
public struct TitlePrices: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case rent = "RENT"
        case buy = "BUY"

        public var label: String { self == .rent ? "Rent" : "Buy" }
    }

    /// A picture quality, lowest first.
    public enum Quality: Int, Sendable, Comparable, CaseIterable {
        case sd, hd, uhd

        public var label: String {
            switch self {
            case .sd: "SD"
            case .hd: "HD"
            case .uhd: "4K"
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        init?(justWatch: String) {
            switch justWatch {
            case "SD": self = .sd
            case "HD": self = .hd
            case "_4K": self = .uhd
            default: return nil
            }
        }
    }

    public struct Offer: Sendable, Equatable {
        public let kind: Kind
        public let quality: Quality
        public let store: String
        public let price: Double
        /// ISO 4217, such as "EUR".
        public let currency: String
        /// True for a price converted from another currency (see `JustWatchPrices.localPrices`).
        public let isConverted: Bool

        public init(kind: Kind, quality: Quality, store: String, price: Double, currency: String, isConverted: Bool = false) {
            self.kind = kind
            self.quality = quality
            self.store = store
            self.price = price
            self.currency = currency
            self.isConverted = isConverted
        }

        /// The price in the device's style, such as "€3.99"; a converted one is marked as near: "≈€4.79".
        public var priceText: String { (isConverted ? "≈" : "") + price.formatted(.currency(code: currency)) }
    }

    public let offers: [Offer]
    /// The services it streams on, each once: subscriptions first, then free ones, in JustWatch's order.
    public let streamers: [String]

    public init(offers: [Offer], streamers: [String] = []) {
        self.offers = offers
        self.streamers = streamers
    }

    /// The cheapest rent in the best quality any store rents the title in. Nil when none rents it.
    public var bestRent: Offer? {
        let rents = offers.filter { $0.kind == .rent }
        guard let best = rents.map(\.quality).max() else { return nil }
        return rents.filter { $0.quality == best }.min { $0.price < $1.price }
    }

    /// The offers of one kind in one quality, cheapest first.
    public func cheapest(_ kind: Kind, _ quality: Quality) -> [Offer] {
        offers.filter { $0.kind == kind && $0.quality == quality }.sorted { $0.price < $1.price }
    }
}

/// A movie's or series' rent and buy prices from JustWatch, the source of TMDb's watch providers. The title is searched by name and the
/// match is the entry with its IMDb id (or, for another id, its name and a release year within one).
public struct JustWatchPrices: Sendable {
    static let endpoint = URL(string: "https://apis.justwatch.com/graphql")!
    private static let kept = KeptAnswers<TitlePrices?>()

    let client: AddonClient

    public init(client: AddonClient) { self.client = client }

    /// The prices in `country` (a region code such as "IE") of the movie (`type` "movie") or series (`type` "series") with `id`. Nil when
    /// JustWatch has no match, nothing sells, rents or streams it there, or for another type. Kept for the session; a failed lookup is asked again.
    public func prices(id: String, title: String, year: Int?, type: String, country: String) async throws -> TitlePrices? {
        guard let objectType = Self.objectType(type), !ITunesTrailers.normalized(title).isEmpty else { return nil }
        let country = country.uppercased()
        let key = "\(type)|\(id)|\(country)"
        let client = client
        return try await Self.kept.value(for: key) {
            let body = try Self.requestBody(title: title, objectType: objectType, country: country)
            let result = try await client.post(Self.endpoint, body: body, limits: FetchLimits(maxBytes: 512 * 1024), timeout: 8)
            return try Self.parse(result.data, id: id, title: title, year: year)
        }
    }

    /// Countries whose stores JustWatch often lists without prices, and the neighbour whose prices stand in for them.
    static let neighbours = ["IE": "GB"]

    /// The prices in `country` as `prices` gives them, in its own currency. When JustWatch lists no rent or buy price there, the
    /// neighbour's (`neighbours`) stand in, and the country's own streaming services are kept. A price in another currency (the
    /// neighbour's pounds, say) is converted at the day's European Central Bank rate and marked as near; without a rate it stays as it is.
    public func localPrices(id: String, title: String, year: Int?, type: String, country: String) async throws -> TitlePrices? {
        let local = try await prices(id: id, title: title, year: year, type: type, country: country)
        var chosen = local
        if local?.offers.isEmpty ?? true, let neighbour = Self.neighbours[country.uppercased()],
           let other = try? await prices(id: id, title: title, year: year, type: type, country: neighbour), !other.offers.isEmpty {
            chosen = TitlePrices(offers: other.offers, streamers: local?.streamers ?? [])
        }
        guard let picked = chosen, let currency = Self.currency(of: country) else { return chosen }
        let rates = ExchangeRates(client: client)
        var rateByCurrency: [String: Double] = [:]
        for source in Set(picked.offers.map(\.currency)) where source != currency {
            rateByCurrency[source] = try? await rates.rate(from: source, to: currency)
        }
        guard !rateByCurrency.isEmpty else { return picked }
        let offers = picked.offers.map { offer -> TitlePrices.Offer in
            guard let rate = rateByCurrency[offer.currency] else { return offer }
            return TitlePrices.Offer(kind: offer.kind, quality: offer.quality, store: offer.store,
                                     price: (offer.price * rate * 100).rounded() / 100, currency: currency, isConverted: true)
        }
        return TitlePrices(offers: offers, streamers: picked.streamers)
    }

    /// The currency a country pays in: "EUR" for "IE".
    static func currency(of country: String) -> String? {
        Locale(identifier: "en_\(country.uppercased())").currency?.identifier
    }

    static func objectType(_ type: String) -> String? {
        switch type {
        case "movie": "MOVIE"
        case "series": "SHOW"
        default: nil
        }
    }

    static func requestBody(title: String, objectType: String, country: String) throws -> Data {
        let query = """
        query TitlePrices($country: Country!, $language: Language!, $search: String!, $types: [ObjectType!]) {
          popularTitles(country: $country, first: 5, filter: {searchQuery: $search, objectTypes: $types}) {
            edges { node {
              content(country: $country, language: $language) { title originalReleaseYear externalIds { imdbId } }
              offers(country: $country, platform: WEB) { monetizationType presentationType retailPriceValue currency package { clearName } }
            } }
          }
        }
        """
        let variables: [String: Any] = [
            "country": country,
            "language": "en",
            "search": title.trimmingCharacters(in: .whitespacesAndNewlines),
            "types": [objectType],
        ]
        return try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    }

    /// The prices and streaming services of the matching entry in an answer. Nil without a match or when it has neither; an answer with
    /// errors and no data (a country JustWatch does not cover) has no match. Throws `invalidJSON` when the answer is not JSON of that shape.
    public static func parse(_ data: Data, id: String, title: String, year: Int?) throws -> TitlePrices? {
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) } catch { throw AddonError.invalidJSON }
        let nodes = response.data?.popularTitles?.edges?.compactMap(\.node) ?? []
        let node: Node?
        if id.hasPrefix("tt") {
            node = nodes.first { $0.content?.externalIds?.imdbId == id }
        } else {
            let wanted = ITunesTrailers.normalized(title)
            node = nodes.first { candidate in
                guard let content = candidate.content, ITunesTrailers.normalized(content.title ?? "") == wanted else { return false }
                guard let year else { return true }
                guard let released = content.originalReleaseYear else { return false }
                return abs(released - year) <= 1
            }
        }
        var seen = Set<String>()
        let offers = (node?.offers ?? []).compactMap { offer -> TitlePrices.Offer? in
            guard let kind = offer.monetizationType.flatMap(TitlePrices.Kind.init(rawValue:)),
                  let quality = offer.presentationType.flatMap(TitlePrices.Quality.init(justWatch:)),
                  let price = offer.retailPriceValue, price > 0,
                  let currency = offer.currency, !currency.isEmpty,
                  let store = offer.package?.clearName, !store.isEmpty,
                  seen.insert("\(kind.rawValue)|\(quality.rawValue)|\(store)").inserted else { return nil }
            return TitlePrices.Offer(kind: kind, quality: quality, store: store, price: price, currency: currency)
        }
        var seenStreamers = Set<String>()
        let streamers = Self.streamingTypes.flatMap { type in
            (node?.offers ?? []).filter { $0.monetizationType == type }.compactMap(\.package?.clearName)
        }
        .filter { !$0.isEmpty && seenStreamers.insert($0).inserted }
        return offers.isEmpty && streamers.isEmpty ? nil : TitlePrices(offers: offers, streamers: streamers)
    }

    /// JustWatch's kinds of streaming offer: a subscription, then free with or without ads.
    static let streamingTypes = ["FLATRATE", "FREE", "ADS"]

    private struct Response: Decodable { let data: ResponseData? }
    private struct ResponseData: Decodable { let popularTitles: Connection? }
    private struct Connection: Decodable { let edges: [Edge]? }
    private struct Edge: Decodable { let node: Node? }
    private struct Node: Decodable {
        let content: Content?
        let offers: [Offer]?
    }
    private struct Content: Decodable {
        let title: String?
        let originalReleaseYear: Int?
        let externalIds: ExternalIDs?
    }
    private struct ExternalIDs: Decodable { let imdbId: String? }
    private struct Offer: Decodable {
        let monetizationType: String?
        let presentationType: String?
        let retailPriceValue: Double?
        let currency: String?
        let package: Package?
    }
    private struct Package: Decodable { let clearName: String? }
}

/// The European Central Bank's reference rates, from Frankfurter (api.frankfurter.dev: free, no key), each pair kept for the session.
struct ExchangeRates: Sendable {
    static let endpoint = URL(string: "https://api.frankfurter.dev/v1/latest")!
    private static let kept = KeptAnswers<Double>()

    let client: AddonClient

    /// What one unit of `source` is worth in `target`. Throws when the service fails or does not know the pair.
    func rate(from source: String, to target: String) async throws -> Double {
        let client = client
        return try await Self.kept.value(for: "\(source)>\(target)") {
            var parts = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)
            parts?.queryItems = [URLQueryItem(name: "base", value: source), URLQueryItem(name: "symbols", value: target)]
            guard let url = parts?.url else { throw AddonError.invalidURL }
            let result = try await client.get(url, headers: ["Accept": "application/json"], limits: FetchLimits(maxBytes: 16 * 1024), timeout: 8)
            return try Self.parse(result.data, target: target)
        }
    }

    static func parse(_ data: Data, target: String) throws -> Double {
        struct Answer: Decodable { let rates: [String: Double] }
        guard let rate = (try? JSONDecoder().decode(Answer.self, from: data))?.rates[target], rate > 0 else { throw AddonError.invalidJSON }
        return rate
    }
}
