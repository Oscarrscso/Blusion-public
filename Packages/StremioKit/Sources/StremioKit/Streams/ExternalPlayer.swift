import Foundation

/// A video player app that streams can be handed to instead of Blusion's own player.
public enum ExternalPlayer: String, Sendable, Codable, CaseIterable, Identifiable, Hashable {
    case infuse

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .infuse: return "Infuse"
        }
    }

    /// The URL scheme the app answers to. It has to be listed under `LSApplicationQueriesSchemes` for the system to say
    /// whether the app is installed.
    public var scheme: String {
        switch self {
        case .infuse: return "infuse"
        }
    }

    /// Where to get the app.
    public var appStoreURL: URL? {
        switch self {
        case .infuse: return URL(string: "https://apps.apple.com/app/id1136220934")
        }
    }
}

/// One video handed to another player app: the stream and what the player should know about it.
public struct ExternalPlaybackRequest: Sendable, Equatable {
    /// The stream itself: an http(s) URL the player fetches on its own.
    public var streamURL: URL
    /// Where to start, in whole seconds. nil and 0 are left out of the link.
    public var position: Int?
    /// A name in Infuse's style (see `ExternalPlayerCallback.filename`), which lets the player find the artwork.
    public var filename: String?
    public var subtitleURL: URL?
    /// Called once when playback ends or the player closes. The player appends `lastPlayedUrl` and `position`.
    public var successCallback: URL?
    /// Called once when the player fails. The player appends `errorCode`, `errorMessage` and `failedUrl`.
    public var errorCallback: URL?

    public init(streamURL: URL, position: Int? = nil, filename: String? = nil, subtitleURL: URL? = nil, successCallback: URL? = nil,
                errorCallback: URL? = nil) {
        self.streamURL = streamURL
        self.position = position
        self.filename = filename
        self.subtitleURL = subtitleURL
        self.successCallback = successCallback
        self.errorCallback = errorCallback
    }
}

extension ExternalPlayer {
    /// The link that makes the player app play `request`, in its x-callback form. Parameters come in the order url, position,
    /// filename, sub, x-success, x-error; nil and empty ones are left out. Every value is percent-encoded with unreserved
    /// characters only, so the player reads back exactly the URL it was given.
    public func playURL(for request: ExternalPlaybackRequest) -> URL? {
        var parameters: [(name: String, value: String)] = [("url", request.streamURL.absoluteString)]
        if let position = request.position, position > 0 { parameters.append(("position", String(position))) }
        if let filename = request.filename, !filename.isEmpty { parameters.append(("filename", filename)) }
        if let subtitleURL = request.subtitleURL { parameters.append(("sub", subtitleURL.absoluteString)) }
        return callbackURL(action: "play", parameters: parameters, request: request)
    }

    /// The link that saves `request`'s stream to the player app's library, optionally starting an offline download. Parameters
    /// come in the order url, filename, sub, download, x-success, x-error; the position is not sent, and nil and empty ones are left
    /// out. Encoded as `playURL(for:)` is.
    public func saveURL(for request: ExternalPlaybackRequest, download: Bool = false) -> URL? {
        var parameters: [(name: String, value: String)] = [("url", request.streamURL.absoluteString)]
        if let filename = request.filename, !filename.isEmpty { parameters.append(("filename", filename)) }
        if let subtitleURL = request.subtitleURL { parameters.append(("sub", subtitleURL.absoluteString)) }
        parameters.append(("download", download ? "1" : "0"))
        return callbackURL(action: "save", parameters: parameters, request: request)
    }

    /// `scheme://x-callback-url/<action>?…`, with the request's callbacks after `parameters`.
    private func callbackURL(action: String, parameters: [(name: String, value: String)], request: ExternalPlaybackRequest) -> URL? {
        var parameters = parameters
        if let successCallback = request.successCallback { parameters.append(("x-success", successCallback.absoluteString)) }
        if let errorCallback = request.errorCallback { parameters.append(("x-error", errorCallback.absoluteString)) }
        let query = parameters.map { "\($0.name)=\(linkEncoded($0.value))" }.joined(separator: "&")
        return URL(string: "\(scheme)://x-callback-url/\(action)?\(query)")
    }

    /// True when this player can be given the stream: an http(s) URL that needs no request headers. The player fetches the stream
    /// itself and cannot send Blusion's headers, so a stream that needs them stays in Blusion.
    public func canPlay(streamURL: URL, headers: [String: String]) -> Bool {
        guard headers.isEmpty, let scheme = streamURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              streamURL.host != nil else { return false }
        return true
    }
}

extension MediaContainer {
    /// The extension a file of this container usually has, for naming a hand-off (see `ExternalPlayerCallback.filename`).
    public var fileExtension: String {
        switch self {
        case .mp4: return "mp4"
        case .mov: return "mov"
        case .m4v: return "m4v"
        case .hls: return "m3u8"
        case .matroska: return "mkv"
        case .webm: return "webm"
        case .avi: return "avi"
        case .mpegTS: return "ts"
        case .mpegPS: return "mpg"
        case .flv: return "flv"
        case .ogg: return "ogg"
        case .asf: return "wmv"
        case .wav: return "wav"
        case .mp3: return "mp3"
        }
    }
}

/// What the player app reported when it was done.
public enum ExternalPlaybackResult: Sendable, Equatable {
    /// Playback ended or the viewer closed the player. `position` is where they stopped, when the app said so.
    case finished(position: TimeInterval?)
    /// The player could not play the stream. The app's code and message, when it sent them.
    case failed(code: String?, message: String?)
}

/// The callback links Blusion gives a player app, and how Blusion reads them back when the player calls.
public enum ExternalPlayerCallback {
    private static let scheme = "blusion"
    private static let host = "x-callback-url"

    /// `blusion://x-callback-url/handoff/<token>/finished`. The token is in the path, so whatever the player appends as a query
    /// stays separate from it.
    public static func successURL(token: String) -> URL? {
        callbackURL(token: token, outcome: "finished")
    }

    /// `blusion://x-callback-url/handoff/<token>/failed`
    public static func errorURL(token: String) -> URL? {
        callbackURL(token: token, outcome: "failed")
    }

    /// `blusion://x-callback-url/saved`: where the player app comes back to once it has saved a stream. It only brings Blusion back, so
    /// `parse(_:)` does not read it.
    public static let savedURL = URL(string: "\(scheme)://\(host)/saved")

    /// Reads one of the two URLs above as the player called it back (with its query). nil for any other URL.
    /// Lenient: accepts `position` as an integer or decimal string, ignores unknown parameters and a missing query.
    public static func parse(_ url: URL) -> (token: String, result: ExternalPlaybackResult)? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // Split before decoding, so an encoded slash inside a token cannot change the path's shape.
        let segments = components.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding ?? "" }
        guard segments.count == 3, segments[0] == "handoff", !segments[1].isEmpty else { return nil }
        let query = components.queryItems ?? []
        // The player appends its own parameters after the stream's URL, which it does not encode: when that URL has a query of
        // its own, its parameters come first, so the player's are the last ones with their name.
        func value(_ name: String) -> String? {
            guard let text = query.last(where: { $0.name == name })?.value, !text.isEmpty else { return nil }
            return text
        }
        switch segments[2] {
        case "finished":
            let position = value("position").flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil }
            return (segments[1], .finished(position: position))
        case "failed":
            return (segments[1], .failed(code: value("errorCode"), message: value("errorMessage")))
        default:
            return nil
        }
    }

    /// A file name in Infuse's style, so it finds the artwork: "Inception-2010.mkv", "Breaking-Bad-S02-E05.mkv", "Some-Title.mp4".
    /// Words are joined with "-", characters other than letters, digits and "-" are dropped, the extension is lower-cased and
    /// defaults to "mp4" when nil or empty. A season and episode take the place of the year.
    public static func filename(title: String, year: String?, season: Int?, episode: Int?, fileExtension: String?) -> String {
        var name = nameWords(title)
        if name.isEmpty { name = "Video" }
        if let season, let episode {
            name += "-S\(twoDigits(season))-E\(twoDigits(episode))"
        } else if let year = StreamRequest.releaseYear(in: year) {
            name += "-" + year
        }
        let ext = (fileExtension ?? "").lowercased().filter { $0.isLetter || ($0.isASCII && $0.isNumber) }
        return name + "." + (ext.isEmpty ? "mp4" : ext)
    }

    private static func callbackURL(token: String, outcome: String) -> URL? {
        guard !token.isEmpty, let encoded = token.addingPercentEncoding(withAllowedCharacters: linkUnreserved) else { return nil }
        return URL(string: "\(scheme)://\(host)/handoff/\(encoded)/\(outcome)")
    }

    /// The words of `text` joined with "-". Each word keeps only letters, digits and "-"; words left empty are dropped.
    private static func nameWords(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .map { word -> String in
                let kept = String(word.filter { $0.isLetter || ($0.isASCII && $0.isNumber) || $0 == "-" })
                return kept.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            }
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    private static func twoDigits(_ number: Int) -> String {
        let value = max(0, number)
        return value < 10 ? "0\(value)" : "\(value)"
    }
}

/// Percent-encodes a link query value. Only letters, digits and `-._~` pass, so `:`, `/`, `&`, `=`, `?`, `#` and spaces are escaped too.
private func linkEncoded(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: linkUnreserved) ?? value
}

private let linkUnreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

/// Which player a stream opens in.
public enum PlayerPreference: String, Sendable, Codable, CaseIterable, Identifiable, Hashable {
    /// Blusion's own player.
    case builtIn
    /// Every stream Infuse can take is handed to Infuse.
    case infuse
    /// Blusion's own player, and Infuse only for formats it cannot play (MKV, DTS and the like).
    case infuseWhenNeeded

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .builtIn: return "Blusion"
        case .infuse: return "Infuse"
        case .infuseWhenNeeded: return "Infuse for formats Blusion can't play"
        }
    }

    /// The app this preference hands streams to, if any.
    public var externalPlayer: ExternalPlayer? {
        switch self {
        case .builtIn: return nil
        case .infuse, .infuseWhenNeeded: return .infuse
        }
    }
}
