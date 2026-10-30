#if canImport(UIKit)
import StremioKit
import SwiftUI
import UIKit
import WebKit

/// The title's rating buttons, with the reviews of the one tapped open right under them. A tap on a rating shows its site here, in the
/// app, rather than in a browser. They stay open alongside the inline trailer, which sits above them.
struct DetailRatings: View {
    let model: DetailViewModel
    /// False holds the lookup back until the screen allows it (the title page waits for its hero).
    var startsLoading = true
    /// The most width the rating buttons take. The reviews are not held to it: they take the page's full width.
    var buttonsWidth: CGFloat?

    var body: some View {
        // The panel reserves its viewport and padding from the first loading frame.
        VStack(alignment: .leading, spacing: 0) {
            RatingButtonsRow(item: model.detail.preview, startsLoading: startsLoading, openSite: model.openedReviews?.site,
                             isLoading: model.reviewsLoading) { site, url, isSearch in
                model.toggleReviews(site, url: url, isSearch: isSearch)
            }
            .frame(maxWidth: buttonsWidth ?? .infinity, alignment: .leading)
            if let reviews = model.openedReviews {
                DetailReviewsPanel(reviews: reviews, shown: model.shownReviews, item: model.detail.preview, isLoading: model.reviewsLoading,
                                   onLoaded: model.reviewsDidLoad, onClose: model.closeReviews)
                    .padding(.top, Theme.Spacing.m)
            }
        }
    }
}

/// The reviews of one rating's site, on the page: the site's name and a close button over the site itself. It is as wide as the rating
/// buttons above it, and stays until it is closed or another rating is tapped. Another rating's site loads behind the open one, which stays
/// on screen until the new one has loaded.
struct DetailReviewsPanel: View {
    let reviews: DetailViewModel.OpenedReviews
    /// The site kept on screen while `reviews` loads behind it. Nil when `reviews` is the one on screen, or is the first to open.
    var shown: DetailViewModel.OpenedReviews?
    let item: MetaPreview
    /// True until the page has loaded: a spinner shows over it.
    var isLoading = false
    /// Called once the page has loaded, or has failed to.
    var onLoaded: () -> Void = {}
    let onClose: () -> Void
    /// Embedded panels can fit their page to the available scroll viewport.
    var viewportHeight: CGFloat? = nil
    /// The id the page scrolls to when the reviews open, so they are in view.
    static let scrollID = "detail.reviewsPanel"
    /// How tall the site's page is on the page. A Mac window has room for more of it than a phone.
    #if targetEnvironment(macCatalyst)
    private static let pageHeight: CGFloat = 540
    #else
    private static let pageHeight: CGFloat = 440
    /// A phone held sideways has about 390 pt of height, so a taller page would sit past the screen's edge and take the page's drags.
    private static let phoneLandscapeHeight: CGFloat = 300
    #endif
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape
    /// The height a page loaded ahead is laid out at: the panel's, as it is drawn upright.
    static let preloadHeight: CGFloat = pageHeight

    private var pageHeightNow: CGFloat {
        #if targetEnvironment(macCatalyst)
        Self.pageHeight
        #else
        isPhoneLandscape ? Self.phoneLandscapeHeight : Self.pageHeight
        #endif
    }

    /// The site on screen: the one kept while another loads, else the open one.
    private var visible: DetailViewModel.OpenedReviews { isLoading ? shown ?? reviews : reviews }

    /// The pages in the panel: the one kept on screen, then the one loading behind it. Each keeps its view, so the new one is shown as it
    /// loaded, not loaded again.
    private var pages: [DetailViewModel.OpenedReviews] {
        guard let shown, shown.site != reviews.site, isLoading else { return [reviews] }
        return [shown, reviews]
    }

    /// Reserve the full viewport while the first site loads. Keep an existing site visible during switches.
    private var showsSkeleton: Bool { isLoading && (shown == nil || shown?.site == reviews.site) }

    var body: some View {
        let visible = visible
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ReviewSiteIcon(site: visible.site, size: 14, keepsColour: true)
                Text(visible.site.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                if visible.isSearch && !ReviewPageReader.supports(visible.site) {
                    Text("Search")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
                Button {
                    Haptics.tap()
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(visible.site.name) reviews")
                .accessibilityIdentifier("detail.reviews.close")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            Divider()
            ZStack {
                // A new site gets a new page with its own script, so its view is rebuilt rather than reused. Only the page opened last
                // reports its load.
                ForEach(pages, id: \.site) { page in
                    let isVisible = page.site == visible.site
                    ReviewWebView(site: page.site, url: page.url, item: item, onLoaded: page.site == reviews.site ? onLoaded : {})
                        .opacity(isVisible && !showsSkeleton ? 1 : 0)
                        .allowsHitTesting(isVisible && !showsSkeleton)
                        .accessibilityHidden(!isVisible || showsSkeleton)
                }
            }
            .frame(height: viewportHeight ?? pageHeightNow)
            .overlay {
                if showsSkeleton {
                    VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                        ForEach(0..<2, id: \.self) { _ in
                            DetailSkeletonLine(font: .headline, width: 140)
                            DetailSkeletonParagraph(style: .subheadline, lines: 5)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Theme.surface)
                    .clipped()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Loading reviews")
                    .transition(.opacity)
                }
            }
            .accessibilityIdentifier("detail.reviewsWeb")
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: .infinity)
        .detailLoadingTransition(showsSkeleton)
        .id(Self.scrollID)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.reviewsPanel")
    }
}

/// Each open of a rating's reviews, appended to a file in the app's Caches folder: why the page was ready and how long it took from the page
/// start. The file is copied off the device to read the timings.
enum ReviewTimingLog {
    static var fileURL: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("reviews-timings.log")
    }

    static func append(_ timing: [String: Any], site: ReviewSite?) {
        guard let url = fileURL else { return }
        // A debugging aid, not a history: past 256 KB only its newest half is kept, so the latest opens are always in it.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 256_000,
           let old = try? Data(contentsOf: url) {
            try? old.suffix(128_000).write(to: url)
        }
        let reason = timing["reason"] as? String ?? "?"
        let headingMs = timing["headingMs"] as? Int ?? -1
        let readyMs = timing["readyMs"] as? Int ?? -1
        // From the page's start to ready, and from the tap to the panel opening (0 when the page was loaded ahead and ready at the tap).
        let pageMs = timing["pageMs"] as? Int ?? -1
        let tapMs = timing["tapMs"] as? Int ?? -1
        let preloaded = timing["preloaded"] as? Bool ?? false
        let line = "\(Date().formatted(.iso8601)) site=\(site?.name ?? "?") reason=\(reason) headingMs=\(headingMs) readyMs=\(readyMs) "
            + "pageMs=\(pageMs) tapMs=\(tapMs) preloaded=\(preloaded)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

extension ReviewPageRules {
    /// The compiled rules, kept once WebKit has compiled them, so each open attaches them without a wait.
    @MainActor private static var compiled: WKContentRuleList?
    /// A web view kept from launch: it holds a WebKit process that has already started, so the first reviews page does not wait for one.
    @MainActor private static var warmed: WKWebView?

    /// Attaches the content rules to a web view, then calls `ready`. The first open compiles them, which WebKit then keeps; later opens attach
    /// them at once. If they do not compile, `ready` still runs, and the page loads without them.
    @MainActor
    static func attach(to view: WKWebView, then ready: @escaping @MainActor () -> Void) {
        if let compiled {
            view.configuration.userContentController.add(compiled)
            ready()
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: contentRules) { list, _ in
            MainActor.assumeIsolated {
                if let list {
                    compiled = list
                    view.configuration.userContentController.add(list)
                }
                ready()
            }
        }
    }

    /// Compiles the rules and starts a WebKit process at launch, after Home has shown, so the first reviews page waits for neither.
    @MainActor
    static func prewarm() {
        guard warmed == nil else { return }
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        warmed = view
        attach(to: view) { view.loadHTMLString("", baseURL: nil) }
    }

    /// Tells the app that the reviews are on screen and have settled. The panel opens on this, not on the load: a panel that opened before
    /// the page had drawn showed the black the reader saw.
    ///
    /// IMDb's reviews are cards with a date, drawn by the server, so they are in the document when this runs. IMDb's header, which holds its
    /// "User reviews" heading, is hidden by the content rules, so the heading is never seen there: every IMDb open waited out the six-second
    /// limit. IMDb is ready once its first card is laid out with its text, and two frames have been drawn.
    ///
    /// The other sites are ready when their reviews heading is in the viewport, its first review has text, and those have not moved for
    /// 120 ms. A page that has finished loading without a heading or a card opens after 2.5 s; one still loading, after six.
    static let paintedScript = #"""
    (function () {
      var heading = /^\s*(user|audience) reviews?\s*$/i;
      var started = Date.now();
      var headingNode = null;
      var headingAt = 0;
      var lastSignature = '';
      var stableFor = 0;
      var done = false;
      var painting = false;
      var interval = null;

      // Whether the page's style sheets have arrived, so what is laid out is the page as it is drawn, not its bare text. IMDb's script runs
      // as the page starts, before they have.
      function stylesLoaded() {
        var links = document.querySelectorAll('link[rel="stylesheet"]');
        for (var i = 0; i < links.length; i++) { if (!links[i].sheet) return false; }
        return true;
      }

      var isIMDb = /(^|\.)imdb\.com$/.test(location.hostname);
      var isRottenTomatoes = /(^|\.)rottentomatoes\.com$/.test(location.hostname);
      var isMetacritic = /(^|\.)metacritic\.com$/.test(location.hostname);
      var isTMDb = /(^|\.)themoviedb\.org$/.test(location.hostname);
      // Rotten Tomatoes' and Metacritic's search and title pages lead on to their reviews: they wait for that page rather than open early
      // themselves.
      var leadsOn = (isRottenTomatoes && !/\/reviews(\/|$)/.test(location.pathname))
        || (isMetacritic && !/\/(user|critic)-reviews(\/|$)/.test(location.pathname));

      // The first review card, once it is laid out with its text: on IMDb the card that holds the first review date, on Rotten Tomatoes
      // its first review card, on Metacritic the card around its first user review's footer, on TMDB its first review card. Those sites'
      // pages only.
      function firstCard() {
        if (!(isIMDb || isRottenTomatoes || isMetacritic || isTMDb) || !document.body || !stylesLoaded()) return null;
        var card = null;
        if (isIMDb) {
          var date = document.querySelector('.review-date');
          card = date && date.closest('.ipc-list-card, article');
        } else if (isTMDb) {
          card = document.querySelector('#review-card-list [data-object-id]');
        } else if (isMetacritic && !leadsOn) {
          var footer = document.querySelector('.review-footer--user');
          card = footer && footer.closest('.c-reviews-container > *');
        } else if (!leadsOn) {
          card = document.querySelector('review-card-audience, review-card-critic');
        }
        if (!card || (card.textContent || '').trim().length < 60 || card.getClientRects().length === 0) return null;
        return card.getBoundingClientRect().height > 0 ? card : null;
      }

      // A visible element whose top is in the viewport: the heading has been scrolled to.
      function onScreen(el) {
        if (!el || el.getClientRects().length === 0) return false;
        var top = el.getBoundingClientRect().top;
        return top >= -2 && top <= window.innerHeight * 0.9;
      }

      function findHeading() {
        var nodes = document.querySelectorAll('h1, h2, h3, h4, h5, a, span, button');
        for (var i = 0; i < nodes.length; i++) {
          if (heading.test(nodes[i].textContent || '') && nodes[i].getClientRects().length > 0) return nodes[i];
        }
        return null;
      }

      // The first review under the heading: the first visible element after it with a few lines of text.
      function firstReview(h) {
        var scope = h;
        for (var up = 0; up < 4 && scope; up++) {
          var el = scope.nextElementSibling;
          for (var seen = 0; el && seen < 40; seen++) {
            if ((el.textContent || '').trim().length >= 60 && el.getClientRects().length > 0) return el;
            el = el.nextElementSibling;
          }
          scope = scope.parentElement;
        }
        return null;
      }

      function finish(reason) {
        if (done) return;
        done = true;
        clearInterval(interval);
        window.webkit.messageHandlers.painted.postMessage({
          reason: reason,
          headingMs: headingAt ? headingAt - started : -1,
          readyMs: Date.now() - started,
          pageMs: Math.round(performance.now())
        });
      }

      // Ready once the next two frames have been drawn, so what is laid out is on screen when the panel opens. Should frames not be drawn,
      // a quarter of a second does instead, so the panel always opens.
      function finishAfterPaint(reason) {
        if (done || painting) return;
        painting = true;
        clearInterval(interval);
        requestAnimationFrame(function () { requestAnimationFrame(function () { finish(reason); }); });
        setTimeout(function () { finish(reason); }, 250);
      }

      // Every 60 ms, look only at the heading, the first review and the scroll position. Ready when the heading is on screen, the first
      // review has text, and those have not moved for 120 ms. A hard cap of 1.2 s after the heading first shows ends the wait regardless.
      function check() {
        if (done || painting) return;
        var now = Date.now();
        if (firstCard()) return finishAfterPaint('card');
        if (!headingNode || headingNode.getClientRects().length === 0) headingNode = findHeading();
        if (!headingNode) {
          if (leadsOn) {
            if (now - started >= 8000) finish('no-heading');
          } else if (now - started >= 6000 || (now - started >= 2500 && document.readyState === 'complete')) {
            finish('no-heading');
          }
          return;
        }
        if (!headingAt) headingAt = now;
        var review = firstReview(headingNode);
        var h = headingNode.getBoundingClientRect();
        var signature = Math.round(h.top) + ',' + Math.round(window.scrollY);
        if (review) {
          var r = review.getBoundingClientRect();
          signature += '|' + Math.round(r.top) + ',' + Math.round(r.height);
        }
        if (signature === lastSignature) { stableFor += 60; } else { stableFor = 0; lastSignature = signature; }
        var visible = onScreen(headingNode);
        if (visible && review && stableFor >= 120) return finish('stable');
        if (visible && now - headingAt >= 1200) return finish('cap');
        if (!visible && now - headingAt >= 8000) finish('heading-off-screen');
      }

      interval = setInterval(check, 60);
      check();
    })();
    """#

    /// Letterboxd's reviews have no heading the script can find, so its page reports ready after its load and two frames, as it always did.
    static let loadedScript = #"""
    (function () {
      var sent = false;
      function post() {
        if (sent) { return; }
        sent = true;
        window.webkit.messageHandlers.painted.postMessage('painted');
      }
      // Two frames after the load, or a quarter of a second should frames not come (a page loading behind another one).
      function painted() {
        requestAnimationFrame(function () { requestAnimationFrame(post); });
        setTimeout(post, 250);
      }
      if (document.readyState === 'complete') { painted(); } else { window.addEventListener('load', painted); }
    })();
    """#
}

/// A rating's site, loaded in the app with its ads and trackers blocked. The page opens its user reviews when it can. It loads once per
/// address: SwiftUI's re-renders leave the page the reader is on alone.
struct ReviewWebView: UIViewRepresentable {
    let site: ReviewSite
    let url: URL
    let item: MetaPreview
    var onLoaded: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// A web view set up for a site's page: its scripts, its look, and `handler` for the page's "painted" message. Nothing is loaded yet.
    static func configuredWebView(site: ReviewSite, url: URL, item: MetaPreview, handler: WKScriptMessageHandler) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(source: ReviewPageRules.script(for: site, item: item),
                                                                       injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        if let dark = ReviewPageRules.darkModeScript(for: site) {
            configuration.userContentController.addUserScript(WKUserScript(source: dark, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if let layout = ReviewPageRules.layoutScript(for: site) {
            configuration.userContentController.addUserScript(WKUserScript(source: layout, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        // Metacritic's direct address for a title can be wrong; a "Page Not Found" falls back to its search.
        if site == .metacritic, let search = site.url(for: item),
           let fallback = ReviewPageRules.notFoundScript(fallback: search) {
            configuration.userContentController.addUserScript(WKUserScript(source: fallback, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        // The panel opens once the page has painted (see `paintedScript`), so the spinner stays until the reader can see the page. A page with
        // no reviews heading to wait for, such as a search, opens once it has loaded and painted, as Letterboxd's does. IMDb's check starts
        // with the page: its reviews arrive with the page's first bytes, well before the page has finished loading its scripts.
        let waitsForHeading = site.waitsForReviewsHeading(at: url)
        configuration.userContentController.addUserScript(WKUserScript(source: waitsForHeading ? ReviewPageRules.paintedScript : ReviewPageRules.loadedScript,
                                                                       injectionTime: waitsForHeading && ReviewPageRules.isShownDark(site)
                                                                           ? .atDocumentStart : .atDocumentEnd,
                                                                       forMainFrameOnly: true))
        configuration.userContentController.add(handler, name: "painted")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        // IMDb's, Rotten Tomatoes', TMDB's and Metacritic's reviews are shown in the dark, whatever the device's setting; Letterboxd keeps the
        // device's look.
        view.overrideUserInterfaceStyle = ReviewPageRules.isShownDark(site) ? .dark : .unspecified
        return view
    }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        coordinator.site = site
        coordinator.onLoaded = onLoaded
        coordinator.tappedAt = Date()
        // The page loaded ahead when the title opened: it is shown as it is, and the panel opens once it has drawn here.
        if let preloaded = ReviewPreloader.shared.take(site: site, url: url) {
            let view = preloaded.view
            view.navigationDelegate = coordinator
            coordinator.requested = url
            coordinator.preloadedPage = preloaded.page
            preloaded.relay.target = coordinator
            if preloaded.relay.hasPainted {
                coordinator.isReady = true
                DispatchQueue.main.async { coordinator.openWhenDrawn(view, tapped: coordinator.tappedAt ?? Date()) }
            } else if preloaded.page.failed {
                // The load ahead failed: the page loads again now, as it would have without it.
                coordinator.isReady = true
                view.load(URLRequest(url: url))
            } else {
                // Still loading, or about to start once the content rules are in place: it carries on, and its message opens the panel.
                coordinator.isReady = preloaded.page.started
            }
            return view
        }
        let view = Self.configuredWebView(site: site, url: url, item: item, handler: coordinator)
        view.navigationDelegate = coordinator
        coordinator.requested = url
        ReviewPageRules.attach(to: view) {
            // The page loads once its rules are in place, at the address asked for last.
            coordinator.isReady = true
            if let latest = coordinator.requested { view.load(URLRequest(url: latest)) }
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onLoaded = onLoaded
        guard coordinator.requested != url else { return }
        coordinator.requested = url
        // Before the rules are in place, the load that is waiting for them picks up this address.
        guard coordinator.isReady else { return }
        view.load(URLRequest(url: url))
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        // A compilation callback still waiting for the content rules must not reopen a dismissed page, whether it is this view's own or
        // the one of a page loaded ahead.
        coordinator.requested = nil
        coordinator.preloadedPage?.wanted = false
        view.stopLoading()
        view.navigationDelegate = nil
        // WebKit keeps a message handler until it is removed, so the view's handler goes with it.
        view.configuration.userContentController.removeScriptMessageHandler(forName: "painted")
    }

    /// The address last asked for, whether the rules are in place, and what to call when the page has loaded, so a re-render does not
    /// load the page again.
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var requested: URL?
        var isReady = false
        var onLoaded: () -> Void = {}
        var site: ReviewSite?
        /// When the rating was tapped, for the timing log.
        var tappedAt: Date?
        /// The page loaded ahead that this view took, if it took one.
        var preloadedPage: ReviewPreloader.Page?

        /// The load itself does not open the panel: the page has still to paint, and `painted` says so.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {}
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onLoaded() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onLoaded() }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            painted(message.body, preloaded: false)
        }

        /// The page says it is ready. Per open, the timing is logged: why it was ready, and how long the page and the tap took.
        func painted(_ body: Any, preloaded: Bool) {
            if var timing = body as? [String: Any] {
                timing["tapMs"] = tappedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
                timing["preloaded"] = preloaded
                ReviewTimingLog.append(timing, site: site)
            }
            onLoaded()
        }

        /// A page loaded ahead, ready before the tap: the panel opens once the page has drawn two frames in its new place, so it never
        /// opens on a blank frame. A quarter of a second does instead, should frames not be drawn.
        func openWhenDrawn(_ view: WKWebView, tapped: Date) {
            var opened = false
            let open = { [weak self] in
                guard !opened, let self else { return }
                opened = true
                self.painted(["reason": "preloaded", "tapMs": 0], preloaded: true)
            }
            view.callAsyncJavaScript("await new Promise(function (r) { requestAnimationFrame(function () { requestAnimationFrame(r); }); }); return 1;",
                                     arguments: [:], in: nil, in: .page) { _ in open() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { open() }
        }
    }
}

/// Passes a preloaded page's "painted" message on to the panel that shows it, once there is one, and remembers that it came, so a page
/// that was ready before the tap opens at once.
@MainActor
final class ReviewPaintRelay: NSObject, WKScriptMessageHandler {
    weak var target: ReviewWebView.Coordinator?
    private(set) var hasPainted = false

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        hasPainted = true
        target?.painted(message.body, preloaded: true)
    }
}

/// IMDb's reviews for the title on screen, loaded in the background once its page has settled, so a tap on its IMDb rating shows them
/// at once instead of waiting for IMDb's heavy page. One page at a time: another title's replaces it, and leaving the title drops it.
@MainActor
final class ReviewPreloader {
    static let shared = ReviewPreloader()

    /// One page loaded ahead: whether its load has started (it waits for the content rules), whether it failed, and whether it is still
    /// wanted, by this preloader or by the panel that took it.
    final class Page: NSObject, WKNavigationDelegate {
        let site: ReviewSite
        let url: URL
        let view: WKWebView
        let relay: ReviewPaintRelay
        var started = false
        var failed = false
        var wanted = true

        init(site: ReviewSite, url: URL, view: WKWebView, relay: ReviewPaintRelay) {
            self.site = site
            self.url = url
            self.view = view
            self.relay = relay
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed = true }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed = true }
    }

    private var page: Page?

    /// Starts loading `url` for `site`, unless it is already the page loaded. The page is laid out at about the panel's size, so it is
    /// drawn as it will be shown.
    func preload(site: ReviewSite, url: URL, item: MetaPreview, width: CGFloat) {
        if let page, page.site == site, page.url == url { return }
        discard()
        let relay = ReviewPaintRelay()
        let view = ReviewWebView.configuredWebView(site: site, url: url, item: item, handler: relay)
        view.frame = CGRect(x: 0, y: 0, width: max(320, width), height: DetailReviewsPanel.preloadHeight)
        let page = Page(site: site, url: url, view: view, relay: relay)
        view.navigationDelegate = page
        self.page = page
        // A page taken by the panel before its rules were in place still starts here; one that was dropped does not.
        ReviewPageRules.attach(to: view) {
            guard page.wanted else { return }
            page.started = true
            if let coordinator = relay.target { coordinator.isReady = true }
            view.load(URLRequest(url: url))
        }
    }

    /// The page loaded for `site` at `url`, handed over to the panel that shows it; nil when another page, or none, was loaded.
    func take(site: ReviewSite, url: URL) -> (view: WKWebView, relay: ReviewPaintRelay, page: Page)? {
        guard let page, page.site == site, page.url == url else { return nil }
        self.page = nil
        return (page.view, page.relay, page)
    }

    /// Drops the loaded page: all of them, or only the one at `url`.
    func discard(url: URL? = nil) {
        guard let page, url == nil || page.url == url else { return }
        page.wanted = false
        page.view.stopLoading()
        page.view.navigationDelegate = nil
        page.view.configuration.userContentController.removeScriptMessageHandler(forName: "painted")
        self.page = nil
    }
}
#endif
