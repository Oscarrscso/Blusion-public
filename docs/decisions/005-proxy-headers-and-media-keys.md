# ADR-005 · Request headers for `proxyHeaders` streams, and the media-related Info.plist keys

- **Status:** accepted, with UNVERIFIED parts that need a device · **Date:** 2026-10-07 · **Node:** M5

## 1. How to send `behaviorHints.proxyHeaders.request` with AVPlayer

Options:

| | Mechanism | Status per research |
|---|---|---|
| A | `AVURLAsset(url:, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])` | Apple developer-forum staff: "not a supported API, so you should not use it … use AVAssetResourceLoader". Widely used by vendor SDKs; third parties warn of App Store risk. No documented rejection found. |
| B | `AVAssetResourceLoaderDelegate` on a custom URL scheme, fetching with `URLSession` and our headers | Documented. The delegate is **not** called for plain `http(s)` URLs, so the asset URL must use a custom scheme (`blusion-https`), and the delegate does the fetching. |

**Decision:** B is the default and the only strategy compiled into release configurations. A exists behind the compile flag
`BLUSION_UNDOCUMENTED_AV_HEADERS` (off by default) for personal builds, because the distribution route is the human's decision (PLAN §8).
Streams without `proxyHeaders` use a plain `AVURLAsset(url:)` and never touch either mechanism.

Consequences of B (all **UNVERIFIED** until run on a device, see `docs/DEVICE_CHECKLIST.md`):

- It handles byte-range requests for progressive files (MP4/MOV) by translating `AVAssetResourceLoadingDataRequest` into `Range` GETs,
  and rewrites HLS playlists so segment and key URIs stay on the custom scheme (otherwise AVPlayer would fetch them without the headers).
  The UTI strings used for `contentType` and HLS handling are from memory of the documented behaviour.
- Fetching goes through `URLSession`, so **ATS applies**. `NSAllowsArbitraryLoadsForMedia` only exempts loads AVFoundation performs itself.
  Header-proxied streams over plain http to non-local hosts therefore fail by design; https and LAN hosts work.
- Failure of this path is a failed stream like any other: the coordinator advances to the next candidate.

## 2. Info.plist keys (checked against Apple's documentation and search results)

| Key | Decision |
|---|---|
| `NSAppTransportSecurity / NSAllowsLocalNetworking` (M2) | Kept. Exempts local addresses only. |
| `NSAppTransportSecurity / NSAllowsArbitraryLoadsForMedia` | **Added.** "Disables all ATS restrictions for media loaded through AV Foundation" (AVPlayer, AVAsset, AVURLAsset). Many direct stream URLs are plain http, and a player that refuses them is useless. App Review has required a justification for this exception since January 2017; the text is in `docs/APP_REVIEW_NOTES.md`. |
| `NSAllowsArbitraryLoads` | **Never set** (PLAN §1). Apple's docs: its value is ignored on iOS 10+ whenever a more specific ATS key is present, so it would have no effect anyway. |
| `UIBackgroundModes: [audio]` | **Added.** Required for background audio and Picture in Picture ("Audio, AirPlay, and Picture in Picture"). |
| `AVAudioSession` category | `.playback` with mode `.moviePlayback`, activated when playback starts (not at launch), so other apps' audio isn't cut off early. |

## 3. Picture in Picture and AirPlay rules adopted

- PiP uses `AVPictureInPictureController(playerLayer:)` for the AVPlayer engine only. It starts **only from a user action**
  (Apple: programmatic start is rejected in App Review). `canStartPictureInPictureAutomaticallyFromInline` is left at its system default.
- AirPlay uses `AVRoutePickerView`; `allowsExternalPlayback` stays true.
- The fallback engine (M6) has no PiP; the PiP button is hidden for it.

## Verification tasks for the human

1. Play the mock "Mock Protected" stream (needs header `X-Mock-Token: abc`) on a device: confirms path B for progressive MP4.
2. Repeat with an HLS stream that requires a header (not available from the mock; use any header-protected HLS you are entitled to use).
3. With `BLUSION_UNDOCUMENTED_AV_HEADERS` enabled, confirm path A also works, if you choose to rely on it for a personal build.
