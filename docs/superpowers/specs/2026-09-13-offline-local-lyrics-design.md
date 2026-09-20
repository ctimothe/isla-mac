# Offline local lyrics design

**Status:** approved 2026-09-13

## Goal

Make Isla's lyrics entirely offline, free, and open source without weakening
the honest timing standard. Isla must feel immediate and native when a local
file describes the exact recording. It must never invent word timing, download
lyrics, or choose a plausible-but-wrong version.

This supersedes the licensed-broker design. Isla will not operate a lyric
service, accept provider credentials, contact a lyrics endpoint, or distribute
a bundled lyric catalogue.

> **Amended 2026-09-21 — one endpoint, off by default.** "Contact a lyrics
> endpoint" is narrowed; everything else in this sentence still stands. Isla
> still operates no service, holds no credential, and ships no catalogue.
>
> The reason is one this design could not answer: a streamed track has no file
> on this Mac, so no offline lookup can ever find words for it. In practice
> that meant a listener on Spotify saw "No local lyrics" on every song and the
> only cure was to find an LRC by hand, per song. The owner decided on
> 2026-09-21 that this cost more than the rule bought.
>
> What is admitted, and nothing more: **LRCLIB** (`https://lrclib.net/api/get`),
> a free community catalogue that needs no account and no key, consulted
> **only** when the local library reports no match at all, and **only** while
> `Look Up Lyrics Online` is switched on — off on a fresh install. What leaves
> the Mac is the track's title, artist, album and duration. Nothing identifies
> the listener, nothing is uploaded, and there is no analytics or contribution
> call.
>
> The non-goals below are otherwise unchanged, and two of them now bind this
> path too. **Word timing is still never invented:** LRCLIB carries line-level
> LRC, so a timeline from it is `.line` and the karaoke sweep stays off for it —
> only an enhanced LRC you import animates word by word. **An ambiguous local
> result still asks you to choose** rather than quietly fetching instead: a
> file you put there outranks anything a catalogue suggests.
>
> Held by `OfflineLyricsIsolationTests`, which no longer forbids the network
> outright but bounds it — exactly one source file may reach it, at exactly
> this endpoint, and the removed providers and the broker stay removed.

## Non-goals

- Universal automatic lyric coverage.
- Scraping Apple Music, Spotify, or any other player.
- Networking for lyric lookup, update, analytics, or contribution.
- Inferring word timing from audio, text, or an estimated singing speed.
- Automatically resolving an ambiguous studio/live/acoustic/remix choice.

## Local sources and ownership

`LocalLyricsLibrary` is the sole lyric-data authority. It reads only:

1. LRC files explicitly imported through Isla. Imports are copied to
   `Application Support/Isla/lyrics-local/imports` so the original remains
   untouched.
2. LRC files in one or more folders explicitly selected in Settings. These are
   referenced in place and rescanned when the folder changes.

Isla never uploads, shares, indexes remotely, or silently downloads any of
those files. Editing a referenced folder file creates an Isla-owned edited
copy; explicit export is the only action that writes an LRC outside Isla's
support directory.

The library accepts ordinary LRC and enhanced word-timed LRC. A file may be
manually bound even when it has no metadata tags. Automatic matching requires
valid `title` and `artist` tags; `album`, duration, and a version label are
stronger disambiguators.

## Identity and matching

`LocalTrackIdentity` contains normalized title, artist, album, duration,
player class, and any recording identifier supplied by the active local player
interface. It is used only on this Mac.

`LocalLyricsBinding` maps a `LocalTrackIdentity` to an LRC document and wins
over every automatic candidate. It is created when the listener chooses “Use
this file for this track”, and can be changed or removed in the lyric stage.

Automatic matching follows this fixed order:

1. An existing binding for the identity.
2. Exactly one candidate with equal normalized title, artist, and album, and a
   duration difference of at most two seconds.
3. Exactly one candidate with equal normalized title and artist, and a duration
   difference of at most half a second.
4. No match.

Any tie, missing required metadata, invalid timing, or failed file read is not
a match. The user sees local-file actions rather than another recording's
lyrics. This is how the design handles studio, acoustic, live, remix, edit,
and remaster versions safely.

## Playback and presentation

`LyricsCoordinator` remains session-owned and begins lookup as soon as valid
Now Playing metadata arrives; no SwiftUI surface may initiate a lookup.
It asks `LocalLyricsLibrary` once for the logical track and preserves visible,
validated lyrics during metadata enrichment or a rescan.

Availability states are:

- `disabled`
- `settlingPlayback`
- `findingLocalLyrics`
- `ready`
- `noLocalLyrics`
- `invalidLocalFile`

Every compact, full-stage, and lock-card lyric surface renders a concrete,
accessible caption for every state. The full stage is always reachable and
offers import, open-library-folder, rescan, file selection for ambiguity,
binding removal, timing controls, and export where applicable. There is no
“service unavailable” state and no consent copy for a network service.

Word animation requires valid word timestamps for the displayed line and a
measured player clock. Otherwise, the exact same timeline uses line-level
highlighting. Existing global and per-track nudges remain and apply to all
surfaces through `LyricSweep`.

## Correction and contribution

The stage adds an offline editor that can adjust line timestamps, add or remove
lines, preview against current playback, and export a standard LRC. Isla
stores edits as a local copy and records a binding to that copy; it never
overwrites an external source file without an explicit export action.

The repository documents the accepted LRC subset, a validator command, and
small non-copyrighted timing fixtures. Contributors may share LRC files or
packs through GitHub releases or any other channel themselves. A listener must
explicitly obtain and import every pack; Isla has no catalogue-fetch feature.

## Migration and removal

On first launch of the local library:

- Copy every valid prior local override from the v5 `overrides` directory into
  the local imports directory. Index it from LRC tags. A tagless legacy import
  remains available under “Unassigned imports” until the listener binds it.
- Delete all v4 community entries and every v5 licensed-provider cache entry.
- Preserve global and per-track timing nudges when their local identity can be
  reconstructed; retain otherwise-unassigned nudges in Settings → Local Lyrics
  for selection, then delete them only on explicit dismissal.

The implementation removes the Cloudflare Worker service, Worker workflows,
broker resolver, installation-token storage, provider adapter interface,
licensed cache-rights model, provider consent, broker release checklist, and
all broker tests. No dormant lyrics networking code remains.

## Validation and release gates

Automated tests must prove:

- local lookup prefetches before a panel opens and every availability state has
  a nonblank compact caption;
- imported and watched-folder LRC documents are indexed, refreshed, validated,
  and never overwritten by an edit;
- exact candidate selection, ambiguity rejection, manual binding precedence,
  binding removal, and legacy migration behave as specified;
- enhanced-LRC words sweep only with valid timing and a measured player clock;
- every lyric path is local: no resolver, token, `URLSession`, Worker endpoint,
  or network request remains;
- editor changes, export, timing nudges, cache clearing, English, Russian,
  VoiceOver, and Reduce Motion remain correct.

Manual release evidence must include physical-notch and lock-card workflows,
offline operation, selected-folder changes, import/export, ambiguous versions,
invalid files, and Spotify plus Apple Music sync probes using local enhanced
LRC fixtures. Word-timed surfaces release only after each player measures at
or below 150ms p95; unmeasured clients remain line-level.
