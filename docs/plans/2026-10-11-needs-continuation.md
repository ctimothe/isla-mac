# Needs continuation

What the 2026-10-11 island program left unfinished, as of release 0.3.0. Everything else in `docs/plans/2026-10-11-island-build-plan.md` is built, dropped or held (see `docs/audits/2026-10-11-closure-audit.md`: 178 of 179 findings closed). Each item says what is missing, why, and what unblocks it.

## Needs the owner (a decision, a measurement or a physical Mac)

1. **Live validation** (`docs/audits/2026-10-11-live-validation-script.md`, 18 sessions of about ten minutes). 40 findings are closed only as far as headless evidence goes. Nothing in this program was run on a physical notch. Record the tested Mac model and macOS version in `checklist.md` afterwards, as CLAUDE.md asks.
2. **The lyric lead (L-02, P1).** The lead is a sum of named terms and a live CoreAudio output-latency monitor, but `LyricLeadModel.appliesOutputLatency` is false, so the lead is still 0.20 s. Session S-LEAD measures the real offset; the lab suggests about 0.3 s is statistically best, and the owner has calibrated 0.20 s by ear. The Auto next-line setting is separate and already shipped.
3. **Developer ID and notarization (J-002).** Needed to stop the Gatekeeper alert on the media helper and the permission re-prompt on every update. Also unblocks an in-app updater (G-027) and Homebrew.
4. **Decision 21: clipboard text going online.** `sp/PV-04` (clipboard text waits for one click before it goes to MyMemory) is built and tested on branch `feat/clipboard-online-consent-held` and not merged. After the owner says yes, merge it and delete the "no extra click" record in the build plan (lines 166 and 244). `ms/MS-19` touched the same entry point, so expect a small merge conflict in `NotchViewModel.receiveCommandedTranslation`.
5. **The other open owner decisions** at the end of `docs/audits/2026-10-11-wave-a-backlog.md` (24 items), plus: the volume and brightness HUD (would cost a permission), the `quietInFullScreen` Settings switch and a Focus filter for quiet ambient moments (K-003, below).

## Unfinished work

| Item | What is missing | Notes |
|---|---|---|
| L-12 (P3) | Decode LRCLIB `lyricsfile` (line `end_ms`, word timing) | Deferred in the plan; gap stamps already carry line ends. Word timing is rare in LRCLIB (2 lines in 540 tracks). Parser: `LocalLyricsDocument`. |
| K-003 (ms/MS-26) | A `quietInFullScreen` Settings switch, a Focus filter intent (`SetFocusFilterIntent`), a `checklist.md` entry, a live-script step | The pure quiet gate and its test are built; none of these four was recorded as skipped. |
| K-004 | Confirm the spinner over a failure and the Retry obstacle on Translate | Dimming and the Copy disable are verified. |
| Overrunning lyrics (ly/VERSION-01) | Lines stamped past the track's end are still dropped, so the tail of a lyric timed for a longer version is missing even after Sync Here; keep them when `overrun` is set. The island caption and the lock card still show an overrunning lyric without a warning (the owner decides whether to hide them). Sync Here uses the click moment, so it lags the voice by the listener's reaction time; the Earlier/Later steppers fine-tune. | Found 2026-10-11 on a Yandex Music version of a song (248 s against lyrics timed for 267 s). The corpus lab (L10) shows 11.4 percent of LRCLIB records are stamped past their own listed length, so the duration field is unreliable. |
| `ax/KB-06`, `ax/KB-07` | Tab keys (⌘1–⌘5) and the list keyboard model | Dropped: they assumed the panel becomes key, which the recorded invariant forbids. Revisit only if the owner changes that invariant. |
| Residuals closed with a named piece deferred | F-015 playback clock split; F-043 persisted file stamps; F-044 pre-blurred cover bitmap; H-013 the 100 ms fold target; H-017 lyrics-stage fade (live check); H-028 reopening mid-close restarts the body fade; G-022 fallback when the screenshot vault save fails; G-028 helper-signature enforcement (report only); G-030 Spotify cover-fetch switch; J-001 an in-context explanation before the first system pasteboard alert; J-007 helper `isMusicApp` flag; J-025 removing a single saved edit | See the closure audit. |

## Design polish found in the last render review (not fixed)

- The lyrics stage truncates a very long current line at the 480 pt width (stress fixture `long-lines-wrapping`); a third row or a smaller step would fix it. The lock card's neighbour lines are single-row.
- The import notice sits 17 pt off the lyrics column and runs on the same row as a faded lyric.
- Russian relative times in Shelf render in the English short form in the lab (probably the lab's fixed locale; unconfirmed in the app). "+0.00 с" mixes a decimal point with the comma used elsewhere in Russian. The Russian welcome leaves a two-word orphan. "Нет устройств вывода." still says "вывода" where the glossary prefers one name.
- Header button reads "Isla" with the tab name as its value; "Close panel" as the label may read better to VoiceOver users (owner/VoiceOver check).
- Not judged from still renders: motion feel, real glass, measured contrast, the Translate tab at 480 pt Russian, VoiceOver in use.

## Housekeeping

- `Scripts/test-lifecycle.sh` (and `measure-performance.sh`) launch the freshly built app against the real `~/Library/Application Support/Isla`, so every gate run executes one-time migrations on the owner's data. Redirecting the data folder and the defaults needs an app-level hook (HOME does not move either). Until then, run the lifecycle step once, not per batch.
- `SettingsIcon.about` and `SettingsIcon.quit` are no longer used by the app (kept for the lab and `SettingsIcon.all`); remove or keep.
- `Diagnostics` reports Launch at Login as off while macOS approval is pending; use `LaunchAtLogin.read()`.
- Docs that contradict the code and were not rewritten (the build plan is a dated approved document): it still schedules `ax/KB-06`/`KB-07` and says `ax/KB-01` makes the panel key; the `ly/LY-08` text still describes applying output latency. `CLAUDE.md` is the record.
- Visual-lab baselines and the contact sheets in `docs/audits/2026-10-11-visual-lab` were generated before the last batches; regenerate with `bash Scripts/visual-lab.sh`.
- Finding M-27 appears only in the plan, not in the audit register.

## How to resume

Pick from the owner list first; the unfinished-work table is small and mostly P3. Build with a Sonnet engineer per related group of tasks, test-first, in a worktree, and gate with `./scripts/check` (see `docs/plans/2026-10-11-island-next-level-program.md` for the method and the incidents it hit).
