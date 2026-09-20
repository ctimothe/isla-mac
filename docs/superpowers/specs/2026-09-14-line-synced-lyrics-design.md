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
