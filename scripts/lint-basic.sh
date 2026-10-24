#!/usr/bin/env bash
# Host-side stand-in for the SwiftLint rules enabled in .swiftlint.yml that are cheap to check without SwiftLint:
# trailing whitespace, more than one blank line in a row, missing or extra trailing newline, trailing semicolons, tabs.
# Used by verify.sh only when `swiftlint` is not installed (e.g. the Linux agent host). macOS CI runs real SwiftLint.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
status=0
TAB="$(printf '\t')"   # BSD grep (macOS) has no -P, so match a literal tab
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  if grep -nE '[[:space:]]+$' "$f" >/dev/null; then echo "$f: trailing whitespace: $(grep -nE '[[:space:]]+$' "$f" | head -3 | cut -d: -f1 | tr '\n' ' ')"; status=1; fi
  if grep -n "$TAB" "$f" >/dev/null; then echo "$f: tab character"; status=1; fi
  if [[ -s "$f" ]]; then
    if [[ "$(tail -c1 "$f" | wc -l)" -eq 0 ]]; then echo "$f: missing trailing newline"; status=1; fi
    if [[ "$(tail -c2 "$f" | wc -l)" -ge 2 ]]; then echo "$f: more than one trailing newline"; status=1; fi
  fi
  if awk 'BEGIN{b=0} /^[[:space:]]*$/{b++; if(b>1){print FILENAME": consecutive blank lines at "NR; exit 1}} !/^[[:space:]]*$/{b=0}' "$f"; then :; else status=1; fi
  if grep -nE ';[[:space:]]*$' "$f" | grep -vE '^\s*[0-9]+:\s*//' >/dev/null; then echo "$f: trailing semicolon: $(grep -nE ';[[:space:]]*$' "$f" | head -3 | cut -d: -f1 | tr '\n' ' ')"; status=1; fi
done < <(git ls-files -co --exclude-standard -- '*.swift' | grep -v '/Fixtures/')
exit $status
