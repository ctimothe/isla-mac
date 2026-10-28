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
| Settings | 2 — spec §10 | 3 — sweep; 26 AX uses | 1 — staged mount measured once (2026-10-19) | 1 | 2 — 128 tests | 1 |
| Volume and brightness pop-up | 2 — spec §12 | 1 — spoken by `Announcer`; no AX test | 1 | 1 — the tap's cost unmeasured | 3 — 181 tests: decide per hold, lock, refusal | 1 |
| Charger and headphones | 2 — spec §3.6 | 1 — sweep only | 1 | 1 | 1 — tested inside the moment tests only | 1 |
| Updates | 2 — spec §19.5 f | 1 — 1 AX use | 1 | 1 | 3 — 290 tests: signature, detach by state, swap, rollback | 1 — DU runs owed |
| Welcome | 2 | 2 — sweep; 2 AX uses | 1 | 1 | 1 — 22 tests | 1 |
| Pages and navigation | 2 — spec §19.16 | 2 — sweep; dots read as one adjustable element | 1 | 1 | 3 — 165 tests, `SurfaceContractTests` | 1 |
| On a Mac with Apple's island | — | — | — | — | 2 — `NativeIslandTests`; identifiers unknown | 0 — NI runs owed |

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
3. **The pop-up, the charger and updates in accessibility (1).** Add AX tests
   for what VoiceOver hears when each appears.
4. **Charger and headphones reliability (1).** Their own tests, outside the
   moment tests.
