# Blusion agent instructions

Swift 6 / SwiftUI app for iPhone, iPad and Mac Catalyst. `project.yml` is the XcodeGen source of truth.

## Context and efficiency
- Stay within the request. Use narrow searches and read only relevant files/sections; avoid repo-wide scans, full logs and repeated context dumps.
- Prefer small changes using existing components. No unrelated refactors, new dependencies, speculative features, extra documentation or subagents for simple work.
- Read only relevant sections of `docs/DESIGN_SPEC.md` for UI and `docs/PLAYER.md` for playback.
- Answer concisely: changed behaviour/files, commit, and any blocker. No long diffs unless requested.

## Git and verification
- Change/fix requests authorize editing, committing and pushing to `main`; questions and examples do not.
- In a local checkout, run `git pull --ff-only origin main` before editing; preserve local changes and report conflicts.
- Stay on `main`. No branches, worktrees, PRs, merges, destructive resets or force pushes. Push fast-forward only.
- The user tests. Do not run builds, tests, verification or installations unless explicitly requested.

## Project rules
- After a local pull or code change, generate the player-enabled Xcode project using `scripts/enable-fallback.sh`, not plain `xcodegen generate`.
- Use native controls/APIs for standard UI. Avoid explanatory UI help text, footers and captions.
- Keep Mac and iPhone features in parity or explain platform-specific exceptions.
- Follow `docs/DESIGN_SPEC.md` where relevant; use `Theme.playControlColour(hex:)` for Play-derived colours.

## Privacy
- Never commit `.env`, API keys, private addon URLs, generated secrets, personal device IDs or private configuration. Do not copy sensitive values from the private repo.
