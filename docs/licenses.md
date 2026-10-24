# Licenses and obligations

This file lists what the app ships and what that obliges. **It is not legal advice, and it is not an audit.** The human signs off before any
release (PLAN §8, §9). Items marked ☐ are open.

## Always in the app

| Component | License | Notes |
|---|---|---|
| Blusion's own code | the owner's choice (none chosen yet) | ☐ add a LICENSE file when decided |
| Swift standard library / Apple frameworks | Apple SDK terms | no redistribution obligations |
| Swift Testing, XCTest | test targets only | not shipped |
| Node mock addon (`Tools/MockAddon`) | development tool, zero dependencies | not shipped |

No third-party code is linked into the **default** build: the dependency list is empty by design (ADR-001).

## Data the app downloads

| Data | Terms | Notes |
|---|---|---|
| IMDb `title.ratings.tsv.gz` (datasets.imdbws.com) | IMDb non-commercial datasets: personal and non-commercial use only (https://developer.imdb.com/non-commercial-datasets/) | Downloaded to the device once a day, kept out of backups, never uploaded or redistributed. Credit line in Settings → IMDb ratings and Acknowledgements. ☐ A public or commercial release needs IMDb's permission or a licence: do not ship this to others on the current terms. |
| IMDb `title.episode.tsv.gz` (datasets.imdbws.com) | IMDb non-commercial datasets: personal and non-commercial use only (https://developer.imdb.com/non-commercial-datasets/) | Episode-to-series/season/number mapping downloaded only on unmetered connections, indexed on device and kept out of backups. The data is not redistributed. |

## Brand marks in the app

| Marks | Terms | Notes |
|---|---|---|
| Six streaming service logos in `App/Assets.xcassets` (`StreamLogoNetflix`, `StreamLogoPrimeVideo`, `StreamLogoAppleTV`, `StreamLogoHBOMax`, `StreamLogoParamountPlus`, `StreamLogoCrunchyroll`), from Simple Icons 13.21.0 (HBO Max from 15.x, the current mark) | Icon files CC0-1.0 (the package licence). Each mark is still that service's trademark, and CC0 does not cover it. Simple Icons asks users to seek permission for brand use. | Shown on a stream's card to name the service it comes from. ☐ A release needs sign-off that each service's mark may be shown. |
| Disney+ logo (`StreamLogoDisneyPlus`, from Wikimedia Commons `Disney+ 2024.svg`, author Disney Enterprises) and Peacock logo (`StreamLogoPeacock`, from `NBCUniversal Peacock Logo (2026).svg`, author NBCUniversal) | Commons marks both as public domain as simple text logos, and as trademarked. Copyright is not the issue: the trademarks belong to Disney and NBCUniversal. | Used on Disney+ and Peacock streams. Hulu streams also show the Disney+ logo, as the viewer chose: Hulu streams from the Disney+ app. The Disney+ SVG is trimmed to its wordmark paths, with the Illustrator styles and hidden layers removed. ☐ Same sign-off as above. |
| Blu-ray and Ultra HD Blu-ray logos (`StreamLogoBluRay`, `StreamLogoUHDBluRay`) for a disc's box beside a release's name, from Wikimedia Commons (`Blu-ray Disc.svg`, `Ultra HD Blu-ray logo.svg`, author Blu-ray Disc Association) | Commons lists the files as public domain, but marks them as trademarked, so they are not free to use. ☐ A release needs sign-off that the Blu-ray Disc Association's marks may be shown. | Personal use only, like the service logos. |

## Fallback engine (ADR-006) — in the iPhone install

`scripts/install-iphone.sh` builds the fallback engine in, so MKV, AVI, DTS, TrueHD and AV1 play in the iPhone app. `scripts/install-mac.sh` leaves it out: the MPVKit versions `from: "0.40.0"` allows fetch a Libuavs3d with no Mac Catalyst slice. The default `project.yml` and `scripts/archive.sh` still leave it out: a release that ships it needs the sign-off below.

Linking MPVKit's **LGPL** build makes the app a distributor of LGPL libraries. Typical component set of that build (verify against the exact
MPVKit release you pin; this list is from project documentation, not from inspecting a binary):

| Component | License (as reported) | Obligation sketch |
|---|---|---|
| libmpv | LGPL-2.1-or-later when built without GPL features (GPL-2.0-or-later with `-Dgpl=true`) | |
| FFmpeg libraries | LGPL-2.1-or-later with GPL features disabled (GPL-2.0-or-later otherwise) | |
| libplacebo | LGPL-2.1-or-later | |
| libass and other helpers | permissive (ISC/BSD/MIT) or LGPL | |
| MoltenVK | Apache-2.0 | include the license and NOTICE text |
| MPVKit wrapper itself | LGPL-3.0 | |

What LGPL asks, in practice, and where we stand:

1. **Use the LGPL build, never the GPL one.** The GPL build would put the whole app under GPL, which conflicts with App Store distribution.
   `scripts/check-project-spec.py` fails the build if `Packages/FallbackPlayer/Package.swift` references a GPL product.
2. **Link dynamically** (frameworks), so a user could in principle replace the library. ☐ Confirm the MPVKit xcframeworks that get resolved are dynamic.
   Static linking into the app binary needs a relinking story that App Store signing makes hard.
3. **Show notices.** The app's Settings → Acknowledgements screen lists each component, its license and a link to its source. ☐ Fill in exact
   versions once MPVKit is pinned (Acknowledgements currently lists MPVKit only when the engine is built in).
4. **Offer the source.** Link to the exact MPVKit release and its build scripts for the version you ship. No Blusion modifications to these libraries exist.
5. **Open question (VideoLAN forum, unresolved):** LGPL asks that end users be able to replace the library; App Store signing complicates that.
   ☐ Counsel decides whether dynamic linking plus source availability is acceptable for your distribution route.

## AetherEngine (added 2026-10-24) — in the iPhone install, with the fallback engine

`Packages/AetherPlayer` links [AetherEngine](https://github.com/superuser404notfound/AetherEngine) 7.47 and is linked only through
`Packages/FallbackPlayer`, so it is in exactly the builds that have mpv (the iPhone install), and in neither the default build nor the Mac
app. It is the default engine for streams AVPlayer can't open; mpv stays as its backup and for full subtitle styling (docs/PLAYER.md).

| Component (resolved version) | License | Notes |
|---|---|---|
| AetherEngine 7.47.0 | LGPL-3.0 with an App Store / DRM exception (Section 7 additional permission) | the exception explicitly allows App Store and TestFlight distribution despite their signing and re-linking limits |
| FFmpegBuild 3.9.0 (FFmpeg n8.1.3, renamed `AetherLib*`) | LGPL-2.1 | **dynamic** frameworks embedded in the app, which keeps the LGPL relink requirement satisfiable |
| dav1d, zimg, libzvbi (inside FFmpegBuild) | BSD-2-Clause, WTFPL, LGPL-2.1+ (GPL parts excised by FFmpegBuild 2.0.0) | dynamic frameworks |
| LibDovi 2.1.0 (dovi_tool's `dolby_vision` crate) | MIT | static, inside `AetherPlayer.framework` |
| LibTrueHD 3.0.0 (the `truehd` crate from truehdd) | MIT wrapper, Apache-2.0 decoder | static, inside `AetherPlayer.framework`; include the Apache-2.0 notice |

What this changes against the mpv section above:

1. **Prebuilt binaries from one maintainer.** FFmpegBuild, LibDovi and LibTrueHD are xcframeworks built and published by AetherEngine's
   author, not by the upstream projects. The owner approved this on 2026-10-23. ☐ Before a public release, rebuild them from their
   build scripts (`FFmpegBuild/build.sh`, LibDovi and LibTrueHD's) or diff against your own build.
2. **Its own dynamic framework.** MPVKit links a static FFmpeg into the executable; AetherEngine linked beside it would bind to that one.
   `AetherPlayer` is a dynamic framework, so its FFmpeg calls bind to `AetherLibavcodec` and friends (checked with
   `nm -m AetherPlayer.framework/AetherPlayer | grep _avcodec_open2` → `(from AetherLibavcodec)`). `scripts/check-project-spec.py` fails if
   the manifest stops being dynamic, gains a PlayerKit or MPVKit dependency, or enables the measurement-only `TrueHDReferenceRender` trait.
3. **Optional components enabled** (package traits): `DualLayerDolbyVision` (profile 7 FEL composed on the GPU), `TrueHDObjectAudio`
   and `DTSXObjectAudio` (Atmos and DTS:X objects rendered to Apple spatial audio). AetherEngine's manifest says these "may be subject
   to third-party patent licensing; an integrator that enables one is responsible for its own licensing". ☐ Counsel, for any distribution
   beyond personal use. This replaces the "objects are not rendered, so no object-audio renderer is shipped" line below for these builds.
4. **Notices.** Settings → Acknowledgements lists each component when the engine is built in.

## Player features added on 2026-10-23 (codecs, subtitles, upscaling)

Nothing new is linked: every feature below uses Apple frameworks or the MPVKit build already listed. What each one obliges, as far as this
file can say (☐ = for the human or counsel):

| Feature | Comes from | Obligation / risk |
|---|---|---|
| ASS/SSA, PGS and VobSub drawing in the fallback engine | libass (ISC), FFmpeg (LGPL) | covered by the MPVKit rows above |
| App's own ASS/SRT/VTT and PGS (.sup) drawing | Blusion's code (`ASSParser`, `PGSDecoder`) | none: written from the format descriptions, no third-party code |
| HDR tone mapping, Dolby Vision RPU (profiles 5, 8, and 7's base layer) | libplacebo (LGPL-2.1+), libdovi (MIT) in MPVKit | ☐ "Dolby Vision" and "Dolby Atmos" are Dolby trademarks: the app shows them as facts about a stream (statistics, stream details), never as a certification. Rendering DV with libplacebo is not Dolby's licensed decoder, and the statistics say so. |
| AC-3, E-AC-3, TrueHD, DTS, DTS-HD MA software decoding | FFmpeg in MPVKit | ☐ Patent licences for these codecs are not covered by the LGPL. Most AC-3 patents have expired; E-AC-3, TrueHD and DTS-HD may not have everywhere. Counsel decides for any distribution beyond personal use. Atmos and DTS:X objects are **not** rendered (decoded to their channel bed), so no object-audio renderer is shipped. |
| HEVC/AV1/H.264 decoding | VideoToolbox (Apple) first; FFmpeg/dav1d software fallback in MPVKit | ☐ Software HEVC decoding (when VideoToolbox declines a stream) falls under the HEVC patent pools; dav1d (BSD-2) for AV1 is royalty-free. |
| VVC/H.266 | nothing: no decoder in MPVKit 0.41's FFmpeg build or on Apple platforms | streams are shown as unsupported; nothing to license |
| AI super resolution | VideoToolbox `VTLowLatencySuperResolutionScaler` (Apple, iOS 26) | Apple SDK terms only |
| Conventional high-quality scaling in the fallback engine | libplacebo's EWA Lanczos | covered above. No third-party upscaling shaders are bundled: Anime4K (MIT) is tuned for line art, and FSRCNNX's licence is unclear (GPL-3.0 and MIT both listed), so neither ships. |
| OpenSubtitles.com search and download | the user's own API consumer key and account | ☐ OpenSubtitles' API terms apply to the user's key. The app names OpenSubtitles on each subtitle it downloads from there. |

## Sign-off

| Question | Decision | Who / when |
|---|---|---|
| Ship the fallback engine at all? | ☐ | |
| Distribution route (TestFlight / App Store / personal) | ☐ | |
| LGPL obligations satisfied for that route | ☐ | |
| Own license for Blusion's code | ☐ | |
