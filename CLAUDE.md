# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout — read this first

`main` contains **documentation only**. All code lives on branches checked out as
git worktrees under `.worktrees/` (git-ignored). Run `git worktree list` before
doing anything.

- `.worktrees/dynamic-island-parity` (branch `dynamic-island-parity`) — the
  **active implementation**: a macOS 15+ utility with functional/performance
  parity with MIT-licensed Cyclop 0.6.5 (pinned upstream commit
  `7ab60c8198681ea6c895fa55458448efb6e4c36e`). Pure SwiftPM
  (`Sources/DynamicIsland`, `Sources/DynamicIslandKit`,
  `Sources/DynamicIslandMediaHelper`, `Tests/DynamicIslandKitTests`) plus
  `Scripts/*.sh` release gates.
- `.worktrees/shell-music-mvp` (branch `shell-music-mvp`) — the earlier
  shell + Music prototype (XcodeGen project + `Packages/IslandCore` package).
  Kept as historical work per the approved parity design; do not extend it
  unless asked.

Each worktree has its own `checklist.md` and `docs/`; the root-level docs on
`main` describe the shell-music-mvp effort.

## Source-of-truth policy

Binding documents win over status/tracking documents. When behavior changes,
update the spec/design first, then checklist and code in the same change.

- shell-music-mvp: `docs/specs/shell-music-mvp.md` is the binding contract;
  `checklist.md` tracks delivery; `docs/runbook.md` has exact commands;
  `docs/research/technical-feasibility.md` is non-binding evidence.
- dynamic-island-parity: `docs/plans/2026-08-18-dynamic-island-parity-design.md`
  (approved) is the behavior and performance contract; the worktree's own
  `docs/runbook.md` and `docs/release-checklist.md` are the execution path.

## Commands

### dynamic-island-parity worktree

```bash
swift test                          # unit tests
swift test --filter <TestName>      # single test
bash Scripts/bundle.sh release      # build ad-hoc-signed app into build/
open "build/Dynamic Island.app"
```

Full release-candidate gate order (see worktree runbook):
`swift test` → `Scripts/test-provenance.sh` → `Scripts/test-branding.sh` →
`Scripts/test-localizations.sh` → `Scripts/bundle.sh release` →
`Scripts/test-helper.sh` → `Scripts/test-package.sh` → `Scripts/dmg.sh` →
`Scripts/test-lifecycle.sh`.

### shell-music-mvp worktree

```bash
swift test --package-path Packages/IslandCore
swift test --package-path Packages/IslandCore --filter <TestName>
xcodebuild -project DynamicIsland.xcodeproj -scheme DynamicIsland \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
```

XcodeGen (`xcodegen generate`) is needed only after editing `project.yml`;
review the resulting `project.pbxproj` diff. Kill a stale app instance with
`pkill -x DynamicIsland`.

## Architecture

A notch-anchored island: a borderless, non-activating `NSPanel`
(`level = .mainMenu + 3`; `.fullScreenAuxiliary`/`.stationary`/
`.canJoinAllSpaces`/`.ignoresCycle`) hosts SwiftUI content. AppKit owns panel
lifecycle and display observation; SwiftUI owns visible content. The app is an
accessory (`LSUIElement`) — no Dock icon; About/Quit live in a status item. The
panel must never become key/main, so never use `NSScreen.main` to pick the
target display; recompute geometry on
`NSApplication.didChangeScreenParametersNotification`.

Notch detection: `safeAreaInsets.top > 0`, exact bounds from
`auxiliaryTopLeftArea`/`auxiliaryTopRightArea`, fallback 185 × 32 pt centered
rectangle. The two branches diverge on unnotched displays: shell-music-mvp
must never draw a simulated island (binding decision D7); the parity app draws
a centered synthetic notch.

Feature modules conform to `IslandModule` (id, priority, activity publisher,
compact/expanded views); `ModuleRegistry` picks the highest-priority active
module.

Music data path: MediaRemote is a private framework whose read path is blocked
for normal processes, so the app spawns the vendored
`ungive/mediaremote-adapter` Perl bridge
(`/usr/bin/perl mediaremote-adapter.pl … stream`) and parses its NDJSON output
(`NDJSONLineBuffer` preserves partial lines; all `NowPlayingInfo` fields are
optional). Transport commands use the same bridge in `send` mode. The Swift app
never links MediaRemote directly. Because of this private-framework dependency,
distribution is a signed + notarized direct-download DMG, never the App Store.

Error-handling contract: adapter failure, malformed JSON, or missing resources
must never crash the app or show a permission prompt (no user-grantable
MediaRemote permission exists) — Music just deactivates and the island
collapses.

## Hard constraints

- Vendored `mediaremote-adapter` is pinned (commit
  `3ac3d4bdf862c7b5399b4fba4df5689f5c38609a`) and unmodified; its BSD-3-Clause
  license must ship in every binary. The parity branch likewise keeps Cyclop's
  MIT attribution in `THIRD_PARTY_NOTICES.md` while all product identity
  (name, icon, copy) must stay original.
- Signing identities, Apple credentials, and notarization inputs are
  release-owner inputs — never commit them.
- A green build does not equal done: the checklists require manual validation
  on physical notch hardware; record tested Mac model and macOS version in the
  relevant `checklist.md` after validation runs.
- Binding decision IDs (D1–D8 in root `checklist.md`) are referenced from
  implementation comments — do not renumber them.
