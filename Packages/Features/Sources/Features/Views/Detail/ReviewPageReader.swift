import Foundation
import StremioKit

/// An on-demand reader inside the existing WebKit page. It makes no API requests: it chooses a matching search result, opens its
/// audience reviews, and reads the public document. The original page stays alive underneath, so browsing never needs a second load.
enum ReviewPageReader {
    static func supports(_ site: ReviewSite) -> Bool { site == .rottenTomatoes || site == .metacritic }

    /// Whether the reader shows its own list of the reviews over the page. Neither site's does: Rotten Tomatoes' and Metacritic's own pages
    /// are shown, and the reader only takes a search to the title's audience or user reviews.
    static func reads(_ site: ReviewSite) -> Bool { false }

    static func script(for site: ReviewSite, item: MetaPreview) -> String {
        guard supports(site) else { return "" }
        var options: [String: Any] = ["site": site.rawValue, "title": item.name, "kind": item.type == "movie" ? "movie" : "tv",
                                      "reads": reads(site)]
        if let year = item.releaseInfo.flatMap({ Int($0.prefix(4)) }) { options["year"] = year }
        guard let data = try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return template.replacingOccurrences(of: "__BLUSION_OPTIONS__", with: json)
    }

    // Raw JavaScript keeps its regexes literal. Options are JSON-encoded, including titles containing quotes, accents or newlines.
    // The observer has a hard deadline and only reads a bounded number of scripts/cards. There is no automatic pagination or polling.
    // swiftlint:disable line_length
    private static let template = #"""
    (function (options) {
      'use strict'
      const rt = options.site === 'rottenTomatoes'
      const hostname = rt ? 'rottentomatoes.com' : 'metacritic.com'
      if (location.hostname !== hostname && location.hostname !== 'www.' + hostname) return
      if (document.getElementById('blusion-review-reader')) return
      const normalize = value => String(value || '').normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase().replace(/[^\p{L}\p{N}]/gu, '')
      const expected = normalize(options.title)
      const cleanTitle = value => String(value || '').replace(/^\d+[.)]\s+/, '').split('|')[0]
        .replace(/\s*-\s*Metacritic\s*$/i, '').replace(/\s+(?:audience |user |critic )?reviews\s*$/i, '')
        .replace(/\s*[\[(](?:18|19|20)\d{2}[\])]\s*$/, '').replace(/\s+(?:18|19|20)\d{2}\s*$/, '').trim()
      const titlePath = rt ? /^\/(m|tv)\/[^/]+\/?$/ : /^\/(movie|tv)\/[^/]+\/?$/
      const reviewPath = rt ? /^\/(m|tv)\/[^/]+(?:\/s\d+)?\/reviews(?:\/[^/]+)?\/?$/ : /^\/(movie|tv)\/[^/]+\/(?:user|critic)-reviews\/?$/
      const started = performance.now()
      let observer, debounce, identityWait, deadline, stopped = false, lastSignature = '', renderCount = 0
      const safeURL = value => {
        if (typeof value !== 'string' || !value.trim()) return null
        try {
          const url = new URL(value, location.href)
          return /^https?:$/.test(url.protocol) ? url : null
        } catch (_) { return null }
      }
      const onSite = url => url && url.origin === location.origin
      const go = url => {
        if (!onSite(url) || url.href === location.href) return false
        // A review page that redirects back to the title must not form a navigation loop.
        try {
          const key = 'blusion.review.routes.' + options.site + '.' + expected + '.' + (options.year || '')
          const visited = JSON.parse(sessionStorage.getItem(key) || '[]')
          if (!Array.isArray(visited) || visited.length >= 3 || visited.includes(url.href)) return false
          sessionStorage.setItem(key, JSON.stringify(visited.concat(url.href)))
        } catch (_) { return false }
        stop()
        location.replace(url.href)
        return true
      }
      // Includes open Web Component roots; closed roots stay untouched.
      const roots = node => {
        const found = node.shadowRoot ? [node, node.shadowRoot] : [node]
        for (let i = 0; i < found.length && found.length < 24; i++) {
          for (const element of Array.from(found[i].querySelectorAll('*')).slice(0, 2500)) {
            if (element.shadowRoot && found.length < 24) found.push(element.shadowRoot)
          }
        }
        return found
      }
      const select = (node, selector) => roots(node).flatMap(root => Array.from(root.querySelectorAll(selector))).slice(0, 80)
      const text = (node, selector) => {
        const match = select(node, selector)[0]
        return match ? String(match.textContent || '').trim() : ''
      }
      const resolveSearch = () => {
        if (!/^\/search(?:\/|$)/.test(location.pathname)) return false
        const candidates = new Map()
        for (const anchor of select(document, 'a[href*="/m/"], a[href*="/tv/"], a[href*="/movie/"], rt-link[href]')) {
          const url = safeURL(anchor.getAttribute('href'))
          if (!onSite(url) || !titlePath.test(url.pathname)) continue
          const kind = url.pathname.split('/')[1]
          if (kind !== (rt && options.kind === 'movie' ? 'm' : options.kind)) continue
          const card = anchor.closest('search-page-result, search-page-media-row, .search-page-media-row, .c-finderProductCard, article, li') || anchor.parentElement
          if (!card) continue
          const names = [anchor.textContent, anchor.getAttribute('aria-label'), text(card,
            '[data-qa="info-name"], [slot="title"], .c-finderProductCard_title, [data-testid="title"], h2, h3')]
          if (!names.some(name => normalize(cleanTitle(name)) === expected)) continue
          const years = String(card.textContent || '').match(/(?<!\d)(?:18|19|20)\d{2}(?!\d)/g) || []
          for (const node of [card, ...select(card, '[releaseyear], [release-year], [data-year], [year]')]) {
            for (const attr of ['releaseyear', 'release-year', 'data-year', 'year']) {
              const year = node.getAttribute(attr)
              if (year) years.push(year)
            }
          }
          if (options.year && years.length && !years.includes(String(options.year))) continue
          const rank = options.year && years.includes(String(options.year)) ? 2 : 1
          const previous = candidates.get(url.href)
          if (!previous || previous.rank < rank) candidates.set(url.href, { url, rank })
        }
        const ranked = Array.from(candidates.values()).sort((a, b) => b.rank - a.rank)
        if (!ranked.length || (ranked[1] && ranked[0].rank === ranked[1].rank)) return false
        // Give a dynamically loaded result time to receive its year before accepting a unique title without a year.
        if (options.year && ranked[0].rank === 1 && performance.now() - started < 2500) return false
        // Rotten Tomatoes' own page is shown for a film: the search goes straight to its audience reviews, one page fewer.
        if (rt && !options.reads && options.kind === 'movie') {
          return go(new URL(ranked[0].url.pathname.replace(/\/$/, '') + '/reviews/all-audience', location.origin))
        }
        // Metacritic's own page is shown: the search goes straight to the title's user reviews, a film's or a show's alike.
        if (!rt && !options.reads) {
          return go(new URL(ranked[0].url.pathname.replace(/\/$/, '') + '/user-reviews/', location.origin))
        }
        return go(ranked[0].url)
      }
      const pageMatches = () => {
        const kind = location.pathname.split('/')[1]
        if (kind !== (rt && options.kind === 'movie' ? 'm' : options.kind)) return false
        const names = [document.title, document.querySelector('meta[property="og:title"]')?.content,
          text(document, '.reviews-container h2, .c-productHero_title, .c-productSubpageHeader_title, [data-qa="score-panel-title"], h1')]
        if (!names.some(name => normalize(cleanTitle(name)) === expected)) return false
        const years = []
        for (const script of select(document, 'script[data-json="props"], script[type="application/ld+json"]')) {
          if (script.textContent.length > 1000000) continue
          try {
            const value = JSON.parse(script.textContent)
            if (value.media?.releaseYear) years.push(Number(value.media.releaseYear))
            for (const item of Array.isArray(value) ? value : value['@graph'] || [value]) {
              if (normalize(item.name) === expected && /Movie|TVSeries/.test(String(item['@type']))) {
                const year = String(item.datePublished || '').match(/^(\d{4})/)
                if (year) years.push(Number(year[1]))
              }
            }
          } catch (_) { /* Identity can still be checked from the visible title. */ }
        }
        return !options.year || !years.length || years.includes(options.year)
      }
      const openReviews = () => {
        if (!titlePath.test(location.pathname) || !pageMatches()) return false
        const base = location.pathname.replace(/\/$/, '')
        const links = select(document, 'a[href*="reviews"], rt-link[href*="reviews"]').map(anchor => ({ anchor, url: safeURL(anchor.getAttribute('href')) }))
        const audience = links.find(({ anchor, url }) => onSite(url) && url.pathname.startsWith(base + '/') && reviewPath.test(url.pathname) &&
          (/audience|user/i.test(anchor.textContent || '') || /all-audience|user-reviews/.test(url.pathname) || url.searchParams.get('type') === 'user'))
        // The slug is from the selected, validated page, never guessed from the movie name.
        return go(audience?.url || new URL(base + (rt ? '/reviews/all-audience' : '/user-reviews/'), location.origin))
      }
      const extract = () => {
        if (!reviewPath.test(location.pathname) || !pageMatches()) return []
        const entries = [], seen = new Set()
        let remainingText = 100000
        const string = value => typeof value === 'string' || typeof value === 'number' ? String(value) : ''
        const name = value => typeof value === 'object' && value ? string(value.name || value.displayName) : string(value)
        const add = row => {
          row.body = string(row.body).trim().replace(/\s*(?:Read More|Show More|Full Review)\s*$/i, '')
          row.author = string(row.author).trim()
          if (!row.body || !row.author || entries.length >= 40 || remainingText <= 0) return
          const key = row.author + '\n' + row.body
          if (seen.has(key)) return
          seen.add(key)
          row.body = row.body.slice(0, Math.min(16000, remainingText))
          remainingText -= row.body.length
          row.url = safeURL(row.url)?.href || ''
          entries.push(row)
        }
        let walked = 0
        const walk = (value, depth) => {
          if (!value || typeof value !== 'object' || depth > 10 || ++walked > 4000 || entries.length >= 40) return
          if (!Array.isArray(value)) {
            const body = value.reviewBody || value.reviewText || value.reviewQuote || value.quote || (typeof value.review === 'string' ? value.review : '')
            const author = name(value.author || value.reviewer || value.critic || value.displayName || value.username)
            if (body && author) {
              const rating = value.reviewRating ?? value.rating ?? value.score
              const raw = typeof rating === 'object' && rating ? rating.ratingValue ?? rating.value : rating
              const scale = typeof rating === 'object' && rating ? rating.bestRating : null
              const audience = rt ? /all-audience|verified-audience/.test(location.pathname) || /type=user/.test(location.search) : /user-reviews/.test(location.pathname)
              const numeric = /^\d+(?:\.\d+)?$/.test(string(raw))
              const suffix = numeric ? scale ? '/' + scale : audience ? rt ? '/5' : '/10' : '' : ''
              const score = string(value.originalScore) || string(raw) + suffix
              add({ body, author, score, publication: name(value.publisher || value.publication),
                date: string(value.datePublished || value.creationDate || value.reviewDate), url: value.url || value.reviewUrl || value.publicationReviewUrl,
                spoiler: value.isSpoiler === true || value.spoiler === true })
            }
          }
          for (const child of Object.values(value)) walk(child, depth + 1)
        }
        // Public structured reviews and the state shipped in the page. No undocumented endpoints or linked article fetching.
        for (const script of select(document, 'script[type="application/ld+json"], script[data-json="reviewsData"], script#__NEXT_DATA__')) {
          if (script.textContent.length > 1000000) continue
          try { walk(JSON.parse(script.textContent), 0) } catch (_) { /* A malformed block does not discard the DOM fallback. */ }
        }
        const cards = select(document,
          '[itemprop="review"], [itemtype$="/Review"], [data-qa="review-item"], [data-testid="review-card"], ' +
          'review-card-audience, review-card-critic, media-review-card, review-card, .review_table_row, .review-row, .audience-review-row, .js-review-list-item, .c-siteReview')
        for (const card of cards) {
          const author = text(card, '[itemprop="author"], [data-qa="review-name"], [slot="author"], [slot="name"], .author-name, ' +
            '.display-name, .audience-review-row__name, .user_name, .c-siteReviewHeader_username, .c-siteReviewHeader_author, .c-siteReviewHeader_name')
          const body = text(card, '[slot="review"] [slot="content"]') || text(card, '[itemprop="reviewBody"], [data-qa="review-text"], [data-testid="review-text"], [slot="review"], ' +
            '[slot="content"], .the_review, .review-text, .audience-review-row__review, .c-siteReview_quote, .c-siteReview_review')
          const stars = select(card, 'rating-stars-group[score]')[0]?.getAttribute('score')
          const score = text(card, '[itemprop="ratingValue"], [slot="rating"], .original-score, .audience-review-row__score, .c-siteReviewHeader_reviewScore') || (stars ? stars + '/5' : '')
          const link = select(card, 'a[href], rt-link[href]')?.find(anchor => /full review|original review/i.test(anchor.textContent || ''))
          add({ body, author, score, date: text(card, 'time, [slot="timestamp"], [itemprop="datePublished"], .review-date, .c-siteReviewHeader_date'),
            publication: text(card, '[slot="publication"], .reviewer-pub, .c-siteReviewHeader_publicationName'), url: link?.getAttribute('href'),
            spoiler: /\[spoiler alert|contains spoilers/i.test(body) })
        }
        return entries
      }
      let host, shadow, list, browse, read, panel
      const element = (tag, value, className) => {
        const node = document.createElement(tag)
        if (value) node.textContent = String(value)
        if (className) node.className = className
        return node
      }
      const showWebsite = () => {
        host.setAttribute('data-mode', 'website')
        panel.hidden = true
        browse.hidden = true
        read.hidden = false
      }
      const render = entries => {
        if (!entries.length) return
        const signature = JSON.stringify(entries)
        if (signature === lastSignature) return
        lastSignature = signature
        if (!host) {
          host = element('div')
          host.id = 'blusion-review-reader'
          host.setAttribute('data-mode', 'reader')
          shadow = host.attachShadow({ mode: 'open' })
          const style = element('style', `
            :host { all:initial; position:fixed; inset:0; z-index:2147483647; color-scheme:dark; }
            :host([data-mode=website]) { inset:8px 8px auto auto; }
            * { box-sizing:border-box; } [hidden] { display:none !important; }
            .reader { height:100%; overflow-y:auto; background:#242424; color:#fff; font:15px/1.5 -apple-system,BlinkMacSystemFont,sans-serif; }
            nav { position:sticky; top:0; z-index:1; display:flex; justify-content:flex-end; padding:8px; background:#242424; }
            button, a { font:inherit; color:#fff; } button { border:0; border-radius:16px; padding:6px 12px; background:#3a3a3a; cursor:pointer; }
            button:focus-visible, a:focus-visible, summary:focus-visible { outline:2px solid white; outline-offset:3px; }
            section { padding:0 14px 14px; } h2 { font-size:16px; margin:4px 0 12px; }
            article { padding:14px; margin:0 0 10px; background:#303030; border-radius:10px; overflow-wrap:anywhere; }
            header { display:flex; gap:12px; justify-content:space-between; } strong { font-weight:600; } .score { white-space:nowrap; }
            .meta { opacity:.65; font-size:12px; margin:3px 0 8px; } p { margin:8px 0 0; white-space:pre-wrap; }
            summary { cursor:pointer; white-space:pre-wrap; } .expanded { display:none; }
            details[open] .preview { display:none; } details[open] .expanded { display:inline; }
            a { display:inline-block; margin-top:8px; font-size:13px; }
          `)
          const container = element('div', '', 'reader')
          const navigation = element('nav')
          browse = element('button', 'Browse website')
          read = element('button', 'Read reviews')
          read.hidden = true
          browse.addEventListener('click', showWebsite)
          read.addEventListener('click', () => {
            const current = extract()
            if (current.length) render(current)
            host.setAttribute('data-mode', 'reader')
            panel.hidden = false
            browse.hidden = false
            read.hidden = true
          })
          navigation.append(browse, read)
          panel = element('section')
          panel.append(element('h2', options.title + ' · ' + (rt ? 'Rotten Tomatoes' : 'Metacritic')))
          list = element('div')
          const more = element('button', 'More reviews on website')
          more.addEventListener('click', showWebsite)
          panel.append(list, more)
          container.append(navigation, panel)
          shadow.append(style, container)
          document.body.append(host)
        }
        list.replaceChildren()
        for (const row of entries) {
          const card = element('article')
          const header = element('header')
          header.append(element('strong', row.author), element('span', row.score, 'score'))
          card.append(header)
          const metadata = [row.publication, row.date].filter(Boolean).join(' · ')
          if (metadata) card.append(element('div', metadata, 'meta'))
          if (row.body.length > 320 || row.spoiler) {
            const details = element('details')
            const summary = element('summary')
            summary.append(element('span', row.spoiler ? 'Spoiler review · show' : row.body.slice(0, 280) + '…', 'preview'),
              element('span', 'Hide review', 'expanded'))
            details.append(summary, element('p', row.body))
            card.append(details)
          } else { card.append(element('p', row.body)) }
          if (row.url && row.url !== location.href) {
            const link = element('a', 'Original review')
            link.href = row.url
            card.append(link)
          }
          list.append(card)
        }
        // Once the page has produced reviews, allow two updates while its cards finish loading, then stop observing.
        if (++renderCount >= 3) stop()
      }
      const inspect = () => {
        if (stopped) return
        if (resolveSearch() || openReviews()) return
        // The site's own page is the reviews: nothing is drawn over it.
        if (!options.reads) { if (reviewPath.test(location.pathname)) stop(); return }
        render(extract())
      }
      function stop() {
        stopped = true
        observer?.disconnect()
        clearTimeout(debounce)
        clearTimeout(identityWait)
        clearTimeout(deadline)
      }
      observer = new MutationObserver(() => {
        clearTimeout(debounce)
        debounce = setTimeout(inspect, 350)
      })
      observer.observe(document.documentElement, { childList:true, subtree:true })
      identityWait = setTimeout(inspect, 2600)
      deadline = setTimeout(() => { inspect(); stop() }, 15000)
      window.addEventListener('pagehide', stop, { once:true })
      inspect()
    })(__BLUSION_OPTIONS__)
    """#
    // swiftlint:enable line_length
}
