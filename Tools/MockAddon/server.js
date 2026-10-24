#!/usr/bin/env node
'use strict';
/**
 * Blusion mock addon: a catalog addon and a stream addon on separate ports, plus media.
 * Zero dependencies, Node 18+.
 *
 *   node server.js [--host 127.0.0.1] [--catalog-port 7001] [--stream-port 7002] [--fixtures DIR] [--watch-stdin]
 *
 * --watch-stdin: exit when stdin closes, so a server spawned by a test process can never outlive it.
 *
 * Port 0 picks free ports. Once both servers listen, ONE JSON line is printed on stdout:
 *   {"ready":true,"catalog":"http://127.0.0.1:7001","stream":"http://127.0.0.1:7002"}
 *
 * Addon URL shape:  <origin>/<prefix segments...>/manifest.json   (and <resource>/<type>/<id>[/<extra>].json)
 *   Prefix segments are ignored, except `flag-<name>` segments, which switch on misbehaviour.
 *   Any other segment is treated as a user token, so tests can prove tokens never reach logs.
 *
 * Flags (apply to resource responses; manifest flags are listed separately):
 *   flag-slow          3 s delay (MOCK_DELAY_MS overrides)
 *   flag-err500        HTTP 500
 *   flag-badjson       200 with invalid JSON
 *   flag-big           200 with a 6 MB JSON body
 *   flag-redirect      302 to the same URL minus flag-redirect
 *   flag-redirectloop  302 to itself, forever
 *   flag-nulls         null arrays and missing fields
 *   flag-strnums       numbers delivered as strings
 *   flag-missingtypes  manifest without top-level `types`
 *   flag-badmanifest   manifest is invalid JSON
 *   flag-manifest500   manifest answers HTTP 500
 *   flag-slowmanifest  manifest delayed 3 s
 */
const http = require('http');
const fs = require('fs');
const path = require('path');
const { SRT, VTT } = require('./subtitles');

const DEFAULT_DELAY_MS = 3000;
const RESOURCES = new Set(['manifest.json', 'catalog', 'meta', 'stream', 'subtitles', 'addon_catalog']);
const PAGE_SIZE = 20;
const MOVIE_COUNT = 45;
const GENRES = ['Action', 'Drama', 'Comedy'];
const MOCK_TOKEN_HEADER = 'x-mock-token';
const MOCK_TOKEN_VALUE = 'abc';

function parseArgs(argv) {
  const out = { host: '127.0.0.1', catalogPort: 7001, streamPort: 7002, fixtures: path.join(__dirname, 'fixtures', 'generated') };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--host') out.host = argv[++i];
    else if (a === '--catalog-port') out.catalogPort = Number(argv[++i]);
    else if (a === '--stream-port') out.streamPort = Number(argv[++i]);
    else if (a === '--fixtures') out.fixtures = path.resolve(argv[++i]);
    else if (a === '--watch-stdin') out.watchStdin = true;
  }
  return out;
}

const delay = (ms) => new Promise((r) => setTimeout(r, ms));
const delayMs = () => Number(process.env.MOCK_DELAY_MS || DEFAULT_DELAY_MS);

function splitPath(rawPath) {
  const segs = rawPath.split('/').filter((s) => s.length > 0);
  const safe = (s) => { try { return decodeURIComponent(s); } catch { return s; } };
  return segs.map(safe);
}

/** Splits a request path into addon prefix and the resource part. */
function parseAddonPath(rawPath) {
  const segs = splitPath(rawPath);
  const idx = segs.findIndex((s) => RESOURCES.has(s));
  if (idx < 0) return null;
  const prefix = segs.slice(0, idx);
  const flags = new Set(prefix.filter((s) => s.startsWith('flag-')).map((s) => s.slice(5)));
  const rest = segs.slice(idx);
  return { prefix, flags, rest };
}

function stripJson(s) { return s.endsWith('.json') ? s.slice(0, -5) : s; }

/** "genre=Action&skip=20" with percent-encoded values -> { genre: 'Action', skip: '20' } */
function parseExtras(seg) {
  const out = {};
  if (!seg) return out;
  for (const pair of stripJson(seg).split('&')) {
    if (!pair) continue;
    const eq = pair.indexOf('=');
    const k = eq < 0 ? pair : pair.slice(0, eq);
    const v = eq < 0 ? '' : pair.slice(eq + 1);
    try { out[decodeURIComponent(k)] = decodeURIComponent(v); } catch { out[k] = v; }
  }
  return out;
}

function send(res, status, body, headers = {}) {
  const buf = Buffer.isBuffer(body) ? body : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body));
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': buf.length,
    'Access-Control-Allow-Origin': '*',
    ...headers,
  });
  res.end(buf);
}

// ---- catalog data ----------------------------------------------------------

function movieId(n) { return `mock:movie${n}`; }

function moviePreview(n, base, flags) {
  const genres = [GENRES[n % GENRES.length]];
  const year = 1980 + (n % 40);
  const p = {
    id: movieId(n),
    type: 'movie',
    name: `Mock Movie ${n}`,
    poster: `${base}/poster/${n}.svg`,
    posterShape: 'poster',
    releaseInfo: String(year),
    description: `Synthetic description for mock movie ${n}.`,
    genres,
    imdbRating: (5 + (n % 5) + 0.5).toFixed(1),
  };
  if (flags.has('strnums')) { p.releaseInfo = year; p.imdbRating = String(p.imdbRating); p.year = String(year); }
  else { p.imdbRating = Number(p.imdbRating); }
  if (flags.has('nulls')) { p.genres = null; p.poster = null; p.description = null; }
  return p;
}

function catalogMetas(catalogId, extras, base, flags) {
  if (catalogId === 'mock-top') {
    const metas = [1, 2, 3].map((n) => moviePreview(n, base, flags));
    // Present in the catalog but its meta endpoint 404s: exercises Detail's catalog-preview fallback.
    metas.push({ id: 'mock:nometa1', type: 'movie', name: 'Preview Only Movie', poster: `${base}/poster/99.svg`, releaseInfo: '2001' });
    // Malformed item: must be dropped without failing the response.
    metas.push({ type: 'movie', name: 'Item without id' });
    return metas;
  }
  if (catalogId === 'mock-series') {
    return [{ id: 'mock:series1', type: 'series', name: 'Mock Series One', poster: `${base}/poster/series1.svg`, releaseInfo: '2020-' }];
  }
  let list = [];
  for (let n = 1; n <= MOVIE_COUNT; n++) list.push(n);
  if (extras.genre) list = list.filter((n) => GENRES[n % GENRES.length] === extras.genre);
  if (extras.search) {
    const q = extras.search.toLowerCase();
    list = list.filter((n) => `mock movie ${n}`.includes(q));
  }
  const skip = Number.parseInt(extras.skip || '0', 10) || 0;
  return list.slice(skip, skip + PAGE_SIZE).map((n) => moviePreview(n, base, flags));
}

function seriesMeta(base) {
  const videos = [];
  for (let s = 1; s <= 2; s++) for (let e = 1; e <= 3; e++) {
    videos.push({ id: `mock:series1:${s}:${e}`, title: `Episode ${e}`, season: s, episode: e, released: `2020-0${s}-0${e}T00:00:00.000Z` });
  }
  return { id: 'mock:series1', type: 'series', name: 'Mock Series One', poster: `${base}/poster/series1.svg`, background: `${base}/poster/series1.svg`,
    description: 'A synthetic series.', releaseInfo: '2020-', genres: ['Drama'], videos };
}

function movieMeta(n, base, flags) {
  const m = moviePreview(n, base, flags);
  const detail = {
    ...m,
    background: `${base}/poster/${n}.svg`,
    runtime: `${90 + (n % 60)} min`,
    released: `${1980 + (n % 40)}-01-01T00:00:00.000Z`,
    director: ['Mock Director'],
    cast: ['Mock Actor A', 'Mock Actor B'],
    links: [{ name: 'Action', category: 'Genres', url: 'stremio:///discover' }],
    behaviorHints: { defaultVideoId: movieId(n) },
  };
  if (flags.has('nulls')) { detail.cast = null; detail.links = null; detail.director = null; detail.videos = null; }
  return detail;
}

function posterSvg(label) {
  const hue = (Array.from(label).reduce((a, c) => a + c.charCodeAt(0), 0) * 37) % 360;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="300" height="450" viewBox="0 0 300 450">` +
    `<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="hsl(${hue},60%,45%)"/>` +
    `<stop offset="1" stop-color="hsl(${(hue + 60) % 360},60%,25%)"/></linearGradient></defs>` +
    `<rect width="300" height="450" fill="url(#g)"/><text x="150" y="235" font-family="Helvetica" font-size="28" fill="white" text-anchor="middle">${label}</text></svg>`;
}

// ---- manifests -------------------------------------------------------------

function catalogManifest(flags) {
  const m = {
    id: 'org.blusion.mock.catalog',
    name: 'Mock Catalog',
    version: '1.0.0',
    description: 'Synthetic movie and series catalog for Blusion tests.',
    resources: ['catalog', 'meta'],
    types: ['movie', 'series'],
    idPrefixes: ['mock:'],
    logo: 'about:blank',
    catalogs: [
      { type: 'movie', id: 'mock-movies', name: 'Mock Movies',
        extra: [{ name: 'search', isRequired: false }, { name: 'genre', isRequired: false, options: GENRES }, { name: 'skip', isRequired: false }] },
      { type: 'movie', id: 'mock-top', name: 'Mock Top Picks', extra: [] },
      { type: 'series', id: 'mock-series', name: 'Mock Series', extraSupported: ['skip'], extraRequired: [] },
    ],
    behaviorHints: { configurable: false, configurationRequired: false },
  };
  if (flags.has('missingtypes')) delete m.types;
  return m;
}

function streamManifest(flags) {
  const m = {
    id: 'org.blusion.mock.streams',
    name: 'Mock Streams',
    version: '1.0.0',
    description: 'Synthetic stream and subtitle addon. All media is generated locally.',
    resources: [
      { name: 'stream', types: ['movie', 'series'], idPrefixes: ['mock:'] },
      { name: 'subtitles', types: ['movie'], idPrefixes: ['mock:'] },
    ],
    types: ['movie', 'series'],
    catalogs: [],
  };
  if (flags.has('missingtypes')) delete m.types;
  return m;
}

// ---- streams ---------------------------------------------------------------

function streamsFor(type, id, base, fixtures) {
  const media = `${base}/media`;
  const size = (f) => { try { return fs.statSync(path.join(fixtures, f)).size; } catch { return undefined; } };
  const mp4 = { name: 'Mock MP4', description: '1080p H.264 AAC\nmp4', url: `${media}/sample.mp4`,
    behaviorHints: { filename: 'sample.mp4', videoSize: size('sample.mp4'), bingeGroup: 'mock-mp4' } };
  const hls = { name: 'Mock HLS', description: '720p HLS', url: `${media}/hls/index.m3u8`, behaviorHints: { bingeGroup: 'mock-hls' } };
  if (type === 'series') return [mp4, hls];
  if (id === 'mock:movie2') return [mp4];
  return [
    mp4,
    hls,
    { name: 'Mock MKV AC3', description: '1080p H.264 AC3\nmkv', url: `${media}/sample-ac3.mkv`, behaviorHints: { filename: 'sample-ac3.mkv', bingeGroup: 'mock-mkv' } },
    { name: 'Mock MKV DTS', description: '2160p 4K H.264 DTS\nmkv', url: `${media}/sample-dts.mkv`, behaviorHints: { notWebReady: true, filename: 'sample-dts.mkv' } },
    { name: 'Mock Blob', description: 'extensionless url, octet-stream', url: `${media}/blob/mp4` },
    { name: 'Mock Protected', description: 'needs proxyHeaders', url: `${media}/protected.mp4`,
      behaviorHints: { proxyHeaders: { request: { 'X-Mock-Token': MOCK_TOKEN_VALUE } } } },
    { name: 'Mock Torrent', description: 'infoHash only', infoHash: '0123456789abcdef0123456789abcdef01234567', fileIdx: 0, sources: ['tracker:udp://tracker.invalid:1337'] },
    { name: 'Mock External', externalUrl: 'https://example.com/watch' },
    { name: 'Mock YouTube', ytId: 'aqz-KE-bpKQ' },
    { name: 'Mock NZB', nzbUrl: 'https://example.invalid/file.nzb' },
  ];
}

// ---- addon request handling -----------------------------------------------

async function handleAddon(kind, req, res, ctx) {
  const parsed = parseAddonPath(new URL(req.url, 'http://x').pathname);
  if (!parsed) return send(res, 404, { err: 'not an addon path' });
  const { flags, rest } = parsed;
  const base = ctx.origin;

  if (rest[0] === 'manifest.json') {
    if (flags.has('slowmanifest')) await delay(delayMs());
    if (flags.has('manifest500')) return send(res, 500, { err: 'manifest failure' });
    if (flags.has('badmanifest')) return send(res, 200, '{"id": "broken", "name": ');
    return send(res, 200, kind === 'catalog' ? catalogManifest(flags) : streamManifest(flags));
  }

  // Resource-level misbehaviour
  if (flags.has('redirectloop')) return send(res, 302, '', { Location: req.url });
  if (flags.has('redirect')) {
    const target = req.url.replace('/flag-redirect', '');
    return send(res, 302, '', { Location: target });
  }
  if (flags.has('slow')) await delay(delayMs());
  if (flags.has('err500')) return send(res, 500, { err: 'boom' });
  if (flags.has('badjson')) return send(res, 200, '{"metas": [ {"id": ');
  if (flags.has('big')) {
    const filler = 'x'.repeat(1024);
    const items = [];
    for (let i = 0; i < 6 * 1024; i++) items.push({ id: `mock:big${i}`, type: 'movie', name: filler });
    return send(res, 200, { metas: items });
  }

  const [resource, type, rawId] = rest;
  const id = rawId ? stripJson(rawId) : undefined;

  if (kind === 'catalog' && resource === 'catalog') {
    const catalogId = stripJson(rest[2] || '');
    const extraPart = rest[3];
    const metas = catalogMetas(catalogId, parseExtras(extraPart), base, flags);
    if (flags.has('nulls') && (extraPart || '').includes('skip=100')) return send(res, 200, { metas: null });
    return send(res, 200, { metas });
  }
  if (kind === 'catalog' && resource === 'meta') {
    if (id === 'mock:series1') return send(res, 200, { meta: seriesMeta(base) });
    const m = /^mock:movie(\d+)$/.exec(id || '');
    if (m) return send(res, 200, { meta: movieMeta(Number(m[1]), base, flags) });
    return send(res, 404, { err: 'no such meta' });
  }
  if (kind === 'stream' && resource === 'stream') {
    let streams = streamsFor(type, id, base, ctx.fixtures);
    if (flags.has('nulls')) streams = [...streams, { name: 'Broken (no source)' }, null];
    return send(res, 200, { streams });
  }
  if (kind === 'stream' && resource === 'subtitles') {
    return send(res, 200, { subtitles: [
      { id: 'mock-en', url: `${base}/media/sample.srt`, lang: 'eng' },
      { id: 'mock-es', url: `${base}/media/sample.vtt`, lang: 'spa' },
    ] });
  }
  return send(res, 404, { err: `unsupported ${resource} for ${kind} addon` });
}

// ---- media -----------------------------------------------------------------

const MIME = { '.mp4': 'video/mp4', '.mkv': 'video/x-matroska', '.m3u8': 'application/vnd.apple.mpegurl', '.ts': 'video/mp2t',
  '.m4s': 'video/iso.segment', '.srt': 'application/x-subrip', '.vtt': 'text/vtt', '.svg': 'image/svg+xml' };

function serveFile(req, res, file, mime, headers = {}) {
  let stat;
  try { stat = fs.statSync(file); } catch {
    return send(res, 404, { err: 'fixture missing. Run Tools/MockAddon/make-fixtures.sh' });
  }
  const range = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range || '');
  let start = 0, end = stat.size - 1, status = 200;
  if (range) {
    if (range[1] !== '') { start = Number(range[1]); if (range[2] !== '') end = Math.min(Number(range[2]), stat.size - 1); }
    else if (range[2] !== '') { start = Math.max(0, stat.size - Number(range[2])); }
    if (start > end || start >= stat.size) {
      res.writeHead(416, { 'Content-Range': `bytes */${stat.size}` });
      return res.end();
    }
    status = 206;
  }
  const h = { 'Content-Type': mime, 'Accept-Ranges': 'bytes', 'Content-Length': end - start + 1, 'Access-Control-Allow-Origin': '*', ...headers };
  if (status === 206) h['Content-Range'] = `bytes ${start}-${end}/${stat.size}`;
  res.writeHead(status, h);
  if (req.method === 'HEAD') return res.end();
  fs.createReadStream(file, { start, end }).pipe(res);
}

function handleMedia(req, res, ctx) {
  const pathname = new URL(req.url, 'http://x').pathname;
  const rel = pathname.replace(/^\/media\//, '');
  if (rel === 'sample.srt') return send(res, 200, SRT, { 'Content-Type': MIME['.srt'] });
  if (rel === 'sample.vtt') return send(res, 200, VTT, { 'Content-Type': MIME['.vtt'] });
  const blobs = { 'blob/mp4': 'sample.mp4', 'blob/mkv': 'sample-ac3.mkv', 'blob/hls': 'hls/index.m3u8' };
  if (blobs[rel]) return serveFile(req, res, path.join(ctx.fixtures, blobs[rel]), 'application/octet-stream');
  if (rel === 'protected.mp4') {
    if (req.headers[MOCK_TOKEN_HEADER] !== MOCK_TOKEN_VALUE) return send(res, 403, { err: 'missing X-Mock-Token' });
    return serveFile(req, res, path.join(ctx.fixtures, 'sample.mp4'), MIME['.mp4']);
  }
  const safe = path.normalize(rel).replace(/^(\.\.[/\\])+/, '');
  const file = path.join(ctx.fixtures, safe);
  if (!file.startsWith(ctx.fixtures)) return send(res, 403, { err: 'forbidden' });
  return serveFile(req, res, file, MIME[path.extname(file)] || 'application/octet-stream');
}

function makeServer(kind, ctx) {
  return http.createServer((req, res) => {
    const pathname = new URL(req.url, 'http://x').pathname;
    if (pathname === '/healthz') return send(res, 200, { ok: true });
    if (req.method === 'OPTIONS') { res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*' }); return res.end(); }
    if (pathname.startsWith('/poster/')) return send(res, 200, posterSvg(path.basename(pathname, '.svg')), { 'Content-Type': MIME['.svg'] });
    if (kind === 'stream' && pathname.startsWith('/media/')) return handleMedia(req, res, ctx);
    handleAddon(kind, req, res, ctx).catch((e) => { try { send(res, 500, { err: String(e) }); } catch { /* socket gone */ } });
  });
}

function listen(server, host, port) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => resolve(server.address().port));
  });
}

async function start(opts = {}) {
  const o = { ...parseArgs([]), ...opts };
  const catalogCtx = { fixtures: o.fixtures, origin: '' };
  const streamCtx = { fixtures: o.fixtures, origin: '' };
  const catalogServer = makeServer('catalog', catalogCtx);
  const streamServer = makeServer('stream', streamCtx);
  const cPort = await listen(catalogServer, o.host, o.catalogPort);
  const sPort = await listen(streamServer, o.host, o.streamPort);
  catalogCtx.origin = `http://${o.host}:${cPort}`;
  streamCtx.origin = `http://${o.host}:${sPort}`;
  return {
    catalog: catalogCtx.origin,
    stream: streamCtx.origin,
    close: () => Promise.all([catalogServer, streamServer].map((s) => new Promise((r) => { s.closeAllConnections?.(); s.close(r); }))),
  };
}

module.exports = { start, parseAddonPath, parseExtras, MOCK_TOKEN_VALUE };

if (require.main === module) {
  start(parseArgs(process.argv.slice(2))).then((s) => {
    process.stdout.write(JSON.stringify({ ready: true, catalog: s.catalog, stream: s.stream }) + '\n');
    const stop = () => s.close().then(() => process.exit(0));
    process.on('SIGINT', stop);
    process.on('SIGTERM', stop);
    if (parseArgs(process.argv.slice(2)).watchStdin) {
      process.stdin.resume();
      process.stdin.on('end', stop);
      process.stdin.on('close', stop);
    }
  }).catch((e) => { process.stderr.write(`mock addon failed to start: ${e}\n`); process.exit(1); });
}
