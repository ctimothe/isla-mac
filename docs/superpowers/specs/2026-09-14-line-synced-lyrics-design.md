# Line-synced lyrics design

## Decision

Lyrics remain enabled by the existing **Show Lyrics** control. Their default
presentation is Spotify-like: the current line follows playback, but no text
sweeps word by word. A separate **Word Karaoke** setting enables the sweep only
when the imported LRC has valid enhanced word timestamps and the active player
has a measured precision clock.

## Behavior

- New installations default Word Karaoke to off.
- Existing users without a stored preference receive the same safe default.
- Turning Word Karaoke off never hides lyrics, stops line selection, or changes
  timing offsets. It only renders the active line fully highlighted.
- Turning it on does not invent word timing: ordinary LRC, line-only timelines,
  and unmeasured player clocks remain line-synced.
- The setting applies consistently to the compact music caption, full stage,
  and lock card.

## Architecture

`LyricsStore` owns the persistent preference, exposing it as a published
boolean. `LyricsPresentation.usesWordTiming` accepts that opt-in alongside its
existing timeline and precision checks. Every lyric surface passes the shared
preference into that policy; no surface makes its own decision.

Settings presents the control directly below **Show Lyrics**, with an
accessibility label and English/Russian localization. The preference has no
network, provider, import, or matching effect.

## Tests

- The preference defaults to line-synced mode and persists its explicit value.
- Word timing is disabled when the preference is off, even for word-timed,
  precision-measured playback.
- Word timing remains disabled for a line-only timeline or unmeasured player
  when the preference is on.
- Both locales contain the new user-facing string.

## Amendment — 2026-09-20: the line is instant, and it turns on the beat

Two changes to how the timeline is *shown*, neither to what is shown.

- **No surface waits for the clock to settle.** `LyricsAvailability` lost its
  `settlingPlayback` case. The caption, the stage and the lock card show the
  line the clock points at the moment they appear and move it when a
  correction lands, as the system's own lyrics do. The wait it replaced put a
  "Syncing playback…" spinner on every open of the panel — 150 ms when a real
  reading came, the full 1.2 s grace when none did — to prevent a wrong line
  that a fresh anchor almost never produced. `MediaController.positionSettled`
  remains as the clock's own statement of trust; nothing user-facing reads it.
- **Line changes land on the frame they are due.** `LyricsCoordinator` hands
  every line's timestamp to `MediaController.setLyricBoundaries`, and the
  clock arms a one-shot, zero-tolerance timer for the next boundary (less the
  lead) at every tick and every anchor change. Before this a change landed
  anywhere on the 250 ms ticker grid — on time or a quarter-second late, at
  random — which is the "sometimes early, sometimes late" no lead can fix.
- **The leads drop to 0.20 s** (from 0.25) on both paths: the 0.10 s the
  probe measured the clock behind the audio, plus 0.10 s of deliberate
  anticipation. The quarter-second the lead held in reserve for the grid is
  gone with the grid. `Scripts/measure-sync.sh` stays the arbiter and has not
  been re-run since this change; the word-edge column is the number to read.

Tests: `LyricsCoordinatorTests.testLyricsAreReadyBeforeTheClockSettles`,
`MediaControllerTests.testTheNextLyricWakeIsTheFirstBoundaryAheadLessTheLead`
and `…testTheClockPublishesOnALyricBoundaryAheadOfItsGrid`, `LyricSweepTests`.

## Amendment — 2026-10-11: a delay delays

The listener's corrections — **Lyric Delay** in Settings (`userOffset`, ±3 s),
the stage's per-track **Lyrics Earlier**/**Lyrics Later** nudges
(`trackOffset`, ±1.5 s) and the **Set Lyric Delay** Shortcuts action — are
delays, and the lead now subtracts them:
`lead = base − userOffset − trackOffset`. They were added until this change,
so every control ran backwards against its own label: a positive delay showed
lyrics earlier, "Lyrics Earlier" showed them later, and the AirPods listener
the setting exists for (checklist.md 2026-09-21) followed the note under the
slider and doubled the error. The labels, the note ("Negative shows lyrics
earlier; positive, later") and the intent's description were right and are
unchanged; the arithmetic now agrees with them.

Stored corrections are negated exactly once, so no listener's timing moves
with the fix: `lyrics.userOffset` in defaults (marked by
`lyrics.offsetSignVersion` = 2), and every value in `offsets.json` and
`unassigned-offsets.json` (marked by an `offset-sign-version` file beside
them — the defaults domain and the directory are separate stores, and a
marker in only one of them would let a process that sees a different domain
flip the files a second time). A pre-local correction the local library
imports into an already-flipped directory is flipped on the way in. A test
process never migrates the live support directory. The owner's −0.247 s reads
+0.247 s afterwards, at the same effective lead of −0.047 s.

Tests: `LyricSweepTests.testAPositiveDelayShowsLyricsLater`,
`…testLyricsEarlierMovesLinesEarlier`,
`…testTheSignMigrationKeepsEveryListenersTiming`,
`…testALegacyOffsetMigratedAfterTheSignFlipKeepsItsTiming`,
`…testATestRunLeavesTheInstalledAppsOffsetsAlone`, and the four legacy-nudge
tests in `LocalLyricsLibraryTests`, which now read the imported nudge back in
the new sign.

## Amendment — 2026-10-11: a line goes dark when its voice ends

A finished line used to stay lit until the next line's stamp, through every
instrumental and every outro. The lyric lab (L6, 540 tracks) measured a
median 28.9 s of stale highlight a track, 12.5 % of track time, with 447
mid-song lines lit through more than 8 s of silence and 295 outros. The
answer was already in hand: LRC marks the end of a line's voice with a bare
stamp, and LRCLIB writes one in most files (1,694 in the corpus). The parser
dropped them.

- **An empty stamp is the end of the sung line before it.**
  `LocalLyricsDocument.parse` keeps it as `LyricsStore.Line.end` when it lies
  strictly after that line's start (after the sort, the next sung line cannot
  start before it); it never becomes a row. A second stamp in one gap leaves
  the first; a stamp before the first line, or at a line's own moment, ends
  nothing. `serialize` writes `[end]` back after its line, only where `parse`
  would read it as that same line's end. `end` is optional, so every cache and
  index written before it still decodes. `parserRevision` is 3.
- **One rule decides whether an end is honoured.** `LyricSweep.effectiveEnd`
  keeps an end only when the silence after it is at least
  `minimumHonouredGap` (1.5 s) before the next line; a breath must not blink
  the line off and on. The last line's end (the outro stamp) is always
  honoured. Ends a file does not state are not invented: a last line without
  an outro stamp still holds to the track's end.
- **From the honoured end nothing is current.** `LyricSweep.moment` answers
  `current: nil` until the next line starts and centres on that line, the
  same statement the intro makes, so the stage, the caption and the lock card
  turn to the coming line, dim and unswept; in the outro they keep the last
  line, unswept. `end(of:in:)` returns the honoured end, so a word-timed
  line's last word ends with the voice instead of stretching across the
  instrumental. `displayed` (the Get Current Lyric action) reads the same
  moment.
- **The clock wakes for an end as for a start.** `LyricsCoordinator` hands
  `setLyricBoundaries` every start and every honoured end, so a line goes
  dark on the frame its voice stops rather than on the next quarter-second
  tick.

Not done: decoding LRCLIB's `lyricsfile` `end_ms` (the same information
behind a YAML reader, deferred as L-12); refreshing cached LRCLIB answers
that predate ends (LY-09); a marker for long gaps (LY-13).

Tests: `LocalLyricsDocumentTests.testABareTimestampEndsTheLineBeforeIt`,
`…testWhichLineAnEmptyStampEnds`,
`…testAnEndIsWrittenOnlyWhereItReadsBackAsTheSameLinesEnd`,
`SharedLyricTimelineTests.testALineGoesDarkAtItsEnd`,
`…testAShortBreathKeepsTheLineLit`,
`…testTheOutroLeavesTheLastLineShownUnswept`,
`LyricsCoordinatorTests.testLineEndsAreBoundaries`; the lab's L6 now measures
production's ends (needs the corpus, `Scripts/lyric-lab.sh`).
