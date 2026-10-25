# Blusion

Blusion is an iPhone/iPad media browser and player for Stremio-protocol addons, with a Mac Catalyst app from the same target.
It supports search, configurable Home rows, saved titles, resume, subtitles, two-way Trakt sync, and playback in Blusion or Infuse.

Cinemeta, Stremio's official metadata addon, is installed once on first launch for catalogs, search, and title details.
It supplies **no streams**. You can disable or remove it in **Settings → Addons**; removal does not cause it to be installed again.
Blusion bundles no media or stream sources and operates no content server. Addon links are stored in the Keychain because they can contain tokens.

The current app has been built with Xcode and rendered locally through Mac Catalyst. This checkout has no installed iOS simulator runtime;
iPhone-sized Catalyst snapshots are layout checks, not iPhone or simulator testing. Final validation results are recorded in
[the Claude handoff](docs/CLAUDE_HANDOFF.md). The older milestone records in `STATE.md` remain historical.

## Build and run

Use a Mac with Xcode providing the iOS 26 SDK or newer, Swift 6, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
The app's deployment target is iOS 26.0. Node 18+ runs the mock addon; ffmpeg generates playback fixtures.

```bash
brew install xcodegen
cd ~/Blusion
xcodegen generate
open Blusion.xcodeproj
```

Select **Blusion → My Mac (Mac Catalyst)** and press **⌘R**. To test on an iPhone, choose a connected compatible device;
to use a simulator, first install its runtime in Xcode. Use your own Apple signing team; the tracked XcodeGen spec deliberately has no developer identity.
The generated Xcode project is ignored by Git. Keep personal team/device IDs outside tracked files.

For the existing advanced playback engine, generate the project with `./scripts/enable-fallback.sh`, then open
`Blusion.xcodeproj`. Xcode resolves the engine through Swift Package Manager and the scheme automatically applies
the pinned release's Swift 6 compiler compatibility fix before building.

To keep the Mac app in `/Applications`, run `scripts/install-mac.sh`: it builds a Release copy, replaces the installed one and
opens it. That is the only copy to open. A build product launched from `build/` becomes one more "Blusion" in Spotlight.
`scripts/install-iphone.sh` installs only on an explicitly selected iPhone. Supply your private `BLUSION_IPHONE_UDID` and
`BLUSION_DEVELOPMENT_TEAM` environment variables when running it; neither identifier is stored in this repository. With a free Apple ID,
run it again every seven days.

[First Mac run](docs/MAC_FIRST_RUN.md) gives the short testing path.

## Using the app

- **Home:** featured titles, Continue Watching, and catalog shelves. Use **Customize Home** or **Settings → Widgets** to add, edit,
  reorder, remove, import, or export rows. Fusion widget exports can be pasted as JSON or imported from a URL.
- **Search:** searches every supported content type across enabled searchable addons. Recent successful searches are kept locally;
  genre tiles let you browse before typing. Discover provides content-type, catalog, and genre filters.
- **Library:** saved titles, Continue Watching, and watched items. Long-press or right-click a poster for library and watched actions.
- **Pointer and keyboard:** cards and controls highlight on hover and keyboard focus. In Blusion's player, Space plays or pauses,
  Left/Right skips 10 seconds, and Esc closes. Reduce Motion keeps cards still.
- **Settings → Playback:** choose Blusion, Infuse, or Infuse only when Blusion cannot play a format. Automatic best-stream playback is optional.
  Infuse handoff includes the resume position and records progress when its callback returns.
- **Settings → Appearance:** toggle poster ratings. Posters show two available sources, preferring IMDb and movie Letterboxd scores,
  then TMDb. IMDb scores come from the offline ratings file below; TMDb needs its optional token.
  Titles with fewer than two available scores show only genuine scores. All configured sources are fetched and cached as you browse.
- **Title details:** small buttons under the title (a site's icon, then its score) open the title on IMDb, Letterboxd, Rotten Tomatoes,
  Metacritic or TMDb. IMDb is always there; the others appear once they have a score. **Settings → Review services** accepts an optional
  OMDb API key (episode IMDb scores only) and a TMDb API Read Access Token for TMDb ratings;
  select **Save Review Services**. Credentials are stored in the Keychain. The free OMDb key allows 1,000 lookups a day; if OMDb refuses the
  key or the quota runs out, Blusion stops asking for an hour.
  Saving credentials refreshes visible posters and episodes, including cached missing scores. **Refresh Ratings** or reopen the screen
  checks again while keeping existing scores visible. Title scores refresh weekly, episode seasons daily, and missing scores hourly;
  temporary failures leave cached scores available offline and can retry after a minute. OMDb errors appear under Review services.
- **Offline IMDb ratings:** Blusion keeps IMDb's own public ratings file (`title.ratings.tsv.gz`, about 9 MB, 1.7 million titles) on the
  device and reads IMDb scores and vote counts from it with no network and no key. At launch, and when the app comes back to the front,
  it checks whether the last check was over 24 hours ago; if so it asks datasets.imdbws.com for the file with `If-None-Match` and
  `If-Modified-Since`, so an unchanged file costs a 304 and no download. A new file is unpacked and indexed in the background into a SQLite
  database beside the current one, checked (gzip CRC and length, header, row count, no more than one bad line in a thousand, not 20% smaller
  than the copy in use), and only then renamed over it. Any failure keeps the old database and waits an hour before trying again.
  The data lives in Application Support, outside backups and iCloud; the scores it supplies replace the catalog's IMDb number on posters
  and title pages. **Settings → IMDb ratings** shows the title count and the date of the last update, and carries IMDb's credit line.
  IMDb allows this data for personal, non-commercial use only (https://developer.imdb.com/non-commercial-datasets/): Blusion never
  uploads, shares or redistributes it. Check those terms before putting a build of Blusion in anyone else's hands.
- **Episode ratings:** Blusion downloads IMDb's `title.episode.tsv.gz` on unmetered connections and builds a separate compact
  SQLite index of series/season/episode numbers to IMDb episode IDs. Its existing IMDb ratings table then supplies episode
  scores entirely offline; OMDb is not needed for seasons whose ratings are already locally available. The episode index is
  refreshed conditionally each day, with previous data retained when a download or import fails. Incomplete seasons can still
  fall back to optional OMDb season requests, then TMDb/addon scores.
- **Best Blu-ray edition:** pressing **Play** on a film automatically looks it up on
  [Best Blurays](https://www.bestblurays.com) while addons search for streams. The streams page shows the recommended release,
  video notes, 4K tier and anything upcoming, with a link to the full comparison. The lookup keeps its answer while the stream picker
  is open and does not delay playback; it makes at most four small requests to match the film's title, year and IMDb id.
- **Watched:** a movie or a whole show can be marked from its title page (a show marks every episode that has aired; clearing asks first).
  The season menu marks one season, and a poster's long-press menu marks a whole show.
- **Settings → Accounts → Trakt:** select **Connect**. The app uses its built-in public Client ID and PKCE sign-in with
  `blusion://trakt/callback`; no API configuration or Client Secret is needed.
  Connecting reads the watchlist (watch later) and collection into **Library → Saved**, and history into **Library → Watched**.
  After that, sync is two-way and automatic: saving or removing a title, marking or clearing a watched mark, and paused positions
  go to Trakt, and what changes on Trakt (from the other device or the web) comes back, removals included. That is also how the
  iPhone and the Mac stay in step. Changes made offline wait in a queue that survives a relaunch.
  Saved titles use the Trakt watchlist; the collection is only read, and removing a collected title here leaves the collection alone.
  A title removed here is not brought back by an older Trakt entry. **Import collection** reads everything again; **Sync** also sends
  the saved titles and watched items Trakt never had. Only IMDb movies, shows and episodes sync.
  Tokens and connection settings use the Keychain.

## Adding an addon

1. Get its manifest link, such as `https://example.com/path/manifest.json` or `stremio://example.com/path/manifest.json`.
2. Open the **Settings** tab → **Addons**, paste the link, and select **Install**. A `stremio://` install link can also open this field for you to review.
3. Enable, reorder, or remove addons on the same screen. Removing one also removes its saved link.

Catalog addons provide browsing and search; stream addons provide playback choices. Direct HTTP(S) media can play in Blusion.
Infuse can handle additional formats, including MKV and DTS. Streams needing request headers stay in Blusion because an external player
cannot receive those headers. Torrent streams require a compatible streaming server you run and configure in **Settings → Streaming server**.

## Local mock addon and verification

```bash
brew install node ffmpeg             # optional until you need mock playback fixtures
./Tools/MockAddon/make-fixtures.sh
node Tools/MockAddon/server.js
```

Install `http://127.0.0.1:7001/demo/manifest.json` for mock catalogs and `http://127.0.0.1:7002/demo/manifest.json` for mock streams
when the app runs on this Mac or a simulator. A physical phone needs the Mac's LAN address. Generated media is ignored by Git.

```bash
./scripts/verify.sh
./scripts/verify.sh milestone
```

Media-dependent tests are explicitly skipped when their generated fixtures are absent. When no iPhone simulator is installed,
verification reports skipped simulator tests and builds for generic iOS and Mac Catalyst instead. A milestone run still requires
simulator tests unless `ALLOW_HOST_ONLY=1` is explicitly supplied; that override retains the skipped-check summary.

```bash
scripts/snapshot.sh home build/shots/home.png
scripts/snapshot.sh home build/shots/home-mac.png --mac
```

The first command renders an iPhone-sized Catalyst layout; `--mac` uses the Mac layout. Neither is a simulator test.
Snapshot builds carry the bundle id `app.blusion.player.snapshot`, so a run never touches the installed app or its settings.

## Known limitations

- Device checks remain open for PiP, AirPlay, lock-screen controls, background playback, hardware decoding, local-network prompts,
  VoiceOver, and accessibility text sizes. See [the device checklist](docs/DEVICE_CHECKLIST.md).
- A real streaming-server route, the optional MPV fallback build, distribution signing, and App Store submission are not validated by local layout snapshots.
- Letterboxd lookup depends on its public page format and availability; missing ratings fall back to other available poster scores.
- Trakt sign-in/sync and optional OMDb/TMDb lookups have stub-based tests; live account checks require user credentials.
- External-player progress depends on the player returning a callback. A canceled or missing callback cannot supply a new position.
- SRT and WebVTT are supported by the built-in player; styled or bitmap subtitles need a player that supports them.
- Trakt sync runs while the app is open (on launch, when it comes to the front, after a change, and when the network returns), not in the background. Devices sync through Trakt, so both must be signed in to the same account. There is no tvOS target.
- Addon manifest URLs containing query strings are rejected. English is the only completed localization.

## Project layout

```text
App/                    app entry point, dependency wiring, privacy manifest, string catalogs, assets
Packages/StremioKit/     addon protocol, catalogs, streams, widgets, settings, ratings, cache contracts
Packages/PlayerKit/      playback engines, coordinator, subtitles, progress
Packages/Persistence/   SwiftData and Keychain stores
Packages/Features/      view models and SwiftUI screens
Packages/FallbackPlayer/ optional MPV backend
Tools/MockAddon/        local addon server and fixture generator
scripts/                verification, project generation checks, snapshots, archives, lint
```

The fallback backend is opt-in through `scripts/enable-fallback.sh`; its licensing and release checks are in
[docs/licenses.md](docs/licenses.md). See [the handoff](docs/CLAUDE_HANDOFF.md) for every original agent brief,
[STATE.md](STATE.md) for historical milestones, and [docs/RELEASE.md](docs/RELEASE.md) for distribution work.
