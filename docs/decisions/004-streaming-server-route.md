# ADR-004 · Playing `infoHash` streams through a user-supplied streaming server

- **Status:** accepted with an **UNVERIFIED assumption** · **Date:** 2026-10-07 · **Node:** M4 (research node required by PLAN §4)

## Question

PLAN §4: `infoHash` streams play "only when the user has set a Stremio-compatible streaming server URL in Settings (research its HTTP route in an
ADR first)". What URL turns `{infoHash, fileIdx, sources}` into something AVPlayer can open?

## What could be established

- The desktop app's local server listens on `http://127.0.0.1:11470/`, and users can add other server URLs such as `http://192.168.1.100:11470/`.
- Official docs I could reach (stremio-web configuration page, stremio-core streaming-server model page) do **not** document the torrent route.
  They only name `POST /settings`, `GET /get-https`, and `/casting`. No create endpoint, no stats route, no `{infoHash}/{fileIdx}` path.
- Secondary evidence (a community server that re-implements Stremio's closed-source `server.js`, and the `enginefs` library behind it) shows
  engines addressed as `/<infoHash>/<fileIdx>` with Range/206 streaming. That is a third-party description of a closed-source server.

## Decision

Implement the simplest route behind a single, isolated function (`StreamingServerRoute.url`):

    <server base>/<infoHash lower-case>/<fileIdx>

`fileIdx` is the addon's value; when the addon omits it (upstream: "the largest file is selected") we send `-1`.

**UNVERIFIED:** (a) the path shape, (b) `-1` meaning "choose the largest file", (c) whether the server needs a prior create call carrying tracker `sources`.
Nothing else in the app depends on these details: a wrong guess produces a 404 or timeout, which the playback coordinator treats like any failed
stream (it advances to the next candidate).

## Verification task for the human (also in docs/DEVICE_CHECKLIST.md)

With a streaming server you run yourself, install an addon that returns `infoHash` streams, set the server URL in Settings, play one, and confirm it starts.
If it does not, capture the requests a Stremio client makes to the server while playing the same title and adjust `StreamingServerRoute` only.

## Consequences

- Torrent streams stay hidden (with a hint) until a server URL is set. No torrent engine is embedded.
- The server URL is user data, but it can embed credentials, so it is stored in the Keychain and redacted like addon URLs.
