# Blusion

Blusion is an iOS and Mac Catalyst media browser and player built with SwiftUI. It supports Stremio-compatible addons, search, a personal library, Continue Watching, subtitles, and optional Trakt integration.

Blusion does not bundle media, streaming sources, or a content server. Users configure their own addons and services.

## Build

Requires a Mac, Xcode with the iOS 26 SDK or newer, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open Blusion.xcodeproj
```

Choose your own Apple development team in Xcode before building for a device. No developer identity is included in this repository.

## Trakt

To use Trakt, create your own Trakt API application and enter its client ID under **Settings → Trakt**. Register `blusion://trakt/callback` as its redirect URI. No Trakt credentials are bundled.

## Notes

This project is under development. See [docs/licenses.md](docs/licenses.md) for third-party licensing and distribution considerations. Publishing the source code is not the same as distributing a finished app.

No open-source license has been selected for Blusion's original code yet.
