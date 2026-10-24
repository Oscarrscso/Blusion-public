# Localization

English is the only shipped language. The scaffolding for more is in place:

- `App/Localizable.xcstrings`: every plain string literal passed to a SwiftUI view in `Packages/Features/Sources/Features/Views`
  (89 at the time of writing). `python3 scripts/extract-strings.py` adds new ones without touching existing translations, and `verify.sh`
  fails if a literal is missing from the catalog (`--check`).
- `App/InfoPlist.xcstrings`: the app name and the local-network permission text shown by iOS. `scripts/check-project-spec.py` keeps the English values equal to `project.yml`.
- `project.yml` sets `SWIFT_EMIT_LOC_STRINGS` and `LOCALIZATION_PREFERS_STRING_CATALOGS`.

## Adding a language

1. Open `App/Localizable.xcstrings` in Xcode, click **+** at the bottom of the language list, choose the language, translate.
2. Do the same in `App/InfoPlist.xcstrings` (the permission text matters most).
3. Strings with interpolation (`"\(count) of \(total)"`) are *not* seeded by the script, because their catalog keys depend on argument types
   (`%lld`, `%@`). Xcode's catalog editor creates those the first time the app target is built; translate them there.

## Why the catalog is in the app target, not the Features package

SwiftUI looks `Text("...")` literals up in the *main* bundle unless a view passes `bundle: .module`. Keeping one catalog in the app target
means the package views need no code changes to become translatable.

## Not localized yet

Addon-supplied text (titles, descriptions, error text from addons) is shown as the addon sent it. Error strings produced by `StremioKit`
(`AddonError.shortDescription`) are English in the package: moving them behind `String(localized:)` is the next step if a second language ships.
