# Island next-level program

Started 2026-10-11 on branch `feat/island-next-level`. The owner set the goal and went to sleep: explore and test every piece of Isla, measure it against Apple's own design guidance, find and fix what falls short, and leave a free, native app that beats the field in `docs/research/2026-10-11-isla-vs-notch-apps.md`. This file is the charter and the status log. It is amended in place, dated, never rewritten.

## What done means

1. **Lyrics.** On a corpus of 500 real tracks across categories, the lyric clock lights every line and every word within one display frame (16.7 ms at 60 Hz, 8.3 ms at 120 Hz) of its target, with zero missed or doubled lines, and the island stage, caption and lock card always agree on the current line. The target is the source timestamp plus the chosen lead; the lead itself is justified by a measurement, not a habit. The owner's own global delay is -0.247 s, which cancels the 0.20 s default lead: that is evidence the default is wrong for this listener and the lab must say why.
2. **Apple design.** Every screen, control, animation and transition is reviewed against the `apple-design` skill and Apple's official guidance (HIG, motion, materials, accessibility). Each finding is fixed or waived in writing.
3. **Human feel.** Persona reviewers walk every flow (every click, button, state, empty state, error, transition). No P0 or P1 remains open.
4. **Performance.** Idle CPU, wakeups per second and resident memory are measured on the running app and held to budgets set in the plan.
5. **Completeness.** A final critic signs that the scenario ledger covers every feature, state, display configuration and failure it can name, and that each row has a test or a written reason it has none.
6. **Gate.** `./scripts/check` passes with the xctest defaults domain set aside. Anything that leaves the machine, touches an account or changes a system setting is added to `checklist.md` and defaults off.

## Safety rules for an unattended run

The owner's Mac is shared with other autonomous sessions working on other projects. Rules that follow from that:

- **No synthetic input.** No CGEvent clicks or keystrokes, no AppleScript or `open` against other apps. A misdirected keystroke could land in another session's terminal. Interaction is exercised through the model layer in tests and through offscreen renders, never through the live desktop.
- **Screen capture is region-only**, cropped to the island's area at the top of the built-in display, and written to the session scratchpad, never into the repo. A full-display capture shows other projects' private work.
- **No installing or relaunching the live app.** `Scripts/install.sh` opens the app through LaunchServices, which the sandbox blocks and this run does not work around. Builds are verified by tests and by `Scripts/bundle.sh`; the owner installs on waking.
- **Real accounts and audio stay untouched.** No Spotify or Apple Music playback, no network calls to Spotify. Lyric accuracy is measured against fixtures and a simulated clock. Any live audio test mutes the output first.
- **Lyric corpora never enter the repo** (the repo is public and lyrics are copyrighted). Only harness code and aggregate statistics are committed. LRCLIB is queried slowly with an identifying User-Agent.
- **Apple's guideline text is not copied into the repo.** It is read into the scratchpad for analysis; documents here cite the URL and paraphrase.
- **The user's settings are restored** after any run that changes them. The xctest defaults domain is exported before the gate and imported after.
- **Nothing is pushed, merged to `main` or shipped.** Work lands on feature branches with merge commits and waits for the owner.

## Company

| Role | Model and effort | Work |
|---|---|---|
| CEO (the driver session) | driver | Sets phases, reads every result, signs every gate, owns the plan |
| Explorers, scouts, harvesters | Haiku, medium | Inventories, HIG harvest, corpus fetch, greps |
| Auditors and persona reviewers | Sonnet, medium | Area audits against Apple guidance, flow walkthroughs |
| Lab engineers | Sonnet or Opus, high | Lyrics accuracy harness, render harness, measurement tooling |
| Principal reviewers, architects, completeness critic | Opus, high | Merge and rank findings, design fixes, adversarial review, sign-off |
| Implementers | Opus, high, one worktree each | Test-first fixes, one finding cluster per branch |

Each workflow stays under 10 agents. No subagent runs on Fable. Haiku output is never a gate or a review of code; an Opus or Sonnet agent confirms anything a Haiku harvest decides.

## Phases and gates

0. **Charter and baseline.** Safety rules, baseline gate, capability probe. Gate: baseline recorded.
1. **Apple guidance harvest.** HIG pages (motion, materials, Liquid Glass, typography, color, accessibility, menus and notch-adjacent surfaces, Live Activities and Dynamic Island) into a digest the auditors cite.
2. **Exploration wave A, static.** Area audits against the digest and the apple-design skill: motion, interaction, type and materials, music and lyrics UX, shelf, clipboard, translate and settings, system integration, performance. An Opus principal merges them into a ranked, evidenced backlog.
3. **Lyrics lab.** Corpus of 500 tracks (categories: pop, hip-hop, rock, electronic, classical and instrumental, non-Latin scripts, long and short tracks, live, gaps, duets, rap speed, no-lyrics), harness over `LyricSweep` and the word-timed path, frame-accurate verdicts, cross-surface agreement, drift model against the player clock.
4. **Exploration wave B, human.** Persona reviewers over offscreen renders and the flow map; interaction harness at the model layer; animation curves sampled analytically.
5. **Mobbin pass.** Part-by-part reference search for each surface; ideas ranked against the backlog.
6. **Exhaustion check.** Scenario ledger and completeness critic. Loop until the critic finds nothing new.
7. **Plan.** One tight, evidenced plan per cluster; Opus adversarial review of the plan.
8. **Build.** Test-first implementation in isolated worktrees, review, gate, merge to this branch.
9. **Verify and report.** Full gate, before and after numbers, owner-facing report, list of what needs the owner (install, physical-notch checks).

## Status log

- 2026-10-11 phase 0: branch cut; capability probe done. The cmux Computer Use daemon is down (needs the owner to toggle it in cmux Settings), so scripted GUI driving and video are unavailable tonight; region-only screen capture works outside the sandbox. Isla pid 869 is running on the owner's Mac. Baseline gate started.
- 2026-10-11 phases 1 to 3 (first pass). Baseline: 544 tests green with the sandbox off (the pasteboard tests crash inside it, which is the sandbox and not Isla). Apple guidance harvested into a 96-item checklist. Wave A (7 Sonnet auditors, Opus principal): 55 verified findings, 8 P1, plus 24 decisions that contradict recorded project decisions and wait for the owner (`docs/audits/2026-10-11-wave-a-backlog.md`). Mobbin pass: 40 ranked ideas (`docs/research/2026-10-11-mobbin-ideas.md`); Mobbin holds no macOS, notch or lock-screen screens, so its evidence is iOS. Lyrics lab merged (`LyricAccuracyLab*`, `Scripts/lyric-lab.sh`): on 240 real tracks the parser is exact to the millisecond and the line search is exact over 80 million checks, so the errors are downstream: lines stay lit through gaps (median 23.5 s a track), the run-loop Timer fires 4 ms late at the median, and the lead is about a third of a second off the owner's ear for a reason the lab cannot measure without audio. Visual lab merged (`VisualLab*`, `Scripts/visual-lab.sh`): 634 renders, 21 sampled curves, accessibility dumps. The merge carries four behaviour-preserving seams in `Sources/`; the full suite passes at 565 tests with 26 skipped (the labs, which skip without their environment variables).
- Open at this entry: the corpus is still filling (about 300 of 500), so the lyrics lab must be rerun on the full set; Wave B (eight persona reviewers) and exhaustion round 1 are running.
- 2026-10-11 phase 6 (exhaustion check) closed. Three rounds of scenario hunting (Wave A, rounds 1 to 3) built a ledger of about 1 230 scenarios across 19 feature groups. New verified findings per round fell 40, 27, 17 and P1s 3, 1, 0; the final Opus critic signed that no code-readable gap remains. The register holds 179 findings (16 P1, 75 P2, 88 P3 before round 3 is counted in; see `2026-10-11-master-register.json`). What cannot be settled without a physical Mac, a Spotify account or time is in `docs/audits/2026-10-11-live-validation-script.md` for the owner. The corpus is complete at 540 tracks and the lyrics lab was rerun on it (`docs/audits/2026-10-11-lyrics-lab/REPORT.md`). Wave B scored the felt quality of the surfaces at 3 to 7 out of 10 (accessibility 3, Settings 4.5, Shelf and Translate 5, lock card 5.5, Music pane and ambient moments 7). Phase 7 (plan) is running: five Opus planners and an adversarial reviewer.
- 2026-10-11 phase 8 (build) started. Batch 1 merged and green (590 tests, 0 failures, 26 skipped, the owner's Application Support data byte-identical before and after): ly/LY-01 (Lyric Delay now moves lines the way its label says, with a one-time migration that keeps every listener's timing identical), ly/LY-02 (every standard LRC dialect reads: BOM, stacked and unknown tags, section labels, angle brackets), sp/SH-01 (Shelf cards on an unmounted disk stay and read "Disk not connected"), ax/AX-00 (a headless accessibility probe for tests). Incident, resolved: the LY-01 engineer's first unsandboxed test run ran the new sign migration on the owner's real `lyrics-local/offsets.json` (the installed build was still the old one); they restored the file by hand, added a fence so a test process never migrates the live directory, and the CEO re-verified the file and the defaults. A data-protection rule was added to the implementer guide. Batch 2 (sp/CB-01, ms/MS-01, ly/LY-03, vt/LC-01) is building.

