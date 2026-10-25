# Blusion

Blusion is an iOS and Mac media browser and player built around Stremio-addons and highly customisable widgets.

## Build

Requires a Mac, Xcode with the iOS 26 SDK or newer, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open Blusion.xcodeproj
```

Make sure to sign into Xcode developer team thing. 

For advanced playback, generate the project with `./scripts/enable-fallback.sh` before opening Xcode. The existing engine package and its Swift 6 compatibility fix are handled automatically.

## Trakt

Has it.

## Notes

under constant dev.
