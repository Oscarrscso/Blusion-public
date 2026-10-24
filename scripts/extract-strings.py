#!/usr/bin/env python3
"""Seeds App/Localizable.xcstrings from the plain string literals in the SwiftUI views (String Catalog scaffolding, PLAN M8).

Xcode extracts strings from the app target on its own, but the views live in the Features package, so this script collects the
literals passed to Text, Label, Button, Section, Toggle, Picker, TextField, navigationTitle, accessibility modifiers and friends.
Existing entries and translations are never overwritten. Literals with interpolation (`\\(x)`) are listed, not written:
their catalog keys depend on argument types (%@, %lld) and are best added from Xcode's catalog editor.

  python3 scripts/extract-strings.py            # add missing entries
  python3 scripts/extract-strings.py --check    # exit 1 if a literal is missing from the catalog
"""
import json
import os
import re
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
catalog_path = os.path.join(root, "App", "Localizable.xcstrings")
views = os.path.join(root, "Packages", "Features", "Sources", "Features", "Views")
CALLS = (r'\b(?:Text|Label|Button|Section|Toggle|Picker|TextField|LabeledContent|NavigationLink|Link|ContentUnavailableView|ProgressView|tabItem'
         r'|navigationTitle|accessibilityLabel|accessibilityHint|accessibilityValue|confirmationDialog|alert|searchable\(text: [^,]+, prompt)'
         r'\(\s*')
pattern = re.compile(CALLS + r'"(?!"")((?:[^"\\]|\\.)*)"')
# Long literals are written as multi-line strings joined with trailing backslashes (SwiftLint line_length). Swift joins them the
# same way, so the catalog key is the joined text.
multiline = re.compile(CALLS + r'"""[ \t]*\n(.*?)\n([ \t]*)"""', re.S)


def joined(body, closing_indent):
    out = []
    for line in body.split("\n"):
        line = line[len(closing_indent):] if line.startswith(closing_indent) else line.lstrip()
        out.append(line[:-1] if line.endswith("\\") else line + "\n")
    return "".join(out).rstrip("\n")


found, interpolated = set(), set()
for dirpath, _, names in os.walk(views):
    for name in sorted(names):
        if not name.endswith(".swift"):
            continue
        source = open(os.path.join(dirpath, name), encoding="utf-8").read()
        literals = pattern.findall(source) + [joined(body, indent) for body, indent in multiline.findall(source)]
        for literal in literals:
            (interpolated if "\\(" in literal else found).add(literal)

catalog = {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
if os.path.isfile(catalog_path):
    catalog = json.load(open(catalog_path, encoding="utf-8"))
known = catalog.setdefault("strings", {})
missing = sorted(found - set(known))

if "--check" in sys.argv:
    for literal in missing:
        print("missing from Localizable.xcstrings:", literal)
    sys.exit(1 if missing else 0)

for literal in missing:
    known[literal] = {"extractionState": "manual", "localizations": {"en": {"stringUnit": {"state": "translated", "value": literal}}}}
with open(catalog_path, "w", encoding="utf-8") as handle:
    json.dump(catalog, handle, indent=2, ensure_ascii=False, sort_keys=True)
    handle.write("\n")
print(f"{len(missing)} strings added, {len(known)} in the catalog, {len(interpolated)} interpolated literals left to Xcode")
