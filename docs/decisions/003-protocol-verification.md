# ADR-003 · Protocol cheat sheet verified against upstream, and what changed

- **Status:** accepted · **Date:** 2026-10-07 · **Node:** M1 retro (verification), refined in M4
- **Sources read:** the published `stremio-addon-sdk` package docs (`docs/protocol.md`, `docs/api/responses/{manifest,stream,meta,subtitles}.md`,
  `docs/api/requests/defineCatalogHandler.md`), fetched from the npm package contents, not from any GitHub repository.

## Confirmed (PLAN §4 was right)

- URL shapes: `/manifest.json`, `/catalog/{type}/{id}.json`, `/meta/…`, `/stream/…`, `/subtitles/…`, and with extras
  `/{resource}/{type}/{id}/{extraArgs}.json`; extras are a query-string-style segment (`search=game%20of%20thrones&skip=100`).
- Manifest: `resources` entries are strings (inherit top-level `types` and `idPrefixes`) or objects (`name`, `types`, `idPrefixes?`);
  an object without `idPrefixes` matches every id for its types. `idPrefixes` does **not** apply to `catalog` requests (we never route catalogs by id).
- Stream source fields: `url`, `ytId`, `infoHash` (+ `fileIdx`; the largest file when omitted), `externalUrl`. `title` is deprecated in favour of `description`.
- `behaviorHints`: `notWebReady`, `bingeGroup`, `proxyHeaders`, `countryWhitelist`. Meta `behaviorHints.defaultVideoId`. Subtitle `lang` is ISO 639-2, otherwise free text.

## Corrections and refinements

1. **`notWebReady` is a browser-player flag, not a codec statement.** Upstream: "applies to http(s) URLs. Set to true if the URL lacks https or is
   not an MP4". Also, `proxyHeaders` "requires `notWebReady: true`", so every header-proxied stream carries it.
   PLAN §4 routes `notWebReady: true` to the fallback engine. Taken literally, that would send plain-http MP4 and HLS (which AVPlayer plays natively)
   and every header-proxied stream to the fallback engine.
   **Decision:** `notWebReady` alone no longer forces the fallback engine. The route is decided by the container (sniffed bytes first, then
   Content-Type, then extension): native for MP4/MOV/M4V/HLS, fallback otherwise. `notWebReady` only breaks the tie when the container is
   unknown and the URL gives no extension hint (then: fallback if available). Audio that AVPlayer cannot decode (DTS, TrueHD) still routes to fallback.
   Sniff requests carry the stream's `proxyHeaders.request`.
2. **Catalog pagination:** upstream page size is 100 and "fewer than 100 items means the end". Page size varies in the wild (the mock uses 20),
   so Discover treats only an **empty** page as the end (one extra request at most) rather than assuming 100.
3. **Subtitles extras:** upstream's protocol page mentions `videoID`/`videoSize` while real clients and the SDK handler use
   `videoHash`, `videoSize` and `filename` (PLAN §4). We send `videoHash`, `videoSize`, `filename` and ignore extras the addon doesn't know.
   **UNVERIFIED:** the `videoID` wording looks like a doc typo; verify against a real subtitles addon on device.
4. **Leniency kept on purpose:** upstream marks `description`, `version`, `types`, `catalogs` and `Video.released` as required; real addons omit them,
   so decoding accepts their absence and `Manifest.validate()` reports only what actually blocks installation.
5. **Not modelled in v1:** `addonCatalogs`, `config`, `contactEmail`, trailers, `Video.streams`/`available`.

## Consequences

PlaybackPolicy (M4) implements refinement 1; DiscoverViewModel implements refinement 2; the subtitle service (M5) implements refinement 3.
