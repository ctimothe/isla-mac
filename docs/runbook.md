# Dynamic Island verification runbook

Use this runbook from a clean checkout of the intended release commit. The
approved parity design is the behavior contract; this document is the execution
path.

## 1. Prerequisites

- macOS 15 or later.
- Xcode Command Line Tools with Swift, Clang, `codesign`, `iconutil`, and
  `hdiutil`.
- A physical-notch MacBook for the hardware pass and a non-notch/external display
  for the synthetic pass.
- Cyclop 0.6.5 built from pinned commit
  `7ab60c8198681ea6c895fa55458448efb6e4c36e` for performance comparison.

Confirm the tree and toolchain:

```bash
git status --short
swift --version
xcode-select -p
```

## 2. Automated release-candidate gates

Run in this order:

```bash
swift test
bash Scripts/test-provenance.sh
bash Scripts/test-branding.sh
bash Scripts/test-localizations.sh
bash Scripts/bundle.sh release
bash Scripts/test-helper.sh
bash Scripts/test-package.sh
bash Scripts/dmg.sh
bash Scripts/test-lifecycle.sh
```

Expected artifacts:

```text
build/Dynamic Island.app
build/DynamicIsland-0.6.5.dmg
```

Launch the verified bundle:

```bash
open "build/Dynamic Island.app"
```

The app is an accessory application, so use its menu-bar capsule if the panel is
not visible.

## 3. Every-tab smoke pass

| Tab | Action | Expected result |
| --- | --- | --- |
| Music | Play media, seek, pause, skip | Metadata and progress update; supported controls act on the active player |
| Shelf | Drop files, multi-select, drag out, copy, reveal, remove | Files remain references; previews load only while Shelf is visible |
| Clipboard | Copy 41 text values, a file, and a concealed item | Latest 40 remain; file is captured; concealed item is absent |
| Snippets | Add, search, copy, externally edit JSON, reopen | Search is case-insensitive; external changes reload; malformed JSON is never overwritten |
| Calendar | Open tab, press Allow, join a known provider | No launch prompt; explicit prompt works; only HTTPS known-provider links show Join |
| Translate | Enter English and Cyrillic text | Route reverses by script; installed packs translate offline; missing packs explain the remedy |
| Notes | Add two notes, edit, copy, delete, leave a blank | First line is the title; blank note disappears on leaving |
| Teleprompter | Paste script, change speed/type, start, leave tab | Smooth scroll; panel holds open only while running; leaving suspends it |
| Settings | Toggle screenshot saving and launch at login; open support files | Values persist and actions open Dynamic Island-owned paths |

Collapse the panel after privacy-covered rows are temporarily revealed. Reopen
it and confirm every reveal reset.

## 4. Display passes

### Physical notch

On a notched MacBook display:

1. Move the pointer into the camera-housing region.
2. Confirm the panel opens after the 50 ms delay without shifting the outer
   window.
3. Move through both rails and confirm the 150 ms tab dwell prevents accidental
   switching.
4. Leave the cool zone and confirm collapse after 320 ms.
5. Run the teleprompter, move the pointer away, and confirm it stays open until
   paused, completed, escaped, or clicked away.

### Synthetic notch

Make a non-notch or external display primary, relaunch, and repeat the pass. The
collapsed target must be centered at the menu-bar top and all nine tabs must
remain available.

## 5. Permission passes on a clean account

Create a temporary macOS user or reset only this bundle's consent state before
the test:

```bash
tccutil reset Calendar dev.dynamicisland.app
```

1. Launch and visit every tab except Calendar. No app permission prompt should
   appear.
2. Open Calendar. Reading the explanatory state must still not prompt.
3. Press **Allow**. Exactly one Calendar prompt should appear.
4. Deny once and confirm only Calendar is disabled; the shell and other tabs
   continue working.
5. Drag a file from Downloads to Shelf. Any protected-folder prompt must appear
   in the context of that Shelf action, never at launch.

The app must not request Accessibility, Screen Recording, contacts, network
accounts, or permission to read Cyclop data.

## 6. Failure and persistence passes

- Quit while editing a note and teleprompter script; relaunch and confirm both
  flushed.
- Put invalid JSON in `~/Library/Application Support/DynamicIsland/snippets.json`;
  confirm the warning appears and adding a snippet does not overwrite the file.
- Temporarily remove the bundled media helper; confirm Music falls back after
  three failures without crashing the shell.
- Delete a referenced Shelf file; open Shelf and confirm only the missing card is
  removed. Denied access must keep the card.
- Enable launch at login, log out/in, confirm a single instance launches, then
  disable the setting.
- Quit from the menu and run `pgrep -fl libdynamicislandmedia`; it must return no
  Dynamic Island helper.

## 7. Performance comparison

Build the pinned reference and product, then run:

```bash
bash Scripts/build-reference.sh
bash Scripts/measure-performance.sh \
  "build/reference/Cyclop.app" \
  "build/Dynamic Island.app" \
  "docs/performance/2026-08-18-cyclop-0.6.5-baseline.md"
```

The report uses three 60-second runs per app. Closed CPU must remain `0.0%`;
product application/helper RSS must be no higher than the reference median; no
helper may survive its parent. Record any unavoidable original-icon bundle-size
variance.

## 8. Developer ID and notarized release

Local builds default to ad-hoc signing. Publishing requires these values and an
installed Developer ID Application certificate:

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Example Corp (TEAMID)"
export APPLE_ID="release@example.com"
export APPLE_TEAM_ID="TEAMID"
export APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
```

Create `docs/releases/0.6.5.md`, commit and push it, confirm the tree is clean,
then explicitly publish:

```bash
bash Scripts/release.sh
```

The script reruns all local gates before tagging, Developer ID-signs the app and
DMG, submits the DMG to Apple notary service, staples and validates the ticket,
pushes `v0.6.5`, and uploads the checksum-bearing GitHub release. It never
publishes from an uncommitted tree or without release notes and credentials.

## 9. Evidence

Record the date, Mac model, macOS version, display arrangement, test account,
artifact checksum, result, and any issue link beside each gate in
[release-checklist.md](release-checklist.md). A checkbox without evidence is not
a release pass.
