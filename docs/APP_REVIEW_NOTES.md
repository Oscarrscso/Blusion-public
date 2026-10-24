# App Review notes

Draft submission material. Distribution, signing, licensing, privacy answers, and reviewer access still need the owner's review;
local builds and screenshots do not establish App Store acceptance.

## Draft notes for the reviewer

> Blusion is a media browser and player for Stremio-protocol addons. It bundles no media or stream sources and operates no content server.
> On first launch it installs Cinemeta, Stremio's official metadata addon, for catalogs, search, and title details; Cinemeta provides no playback streams.
> The user can disable or remove it in Settings → Addons. Users install additional addons by manifest URL.
>
> For playback review, open the Settings tab → Addons and install `<DEMO ADDON URL supplied by the owner>`.
> The demo addon should provide media the developer has permission to distribute. Home, Discover, Search, title details, stream selection,
> and playback can then be reviewed. Library and Home customization under Settings → Widgets are available without a stream source.
>
> Playback can use Blusion or Infuse, selected in Settings → Playback. Infuse is an external app; Blusion can hand over a stream and receive
> its playback position through a callback. Poster ratings can be disabled in Settings → Appearance. Title pages link to IMDb,
> Letterboxd, Rotten Tomatoes, Metacritic, and TMDb using their icons; unmatched titles open a labeled site search.
>
> Optional Trakt authorization is under Settings → Accounts → Trakt. Users register an API app with Redirect URI `urn:ietf:wg:oauth:2.0:oob`,
> supply its Client ID and Client Secret, and authorize a device code in their browser. Import from Trakt and Send to Trakt add missing watchlist and watched-history items;
> they do not delete items or sync playback positions. Optional review API credentials are under Settings → Review services.

The reviewer demo URL is not supplied by this repository. `Tools/MockAddon` demonstrates the protocol and can serve generated test media
or media the owner is authorized to make available. A public review endpoint needs separate hosting and access checks.

## Current implementation facts to review before submission

| Area | Current behavior |
|---|---|
| Sources | Cinemeta is installed once for metadata; no stream addon or media file is bundled. |
| Network | Enabled addons supply catalogs, metadata, streams, and subtitles. Letterboxd ratings use public pages; once a day the app downloads IMDb's public ratings file (datasets.imdbws.com, personal and non-commercial use, credited in Settings) and reads it offline; an optional TMDb credential enables TMDb scores and episode ratings. Review icons open external sites. Configured Trakt widgets and manual account sync contact Trakt. |
| Local storage | Addon links, streaming-server address, Trakt API credentials/tokens, TMDb API Read Access Token use the Keychain. Library, progress, widget layouts, recent searches, and caches stay on the device; users can manually share saved titles and watched marks with Trakt. |
| Account sync | Device-code Trakt sign-in; manual import/export of selected watchlist and watched movie/episode data with IMDb IDs. Sync only adds missing items. Playback positions and removals are not transferred. |
| External playback | The app registers `blusion://` callback URLs, accepts addon install links through `stremio://`, and checks the `infuse` scheme. |
| Privacy | There is no app-operated analytics or account service. Review `App/PrivacyInfo.xcprivacy` and every external service used when completing submission answers. |
| Media features | PiP, AirPlay, background audio, local-network access, and lock-screen controls need the real-device checklist. |
| Interaction | Custom cards and controls provide pointer highlights and keyboard focus feedback. The built-in player supports Space, Left/Right, and Esc; Reduce Motion disables card movement. |
| Optional fallback | MPVKit is excluded from the default build. Including it requires the release and licensing checks in `docs/licenses.md`. |

The old statement that the first launch is empty with no catalogs or addons is no longer accurate.
Submission descriptions and screenshots must disclose the default metadata addon and match the actual shipped build.
Trakt account flows and optional review APIs have stub-based tests; live account checks still need user credentials.

## Remaining submission work

- Complete signing, App Store Connect setup, support/privacy URLs, and accurate content/privacy questionnaires.
- Supply and verify reviewer playback access using authorized media.
- Produce release screenshots from the intended devices; Catalyst layout snapshots are development evidence only.
- Complete [DEVICE_CHECKLIST.md](DEVICE_CHECKLIST.md) and [RELEASE.md](RELEASE.md).
- Revisit these notes if default sources, network services, storage, tracking, accounts, or the optional fallback build change.
