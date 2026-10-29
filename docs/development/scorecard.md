# Scorecard

The bar every batch of the maturity program is held to
(`plans/2026-10-29-maturity-program.md`). One row per feature, one column per
dimension, 0–4 per cell, and the evidence for the score. A cell with no
evidence scores 0; an owner run counts only with its date, Mac model and macOS
version. Re-scored after every batch; the history stays below the table.

What the numbers mean: **0** nothing shows it; **1** a tool exists to measure
it but no current number, or tests cover a corner; **2** tests cover the main
paths, or one dated measurement exists; **3** tests cover the failure paths
and the settings that change it, and a measurement meets its budget; **4** all
of 3, plus a dated owner run on hardware within the last release.

## Baseline, 2026-10-29 (`feat/maturity-batch-0`)

Scored by the driver from the code on `origin/main` plus Batch 0. Test counts
are `func test` lines in files named for the feature; "AX" counts the
accessibility-probe uses in them. Every surface also passes
`AccessibilitySweepTests` (no nameless control under the standard look,
Reduce Motion, Increase Contrast or Reduce Transparency).

| Feature | Design | Accessibility | Speed | Efficiency | Reliability | Usability |
|---|---|---|---|---|---|---|
| Island and activities | 2 — spec §3, §19; visual lab renders; R7–R8 runs owed | 2 — sweep; 6 AX uses; no VoiceOver run | 2 — `measure-hitches.sh` at idle load, 120 Hz (B0.6, 2026-10-29): opening misses 0.6–2.9 frames of about 125, closing 0.5–1.4, rest none; the bar of none is not met | 2 — idle budget recorded 2026-10-11 (CPU ≤ 0.1 %, RSS ≤ 88 MB), before the redesign | 3 — 210 tests: geometry, notch memory, moments, lock | 1 — runs owed |
| Player | 2 — spec §4; R1 runs owed | 2 — sweep; 5 AX uses | 2 — `measure-mounts.sh`: 7 ms to build empty, 12 ms playing (release, 2026-10-29); a sample puts 97 % of it in SwiftUI's first graph build and no Isla function above 3 % (B3) | 2 — as above, music playing measured | 3 — 374 tests: helper failure policy, seek, hold, favourites | 1 |
| Lyrics and stage | 2 — spec §5 | 3 — sweep; 39 AX uses | 2 — opening on the stage misses 2.2–2.9 frames (B0.6); the stage builds in 15 ms (`measure-mounts.sh`, 2026-10-29); `measure-sync.sh`'s 150 ms p95 target still unmeasured | 1 | 3 — 428 tests: timelines, overrun, offline, 429 | 1 |
| Lock card | 2 — spec §7; R2 runs owed | 3 — sweep; 10 AX uses; picker labels | 1 | 1 | 2 — 116 tests; the private-space path only on hardware | 1 |
| Shelf | 2 — spec §8 | 3 — sweep; 11 AX uses; one card is "1 item" on the island and in Remove All (B3) | 2 — the tray builds in 5 ms (`measure-mounts.sh`, 2026-10-29) | 1 | 2 — 146 tests | 1 |
| Clipboard | 2 — spec §9 | 3 — sweep; 27 AX uses | 2 — 10 ms to build (`measure-mounts.sh`, 2026-10-29) | 1 | 2 — 203 tests | 1 |
| Translate | 2 — spec §11 | 3 — sweep; 22 AX uses | 2 — 12 ms to build (`measure-mounts.sh`, 2026-10-29) | 1 | 2 — 214 tests, offline consent | 1 |
| Settings | 2 — spec §10 | 3 — sweep; 26 AX uses | 2 — `measure-mounts.sh`: 15–32 ms to build a section in release (Lyrics the costliest); no main-thread wait on the login-items daemon after a launch's first opening (B2); the player-to-Settings swap misses 26.8 frames of 125 at idle load, 212 ms of hitch a second, the worst in the app (B0.6) | 1 | 2 — 128 tests | 1 |
| Volume and brightness pop-up | 2 — spec §12 | 2 — `MomentAccessibilityTests`: the island's value for volume, brightness, keyboard and mute, and over a song and the charger (B1) | 2 — a 2 s hold misses 1.8–4.0 frames of 254, folding 0.2 (B0.6) | 1 — the tap's cost unmeasured | 3 — 181 tests: decide per hold, lock, refusal | 1 |
| Charger and headphones | 3 — spec §3.6; the capsule's words held whole in English and Russian against their natural width (B4) | 2 — every charger state with its level, headphones by model (B1) | 2 — the headphones alert misses 0–0.1 frames at idle load (B0.6) | 1 | 3 — `AmbientWatchSequenceTests`: failed reads, a pull before the reading lands, the re-reads, the blip, the 30 s quiet; mutation-checked (B1) | 1 |
| Updates | 2 — spec §19.5 f | 2 — every stage read and answered; the progress bar now reads its percent (B1 fix) | 1 | 1 | 3 — 290 tests: signature, detach by state, swap, rollback | 1 — DU runs owed |
| Welcome | 2 | 3 — sweep; the headline is a heading and is read first, the legend next, Get Started last, held on VoiceOver's own navigation order (B3); fits in both languages | 1 | 1 | 2 — `FirstRunTests`, 23 tests: a pointer crossing, a drag, a screenshot and a shortcut each leave it or retire it as they should; never shown over the lock | 1 |
| Pages and navigation | 2 — spec §19.16 | 2 — sweep; dots read as one adjustable element | 1 | 1 | 3 — 165 tests, `SurfaceContractTests` | 1 |
| On a Mac with Apple's island | — | — | — | — | 2 — `NativeIslandTests`; identifiers unknown | 0 — NI runs owed |

## History

- **B0.6, half of it, 2026-10-29.** `Scripts/measure-hitches.sh` needs no
  running Isla (it builds its own panel at alpha 0.02), so it ran unattended
  at idle load only: load 3.0 on 12 cores, 1800×1169 at 120 Hz, 8 cycles a
  step. Opening misses 0.6–2.9 frames of about 125, closing 0.5–1.4, an
  alert 0–0.1, rest none; a 50 ms main-thread block costs about 7. The
  outlier is Settings: player to Settings misses 26.8 frames (212 ms of
  hitch a second, worst gap 40.7 ms, 105 ms of main-thread CPU), the way
  back 6.8. Speed 1 → 2 for the island, the pop-up and the charger alert;
  Settings stays 2 with its swap named as the app's worst frame drop. The
  stressed and saturated loads were not run (they load every core), and
  `measure-idle.sh` waits for Isla to be running: it had been quit from its
  own menu at 23:50 the night before. The numbers are in the run's JSON,
  `hitches-b06-idle.json`, in the session scratchpad; the table above
  carries every figure it needs.

- **Batch 8, 2026-10-29.** Sittings 4 and 9 searched for logic. Most of
  the update alert's run-sheet lines were already held by
  `UpdateOfferTests` and `UpdateFeedWatcherTests`; one clause was not, and
  now is: the alert never folds under a pointer resting on it
  (`testItDoesNotFoldUnderAPointerRestingOnIt`, checked by breaking the
  fold's question about the pointer). Translate's Recent list and the
  Launch at Login switch's role were already held. No bug; scores
  unchanged. With this batch the run sheet's logic-shaped clauses are
  nearly all under tests; what remains is looks, feel, real hardware and
  macOS's own prompts.
- **Batch 7, 2026-10-29.** Sittings 1, 2 and 8 searched for logic. Two
  new tests, both checked by breaking the code they hold: the favourite
  star leaves with Music when the same song moves to Yandex Music or a
  browser, and an island standing aside for Apple's leaves the volume
  keys to macOS. The second needed the HUD's wiring moved out of
  `install()` into `NotchController.wireHUD`, so the test runs the wiring
  the app runs rather than a copy of it. Two more checks (the waveform's
  colour, "60" in the bubble) were already held. No bug found; scores
  unchanged.
- **Batch 6, 2026-10-29.** Four Sitting 3 checks moved to tests, as far
  as a test can hold them: R4-H9 (a letter typed into a full Translate
  field is gone from the real editor too, typed through its `NSTextView`),
  R4-H5 (already held; only macOS's alert is left), and 427 and 431 (a
  launch never looks at the Shelf's files; each arrival on the tray looks
  once and evicts a deleted file). No bug this time, but one wrong comment:
  the source said a republication on refusal was what made the editor drop
  the letter, and removing it showed the editor drops it anyway. The tray
  test fails when the reopened-panel arrival is dropped; the editor test's
  model half fails when the refusal is removed, and its editor half guards
  SwiftUI's own behaviour, which no change to Isla's code broke.
  Scores unchanged: these cells were already held at the level the tests
  reach; what is left of each check is macOS's own prompt or an input
  method.
- **Batch 5, 2026-10-29.** Run-sheet check 1269 moved to tests, and the
  move found a bug: Russian VoiceOver heard Panel Width as "560 пт", the
  drawn abbreviation, which is also how Russian writes Friday. It now hears
  "пунктов: 560", the table's plural-free "label: N" form, correct for every
  width from 480 to 620 (`SettingsAccessibilityTests`). A sweep of every
  spoken unit in the Russian table found no other abbreviation. The
  check's "Glass" clause was stale (the row left Settings on 2026-10-15).
- **Batch 4, 2026-10-29.** Efficiency: every repeating timer and frame
  clock was read for work done while nothing is on screen. The always-on
  ones (the pointer sampler at 8 Hz idle with half a beat of slack, the
  2 s geometry watchdog that skips when nothing moved, the helper's
  silence watch) already let the system batch their wake-ups, and the
  fast ones (Translate's paste check, the lyric-delay preview) live only
  while their page does; nothing to cut without a measurement on the
  running app, which is B0.6. Design: one bug fixed. Under the open
  island, Russian cut the headphones' name to "AirPods… Подключено" in a
  capsule it fitted: the stack's 10 pt spacing stood before a zero-width
  trailing spacer (`AlertCapsuleTests`, which now also holds every
  confirmation's words whole). Charger and headphones design 2 → 3. Seen
  and left: the charger's «Пауза» for On Hold — Apple's «приостановлена»
  is 116 pt in a 76 pt wing, so the word is a call for the owner, who has
  had it on screen since 2026-10-26.
- **Batch 3, 2026-10-29.** Speed 1 → 2 for the player, the lyric stage,
  the Shelf, Clipboard and Translate, on the mount lab's numbers. A sample of
  the playing player's build (12 ms in release) found it nearly all SwiftUI's
  first graph build, with nothing of Isla's to cut, unlike Settings' daemon
  read; left as it is. Two accessibility bugs fixed. Three counted
  sentences said the plural at one: "Shelf, 1 items" (the island's value and
  the bubble's name for a single dropped file), "Remove all 1 items?" and
  "Clear 1 entries?" (`CountedSentenceTests`). And VoiceOver read the
  welcome's legend before its headline, with no heading anywhere on the pane;
  the headline is now a heading and read first
  (`FirstRunTests.testTheWelcomeReadsItsHeadlineFirstAsAHeading`, on the new
  `AXProbe.spokenOrder`, which follows VoiceOver's navigation order rather
  than the layout). Welcome accessibility 2 → 3, reliability 1 → 2.
- **Batch 1, 2026-10-29** (`feat/maturity-batch-0-on-mobbin`, on top of the
  held refinements, so test counts there run higher than the baseline's).
  Pop-up accessibility 1 → 2, charger and headphones accessibility 1 → 2 and
  reliability 1 → 3, updates accessibility 1 → 2. One bug found and fixed:
  during an install the island's progress bar reached VoiceOver as an unknown
  element with no value, so how far the download had got was never said.
  Sixteen of the run sheet's hardware checks are now held by tests (run
  sheet, "Held by tests since Batch 1"); one of them found a second bug, now
  fixed: a folder rescan that found a second copy of the playing song took the
  lyric off the screen mid-song.
- **Batch 2, speed, 2026-10-29.** A new headless harness,
  `Scripts/measure-mounts.sh` (`MountCostLab`), times each surface's build and
  first layout on the main thread's own CPU clock, with no window on screen
  and no idle Mac needed. Release, median of 15 builds: shelf 5 ms, empty
  player 7, clipboard 10, translate 12, playing player 12, lyric stage 15,
  Settings sections 15–32 (Lyrics 32), against a 8.3 ms frame at 120 Hz. A
  sample of the Lyrics section found Isla's own code at about a fifth of that
  and SwiftUI the rest. One bug found and fixed: every opening of Settings
  asked the login-items daemon for Launch at Login twice on the main thread,
  2.5 ms median and up to 9 ms each on a busy Mac, with the thread waiting
  (`LaunchAtLoginReadTests`). Tried and dropped: one hidden probe per row
  instead of one per word, pixel-identical over 178 renders but no faster.
  Settings speed 1 → 2. The swap's dropped frames still want
  `measure-hitches.sh` (B0.6, the owner's go). Two tests that failed on
  untouched code at load 50–160 now hold their claim without a clock: the
  karaoke frame clock compares with what was published, and the staged-mount
  shell tests assert the swap flag as the island opens instead of reading the
  tree within 80 ms (a mutation that keeps the flag past a reopening fails
  them every run).

## Scenario matrix, 2026-10-29

Automated (in `./scripts/check`): display choice and notch memory
(`NotchGeometry.decide`, `pick`), full screen, mirroring and lid-shut quiet
moments, the lock, dark displays, every surface under Reduce Motion, Increase
Contrast and Reduce Transparency, English and Russian key parity, no network,
LRCLIB refusing, the update path end to end in a scratch repository.

Owner runs only: real notch sizes, a Mac without a notch, external displays
plugged in and out, macOS 15 (CI runs 26 and the owner's Mac 27), VoiceOver
and Full Keyboard Access by hand, Stage Manager, Mission Control, fast user
switching, Low Power Mode, a real Spotify and Music, Apple's island Mac.
149 hardware checks are open in `checklist.md` (B0.5 sorts them).

## Lowest cells, which the first batches go after

1. **Speed and efficiency everywhere (1).** Speed has its idle-load numbers
   (B0.6, half); efficiency waits for a running Isla. Settings' swap is the
   worst frame drop measured.
2. **Usability everywhere (1).** Only owner runs move it. B0.5's run sheet
   turns 149 open checks into one ordered sitting.
3. ~~The pop-up, the charger and updates in accessibility (1).~~ Batch 1.
   What remains is a VoiceOver pass by hand (run sheet, Sitting 4).
4. ~~Charger and headphones reliability (1).~~ Batch 1.
