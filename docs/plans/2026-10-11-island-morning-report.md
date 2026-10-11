# Morning report: where the island program stands

Written 2026-10-11 at the end of batch 7 (08:00 local); amended at the end of the run. Everything is on branch `feat/island-next-level`, nothing is pushed, nothing is merged to `main`, nothing is installed. The installed `/Applications/Isla.app` is still the old 0.2.0 build, running.

## What happened overnight

1. **Explored everything.** A 540-track lyrics lab (20 categories), 634 headless renders, 21 sampled animation curves, accessibility dumps, three scenario-hunt rounds (about 1 230 scenarios across 19 feature groups), a Mobbin pass, and a competitor study. Three rounds of hunting found 40, then 27, then 17 new verified findings, with P1s falling 3, 1, 0, and the final critic signed that no code-readable gap remains. 179 findings in `docs/audits/2026-10-11-master-register.json`.
2. **Planned.** 126 test-first tasks, attacked by an adversarial reviewer (32 problems found and fixed), scheduled in 30 batches of at most four (`docs/plans/2026-10-11-island-build-plan.md`).
3. **Built.** Seven batches, 28 tasks, each test-first by an Opus engineer in its own worktree, merged by me in order, and gated after every batch with the full unit suite, the localization, branding and provenance checks, and a before-and-after checksum of your real Application Support folder. Suite: 544 tests at the start, 732 now, 0 failures.

## What is better for you now (all 16 P1 findings have a fix merged; a few still need your live check)

- **Lyrics.** Lines go dark when their voice ends instead of staying lit through instrumentals (median 23.5 s a track, 12.5 percent of track time, measured on 540 songs). Every standard LRC dialect reads (a BOM, stacked and unknown tags, section labels and angle brackets used to refuse whole files, and LRCLIB cached that refusal for two weeks). Lyric timers fire strictly (4 ms late at the median became 0.07 ms). The clock never jumps on a speed change. The lock card no longer lights line one through an intro while the stage shows nothing. A stream says "No lyrics for live audio" instead of claiming lyrics are off. Lyrics that do not fit the recording's length are skipped for the next candidate.
- **The Lyric Delay sign.** The control did the opposite of its label (positive moved lines earlier). Fixed, with a one-time migration: your -0.247 s reads +0.25 s afterwards and lines land exactly where they did. The unmodelled third of a second behind that number is still open: the lead is now a sum of named terms with a live CoreAudio output-latency monitor, but the output-latency term is deliberately not applied until you measure it (live session 18).
- **Accessibility** (felt score 3 of 10 before). VoiceOver always finds one "Isla" button and the open panel closes from its header. Shelf cards and Clipboard rows are named, with Copy, Remove, Quick Look and AirDrop as actions. Settings switches show their state at a glance and the whole row flips them. Things are announced: charger, headphones, new tracks, a lock-card skip, the locked refusal, "Copied". Armed confirmations speak and wait longer under VoiceOver.
- **Escape and app switching** close a panel the keyboard opened, without changing the key-status invariant (a transient Escape hot key while pinned).
- **Privacy.** The Translate cover hides the translation too and no longer blinds your typing. The privacy switches say what they protect and say honestly what screen-recording hiding does and does not promise. Clipboard reads only what a switch wants and survives macOS pasteboard privacy.
- **Data loss.** Shelf cards on an ejected disk stay and read "Disk not connected" instead of vanishing. Screenshots reach the Shelf on a Russian or any non-English Mac.
- **The music fallback route** (what every DMG user sees until the app is Developer-ID signed) now shows shuffle, repeat and the heart, keeps the right clock after a skip, and no longer raises an unprompted Automation dialog at launch.
- **Lock card** text holds 4.5:1 over a pale cover, and the card always draws the recipe glass.

## Decisions I made for you (all reversible, all in the plan)

I applied the CEO policy recorded in the plan: privacy and accounts opt-in and default off; accessibility beats taste; never reverse a dated request of yours; removed features stay removed. Notable: the keyboard-opened panel does **not** become key (your recorded invariant stands; Escape works through a transient hot key). The volume and brightness HUD, a Developer ID build and an in-app updater were not built: they are your product decisions (the HUD usually costs a permission, which cuts against Isla's no-permission stance).

## What you should do first

1. **Review and install.** From `~/code/projects/production/dynamic-island` on `feat/island-next-level`:
   `bash Scripts/bundle.sh release && bash Scripts/install.sh` (I could not run `install.sh`: it opens the app through LaunchServices, which the sandbox blocks, and I did not work around that). Then open Settings > Music and check that Lyric Delay reads +0.25 s.
2. **Run the live validation script** (`docs/audits/2026-10-11-live-validation-script.md`, 18 sessions of about 10 minutes). Session 1 (pasteboard privacy on macOS 27) and the screen-recording exclusion check decide the two findings that remain at the top of the risk list. Session 18 measures the lead.
3. **Decide** the open owner decisions listed at the end of `docs/audits/2026-10-11-wave-a-backlog.md` (24 items), and whether keyboard-opened panels should become key.

## Honest limits

- Nothing was run on the physical notch: no live app was driven, no screen was recorded (the machine is shared with other autonomous sessions, so no synthetic input was allowed). Everything visual is judged from headless renders and sampled curves.
- Haiku and Sonnet did the exploring and an Opus principal or critic verified it, but the findings are code-read, not watched. 41 of the 179 are marked "needs live check", and several P1 fixes (the pasteboard privacy answer, the screen-recording exclusion honesty, the lead) are only closed as far as headless evidence goes.
- The corpus is LRCLIB's line-level timing; real word-timed lyrics barely exist in it (2 lines), so word-by-word accuracy rests on synthetic word times.
- One incident: an engineer's unsandboxed test run briefly rewrote one per-track lyric offset in your real data (the installed build was unaffected); it was restored byte for byte and fenced against recurrence, and every later gate checksums that folder.
