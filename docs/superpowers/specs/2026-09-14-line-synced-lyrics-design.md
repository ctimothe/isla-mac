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
