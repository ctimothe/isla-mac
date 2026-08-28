# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout — read this first

`main` contains **documentation only**. All code lives on branches checked out
as git worktrees under `.worktrees/` (git-ignored). Run `git worktree list`
before doing anything.

- `.worktrees/dynamic-island-parity` (branch `dynamic-island-parity`) — the
  **active implementation**, and the only worktree normally checked out. A
  macOS 15+ accessory app built for functional/performance parity with
  MIT-licensed Cyclop 0.6.5 (pinned upstream commit
  `7ab60c8198681ea6c895fa55458448efb6e4c36e`). Pure SwiftPM: `Sources/DynamicIsland`
  (2-line entry point), `Sources/DynamicIslandKit` (everything),
  `Sources/DynamicIslandMediaHelper` (Objective-C dylib), `Tests/DynamicIslandKitTests`,
  plus `Scripts/*.sh` release gates.
- Branch `shell-music-mvp` — the earlier shell + Music prototype (XcodeGen
  project + `Packages/IslandCore`, `IslandModule`/`ModuleRegistry`, vendored
  `ungive/mediaremote-adapter` Perl bridge). **Has no worktree**; add one with
  `git worktree add .worktrees/shell-music-mvp shell-music-mvp` if it is ever
  needed. Kept as historical work per the approved parity design — do not
  extend it unless asked.

The parity worktree carries no `CLAUDE.md` of its own; this file is picked up
from the parent directory. Its `checklist.md` and `docs/` are separate from the
root-level ones, which describe the shell-music-mvp prototype.

## Source-of-truth policy

Binding documents win over status/tracking documents. When behavior changes,
update the spec/design first, then checklist and code in the same change.

- dynamic-island-parity: `docs/plans/2026-08-18-dynamic-island-parity-design.md`
  (approved) is the behavior and performance contract; the worktree's own
  `docs/runbook.md` and `docs/release-checklist.md` are the execution path; its
  `checklist.md` §"Scope divergence from Cyclop 0.6.5" is the current record of
  what the product deliberately does *not* match.
- shell-music-mvp: `docs/specs/shell-music-mvp.md` is the binding contract;
  root `checklist.md` tracks delivery (its D1–D8 decisions bind *that* branch
  only — nothing in the parity sources references them);
  `docs/research/technical-feasibility.md` is non-binding evidence.

**Removed features stay removed.** Snippets and Calendar went on 2026-08-20;
Notes and the Teleprompter on 2026-08-22 (`57650e0`), taking the second rail and
the tall panel body with them. Five tabs ship — Music, Shelf, Clipboard,
Translate, Settings — on one rail, and
`Tests/DynamicIslandKitTests/TabContractTests.swift` asserts the absence so a tab
cannot creep back. The parity design records each removal as a dated
**Withdrawn** amendment in place rather than deleting the section: amend it the
same way, never by rewriting the original contract.

## Commands

All commands below run from inside `.worktrees/dynamic-island-parity`.

```bash
swift test                          # unit tests
swift test --filter <TestName>      # single test or test case
bash Scripts/bundle.sh release      # assemble + ad-hoc-sign build/Dynamic Island.app
open "build/Dynamic Island.app"
pkill -x DynamicIsland              # kill a stale instance
```

There is no Xcode project — SwiftPM builds the binary and `Scripts/bundle.sh`
assembles the `.app` around it (Info.plist, icon, `.lproj` tables, licenses,
helper dylib, hardened runtime).

Full release-candidate gate order, matching `.github/workflows/build.yml` and
what `Scripts/release.sh` re-runs before it tags:

```bash
swift test
bash Scripts/test-provenance.sh    # upstream pin + MIT attribution intact
bash Scripts/test-branding.sh      # no "cyclop"/"libcyclopmedia" anywhere in Sources, Resources, Scripts
bash Scripts/test-localizations.sh # en/ru key parity, plutil-clean
bash Scripts/bundle.sh release
bash Scripts/test-identity.sh      # Info.plist name/id/executable/LSMinimumSystemVersion=15.0
bash Scripts/test-helper.sh        # helper answers "get" with one line of JSON
bash Scripts/test-package.sh       # bundle contract: binary, dylib, icon, both .lproj, licenses
bash Scripts/dmg.sh
bash Scripts/test-lifecycle.sh     # no helper survives the app
```

Two harnesses are run by hand, never as gates:
`Scripts/measure-performance.sh` (against a Cyclop build from
`Scripts/build-reference.sh`) and `Scripts/measure-sync.sh` (position accuracy
against a live Spotify, using `Scripts/sync-probe/`).

Verification-only environment hooks, all off unless set to `1` — a normal run
never touches disk for them:

- `DI_GEOM=1` — geometry trail plus the active watchdog, appended to `/tmp/di-debug.log`.
- `DI_LOCK_PREVIEW=1` — present the lock card without locking the Mac.
- `DI_OPEN_LYRICS=1` — open the lyrics stage without a pointer; also writes the trail.
- `DI_TEST_CLICK=next` — drive a lyric click from a test.

## After each change

Close the loop on every successful change — never leave the working tree or the
running app behind the code:

1. **Commit it**, on the change's own `feat/…`/`fix/…` branch (never `main` or
   `staging`; merge back with an explicit merge commit), subject describing the
   user-visible result. Only once the change's checks are green — `swift test`
   for code, the full gate order above before a release. A red build is not a
   change to commit.
2. **Rebuild the app** so the running binary matches what was just committed:
   ```bash
   bash Scripts/bundle.sh release
   ```
3. **Relaunch it**, replacing the stale instance:
   ```bash
   pkill -x DynamicIsland; open "build/Dynamic Island.app"
   ```

Steps 2–3 exist for code in the parity worktree; a docs-only change on `main`
has nothing to rebuild or relaunch and stops at the commit. The point is that
the dev app is never left running against superseded code.

## Architecture

**Shell.** A borderless, non-activating `NSPanel` (`NotchPanel`) hosts SwiftUI
content. Level is `CGWindowLevelForKey(.statusWindow) + 1` (`NotchPanel.normalLevel`
— it is read back by the lock path, so change it there and nowhere else);
collection behavior `.canJoinAllSpaces`/`.stationary`/`.fullScreenAuxiliary`/`.ignoresCycle`.
`canBecomeMain` is always false and `canBecomeKey` only while the Translate tab
asks for the keyboard. Because the panel never activates, `NSScreen.main` is
meaningless here — never use it to pick the target display, and recompute
geometry on `NSApplication.didChangeScreenParametersNotification`. The app is
`.accessory` — no Dock icon, no menu-bar item, no window — and the policy is set
once in `DynamicIslandApplication.run()` and never changed at runtime. There is
no status item: Open Panel, About, Quit and the privacy toggles all live in the
**Settings** tab (`SettingsPane` calls `orderFrontStandardAboutPanel`/`terminate`
directly). `NotchController` (~1100 lines) owns panel lifecycle, geometry,
open/close timing, and the lock transition; `AppDelegate` owns the two global hot
keys (⌥⌘I open, ⌥⌘T translate clipboard), the "Translate in Dynamic Island"
service (`NSApp.servicesProvider`, no Accessibility permission), and the Spotify
URL-scheme callback.

**Window sizing.** The window is cut once to the tallest body any tab can ask
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
`com.apple.screenIsLocked`/`…Unlocked` distributed notifications, raises the
panel past `CGShieldingWindowLevel()` and sets `canBecomeVisibleWithoutLogin`.
Over the shield the island is visible but inert; the card is a separate window
and is the only thing that answers clicks.

**Media path.** MediaRemote's read path is closed to ordinary processes since
macOS 15.4, and the `com.apple.mediaremote.external-access` entitlement is
restricted. `Sources/DynamicIslandMediaHelper/helper.m` is built into
`libdynamicislandmedia.dylib` and loaded into `/usr/bin/perl`, a platform binary
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

**UI.** `NotchContentView` switches panes by tab. Every translucent surface goes
through `glassSurface(...)` — do not hand-mix another gradient. It picks one of
two implementations: Apple's own material via `glassEffect` on macOS 26 where
there is a backdrop to sample, and `GlassSurface`'s hand-drawn recipe otherwise
(elevation `card`/`popover`/`pill`, deterministic grain). The two are never
stacked; a drawn scrim under real glass is just a scrim. `SystemAppearance`
watches Reduce Transparency and Increase Contrast and both are honored live —
an app built on a material owes them an answer. `defaults write
dev.dynamicisland.app drawnGlass -bool true` forces the recipe everywhere.

Animation curves and the collapsed/open corner radii live in `Theme`, including
Reduce Motion variants and `tracking(forSize:)` — SwiftUI applies Apple's
tracking table to semantic text styles and not to `.system(size:)`, which fixed
panels have to use. Springs are critically damped: overshoot is for gestures
that carried momentum, and nothing here is thrown.

**Interaction.** A click opens the panel; a hover only brightens the island's
surface. Every point of the compact island opens it, and the compact island has
no controls — that hit region is cut from `bodySize.width` plus the corner
radius, so it follows the width setting. Hover-to-open survives as **Open on
Hover** in Settings, off by default. Over the lock screen nothing opens: a hover
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
first timestamp; do not add a fourth.

## Hard constraints

- Cyclop's MIT attribution stays in `THIRD_PARTY_NOTICES.md` and ships inside
  the bundle; all product identity (name, bundle id `dev.dynamicisland.app`,
  paths, icon, copy) must stay original. `test-branding.sh` fails on any
  case-insensitive `cyclop` match under `Sources`, `Resources`, or the named
  scripts — including in comments.
- Every user-facing string is localized in both `Resources/en.lproj` and
  `Resources/ru.lproj`; keys *are* the English text, and `test-localizations.sh`
  enforces key parity. Use `localized(_:)` for strings needed before they reach
  a `Text`.
- Capabilities that exceed the parity design's non-goals are recorded in the
  worktree `checklist.md`: Lyrics (network, default off), Spotify PKCE account
  (keychain), the lock-screen card, system audio-output switching, and output
  volume. Anything new that leaves the machine, touches an account, or changes a
  system-wide setting must be added there and default to off.
- The design doc is amended in place, dated, never rewritten. The panel width
  (`480…620`, default `560`), the click-to-open model, and the removals all
  carry amendments; the status item, its menu and a short-lived main window were
  all withdrawn on 2026-08-25 — the app has no Dock icon, no menu-bar item and
  no window, and `.accessory` is not changed at runtime.
- The app claims exactly one entitlement,
  `com.apple.security.automation.apple-events`, for the scripting fallback.
  Adding an entitlement is a product decision, not an implementation detail.
- Signing identities, Apple credentials, and notarization inputs are
  release-owner inputs — never commit them. `Scripts/release.sh` refuses an
  unclean tree or missing release notes.
- A green build does not equal done: the checklists require manual validation on
  physical notch hardware. Record the tested Mac model and macOS version in the
  relevant `checklist.md` after a validation run.

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
