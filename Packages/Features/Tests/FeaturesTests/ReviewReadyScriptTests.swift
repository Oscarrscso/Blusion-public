#if canImport(JavaScriptCore)
import Foundation
import JavaScriptCore
import Testing

/// The script that says a reviews page is ready (`ReviewPageRules.paintedScript`), run in JavaScriptCore against a stand-in page with a
/// clock the test moves. It is read from the Swift source, as the WebKit build is not compiled on the host.
@Suite struct ReviewReadyScriptTests {
    private static func paintedScript() throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Features/Views/Detail/DetailReviewsPanel.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let start = try #require(text.range(of: "static let paintedScript = #\"\"\"\n"))
        let end = try #require(text.range(of: "\"\"\"#", range: start.upperBound..<text.endIndex))
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// A page with a clock: `cards` review cards (IMDb's, each with a date), a "User reviews" heading that is hidden as IMDb's is by the
    /// content rules, and `readyState`. `run(ms)` moves the clock in 10 ms steps, firing intervals and frames.
    private static let harness = #"""
    var now = 1000; Date.now = function () { return now; };
    var intervals = []; var frames = []; var posted = null; var drawsFrames = true;
    function setInterval(fn, ms) { intervals.push({ fn: fn, ms: ms, next: now + ms, repeats: true }); return intervals.length; }
    function setTimeout(fn, ms) { intervals.push({ fn: fn, ms: ms, next: now + ms, repeats: false }); return intervals.length; }
    function clearInterval(id) { if (id) intervals[id - 1] = null; }
    function requestAnimationFrame(fn) { frames.push(fn); }
    var performance = { now: function () { return now - 1000; } };
    var window = { innerHeight: 800, scrollY: 0, webkit: { messageHandlers: { painted: { postMessage: function (m) { posted = m; } } } } };
    var page = { cards: 0, readyState: 'interactive', stylesLoaded: true };
    var styleSheet = { get sheet() { return page.stylesLoaded ? {} : null; } };
    var location = { hostname: 'm.imdb.com', pathname: '/title/tt0372784/reviews/' };
    function element(text, laidOut) {
      return { textContent: text, nextElementSibling: null, parentElement: null,
               getClientRects: function () { return laidOut ? [1] : []; },
               getBoundingClientRect: function () { return { top: 40, height: laidOut ? 180 : 0 }; },
               closest: function () { return null; } };
    }
    var hiddenHeading = element('User reviews', false);
    var document = {
      body: {},
      get readyState() { return page.readyState; },
      querySelector: function (selector) {
        if (selector.indexOf('review-card-audience') >= 0 && page.cards > 0) {
          return element('Jack F @MovieFan111 4 days ago I am giving it 50/50 because I do not know what to think about it at all.', true);
        }
        if (selector === '#review-card-list [data-object-id]' && page.cards > 0 && !page.imdbCardOnly) {
          return element('A review by Sampson · Written on May 12, 2019 · A landmark of the genre that still holds up decades later.', true);
        }
        if (selector === '.review-footer--user' && page.cards > 0 && !page.imdbCardOnly) {
          var userCard = element('Neo99 · 10 · Oct 3, 2025 · Still the best science fiction film ever made, nothing comes close to it.', true);
          var footer = element('Report', true);
          footer.closest = function () { return userCard; };
          return footer;
        }
        if (selector !== '.review-date' || page.cards === 0) return null;
        var card = element('Shinra788 · Jun 6, 2005 · The Batman film I have been waiting for, and it was worth every minute of it.', true);
        var date = element('Jun 6, 2005', true);
        date.closest = function () { return card; };
        return date;
      },
      querySelectorAll: function (selector) { return selector.indexOf('stylesheet') >= 0 ? [styleSheet] : [hiddenHeading]; }
    };
    function run(ms) {
      var end = now + ms;
      while (now < end) {
        now += 10;
        for (var i = 0; i < intervals.length; i++) {
          var t = intervals[i];
          if (t && now >= t.next) { if (t.repeats) { t.next += t.ms; } else { intervals[i] = null; } t.fn(); }
        }
        if (drawsFrames && now % 20 === 0) { var due = frames; frames = []; for (var j = 0; j < due.length; j++) due[j](); }
      }
    }
    """#

    private func page(cards: Int, readyState: String = "interactive", host: String = "m.imdb.com",
                      path: String = "/title/tt0372784/reviews/") throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(Self.harness)
        context.evaluateScript("page.cards = \(cards); page.readyState = '\(readyState)'; location.hostname = '\(host)'; location.pathname = '\(path)';")
        context.evaluateScript(try Self.paintedScript())
        return context
    }

    private func posted(_ context: JSContext) -> (reason: String, readyMs: Int)? {
        guard let value = context.evaluateScript("posted"), !value.isNull, !value.isUndefined else { return nil }
        return (value.forProperty("reason").toString(), Int(value.forProperty("readyMs").toInt32()))
    }

    /// IMDb's header holds its "User reviews" heading and is hidden, so the heading is never seen. The page used to wait out six seconds
    /// every time; it is ready once its first review card is laid out and two frames are drawn.
    @Test func imdbIsReadyOnItsFirstReviewCardDespiteItsHiddenHeading() throws {
        let context = try page(cards: 1)
        context.evaluateScript("run(200)")
        let ready = try #require(posted(context))
        #expect(ready.reason == "card")
        #expect(ready.readyMs < 100, "within a few frames, not the six-second limit")
    }

    @Test func aPageThatDrawsNoFramesStillOpens() throws {
        let context = try page(cards: 1)
        context.evaluateScript("drawsFrames = false; run(400)")
        let ready = try #require(posted(context))
        #expect(ready.reason == "card")
        #expect(ready.readyMs >= 250 && ready.readyMs < 300)
    }

    @Test func anotherSiteIsNotReadyOnACardThatLooksLikeIMDbs() throws {
        let context = try page(cards: 0, host: "www.metacritic.com", path: "/movie/barbie/user-reviews/")
        context.evaluateScript("page.imdbCardOnly = true; page.cards = 1; run(1000)")
        #expect(posted(context) == nil, "it waits for its own card or heading")
    }

    /// Rotten Tomatoes' own page is shown now: it is ready on its first review card, as IMDb is.
    @Test func rottenTomatoesIsReadyOnItsFirstReviewCard() throws {
        let context = try page(cards: 1, host: "www.rottentomatoes.com", path: "/m/barbie/reviews/all-audience")
        context.evaluateScript("run(200)")
        #expect(posted(context)?.reason == "card")
    }

    /// Its search page leads on to the reviews, so it does not open the panel itself, even once it has loaded.
    @Test func rottenTomatoesSearchWaitsForTheReviewsPage() throws {
        let context = try page(cards: 1, readyState: "complete", host: "www.rottentomatoes.com", path: "/search")
        context.evaluateScript("run(7000)")
        #expect(posted(context) == nil)
        context.evaluateScript("run(1200)")
        #expect(posted(context)?.reason == "no-heading", "after 8 s it opens on whatever is there")
    }

    /// A series' title page leads on to its audience reviews too.
    @Test func rottenTomatoesTitlePageWaitsForTheReviewsPage() throws {
        let context = try page(cards: 1, readyState: "complete", host: "www.rottentomatoes.com", path: "/tv/the_simpsons")
        context.evaluateScript("run(3000)")
        #expect(posted(context) == nil)
    }

    /// TMDB's reviews page has no "User reviews" heading: it is ready on its first review card.
    @Test func tmdbIsReadyOnItsFirstReviewCard() throws {
        let context = try page(cards: 1, host: "www.themoviedb.org", path: "/movie/603/reviews")
        context.evaluateScript("run(200)")
        #expect(posted(context)?.reason == "card")
    }

    /// Metacritic's own user reviews page is shown now: it is ready on its first user review, as Rotten Tomatoes is.
    @Test func metacriticIsReadyOnItsFirstUserReview() throws {
        let context = try page(cards: 1, host: "www.metacritic.com", path: "/movie/barbie/user-reviews/")
        context.evaluateScript("run(200)")
        #expect(posted(context)?.reason == "card")
    }

    /// Its search page leads on to the user reviews, so it does not open the panel itself, even once it has loaded.
    @Test func metacriticSearchWaitsForTheReviewsPage() throws {
        let context = try page(cards: 1, readyState: "complete", host: "www.metacritic.com", path: "/search/barbie/")
        context.evaluateScript("run(7000)")
        #expect(posted(context) == nil)
        context.evaluateScript("run(1200)")
        #expect(posted(context)?.reason == "no-heading", "after 8 s it opens on whatever is there")
    }

    /// IMDb's check starts with the page, before its style sheets have arrived: a card laid out without them is its bare text.
    @Test func aCardIsNotReadyUntilThePagesStylesHaveArrived() throws {
        let context = try page(cards: 0)
        context.evaluateScript("page.stylesLoaded = false; page.cards = 1; run(500)")
        #expect(posted(context) == nil)
        context.evaluateScript("page.stylesLoaded = true; run(200)")
        #expect(posted(context)?.reason == "card")
    }

    @Test func aCardThatArrivesLaterIsReadyWhenItArrives() throws {
        let context = try page(cards: 0)
        context.evaluateScript("run(700)")
        #expect(posted(context) == nil)
        context.evaluateScript("page.cards = 1; run(200)")
        let ready = try #require(posted(context))
        #expect(ready.reason == "card")
        #expect(ready.readyMs >= 700 && ready.readyMs < 900)
    }

    @Test func aLoadedPageWithNothingToWaitForOpensAfterTwoAndAHalfSeconds() throws {
        let context = try page(cards: 0, readyState: "complete")
        context.evaluateScript("run(2400)")
        #expect(posted(context) == nil)
        context.evaluateScript("run(200)")
        let ready = try #require(posted(context))
        #expect(ready.reason == "no-heading")
        #expect(ready.readyMs >= 2500 && ready.readyMs < 2600)
    }

    @Test func aPageStillLoadingWaitsUpToSixSeconds() throws {
        let context = try page(cards: 0, readyState: "interactive")
        context.evaluateScript("run(5900)")
        #expect(posted(context) == nil)
        context.evaluateScript("run(200)")
        #expect(posted(context)?.reason == "no-heading")
    }
}
#endif
