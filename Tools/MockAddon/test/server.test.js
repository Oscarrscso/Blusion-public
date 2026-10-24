'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { start, parseAddonPath, parseExtras } = require('../server');

process.env.MOCK_DELAY_MS = '300';

let srv;
test.before(async () => { srv = await start({ catalogPort: 0, streamPort: 0 }); });
test.after(async () => { await srv.close(); });

function get(url, headers = {}) {
  return new Promise((resolve, reject) => {
    http.get(url, { headers }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
    }).on('error', reject);
  });
}
const json = (r) => JSON.parse(r.body.toString('utf8'));

test('parseAddonPath splits prefix, flags and resource', () => {
  const p = parseAddonPath('/flag-slow/SECRET/catalog/movie/mock-movies.json');
  assert.deepEqual([...p.flags], ['slow']);
  assert.deepEqual(p.prefix, ['flag-slow', 'SECRET']);
  assert.deepEqual(p.rest, ['catalog', 'movie', 'mock-movies.json']);
  assert.equal(parseAddonPath('/nothing/here'), null);
});

test('parseExtras decodes percent-encoded keys and values', () => {
  assert.deepEqual(parseExtras('search=a%26b%3Dc%2Fd%20e&skip=20.json'), { search: 'a&b=c/d e', skip: '20' });
});

test('catalog manifest is valid and has expected shape', async () => {
  const r = await get(`${srv.catalog}/tok123/manifest.json`);
  assert.equal(r.status, 200);
  const m = json(r);
  assert.equal(m.id, 'org.blusion.mock.catalog');
  assert.ok(m.catalogs.length >= 3);
  assert.deepEqual(m.resources, ['catalog', 'meta']);
});

test('stream manifest mixes object resources with idPrefixes', async () => {
  const m = json(await get(`${srv.stream}/manifest.json`));
  assert.equal(m.resources[0].name, 'stream');
  assert.deepEqual(m.resources[0].idPrefixes, ['mock:']);
});

test('catalog paginates with skip and filters by genre and search', async () => {
  const p1 = json(await get(`${srv.catalog}/catalog/movie/mock-movies.json`)).metas;
  const p2 = json(await get(`${srv.catalog}/catalog/movie/mock-movies/skip=20.json`)).metas;
  const p3 = json(await get(`${srv.catalog}/catalog/movie/mock-movies/skip=40.json`)).metas;
  assert.equal(p1.length, 20);
  assert.equal(p2.length, 20);
  assert.equal(p3.length, 5);
  assert.notEqual(p1[0].id, p2[0].id);
  const action = json(await get(`${srv.catalog}/catalog/movie/mock-movies/genre=Action.json`)).metas;
  assert.ok(action.length > 0 && action.every((m) => m.genres.includes('Action')));
  const found = json(await get(`${srv.catalog}/catalog/movie/mock-movies/search=movie%2012.json`)).metas;
  assert.deepEqual(found.map((m) => m.id), ['mock:movie12']);
});

test('meta returns detail, 404 for unknown', async () => {
  assert.equal(json(await get(`${srv.catalog}/meta/movie/mock:movie3.json`)).meta.name, 'Mock Movie 3');
  assert.equal((await get(`${srv.catalog}/meta/movie/mock:nometa1.json`)).status, 404);
  assert.equal(json(await get(`${srv.catalog}/meta/series/mock:series1.json`)).meta.videos.length, 6);
});

test('stream addon offers every stream kind', async () => {
  const s = json(await get(`${srv.stream}/stream/movie/mock:movie1.json`)).streams;
  const kinds = s.map((x) => (x.url ? 'url' : x.infoHash ? 'infoHash' : x.externalUrl ? 'externalUrl' : x.ytId ? 'ytId' : x.nzbUrl ? 'nzb' : '?'));
  assert.deepEqual([...new Set(kinds)].sort(), ['externalUrl', 'infoHash', 'nzb', 'url', 'ytId']);
  assert.deepEqual(json(await get(`${srv.stream}/stream/movie/mock:movie2.json`)).streams.length, 1);
});

test('subtitles resource returns srt and vtt links', async () => {
  const r = json(await get(`${srv.stream}/subtitles/movie/mock:movie1/videoHash=abc&filename=a%20b.mp4.json`));
  assert.deepEqual(r.subtitles.map((s) => s.lang), ['eng', 'spa']);
  const srt = await get(r.subtitles[0].url);
  assert.match(srt.body.toString(), /00:00:01,000 --> 00:00:03,000/);
});

test('flags: err500, badjson, big, nulls, strnums', async () => {
  assert.equal((await get(`${srv.catalog}/flag-err500/catalog/movie/mock-top.json`)).status, 500);
  const bad = await get(`${srv.catalog}/flag-badjson/catalog/movie/mock-top.json`);
  assert.equal(bad.status, 200);
  assert.throws(() => JSON.parse(bad.body.toString()));
  const big = await get(`${srv.catalog}/flag-big/catalog/movie/mock-top.json`);
  assert.ok(big.body.length > 6 * 1024 * 1024);
  const nulls = json(await get(`${srv.catalog}/flag-nulls/catalog/movie/mock-top.json`)).metas;
  assert.equal(nulls[0].genres, null);
  const str = json(await get(`${srv.catalog}/flag-strnums/catalog/movie/mock-top.json`)).metas;
  assert.equal(typeof str[0].imdbRating, 'string');
  assert.equal(typeof str[0].releaseInfo, 'number');
});

test('flag-slow delays resources but not the manifest', async () => {
  let t = Date.now();
  await get(`${srv.catalog}/flag-slow/manifest.json`);
  assert.ok(Date.now() - t < 250);
  t = Date.now();
  await get(`${srv.catalog}/flag-slow/catalog/movie/mock-top.json`);
  assert.ok(Date.now() - t >= 290);
});

test('flag-redirect redirects once; redirectloop never settles', async () => {
  const r = await get(`${srv.catalog}/flag-redirect/catalog/movie/mock-top.json`);
  assert.equal(r.status, 302);
  assert.equal(r.headers.location, '/catalog/movie/mock-top.json');
  const loop = await get(`${srv.catalog}/flag-redirectloop/catalog/movie/mock-top.json`);
  assert.equal(loop.status, 302);
  assert.equal(loop.headers.location, '/flag-redirectloop/catalog/movie/mock-top.json');
});

test('manifest flags: badmanifest, manifest500, missingtypes', async () => {
  const bad = await get(`${srv.catalog}/flag-badmanifest/manifest.json`);
  assert.throws(() => JSON.parse(bad.body.toString()));
  assert.equal((await get(`${srv.catalog}/flag-manifest500/manifest.json`)).status, 500);
  assert.equal('types' in json(await get(`${srv.catalog}/flag-missingtypes/manifest.json`)), false);
});

test('media: ranges, content types, protected header, blobs', async (t) => {
  const mp4 = await get(`${srv.stream}/media/sample.mp4`, { Range: 'bytes=0-15' });
  if (mp4.status === 404) return t.skip('fixtures not generated');
  assert.equal(mp4.status, 206);
  assert.equal(mp4.body.length, 16);
  assert.equal(mp4.body.subarray(4, 8).toString(), 'ftyp');
  assert.match(mp4.headers['content-range'], /^bytes 0-15\/\d+$/);
  assert.equal(mp4.headers['accept-ranges'], 'bytes');
  const mkv = await get(`${srv.stream}/media/blob/mkv`, { Range: 'bytes=0-3' });
  assert.deepEqual([...mkv.body], [0x1a, 0x45, 0xdf, 0xa3]);
  assert.equal(mkv.headers['content-type'], 'application/octet-stream');
  const hls = await get(`${srv.stream}/media/hls/index.m3u8`);
  assert.ok(hls.body.toString().startsWith('#EXTM3U'));
  assert.equal((await get(`${srv.stream}/media/protected.mp4`)).status, 403);
  assert.equal((await get(`${srv.stream}/media/protected.mp4`, { 'X-Mock-Token': 'abc' })).status, 200);
});
