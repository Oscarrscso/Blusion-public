import Foundation

/// The headers every Trakt request sends: the API version, the JSON content type and, when there is one, the client ID. `TraktAccount`
/// adds its own user agent, cache policy and bearer token on top; `TraktClient` sends these as they are.
enum TraktHeaders {
    static func common(clientID: String?) -> [String: String] {
        var headers = ["trakt-api-version": "2", "Content-Type": "application/json"]
        if let clientID { headers["trakt-api-key"] = clientID }
        return headers
    }
}
