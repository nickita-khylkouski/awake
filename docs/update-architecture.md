# Update Architecture

`awake` now ships a complete npm-driven update path for the current distribution model:

- background update checks against the published `awake-agent` npm package
- an in-app `Update available` banner for self-updatable installs
- one-click self-update for `npx` and `npm -g` installs
- explicit fallback messaging for repo installs and local copies

This document records what is implemented today, why Sparkle is not the default yet, and what would need to change before a native macOS auto-update system becomes the right next step.

## Current shipped model

The source of truth for shipping is the npm package plus GitHub source/release artifacts.

### Implemented now

- CLI status surface:
  - `awake version`
  - `awake update status --json`
  - `awake update apply`
  - `awake update clear-cache`
- Install-source detection:
  - `npx`
  - `npm-global`
  - `repo`
  - `local-copy`
- Cached npm latest-version lookup with offline/stale-cache handling
- SwiftUI update banner and Settings update card
- One-click self-update for:
  - `npx --yes awake-agent@latest install`
  - `npm install -g awake-agent@latest` followed by `awake install`
- Relaunch after successful update
- Self-contained installed app bundle so the installed `.app` can rebuild/reinstall from bundled sources and metadata

### Why this is the right default today

`awake` is not distributed primarily as a signed standalone `.app` with a native updater feed. It is currently:

- a CLI package published to npm
- a repo-driven source install
- a generated local macOS `.app` built from shipped Swift source

That means the fastest reliable update path is still package-manager driven, with the app acting as a control surface for the updater instead of pretending the `.app` is the canonical artifact.

## Why Sparkle is not implemented yet

Sparkle is a good fit when the app bundle itself is the primary release artifact and release engineering already supports:

- versioned app archives
- stable appcast feeds
- proper signing and notarization
- predictable update channels
- native macOS-first distribution expectations

`awake` is not there yet.

### Current blockers

1. Distribution is mixed

- npm is the main install/update channel for many users
- repo/source installs are still first-class
- the installed app is generated locally during `awake install`

2. Release engineering is not Sparkle-ready

- no signed Sparkle appcast pipeline
- no notarized Developer ID release flow wired into shipping
- no separate strategy for updating bundled CLI/helper scripts vs the `.app`

3. Product complexity would jump before user value requires it

- Sparkle would solve native app updates
- but `awake` still has CLI/helper/runtime pieces that need to stay in sync
- app-assisted npm update already covers most user needs with much less release complexity

## Recommended path

Stay on the current shipped model until these conditions change:

1. Most installs come from `.app` downloads rather than npm
2. The `.app` becomes the canonical artifact instead of a locally built result
3. Release signing/notarization are automated and stable
4. Helper/runtime updates are either bundled safely inside the app or split into a supported companion update path

Until then, npm-backed updating is the right operational model.

## What Sparkle adoption would require later

If `awake` graduates to Sparkle, the implementation should be treated as a release-engineering project, not a UI polish task.

### Required deliverables

- Signed and notarized release archives for each macOS build
- A stable appcast feed
- Embedded Sparkle framework in the app build
- Versioned release artifacts on GitHub Releases
- Clear ownership of:
  - app bundle update
  - helper script update
  - CLI/runtime compatibility

### Required product decisions

- Is the installed `.app` the primary artifact?
- Are npm installs still supported?
- If yes, do npm installs continue to use npm updates while release installs use Sparkle?
- If no, is npm demoted to developer-only usage?

### Required verification

- Update from version N to N+1 on another Mac
- Relaunch after update
- Settings persistence
- Runtime compatibility for bundled helper scripts
- Notarization / Gatekeeper validation
- Failure-path handling:
  - interrupted download
  - failed signature validation
  - rollback or failed relaunch

## Validation matrix for the current shipped updater

Before each release, validate:

- `npm run verify:shell`
- `bash tests/test_updates.sh`
- `bash tests/test_install_flow.sh`
- `bash tests/test_build_ui.sh`
- `swiftc -typecheck ui/main.swift`
- temp-prefix npm install validation
- one manual second-machine check of:
  - update banner
  - `Update now`
  - app relaunch
  - settings persistence

## Summary

Sparkle is deferred intentionally.

The current updater is complete for the way `awake` is actually distributed today:

- npm-backed
- app-assisted
- self-updating for package installs
- explicit/manual for repo installs

When distribution shifts toward a signed standalone app as the primary product surface, Sparkle becomes worth revisiting.
