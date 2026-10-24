// Run with `node --test Tools/review-reader.test.cjs` on a host with the development-only `linkedom` package installed.
// Executes the exact WebKit script from the Swift source against offline DOM fixtures; no network requests are made.
const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const { performance } = require('node:perf_hooks')
const { parseHTML } = require(process.env.BLUSION_TEST_DOM_PATH || 'linkedom')

const source = fs.readFileSync(path.join(__dirname, '../Packages/Features/Sources/Features/Views/Detail/ReviewPageReader.swift'), 'utf8')
const template = source.match(/private static let template = #"""\n([\s\S]*?)\n    """#/)[1]

// `reads: true` draws the reader's own list of reviews, which these tests cover. The app shows Rotten Tomatoes' and Metacritic's own pages
// (`reads: false`): the reader only takes a search on to the title's audience or user reviews.
const rtOptions = { site: 'rottenTomatoes', title: 'It', year: 2017, kind: 'movie', reads: true }
const mcOptions = { site: 'metacritic', title: 'It', year: 2017, kind: 'movie', reads: true }
const rtRow = (author, body, score = '4.5/5') => `<article class="audience-review-row">
  <strong class="audience-review-row__name">${author}</strong>
  <span class="audience-review-row__score">${score}</span><p class="audience-review-row__review">${body}</p>
</article>`
const mcRow = (author, body) => `<article class="c-siteReview">
  <strong class="c-siteReviewHeader_username">${author}</strong><span class="c-siteReviewHeader_reviewScore">9</span>
  <p class="c-siteReview_quote">${body}</p><time>2026-10-14</time></article>`
const reviewsPage = (title, rows) => `<title>${title} | Audience Reviews</title><h1>${title} Reviews</h1>${rows}`

async function withPage(url, pages, options, check) {
  const requests = [], errors = [], timers = new Set(), storage = new Map()
  const script = template.replace('__BLUSION_OPTIONS__', JSON.stringify(options))
  let current, sandbox, context, disposed = false
  const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds))
  function navigate(address) {
    if (disposed) return
    requests.push(address)
    const { document, window } = parseHTML(`<!doctype html><html><head></head><body>${pages[address] || '<h1>Unavailable</h1>'}</body></html>`)
    current = new URL(address)
    sandbox = {
      document, URL, performance, MutationObserver: window.MutationObserver,
      location: { hostname: current.hostname, origin: current.origin, pathname: current.pathname,
        search: current.search, href: current.href, replace: next => queueMicrotask(() => navigate(next)) },
      sessionStorage: { getItem: key => storage.get(key) || null, setItem: (key, value) => storage.set(key, value) },
      setTimeout: (callback, milliseconds) => {
        const timer = setTimeout(() => { timers.delete(timer); callback() }, milliseconds)
        timers.add(timer)
        return timer
      },
      clearTimeout: timer => { timers.delete(timer); clearTimeout(timer) },
      addEventListener: window.addEventListener.bind(window),
    }
    sandbox.window = sandbox
    context = vm.createContext(sandbox)
    try { vm.runInContext(script, context) } catch (error) { errors.push(error.message) }
  }
  function nodes(selector) {
    const match = selector.match(/^#blusion-review-reader\s+(.+)$/)
    if (match) return Array.from(sandbox.document.getElementById('blusion-review-reader')?.shadowRoot.querySelectorAll(match[1]) || [])
    return Array.from(sandbox.document.querySelectorAll(selector))
  }
  function locator(selector, index) {
    const all = () => index === undefined ? nodes(selector) : nodes(selector).slice(index, index + 1)
    return {
      count: async () => all().length,
      textContent: async () => all()[0]?.textContent,
      getAttribute: async name => all()[0]?.getAttribute(name),
      first: () => locator(selector, 0),
      click: async () => all()[0]?.click(),
    }
  }
  const page = {
    url: () => current.href,
    locator,
    getByRole: (_, { name }) => ({ click: async () => {
      const button = nodes('#blusion-review-reader button').find(node => node.textContent === name)
      assert.ok(button, 'button exists: ' + name)
      button.click()
    } }),
    waitForTimeout: delay,
    waitForSelector: async selector => {
      const started = performance.now()
      while (!nodes(selector).length) {
        if (errors.length) throw new Error(errors.join('\n'))
        if (performance.now() - started > 3500) throw new Error('Timed out: ' + selector)
        await delay(20)
      }
    },
    evaluate: async callback => vm.runInContext('(' + callback.toString() + ')()', context),
  }
  try {
    navigate(url)
    await check(page, requests)
    assert.deepEqual(errors, [], 'the page reader throws no JavaScript errors')
  } finally {
    disposed = true
    for (const timer of timers) clearTimeout(timer)
  }
}

test('RT automatically selects the right movie and year and uses the selected slug', async () => {
  const search = 'https://www.rottentomatoes.com/search?search=It'
  const title = 'https://www.rottentomatoes.com/m/the_actual_site_slug'
  const reviews = title + '/reviews/all-audience'
  const searchHTML = `<search-page-result><a slot="title" href="/m/it_1990">It</a><span>1990</span></search-page-result>
    <search-page-result><a slot="title" href="/tv/it">It</a><span>2017</span></search-page-result>
    <search-page-result><a slot="title" href="${title}">It</a><span>2017</span></search-page-result>`
  await withPage(search, {
    [search]: searchHTML,
    [title]: `<h1>It</h1><a href="${reviews}">Audience reviews</a>`,
    [reviews]: reviewsPage('It', rtRow('Reader A', 'A public audience review.')),
  }, rtOptions, async (page, requests) => {
    await page.waitForSelector('#blusion-review-reader')
    assert.equal(page.url(), reviews)
    assert.deepEqual(requests, [search, title, reviews], 'only the search, selected title and reviews page load')
    assert.equal(await page.locator('#blusion-review-reader article strong').textContent(), 'Reader A')
    await page.getByRole('button', { name: 'Browse website', exact: true }).click()
    assert.equal(await page.locator('#blusion-review-reader').getAttribute('data-mode'), 'website')
    await page.getByRole('button', { name: 'Read reviews', exact: true }).click()
    assert.equal(await page.locator('#blusion-review-reader').getAttribute('data-mode'), 'reader')
    assert.equal(requests.length, 3, 'reader/website switching does not reload the site')
  })
})

test('Metacritic selects the matching year and movie type from numbered cards', async () => {
  const search = 'https://www.metacritic.com/search/It/'
  const title = 'https://www.metacritic.com/movie/it-2017/'
  const reviews = title + 'user-reviews/'
  await withPage(search, {
    [search]: `<article class="c-finderProductCard"><a href="/movie/it-1990/"><h3>1. It</h3><span>1990</span></a></article>
      <article class="c-finderProductCard"><a href="/tv/it/"><h3>2. It</h3><span>2017</span></a></article>
      <article class="c-finderProductCard"><a href="${title}"><h3>3. It</h3><span>2017</span></a></article>`,
    [title]: `<h1>It</h1><a href="${reviews}">User Reviews</a>`,
    [reviews]: reviewsPage('It', mcRow('Reader B', 'A Metacritic user review.')),
  }, mcOptions, async (page, requests) => {
    await page.waitForSelector('#blusion-review-reader')
    assert.equal(page.url(), reviews)
    assert.deepEqual(requests, [search, title, reviews])
    assert.equal(await page.locator('#blusion-review-reader article strong').textContent(), 'Reader B')
  })
})

test('ambiguous results and results for a different year are left as the original website', async () => {
  const url = 'https://www.rottentomatoes.com/search?search=It'
  const variants = [
    `<article><a href="/m/it_a">It</a>2017</article><article><a href="/m/it_b">It</a>2017</article>`,
    `<article><a href="/m/it_1990">It</a>1990</article>`,
    `<article><a href="https://evil.example/m/it">It</a>2017</article>`,
  ]
  for (const html of variants) {
    await withPage(url, { [url]: html }, rtOptions, async (page, requests) => {
      await page.waitForTimeout(450)
      assert.deepEqual(requests, [url])
      assert.equal(await page.locator('#blusion-review-reader').count(), 0)
    })
  }
})

test('structured data preserves a zero rating and never executes review markup', async () => {
  const url = 'https://www.metacritic.com/movie/it-2017/user-reviews/'
  const review = { '@type': 'Review', author: { name: '<img src="https://evil.example/author">' },
    reviewBody: '<img src=x onerror="window.bad=true">Public review.', rating: 0, datePublished: '2026-10-14' }
  await withPage(url, { [url]: reviewsPage('It', `<script type="application/ld+json">${JSON.stringify(review)}</script>`) },
    mcOptions, async (page, requests) => {
      await page.waitForSelector('#blusion-review-reader')
      assert.equal(await page.locator('#blusion-review-reader .score').textContent(), '0/10')
      assert.equal(await page.locator('#blusion-review-reader img').count(), 0)
      assert.equal(await page.evaluate(() => window.bad), undefined)
      assert.deepEqual(requests, [url])
    })
})

test('malformed structured data falls back to DOM reviews and duplicate data produces one card', async () => {
  const url = 'https://www.rottentomatoes.com/m/it/reviews/all-audience'
  const row = { author: 'Reader', reviewBody: 'The same review.', reviewRating: { ratingValue: 4, bestRating: 5 } }
  const html = `<script type="application/ld+json">{bad</script>
    <script data-json="reviewsData" type="application/json">${JSON.stringify({ reviews: [row] })}</script>
    ${rtRow('Reader', 'The same review.')}${rtRow('Other reader', 'A separate review.')}`
  await withPage(url, { [url]: reviewsPage('It', html) }, rtOptions, async page => {
    await page.waitForSelector('#blusion-review-reader')
    assert.equal(await page.locator('#blusion-review-reader article').count(), 2)
    assert.equal(await page.locator('#blusion-review-reader .score').first().textContent(), '4/5')
  })
})

test('unrelated title pages, wrong-year pages, challenges and foreign domains are not extracted', async () => {
  const url = 'https://www.rottentomatoes.com/m/it/reviews/all-audience'
  const wrongYear = `<script data-json="props" type="application/json">{"media":{"releaseYear":"1990"}}</script>`
  for (const html of [reviewsPage('Other movie', rtRow('Reader', 'Wrong title.')),
    reviewsPage('It', wrongYear + rtRow('Reader', 'Wrong year.')), '<h1>Verify you are human</h1>']) {
    await withPage(url, { [url]: html }, rtOptions, async page => {
      await page.waitForTimeout(450)
      assert.equal(await page.locator('#blusion-review-reader').count(), 0)
    })
  }
  const foreign = 'https://evil.example/m/it/reviews/all-audience'
  await withPage(foreign, { [foreign]: reviewsPage('It', rtRow('Reader', 'Do not extract.')) }, rtOptions, async page => {
    assert.equal(await page.locator('#blusion-review-reader').count(), 0)
  })
})

test('reviews that appear after document load are collected and open shadow roots work', async () => {
  const url = 'https://www.rottentomatoes.com/m/it/reviews/all-audience'
  await withPage(url, { [url]: reviewsPage('It', '') }, rtOptions, async page => {
    await page.evaluate(() => {
      const card = document.createElement('media-review-card')
      const shadow = card.attachShadow({ mode: 'open' })
      shadow.innerHTML = '<span slot="author">Late reader</span><p class="review-text">A dynamically loaded review.</p>'
      document.body.append(card)
    })
    await page.waitForSelector('#blusion-review-reader')
    assert.equal(await page.locator('#blusion-review-reader article strong').textContent(), 'Late reader')
  })
})

test('spoilers stay folded, long reviews expand and unsafe original-review links are discarded', async () => {
  const url = 'https://www.metacritic.com/movie/it-2017/user-reviews/'
  const row = { author: 'Reader', reviewBody: 'Visible review text. '.repeat(30), isSpoiler: true, url: 'javascript:alert(1)' }
  await withPage(url, { [url]: reviewsPage('It', `<script type="application/ld+json">${JSON.stringify(row)}</script>`) },
    mcOptions, async page => {
      await page.waitForSelector('#blusion-review-reader')
      assert.equal(await page.locator('#blusion-review-reader details').getAttribute('open'), null)
      assert.equal(await page.locator('#blusion-review-reader a').count(), 0)
      assert.equal(await page.locator('#blusion-review-reader summary').count(), 1)
      assert.equal(await page.locator('#blusion-review-reader p').textContent(), row.reviewBody.trim())
    })
})

test('review collection is bounded and does not request more pages', async () => {
  const url = 'https://www.rottentomatoes.com/m/it/reviews/all-audience'
  const data = Array.from({ length: 75 }, (_, index) => ({ author: 'Reader ' + index, reviewBody: 'Public review ' + index }))
  await withPage(url, { [url]: reviewsPage('It', `<script data-json="reviewsData">${JSON.stringify(data)}</script>`) },
    rtOptions, async (page, requests) => {
      await page.waitForSelector('#blusion-review-reader')
      assert.equal(await page.locator('#blusion-review-reader article').count(), 40)
      assert.deepEqual(requests, [url])
    })
})

test('current RT review-card-audience slots preserve the score and omit drawer controls', async () => {
  const url = 'https://www.rottentomatoes.com/m/it/reviews/all-audience'
  const card = `<review-card-audience><rt-link slot="name">Current RT reader</rt-link>
    <span slot="timestamp">Today</span><rating-stars-group slot="rating" score="4.5"></rating-stars-group>
    <drawer-more slot="review"><span slot="content">The public review text.</span>
      <rt-link slot="cta-open">See More</rt-link><rt-link slot="cta-close">See Less</rt-link></drawer-more></review-card-audience>`
  await withPage(url, { [url]: reviewsPage('It', card) }, rtOptions, async page => {
    await page.waitForSelector('#blusion-review-reader')
    assert.equal(await page.locator('#blusion-review-reader .score').textContent(), '4.5/5')
    assert.equal(await page.locator('#blusion-review-reader p').textContent(), 'The public review text.')
    assert.equal(await page.locator('#blusion-review-reader a').count(), 0, 'missing URLs do not turn into guessed links')
  })
})
