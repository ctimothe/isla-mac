# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout — read this first

`main` carries the **code** — it has since the parity foundation was imported
on 2026-08-18 (`b789719`), and every feature branch lands on it with a merge
commit. Run `git worktree list` before doing anything: feature branches are checked out
as git worktrees under `.worktrees/` (git-ignored), and a worktree may sit on a
branch that has already been merged. Compare against `main` before trusting one.

- The app, on `main` and every `feat/…`/`fix/…` branch cut from it — a macOS
  15+ accessory app built for functional/performance parity with MIT-licensed
  Cyclop 0.6.5 (pinned upstream commit
  `7ab60c8198681ea6c895fa55458448efb6e4c36e`). Pure SwiftPM: `Sources/Isla`
  (a four-line entry point), `Sources/IslaKit` (everything),
  `Sources/IslaMediaHelper` (Objective-C dylib), `Tests/IslaKitTests`,
  plus `Scripts/*.sh` release gates and `scripts/check`, the one verification
  gate.
- Branch `shell-music-mvp` — the earlier shell + Music prototype (XcodeGen
  project + `Packages/IslandCore`, `IslandModule`/`ModuleRegistry`, vendored
  `ungive/mediaremote-adapter` Perl bridge). **Has no worktree**; add one with
  `git worktree add .worktrees/shell-music-mvp shell-music-mvp` if it is ever
  needed. Kept as historical work per the approved parity design — do not
  extend it unless asked. Its own `checklist.md` lives on that branch; a copy of
  its spec is kept in `docs/development/specs/shell-music-mvp.md`. Both describe
  that prototype, not this app.

## Source-of-truth policy

User-facing documents are `README.md`, `CONTRIBUTING.md` and the files directly
under `docs/`. How Isla was planned, audited and verified lives under
`docs/development/`, indexed by its `README.md`. Keep that split: a new plan,
audit or research note goes under `docs/development/`, never at the root or
directly under `docs/`.

Binding documents win over status/tracking documents. When behavior changes,
update the spec/design first, then checklist and code in the same change.

- The app: `docs/development/plans/2026-08-18-dynamic-island-parity-design.md`
  (approved) is the behavior and performance contract; `docs/runbook.md` and
  `docs/release-checklist.md` are the execution path; `docs/development/checklist.md` §"Scope
  divergence from Cyclop 0.6.5" is the current record of what the product
  deliberately does *not* match, and its dated sections (v0.2, v0.3, …) record
  what each release closed.
- shell-music-mvp (that branch only): `docs/development/specs/shell-music-mvp.md` is the
  binding contract; that branch's `checklist.md` tracks delivery (its D1–D8
  decisions bind *that* branch only — nothing in this app references them);
  `docs/development/research/technical-feasibility.md` is non-binding evidence.

**Removed features stay removed.** Snippets and Calendar went on 2026-08-20;
Notes and the Teleprompter on 2026-08-22 (`57650e0`), taking the second rail and
the tall panel body with them. Since R8 (spec §19, 2026-10-18) there are no
tabs and no rail: the panel shows one surface at a time — the player, the
lyric stage, the Shelf's tray, the drop surface, Clipboard, Translate,
Settings and the welcome (`NotchViewModel.Surface`) — reached from the
island, the pages' dots and swipe, the gear, the right-click menu and the hot
keys. Tools went with R8b (spec §19.16, 2026-10-18), previews and all, rather
than staying as a fifth page. `Tests/IslaKitTests/SurfaceContractTests.swift`
asserts every surface and every road to it, so neither a removed feature nor
a tab can creep back. The parity design records each removal as a dated
**Withdrawn** amendment in place rather than deleting the section: amend it the
same way, never by rewriting the original contract.

## Commands

All commands below run from the repository root (or the root of whichever
worktree the change lives in).

```bash
./scripts/check                     # the gate — all eleven release steps, exactly what CI runs
./scripts/check test                # just the unit tests, for a quick pass while iterating
swift test                          # unit tests
swift test --filter <TestName>      # single test or test case
bash Scripts/bundle.sh release      # assemble + ad-hoc-sign build/app.noindex/Isla.app
bash Scripts/install.sh             # replace /Applications/Isla.app and open it (bootstrap / fallback)
bash Scripts/publish-dev-update.sh  # publish the committed build to the local update feed;
                                    # the running Isla offers it on the island (--dry-run, --enable)
```

There is no Xcode project — SwiftPM builds the binary and `Scripts/bundle.sh`
assembles the `.app` around it (Info.plist, icon, `.lproj` tables, licenses,
helper dylib, hardened runtime).

Full release-candidate gate order, matching `.github/workflows/build.yml` and
what `Scripts/release.sh` re-runs before it tags:

```bash
swift test
bash Scripts/test-provenance.sh    # upstream pin + MIT attribution intact
bash Scripts/test-branding.sh      # no "cyclop" and no former "Dynamic Island" identity anywhere
                                   # in Sources, Resources, Scripts; bundle.sh names Isla
bash Scripts/test-localizations.sh # en/ru key parity, plutil-clean
bash Scripts/bundle.sh release
bash Scripts/test-identity.sh      # Info.plist name/id/executable/LSMinimumSystemVersion=15.0
bash Scripts/test-helper.sh        # helper answers "get" with one line of JSON
bash Scripts/test-package.sh       # bundle contract: binary, dylib, icon, both .lproj,
                                   # licenses, App Intents metadata
bash Scripts/test-gatekeeper.sh    # the outside view: Developer ID on the bundle and the
                                   # nested dylib, spctl, a stapled ticket, and the helper
                                   # loading under quarantine. Skips itself on an ad-hoc build
bash Scripts/test-lifecycle.sh     # no helper survives the app
bash Scripts/dmg.sh
```

Two harnesses are run by hand, never as gates:
`Scripts/measure-performance.sh` (against a Cyclop build from
`Scripts/build-reference.sh`) and `Scripts/measure-sync.sh` (position accuracy
against a live Spotify, using `Scripts/sync-probe/`).

Verification-only environment hooks, all off unless set (to `1`, or for `DI_UPDATE_REHEARSAL` to a folder) — a normal run
never touches disk for them. `DebugTrail` reads each one once, at launch; ask it
(`DebugTrail.geometry`, …) rather than the environment:

- `DI_GEOM=1` — geometry trail, the watchdog's samples included, appended to `/tmp/di-debug.log`.
- `DI_LOCK_PREVIEW=1` — present the lock card without locking the Mac.
- `DI_OPEN_LYRICS=1` — open the lyrics stage without a pointer; also writes the trail.
- `DI_OPEN_PANEL=1` — open the panel on the player without a pointer, to film a skip.
- `DI_MEDIA=1` — the media trail alone: every snapshot and hold decision, nothing drawn.
- `DI_TEST_CLICK=next` — drive a lyric click from a test.
- `DI_UPDATE_REHEARSAL=<folder>` — Update Now takes its release from `<folder>/release.json` and that folder's files, not GitHub; made by `Scripts/rehearse-update.sh`.

## After each change

Close the loop on every successful change — never leave the working tree or the
running app behind the code:

1. **Commit it**, on the change's own `feat/…`/`fix/…` branch (never `main` or
   `staging`; merge back with an explicit merge commit), subject describing the
   user-visible result. Only once the change's checks are green — `swift test`
   for code, the full gate order above before a release. A red build is not a
   change to commit.
2. **Publish it to the local update feed** (owner, 2026-10-19: every change
   reaches the running app through Isla's own update, never a reinstall):
   ```bash
   bash Scripts/publish-dev-update.sh
   ```
   It builds the committed checkout as `VERSION.N`, signs it with the update
   key and lands it in the feed (`.dev-updates` in the main checkout). The
   running Isla offers it on the island within a second or two.
3. **The owner presses Install on the island**; Isla replaces itself in
   `/Applications` and restarts as the new build. Do not install it for them.

`Scripts/install.sh` (after `bash Scripts/bundle.sh release`) is now the
bootstrap and the fallback only: the first install of a build that knows the
feed, a Mac where the update path fails, or leaving the channel
(`defaults delete com.ctimothe.isla updates.localFeed`). Never `open` the
bundle in `build/`: every launch from there registered a second Isla with
LaunchServices — three showed in Spotlight on 2026-09-21, and any of them
could catch the Spotify sign-in callback. The build lives in
`build/app.noindex/` so Spotlight skips it; `install.sh` and the publish
script unregister it.

Steps 2–3 exist for code changes; a docs-only change has nothing to publish
and stops at the commit. The point is that the dev app is never left running
against superseded code.

## Architecture

**Shell.** A borderless, non-activating `NSPanel` (`NotchPanel`) hosts SwiftUI
content. Level is `CGWindowLevelForKey(.statusWindow) + 1` (`NotchPanel.normalLevel`
— it is read back by the lock path, so change it there and nowhere else);
collection behavior `.canJoinAllSpaces`/`.stationary`/`.fullScreenAuxiliary`/`.ignoresCycle`.
`canBecomeMain` is always false and `canBecomeKey` only while a surface that
types asks for the keyboard — Clipboard and Translate (`Surface.takesKeyboard`),
and Settings only while a shortcut field records. A page reached by a swipe,
a dot, the pointer or a click on the bare notch never takes it: only a
summons (⌃⌥⌘V, ⌃⌥⌘T, the menu), a press into the field
(`NotchViewModel.pressClaimsKeyboard`) or focus moving into it (VoiceOver) does. ⌃Tab, which only a key panel hears, carries it onto
the page it turns to, the Shelf and Music included
(`NotchViewModel.turnPageByKey`). Because the panel never activates, `NSScreen.main` is
meaningless here — never use it to pick the target display, and recompute
geometry on `NSApplication.didChangeScreenParametersNotification`. The app is
`.accessory` — no Dock icon, no menu-bar item, no window — and the policy is set
once in `IslaApplication.run()` and never changed at runtime. There is
no status item: Open Panel, About, Quit and the privacy toggles all live in the
**Settings** surface (`SettingsPane` calls `orderFrontStandardAboutPanel`/`terminate`
directly). Since 2026-10-15 Settings is a 400-tall sidebar of ten sections
drawn from `SettingsTable`, a pure table of every row with its key and
default; `NotchViewModel`'s accessors read their defaults back from it, so add
a setting there, not in the view. `NotchController` (~1400 lines) owns panel lifecycle, geometry,
open/close timing, and the lock transition; `AppDelegate` owns the four global hot
keys (⌃⌥⌘I open, ⌃⌥⌘V clipboard, ⌃⌥⌘T translate clipboard, ⌃⌥⌘L lyric stage —
rebindable, held by `HotKeyCenter`), the "Translate in
Isla" service (`NSApp.servicesProvider`, no Accessibility permission), and the
Spotify URL-scheme callback. Since 2026-10-11 a pinned panel that is not key
also holds plain Escape through a transient Carbon hot key, registered only
while the pin stands (`NotchController.updateEscapeHotKey`), and ends on
another app's activation; key status is unchanged by it.
The Shelf's Delete key (⌫, ⌘⌫) uses the same mechanism since 2026-10-15
(`ShelfDeleteKeyHolder`): held only while the panel is open on the Shelf's
tray, the pointer is over it, Isla is not active, and the selection was made
during this opening — a stuck one would eat Delete system-wide, so every
other state releases it.
Since 2026-10-15 **Volume and Brightness** (off by default) reads the media
keys through a `CGEventTap` once Accessibility is granted (`MediaKeyHUD`,
`MediaKeyTap`). It takes a key only when it can apply it, decides once per
hold, and keeps the callback to a decode and a write — a slow or stuck tap
eats those keys in every app. Third-party app icons (Spotify, the players in
Settings, the empty player's buttons) come only from the installed app at
runtime (`AppIcons`); no brand asset ships in the bundle.

**Window sizing.** The window is cut once to the tallest body any surface can ask
for and then never resized — it is transparent outside the visible panel, and
what is *clickable* is decided separately by `activeRect` on `NotchRootView`
(everything outside it is click-through). Resizing across a lock produced
stretched window-server snapshots, which is why the lock card lives in its own
`LockCardWindow` instead. All constants live in `NotchMetrics`; derived rects
in `NotchGeometry`.

**Notch detection.** `safeAreaInsets.top > 0`, exact bounds from
`auxiliaryTopLeftArea`/`auxiliaryTopRightArea`. Unlike shell-music-mvp (binding
decision D7), the parity app *does* draw a centered synthetic notch on
unnotched displays.

**Lock screen.** `LockScreenPresence` watches the undocumented-but-stable
`com.apple.screenIsLocked`/`…Unlocked` distributed notifications and lifts the
panel into a SkyLight space of its own at absolute level 400, over the lock
screen's own space at 300 — private SPI resolved with `dlsym`, so a macOS that
drops a symbol degrades to a pill hidden while locked. Raising the window level past
`CGShieldingWindowLevel()` was tried first and lost the physical test.
Over the shield the island is visible but inert; the card is a separate window
and is the only thing that answers clicks.

**Media path.** MediaRemote's read path is closed to ordinary processes since
macOS 15.4, and the `com.apple.mediaremote.external-access` entitlement is
restricted. `Sources/IslaMediaHelper/helper.m` is built into
`libislamedia.dylib` and loaded into `/usr/bin/perl`, a platform binary
the daemon trusts and which is signed without library validation. It prints one
JSON object per line on stdout, takes commands on stdin, and exits when stdin
closes so it can never outlive the app. `NowPlayingFeed` spawns it and parses
the stream (`NDJSONBuffer` preserves partial lines; every `Snapshot` field is
optional-shaped, and `commands: nil` means *unknown*, not *none*).
`MediaController` layers position-clock logic over that — seek verdicts, rate,
foreign-session hold — and falls back to `PlayerBridge` (AppleScript +
distributed notifications, Music and Spotify only) when the helper is
unavailable. **The Swift app never links MediaRemote.** Because of the private
framework, distribution is a signed + notarized direct-download DMG, never the
App Store.

**Error contract.** Helper failure, malformed JSON, or missing resources must
never crash the app or raise a permission prompt — there is no user-grantable
MediaRemote permission. Music deactivates, the island collapses, and
`NowPlayingFailurePolicy` backs the restart delay off rather than retrying every
two seconds.

**UI.** `NotchContentView` switches panes by surface, and draws two pages side
by side only while they travel. Every translucent surface goes
through `glassSurface(...)` — do not hand-mix another gradient. It picks one of
two implementations: Apple's own material via `glassEffect` on macOS 26 where
there is a backdrop to sample, and `GlassSurface`'s hand-drawn recipe otherwise
(elevation `card`/`popover`/`pill`, deterministic grain). The two are never
stacked; a drawn scrim under real glass is just a scrim. `SystemAppearance`
watches Reduce Transparency and Increase Contrast and both are honored live —
an app built on a material owes them an answer. `defaults write
com.ctimothe.isla drawnGlass -bool true` forces the recipe everywhere.

Animation curves and the collapsed/open corner radii live in `Theme`, including
Reduce Motion variants and `tracking(forSize:)` — SwiftUI applies Apple's
tracking table to semantic text styles and not to `.system(size:)`, which fixed
panels have to use. Springs are critically damped: overshoot is for gestures
that carried momentum, and nothing here is thrown — except the island's
outline (spec §19.3), which grows out of the bezel on `Theme.islandSpring`
(response 0.5, damping 0.75) as the reference's does; the content inside it
keeps the critically damped curves. The shut island carries a 2 pt stroke,
tinted by its activity, on every wallpaper and never on the bare notch
(`IslandStroke`).

**Interaction.** A click opens the panel on what the island shows; a hover
only brightens the island's surface. Every point of the compact island opens
it, and the compact island has no controls — that hit region is cut from
`bodySize.width` plus the corner radius, so it follows the width setting. The
island shows one activity at a time, by rank (`IslandActivity`, spec §19.1),
and a click follows the rank (`NotchViewModel.openTarget`): Music opens the
player, the Shelf its tray, and an alert folds instead of opening anything.
While Music holds the island, files on the Shelf wait as a bubble beside it,
which has a hit region of its own (`NotchRootView.bubbleRect`) so the gap
between the two stays click-through; a click on the bubble opens the tray.
The open island has four **pages** side by side — Music, the Shelf, Clipboard,
Translate (`Surface.pages`, spec §19.16) — and four dots under each
(`PageDots`) say where you are and turn to any page on a click; VoiceOver
reads the row as one adjustable element, "Pages, Page 2 of 4, Shelf". A
sideways two-finger swipe over the pages turns them one at a time:
`PageSwipe` takes precise scroll events only, locks a direction after 10 pt,
tracks 1:1, rubber-bands past either end and projects the release's momentum.
Nothing on a page scrolls sideways — the Shelf is a grid that scrolls down —
so sideways is always the pages'. Shelf, Clipboard and Translate share one
size (`SurfaceLayout.toolPageHeight`, the panel's width); only Music keeps its
own. `PageTravel` draws every frame on the
display's own clock, with animations disabled, so no implicit `.animation`
lays a curve over the fingers; the settle is the island's spring. An ordinary
wheel never turns a page — the dots are its way — and ⌃Tab and ⌃⇧Tab turn
them while the panel has the keyboard. The clickable region is cut over every
page a gesture can reach, once per gesture. The stage and Settings sit a level
below the pages: every page and the stage carry the **gear**, which opens
Settings; on Settings it is an X (`HeaderGear`) that goes back. When the
open body shrinks under a pointer that was on it (a dot to a shorter page),
the body it left holds the panel until the pointer reaches the new one,
leaves, heads away, or presses or scrolls off the panel
(`PointerWatcher.shrunkFromRect`, with a global mouse monitor only while it
stands; the controller's collapse check asks `holdsBeyondBody(at:)`, never a
copy). A click on the notch's own span of the
header row closes the panel. A right-click on the island or the header row opens
`IslandMenu` (Clipboard, Shelf, Translate Clipboard, lyrics, Settings…, Quit);
it is the app's only menu, since an `.accessory` app has no menu bar.
Hover-to-open survives as **Open on Hover** in Settings, off by default. Over the lock screen nothing opens: a hover
brightens, a click shakes (`RefusalShake`). `PrivacyMode` covers per-section
content (clipboard, translate) behind drifting dots. Haptics are sparing:
`Haptics` fires `NSHapticFeedbackManager`'s `.alignment` when a lyric click lands
on its line and `.levelChange` when an audio output is picked on the lock card —
on the drawn frame, never ahead of the animation.

**Lyrics.** One timeline and one renderer for every surface. `LyricSweep` owns
the clock — `index`, `centreIndex`, `end`, `lead`, `position`, `fraction`,
`displayed` — and `LyricRow`/`KaraokeText` own what a line looks like. The
island's stage and the lock card each keep only their own container. They had
three copies of the binary search once and disagreed about the line before the
first timestamp; do not add a fourth. The closed island's one-line caption
alone reads ahead of the voice (Settings "Show next line early", default Auto,
0.30–0.50 s by the length of the line turned to, never below 0.30 s except
where the 45 percent cap binds):
`LyricSweep.readingMoment` is the one function that picks its line, and
`readAheadStart` the one that says when it turns — the boundary wakes ask the
same function, so route nothing else around them. A catalogue timeline stamped
past the track's end (`LyricTimeline.overrun`, flagged above
`OnlineLyrics.durationTolerance`) is timed for a longer version: the stage says
so and every row offers Sync Here (`LyricSweep.syncDelay`, per-track range ±45 s).

## Hard constraints

- Cyclop's MIT attribution stays in `THIRD_PARTY_NOTICES.md` and ships inside
  the bundle; all product identity (name, bundle id `com.ctimothe.isla`,
  paths, icon, copy) must stay original. `test-branding.sh` fails on any
  case-insensitive `cyclop` match under `Sources`, `Resources`, or the named
  scripts — including in comments. It bans the former product name
  **Dynamic Island** on the same terms, so the rename to Isla cannot silently
  regress; the descriptive tagline "Dynamic Island–style" is nominative use and
  lives only in the README. The hyphenated repository name `dynamic-island`
  is not matched, on purpose: it names the folder, not the product.
- Every user-facing string is localized in both `Resources/en.lproj` and
  `Resources/ru.lproj`; keys *are* the English text, and `test-localizations.sh`
  enforces key parity. Use `localized(_:)` for strings needed before they reach
  a `Text`.
- Capabilities that exceed the parity design's non-goals are recorded in the
  `docs/development/checklist.md`: Lyrics (network, default off), Spotify PKCE account
  (keychain), the lock-screen card, system audio-output switching, and output
  volume. Anything new that leaves the machine, touches an account, or changes a
  system-wide setting must be added there and default to off.
- The design doc is amended in place, dated, never rewritten. The panel width
  (`480…620`, default `560`), the click-to-open model, and the removals all
  carry amendments; the status item, its menu and a short-lived main window were
  all withdrawn on 2026-08-25 — the app has no Dock icon, no menu-bar item and
  no window, and `.accessory` is not changed at runtime.
- The app claims exactly one entitlement in `Resources/Isla.entitlements`,
  `com.apple.security.automation.apple-events`, for the scripting fallback.
  A Developer ID build adds `keychain-access-groups` at bundle time
  (`Scripts/bundle.sh`) so Spotify tokens can live in the data-protection
  keychain; an ad-hoc build cannot carry it. Adding any other entitlement is a
  product decision, not an implementation detail.
- Signing identities, Apple credentials, and notarization inputs are
  release-owner inputs — never commit them. `Scripts/release.sh` refuses an
  unclean tree or missing release notes.
- A green build does not equal done: the checklists require manual validation on
  physical notch hardware. Record the tested Mac model and macOS version in the
  `docs/development/checklist.md` after a validation run.

## Conventions

- Swift tools 6.0, language mode v5, `platforms: [.macOS(.v15)]`. Almost
  everything is `@MainActor`.
- Comments here are long and explain *why*, usually by naming the bug that
  motivated the code ("this used to be an index-out-of-range crash on a
  supported gesture"). Match that density; a bare restatement of the code is
  worse than no comment. Some scripts carry Russian comments — leave them in the
  language they are in.
- Commit subjects are lowercase sentences describing the user-visible result,
  not the files touched: `fix: the island stays at the notch while locked`.
  Bodies explain the mechanism and name the tests that hold the invariant.
- Work happens on `feat/…` or `fix/…` branches merged back with an explicit
  merge commit: `Merge feat/lock-card-own-window: nothing resizes across a lock`.
