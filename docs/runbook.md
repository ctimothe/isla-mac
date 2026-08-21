---
title: Development and Release Runbook
description: Reproducible commands and validation gates for the Dynamic Island MVP.
lastModified: 2026-08-18
---

# Development and Release Runbook

> **This runbook covers the historical `shell-music-mvp` prototype only.**
> The active implementation is the `dynamic-island-parity` branch, whose own
> runbook lives at `.worktrees/dynamic-island-parity/docs/runbook.md`. That one
> targets macOS 15 and builds with SwiftPM plus `Scripts/bundle.sh`; none of
> the commands below apply to it.

## 1. Locate the implementation

The prototype this document describes lives on the `shell-music-mvp` branch. List local
worktrees before running commands:

```bash
git worktree list
```

In the current checkout, enter it with:

```bash
cd .worktrees/shell-music-mvp
```

After the branch is integrated, run the remaining commands from the repository
root instead.

## 2. Toolchain

The documented flow was last verified with:

- Xcode 26.6 (build 17F113).
- Apple Swift 6.3.3.
- macOS SDK 26.5.
- XcodeGen available at `/opt/homebrew/bin/xcodegen`.

The prototype's deployment target is macOS 14.0. (The active parity
implementation targets macOS 15.0 — see its own runbook.) XcodeGen is needed only after
editing `project.yml`; ordinary builds use the committed Xcode project.

Inspect the local toolchain with:

```bash
xcodebuild -version
swift --version
command -v xcodegen
```

## 3. Verify source state

Before changing or validating the implementation:

```bash
git status --short --branch
git diff --check
```

Do not discard unrelated or uncommitted work. If `project.yml` changes,
regenerate and review the project diff:

```bash
xcodegen generate
git diff -- DynamicIsland.xcodeproj/project.pbxproj
```

## 4. Run automated checks

Run the core test suite:

```bash
swift test --package-path Packages/IslandCore
```

Expected baseline on 2026-08-18: 18 tests in six suites pass.

Build an unsigned Debug application into a predictable local directory:

```bash
xcodebuild \
  -project DynamicIsland.xcodeproj \
  -scheme DynamicIsland \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Expected result: `** BUILD SUCCEEDED **`. Two run-script phases currently warn
that they declare no outputs. The unsigned verification build also notes that
Hardened Runtime is disabled; that note is expected only because
`CODE_SIGNING_ALLOWED=NO` is explicit. Record any additional warning as a new
checklist item.

Inspect the bundled adapter resources:

```bash
test -d .build/xcode/Build/Products/Debug/DynamicIsland.app/Contents/Resources/mediaremote-adapter/MediaRemoteAdapter.framework
test -f .build/xcode/Build/Products/Debug/DynamicIsland.app/Contents/Resources/mediaremote-adapter/mediaremote-adapter.pl
test -f .build/xcode/Build/Products/Debug/DynamicIsland.app/Contents/Resources/mediaremote-adapter/LICENSE
```

Each command must exit with status 0.

## 5. Launch a local Debug build

Unsigned builds are suitable for local development only:

```bash
open .build/xcode/Build/Products/Debug/DynamicIsland.app
```

Quit through the status-menu item before rebuilding or relaunching. If a stale
instance remains:

```bash
pkill -x DynamicIsland
```

## 6. Manual hardware matrix

Record the Mac model and macOS version beside each result in
[`../checklist.md`](../checklist.md).

- [ ] Launch with the built-in notched display active; one island appears and
  is centered on the physical notch.
- [ ] Hover for less than 150 ms; the island does not expand.
- [ ] Continue hovering; the expanded content appears without clipping.
- [ ] Move the pointer away; the island collapses after about 2.5 seconds.
- [ ] Click while expanded; the island remains pinned after the pointer leaves.
- [ ] Click again; the island unpins and returns to compact behavior.
- [ ] Switch Spaces; the panel remains correctly placed and does not enter
  normal window cycling.
- [ ] Enter and leave fullscreen with another app; verify visibility and focus
  behavior.
- [ ] Disconnect, close, or otherwise deactivate the built-in display; no fake
  island appears on an unnotched display and the unsupported state remains
  discoverable from the status menu.
- [ ] Reactivate the built-in display; the island returns at the correct frame.
- [ ] If Ice, Bartender, iBar, or another menu-bar utility is installed, repeat
  pointer and fullscreen checks and record conflicts.
- [ ] Choose About and Quit from the status menu; both actions work without a
  Dock icon.

## 7. Manual Music matrix

- [ ] Start a track in Apple Music; compact mode shows its title.
- [ ] Pause the track; Music remains active and shows a paused state.
- [ ] Resume, skip forward, and skip backward from expanded controls.
- [ ] Verify title, artist, and album update after a track change.
- [ ] Repeat observation and controls with at least one third-party player.
- [ ] Stop playback and clear the player's queue; Music becomes inactive and
  the shell collapses.
- [ ] Terminate the adapter subprocess or temporarily remove its bundled
  resources in a disposable build; the app remains alive and Music deactivates.
- [ ] Restore the normal build before continuing. No MediaRemote permission
  prompt should have appeared.

## 8. Archive and distribution gates

Do not distribute the unsigned Debug product. For a release candidate:

1. Configure Developer ID Application signing without enabling App Sandbox.
2. Archive the `DynamicIsland` scheme in Release configuration.
3. Verify the app and nested adapter framework signatures with
   `codesign --verify --deep --strict --verbose=2`.
4. Confirm the adapter framework, Perl script, and BSD-3-Clause license are in
   the archived app's `Contents/Resources/mediaremote-adapter` directory.
5. Package the signed app in a DMG.
6. Submit the DMG with `xcrun notarytool`, wait for an accepted result, and
   staple the ticket with `xcrun stapler`.
7. Run `spctl --assess --type open --context context:primary-signature` against
   the stapled DMG.
8. Test installation and launch from the DMG in a clean user account.

Signing identities, Apple credentials, bundle ownership, and the final DMG
layout are release-owner inputs and must never be committed to this repository.

## 9. Close the loop

After every validation run:

- Update [`../checklist.md`](../checklist.md) with results and tested hardware.
- Add newly discovered behavior to the specification before changing code.
- Keep investigation details in the research archive, not in the status list.
- Run `git diff --check`, tests, and the Debug build once more before claiming
  the change is ready.
