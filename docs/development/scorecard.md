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
| Island and activities | 2 — spec §3, §19; visual lab renders; R7–R8 runs owed | 2 — sweep; 6 AX uses; no VoiceOver run | 1 — `measure-hitches.sh` exists, no number since the redesign | 2 — idle budget recorded 2026-10-11 (CPU ≤ 0.1 %, RSS ≤ 88 MB), before the redesign | 3 — 210 tests: geometry, notch memory, moments, lock | 1 — runs owed |
| Player | 2 — spec §4; R1 runs owed | 2 — sweep; 5 AX uses | 1 — as above | 2 — as above, music playing measured | 3 — 374 tests: helper failure policy, seek, hold, favourites | 1 |
| Lyrics and stage | 2 — spec §5 | 3 — sweep; 39 AX uses | 1 — `measure-sync.sh` exists; 150 ms p95 target unmeasured | 1 | 3 — 428 tests: timelines, overrun, offline, 429 | 1 |
| Lock card | 2 — spec §7; R2 runs owed | 3 — sweep; 10 AX uses; picker labels | 1 | 1 | 2 — 116 tests; the private-space path only on hardware | 1 |
| Shelf | 2 — spec §8 | 3 — sweep; 11 AX uses | 1 | 1 | 2 — 146 tests | 1 |
| Clipboard | 2 — spec §9 | 3 — sweep; 27 AX uses | 1 | 1 | 2 — 203 tests | 1 |
| Translate | 2 — spec §11 | 3 — sweep; 22 AX uses | 1 | 1 | 2 — 214 tests, offline consent | 1 |
| Settings | 2 — spec §10 | 3 — sweep; 26 AX uses | 2 — `measure-mounts.sh`: 15–32 ms to build a section in release (Lyrics the costliest); no main-thread wait on the login-items daemon after a launch's first opening (B2) | 1 | 2 — 128 tests | 1 |
| Volume and brightness pop-up | 2 — spec §12 | 2 — `MomentAccessibilityTests`: the island's value for volume, brightness, keyboard and mute, and over a song and the charger (B1) | 1 | 1 — the tap's cost unmeasured | 3 — 181 tests: decide per hold, lock, refusal | 1 |
| Charger and headphones | 2 — spec §3.6 | 2 — every charger state with its level, headphones by model (B1) | 1 | 1 | 3 — `AmbientWatchSequenceTests`: failed reads, a pull before the reading lands, the re-reads, the blip, the 30 s quiet; mutation-checked (B1) | 1 |
| Updates | 2 — spec §19.5 f | 2 — every stage read and answered; the progress bar now reads its percent (B1 fix) | 1 | 1 | 3 — 290 tests: signature, detach by state, swap, rollback | 1 — DU runs owed |
| Welcome | 2 | 2 — sweep; 2 AX uses | 1 | 1 | 1 — 22 tests | 1 |
| Pages and navigation | 2 — spec §19.16 | 2 — sweep; dots read as one adjustable element | 1 | 1 | 3 — 165 tests, `SurfaceContractTests` | 1 |
| On a Mac with Apple's island | — | — | — | — | 2 — `NativeIslandTests`; identifiers unknown | 0 — NI runs owed |

## History

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

1. **Speed and efficiency everywhere (1).** The harnesses exist and no number
   has been taken since the redesign. B0.6, one sitting with the owner's go.
2. **Usability everywhere (1).** Only owner runs move it. B0.5's run sheet
   turns 149 open checks into one ordered sitting.
3. ~~The pop-up, the charger and updates in accessibility (1).~~ Batch 1.
   What remains is a VoiceOver pass by hand (run sheet, Sitting 4).
4. ~~Charger and headphones reliability (1).~~ Batch 1.
