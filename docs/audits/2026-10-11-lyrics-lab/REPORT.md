# Lyrics accuracy lab: first run

Run 2026-10-11 on 240 real LRCLIB tracks (the corpus was still filling: 240 of a planned 500, across 11 of 20 categories). Harness: `Scripts/lyric-lab.sh`, tests `LyricAccuracyLab*`. The corpus holds copyrighted lyrics and lives outside the repository; this report carries aggregate numbers only. Rerun on the full set before treating the percentiles as final.

## Headline

Across 240 real LRCLIB tracks, Isla reads every timestamp it keeps exactly to the millisecond (12,894 lines, max error 0.000 ms), and its line search never named a wrong line in 80,368,189 one-millisecond checks. The errors that matter sit downstream of the parser. Isla throws away LRCLIB's gap stamps, so a finished line stays lit through instrumentals for a median of 23.5 s per track (10.5% of the track). The run-loop Timer that drives line changes fires 4 ms late at the median and 10 ms at p99, against 0.07 ms for a strict dispatch timer. The lead is off by about a third of a second against the owner's ear. The cause is a delay between the player's reported position and the voice reaching the ear that no measured term accounts for; Isla's own clock arithmetic is exact.

## How to rerun

```
bash Scripts/lyric-lab.sh <corpus-dir> <report.json>
```

Run it from a normal terminal: inside the Claude Code Bash sandbox CoreAudio does not answer and L7 records the output device as unavailable. `ISLA_LYRIC_STRICT=1` turns findings into test failures; `ISLA_LYRIC_TIMERS=N` sets the real-timer count per condition (default 300).

## Measurements

### L1 · fail

Parse fidelity: OnlineLyrics.timeline on the raw LRCLIB bytes against an independent integer-millisecond LRC reader, aligned by time

240/240 accepted. 12,894 lines match to the millisecond (max error 0.000 ms) with 0 text mismatches. 1 sung line lost in 1 track: a leading U+FEFF (BOM) is not stripped by trimmingCharacters(.whitespaces), so the first line is skipped. 764 empty gap stamps in 231 tracks are dropped by design. 993 lines in 45 tracks (18.8%) are stamped past their own track's duration and are accepted without a check. CR line endings (1 track) and 3-digit milliseconds (1 track, 58 lines) are handled exactly. Multi-stamp lines, [offset:], out-of-order stamps, duplicates, unknown tags, mm:ss:ff and angle brackets do not occur in this corpus.

### L2 · pass

Index exactness: every boundary at t−1 ms and t, 2000 seeded seeks per track, a 1 ms sweep of every track against a linear-scan oracle, and cross-checks of index, displayed and LyricsStore.current

12,894 boundaries, 480,000 seeks and 80,368,189 sweep steps: 0 oracle misses, 0 monotonicity violations, 0 disagreements between entry points. No duplicate stamps occurred, so no line was shadowed.

### L3 · concern

Frame-grid activation error with the real LyricSweep.position (lead 0.20 s) and a perfect clock

60 Hz: p50 8.30, p95 15.92, p99 16.44, max 16.64 ms. 120 Hz: p50 4.05, p95 7.82, p99 8.22, max 8.32 ms. Every category's maximum is under one frame. 0 lines skipped (smallest gap between lines 30 ms), 0 doubled. 18 lines due before playback starts are shown on the first frame. 991 lines in 45 tracks are never reached because they are stamped past the track's end.

### L4a · concern

Boundary-timer arming arithmetic through the real MediaController with its monotonicNow seam frozen and stepped: rates 0.5, 1, 1.25 and 2; register, tick, on-boundary, rate change, seek forward, seek back

1,440 arms, 0 wrong or missing, max error 0.000 ms. A wake landing exactly on its boundary arms the next one. But a rate change while the snapshot's position is not adopted (here, during a pending seek) leaves the anchor un-rebased: the next tick jumps by −400 to +800 ms (p50 −200 ms) and the armed wake is off by −1.10 to +2.11 s.

### L4b · concern

Real timer lateness: 300 one-shot timers per condition at 5–250 ms, built exactly as armBoundaryTimer builds them, beside the 100 ms grid tick

Timer plus main-actor hop, idle: p50 4.07, p95 9.53, p99 10.00, max 10.14 ms (34 of 300 later than 8.33 ms). Without the grid tick: p50 4.77, max 9.97 ms. With all 12 cores busy: p50 5.59, p99 14.47, max 17.73 ms (1 later than a 60 Hz frame). A DispatchSourceTimer(.strict) on the main queue with leeway 0: p50 0.074, p99 0.29, max 0.90 ms. The Task hop adds about 0.05 ms.

### L4c · concern

Clock fidelity through the real snapshot path: an exact 1x player, a snapshot every 2 s at a random phase, the 0.1 s tick, and the anchor read back from the armed wake

114 of 300 snapshots re-based the anchor onto the stale published position. The anchor sits behind a perfect player 36% of the time, by a mean of 26.6 ms while behind and at worst 49.9 ms; the overall mean is −9.6 ms.

### L5 · concern

Word sweep invariants on real lyricsfile word timing (2 lines, 12 words) and on SYNTHETIC syllable-proportional words (12,894 lines, 89,655 words), with end nil and with end set; 120 Hz frames; jump threshold one character

0 monotonicity, before-start, early-full, late-full or cumulative-share failures. Equal-length words of 0.2 s and 1.0 s give exactly 0.25 and 0.75 at their midpoints. With end nil, 11,522 lines deviate more than one character from the true edge (p50 2.36, max 10.09). With end set, 22 lines do (max 4.98, all from the 50 ms floor; 177 words are shorter). A 10 ms word reaches 0.099 and then leaps to 0.5 at its end. Animation MODEL (linear 0.25 s retargeted every 0.1 s, additive): the edge trails by 175 ms at p50, 196 ms at p95. None of this reaches LRCLIB lines, which are .line granularity and drawn at fraction 1.

### L6 · fail

Gap behaviour: stale highlight against LRCLIB's empty stamps and lyricsfile end_ms (11,901 of 11,901 lines matched)

Stale time per track p50 23.5 s, p95 292 s, max 2,685 s. Share of track time p50 0.105, p95 0.531. Outro p50 6.9 s. 214 mid-song lines lit through more than 8 s of silence, plus 114 outros over 8 s. Highest category: long tracks at p50 198.5 s; lowest: fast rap at p50 3.5 s. Ending lines at the empty stamps Isla already receives removes 99.85% of the stale time (27 s left across the corpus). Lines are fully lit throughout the gap. The unreachable sweepSpan path would finish more than 100 ms early on 629 of 801 lines and then sit full for a p50 of 4.3 s.

### L7 · concern

Lead calibration by Monte Carlo over the measured and assumed terms against ITU-R BT.1359-1 (window −125/+45 ms)

Undetectable share of onsets at the shipped 0.20 s lead, and the optimal lead: 60 Hz output 0: 17%, optimum 0.31 s. 120 Hz output 0: 33% (median +59 ms), optimum 0.30 s. Wired 20 ms: 57%, optimum 0.28 s. This Mac's built-in output (27.3 ms): 67%, optimum 0.27 s. Bluetooth 200 ms (assumed): 30%, optimum 0.10 s. The owner's effective −0.047 s models as +306 ms late, so 0.31–0.35 s of delay between player and ear is unaccounted for (0.24–0.28 s if the eye takes the crossfade's 10% point).

### L8 · fail

Cross-surface agreement: stage, caption and lock card through the same LyricSweep entry points, 444,648 samples in 4 configurations

All 22,930 disagreements fall before the first line. There the lock card marks line 1 current and lit (fraction 1 for line timing), the stage marks none and the caption shows line 1 unswept. This lasts p50 9.95 s, p95 98.7 s, max 458.7 s per track. After the first line the three surfaces agree exactly. All three compute position + lead inline; none runs its own clock.

## Defects found

### P1 Lines stay lit through instrumentals and outros: empty LRC gap stamps are dropped and LyricSweep.index has no line end

- Evidence: LocalLyricsDocument.swift:153-160 drops stamps with no text; LyricSweep.swift:97-105 (index) and :116-120 (end) take only the next line's start. L6: stale highlight p50 23.5 s per track (10.5% of track time), p95 292 s; 214 mid-song lines lit through more than 8 s of silence; 114 outros over 8 s. 764 gap stamps in 231 of 240 tracks are thrown away.
- Fix direction: Keep empty stamps as the previous line's end (add an end to LyricsStore.Line) and end the current line there and at the track's end. Optionally decode lyricsfile end_ms. Ending at the stamps alone removes 99.85% of the stale time.

### P1 The lyric lead does not match the listener: the shipped 0.20 s is about 0.25 s off by the owner's ear, and the model's optimum is 0.30 s on a zero-latency route

- Evidence: LyricSweep.swift:35,40. L7: at 0.20 s the median onset is +59 ms at 120 Hz with output 0 and only 33% of onsets undetectable; the owner's −0.247 s implies 0.31–0.35 s of unmodelled delay between player and ear. The lead was tuned on 2026-09-21 against the stale published position, but boundary wakes publish a fresh one, so onsets run about 50 ms earlier than that calibration assumed.
- Fix direction: Make the lead a sum of named terms: anchor lag, render terms, live CoreAudio output latency, and an acoustic stamp-bias term. Build an acoustic loopback probe before changing the constant.

### P2 Foundation Timer boundary wakes fire 4 ms late at p50 and 10 ms at p99, up to 17.7 ms under load

- Evidence: MediaController.swift:264-269 (Timer, tolerance 0, .common, Task hop). L4b: idle p50 4.07, p99 10.0 ms; loaded max 17.73 ms, 1 of 300 later than a 60 Hz frame. A DispatchSourceTimer(.strict) in the same process: p50 0.074, p99 0.29 ms.
- Fix direction: Schedule boundary wakes on a DispatchSourceTimer(flags: .strict) on the main queue with zero leeway, and call tick() directly instead of through a Task hop.

### P2 A playback-rate change without a re-anchor makes the clock jump by hundreds of milliseconds

- Evidence: MediaController.swift:1541 sets playbackRate before position adoption; the precisionSteers, pending-seek, stale and held branches (about lines 1545-1567) never re-base the anchor. L4a: the next tick jumps −400 to +800 ms and the armed wake is off by −1.10 to +2.11 s.
- Fix direction: Re-base the anchor at the current extrapolated position under the old rate before assigning the new rate, for example in playbackRate's willSet.

### P2 adopt() re-bases the anchor onto the stale published position, leaving the clock up to 50 ms behind

- Evidence: MediaController.swift:2050-2054 (anchor = (position, nowMono), where position is the last tick's value). L4c: 114 of 300 snapshots re-based; the anchor is behind a perfect player 36% of the time, by a mean of 26.6 ms while behind, at worst 49.9 ms.
- Fix direction: Re-base on the extrapolated anchor value (anchor.position + elapsed × rate), not on the last published position.

### P2 The lock card lights line 1 during the intro while the stage shows nothing and the caption shows it unlit

- Evidence: LockScreenCard.swift:371 uses centreIndex (0 before the first stamp); LyricRow.swift:135-137 then draws fraction 1 for line timing. L8: all 22,930 cross-surface disagreements are here, p50 9.95 s per track, p95 98.7 s.
- Fix direction: Pass isCurrent only when LyricSweep.index is non-nil (or use displayed().swept), so the card draws the opening line unswept, as the caption already does.

### P2 LRCLIB timelines stamped past the track's duration are accepted unchecked

- Evidence: OnlineLyrics.swift:88-102 and :209-231 compare durations but never compare stamps with duration. L1: 993 lines in 45 of 240 tracks (18.8%) lie past their own record's duration; L3: 991 of those lines never show. The rest of each of those files is probably timed to a different cut.
- Fix direction: Reject or rank down a candidate whose last sung stamp exceeds the duration plus a small tolerance, and try the next search row.

### P2 A leading UTF-8 BOM drops the first lyric line

- Evidence: LocalLyricsDocument.swift:57 trims .whitespaces, which does not include U+FEFF, so the line no longer starts with '[' and is skipped. L1: track 36975922 shows 37 of 38 lines; the missing one is the 00:00.00 line.
- Fix direction: Strip U+FEFF from the start of the document (or of each line) before parsing.

### P3 The onset crossfade spring delays the perceived line change by about 104 ms

- Evidence: LyricRow.swift:164 animates isCurrent on Theme.lyricScroll (Theme.swift:105-108). L7: rise to 10% at 34.7 ms, 50% at 103.9 ms, 90% at 215.8 ms. This is the largest render term in the lead model.
- Fix direction: Start the crossfade early by its rise time, or light the onset without the spring.

### P3 The karaoke sweep animation (0.25 s linear) is mismatched to the 0.1 s position tick and trails the voice by about 175 ms

- Evidence: KaraokeText.swift:106-108; its comment still says 'one tick'; MediaController.positionTickInterval is 0.1. L5 MODEL: lag p50 175 ms, p95 196 ms.
- Fix direction: Drive the fraction from a TimelineView or display link off the anchor rather than animating between publishes, or shorten the animation to the tick and offset the sweep by it.

### P3 Word ends are never set, and the 50 ms floor makes short words leap

- Evidence: LocalLyricsDocument.swift:186 sets end nil; LyricSweep.swift:141-146. L5: with end nil, 11,522 of 12,894 synthetic lines deviate more than one character (p50 2.36); with end set, 22. A 10 ms word goes from 0.099 to 0.5 in one step.
- Fix direction: Carry word end times where a source has them (lyricsfile words, enhanced-LRC end markers), and interpolate sub-floor words without the jump.

### P3 LRCLIB lyricsfile (line end_ms and word timing) is never decoded

- Evidence: OnlineLyrics.swift:32-36 decodes only syncedLyrics, instrumental and duration. L6: lyricsfile end_ms matched 11,901 of 11,901 lines and carries the same line ends as the gap stamps. L5: only 2 real word-timed lines exist in this corpus.
- Fix direction: Decode lyricsfile as a secondary source for line ends and word timing.

## Lead calibration

Do not pick a new constant from the model alone. Make the lead a sum of named terms, and measure the one that is missing with an acoustic loopback probe.

Model (L7): offset = anchorLag + timerWake + vsyncWait + compositor + crossfadeRise − outputLatency − stampBias − lead. A positive offset means the line lights after the voice.
- Measured in this run:
  - timer wake: idle p50 4.07 ms, p99 10.0 ms.
  - vsync wait: uniform over one frame (L3).
  - crossfade rise: Theme.lyricScroll (response 0.42, damping 0.86) reaches 10% at 34.7 ms, 50% at 103.9 ms and 90% at 215.8 ms.
  - this Mac's default output, as CoreAudio reports it: built-in, 27.3 ms.
- Measured elsewhere: anchor lag 0.138 s. This is the 2026-09-21 Spotify probe's published-position lag of 0.188 s minus the 0.05 s mean staleness of the 0.1 s tick grid; boundary wakes publish a fresh position and do not suffer that staleness. The ±0.04 s spread is assumed.
- Assumed: one frame of compositor latency, LRCLIB stamp bias of 0, perceived onset at the crossfade's 50% point.

Criterion: ITU-R BT.1359-1 (1998), sound before picture detectable beyond +45 ms and sound after picture beyond −125 ms; acceptability limits +90/−185 ms; target is the window centre, −40 ms. EBU R37 (+40/−60 ms) and ATSC IS-191 (+15/−45 ms) agree on the asymmetry and are tighter. Lyrics are text, not lips, so these are a proxy.

Results:
- On a zero-latency route at 120 Hz, the shipped 0.20 s lead lights lines at a median of +59 ms (late), with only 33% of onsets undetectable (17% at 60 Hz). The optimum is 0.30 s.
- For this Mac's reported built-in output the optimum is 0.27 s.
- For an assumed 200 ms Bluetooth route the optimum is 0.10 s.

The owner's −0.247 s gives an effective lead of −0.047 s. By the model that is +306 ms late, outside every window. Because the owner tuned it by ear, the model is missing 0.31–0.35 s of delay between Spotify's reported position and the voice reaching the ear (0.24–0.28 s if the eye takes the crossfade's 10% point). Candidates are output latency, buffering that Spotify's reported position does not include, and LRCLIB stamps set early. The lab cannot divide it between them. Bluetooth would explain about 0.2 s, but CoreAudio reported built-in output during this run, and the route when the owner set the correction is unknown.

The older numbers also conflict. The 2026-09-13 probe (−0.103 s on the 0.25 s grid) implies an anchor lag near −0.02 s; the 2026-09-21 probe implies about 0.14 s. And the 0.20 s lead was tuned against the stale published position, so line onsets run about 50 ms earlier than that calibration assumed.

Recommendation:
1. Make the lead the sum: anchorLag (re-measure) + timerWake + frame/2 + compositor + crossfadeRise + 0.040 − outputLatency (read live from CoreAudio per route) − stampBias (acoustic probe).
2. Remove two terms outright: switch boundary wakes to DispatchSourceTimer(.strict), which saves about 4 ms at p50 and 10 ms at p99; and either start the onset crossfade early by its rise or drop the spring on line onset (104 ms to 50%).
3. Until the acoustic probe exists, keep the owner's correction: it stands in for the missing term. Neither the shipped 0.20 s nor any single constant fits both the model and the owner's ear.

## Seams a future change needs

- A pure LyricSweep.surfaceState(lines:position:lead:wordTiming:surface:) used by LyricsStage, MediaPane and LockScreenCard, so L8 calls production code instead of restating the views' inline expressions (LabSurfaces).
- An injectable lyric-boundary scheduler in MediaController (Timer and DispatchSourceTimer implementations) plus a DebugTrail record of each wake's lateness, so L4 can measure fire accuracy inside the real app.
- A display-frame probe that logs the display-link timestamp of the first frame drawing a new line, to measure compositor and render latency end to end.
- A live output-latency term for LyricSweep.lead, read from CoreAudio (device latency, safety offset, buffer and stream latency for the current route).
- A line end on LyricsStore.Line, filled from empty LRC stamps and lyricsfile end_ms, with OnlineLyrics.Response decoding lyricsfile.
- An acoustic loopback mode for Scripts/sync-probe that captures audio and screen to measure the player-to-ear delay and LRCLIB stamp bias.
- A test seam that blocks PlayerBridge.playbackModes and refreshPlaybackModes, so the precision-sync rate-change path can be driven without a real player.

## Not measurable here

- The acoustic offset between the line on screen and the voice heard. This is the 0.31–0.35 s term the owner's correction implies, and it needs a microphone or loopback capture.
- Whether Spotify's AppleScript player position includes output buffering or DAC latency.
- LRCLIB stamp bias against real vocal onsets (needs audio).
- Compositor and display scan-out latency on the real panel (assumed to be one frame).
- Timer lateness inside the running Isla.app rather than the xctest process (task role, App Nap and coalescing may differ).
- The precision-sync rate-change path: driving it calls PlayerBridge.playbackModes on a real player, which the rules forbid. The same mechanism was measured through the pending-seek path.
- Real word-timed lyrics at scale: only 2 lines and 12 words exist in this corpus, so L5 rests mostly on SYNTHETIC words.
- The audio route in use when the owner set −0.247 s (CoreAudio reported built-in output, 27.3 ms, during this run).
- 9 of the 20 planned categories were empty when the run started (240 of the planned 500 tracks; no _index.json yet). The harness takes the corpus path from the environment for a rerun on the full set.
