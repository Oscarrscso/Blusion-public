# ADR-007 · Offline detection from request evidence; privacy manifest contents

- **Status:** accepted · **Date:** 2026-10-07 · **Node:** M8

## Context

M8 asks for empty, offline and error states and a `PrivacyInfo.xcprivacy`. The app talks only to addons the user installed, some on a
LAN, some on the internet, some behind a streaming server. "Offline" therefore does not mean one thing.

## Decision 1: no reachability monitor; "offline" is what the requests say

`NWPathMonitor` answers "does the device have a route", not "can the user's addons be reached". On a plane with a LAN addon, or on
Wi-Fi with no internet but a working home server, it would show the wrong banner. Instead every screen asks the evidence it already has:

- `AddonError.offline` is produced from `URLError.notConnectedToInternet`, `.dataNotAllowed` and `.internationalRoamingOff`.
- `Connectivity.isOffline(errors)` is true only when there is at least one failure and **all** of them are `.offline`. One addon that answers
  with HTTP 500 means the network is up, so the per-addon chips stay and no banner is shown.
- Home, Discover, Search and the stream picker replace their error chips (and the misleading "No streams found") with one `OfflineBanner`.
  "Try again" stays available.

Consequences: no extra permission or entitlement, no stale state to keep in sync, and the logic is a pure function tested on Linux
(`OfflineStateTests`). Cost: the banner appears after the first failed requests, not before; acceptable because nothing else would work either.

## Decision 2: privacy manifest

`App/PrivacyInfo.xcprivacy`:

| Key | Value | Why |
|---|---|---|
| `NSPrivacyTracking` | false | no tracking exists |
| `NSPrivacyTrackingDomains` | empty | none |
| `NSPrivacyCollectedDataTypes` | empty | the app has no backend, accounts, analytics or crash reporting; addon URLs go only to the addon the user typed |
| `NSPrivacyAccessedAPITypes` | UserDefaults, reason `CA92.1` | `DefaultsSettingsStore` reads and writes playback preferences |

Not declared, deliberately: file timestamp, disk space, system boot time and active keyboard APIs. `grep` finds no use in the app or its packages;
SwiftData, SwiftUI and AVFoundation make their own declarations as Apple frameworks. Re-run that grep (`scripts/check-project-spec.py` guards
the manifest's shape, not its completeness) when adding any dependency. **Any third-party SDK, including the opt-in MPVKit, ships its own
manifest or needs entries here;** check before release.

`scripts/check-project-spec.py` fails the build if tracking becomes true, any data type is declared, the UserDefaults reason disappears, or
the icon gains an alpha channel.
