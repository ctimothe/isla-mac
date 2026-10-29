# Maturity program — the best island for every Mac without one

Status: proposed 2026-10-29, owner decisions D1–D3 open. Not binding until the
owner approves it; once approved, the scorecard it creates is the bar every
batch is held to, and the parity design and redesign spec stay the behaviour
contract.

## Why now

On 2026-10-28 Apple announced the touchscreen 14-inch and 16-inch MacBook Pro
(M5 Pro and M5 Max, OLED, pre-order that day, in stores 2026-11-06) with a
native Dynamic Island in place of the notch: calls, music and AirDrop live in
it. Every other Mac has none — every notched MacBook Pro and MacBook Air since
2021, every Mac without a notch (where Isla draws one), and every external
display. That is Isla's audience, it is most Macs in use, and it will be for
years.

Two jobs follow:

1. **Be the best island on a Mac that has none** — measurably: faster, lighter,
   more accessible and more reliable than the other notch apps, in every
   scenario a real Mac goes through, not only on the owner's desk.
2. **Behave on a Mac that has one.** Isla updates every user within the hour,
   so a copy already installed reaches a new MacBook Pro by Migration Assistant
   on day one. Drawn there, it would put a second island over Apple's. This is
   the first item (B0.1), and it should ship before 2026-11-06.

   *Withdrawn 2026-10-29 (owner: "isla-mac is only for the notch style
   MacBooks. period."). Isla is not made for a Mac with Apple's island and
   does nothing special on one; the guard built for this job was removed.*

## The bar: a scorecard

`docs/development/scorecard.md` (created by B0.2): one row per feature, one
column per dimension, a score from 0 to 4 per cell, and the evidence for it —
a test name, a file:line, a number from a harness, or a dated owner run. A
cell without evidence scores 0. It is re-scored after every batch, so
progress is a number, not an impression.

Features: the island and its activities, the player, the lyric stage, the
lock card, the Shelf, Clipboard, Translate, Settings, the volume and brightness
pop-up, the charger activity, updates, the welcome, pages and navigation.

| Dimension | What 4 means | How it is measured |
|---|---|---|
| Design | Meets the apple-design skill and spec §19; nothing hand-mixed | Snapshot gallery (B0.4) reviewed against named principles; owner approval of the baseline |
| Accessibility | Every control has a name and role in VoiceOver, every action is reachable from the keyboard, Reduce Motion, Reduce Transparency and Increase Contrast are honoured live, en and ru complete | AXProbe sweep per surface and setting (B0.3); `test-localizations.sh` |
| Speed | No dropped frame in open, close, page turn or alert at idle; budgeted misses under load | `Scripts/measure-hitches.sh`, before and after, numbers in the scorecard; `Scripts/measure-mounts.sh` (added 2026-10-29) for what a surface costs to build, which needs no screen and no idle Mac |
| Efficiency | Awake-idle CPU, wake-ups per second and footprint at or under the S17 budget | `Scripts/measure-idle.sh` per scenario; `Scripts/measure-idle-lab.sh` (added 2026-10-29) for what each resting state of the island costs, which needs no running Isla |
| Reliability | Every failure path has a test: helper death, malformed output, no network, display change, sleep and wake, lock | XCTest with fakes; the failure-path list per feature |
| Usability | First use works without reading anything; one failure surface per event | Owner run, dated, Mac model and macOS recorded |

## The hard checks: a scenario matrix

Each scenario is either **automated** (a test in `./scripts/check`, so it
holds forever) or an **owner run** (a line in the batch's run sheet). Moving a
scenario from the second kind to the first is progress in its own right.

- **Displays:** 14-inch and 16-inch notch, Air 13-inch and 15-inch notch, a
  Mac without a notch (synthetic island), an external display alone, external
  plus built-in, clamshell, "More Space" scaling, plugging and unplugging,
  and mirroring. Geometry for every real panel
  size and notch width is a pure table test; the rest are owner runs.
- **macOS:** 15.x, 26.x, 27.x. CI covers one; the others are owner runs or a
  spare volume.
- **Settings:** light and dark, Reduce Motion, Reduce Transparency, Increase
  Contrast, VoiceOver, Full Keyboard Access, the Russian locale.
- **System states:** a full-screen app, Stage Manager, Mission Control, a
  Space switch, the lock screen, the screen saver, fast user switching, sleep
  and wake, Low Power Mode, every core busy.
- **Media:** Music, Spotify, a browser, Podcasts, nothing playing, the helper
  unavailable, paused for hours.
- **Network:** offline, slow, rate-limited (LRCLIB 429), GitHub unreachable
  during an update.

## The loop

One batch at a time, five to eight fixes, the same steps every time:

1. **Measure.** Score one area. Haiku scouts take inventory; the driver
   judges against the scorecard. Out comes a ranked fix list, each item with
   its evidence and its tier.
2. **Approve.** The owner picks the batch in one decision.
3. **Build.** Each fix in its own worktree cut from `origin/main` — never
   from the local `main`, which went stale on 2026-10-28 — test first, with a
   mutation check that the test fails on the old code. Implementers run on
   Sonnet `high` from a spelled-out brief; the driver reproduces and diagnoses
   anything that is not.
4. **Prove.** `./scripts/check` with the xctest domain set aside; before and
   after numbers for anything touching speed or efficiency; a Sonnet `high`
   reviewer per fix, Opus `high` for the updater, keychain or anything that
   leaves the Mac, Codex for Tier 3; `/review-branch` over the batch.
5. **Deliver.** Merge into the batch branch, publish to the dev feed; the
   owner presses Install and runs the batch's run sheet (about 15 minutes).
6. **Ship.** One pull request, one CI run, every user's island within the
   hour. Re-score the area.

## What runs without the owner, and what never does

Runs unattended: measuring, writing tests, fixing approved items, reviewing,
the gate, publishing to the dev feed. An approved batch whose items are all
spelled out can run overnight — one item at a time, stopping at the first red
gate, ending with one summary and the run sheet in the morning.

Needs the owner: approving a batch, design direction, the run sheet on real
hardware, pressing Install, merging to `main`, release keys and the Developer
ID.

Never: an agent driving the live app or setting `DI_*` hooks while the owner
works; a fan-out of more than six agents, or any Opus fan-out, without a yes
(an overnight Opus build once took about 22 percent of the weekly limit).

## The loop in practice (2026-10-29, after thirteen batches)

This is the recommended setup, settled by thirteen batches in one day. One
driver session runs one batch at a time with no fan-out: Haiku scouts only
for inventories, and no implementer agents, because every fix so far was
small enough that briefing an agent cost more than writing it. Each batch is
seven steps:

1. **Pick** the lowest scorecard cell that a headless lab can measure.
2. **Measure** it with one of the five instruments, none of which launches
   Isla or needs the screen:
   - `Scripts/measure-mounts.sh`: how long each surface takes to build.
   - `Scripts/measure-idle-lab.sh`: CPU and wake-ups in resting states.
   - `Scripts/measure-hitches.sh`: missed frames in open, close, swap and
     page turns. Take a `sample` of its xctest process when the CPU columns
     look fine but frames still miss: a main thread waiting on Core
     Animation shows only there.
   - The visual lab plus the Vision OCR sweep: English and Russian, at 480
     and 620, for cut text.
   - The accessibility sweep and `AXProbe.spokenOrder`: names and reading
     order.
3. **Fix only on evidence.** Write the test first and break the old code to
   see it fail (mutation check). A number that does not move is a reason to
   drop the change, not to keep it.
4. **Gate.** Run `./scripts/check` with the xctest domain set aside.
5. **Commit** on the held batch branch. If app code changed, publish to the
   dev feed.
6. **Re-score.** Record the result in the scorecard, the checklist and the
   run sheet.
7. **Stop** at a red gate, a product decision, anything that would leave the
   Mac, or the pointer sampler and the watchdog (owner decision 19).

What each source found, which is the reason for that order:

| Source | Batches | Bugs |
|---|---|---|
| Russian and VoiceOver sweeps | 3–5 | 4 |
| OCR over the visual lab | 10 | 2 |
| Mount lab | 2 | 1 (login item read twice) |
| Hitch lab with `sample` | 9 | 1 (gear swap, 27 → 4 missed frames) |
| Idle-cost lab | 11 | 1 (marquee, 100+ wake-ups a second → under 1) |
| Run-sheet clauses turned into tests | 5–8 | 1, now spent |
| Lock-card and page-turn labs | 12–13 | 0 |

The next queue for the cells still at 1, in order:

- ~~Welcome and the update alert in the mount and idle labs.~~ Batch 14.
- ~~The media-key tap's callback cost, timed on synthesised events.~~ Batch 15.
- ~~The charger and headphones watchers at rest.~~ Batch 15.

After Batch 15 no cell outside Usability is at 1. A 3 needs a measurement
that meets its budget, so the next headless queue is the cells over it:

- ~~Translate at rest, about 0.2 % of a core with its 1 s paste check, against
  the 0.1 % budget (S17).~~ Batch 16: 0.03–0.06 % on quiet runs; the 0.2 %
  was noise from outside the lab.
- The opening's missed frames (0.6–2.9 at idle), against the bar of none.
  Any staged build there waits for the owner's R8e-H2 verdict on the
  Settings morph, which asked the same question.

With Translate settled (Batch 16), that last item waits on the owner, and so
does every other 3: efficiency's budget includes the footprint, which only
the running Isla shows (`measure-idle.sh`), and usability needs Sitting 1.

What only the owner can do, and what it unblocks:

- ~~**Start Isla once.** This unblocks the idle half of B0.6.~~ Batch 17:
  shut with music it is inside the budget, but using the panel cost
  15–27 % of a core, far over the lab. Next: **open each surface for a
  minute while it is measured** (B17-H1 to H3), so the gap can be traced.
- **Press Install.** The feed builds reach the running copy only this way.
- **Run hardware Sitting 1** (about 100 minutes). Until it runs, Usability is
  1 in every row.
- **Give the gallery verdicts.** They set the design baseline.
- **Merge.** Merging to `main` ships to every user. It is on hold until the
  owner says otherwise.
- **D3.** Decided 2026-10-29: no nightly routine; batches run only while
  the owner is in the session.

## Batch 0 — the instruments, before the fixes

- **B0.1 Native-island guard.** *Built, then withdrawn on 2026-10-29 with
  job 2: Isla is for notched Macs only, so `NativeIsland`, the step-aside and
  Show on Built-in Display were removed, and NI-H1 to NI-H3 with them.*
  Find what a native-island Mac reports (model identifiers, `NSScreen` safe
  area and auxiliary areas, any public API), then make Isla draw nothing over Apple's island. Research now, from
  Apple's developer documentation and specifications; code once the facts are
  known; one owner run on the new Mac, or a borrowed one. Decision D1.

  What was known on 2026-10-29: Apple's model list
  (support.apple.com/108052) did not yet name the new models, so there is no
  identifier to match. The island sits on a camera cutout at the centre top
  of the panel, as on the iPhone, not on a notch. If macOS reports no top
  safe area there, Isla takes the display for one without a notch and draws
  its synthetic island in the same place. Apple's developer material
  (WWDC 2026 session 223, "Live Activities essentials") puts Live Activities
  in the macOS menu bar and the Dynamic Island only on iOS 27, so no public
  API for the Mac's island was found. So the guard needs either the new
  identifiers, once Apple's list names them (by 2026-11-06), or the screen
  properties read on the hardware, plus a switch in Settings meanwhile.
- **B0.2 Scorecard baseline.** Score every feature with the evidence that
  exists today; empty cells are the backlog.
- **B0.3 Accessibility sweep.** One AXProbe test per surface under every
  appearance setting: every control named, every action reachable.
- **B0.4 Snapshot gallery.** Every surface rendered in light, dark, Increase
  Contrast and Reduce Transparency, in English and Russian, at widths 480, 560
  and 620, published as one private page the owner reviews once. Approved
  images become the baseline later changes are compared to.
- **B0.5 Run-sheet triage.** `checklist.md` has 172 open hardware checks on
  `feat/mobbin-refinements`. Retire what is stale, turn what can be into tests,
  and fold the rest into one ordered run sheet.
- **B0.6 Performance baseline.** `measure-hitches.sh` and `measure-idle.sh`,
  run once with the owner's go while the Mac is otherwise idle, recorded in
  the scorecard as the budget.

## Owner decisions

- **D1 — on a Mac with Apple's island.** *Decided 2026-10-29 (owner: "Yes,
  step aside"): Isla steps aside, as built in Batch 0 (spec §3.8).*
  *Superseded the same day (owner: "we dont need a support for the new
  Native dynamic island macbooks, isla-mac is only for the NOTCH STYLE
  MACBOOKS. period."): no step-aside, no switch; spec §3.8 records the
  withdrawal.*
  Recommended: draw nothing on that
  display and keep working on external displays; the hot keys and the
  right-click menu still open Clipboard, Translate, the Shelf and Settings
  under Apple's island. Alternatives: quit with a one-time notice, or keep
  drawing and leave the choice to the user.
- **D2 — the first batch after Batch 0.** Ranked by the scorecard; the owner
  picks from the top.
- **D3 — overnight runs.** Whether approved, spelled-out batches may run
  unattended, and the nightly budget for them.
  *Decided 2026-10-29 (owner: "No, only with me"): batches run only inside a
  session the owner is in. No nightly routine, no scheduled agent.*
