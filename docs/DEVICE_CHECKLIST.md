# Device checklist

Things the simulator and CI cannot prove. Items are marked `[d]` in STATE.md until someone ticks them here.
Run each on a real iPhone (and the iPad item on an iPad). Tick with the date and iOS version.

## Playback (M5)

- [ ] **Picture in Picture:** play the mock MP4, tap the PiP button; video floats, audio continues; returning restores the player. PiP never starts without a tap.
- [ ] **AirPlay:** tap the route button, pick an AirPlay device; playback moves, scrubbing and pause still work from the phone.
- [ ] **Lock-screen controls:** lock the phone while playing; title, elapsed time and play/pause/skip appear and work.
- [ ] **Background audio:** switch to another app while playing; audio continues; Control Center shows the right title.
- [ ] **Interruptions:** a phone call or alarm pauses playback; after it ends playback resumes only if the system says so.
- [ ] **Headphone unplug:** unplugging wired headphones pauses playback.
- [ ] **Header-proxied stream (ADR-005):** the mock's "Mock Protected" stream plays; with the header removed in the mock it fails and playback advances to the next stream.
- [ ] **Resume:** quit mid-movie, reopen, play again: it offers to continue within a few seconds of where you stopped.

## Formats (M6)

- [ ] **MKV (H.264 + AC3)** from the mock plays with picture and sound on device.
- [ ] **MKV with DTS audio** plays with sound on device.
- [ ] Hardware decode is used for H.264/HEVC (check CPU/battery is sane over 10 minutes).

## Streaming server (ADR-004, UNVERIFIED)

- [ ] With a Stremio-compatible streaming server you run yourself, set its URL in Settings, play an `infoHash` stream, confirm it starts.
      If not, capture the requests a Stremio client makes to the server for the same title and adjust `StreamingServerRoute` only.

## Library and settings (M7)

- [ ] **Persistence across launches:** save a title, watch two minutes, change the subtitle language, force-quit, reopen: Library, Continue Watching and the setting are all still there.
- [ ] **Upgrade path:** install a build from before M7 (schema V1), add an addon, then install this build over it: the addon survives and Library works (SwiftData V1 to V2 migration on a real store).
- [ ] **Keychain:** after "Clear data > All addons", reinstalling the app does not resurrect addon links; after deleting and reinstalling the app, no old links appear.
- [ ] **Swipe actions and the clear-data confirmation** are reachable with VoiceOver and with the largest Dynamic Type size.

## Release (M8)

- [ ] **Offline:** with Airplane Mode on, Home, Discover, Search and a stream list show the "You're offline" banner (not a pile of error chips); turning it off and tapping "Try again" recovers without a relaunch.
- [ ] **Launch time:** on the oldest supported iPhone you own, cold launch to the Home tab feels instant (budget in `LaunchPerformanceTests`: 8 s ceiling, `XCTApplicationLaunchMetric` baseline to set once on the reference device).
- [ ] **Leaks:** run `./scripts/leaks.sh` on a Mac, or Instruments > Leaks for a few minutes of browsing and one playback; no leak stack runs through Blusion's own code.
- [ ] **Privacy manifest:** Xcode > Product > Archive > *Generate Privacy Report* shows exactly the declared UserDefaults reason and nothing else.
- [ ] App launches without the local-network prompt appearing for non-LAN addons; the prompt appears (once) for a LAN addon.
- [ ] Dynamic Type at the largest accessibility size: Home, Detail, Addons, Player controls are readable and nothing is clipped.
- [ ] VoiceOver can install an addon, open a title, pick a stream and play/pause.
