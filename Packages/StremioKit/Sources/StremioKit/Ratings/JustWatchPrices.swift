import Foundation

/// A title's prices to rent and to buy in one country: what each store asks for each picture quality.
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

        public init(kind: Kind, quality: Quality, store: String, price: Double, currency: String) {
            self.kind = kind
            self.quality = quality
            self.store = store
            self.price = price
            self.currency = currency
        }

        /// The price in the device's style, such as "€3.99".
        public var priceText: String { price.formatted(.currency(code: currency)) }
    }

    public let offers: [Offer]

    public init(offers: [Offer]) { self.offers = offers }

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
    /// JustWatch has no match, no store sells or rents it there, or for another type. Kept for the session; a failed lookup is asked again.
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

    /// The prices of the matching entry in an answer. Nil without a match or when it has no rent or buy offer; an answer with errors and
    /// no data (a country JustWatch does not cover) has no match. Throws `invalidJSON` when the answer is not JSON of that shape.
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
        return offers.isEmpty ? nil : TitlePrices(offers: offers)
    }

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
