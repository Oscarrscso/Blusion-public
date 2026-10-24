# First run on a Mac

The project now builds with Xcode for Mac Catalyst; its deployment target is iOS 26.0.
The original Linux-only build notes are historical. This Mac currently has no iOS simulator runtime, so local Catalyst screenshots
and package tests do not establish iPhone or simulator playback results.

## Run the current app

```bash
cd ~/Blusion
brew install xcodegen
xcodegen generate
open Blusion.xcodeproj
```

Select **Blusion → My Mac (Mac Catalyst)** and press **⌘R**. Review the development team and bundle ID in `project.yml` before using your own device.
For a simulator, install a compatible runtime through Xcode and select an iPhone destination.

To use the app outside Xcode, run `scripts/install-mac.sh`. It puts a Release build in `/Applications/Blusion.app` and is the way
to update it; do not copy a build product there by hand or open one from `build/`.

Cinemeta is seeded once for browsing and search. To test real playback, install your stream addon in **Settings → Addons** (the Settings tab).
Choose the preferred player in **Settings → Playback**. Infuse must be installed if you select it.

Cards and controls highlight under the pointer and keyboard focus. In Blusion's player, use Space to play/pause,
Left/Right to skip 10 seconds, and Esc to close. Reduce Motion disables card movement.

## Quick manual check

1. Open Home, search for a known title, and open its detail page.
2. Save the title, check it appears in Library, and try the poster context menu.
3. Open **Settings → Widgets**, edit a Home row, return Home, and check the change.
4. Open the small rating buttons under a title's name (IMDb, and Letterboxd, Rotten Tomatoes, Metacritic and TMDb once they have a score).
   Optional scores use an OMDb API key and TMDb API Read Access Token saved in **Settings → Review services**. With an OMDb key, open a
   series and check that its episodes show IMDb scores, and that posters without a catalog rating gain one. Mark a show watched from its
   title page and check every episode follows.
5. Open **Settings → Accounts → Trakt**, select **Connect**, and authorize in the browser.
   Use **Import collection** to import later changes, or **Sync** to send local saved and watched items before importing.
   This manual sync adds missing saved titles and watched movies/episodes with IMDb IDs; it never deletes items and keeps playback positions local.
6. Check player selection, automatic playback, and poster ratings in Settings. With a stream addon, play, return, and check Continue Watching.
   For Infuse, also check the callback updates progress.

Trakt credentials, sign-in tokens, and review API credentials stay in the Keychain. Account sync and optional review lookups
have stub-based tests; live checks need your credentials.

## Local mock playback

```bash
brew install node ffmpeg
./Tools/MockAddon/make-fixtures.sh
node Tools/MockAddon/server.js
```

On the Mac or simulator, install `http://127.0.0.1:7001/demo/manifest.json` for catalogs and
`http://127.0.0.1:7002/demo/manifest.json` for streams. A phone needs the Mac's LAN address.
Generated media is ignored by Git. Without it, media-dependent tests skip with an explanation.

## Verification commands

```bash
./scripts/verify.sh
./scripts/verify.sh milestone
scripts/snapshot.sh home build/shots/home.png
scripts/snapshot.sh home build/shots/home-mac.png --mac
```

When no iPhone simulator exists, `verify.sh` reports skipped simulator tests and builds generic iOS and Mac Catalyst instead.
`milestone` rejects that incomplete gate unless `ALLOW_HOST_ONLY=1` is supplied explicitly. The override does not turn skipped checks into completed checks.
Snapshot output is rendered through Catalyst; its phone-sized mode is a layout stand-in.

Final counts and build results belong in [CLAUDE_HANDOFF.md](CLAUDE_HANDOFF.md).
Real-device checks remain in [DEVICE_CHECKLIST.md](DEVICE_CHECKLIST.md); the streaming-server route and optional fallback player also need separate validation.
