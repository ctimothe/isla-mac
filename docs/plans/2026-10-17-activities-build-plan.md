# Activities first — build plan (R7–R10)

Date: 2026-10-17. Contract: `docs/plans/2026-10-15-redesign-spec.md` §19,
decisions 15–17 and the dated notes that point to §19; the parity design's
second 2026-10-17 amendment. Where this plan and §19 disagree, §19 wins and
this plan is fixed. Reference: the private navigation canvas
`8dfB3WZszjMw7Gmjw587NZ`, version 16, boards `R2-*`.

**Tier 3.** It replaces the shell's navigation and the island's shape and
motion, adds a fourth global hot key, puts text on the person's clipboard,
changes when the panel may take the keyboard, and replaces the lock screen's
presentation. Every release: tests first, `./scripts/check` green with its
output shown, a Codex review (`codex exec review --base <previous release
branch>`) and an Opus review (high effort; xhigh for the final whole-chain
review), then commit, `bash Scripts/bundle.sh release`, `bash
Scripts/install.sh`, and a `pgrep` that proves the new build is the one
running.

**DynamicNotch stays outside.** It is GPL-3.0 and Isla is MIT. Nobody who
builds this reads DynamicNotch's source, copies its images or icons, or reuses
its text. Every value needed is in §19; everything drawn uses SF Symbols,
SwiftUI shapes and Isla's own strings. A reviewer who finds DynamicNotch-derived
code or assets in a diff fails the release.

**Branches.** A chain, each cut from the previous one, in its own worktree
under `.worktrees/`:

| Release | Branch | Cut from |
|---|---|---|
| R7 | `feat/redesign-r7-island` | `feat/redesign-activities` (this spec, on the R5 chain and its release keys) |
| R8 | `feat/redesign-r8-surfaces` | R7 |
| R8b | `feat/redesign-r8b-pages` | R8 *(added 2026-10-18, decision 18)* |
| R9 | `feat/redesign-r9-alerts` | R8b |
| R10 | `feat/redesign-r10-lock` | R9 |

None merges to `main` without the owner; the redesign chain R1–R5 is still
unmerged and merges with it. These branches still have the docs layout from
before the 2026-10-17 cleanup (`docs/plans/`, `checklist.md` at the root); the
merge into `main` moves them with the rest. A fresh worktree needs its
dependencies resolved before `./scripts/check`, which otherwise exits 2.

**One implementer at a time.** Tasks inside a release touch the same few files
(`NotchContentView`, `NotchViewModel`, `NotchController`, `Theme`), so they run
in order, never in parallel. A task that cannot build green alone is committed
with the next one, and the plan says where. Tests never drive the live app,
never register a real hot key, never write to the general pasteboard (only a
named test pasteboard), never reach a real player or the network, and never
read the real battery.

**Model and effort for delegated work** (the global table): a spelled-out
transcription task — Sonnet medium; a task that must decide layout or timing
not written here — Opus medium; reviews — Opus high; anything touching the
lock, the keyboard rule or the clipboard — the driver or Opus high, never
Haiku.

## Map of what changes

| Area | Files | Today | After |
|---|---|---|---|
| The outline | `UI/NotchShape.swift`, `UI/KeyLine.swift`, `UI/Theme.swift` (radii at 526–540, `keyLineWidth` 723) | circular fillets, a 1 pt key line on dark wallpapers | §19.2's quadratic path, a 2 pt stroke at 0.21 / 0.14, a shadow above 68 |
| Motion | `UI/Theme.swift` (springs 4–260, `criticallyDampedSprings` 143) | every spring critically damped | `islandSpring` 0.5 / 0.75 for the shape, `expandedArrival`, `compactArrival` |
| Ranks | `Model/HUDMoment.swift` (`IslandMoment` 132–143), `Model/NotchViewModel.swift` (`bodySize` 1357–1381) | HUD > ambient > peek > none, each its own path | one pure `IslandActivity` ranking (§19.1) the view model reads |
| Compact sizes | `Notch/CompactIslandLayout.swift`, `Notch/NotchMetrics.swift` (`compactMediaExtension` 40, `ambientNameExtension` 127, `sneakPeekExtension` 113) | notch + 80, 208 for names | §19.4's `nw + ΔW`, the expanded widths with their `nw + 20` floor |
| Moments | `Model/AmbientActivity.swift`, `Services/AmbientWatch.swift`, `Services/MediaKeyHUD.swift`, `UI/NotchContentView.swift` (`ambientHeader` 640, `hudHeader` 688) | compact charging and headphones, a 428 pt HUD | Charging compact; headphones and volume as §19.5 c and d |
| The bubble | new `UI/IslandBubble.swift`; `Notch/NotchRootView.swift` (`activeRect` 20, `hitTest` ~114); `Notch/NotchController.swift` (`applyActiveRect` ~2405) | — | §19.7's bubble inside the window and `activeRect` |
| Navigation | `Model/NotchViewModel.swift` (`Tab` 7–73, `tab` 283, `select` 1872, `clickOpened` 609, `openBodyHeight` 393–405, `expandedTabs` 365), `UI/NotchContentView.swift` (`Rail` 1309, `panes` 1165, `pane` 1206) | five tabs on a rail, per-tab height and expansion | a `Surface` enum (player, stage, tray, drop, tools, clipboard, translate, settings, welcome), each with one size; no rail |
| Player and stage | `UI/MediaPane.swift`, `UI/PlayerLayout.swift`, `UI/LyricsStage.swift`, `UI/LyricHeaderTools.swift`, `UI/LyricsPageModel.swift` | player / column / tall | §19.6's player and lyrics stage, one lyric renderer |
| Shelf | `UI/ShelfPane.swift`, `UI/ShelfLayout.swift` (`ShelfDropTarget` 620), `Notch/NotchController.swift` (drag 1269–1311) | a grid and a selection bar | the drop surface and the tray |
| Tools, menu | new `UI/ToolsSurface.swift`, new `Notch/IslandMenu.swift` | no island menu; only the right-mouse outside-click monitor at `NotchController.swift:1024` | §19.8's Tools, §19.9's `NSMenu` |
| Clipboard, Translate, Settings | `UI/ClipboardPane.swift`, `UI/ClipboardHeaderTools.swift`, `UI/TranslatePane.swift`, `UI/TranslateHeaderTools.swift`, `UI/SettingsPane.swift`, `UI/SettingsTable.swift`, `UI/SettingsSidebar.swift`, `Notch/NotchPanel.swift` | tabs with a header title, leading edge 58 | summoned surfaces, leading edge 16; Clipboard takes the keyboard |
| Hot keys | `App/HotKeys.swift` (`HotKeyAction` 6, defaults 37–39, `HotKeyCenter` 191), `App/AppDelegate.swift` (install 78–88) | ⌃⌥⌘I, L, T | + ⌃⌥⌘V Show Clipboard |
| New alerts | `Services/AmbientWatch.swift` (`readPower` 126), new `Model/BatteryAlerts.swift`, `Services/UpdateCheck.swift`, `Services/UpdateInstaller.swift`, `Notch/NotchController.swift` (`translateCommanded` 787) | — | §19.5 a, b, e, f |
| Lock | `Notch/LockCardWindow.swift`, `UI/LockScreenCard.swift`, `UI/LockCardMaterial.swift`, `Notch/LockScreenPresence.swift`, `UI/SettingsLockStyle.swift` | the banner and the card | Full Screen by default, the card as Layout › Card |
| Strings | `Resources/en.lproj/Localizable.strings`, `Resources/ru.lproj/Localizable.strings` | — | §19.14, per release |
| Repo docs | `CLAUDE.md` (Repository layout, Shell, Interaction, UI paragraphs), `checklist.md` §"Redesign — 2026-10-15" | five tabs on one rail, critically damped springs, Translate alone takes the keyboard | updated in R7 and R8 as the code changes |

Line numbers are those on `feat/redesign-activities` at 4c5130f; read the code
before trusting them.

## R7 — The island and its activities

Done when §19.1–§19.4, §19.5 c and d and §19.12 hold, the open panel still
works through today's tabs (R8 replaces them), and R7-H1…H5 are listed in
`checklist.md`.

**Task 1 — the outline.** Tests first in a new `IslandOutlineTests`: the path
for each reference shape (225.4 × 38 at 8.67 / 12.67; 425.4 × 198 at 34 / 44;
325.4 × 113 at 22 / 40) has its shoulder control points on `y = 0` and its
bottom control points on the corners; `animatableData` interpolates both
radii; the stroke path has no top segment. Then rebuild `NotchShape.openPath`
on the quadratic construction and replace `KeyLineShape`'s 1 pt dark-only line
with the 2 pt centred stroke (`IslandStroke`: tint at 0.21, white 0.14; 0.42 /
0.30 under Increase Contrast through `SystemAppearance`). `KeyLineTests`
becomes `IslandStrokeTests`; the wallpaper gate leaves the island
(`WallpaperTone` stays for `LockCardMaterial`). Shadow above 68 tall. Commit.

**Task 2 — the spring and the arrivals.** Tests first in `MotionValuesTests`
and `ReduceMotionContractTests`: `Theme.islandSpring` is response 0.5,
damping 0.75; `expandedArrival` is blur 30, scale (0.6, 0.2) at (0.5, 0.4);
`compactArrival` blur 15, scale x 0.8; their Reduce Motion forms are 0.24
crossfades with no blur or scale; `criticallyDampedSprings` no longer lists
the shape's curves and still lists every content curve. Then add them to
`Theme` with a comment naming §19.3 and why the island alone overshoots.
Commit.

**Task 3 — ranking.** Tests first in a new `IslandActivityTests`, pure (no
view, no timer): §19.1's table as `IslandActivity.current(...)` over Music,
Shelf, the HUD, headphones, charging and the peek (R9 adds its alerts to the
same function); a higher alert replaces a lower; an equal one replaces the
older; the 1 s drop rule with its two exceptions, on an injected clock; the
bubble only beside a compact live activity. Then replace `IslandMoment`'s
three-way choice (`HUDMoment.swift:132`) with it and route
`NotchViewModel.bodySize` through it. `HUDMomentTests` and
`AmbientMomentTests` keep their assertions where §19 did not change them.
Commit.

**Task 4 — compact sizes and content.** Tests first in
`CompactIslandLayoutTests`: Music `nw + 70`, Shelf `nw + 75`, Charging
`nw + 180` at every `nw` in §19.12; the cover at (17.3, 8), 22 × 22; the
equalizer 18 × 18, six bars of 2.2, ending right 19.3; Shelf's count ending
right 18.3; Charging's text and drawn battery; the `H` 24 forms; expanded
widths floored at `nw + 20`. Then `NotchMetrics` (the extensions become §19's
deltas, with a comment pointing to §19.4), `CompactIslandLayout`,
`CompactEqualizer` (six bars), and the compact branches of
`NotchContentView.header`. The test
`testTheCoverAndTheEqualizerSitOnEightPointMarginsAtEveryNotchWidth` is renamed
for what it now asserts. Commit.

**Task 5 — headphones and volume restyled.** Tests first: the headphones alert
at 370.3 × 95 with its glyph, "Connected", the name's truncation and no ring
(the ring is R9's); the volume alert at 245.4 × 103 with the name, the bar at
(69.5, 76.5) 107 × 8, the number 0–100, muted at white 0.32 with no glow,
"Display Brightness" and "Keyboard Brightness"; both at `nw` 180 and 240. Then
`ambientHeader` and `hudHeader` in `NotchContentView`, and the §19.14 rows they
use. `MediaKeyHUDTests` and `SystemVolumeTests` are unchanged. Commit.

**Task 6 — the bubble.** Tests first: its frame (58 × `H`, 16 right of the
island), its content and label, its absence during an alert, a surface and the
lock, and `activeRect` containing it while it shows and not after
(`CompactHitAreaTests`, `CompactGestureRectTests`). Then `UI/IslandBubble.swift`,
hit-testing in `NotchRootView`, and `NotchController.applyActiveRect`. Until
R8 a click on it opens today's Shelf tab. Commit.

**Task 7 — docs and the gate.** `CLAUDE.md`'s UI paragraph: "Springs are
critically damped" gains "except the island's outline (spec §19.3)", and the
key-line wording follows Task 1. The checklist gains R7-H1…H5.
`./scripts/check`, reviews, fixes, commit, bundle, install.

## R8 — Surfaces without tabs

Done when §19.6–§19.9 and §19.11 hold, nothing draws a rail or a tab,
`TabContractTests` is replaced by `SurfaceContractTests`, and R8-H1…H6 are
listed.

**Tasks 1–5 are one change and one commit.** Removing `Tab` breaks every pane
and its tests at once; no subset builds green. Work through them in order on
the branch, run `swift test` at the end of task 5, and commit once.

**Task 1 — the surface model.** Tests first in a new `SurfaceContractTests`,
written from §19.1's two tables: every surface and every road to it; what a
click opens for every rank; the removed features (Snippets, Calendar, Notes,
the Teleprompter) absent, as `TabContractTests` asserted; `PrivacyMode`'s
sections still Clipboard and Translate. Then `NotchViewModel.Tab` becomes
`Surface`, `select(_:)` becomes `open(_:)`, `clickOpened` follows the rank,
`openBodyHeight` returns each surface's one height, and `expandedTabs`,
`musicPage` and the Expand button go. `AppSurfaceContractTests` keeps its
assertions (no Dock icon, no window); its comment's "the panel's own Settings
tab already carries Open Panel, About and Quit" is rewritten for Settings and
the menu.

**Task 2 — the player and the stage.** Tests first in `PlayerLayoutTests`,
`PlayerStatesLayoutTests` and a new `LyricsStageLayoutTests`: §19.6's frames;
the sung line in the subtitle and "Title · Artist"; Favourite only with a
bridge that can act (a fake `PlayerBridge`); the stage at 480, 560 and 620 in
Russian; the More menu with Shuffle and Repeat; Hide Lyrics back to the
player. Then `MediaPane`, `PlayerLayout`, `LyricsStage` (one renderer —
`LyricSweep` and `LyricRow` unchanged) and `LyricHeaderTools` moving into the
foot.

**Task 3 — the Shelf.** Tests first in `ShelfLayoutTests`, `ShelfDropTests`,
`ShelfPaneTests` and `ShelfAccessibilityTests`: the drop surface's targets and
lit state; the tray's tiles, their sideways scroll past four, the badge on
hover and selection, Remove All's confirmation, the empty line; Delete and
Quick Look still through `ShelfDeleteKeyHolder`. Then `ShelfPane`,
`ShelfLayout`, and `NotchController`'s drag path (`onDragEntered` opens the
drop surface instead of `showShelfForDrag`).

**Task 4 — Tools, Clipboard, Translate, Settings.** Tests first: Tools' cards
and previews (the newest clip behind the privacy cover); Clipboard's frames
and keyboard — typing, ↑ ↓, ↩ copies and closes, Escape — and
`NotchPanel.canBecomeKey` true only for Clipboard and Translate
(`PanelKeyRoutingTests`); Translate's frames; Settings' leading edge at 16 and
its form 316 wide below 540 (`SettingsPaneTests`, `SettingsTableTests`,
`SettingsWayfindingTests`); the Tools button on each. Then
`UI/ToolsSurface.swift`, `ClipboardPane`, `TranslatePane`, `SettingsPane`,
`SettingsSidebar`, and `NotchPanel`'s key rule.

**Task 5 — the shell.** `NotchContentView`: `Rail`, the header titles and the
per-tab header tools go; `panes` switches on `Surface`; the welcome's legend
becomes §19.8's four lines (`WelcomePane`). `ExpandedBodyTests`,
`HeaderNotchBandTests`, `PanelWidthTests` and the `VisualLab*Tests` follow.
Run `swift test`; commit tasks 1–5 together.

**Task 6 — the menu.** Tests first in a new `IslandMenuTests`: the items in
order, Lyrics enabled only while a song plays, the shown keys equal to
`HotKeyCenter`'s bindings, no item holding a key of its own, refusal over the
lock (`LockedIslandIsInertTests`), and a right-click on an open surface's
header row opening it. Then `Notch/IslandMenu.swift` and the right-mouse
handling in `NotchRootView`. Commit.

**Task 7 — ⌃⌥⌘V.** Tests first in `HotKeyTests`: `HotKeyAction.showClipboard`
with the default `kVK_ANSI_V` and `defaultModifiers`, rebindable through
`ShortcutRecorder`, installed and released with the rest, using the fake
registrar the file already has. Then `HotKeys.swift`, `AppDelegate`'s install
list and the Shortcuts row. Commit.

**Task 8 — docs and the gate.** `CLAUDE.md`: the Repository layout's "Five
tabs ship … on one rail" and its `TabContractTests` line, the Shell
paragraph's "while the Translate tab asks for the keyboard" and its three hot
keys, and the Interaction paragraph, rewritten for §19. Checklist R8-H1…H6.
Gate, reviews, commit, bundle, install.

## R8b — Pages and dots

*Added 2026-10-18 (owner, decision 18).* Contract: spec §19.16 and the dated
notes it left in §19.1 and §19.6–§19.11. Branch `feat/redesign-r8b-pages`, cut
from R8 (`e003969`), worktree `.worktrees/redesign-r8b-pages`; R9 is then cut
from R8b, not from R8. Line numbers are those at `e003969`.

Done when §19.16 holds, `Surface.tools` and `ToolsSurface` are gone, every
road in §19.16's table is a test, and R8b-H1…H8 are listed in `checklist.md`.

**Tasks 1–2 are one change and one commit.** Removing Tools breaks the gear's
routes, the welcome and their tests at once.

**Task 1 — the page model.** Tests first in `SurfaceContractTests`: the page
order (`Surface.pages == [.player, .tray, .clipboard, .translate]`); every
road in §19.16's table; Tools absent with the removed features; the bare notch
with no song opening the last page shown, Music at launch; a song, playing or
paused, still opening Music. Then `Model/Surface.swift`: `.tools` leaves the
enum (13), `reachable` (17), `title` (27), `symbol`, `hasToolsButton` (52,
becomes `hasGear`) and `SurfaceLayout.bodySize` (168–184, `toolsWidth` /
`toolsHeight` go; each page's height + 16); `openTarget` (106) takes the last
page. `Model/NotchViewModel.swift`: `surface`'s default (243) becomes
`.player`; a `lastPage` held for the launch, set whenever a page is presented;
`turnPage(to:)` beside `open(_:)` (1849), which presents a page without
setting `wantsKeyboard`; `openSettings(at:)` remembers the page or stage to go
back to. `ToolsSurfaceTests` is deleted with `UI/ToolsSurface.swift`.

**Task 2 — the gear.** Tests first in `HeaderNotchBandTests` and a new
`PageGearTests`: the gear's frame on every page and the stage at `bw` 480, 560
and 620 and `nw` 180–240; the update badge; lit on Settings; a second click
going back; the tray's Remove All ending 8 before the gear's well and the
tray's minimum width counting it. Then `UI/NotchContentView.swift`'s header
switch (935–960): `toolsButton` (966) becomes the gear, and the player and the
tray gain it; `ShelfPane`'s header. The welcome's second line
(`UI/WelcomePane.swift`) and its strings. Run `swift test`; commit tasks 1–2.

**Task 3 — the swipe.** Tests first in a new `PageSwipeTests`, all on a pure
`PageSwipe` value fed (phase, Δx, Δy, momentum, precise, time) and the pages'
widths: the 10 pt direction lock; a vertical start never paging for the rest
of the gesture; a phaseless or imprecise event ignored; momentum events after
release ignored; 1:1 travel inside the pages and `rubberband(…, 0.55)` past
both ends; the projection (0.998) choosing at most one page; a new gesture
during a settle starting from the presented offset; the strip-edge rule given
the strip's "at its end" as an input. `SurfaceLayout` gains the outline's size
between two pages at a travel fraction, tested at 0, 0.5 and 1. Then a new
`UI/PageSwipeMonitor.swift` — a local `.scrollWheel` monitor in the manner of
`UI/ScrollWheelWatch.swift`, installed only while a page is presented and the
pointer is inside `activeRect`, passing every event it does not consume —
and the paging container in `NotchContentView.panes` (1197): the two pages
side by side, clipped by the outline, offset by the travel; the settle on
`Theme.islandSpring` (ease-in-out 0.24 under Reduce Motion) with the release
velocity handed over. `ShelfPane`'s strip (88) reports whether it is at an
end. Commit.

**Task 4 — the dots.** Tests first in a new `PageDotsTests`: the row's frame
on every page (centre 10 above the bottom; 6 pt dots on a 14 pt pitch), the
14 × 20 hit targets, the tooltips, the VoiceOver value "Page %d of %d, %@" in
English and Russian and its increment and decrement, white 0.90 / 0.30 /
0.45, a dot click turning the page without the keyboard, the crossfade under
Reduce Motion. Then a new `UI/PageDots.swift` placed by the paging container.
`activeRect` (`Notch/NotchRootView.swift:23`) already follows the outline;
the test asserts it covers the row. Commit.

**Task 5 — the keyboard.** Tests first in `PanelKeyRoutingTests`,
`ClipboardKeyboardTests` and `KeyboardAndMenuCloseTests`: a swipe or a dot to
Clipboard or Translate leaves `NotchPanel.canBecomeKey` (`Notch/NotchPanel.swift:28`)
false; ⌃⌥⌘V and a click into the field make it true; leaving the page lowers
it; ⌃Tab and ⌃⇧Tab turn the page while the panel has the keyboard and are
ignored over the lock. Then `NotchViewModel.consumeListKey` (1924) and the
panel's key routing. Commit.

**Task 6 — docs and the gate.** `CLAUDE.md`'s Interaction paragraph (pages,
dots, the gear; no Tools) and its Shell paragraph if the keyboard rule's
wording changes; `checklist.md` R8b-H1…H8 and a Built line; spec §19.15 gains
any technical question the swipe raised. Gate with the xctest domain set
aside, `codex exec review --base feat/redesign-r8-surfaces` (never alongside
the gate: both take the SwiftPM lock), an Opus review at high effort, fixes
test-first, commit, `bash Scripts/bundle.sh release`, `bash
Scripts/install.sh`, `pgrep`.

## R9 — New alerts

Done when §19.5 a, b, e and f hold, §19.15's MagSafe and headphone-battery
questions are answered in the spec, and R9-H1…H5 are listed.

**Task 1 — answer §19.15 first.** A read-only spike, no UI: does
`IOPSCopyExternalPowerAdapterDetails` name MagSafe on macOS 15 and 26 (record
the dictionary on this Mac); is a connected Apple headphone's battery readable
without a new permission, entitlement or private framework. Both answers go
into §19.15 as a dated amendment before any code depends on them.

**Task 2 — battery alerts.** Tests first in a new `BatteryAlertsTests`, pure
over a sequence of power readings: 20 % and 10 % once per discharge, reset on
power; Low Power Mode's line; Fully Charged once per charge, not at an
optimised 80 %, reset on unplugging or below 95 %; MagSafe only for a fixture
the detector names; nothing on a Mac without a battery. Then
`Model/BatteryAlerts.swift` fed by `AmbientWatch.readPower`, the two views,
the two Settings rows (`island.lowBattery`, `island.fullBattery`), and the
"Charging" → "Charger Connected" rename in `SettingsTable` (190) and both
string tables. Commit.

**Task 3 — Translated.** Tests first in a new `TranslateCommandTests`: success
puts the translation on a named test pasteboard and keeps the original as the
history's newest entry; failure copies nothing and shows the reason;
`admitsCommandedOpen`'s refusal over the lock is unchanged; a click opens
Translate with both texts. Then `translateCommanded` (787) presents the alert
instead of opening the tab. Commit.

**Task 4 — the update choice.** Tests first in `UpdatePresentationTests`: once
per version, only at an idle moment, Later and the 20 s timeout both
remembering the version, Install calling a fake installer, the gear's badge
staying. Then the alert, wired to `UpdateCheck.hasUpdate` and
`UpdateInstaller`. Commit.

**Task 5 — the headphone ring**, only if task 1 found a source. Tests first
over fixture readings (green, red below 20 %, absent with none). Commit.

**Task 6 — the gate.** Checklist R9-H1…H5. Gate, reviews, commit, bundle,
install.

## R10 — The lock screen, full screen

Done when §19.10 holds, the Card layout still passes every R2 test, and
R10-H1…H5 are listed. R10-H1 (the unlock controls stay visible and usable) is
checked by the owner on hardware **before** this release merges; if 18 % is
wrong on any Mac, §19.10 is amended first.

**Task 1 — the layout.** Tests first in a new `LockFullScreenLayoutTests`:
every frame as a fraction of 1512 × 982 and 1728 × 1117; nothing inside the
unlock band; the backdrop's fade; the clock row's text in en and ru, 12- and
24-hour, from a fixed date; the lyric ramp's opacity, blur and scale by
distance; the cover centred with no lyrics; the Reduce Transparency and Reduce
Motion forms. Then the view, in `LockCardWindow`'s window, with
`LockCardMaterial` for the glass player.

**Task 2 — hit-testing and the island.** Tests first: only the glass player's
controls hit-test (`LockCardWindowTests`); the Locked compact activity shows
and decision 1 holds (`LockedIslandTests`, `LockedShellLayoutTests`). Then the
window's hit-testing and `IslandActivity`'s Locked rank.

**Task 3 — the setting.** Tests first: `lock.layout` absent → Full Screen;
`card` → §7's banner and card exactly as R2 built them (`LockCardLayoutTests`
unchanged); Rest as Banner hidden under Full Screen. Then `SettingsLockStyle`
and the strings. Tasks 1–3 commit together if task 1 does not build alone.

**Task 4 — the gate and the final review.** Checklist R10-H1…H5. Gate; a Codex
review against R9 and an Opus **xhigh** review of the whole chain R7–R10
against `feat/redesign-activities`; commit, bundle, install.

## Hardware checks, by release

Copied into `checklist.md` §"Redesign — 2026-10-15" as each release is built,
with the tested Mac model and macOS version recorded after each run.

| Check | What the owner looks at |
|---|---|
| R7-H1 | the outline flush with the 14-inch notch at Default and More Space |
| R7-H2 | the overshoot reads as the island growing, not a bounce; Reduce Motion is calm |
| R7-H3 | the stroke on Aerial, Sonoma and a white wallpaper |
| R7-H4 | Music with the Shelf as a bubble; the bubble opens the Shelf |
| R7-H5 | AirPods connecting; the volume keys with Volume and Brightness on |
| R8-H1 | every surface at 480 and 620 in Russian |
| R8-H2 | a Finder drag onto Keep on Shelf and onto AirDrop |
| R8-H3 | ⌃⌥⌘V from Safari, type, ↩, ⌘V back in Safari |
| R8-H4 | the right-click menu over a full-screen app and with Ice running |
| R8-H5 | the sung line in the player on a synced song |
| R8-H6 | Favourite in Music |
| R8b-H1 | a slow and a flicked swipe through all four pages and back, built-in trackpad |
| R8b-H2 | the same on a Magic Mouse |
| R8b-H3 | a wheel mouse: the dots only |
| R8b-H4 | the tray with fourteen files: the grid scrolls down, sideways turns the page, one size for the three tools |
| R8b-H5 | VoiceOver adjusting the dots |
| R8b-H6 | Reduce Motion |
| R8b-H7 | Clipboard reached by a swipe while typing in Safari: Safari keeps the keyboard |
| R8b-H8 | every page in Russian at 480 and 620 |
| R8b-H9 | Music's dot from Clipboard, pointer left still: the panel stays; Settings' X goes back |
| R8b-H10 | a song with timed pauses: the coming line holds under the title, never the artist |
| R8c-H1 | Translate held past the last page and swiped back: no dark band, nothing over the edge |
| R8c-H2 | the gear, the X and a summoned page: one pane at a time, nothing outside the outline |
| R8c-H3 | volume and brightness tapped and held on a busy Mac: no lag, no overshoot, system white |
| R8c-H4 | a flick to the island and an instant click, twenty times: it opens every time |
| R8c-H5 | Music's header names Spotify, Apple Music, Yandex Music and a browser |
| R8c-H6 | tile dates, Remove All beside the gear, one Clipboard control height, Paste in full |
| R8c-H7 | ten 20 MB screenshots copied: memory comes back, the oldest pastes whole |
| R9-H1 | Battery Low at 20 % |
| R9-H2 | Full Battery on MagSafe and on USB-C |
| R9-H3 | the MagSafe light turning green |
| R9-H4 | ⌃⌥⌘T in Mail, then ⌘V |
| R9-H5 | the update choice from a rehearsed release |
| R10-H1 | the password field, the picture and a long name visible and usable, 14- and 16-inch |
| R10-H2 | Touch ID unlock with the layout up |
| R10-H3 | the backdrop with a bright and a dark cover |
| R10-H4 | the output pane from the glass player |
| R10-H5 | lock-screen notifications while the layout is up |
