import Foundation
import StremioKit
import Testing
import WebKit
@testable import Features

@Suite struct ReviewPageRulesTests {
    @Test func theContentRulesAreWellFormedAndBlockOneHostEach() throws {
        let rules = try #require(JSONSerialization.jsonObject(with: Data(ReviewPageRules.contentRules.utf8)) as? [[String: Any]])
        #expect(rules.count > 1, "a block rule per ad host, then the ad slot hiding")
        for rule in rules {
            let trigger = try #require(rule["trigger"] as? [String: Any])
            let filter = try #require(trigger["url-filter"] as? String)
            #expect(!filter.contains("|"), "WebKit rejects alternation in a url-filter: \(filter)")
        }
        let hides = try rules.suffix(5).map { try #require($0["action"] as? [String: String]) }
        #expect(hides.allSatisfy { $0["type"] == "css-display-none" },
                "the ad slots on every site, then IMDb's, Rotten Tomatoes', TMDB's and Metacritic's bars")
        for rule in rules.dropLast(5) {
            let action = try #require(rule["action"] as? [String: String])
            #expect(action["type"] == "block")
        }
    }

    @MainActor
    @Test func webKitCompilesTheContentRules() async {
        let identifier = "tests.review-page-rules.\(UUID().uuidString)"
        let compiled = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier,
                                                                    encodedContentRuleList: ReviewPageRules.contentRules) { list, error in
                if let error { print("WebKit rejected the review page rules: \(error)") }
                continuation.resume(returning: list != nil)
            }
        }
        #expect(compiled, "WebKit compiles every rule, so none is silently dropped")
    }

    @Test func theDarkModeScriptInvertsEverySiteButLetterboxdAndTheirPicturesBack() {
        for site in [ReviewSite.imdb, .rottenTomatoes, .tmdb, .metacritic] {
            let script = ReviewPageRules.darkModeScript(for: site) ?? ""
            #expect(script.contains("filter:invert(1)"), "\(site.name)'s page is inverted")
            #expect(script.contains("img,video"), "pictures are inverted back")
            #expect(ReviewPageRules.isShownDark(site))
            #expect(script == ReviewPageRules.darkModeScript(for: .imdb), "one treatment, shared")
        }
        #expect(ReviewPageRules.darkModeScript(for: .letterboxd) == nil, "Letterboxd keeps its own look")
        #expect(!ReviewPageRules.isShownDark(.letterboxd))
    }

    @Test func rottenTomatoesBarsAreHiddenOnlyOnItsPages() throws {
        let rules = try #require(JSONSerialization.jsonObject(with: Data(ReviewPageRules.contentRules.utf8)) as? [[String: Any]])
        let rottenTomatoes = rules.first { ($0["trigger"] as? [String: Any])?["url-filter"] as? String == "rottentomatoes[.]com" }
        let selector = try #require(((rottenTomatoes?["action"] as? [String: Any])?["selector"]) as? String)
        for part in ["#main > header", "rt-header", "#onetrust-banner-sdk", ".onetrust-pc-dark-filter"] {
            #expect(selector.contains(part), "\(part) is hidden")
        }
    }

    @Test func tmdbAndMetacriticBarsAreHiddenOnlyOnTheirOwnPages() throws {
        let rules = try #require(JSONSerialization.jsonObject(with: Data(ReviewPageRules.contentRules.utf8)) as? [[String: Any]])
        func selector(_ filter: String) -> String? {
            let rule = rules.first { ($0["trigger"] as? [String: Any])?["url-filter"] as? String == filter }
            return (rule?["action"] as? [String: Any])?["selector"] as? String
        }
        let tmdb = try #require(selector("themoviedb[.]org"))
        for part in ["header.main-header", "#new_shortcut_bar", "div.header.small.first", "#onetrust-banner-sdk"] {
            #expect(tmdb.contains(part), "TMDB's \(part) is hidden")
        }
        let metacritic = try #require(selector("metacritic[.]com"))
        for part in ["header.c-site-header", "#onetrust-banner-sdk", ".fandom-ad-wrapper", ".fandom-ad-placeholder", ".fandom-ad-sticky-container",
                     "[id^=incontent_boxad]", "#top_leaderboard"] {
            #expect(metacritic.contains(part), "Metacritic's \(part) is hidden")
        }
        #expect(!(selector("imdb[.]com") ?? "").contains("c-site-header"), "another site's bars stay on its own pages")
    }

    @Test func rottenTomatoesAndMetacriticShowTheirOwnPages() {
        let item = MetaPreview(id: "tt1517268", type: "movie", name: "Barbie", releaseInfo: "2023")
        #expect(ReviewPageRules.script(for: .rottenTomatoes, item: item).contains(#""reads":false"#))
        let metacritic = ReviewPageRules.script(for: .metacritic, item: item)
        #expect(metacritic.contains(#""reads":false"#), "no reader list is drawn over Metacritic's page")
        #expect(metacritic.contains("if (!rt && !options.reads)"), "its search goes straight to the title's user reviews")
    }

    @Test func tmdbClosesTheBandItsHiddenHeaderLeaves() {
        let script = ReviewPageRules.layoutScript(for: .tmdb) ?? ""
        #expect(script.contains("main{margin-top:0 !important}"))
        #expect(script.contains("themoviedb"), "on TMDB's pages only")
        for site in [ReviewSite.imdb, .letterboxd, .rottenTomatoes, .metacritic] { #expect(ReviewPageRules.layoutScript(for: site) == nil) }
    }

    @Test func theImdbHeaderIsHiddenOnlyOnIMDbPages() throws {
        let rules = try #require(JSONSerialization.jsonObject(with: Data(ReviewPageRules.contentRules.utf8)) as? [[String: Any]])
        let imdb = rules.first { ($0["trigger"] as? [String: Any])?["url-filter"] as? String == "imdb[.]com" }
        let selector = ((imdb?["action"] as? [String: Any])?["selector"]) as? String
        #expect(selector?.contains("[data-testid=atf-wrapper-bg]") == true, "the white header block is hidden on IMDb")
        #expect(selector?.contains("#imdbHeader") == true, "and IMDb's header bar")
    }

    @Test func theLetterboxdScriptGoesOnFromAFilmToItsReviews() {
        let script = ReviewPageRules.script(for: .letterboxd)
        #expect(script.contains("location.replace"))
        #expect(script.contains("'reviews/'"))
    }

    @Test func theOtherSitesScrollToTheirUserReviewsHeading() {
        for site in [ReviewSite.imdb, .rottenTomatoes, .metacritic, .tmdb] {
            #expect(ReviewPageRules.script(for: site).contains("(user|audience) reviews?"), "\(site.name) looks for its user reviews heading")
        }
    }
}
