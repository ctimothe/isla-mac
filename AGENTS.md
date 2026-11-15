# AGENTS.md

Canonical instructions for every agent tool working in this repository
(Claude Code imports this file from `CLAUDE.md`; Codex and others read it
directly). It overrides the owner's global working agreement where they differ.

## Purpose and stack

Isla is a macOS accessory app that turns the MacBook's notch into an island in
the style of the iPhone's Dynamic Island: one activity at a time on the island,
and a click opens a panel with the player, synced lyrics, a file Shelf,
clipboard history, translation and Settings. Open source (MIT), distributed as
a direct-download DMG from GitHub Releases, never the App Store.

Pure SwiftPM, no Xcode project: `Sources/Isla` (a four-line entry point),
`Sources/IslaKit` (everything), `Sources/IslaMediaHelper` (an Objective-C
dylib), `Tests/IslaKitTests`, `Scripts/*.sh` (packaging, release gates, labs)
and `scripts/check`, the one verification gate. `Scripts/bundle.sh` assembles
the `.app` (Info.plist, icon, `.lproj` tables, licenses, helper dylib, hardened
runtime) around the SwiftPM binary.

## Is this checkout the shipped app? Run this first

```bash
./scripts/source-fresh.sh      # 0 fresh · 1 stale or unrelated · 2 origin is not GitHub
```

Run it before reading `Sources/` to design, document, measure or rebuild the
app anywhere else (a canvas, a spec, a film, a landing page), and say its
one-line answer in your first reply. On anything but `FRESH`, stop: the code in
front of you is not what ships. `origin` must be GitHub (`ctimothe/isla-mac`).

## Repository layout

- One working line: `main`, plus the active feature branch (today
  `feat/islandcn-identical`). Feature branches are `feat/…` or `fix/…`, cut
  from `origin/main`, and merge back with an explicit merge commit
  (`Merge feat/x: what the user gets`). Never commit directly to `main`.
- Worktrees live under `.claude/worktrees/<name>`. Run `git worktree list`
  first; a worktree may sit on a branch that has already been merged, so
  compare it against `main` before trusting it.
- There are no archive tags and no backup remote.

## Docs

Docs describe the app as it is today; history lives in git. **When behaviour
changes, update `docs/development/spec.md` in the same change.** A new hardware
check goes into `docs/development/open-checks.md`; a passed one is deleted from
it in the commit that records it.

- User-facing: `README.md`, `CONTRIBUTING.md`, `docs/runbook.md` (verify and
  release), `docs/release-checklist.md`, `docs/local-lyrics.md`, and
  `docs/releases/<version>.md` (release notes the release job reads; never
  rename or delete them). `THIRD_PARTY_NOTICES.md` is checked by
  `Scripts/test-provenance.sh`.
- Development: `docs/development/README.md` indexes `spec.md`,
  `open-checks.md`, and the active plan and its audits.

## Map: read before editing

| Under | Read first |
|---|---|
| `Sources/IslaKit/**` (any behaviour) | `docs/development/spec.md`, the section for that feature |
| `Sources/IslaKit/Notch/`, `UI/IslandMotion.swift`, `UI/Hugeicons.swift`, `UI/GlyphRecipe.swift` | `docs/development/plans/2026-11-15-islandcn-identical.md` and its audits (current work) |
| `Sources/IslaKit/UI/SettingsTable.swift` | spec §13 and §17 (a new setting's default) |
| `Sources/IslaMediaHelper/` | spec §8.1–8.2 |
| `Tests/IslaKitTests/SurfaceContractTests.swift` | spec §6 and §22 |
| `Scripts/release.sh`, `Scripts/next-release.sh`, `.github/workflows/` | `docs/runbook.md` §8 |
| anything owed on hardware | `docs/development/open-checks.md` |

## Commands

All from the repository root (or the worktree's root).

```bash
./scripts/check                     # the gate: all twelve steps, exactly what CI runs
./scripts/check test                # just the unit tests, for a quick pass
swift test --filter <TestName>      # one test or test case
bash Scripts/bundle.sh release      # assemble and sign build/app.noindex/Isla.app
bash Scripts/publish-dev-update.sh  # publish the committed build to the local update feed
                                    # (--dry-run, --enable, --replace)
bash Scripts/install.sh             # replace /Applications/Isla.app and open it (bootstrap only)
bash Scripts/rehearse-update.sh     # build a fake next version to rehearse Update Now
```

By hand, never as gates: `Scripts/measure-idle.sh` (the running app's cost at
rest), `Scripts/measure-hitches.sh` (frame timing under a real
`NSApplication.run()`), `Scripts/measure-performance.sh` against a Cyclop build
from `Scripts/build-reference.sh`, `Scripts/measure-sync.sh` (lyric position
accuracy against a live player), `Scripts/visual-lab.sh` (headless renders),
`Scripts/clean-test-plists.sh` (counts empty test preference files; `--apply`
moves them aside).

Run SwiftPM and `git commit` with the agent sandbox off: SwiftPM's own sandbox
and a worktree's git index are blocked inside it.

## Definition of done

Done means `./scripts/check` ran and passed and the owner saw the output. Its
twelve steps, in order: `test` (`swift test`), `provenance` (upstream pin and
MIT attribution), `branding` (no "cyclop" and no former "Dynamic Island"
identity), `localizations` (en/ru key parity, plutil-clean), `bundle`,
`identity` (Info.plist name, id, executable, `LSMinimumSystemVersion` 15.0),
`helper` (answers `get` with one line of JSON), `package` (binary, dylib, icon,
both `.lproj`, licenses, App Intents metadata), `gatekeeper` (Developer ID,
`spctl`, stapled ticket, the helper loading under quarantine; skips itself on
an ad-hoc build), `lifecycle` (no helper survives the app), `dmg`,
`next-release` (the release job's version and notes rules in a scratch repo).
CI (`.github/workflows/build.yml`, `macos-26`) runs `./scripts/check` itself.
Per-step logs land in `.check-logs/<step>.log`.

A green build is not the whole of done: what only a notched MacBook can show
is a check in `docs/development/open-checks.md`, and a person runs it.

## After each change

1. **Commit it** on the change's own branch once its checks are green
   (`swift test` for code; the full gate before a merge). Subject: a lowercase
   sentence about what the user gets (`fix: the island stays at the notch
   while locked`); body: the mechanism and the tests that hold it.
2. **Publish it to the local update feed:** `bash Scripts/publish-dev-update.sh`.
   It builds the committed checkout as `VERSION.N`, signs it with the feed's
   own key ("Isla Dev Update Signing" in the login keychain, never the release
   key) and lands it in `.dev-updates` in the main checkout. The running Isla
   offers it on the island within a second or two. It refuses a checkout that
   lacks the feed's last published commit; merge that in.
3. **The owner presses Install on the island.** Do not install it for them.

A docs-only change stops at the commit. `Scripts/install.sh` is only for the
first install of a build that knows the feed, a Mac where the update path
fails, or leaving the channel (`defaults delete com.ctimothe.isla
updates.localFeed`). **Never `open` the bundle in `build/`**: each launch from
there registers another Isla with LaunchServices, and any of them can catch
the Spotify sign-in callback. The build lives in `build/app.noindex/` so
Spotlight skips it.

**Merging to `main` ships to every user.** CI (`.github/workflows/release.yml`)
versions, signs and releases every merge that changes the app, and every island
offers it within the hour. A change that is committed, published to the feed
and installed here is not shipped: say so when holding it, and ask once per
working session whether to merge the batch.

## Architecture

Detail and numbers are in `docs/development/spec.md`; this is the shape and
the reason for each invariant.

- **Shell.** A borderless, non-activating `NSPanel` (`NotchPanel`) hosts
  SwiftUI. Level `CGWindowLevelForKey(.statusWindow) + 1`
  (`NotchPanel.normalLevel`; the lock path reads it back, so change it there
  only). `.canJoinAllSpaces`, `.stationary`, `.fullScreenAuxiliary`,
  `.ignoresCycle`. `canBecomeMain` is always false; `canBecomeKey` only while
  Clipboard or Translate asks for the keyboard (`Surface.takesKeyboard`) or a
  Settings shortcut field records, so looking at Isla never takes typing from
  the app in front. The app is `.accessory`, set once in
  `IslaApplication.run()` and never changed: no Dock icon, no menu-bar item, no
  window. `NotchController` owns the panel's lifecycle, geometry, open and
  close timing and the lock transition; `AppDelegate` owns the four global hot
  keys (`HotKeyCenter`), the "Translate in Isla" service and the Spotify
  URL-scheme callback.
- **Window sizing.** The window is cut once to the tallest body any surface
  can ask for and never resized; it is transparent outside the island, and
  what is clickable is `activeRect` on `NotchRootView`. Resizing across a lock
  produced stretched window-server snapshots, which is also why the lock card
  is its own `LockCardWindow`. Constants in `NotchMetrics`, derived rects in
  `NotchGeometry`.
- **Notch detection.** `safeAreaInsets.top > 0`, exact bounds from
  `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`; a synthetic notch on
  displays without one. Never use `NSScreen.main` (meaningless for a panel that
  never activates); recompute on `didChangeScreenParametersNotification`.
- **The island.** `IslandActivity.current` picks one activity by rank (alerts,
  then live activities: timer, stopwatch, music, recording, downloads, Shelf);
  a second live activity waits as the bubble. A click follows the rank
  (`NotchViewModel.openTarget`). The outline's fill, mask, line and shadow are
  `CAShapeLayer`s animated by the render server (`IslandOutlineHost`), so a
  stalled main thread does not freeze a morph already begun.
- **Surfaces.** One at a time (`NotchViewModel.Surface`): four pages (Music,
  Shelf, Clipboard, Translate) turned by dots, a swipe (`PageSwipe`) or ⌃Tab,
  and the stage, Settings, the drop surface and the welcome below them. No
  tabs, no rail. `SurfaceContractTests` asserts every surface and every road to
  it, so neither a removed feature nor a tab can creep back.
- **Lock screen.** `LockScreenPresence` lifts the panel into a SkyLight space of
  its own at absolute level 400, over the lock screen's 300 (private SPI via
  `dlsym`; a missing symbol degrades to hiding the island while locked). Over
  the shield the island is visible but inert; the lock card is the only thing
  that answers clicks.
- **Media path.** MediaRemote's read path is closed to ordinary processes since
  macOS 15.4. `Sources/IslaMediaHelper/helper.m` builds `libislamedia.dylib`,
  loaded into `/usr/bin/perl`; it prints one JSON object per line, takes
  commands on stdin and exits when stdin closes, so it can never outlive the
  app. `NowPlayingFeed` parses it (`NDJSONBuffer`; every `Snapshot` field is
  optional and `commands: nil` means unknown); `MediaController` adds the
  position clock; `PlayerBridge` (AppleScript, Music and Spotify only) is the
  fallback. **The Swift app never links MediaRemote.**
- **Error contract.** Helper failure, malformed JSON or missing resources never
  crash the app or raise a prompt; Music deactivates, the island collapses, and
  `NowPlayingFailurePolicy` backs the restart off.
- **UI.** Translucent surfaces go through `glassSurface(...)`: `glassEffect` on
  macOS 26 where there is a backdrop, `GlassSurface`'s drawn recipe otherwise,
  never both. `SystemAppearance` honours Reduce Transparency and Increase
  Contrast live. Curves, radii and `tracking(forSize:)` live in `Theme`
  (SwiftUI does not track fixed sizes). Glyphs are Hugeicons drawn by
  islandcn's recipes (`IslandGlyph`); other apps' icons come from the installed
  app at runtime (`AppIcons`). Settings rows come from `SettingsTable`, which
  holds every key and default; add a setting there, not in a view.
- **Keys that reach past the panel.** Plain Escape for a pinned panel and the
  Shelf's Delete are transient Carbon hot keys held only while their condition
  stands (`NotchController.updateEscapeHotKey`, `ShelfDeleteKeyHolder`): a
  stuck one would eat that key system-wide. The volume and brightness tap
  (`MediaKeyTap`) keeps its callback to a decode and a write: a slow tap eats
  those keys in every app.
- **Lyrics.** One timeline (`LyricSweep`) and one renderer (`LyricRow`,
  `KaraokeText`) for every surface; do not add another binary search over
  lines. `LyricSweep.readingMoment` alone picks the read-ahead line and
  `readAheadStart` alone says when it turns.
- **Pasteboard.** Only `PasteboardRead` reads the general pasteboard; while a
  read is in flight the main actor asks only for the change count
  (`PasteboardAccessContractTests`).

## Hard constraints

- **Identity.** Cyclop's MIT attribution stays in `THIRD_PARTY_NOTICES.md` and
  ships in the bundle; everything else (name, bundle id `com.ctimothe.isla`,
  paths, icon, copy) is original. `Scripts/test-branding.sh` fails on any
  case-insensitive `cyclop` and on the former product name "Dynamic Island"
  under `Sources`, `Resources` and the named scripts, comments included. The
  descriptive "Dynamic Island–style" lives only in the README; the folder name
  `dynamic-island` is not matched.
- **Localization.** Every user-facing string is in `Resources/en.lproj` and
  `Resources/ru.lproj`; the key is the English text. Use `localized(_:)` for a
  string needed before it reaches a `Text`.
- **Entitlements.** Exactly one, `com.apple.security.automation.apple-events`
  (`Resources/Isla.entitlements`). A Developer ID build adds
  `keychain-access-groups` at bundle time for Spotify tokens. Any other
  entitlement is a product decision.
- **What leaves the Mac.** Anything new that leaves the machine, touches an
  account or changes a system-wide setting defaults to off and is listed in
  spec §17 and the README's Privacy table. The one exception is the update
  check: on, hourly, one request to GitHub naming Isla's version, switchable in
  Settings › About.
- **Signing inputs.** Signing identities, Apple credentials, notarization inputs
  and update keys are release-owner inputs; never commit them.
  `Scripts/release.sh` refuses an unclean tree or missing release notes.
- **Hardware.** A green build does not prove what only a notched MacBook shows.
  Record the Mac model and macOS version when ticking a check in
  `docs/development/open-checks.md`.
- **Removed features stay removed** (spec §22).

## Conventions

- Swift tools 6.0, language mode v5, `platforms: [.macOS(.v15)]`. Almost
  everything is `@MainActor`.
- Large types are split into `Type+Concern.swift` extension files in the same
  folder: stored properties stay in the main file, and a test that reads
  source goes through `SourceText.of(...)`, which joins the main file and its
  extensions.
- Comments are long and explain *why*, usually by naming the bug that motivated
  the code. Match that density; a comment that restates the code is worse than
  none. Some scripts carry Russian comments; leave them in their language.
- Commit subjects are lowercase sentences about the user-visible result; bodies
  explain the mechanism and name the tests that hold the invariant. Merges:
  `Merge feat/<name>: <what the user gets>`.
- Personal repository: commit as `ctimothe`, no attribution trailers, no
  `claude/…` or `codex/…` branch names.

## Verification-only environment hooks

All off unless set (to `1`, or for `DI_UPDATE_REHEARSAL` to a folder); a normal
run never touches disk for them. `DebugTrail` reads each once, at launch; ask
it (`DebugTrail.geometry`, …) rather than the environment.

- `DI_GEOM=1` — geometry trail, the watchdog's samples included, to `/tmp/di-debug.log`.
- `DI_LOCK_PREVIEW=1` — present the lock card without locking the Mac.
- `DI_OPEN_LYRICS=1` — open the lyric stage without a pointer; also writes the trail.
- `DI_OPEN_PANEL=1` — open the panel on the player without a pointer, to film a skip.
- `DI_MEDIA=1` — the media trail alone: every snapshot and hold decision.
- `DI_TEST_CLICK=next` — drive a lyric click from a test.
- `DI_UPDATE_REHEARSAL=<folder>` — Update Now takes its release from
  `<folder>/release.json`; made by `Scripts/rehearse-update.sh`.

Never set these, or launch Isla, while the owner is using the Mac unless the
owner has handed the Mac over for live checks.
