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

The app has no Dock icon, no menu-bar item and no window. If the panel is not
visible, press ⌥⌘I — that shortcut is the only route in that needs no pointer.

## 3. Every-tab smoke pass

| Tab | Action | Expected result |
| --- | --- | --- |
| Music | Play media, seek, pause, skip | Metadata and progress update; supported controls act on the active player |
| Shelf | Drop files, multi-select, drag out, copy, reveal, remove | Files remain references; previews load only while Shelf is visible |
| Clipboard | Copy 41 text values, a multi-file selection, and a concealed item | Latest 40 remain; the selection returns all of its files when pasted back; concealed item is absent |
| Translate | Enter English and Cyrillic text; press ⌥⌘T with text on the clipboard | Route reverses by script; the pane takes the keyboard; covered when Translate privacy is on |
| Settings | Toggle screenshot saving, lyrics, capture hiding and launch at login; drag the panel-width slider; open support files | Values persist, the panel rebuilds at the new width, and actions open Dynamic Island-owned paths; screenshot saving and lyrics start off |

Collapse the panel after privacy-covered rows are temporarily revealed. Reopen
it and confirm every reveal reset.

## 3a. Nothing but the island

The app must show no surface other than the panel itself.

1. Launch and confirm there is **no** Dock icon, **no** menu-bar item, and no
   window — before, during and after opening the panel.
2. Press ⌥⌘I with the pointer nowhere near the notch. The panel opens.
3. In Settings, press **Open Panel** and confirm it closes again.
4. In Settings, press **About** and confirm the standard about panel names the
   build's version.
5. In Settings, toggle **Hide Contents** for a section and confirm the panel
   covers exactly that tab.
6. In Settings, press **Quit**, confirm the second press is required, and
   confirm the app exits. This is the only quit route; if it fails, the app can
   only be stopped from Activity Monitor.

## 3b. Panel width

1. Drag **Settings → Panel Width** to its minimum. The panel rebuilds narrower,
   the rail keeps all five icons, and nothing is clipped.
2. Drag it to its maximum and confirm the panel is the full 620 pt again.
3. At every setting the outer window is unchanged: hover just outside the drawn
   panel and confirm the click goes to whatever is behind it, not to the island.

## 4. Display passes

### Physical notch

On a notched MacBook display:

1. Move the pointer into the camera-housing region.
2. Confirm the panel opens after the 50 ms delay without shifting the outer
   window.
3. Move down the rail and confirm the 150 ms tab dwell prevents accidental
   switching.
4. Leave the cool zone and confirm collapse after 320 ms.
5. Press ⌥⌘I, move the pointer well away, and confirm the panel stays open
   until Escape, ⌥⌘I again, or a click in another application closes it.

### Synthetic notch

Make a non-notch or external display primary, relaunch, and repeat the pass. The
collapsed target must be centered at the menu-bar top and all five tabs must
remain available.

### Display changes and the lock screen

1. With the panel open on the Translate tab and a phrase half-typed in it, plug
   in or unplug an external display. The panel is rebuilt on the notch display,
   keeps the tab, and keeps the clipboard history and the half-typed
   translation.
2. Lock the Mac with the panel expanded. The lock card appears centered, its
   transport answers clicks, and the pill stays at the notch.
3. Let the display sleep while locked, then wake it. The card still works and
   the panel never opens under the shield.
4. Let a track change while locked. The card stays clickable and no phantom
   region elsewhere on the shield eats clicks.
5. Unlock. The panel returns to its notch frame, collapsed.
5a. Repeat the lock with the panel width set to its minimum. The card and the
   pill are placed the same way — the window never resized, so nothing about the
   lock path depends on the width.
6. With the lock-screen card switched off in Settings, repeat step 2: nothing
   is drawn over the shield and pointer movement over the notch opens nothing.

## 5. Permission and network passes on a clean account

Create a temporary macOS user for the test.

1. Launch and visit every tab. No app permission prompt should appear at
   launch or while browsing: the one entitlement the app claims
   (`com.apple.security.automation.apple-events`) is only exercised when the
   scripting fallback first drives a player.
2. Drag a file from Downloads to Shelf. Any protected-folder prompt must appear
   in the context of that Shelf action, never at launch.
3. Copy a screenshot with **Save clipboard screenshots** off (the default) and
   confirm nothing is written to `~/Pictures/DynamicIsland`.
4. Play a track with **Lyrics** off (the default) and confirm, with Little
   Snitch or `nettop`, that no request leaves the machine.
5. Turn Lyrics on and confirm requests go only to `lrclib.net`,
   `raw.githubusercontent.com` and `lyrics.kugou.com`.
6. Connect a Spotify account, confirm the browser round trip returns and the
   heart works, then Disconnect and confirm the keychain items are gone.

The app must not request Accessibility, Screen Recording, contacts, or
permission to read Cyclop data. Apple Events consent is raised by macOS only
when the scripting fallback first drives Music or Spotify.

7. Force the fallback (remove the bundled helper) on a *signed* build and
   confirm the Apple Events prompt appears and transport works after Allow.
   This is the check that would have caught a hardened-runtime build shipping
   without that entitlement, where the fallback fails with -1743 and logs
   nothing a user would see.

## 6. Failure and persistence passes

- Drop several files on the Shelf, one of them from a protected folder; quit,
  relaunch, and confirm every card returns and still opens its file.
- Make the lyrics cache directory
  `~/Library/Application Support/DynamicIsland/lyrics` unreadable
  (`chmod 000`); play a track with Lyrics on, restore permissions, and confirm
  the track kept playing and the cached words are intact.
- On an unsigned local build with a Spotify account connected, confirm
  `spotify-credentials.json` is mode `0600`, then make it unreadable: the cost
  is the account showing as disconnected, never a failed launch.
- Temporarily remove the bundled media helper; confirm Music falls back after
  three failures without crashing the shell, and that the restart delay grows
  rather than repeating every two seconds.
- Suspend the helper process (`kill -STOP`) so it stays alive but silent;
  confirm the app notices within about fifteen seconds and falls back rather
  than showing an empty media tab indefinitely.
- Delete a referenced Shelf file; open Shelf and confirm only the missing card is
  removed. Denied access must keep the card.
- Pause a track before its first lyric line, then open the panel. The caption
  shows the opening line, unswept — never nothing — and the transport sits at
  exactly the height it does for a track with words.
- Play a track whose lyrics carry word timing, open the full stage, and confirm
  the caption behind it and the stage agree on the current line. Nudge Sync and
  confirm both move together.
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

The script runs every gate in §2 — including `test-identity.sh` and
`test-lifecycle.sh` — then Developer ID-signs, notarizes and staples the app,
builds the disk image around that stapled app without rebuilding it, notarizes
and staples the image, and only then tags `v0.6.5` and uploads the
checksum-bearing GitHub release. A failure while publishing removes the tag it
pushed, so a retry is not blocked by it. It never publishes from an uncommitted
tree or without release notes and credentials.

## 9. Evidence

Record the date, Mac model, macOS version, display arrangement, test account,
artifact checksum, result, and any issue link beside each gate in
[release-checklist.md](release-checklist.md). A checkbox without evidence is not
a release pass.
