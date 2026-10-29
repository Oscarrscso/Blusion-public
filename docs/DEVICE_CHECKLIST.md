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
- [ ] **Privacy manifest:** Xcode > Product > Archive > *Generate Privacy Report* shows UserDefaults CA92.1 and DiskSpace E174.1 for the app’s own declared API uses.
- [ ] App launches without the local-network prompt appearing for non-LAN addons; the prompt appears (once) for a LAN addon.
- [ ] Dynamic Type at the largest accessibility size: Home, Detail, Addons, Player controls are readable and nothing is clipped.
- [ ] VoiceOver can install an addon, open a title, pick a stream and play/pause.

## Native downloads (ADR-008, iPhone and Mac)

All items below require manual device checks; compilation and installation do not establish playback or CDN interoperability.

- [ ] Download an authorized progressive MP4/MOV and a supported fallback container from direct, debrid and ready-to-play usenet sources. Confirm native Download and Download in Infuse remain separate.
- [ ] Download a header-protected file; confirm it completes without URLs, headers or credentials appearing in logs, defaults, SwiftData or session snapshots.
- [ ] Pause, resume, cancel/delete, retry a failure and Delete All. Try rapid repeated controls and deleting while a completion is arriving. Only the selected UUID's files disappear.
- [ ] Interrupt Wi-Fi, lock/background, allow OS termination, and relaunch. One transfer per UUID survives/reconciles, with progress updates and no duplicate task. Separately force-quit: iOS cancels background activity until the app is opened again.
- [ ] Rotate an expired link (401/403/410). The original addon and same release are rematched. Verify valid 206/If-Range continuation, 200 clean replacement, changed validators, wrong offsets, 416 and servers without Range support. No mixed files or silent release changes.
- [ ] Start with insufficient space; fill storage mid-transfer; confirm a recoverable failure with no retry loop and successful cleanup. Unknown lengths retain a 256 MiB reserve.
- [ ] Cellular is off initially. Change it during a transfer; confirm the replacement request follows the preference and Wi-Fi work can wait for connectivity.
- [ ] Enable airplane mode, open Library → Downloads, play/seek MP4 and MKV, and resume from Continue Watching. No addon, OpenSubtitles, remote hash or preload requests are initiated by the offline player.
- [ ] Download SRT/VTT/ASS and SUP subtitles. Play embedded and saved external tracks offline, including language/default selection. Missing or failed subtitles do not discard the video.
- [ ] Background/foreground and terminate/relaunch during offline playback: position, pause, tracks and picture settings restore locally. Remove a saved file outside the app and confirm a local missing-file error.
- [ ] Delete When Watched is off initially. Enable it, finish a download, and close the player: deletion occurs after the engine releases the file. Delete while playing is also deferred until close.
- [ ] Catalyst: repeat queue, pause/resume, relaunch, delete, storage settings, offline MP4 and mpv containers. AetherEngine remains iOS-only. Check actual quit/relaunch scheduling; iOS background guarantees do not imply identical Mac behavior.
- [ ] Upgrade a V4 store to V5; existing addons, library and progress survive and Downloads persists. Clear Data → Downloads and Everything cancel and remove downloads and device-local secrets.
- [ ] Privacy report includes DiskSpace E174.1 (download capacity checks), alongside UserDefaults CA92.1.

- [ ] Tap Download on a stream, movie and episode: loading circle appears while resolving/queueing, a tap haptic is emitted on iPhone, and the circle clears on success/failure. Ghost mode continues to suppress Watched changes intentionally.
- [ ] Queue four media files: at most three transfer simultaneously, the fourth starts when one finishes/pauses, and progress remains responsive while subtitle files arrive. Verify low-space checks reserve remaining bytes for all active files.
- [ ] Delete All during active transfers, terminate immediately and relaunch: saved deletion intent completes cleanup without restarting those downloads.

- [ ] Stream Download matches the Play circle's size, shape and colour directly below it. During transfer it shows a filling progress ring; tap the ring to pause/resume. Title, episode and Library progress update from the same received/expected byte counts, including after relaunch.

- [ ] Title-page Download stays the same 50 pt circle as Save/Watched/Trailer (40 pt on Mac), without oversized glass or overlap. Stream Download remains matched directly below Play.
- [ ] Hold Download while idle, starting, transferring, paused, failed and complete: Library → Downloads opens; releasing the hold does not also start, pause or resume the transfer.
- [ ] Downloads shows accurate bytes, percentage, live speed and estimated remaining time. Expand Details for format, quality, codecs/HDR, source, addon, dates, watch state/runtime and subtitles. Older downloads upgrade locally without addon/network lookups; missing facts stay omitted.
