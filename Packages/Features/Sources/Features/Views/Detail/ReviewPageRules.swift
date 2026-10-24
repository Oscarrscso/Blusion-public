import Foundation
import StremioKit

/// What a rating's review page loads with: the ad and tracker requests it may not make, the ad slots it hides, and a script that opens the
/// page's user reviews. These are plain data and script text. `ReviewWebView` compiles and attaches them.
enum ReviewPageRules {
    /// The identifier WebKit keeps the compiled rules under.
    static let identifier = "app.blusion.review-page-rules"

    /// The ad-serving and tracking hosts whose requests are blocked, one rule each: WebKit's content-blocking patterns have no alternation,
    /// so a rule with `(a|b)` makes WebKit reject the whole list. A dot is written `[.]`, so no backslash needs escaping in the JSON.
    private static let adHosts = [
        "doubleclick[.]net", "googlesyndication[.]com", "googleadservices[.]com", "adservice[.]google[.][a-z]+",
        "taboola[.]com", "outbrain[.]com", "criteo[.]com", "criteo[.]net", "amazon-adsystem[.]com", "adnxs[.]com",
        "pubmatic[.]com", "rubiconproject[.]com", "openx[.]net", "moatads[.]com", "scorecardresearch[.]com",
    ]

    /// The ad slots on every site: Google's, and IMDb's sticky bottom ad, a fixed "adhesion" wrapper with inline ad frames inside it.
    private static let adSlots = "ins.adsbygoogle, div[id^=div-gpt-ad], div[id^=adhesion_], div[class*=AdhesionAdSlot], iframe[id^=inline]"

    /// IMDb's own header on its reviews page: the header bar with sign-in and app links, and the white block with Back, the title and the
    /// "User reviews" heading. Only IMDb's pages hide them, so the reviews panel starts at the count and "Add a review".
    private static let imdbHeaderSlots = "#imdbHeader, [data-testid=atf-wrapper-bg], .ipc-scroll-to-top-button"

    /// Rotten Tomatoes' own bars: its header (the leaderboard ad and the navigation bar), the app banner, the notification bar, and its
    /// cookie banner and the shade behind it, which cover the page. Only Rotten Tomatoes' pages hide them, so the reviews panel starts at the
    /// reviews' heading.
    private static let rottenTomatoesHeaderSlots = "#main > header, rt-header, mobile-android-banner, notification-alert, back-to-top, "
        + "#onetrust-consent-sdk, #onetrust-banner-sdk, .onetrust-pc-dark-filter"

    /// TMDB's own bars: its header (logo, menus, search), the bar of title links under it, and the block with the title and "Back to main",
    /// and its cookie banner. Only TMDB's pages hide them, so the reviews panel starts at the first review.
    private static let tmdbHeaderSlots = "header.main-header, .shortcut_bar_outer, #new_shortcut_bar, div.header.small.first, "
        + "#onetrust-consent-sdk, #onetrust-banner-sdk, .onetrust-pc-dark-filter"

    /// Metacritic's own navigation bar (logo, menu, search, sign-in), its cookie banner, and its ads: Fandom's ad slots, which hold their
    /// space (a 300 by 250 box above the reviews, a top banner, more between reviews) before an ad loads. Only Metacritic's pages hide them,
    /// so the reviews panel starts at the title's "User Reviews" and the reviews follow on with no gaps. A content rule keeps applying to
    /// slots the page adds later, as it scrolls.
    private static let metacriticHeaderSlots = "header.c-site-header, #onetrust-consent-sdk, #onetrust-banner-sdk, .onetrust-pc-dark-filter, "
        + ".fandom-ad-wrapper, .fandom-ad-placeholder, .fandom-ad-sticky-container, [id^=incontent_boxad], #top_leaderboard"

    /// WebKit content-blocking rules, as JSON. Requests to ad-serving and tracking hosts are blocked, and the ad slots are hidden where they
    /// remain. Each site's own bars are hidden on that site's pages only: IMDb's, Rotten Tomatoes', TMDB's and Metacritic's.
    static var contentRules: String {
        let blocks = adHosts.map { #"{"trigger": {"url-filter": "\#($0)"}, "action": {"type": "block"}}"# }
        let hides = [#"{"trigger": {"url-filter": ".*"}, "action": {"type": "css-display-none", "selector": "\#(adSlots)"}}"#,
                     #"{"trigger": {"url-filter": "imdb[.]com"}, "action": {"type": "css-display-none", "selector": "\#(imdbHeaderSlots)"}}"#,
                     #"{"trigger": {"url-filter": "rottentomatoes[.]com"}, "action": {"type": "css-display-none", "selector": "\#(rottenTomatoesHeaderSlots)"}}"#,
                     #"{"trigger": {"url-filter": "themoviedb[.]org"}, "action": {"type": "css-display-none", "selector": "\#(tmdbHeaderSlots)"}}"#,
                     #"{"trigger": {"url-filter": "metacritic[.]com"}, "action": {"type": "css-display-none", "selector": "\#(metacriticHeaderSlots)"}}"#]
        return "[\n" + (blocks + hides).joined(separator: ",\n") + "\n]"
    }

    /// The script for a site, run once the page's document is ready. Letterboxd's address for a title opens the film's page, which goes on
    /// to the film's reviews. The other sites load their user reviews after the page, so the script scrolls to their heading once it is
    /// there. RT and Metacritic can also resolve a title search and read the reviews from the page already being loaded.
    static func script(for site: ReviewSite, item: MetaPreview? = nil) -> String {
        if let item, ReviewPageReader.supports(site) { return ReviewPageReader.script(for: site, item: item) }
        switch site {
        case .letterboxd: return letterboxdScript
        case .imdb, .rottenTomatoes, .metacritic, .tmdb: return reviewsHeadingScript
        }
    }

    /// The dark treatment, for IMDb's, Rotten Tomatoes', TMDB's and Metacritic's pages: the page is inverted, then its pictures are inverted
    /// back, so text reads light on a dark ground. Nil for Letterboxd, which keeps its own look. Runs before the page is drawn, so no white
    /// flashes.
    static func darkModeScript(for site: ReviewSite) -> String? {
        isShownDark(site) ? invertedDarkScript : nil
    }

    /// A site's own layout fixes once its bars are hidden, run before the page is drawn. TMDB keeps room above its pages for its fixed
    /// header, so with the header hidden that band goes too. Nil for the other sites, whose bars take their room with them.
    static func layoutScript(for site: ReviewSite) -> String? {
        site == .tmdb ? tmdbLayoutScript : nil
    }

    private static let tmdbLayoutScript = """
    (function () {
      if (!/(^|\\.)themoviedb\\.org$/.test(location.hostname)) return;
      var style = document.createElement('style');
      style.textContent = 'main{margin-top:0 !important}';
      (document.head || document.documentElement).appendChild(style);
    })();
    """

    /// Whether a site's page is shown in the dark treatment, and its web view in dark mode.
    static func isShownDark(_ site: ReviewSite) -> Bool {
        [.imdb, .rottenTomatoes, .tmdb, .metacritic].contains(site)
    }

    private static let invertedDarkScript = """
    (function () {
      var style = document.createElement('style');
      style.textContent = 'html{background:#fff !important;filter:invert(1) hue-rotate(180deg) !important}' +
        'img,video,picture,svg image,[role=img]{filter:invert(1) hue-rotate(180deg) !important}';
      (document.head || document.documentElement).appendChild(style);
    })();
    """

    /// Sends a "Page Not Found" to `fallback`, the site's search for the title. Nil when the address cannot be written into a script.
    static func notFoundScript(fallback: URL) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [fallback.absoluteString]),
              let encoded = String(data: data, encoding: .utf8) else { return nil }
        let target = String(encoded.dropFirst().dropLast())
        return """
        (function () {
          if (/page not found/i.test(document.title)) { location.replace(\(target)); }
        })();
        """
    }

    private static let letterboxdScript = """
    (function () {
      if (/^\\/film\\/[^\\/]+\\/?$/.test(location.pathname)) {
        location.replace(location.pathname.replace(/\\/?$/, '/') + 'reviews/');
      }
    })();
    """

    private static let reviewsHeadingScript = """
    (function () {
      var heading = /^\\s*(user|audience) reviews?\\s*$/i;
      var tries = 0;
      var timer = setInterval(function () {
        tries += 1;
        var nodes = document.querySelectorAll('h1, h2, h3, h4, h5, a, span, button');
        for (var i = 0; i < nodes.length; i++) {
          if (heading.test(nodes[i].textContent || '')) {
            nodes[i].scrollIntoView({ block: 'start' });
            clearInterval(timer);
            return;
          }
        }
        if (tries >= 20) { clearInterval(timer); }
      }, 500);
    })();
    """
}
