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
