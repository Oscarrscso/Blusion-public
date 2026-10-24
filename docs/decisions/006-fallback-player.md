# ADR-006 · Fallback player for MKV, AVI, DTS and other formats AVPlayer cannot open

- **Status:** accepted; the engine is **opt-in and UNVERIFIED** until built on a Mac · **Date:** 2026-10-07 · **Node:** M6
- **Evidence:** web searches on 2026-10-07 (project READMEs, VideoLAN forums and mailing lists, package indexes). Mostly secondary sources
  and mirrors; nothing below was verified by building or running these libraries. Sources are listed at the end.

## Question

PLAN §6 M6: compare MPVKit, VLCKit and KSPlayer on license, App Store compatibility, binary size, HDR and Dolby Vision, ASS and PGS subtitles,
maintenance and SPM support, then implement one behind the `PlaybackEngine` protocol.

## Comparison (as reported; verify before relying on any cell)

| | **MPVKit** (libmpv + FFmpeg) | **VLCKit** (libVLC) | **KSPlayer** (AVPlayer + FFmpeg hybrid) |
|---|---|---|---|
| License | Two builds: **LGPL-3.0 (default)** and a GPL-3.0 build (adds Samba). Some forks are GPL-only. | LGPL-2.1+ (a VideoLAN dev: dynamic linking is fine on the App Store; use the LGPLv2 binary, not an LGPLv3 one) | **GPL by default** (obliges you to open-source your app); a **paid LGPL** license exists |
| App Store | No statement found. LGPL route is the plausible one; the GPL build is the known-bad case (VLC was pulled in 2011 over GPLv2). Open question from users: LGPL asks that users can replace the library, which App Store signing complicates. | Same LGPL question, but VLC itself ships on the App Store | GPL: no, unless you buy the license |
| SwiftPM | **Yes, first-class** (binary xcframeworks) | **No official package** (CocoaPods/Carthage; community wrappers) | Yes (depends on the author's own FFmpegKit fork) |
| Maturity / upkeep | README says it is "only suitable for learning libmpv" and "will not be maintained too frequently"; a mirror shows commits as recent as April 2026 | VLCKit 4 still alpha (4.0.0a18, Dec 2025); 3.x is the stable line | Pushes as recent as April 2026 |
| Binary size | Not published | Old numbers: ~20 MB per architecture stripped (2010s); unstripped far larger | Not published |
| HDR / Dolby Vision | Metal rendering goes through MoltenVK and "is not officially supported yet" per the README; DV profile 7 needs mpv/libplacebo commits not in releases; HDR10 via gpu-next | HDR support limited; a VideoLAN forum thread says DV is not supported on iOS | Claims HLG, HDR10, HDR10+, Dolby Vision (largely via its AVPlayer path) |
| ASS / PGS subtitles | ASS via libass; PGS (bitmap) via FFmpeg + mpv | Both supported by VLC | ASS via libass; "text/image subtitles" |

## Decision

**MPVKit, LGPL build only.** Reasons: SwiftPM-native, which the plan requires and VLCKit lacks; an LGPL build exists, so no paid license and no GPL
obligation on a closed app (KSPlayer needs one of the two); libass and FFmpeg give the subtitle and codec coverage this app needs (MKV, AC3,
DTS, ASS, PGS); VideoToolbox hardware decoding.

Accepted risks, all recorded rather than hidden:

1. **Maintenance warning** in the upstream README. Mitigation: all library calls are in one file (`MPVBackend.swift`) behind `FallbackBackend`,
   so swapping to VLCKit (or a fork) means rewriting that file only.
2. **Rendering path** (MoltenVK) and **Dolby Vision profile 7** are weak spots. v1 plays DV profile 5/8 as the library allows and does not promise profile 7.
3. **Unmeasured binary size.** `scripts/size-report.sh` measures it on a Mac; the real number is the App Store thinning report from an archive.
4. **License sign-off is the human's** (PLAN §8, §9): see `docs/licenses.md`.

## How it is built in

- `PlayerKit` defines `FallbackBackend` (what any third-party player must provide) and `FallbackEngine` (the `PlaybackEngine` that maps backend events to
  `PlaybackState`). Both are portable and covered by host tests with a `MockBackend`, including end-to-end through `PlaybackCoordinator`.
- `Packages/FallbackPlayer` holds `MPVBackend`, guarded by `#if canImport(Libmpv)`, and declares the MPVKit dependency.
- **Opt-in:** the default `project.yml` does not reference `FallbackPlayer`. Lines marked `#fallback# ` are un-commented by
  `scripts/enable-fallback.sh` into `project.fallback.generated.yml` (adds the package, links it, defines `BLUSION_FALLBACK_ENGINE`).
  `FALLBACK=1 ./scripts/verify.sh` builds and tests that variant. Why: this build host had no Xcode, so neither the MPVKit version pin nor the
  libmpv calls could be compiled. A wrong guess must not be able to break the main app, so the main build cannot even resolve the dependency.
- Routing is the policy of PLAN §4 (with ADR-003's refinement): `PlaybackPolicy` returns `.fallback` for MKV/AVI/etc. and for DTS/TrueHD audio when
  `PolicyConfiguration.fallbackEngineAvailable` is true (engine linked **and** enabled in Settings). Otherwise the picker says "format not supported
  yet" and offers the next stream, which is today's default-build behaviour.

## What the human must do (also in `docs/MAC_FIRST_RUN.md`)

1. Build the default app first (no third-party code). Then `FALLBACK=1 ./scripts/verify.sh milestone`.
2. If SwiftPM cannot resolve MPVKit, correct the URL, product name and version in `Packages/FallbackPlayer/Package.swift`.
3. If `MPVBackend.swift` does not compile or render, fix that file only (libmpv symbol names, the `wid`/MoltenVK options).
4. Run the two MKV UI tests, `scripts/size-report.sh`, and the device checklist items; then obtain license sign-off.

## Sources

- MPVKit repository README and mirrors/forks (license variants, Metal and Dolby Vision status, maintenance note), via web search.
- VideoLAN forum and vlc-devel threads on LGPL and App Store use of MobileVLCKit; CocoaPods listing of VLCKit 4.0.0a18; VideoLAN forum thread on Dolby Vision on iOS.
- KSPlayer README as indexed by swiftpackageregistry.com and Swift Package Index (license tiers, dependencies, feature claims).
- Press coverage of VLC's 2011 App Store removal (context for the GPL risk only).

## Update 2026-10-13: in-app codec coverage

- **The iPhone install builds the engine in.** `scripts/install-iphone.sh` generates its spec with `scripts/enable-fallback.sh`, so the
  iPhone app links MPVKit (LGPL build). `scripts/install-mac.sh` does not: the MPVKit versions `from: "0.40.0"` allows fetch a Libuavs3d with no Mac Catalyst slice
  (`docs/CLAUDE_HANDOFF.md`, iOS-only exceptions). `project.yml` and `scripts/archive.sh` keep the
  default build without it. Revert an install by using the default spec again; the routing below then falls back to today's behaviour.
- **Routing.** A container AVPlayer cannot open (MKV, AVI, WebM, …) and DTS, DTS-HD or TrueHD audio go to the engine, as before. AV1 video
  goes to the engine only on chips without hardware AV1 decode (`AVHardware.decodesAV1InHardware`, VideoToolbox), where AVPlayer cannot play
  it at all. On A17 Pro, M3 and later AVPlayer keeps AV1, so ranking, PiP and AirPlay are unchanged there. On the other chips AV1 streams rank
  below native streams. Without an engine, AV1 still gets the AVPlayer attempt, as before.
- **Retry on failure.** When AVPlayer cannot open a stream before it starts (`.format`), the coordinator plays the same stream once in the
  fallback engine, from the same position. That covers codecs the release text does not name, such as VP9 or MPEG-4 Part 2 inside MP4. A
  retry is not recorded as a failure, and a retry that also fails is recorded once. The retry follows Settings: it runs only when the engine is
  linked and enabled (`PlaybackPlan.retriesInFallbackEngine`, from the policy that routed the streams). Network and timeout failures are not
  retried. `AVEngine` maps `.failedToLoadMediaData` to a format failure, so a network error there can reach the engine, which then waits for its
  own network timeout (20 s) before the next stream.
- **Lost on engine playback.** PiP and AirPlay do not work for streams the engine plays (`PlayerViewModel.canPictureInPicture`, `AVEngine`).
- **Not verified here.** The host tests cover routing and the coordinator. Nothing in `MPVBackend.swift` has been compiled against MPVKit or
  played on a device; the iPhone install build and a device run are the check. Dolby Vision profile 7 still plays its base layer only.
- **Still the human's.** The licence and distribution questions in `docs/licenses.md` (LGPL linking, App Store route) are open. The installs
  are for the owner's own devices.
