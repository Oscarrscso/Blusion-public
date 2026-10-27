# Built-in player: capabilities, limits and blockers

Status on 2026-10-24. "Built" means compiled for iOS with the fallback engine and covered by host tests; nothing here was watched on a device
unless it says so. Source labels (HDR, DV, Atmos in a release name) are not proof of what plays. The on-screen Statistics panel was removed
on 2026-10-24; `PlaybackEngine.statistics()` still reads what the engine decodes and outputs, for a future debug view.

**Options panel (all engines, iPhone and Mac; replaced the system menus on 2026-10-24):** the bar under the timeline opens one glass
panel, at the side on a wide screen and at the bottom on a tall one, with tabs for Subtitles, Audio, Picture, Speed and Chapters. Values
are chips, delays are −/+ steppers (hold to repeat, tap the value to reset), switches are toggles; picking a track or a chapter closes it,
a tap outside or Escape closes it too. **Start-up (2026-10-25):** until the film's first frame is on screen (`PlayerContent.isVideoReady`;
playing over AirPlay counts) the player shows only a spinner on black, and Close: no poster, play button, skip buttons, subtitles or
scrubber. Another
stream or the next episode waits for its own first frame the same way. After that the spinner shows only for a stall, with the controls
hidden. The picture never animates into place: the video views
lay out with Core Animation's actions off, so a new size or scaling mode doesn't slide it up or down.

**Preload (iPhone and iPad, AetherEngine):** the moment a player opens (`PlayerContent.init`, before its screen appears), its first stream
starts downloading with `AetherEngine.prewarm` (4 MB, redirects followed: a debrid link resolves here), and `AetherSession.load` waits up
to 4 s for a warm still under way, since the engine adopts only a finished one. AVPlayer and mpv fetch their own bytes, so their streams
are not warmed.

**Readied before it opens (iPhone, iPad and Mac):** a stream Blusion plays opens its player only once the film is ready. Tapping a
stream (or Auto Pick) turns its play button into a spinner while `PlayerViewModel.prepare` starts it off screen: muted, held paused on
its first frame, saving no progress (`ProgressSession.isRecording`), so nothing reaches Continue Watching or Trakt. The player screen
takes that model and plays at once. The first stream listed starts readying in the background as soon as it arrives, so playing it is
nearly instant; tapping another stream replaces it, tapping the spinning one calls it off, and leaving the picker closes it. A muted
start still takes the audio session, so music from another app stops when a stream list loads. mpv's view starts at 1280×720 so it has
a picture layer to draw on before the screen lays it out. The picture itself can only be drawn once the player's screen is up, so the
player's spinner takes over from the button's until the first frame: a spinner shows from the tap until the picture.

**Swipe to seek (iPhone and iPad, 2026-10-25):** a sideways swipe anywhere on the picture seeks, right forward and left back. A swipe across
the whole width moves two minutes, or the whole of a shorter video (`SwipeSeek`). It drives the timeline's own scrub, so the timeline shows
where it will land, and it seeks once, when the finger lifts. A drag's first movement decides it: up or down at the sides stays brightness
and volume (that Settings switch covers only those two), and a drag that is part of a pinch never seeks.

**Picture tab (all engines, iPhone and Mac):** Fit / Fill / Stretch, Zoom, **Aspect Ratio** (Original, 1:1, 5:4, 4:3, 3:2, 1.66, 16:10,
16:9, 1.85, 1.90, 2:1, 2.20, 2.35, 2.39, 2.40, 2.55, 2.76) and **Crop** (4:3 to 2.76:1, centred, takes off bars burned into the video). mpv
applies them itself (`video-aspect-override`, `video-crop`); AVPlayer and AetherEngine through `VideoGeometry`, which places the whole picture
and clips it to the kept part. Fit is remembered; zoom, aspect and crop are per video. **Dolby Vision** switch (Picture tab, and Settings → Player →
Picture): off plays the HDR10/HLG base layer (AetherEngine `dolbyVisionHandling = .baseLayerOnly`, rebuilt at the current position; mpv
`vf=format=dolbyvision=no`). Shown only for Dolby Vision streams with a base layer (not profile 5) on those two engines; AVPlayer always shows
Dolby Vision.

## Engines

| | AVPlayer (`AVEngine`) | mpv (`MPVBackend`, MPVKit 0.41 / mpv 0.40, iPhone and iPad only) |
|---|---|---|
| Containers | MP4, MOV, M4V, HLS | MKV/WebM, AVI, TS/M2TS, MPEG-PS, FLV, OGG, ASF, and the above |
| Video | H.264, HEVC, AV1 on A17 Pro/M3+ | + AV1 (dav1d), VP9, MPEG-2, VC-1, MPEG-4 ASP; VideoToolbox first, FFmpeg software otherwise |
| HDR | HDR10, HLG, Dolby Vision 5/8.1/8.4 by the system | HDR10, HLG, DV 5 and 8 via libplacebo + libdovi; DV 7 base layer + RPU (the enhancement layer, MEL or FEL, is **not** decoded). HDR10+ dynamic metadata is not used. EDR output through `target-colorspace-hint`; tone mapping curve and "always SDR" selectable |
| Audio | AAC, AC-3, E-AC-3 (Atmos passes to the system's spatial renderer where the route supports it) | + TrueHD, DTS, DTS-HD MA, FLAC, Opus: decoded to multichannel PCM. **Atmos and DTS:X objects are not rendered**, only their channel bed |
| Subtitles | embedded text tracks (styled through text style rules); files drawn by the app: SRT/VTT/ASS (styling simplified: no karaoke, motion, drawings) and PGS `.sup` pictures | embedded and file subtitles drawn by libass/FFmpeg with full ASS styling, PGS, VobSub, DVB; HDR subtitle brightness (`sub-hdr-peak`) |
| Timing controls | the app's subtitle offset (files) | subtitle delay (all), audio delay |
| Extra audio file | no | yes (Audio tab → Add File) |
| Picture | fit/fill/stretch, zoom (pinch on iPhone), aspect override and crop (video surface) | fit/fill/stretch, zoom, aspect override, crop, Dolby Vision off, deinterlacing (auto/always/off) |
| Upscaling | AI: VideoToolbox low-latency super resolution, SDR below screen resolution, steps aside on HDR, unsupported chips, embedded subtitles or when it cannot keep up | "High quality" EWA Lanczos (Spline36 in Low Power Mode); AI mode uses the same and says so |
| PiP, video AirPlay | yes | **no** (see blockers) |
| Ambient Mode | yes (edge colours from a 32×18 copy of the frame) | no (mpv draws straight to the screen) |

### AetherEngine (`AetherBackend`, AetherEngine 7.47, iPhone and iPad only; added 2026-10-24)

The default engine for streams AVPlayer can't open (Settings → Fallback player → Engine; mpv is the other choice). It demuxes with its own
FFmpeg and gives AVPlayer what AVPlayer can play, so most MKVs keep the system's own Dolby Vision, HDR10 and E-AC-3 Atmos passthrough; the
rest decodes in VideoToolbox (dav1d/libavcodec in software) and draws into a sample-buffer layer.

| | AetherEngine |
|---|---|
| Containers | MKV/WebM, MP4/MOV, TS/M2TS, AVI, FLV, OGG, ASF/WMV, RealMedia, HLS |
| HDR | HDR10, HDR10+, HLG, Dolby Vision 5/8.1/8.4/AV1 10 by the system. **Profile 7 FEL**: both layers decode in VideoToolbox, Metal composes them and every frame carries its RPU converted to 8.1 (Settings → "Compose Dolby Vision FEL", on by default). MEL, and FEL the device can't decode twice in real time, convert to 8.1 (enhancement layer dropped, lossless for MEL) |
| Audio | AAC, AC-3, E-AC-3 (Atmos objects passed to the system), FLAC, ALAC copied; TrueHD, DTS, DTS-HD MA, Opus and others bridged to multichannel. **TrueHD Atmos and DTS:X**: objects and heights rendered into a 7.1.4 bed delivered as Apple spatial audio (Settings → "Spatial audio for TrueHD and DTS:X", on by default; lossy, 320 kbps per channel, instead of the lossless 7.1 bed) |
| Subtitles | embedded text, PGS, VobSub and DVB drawn by `AetherSubtitleOverlay` with the app's subtitle style; files drawn by the app as on AVPlayer. ASS keeps colours, bold/italic and positions, not fonts, karaoke or motion: "Show Full Styling" moves the stream to mpv |
| Timing controls | subtitle delay, audio delay (±2 s) |
| Picture | fit/fill/stretch, zoom, aspect override and crop, Dolby Vision off |
| Not here | external audio file, deinterlacing and tone-mapping choice, upscaling, PiP, Ambient Mode (all on mpv or AVPlayer) |

Trade-offs, all from AetherEngine's docs (`docs/dolby-vision-fel.md` there) and not yet watched on a device:

- The FEL route runs on the software path, so an E-AC-3 Atmos track on an FEL title plays as its 5.1/7.1 bed without objects (TrueHD is
  unaffected), AirPlay plays sound only, and there is no PiP. Turn FEL composition off for that title to get the native route back.
- AetherEngine measured FEL with Dolby Vision display management on Apple TV only. On iPhone the composed picture is correct; whether iOS
  applies Dolby Vision display mapping to it has not been verified.
- Start-up: Blusion's play arrives before AetherEngine has a session, so `AetherSession` keeps it and plays once the load finishes (before
  2026-10-24 every AetherEngine stream sat paused until the 20 s start timeout). Segments are served progressively
  (`progressiveSegmentDelivery`), so the first frame shows on a segment's first fragments.
- A stream AetherEngine can't start (format or engine error before the first frame) is tried once in mpv at the same position.

Both: chapters (Chapters tab, `[` and `]` on a keyboard), Skip Intro/Recap/Credits from chapter names, continuity of speed, tracks
(matched by language and name), delays, picture settings and engine-loaded files when the coordinator changes engine (fallback retry, next
stream, reconnect, "Play in Advanced Player"). A dropped connection mid-stream reloads the same stream once where it stopped before moving on;
a buffer that is still filling is not treated as a stall.

## Subtitles

- Defaults (Settings → Player): language, Always / Forced only / Off, prefer SDH. Embedded tracks win over files; a file picked first gives
  way to an embedded track that appears later. Forced-only follows the audio language when no subtitle language is set.
- Sources: the stream's own, addons (re-queried with each new stream's hash and file name when the stream changes), local files (SRT, VTT,
  ASS/SSA, SUP), and OpenSubtitles.com (Settings → Player: the user's own free API key, optional login; results matched by moviehash, computed
  with two range requests when the addon gives none).
- A VobSub file on AVPlayer switches the stream to the fallback engine at the same position. A styled ASS file on AVPlayer offers
  "Show Full Styling", which does the same.

## Mac/iPhone parity

The Mac app has every control above that its engine supports, with the same options panel, Settings page and OpenSubtitles account (synced through
iCloud Keychain). Intentionally iPhone/iPad-only:

- **Preloading.** It is AetherEngine's (`prewarm`), and the Mac has no AetherEngine; AVPlayer offers no way to hand it fetched bytes.
- **AetherEngine.** Its FFmpegBuild, LibDovi and LibTrueHD xcframeworks ship iOS, tvOS, visionOS and macOS slices but no Mac Catalyst
  slice, so the Catalyst app cannot link it either. FEL composition and TrueHD/DTS:X spatial audio are therefore iPhone/iPad-only.
- **The fallback engine.** MPVKit 0.41's `Libuavs3d` (AVS3 decoder) and `Libluajit` binaries have no Mac Catalyst slice, so the Catalyst
  build cannot link `_FFmpeg`. Until a build of MPVKit without them exists, the Mac plays MP4/MOV/HLS only; mpv-only features (full ASS
  styling, PGS/VobSub in MKV, TrueHD/DTS, audio delay, deinterlacing, tone-mapping choice) follow from that.
- **Brightness and volume swipes, swipe to seek, and pinch zoom.** No touch screen; the Mac's keyboard already sets the volume (↑ ↓ M) and
  seeks 10 s (← →), the timeline can be dragged, and an app cannot set a Mac display's brightness. Zoom is in the Picture tab on both.

## Blockers and what would unblock them

| Wanted | Why not now | Way forward |
|---|---|---|
| VVC/H.266 | No decoder: not in VideoToolbox, not enabled in MPVKit 0.41's FFmpeg (`ff_vvc_decoder` absent) | A custom FFmpeg/MPVKit build with `--enable-decoder=vvc` (FFmpeg 7.1+, software only, heavy at 4K) |
| Dolby Vision 7 FEL in mpv | FFmpeg/libplacebo in MPVKit 0.41 apply the RPU to the base layer only | done in AetherEngine (above); mpv 0.42 + newer libplacebo would bring it to mpv |
| Atmos / DTS:X objects in mpv | FFmpeg decodes the bed only. Passthrough (bitstream) is not available to apps on iOS | done in AetherEngine: rendered to spatial audio (TrueHD, DTS:X), passed through (E-AC-3) |
| E-AC-3 Atmos objects on an FEL title | the FEL route has no AVPlayer, and only AVPlayer renders E-AC-3 objects | a second, audio-only engine kept in sync (not built) |
| PiP and video AirPlay for mpv | PiP needs an `AVSampleBufferDisplayLayer` fed with frames; mpv renders through Vulkan into a CAMetalLayer with no frame export in libmpv's render API. AirPlay video needs an AVPlayer item the receiver can play, which MKV is not | a render path that copies mpv frames into sample buffers (costly at 4K), or remuxing to HLS through a local server |
| HDR10+ dynamic metadata | not exposed by mpv; AVPlayer's handling is the system's | — |
| AI upscaling in mpv | libmpv has no ML scaler and no frame export for VideoToolbox; bundling a CNN shader was ruled out (licence or content fit, see docs/licenses.md) | — |
| Reliable intro/credits markers without chapters | free services (AniSkip, IntroDB) cover anime or few titles and need ID mappings; guessing from running time would skip real scenes | an opt-in community marker source later |

## Not yet checked on a device

HDR/EDR output through MoltenVK, DV profile 5/8 colours, multichannel PCM over HDMI/AirPlay, VideoToolbox super-resolution speed per chip,
PGS placement against the picture, OpenSubtitles against the live API (needs a key), and mpv's `deinterlace=auto` on this build.
