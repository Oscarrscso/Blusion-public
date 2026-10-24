import Foundation
import StremioKit

/// The links that open a YouTube trailer outside Blusion, and the page that plays it inside. Nothing here touches UIKit, so the host tests
/// cover it.
enum YouTubeLink {
    /// The YouTube app's link for `videoID`, or nil unless it is a well-formed YouTube id.
    static func appURL(videoID: String) -> URL? {
        guard Trailer.isYouTubeID(videoID) else { return nil }
        return URL(string: "youtube://www.youtube.com/watch?v=\(videoID)")
    }

    /// The watch page for `videoID`, or nil unless it is a well-formed YouTube id. It is the fallback for a video YouTube will not embed,
    /// when the YouTube app does not open.
    static func webURL(videoID: String) -> URL? {
        guard Trailer.isYouTubeID(videoID) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(videoID)")
    }

    /// The address the embedded player's page is loaded under, which is how the app names itself to YouTube: `https://<bundle id>` in
    /// lowercase. YouTube refuses to play in a page that has no address. A missing or odd bundle id falls back to Blusion's own.
    static func embedOrigin(bundleID: String?) -> URL? {
        let lowercased = bundleID?.lowercased() ?? ""
        let usable = !lowercased.isEmpty && lowercased.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
        return URL(string: "https://\(usable ? lowercased : "app.blusion.player")")
    }

    /// The page holding YouTube's embedded player for `videoID`, or nil unless it is a well-formed YouTube id. The page tells the app what
    /// the player does through the `trailer` message handler: `{event: "ready", duration}`, `{event: "error", code}` and
    /// `{event: "state", state}` (YouTube's player states: 0 ended, 1 playing, 2 paused, 3 buffering).
    static func embedPage(videoID: String, origin: URL) -> String? {
        guard Trailer.isYouTubeID(videoID),
              let encodedOrigin = origin.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}\
        iframe{position:absolute;top:0;left:0;width:100%;height:100%;border:0}</style></head>
        <body>
        <iframe id="player" src="https://www.youtube.com/embed/\(videoID)?enablejsapi=1&playsinline=1&rel=0&origin=\(encodedOrigin)" \
        referrerpolicy="strict-origin-when-cross-origin" \
        allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>
        <script>
        function post(m){ try { window.webkit.messageHandlers.trailer.postMessage(m); } catch (e) {} }
        var player;
        function onYouTubeIframeAPIReady(){
          player = new YT.Player('player', { events: {
            onReady: function(e){ post({event:'ready', duration: e.target.getDuration()}); },
            onError: function(e){ post({event:'error', code: e.data}); },
            onStateChange: function(e){ post({event:'state', state: e.data}); }
          }});
        }
        </script>
        <script src="https://www.youtube.com/iframe_api" onerror="post({event:'error', code:-1})"></script>
        </body></html>
        """
    }
}
