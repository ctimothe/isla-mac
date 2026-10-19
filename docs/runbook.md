# Isla verification runbook

Use this runbook from a clean checkout of the intended release commit. The
approved parity design is the behavior contract; this document is the execution
path.

## 1. Prerequisites

- macOS 15 or later.
- Xcode Command Line Tools with Swift, Clang, `codesign`, `iconutil`, and
  `hdiutil`.
- Full Xcode 26 or later only to change the app icon: `Scripts/make-app-icon.sh`
  compiles `Resources/AppIcon.icon` with `actool`, which the Command Line Tools
  lack. A build never needs it, because the compiled icon is committed.
- Optional, once per build Mac: `bash Scripts/make-signing-identity.sh` adds the
  self-signed "Isla Code Signing" identity to the login keychain, and
  `Scripts/bundle.sh` signs with it whenever no Developer ID is given. Without
  it builds are ad-hoc, and macOS forgets Isla's Accessibility permission (the
  Volume and Brightness pop-up) after every rebuild or update while System
  Settings still shows Isla switched on. `ISLA_SIGN_ADHOC=1` forces ad-hoc.
  The script pins the certificate's SHA-1 in `Scripts/signing-identity.sha1`
  (commit it): `bundle.sh` refuses a same-named certificate with another hash,
  and `ISLA_ADHOC=1 Scripts/release.sh` refuses a bundle not signed with the
  pinned one. Keep the `.p12` backup it writes; on a new Mac, import that
  rather than making a new identity, or every user re-grants the permission.
- Once, on the Mac that publishes releases: `bash Scripts/make-update-key.sh`
  makes the Ed25519 key that in-app updates trust. The private half stays in
  the login keychain ("Isla Update Signing" / `ed25519`) and goes into a
  password manager; the public half is `Resources/update-public-key.txt`
  (commit it), which `bundle.sh` writes into Info.plist as
  `IslaUpdatePublicKey`. `Scripts/release.sh` refuses to run without both, and
  uploads `Isla-<version>.dmg.sig` beside the image. Losing the private key
  means every installed copy refuses the next update and users download it by
  hand once.
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
bash Scripts/test-identity.sh
bash Scripts/test-helper.sh
bash Scripts/test-package.sh
bash Scripts/test-gatekeeper.sh
bash Scripts/test-lifecycle.sh
bash Scripts/dmg.sh
```

This is the order `Scripts/release.sh` runs and `.github/workflows/build.yml`
mirrors. `./scripts/check` runs the first four — the ones every change owes —
and nothing that packages.

Expected artifacts:

```text
build/app.noindex/Isla.app
build/Isla-<version>.dmg   # <version> from Scripts/version
```

The app is built inside a `.noindex` folder so Spotlight does not list it
beside the installed copy. Install and open it:

```bash
bash Scripts/install.sh
```

This replaces `/Applications/Isla.app` and unregisters the built copy, so
macOS only knows one Isla. Opening the built app directly registers a second
copy that can intercept the Spotify sign-in callback.

The app has no Dock icon, no menu-bar item and no window. If the panel is not
visible, press ⌃⌥⌘I — that shortcut is the only route in that needs no pointer.

## 3. Every-tab smoke pass

| Tab | Action | Expected result |
| --- | --- | --- |
| Music | Play media, seek, pause, skip | Metadata and progress update; supported controls act on the active player |
| Shelf | Drop files, multi-select, drag out, copy, reveal, remove | Files remain references; previews load only while Shelf is visible |
| Clipboard | Copy 41 text values, a multi-file selection, and a concealed item | Latest 40 remain; the selection returns all of its files when pasted back; concealed item is absent |
| Translate | Enter English and Cyrillic text; press ⌃⌥⌘T with text on the clipboard | Route reverses by script; the pane takes the keyboard; covered when Translate privacy is on |
| Settings | Toggle screenshot saving, lyrics, capture hiding and launch at login; drag the panel-width slider; open support files | Values persist, the panel rebuilds at the new width, and actions open Isla-owned paths; screenshot saving and lyrics start off |

Collapse the panel after privacy-covered rows are temporarily revealed. Reopen
it and confirm every reveal reset.

## 3a. Nothing but the island

The app must show no surface other than the panel itself.

1. Launch and confirm there is **no** Dock icon, **no** menu-bar item, and no
   window — before, during and after opening the panel.
2. Press ⌃⌥⌘I with the pointer nowhere near the notch. The panel opens.
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

1. Move the pointer into the camera-housing region. The island brightens
   under the pointer and does **not** open.
2. Click anywhere on it — artwork side, the cutout, equalizer side, and each
   outer shoulder — and confirm every one of them opens the panel without
   shifting the outer window. Nothing on the compact island is a control:
   confirm no click on it starts or stops playback.
3. Turn on **Settings → Open on Hover**, confirm the hover-delay slider appears
   and a hover opens the panel after the 50 ms delay, then turn it off again.
4. Move down the rail and confirm the 150 ms tab dwell prevents accidental
   switching.
5. Leave the cool zone and confirm collapse after 320 ms.
6. Press ⌃⌥⌘I, move the pointer well away, and confirm the panel stays open
   until Escape, ⌃⌥⌘I again, or a click in another application closes it.
7. Set the panel width to its minimum and maximum in turn, and repeat step 2 at
   each: the clickable area is cut from the width, so a dead edge would only
   appear at one of them.

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
   transport answers clicks, and the pill stays at the notch. Hover the pill:
   it brightens. Click it: it shakes and nothing opens, and the music keeps
   playing — the compact island has no transport over the shield either.
2a. Watch the card for a minute while a track plays. The scrubber advances and
   the lyric moves with it; a frozen clock here means media was deactivated by
   the lock path.
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
   confirm nothing is written to `~/Pictures/Isla`.
4. Play a track with **Lyrics** off (the default) and confirm, with Little
   Snitch or `nettop`, that no request leaves the machine.
5. Turn Lyrics on, import an LRC file and add a folder, and confirm that
   still nothing leaves the machine: lyrics are fully offline since
   `032d34b`, and any request from the app while a lyric surface is open is a
   regression.
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
  `~/Library/Application Support/Isla/lyrics` unreadable
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
  confirm both move together. Nudge one track with Sync ±, replay another, and
  confirm the second is unmoved and the first keeps its nudge; hold the offset
  readout to clear it back to 0. Re-search clears the track nudge: the
  correction belonged to the deleted entry's timing.
- Turn on **Reduce Transparency** in System Settings → Accessibility → Display.
  Every translucent surface becomes an opaque panel while the panel is open,
  without relaunching. Turn on **Increase Contrast** and confirm the lit rim
  becomes a defined border. Turn both off again.
- Open the lock card's output list and choose a device: the trackpad taps once,
  the list closes, and the foot rail's glyph becomes that device's.
- Enable launch at login, log out/in, confirm a single instance launches, then
  disable the setting.
- Quit from the menu and run `pgrep -fl libislamedia`; it must return no
  Isla helper.

## 7. Performance comparison

Build the pinned reference and product, then run:

```bash
bash Scripts/build-reference.sh
bash Scripts/measure-performance.sh \
  "build/reference/Cyclop.app" \
  "build/app.noindex/Isla.app" \
  "docs/development/performance/2026-08-18-cyclop-0.6.5-baseline.md"
```

The report uses three 60-second runs per app. Closed CPU must remain `0.0%`;
product application/helper RSS must be no higher than the reference median; no
helper may survive its parent. Record any unavoidable original-icon bundle-size
variance.

## 7a. Rehearse an update

Update Now has only replaced an app in a test folder. Before merging it, run it
once on real hardware: `bash Scripts/rehearse-update.sh` builds the next patch
version of the *installed* Isla (`ISLA_VERSION_OVERRIDE` /
`ISLA_BUILD_OVERRIDE` in `Scripts/bundle.sh` and `Scripts/dmg.sh`, rehearsal
only; `Scripts/release.sh` refuses to run with them set), packs it with
`Scripts/dmg.sh` like a release image, signs it with the update key, and writes a `release.json` into a fresh `$TMPDIR/isla-rehearsal-<version>` folder.
It then prints the steps: start the installed Isla with
`open --env DI_UPDATE_REHEARSAL=<folder> /Applications/Isla.app`, press Check for
Updates and Update Now, and watch for the restart, any App Management message,
and whether Accessibility survives. It needs the update key in the login keychain
and an installed Isla built with the same `IslaUpdatePublicKey`; it never
launches, quits or installs anything, and it removes its fake-version build from
`build/` even when it fails. Go back to the real build with
`bash Scripts/bundle.sh release && bash Scripts/install.sh`.

**Following every change (the local feed, owner's Mac).** Since 2026-10-19 the
owner's own Isla takes each committed change through Update Now instead of a
reinstall. `bash Scripts/publish-dev-update.sh` builds the committed checkout
as `VERSION.N` (newer than the installed build and the feed's last, older than
the next real release), signs it with the feed's own key and lands the image,
its signature and `release.json` in the feed — `$ISLA_DEV_FEED`, or
`.dev-updates` in the main checkout (git-ignored, 0700, marked
`.isla-dev-feed`). The feed's key is not the release key: its private half is
"Isla Dev Update Signing" in the login keychain, its public half
`Resources/update-dev-public-key.txt`, which every build carries as
`IslaDevUpdatePublicKey`; a copy following the feed trusts that key and only
that key. If it is lost, make a new pair with
`swift Scripts/update-signing.swift create-key --dev Resources/update-dev-public-key.txt`,
commit it, and reinstall once. Isla follows the feed while
`updates.localFeed` in its defaults names it (`--enable` writes it; read at
launch, so the first time takes one relaunch); it watches the folder and
offers each new build on the island, where Install runs the same download,
signature check, validator, swap and restart as a GitHub release.
`--dry-run` prints the version, build and notes without building. It refuses
a checkout that does not contain the feed's last published commit (another
worktree's branch would take those changes out of the running app); merge it
in, or pass `--replace` when that is the point. To leave:
`defaults delete com.ctimothe.isla updates.localFeed`, then `bundle.sh` and
`install.sh` — a dev build's build number may be above the next public
release's.

## 8. Developer ID and notarized release

Local builds default to ad-hoc signing. Publishing requires these values and an
installed Developer ID Application certificate:

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Example Corp (TEAMID)"
export APPLE_ID="release@example.com"
export APPLE_TEAM_ID="TEAMID"
export APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
```

Create `docs/releases/<version>.md` for the version in `Scripts/version`,
commit and push it, confirm the tree is clean,
then explicitly publish:

```bash
bash Scripts/release.sh
```

The script runs every gate in §2 — including `test-identity.sh` and
`test-lifecycle.sh` — then Developer ID-signs, notarizes and staples the app,
builds the disk image around that stapled app without rebuilding it, notarizes
and staples the image, and only then tags `v<version>` and uploads the
checksum-bearing GitHub release. A failure while publishing removes the tag it
pushed, so a retry is not blocked by it. It never publishes from an uncommitted
tree or without release notes and credentials.

## 9. Evidence

Record the date, Mac model, macOS version, display arrangement, test account,
artifact checksum, result, and any issue link beside each gate in
[release-checklist.md](release-checklist.md). A checkbox without evidence is not
a release pass.
