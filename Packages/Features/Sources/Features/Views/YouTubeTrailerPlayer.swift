#if canImport(UIKit)
import AVFoundation
import StremioKit
import SwiftUI
import UIKit
import WebKit

/// A YouTube trailer in YouTube's own embedded player, inside a web view that the page's panel shows. The page built by
/// `YouTubeLink.embedPage` reports what the player does through the `trailer` message handler, and this class turns those reports into the
/// loader's terms. Links the player opens (the YouTube logo, a new window) leave for the YouTube app or Safari, not the panel.
@MainActor
final class YouTubeTrailerPlayback: NSObject, TrailerPlayback {
    /// The name of the script message handler the page reports through.
    private static let handlerName = "trailer"

    /// What the page has reported so far: the player is still starting, is ready, or cannot play.
    private enum Load {
        case waiting
        case ready
        case failed(TrailerPlaybackError)
    }

    /// The web view that shows the player. The panel puts it on screen.
    let webView: WKWebView
    private(set) var duration: TimeInterval?
    /// YouTube's player does not report the picture's size, so this is nil. The loader then uses the shape from the embed check's answer.
    var aspectRatio: Double? { nil }
    var onFinish: (@MainActor (TrailerPlaybackError?) -> Void)?
    private var playerState = Load.waiting
    /// The address the page was loaded under. Its own navigation is the only one that stays in the panel.
    private var pageURL: URL?
    private var hasActivatedSession = false
    /// True once `play()` has been asked for. A web view that is not on screen yet does not start, so the request is made again when it is.
    private var wantsPlayback = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.preferences.isElementFullscreenEnabled = true
        let handler = WeakMessageHandler()
        configuration.userContentController.add(handler, name: Self.handlerName)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        handler.target = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Loads the page under `baseURL` and waits until the player reports that it is ready (returns), that it cannot play (throws its
    /// reason), or until `timeout` has passed (throws `timedOut`). Polls, so the wait can be cancelled.
    func load(_ html: String, baseURL: URL, timeout: Duration) async throws {
        pageURL = baseURL
        webView.loadHTMLString(html, baseURL: baseURL)
        let clock = ContinuousClock()
        let started = clock.now
        while true {
            switch playerState {
            case .ready: return
            case .failed(let reason): throw reason
            case .waiting: break
            }
            if started.duration(to: clock.now) > timeout { throw TrailerPlaybackError.timedOut }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func play() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        hasActivatedSession = true
        wantsPlayback = true
        webView.evaluateJavaScript("player.playVideo()", completionHandler: nil)
    }

    /// The panel has put the web view on screen. The loader asks for playback before that, and a player that is not visible only buffers,
    /// so playback is asked for once more here.
    func viewDidAppearOnScreen() {
        guard wantsPlayback else { return }
        webView.evaluateJavaScript("player.playVideo()", completionHandler: nil)
    }

    /// Stops the player and empties the page, so no sound goes on. Safe to call more than once.
    func stop() {
        onFinish = nil
        wantsPlayback = false
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
        guard hasActivatedSession else { return }
        hasActivatedSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Takes one message from the page: `ready` with the length, `error` with YouTube's code, or `state` with the player's state.
    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let event = message["event"] as? String else { return }
        switch event {
        case "ready":
            if let seconds = Self.number(message["duration"]), seconds.isFinite, seconds > 0 {
                duration = seconds
                playerState = .ready
            } else {
                playerState = .failed(.unplayable)
            }
        case "error":
            let code = Self.number(message["code"]).map { Int($0) }
            let reason: TrailerPlaybackError = [101, 150, 153].contains(code ?? -1) ? .embeddingRefused : .unplayable
            if case .ready = playerState {
                onFinish?(reason)
            } else {
                playerState = .failed(reason)
            }
        case "state":
            // YouTube's state 0 is ended.
            if Self.number(message["state"]) == 0 { onFinish?(nil) }
        default:
            return
        }
    }

    /// A JSON number as the script message delivers it, which may be an `NSNumber`.
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return value as? Double
    }
}

// MARK: - Navigation

extension YouTubeTrailerPlayback: WKNavigationDelegate, WKUIDelegate {
    /// Keeps the page and its player in the panel. Any other main-frame navigation (the YouTube logo, a link) is opened outside the app.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if navigationAction.targetFrame?.isMainFrame == false || isPage(url) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if let url { UIApplication.shared.open(url) }
    }

    /// True for the page itself: a blank page, or the address the page was loaded under. Only the scheme and host are compared, since
    /// WebKit may write the address with or without a trailing slash.
    private func isPage(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme == "about" { return true }
        guard let pageURL, let host = pageURL.host else { return false }
        return url.scheme == pageURL.scheme && url.host == host
    }

    /// A link that asks for a new window opens outside the app, not in a second web view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { UIApplication.shared.open(url) }
        return nil
    }
}

/// Passes the page's script messages to a playback without keeping it alive. The web view's content controller keeps its handler, so a
/// handler that held the playback would be a retain cycle.
@MainActor
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: YouTubeTrailerPlayback?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message.body)
    }
}

/// Makes YouTube's embedded player for a video and waits until it reports ready.
enum YouTubeTrailerPreparer {
    /// How long the player may take to report that it is ready. A video that cannot be loaded reports so at once.
    static let readyTimeout: Duration = .seconds(12)

    /// The player for `videoID`, ready to start. Throws `TrailerPlaybackError.embeddingRefused` when YouTube will not embed the video, and
    /// another error when the player cannot be made or loaded. The player is stopped on any failure.
    @MainActor
    static func prepare(_ videoID: String) async throws -> any TrailerPlayback {
        guard let origin = YouTubeLink.embedOrigin(bundleID: Bundle.main.bundleIdentifier),
              let page = YouTubeLink.embedPage(videoID: videoID, origin: origin) else { throw TrailerPlaybackError.unplayable }
        let playback = YouTubeTrailerPlayback()
        do {
            try await playback.load(page, baseURL: origin, timeout: readyTimeout)
        } catch {
            playback.stop()
            throw error
        }
        return playback
    }
}

/// The web view of a YouTube trailer's player, shown in the page's panel. The view only shows the playback's web view; the loader stops
/// the playback when it closes.
struct YouTubeTrailerView: UIViewRepresentable {
    let playback: YouTubeTrailerPlayback

    func makeUIView(context: Context) -> WindowAwareView {
        let container = WindowAwareView()
        container.backgroundColor = .black
        return container
    }

    func updateUIView(_ container: WindowAwareView, context: Context) {
        let playback = self.playback
        container.onWindow = { playback.viewDidAppearOnScreen() }
        let webView = playback.webView
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        container.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    /// Leaves the playback alone: the loader stops it when the panel closes.
    static func dismantleUIView(_ container: WindowAwareView, coordinator: ()) {}

    /// A plain view that says when it has been put into a window, which is when what it holds can be seen.
    final class WindowAwareView: UIView {
        var onWindow: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onWindow?() }
        }
    }
}
#endif
