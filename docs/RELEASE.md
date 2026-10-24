# Release: signing and shipping (steps for the human)

An agent cannot do these: they need your Apple account, certificates and App Store Connect. Everything before this page is automated
(`./scripts/verify.sh milestone` ends with an unsigned `xcodebuild archive`). Nothing here is sent anywhere until you do it.

## 0. Decide first (PLAN §9)

- **Distribution route:** personal device build (free account, 7-day signing), TestFlight, or App Store. This sets how much of `docs/APP_REVIEW_NOTES.md` matters.
- **Fallback player:** ship it or not. It is off by default; shipping needs the sign-offs in `docs/licenses.md`.
- **Your own licence** for Blusion's code (none chosen; `docs/licenses.md`).

## 1. Identity (one-time)

1. Pick a bundle id you own. The placeholder is `app.blusion.player` (`project.yml`: `PRODUCT_BUNDLE_IDENTIFIER`; the test targets append `.tests`, `.uitests`).
   Keep the "no third-party marks in the name or id" rule.
2. Keep your Apple Developer Team ID out of version control. Set `BLUSION_DEVELOPMENT_TEAM` in your local shell (or choose a team in the generated Xcode project). Leave `CODE_SIGN_STYLE: Automatic` unless you manage profiles by hand.
3. Regenerate and open: `xcodegen generate && open Blusion.xcodeproj`. Sign in under Xcode *Settings > Accounts* and select your team under *Signing & Capabilities* if building from Xcode. Regenerating the project resets that local choice; command-line builds can instead pass `DEVELOPMENT_TEAM="$BLUSION_DEVELOPMENT_TEAM"`.
4. Bump `MARKETING_VERSION` (user-visible) and `CURRENT_PROJECT_VERSION` (must increase on every upload) in `project.yml`.

## 2. Build a signed archive

Xcode: *Product > Archive*, then *Distribute App*. Or from the shell:

```bash
xcodegen generate
xcodebuild archive -project Blusion.xcodeproj -scheme Blusion -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Blusion.xcarchive -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$BLUSION_DEVELOPMENT_TEAM"
```

Export and upload with an `ExportOptions.plist` like this (`method` is `app-store-connect` for TestFlight and the App Store):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>ABCDE12345</string>
  <key>destination</key><string>upload</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
```

```bash
xcodebuild -exportArchive -archivePath build/Blusion.xcarchive -exportOptionsPlist ExportOptions.plist -exportPath build/export -allowProvisioningUpdates
```

(With `destination` set to `export` you get an `.ipa` to upload through the Transporter app instead.)

## 3. App Store Connect (website, by hand)

- Create the app record with the same bundle id. Name, subtitle and description must not use third-party marks.
- Answer **App Privacy** and **Age rating** consciously: `docs/APP_REVIEW_NOTES.md` explains why.
- Screenshots from `scripts/screenshots.sh`; support URL; privacy policy URL.
- Paste the reviewer notes and add the demo addon URL you host.
- Add the build once processing finishes, send to TestFlight first.

## 4. Before pressing submit

- [ ] `./scripts/verify.sh milestone` green on a Mac, on the commit you archive
- [ ] `docs/DEVICE_CHECKLIST.md` ticked on a real iPhone (and iPad if you ship the iPad layout)
- [ ] `docs/licenses.md` sign-off table filled in; Acknowledgements screen matches what is linked
- [ ] Privacy manifest and App Privacy answers still true
- [ ] Version and build numbers bumped; release notes written

## Troubleshooting

- *No profiles for "app.blusion.player"*: the bundle id is taken or not yet registered; change it (step 1) rather than fighting the profile.
- *Archive succeeds unsigned but not signed*: open the project in Xcode once, pick your team under *Signing & Capabilities*, and read the first red message.
- *Upload rejects the icon*: `AppIcon-1024.png` must be opaque 1024×1024 (`scripts/check-project-spec.py` checks this).
