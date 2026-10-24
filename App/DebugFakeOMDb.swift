#if DEBUG
import Features
import Foundation
import StremioKit

/// `BLUSION_FAKE_OMDB=1` answers OMDb lookups (episode scores) from here, after a short random delay, so the rating flow can be driven on a
/// device without a key or a network (the scroll stress test in `Tests/BlusionUITests` uses it). Roughly one title in three has no
/// IMDb score, as real catalogs do. Debug builds only, and only when asked for.
struct DebugFakeOMDbTransport: HTTPTransport {
    func send(_ request: URLRequest, limits: FetchLimits) async throws -> HTTPResult {
        try await Task.sleep(for: .milliseconds(Int.random(in: 80...450)))
        let id = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "i" }?.value ?? ""
        let seed = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let body: String
        if seed % 3 == 0 {
            body = #"{"Response":"True","imdbRating":"N/A","Metascore":"N/A","Ratings":[]}"#
        } else {
            let score = 5.0 + Double(seed % 40) / 10
            body = #"{"Response":"True","imdbRating":"\#(String(format: "%.1f", score))","Metascore":"\#(40 + seed % 55)","#
                + #""Ratings":[{"Source":"Rotten Tomatoes","Value":"\#(30 + seed % 70)%"}]}"#
        }
        return HTTPResult(data: Data(body.utf8), response: HTTPResponseInfo(statusCode: 200, url: request.url))
    }
}

extension DebugDemoData {
    /// With `BLUSION_FAKE_OMDB=1`, the poster ratings use the fake OMDb above instead of the key in Settings.
    static func installFakeOMDbIfRequested(_ services: AppServices, environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard environment["BLUSION_FAKE_OMDB"] == "1" else { return }
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: 5, maxRetries: 0), transport: DebugFakeOMDbTransport())
        await services.posterRatings.setReviewServices(omdb: OMDbRatings(client: client, apiKey: "debug"), tmdb: nil)
    }
}
#endif
