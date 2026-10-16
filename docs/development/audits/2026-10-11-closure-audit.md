# Closure audit: the 179 findings against the integrated branch

2026-10-11, after the finish pass. A read-only Sonnet auditor checked each finding in `2026-10-11-master-register.json` (round-3 K findings included) against the merge history and the code at HEAD of `feat/island-next-level`: the fix commit is an ancestor, and a named test or symbol exists. It did not run the tests (the gate does: 1 111 passing).

| Bucket | Findings |
|---|---|
| Closed, verified in code and tests | 136 |
| Closed as far as headless evidence goes, needs the owner's live check | 40 |
| Deferred to an owner decision | 2: L-02 (the lead stays 0.20 s until the owner's S-LEAD measurement; the model and a live Lyric Delay preview are built) and J-002 (docs fix merged; Developer ID signing is the root fix) |
| Open | 1: L-12 (P3), LRCLIB `lyricsfile` line ends and word timing are not decoded; the plan deferred it because gap stamps already carry line ends |

Held or dropped tasks close no register finding: `sp/PV-04` (held on `feat/clipboard-online-consent-held`, owner decision 21) closes only a Mobbin idea, M-25; `ax/KB-06` and `ax/KB-07` (tab keys, list keyboard model) are dropped because they assumed the panel becomes key, which the recorded invariant forbids.

## Closed with a named residual (deferred in the plan)

F-015 playback clock split; F-043 persisted file stamps; F-044 pre-blurred cover bitmap; H-013 the 100 ms fold target; H-017 lyrics-stage fade (live check only); H-028 reopening mid-close restarts the body fade; G-022 fallback when the screenshot vault save fails; G-027 in-app updater; G-028 helper-signature enforcement (report only); G-030 Spotify cover-fetch switch; J-001 in-context explanation before the first system pasteboard alert; J-007 helper `isMusicApp` flag; J-025 removing a single saved edit.

## Partly located

- **K-003** (quiet ambient moments while another app is full screen): the pure gate and its test are built (`ms/MS-26`). Not built, and not previously recorded as skipped: a `quietInFullScreen` Settings switch, a Focus filter intent, a `checklist.md` entry, a live-script step. Owner call: whether to add the switch and the Focus filter.
- **K-004**: dimming and the Copy disable are verified; the spinner-over-failure and the Retry obstacle were not confirmed.
- **G-031**: closed by `ServicesMenu.strings` and the localization gate script, with no XCTest of its own.

## Documentation contradictions (found by the audit, recorded here rather than rewritten)

1. The morning report said all 16 P1 findings have a fix merged. L-02 (P1) does not: its fix is waiting on the owner's measurement.
2. The program log's "179 findings, 16 P1, 75 P2, 88 P3 before round 3 is counted in" is wrong: 179 already includes K-001 to K-017.
3. The build plan (`.md` and `.json`) still schedules `ax/KB-06` and `ax/KB-07` and still says `ax/KB-01` makes the keyboard-opened panel key. Neither happened; `CLAUDE.md` Shell section is the record. The plan is an approved dated document and is not rewritten; this entry is its amendment.
4. The plan text for `ly/LY-08` still describes applying the output-latency term and migrating stored corrections. The term is off (`appliesOutputLatency = false`) and no migration runs.
5. Merge subjects for the first batch and the finish pass name a batch or an engineer slot, not task ids; the task-to-commit mapping is in the program log and in this audit's evidence list below.

## Evidence, one test or symbol per task

The auditor's full list (one test per closing task, about 100 lines) is kept in the transcript of this run; the register's `closes` lists plus the test names in `Tests/IslaKitTests` are the durable record. Spot-check examples: `ly/LY-05` LocalLyricsDocumentTests.testABareTimestampEndsTheLineBeforeIt; `sp/SH-01` ShelfStoreTests.testACardOnAnUnmountedVolumeStaysOffline; `ax/KB-01` PinnedKeyboardTests.testOnlyAPinnedPanelWithoutTheKeyboardClaimsEscape; `ly/READ-01` ReadingLeadTests; `ly/PARSE-ENH` LocalLyricsDocumentTests.testAFirstWordAFewMillisecondsBeforeItsRoundedLineStampKeepsItsRealTiming.

## Human-perspective review of the final renders (Sonnet, 24 images)

One P1, fixed the same hour: the new Show Next Line Early options collapsed to "В… / 0,… / 0,…" at the 480 pt Russian width; a Settings choice row that does not fit now puts its options under its title (`SettingsChoiceRow`). Not fixed, for the owner's eye: P2 the lyrics stage truncates a very long current line at 480 pt (the stress fixture, "long-lines-wrapping"), and the lock card's neighbour lines are single-row; P2 the import notice is 17 pt out of line with the lyrics column; P3 Russian relative times in the Shelf render in the English short form (probably the lab's fixed locale; unconfirmed), "+0.00 с" mixes a point with the comma used in the options, a two-word orphan in the Russian welcome. The reviewer could not judge motion, real glass, measured contrast, the Translate tab at 480 pt Russian, or VoiceOver in use.
