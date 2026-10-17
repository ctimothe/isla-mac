# Tabs in the notch's wings — implementation plan (R6)

> **Withdrawn 2026-10-17 (owner).** Not to be built. The owner chose the
> activities-first round — "Yes, that's the style" — and the spec withdrew §18
> and R6 the same day. Round two is specified in
> `docs/plans/2026-10-15-redesign-spec.md` §19 and planned in
> `docs/plans/2026-10-17-activities-build-plan.md`. This plan stays as the
> record of the wings direction.

> **Paused 2026-10-17 (owner).** Not to be built. After comparing Isla with an
> event-driven notch app, the owner asked for a second canvas round on an
> activities-first model (the island shows what is happening; tools are
> summoned, not tabbed). This section stands as a record until that round
> settles; if the round is chosen, it is withdrawn by a dated amendment.

Date: 2026-10-17. Contract: `docs/plans/2026-10-15-redesign-spec.md` §18 and
the dated notes that point to it; the parity design's 2026-10-17 amendment.
Where this plan and §18 disagree, §18 wins and this plan is fixed.

**Tier 3.** It replaces the shell's navigation, moves every pane's leading
edge, and adds hot keys held while the pointer is on the panel — a key left
registered takes ⌘1 from every app until Isla quits. Pipeline: tests first,
`./scripts/check` green with its output shown, a Codex review
(`codex exec review --base feat/redesign-r5-hud`) and an Opus review, then
commit, `Scripts/bundle.sh release`, `Scripts/install.sh`.

**Branch.** `feat/redesign-wings`, cut from `feat/redesign-r5-hud` (6a77379),
in `.worktrees/redesign-wings`. It merges with the redesign chain; nothing
goes to `main` without the owner. This branch still has the docs layout from
before the 2026-10-17 cleanup (`docs/plans/`, not `docs/development/plans/`);
the merge into `main` moves these files with the rest.

**One implementer at a time.** The tasks touch the same few files, so they
run in order, never in parallel. Tests never drive the live app, never
register a real hot key and never reach a real player.

**Commits.** Tasks 1, 7, 8 and 9 are each their own green commit. Tasks 2–6
are **one change, one commit**: the rail, the header tools, the pane edge and
the welcome all read each other (`Rail.footerGap` in the welcome,
`railIconHeight` in `ExpandedBodyTests`, the header tools at `bw − 39` over
the new Settings tab at `bw − 44`, the panes' literal 206/268/… beside a cover
already at 14), so no subset of them builds green. Work through them in the
order below on the branch, run `swift test` at the end of 6, and commit once.

## Map of what changes

| Area | Files | Today |
|---|---|---|
| Tab groups | `Model/NotchViewModel.swift` (`Tab.contentTabs`, `utilityTabs`, `leftRail`, `rightRail`) | the rail's order |
| Header | `UI/NotchContentView.swift` (`headerRow`, `trailing`, `openHeader`, `islandAccessibility`) | title left, source tag or count right, tools laid over after the Isla element |
| Rail | `UI/NotchContentView.swift` (`struct Rail`, `content`) | vertical column, `PlayerLayout.railWidth`/`railGap` |
| Rail metrics | `Notch/NotchGeometry.swift` (`railSpacing`, `railIconHeight`, `contentHeight`) | icon height from the body's height |
| Pane edge | `UI/PlayerLayout.swift` (`bodyInset`, `railWidth`, `railGap`, `paneLeading`, `columnLeading`, `columnLinesLeading`, `emptyWell`) and `ShelfLayout`, `ClipboardLayout`, `TranslateLayout`, `SettingsLayout` | 58 |
| Header tools | `UI/ClipboardHeaderTools.swift`, `TranslateHeaderTools.swift`, `LyricHeaderTools.swift`, `ExpandHeaderTool` in `NotchContentView.swift`, `ShelfHeader` in `ShelfLayout.swift` | laid over the header's trailing corner |
| Equalizer travel | `NotchContentView.swift` (`MorphID.equalizer` in `trailing` and `compactPlaybackState`) | compact right wing → open header's right end |
| Pane swap | `NotchContentView.panes`, `Theme.paneSwapScales` | opacity + 0.98 scale, no direction |
| Welcome | `UI/WelcomePane.swift` (`legendColumn`, `railIconHeight`) | legend lines level with the rail |
| Keys | `Notch/ShelfDeleteKey.swift` (pattern), `Notch/NotchPanel.swift` (`sendEvent`), `Notch/NotchController.swift` | none for tabs |
| Scroll | `UI/ScrollWheelWatch.swift` (`ScrollSample`), `UI/LyricFollowGate.swift` | lyric column only |
| Prose | `docs/runbook.md` (the rail line, the stale 150 ms dwell), `CLAUDE.md` ("on one rail"), `checklist.md` | the rail |

## Tasks

### 1. Tab groups and the wing layout (pure) — own commit

- `NotchViewModel.Tab`: `leftWing = [.media, .shelf]`,
  `rightWing = [.clipboard, .translate]`, `swipeRun = contentTabs`,
  `utilityTabs = [.settings]`. `leftRail` and `rightRail` stay until task 2
  removes their last readers, so this commit builds.
- New `UI/WingLayout.swift`: `WingLayout.frames(bodyWidth:notchWidth:headerHeight:)`
  → the notch span, the leading slot, and one rect per tab, per §18.2,
  including the fallback (tabs 26 wide when a wing is short, Settings then
  at `bw − 40`). Also `hitRect(for:)` (full `H`, widened into half of each
  shared gap, never on a run's outer ends) and `closesPanel(at:)` (the notch
  span only).
- Tests, `WingLayoutTests` (new): for every bw in {480, 560, 620}, nw in
  {180, 185, 200, 220, 240}, H in {24, 32, 38}: no tab, hit rect or slot
  meets the notch span widened by 8 a side (the band `HeaderNotchBandTests`
  uses); Music outermost on the left, Clipboard innermost on the right,
  Settings ending at `bw − 14`; chips `min(26, H − 4)` tall and centred; 4
  apart; 30 wide everywhere except nw 240 at 480, where they are 26; hit
  rects tile each run with no gap; `closesPanel` true across the notch span
  and false on every tab and on empty wing space.
- `TabContractTests`: assert the two wings, the swipe run and the utility
  tab beside the existing rail checks (those go in task 2).

### 2. The header row carries the tabs; the rail goes — part of one commit

- The tabs are a `WingTabs` view **laid over `openHeader` after
  `islandAccessibility(open: true)`**, the way the header tools are today:
  inside `headerRow` they would be hidden, because that element ignores its
  children. The chip is the rail's `icon(for:)` moved over unchanged (fill,
  edge, filled glyph, hover well, badge, `PanelButtonStyle`,
  `.transaction { $0.animation = nil }`), sized from `WingLayout`, with
  `.help(tab.title)`. One group, "Tabs", Music…Settings order
  (`accessibilitySortPriority`), after the Isla element, before the pane.
- `headerRow` loses the title and `trailing`. Its `onTapGesture` close and
  the Isla element's frame both narrow to the notch span (`closesPanel`).
  The header note above it ("No controls go in this row … Ice") is rewritten
  to say the row now carries the tabs, that menu-bar utilities may see those
  clicks, and that R6-H6 owes the check.
- `content`: the `HStack` with `Rail` goes; `panes` fills the body inside
  `PlayerLayout.bodyInset` on both sides. Delete `struct Rail`,
  `NotchGeometry.railSpacing`, `railIconHeight`, `PlayerLayout.railWidth`,
  `railGap`, `Tab.leftRail`, `Tab.rightRail`; `paneLeading` becomes
  `bodyInset` (14). `Rail.isLit`'s rule moves to `WingTabs.isLit` with its
  test; `Rail.footerGap` moves to `WelcomePane` (task 6 is its only reader).
- Tests: `IslandAccessibilityTests` (tab order, group label, selected trait,
  no tab lit on the welcome, the Isla frame is the notch span);
  `TabContractTests` drops the rail checks; `FirstRunTests` reads
  `WingTabs.isLit`; a render test that the open header at 480/560/620 in
  Russian shows five tabs and no title.

### 3. The leading slot and the equalizer — part of one commit

- The slot (§18.3): the source app icon on the player, Expand / Collapse on
  C, T, Shelf (when `ShelfHeader.showsExpand`), Clipboard and Translate,
  nothing on Settings, the welcome, or Music with no track. Crossfade on the
  tab's curve. `ExpandHeaderTool` re-anchored to the slot; its binding and
  `expandAnimation` unchanged.
- Remove the open end of `MorphID.equalizer`; the compact equalizer leaves
  with the compact content. The cover's travel is untouched.
- The tabs' open/close sequencing (§18.2): in on `paneIn` after the compact
  content's 0.20 s out-curve, out on `paneOut`.
- Tests: `LeadingSlotTests` (new, pure: tab, music page, track, item count,
  welcome → `.sourceIcon | .expand | .collapse | .none`);
  `ArtworkMorphTests` gains "the open header has no equalizer" and keeps the
  cover's two ends; `ExpandedBodyTests` reads Expand's frame from the slot
  and stops reading `railIconHeight`.

### 4. Per-tab tools move into the panes — part of one commit

- Lyrics: Show Translation and More join Output and Lyrics in the pane's
  tool row, packed right with hidden ones closing up — C at y 169 ending at
  x 204, T at y 351 ending at `bw − 19` on a 30 pitch, T's progress ending
  12 before the leftmost visible tool. Menus (`lyricsTranslateMenu`,
  `lyricsMoreMenu`), the right-click/long-press translation menu and the
  hidden-when-off rule unchanged. `LyricHeaderTools` becomes the row's view,
  not an overlay.
- Clipboard: Search to (`bw − 36`, 44) at the filter row's end; the row runs
  to `bw − 44`; the search field takes the same row. `ClipboardHeaderTools`
  loses Expand.
- Translate: History to (`bw − 36`, `H + 8`) while Keep History is on; the
  pair bar ends at `bw − 44`, or `bw − 14` with History hidden.
  `TranslateHeaderTools` loses Expand.
- Shelf: the count leaves the header for the bar's no-selection state at
  `h − 37`: "%d items", the hint from 540 up, Clear.
  `ShelfHeader.countClearance` goes.
- Tests: `HeaderNotchBandTests` is rewritten to assert the header row holds
  nothing but the slot and the tabs; its per-tool cases move to
  `PlayerLayoutTests`, `MediaPaneLayoutTests` and `LyricColumnPaneTests` (C
  and T tool rows with all four tools, without Show Translation, without
  Output), `ClipboardLayoutTests`, `TranslatePaneLayoutTests` and
  `ShelfPaneTests` (the bar's three states), each at 480/560/620 in Russian.

### 5. Pane coordinates — part of one commit

- Apply §18.6: player, C, T, Clipboard list, Translate (today's split rule
  with `sourceBonus`, now over `bw − 28`), Settings sidebar and form (318
  below 540), Shelf from 14 on the **fixed** 82 pitch (no spread gap:
  `tileIndex(at:)`, `tileFrame` and `contentHeight` hit-test against it).
- Tests updated for the new numbers: `PlayerShellLayoutTests` (stops
  reading `railGap`), `PlayerLayoutTests`, `PlayerStatesLayoutTests`,
  `LyricColumnPaneTests`, `MediaPaneLayoutTests`, `ShelfLayoutTests`
  (5/6/7 columns, `tileIndex` at all three widths), `ClipboardLayoutTests`,
  `TranslatePaneLayoutTests`, `SettingsLayoutTests`, `SettingsFormTests`
  (318 and `bw − 162`), `VisualLabPanelTests` — each at 480/560/620 with the
  Russian table, asserting no control truncates. Grep `Tests/` for `58`,
  `206`, `268`, `122` and `paneLeading` before calling it done.

### 6. The welcome — part of one commit; commit 2–6 here

- `WelcomePane.legendColumn`: one line per tab in Music…Settings order, each
  led by its tab's glyph (14 pt, tertiary), Settings after the footer gap; no
  positional tie to any tab. `railIconHeight` leaves its initializer.
- Tests: `FirstRunTests` keeps measuring both columns in both languages at
  480 against the 154 pt body, and asserts each line's glyph is its tab's.
- `swift test` green; commit tasks 2–6 together.

### 7. The pane swap's direction — own commit

- `Theme.paneSwap(from:to:reduceMotion:)` → offsets and opacity: going to a
  tab further right (Settings rightmost), the old pane −12 and the new +12
  on entry; going left, mirrored; Reduce Motion → no offset. `paneSwapScales`
  goes. The direction is stored on the model **before** `tab` changes, so
  the removal transition carries this switch's direction.
- Tests: `PaneSwapTests` (new): sign for every pair, Settings rightmost, zero
  under Reduce Motion, and two switches in a row carry their own directions.

### 8. Two-finger swipe — own commit

- New `UI/TabSwipe.swift`: a pure recogniser over `ScrollSample`s that
  decides once, at the first sample with `|Σdx| ≥ 24` or `|Σdy| ≥ 10`:
  horizontal if `|Σdx| ≥ 24` and `|Σdx| > 2·|Σdy|`, else vertical. Answers
  `.pass`, `.switch(to:)`, `.nudge(direction)` at an end, then `.swallow` for
  the rest of a horizontal gesture including momentum; phase-less samples
  always `.pass`.
- Wiring: one local `scrollWheel` monitor on the open body (the
  `ScrollWheelWatch` pattern, installed with the view, removed with it) that
  returns the event for `.pass` and nil for `.switch`, `.nudge` and
  `.swallow`; refused (always `.pass`) while locked, on the welcome, on
  Settings, while `pressIsHeld()`, or with a menu or sheet up. The nudge is
  6 pt on `openAnimation`, none under Reduce Motion.
- Tests: `TabSwipeTests` (new, pure: the decision at the boundary in both
  axes, one switch per gesture, no wrap, the nudge, momentum swallowed,
  wheels passed, every refusal); `LyricFollowGateTests` gains a swipe made
  of mixed samples (some mostly vertical) that does not stop the follow.

### 9. ⌘1…⌘4 and ⌘, — own commit

- `NotchViewModel.claimsTabKeys(panelOpen:pointerOnPanel:panelHasKeyboard:appIsActive:locked:)`
  → `panelOpen && pointerOnPanel && !panelHasKeyboard && !appIsActive && !locked`.
  No `pinned` term (§18.4 says why).
- New `Notch/TabKeyHolder.swift` on `ShelfDeleteKeyHolder`'s shape: five
  bindings, one group, `update(wanted:)` idempotent both ways, the claim
  re-asked on every input that feeds it (pointer, open, keyboard, active
  app, lock), `teardown()` on close, lock, rebuild and quit, a `Registrar`
  seam. A press calls `chooseTab`.
- `NotchPanel.sendEvent`: while the panel has the keyboard, ⌘1…⌘4 and ⌘,
  choose the tab before the text view sees them.
- The keys are fixed, not recordable, and not listed in Settings ›
  Shortcuts, which holds only the three global ones.
- Tests: `TabKeyTests` (new): the claim's truth table; a fake registrar sees
  five registrations once however often `update(true)` runs, none after each
  road out, and none while the claim's inputs say pointer away, keyboard,
  active or locked; `PanelKeyRoutingTests` gains the key path while the
  panel has the keyboard.

### 10. Verify, review, ship to the device

- Prose: `docs/runbook.md` (the rail line; the 150 ms dwell, withdrawn
  2026-09-21), `CLAUDE.md` ("on one rail" → the wings), `checklist.md`
  §"Redesign — 2026-10-15" gains R6 and R6-H1…H6.
- `./scripts/check` in full; show the output.
- Codex review against `feat/redesign-r5-hud`, then an Opus reviewer at
  high effort told to refute: the notch-span close and the Isla element's
  frame, the hot-key lifetime, the swipe against the lyric follow, the Shelf
  drag and scrubbing, and §18.6 at 480 in Russian.
- Commit; `bash Scripts/bundle.sh release`; `bash Scripts/install.sh`; prove
  the running binary with `pgrep`.

## Not in this plan

- Recordable tab shortcuts, a sixth tab, or a Settings switch for the swipe:
  none is asked for.
- The lock card and its foot rail, the compact island, the peek and the
  volume pop-up (§18.6's last line).
