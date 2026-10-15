# Lyrics match lab: report

Run on 2026-10-15 on branch `feat/lyrics-match-lab`. The method, the metrics
(M1–M10) and every rule the lab follows are in [SPEC.md](SPEC.md) beside this
file. The corpus holds copyrighted lyrics and lives outside the repository, in
`~/code/_tools/isla-lyrics-lab/`. This report carries counts, timings, LRCLIB
record ids, titles and artists only.

**Status: in progress.** Isla's timing and parsing are measured on 1,441 real
records. The catalogue's own limits are measured from LRCLIB's answers and its
server source. Whether Isla finds the right lyrics for a song (M1) is not
measured yet: LRCLIB stopped answering this machine's address after 129
answers, before Isla's own lookups could be recorded. The section "What is
owed" says what each open measurement needs.

## Headline

- **Word-by-word lyrics barely exist in LRCLIB.** None of the 1,016 distinct
  synced records in LRCLIB's answers to the lab carries word timing. In the
  two corpora, 2 of 1,441 records do. Isla's word karaoke needs word timing,
  so for online lyrics it almost never runs. A matcher change cannot fix that;
  a source with word timing can.
- **Isla's own line-timing arithmetic is exact.** M5 tested it on 901 new
  records (46,765 lines) and on the 540-record corpus of 2026-10-11:
  - Isla reads every stamp to the millisecond.
  - Its line search agrees with an oracle at every one-millisecond step.
  - No line is drawn more than one frame late (with a perfect player clock).

  On the 2026-10-11 corpus, Isla now reads the one file it refused then:
  LRCLIB 36877652, an enhanced LRC.
- **The catalogue sets the accuracy floor.** Distinct uploads of one song at
  one length disagree. In 21 % of pairs one whole timeline is shifted more
  than 0.3 s from the other, and after that shift 15 % of lines still differ
  by more than 0.25 s (M9; 29 pairs over 8 songs). Also, 11.3 % of records
  are stamped for a longer cut than their own listed length.
- **LRCLIB's rate limit decided what the lab could measure, and it can decide
  what a listener sees.** After 119 answers in 46 minutes, this address got
  11 answers in the next three hours, 0 to 6 per probe. Isla treats a 429
  like any failure and, while the song plays, asks again after 5, 30 and
  120 s, with up to three requests each time.
- **LRCLIB's two endpoints see different uploads.** `/api/get` returns the
  oldest matching upload. In 5 of the 7 gets that found a record, it was an
  upload that neither 20-row search page showed. 84 % of search pages are
  full at 20 rows, so for a popular song Isla's search sees only part of the
  uploads.

## What the lab holds

| Source | Size | Used for |
|---|---|---|
| Harvest | 465 tracks in 16 slices, 22–30 each | the songs Isla is asked about |
| Resolved sample | 88 tracks (3 popular and 3 stress picks per slice), 375 query variants | M1, M2, M4, M6, M10: not run yet |
| Pool | 901 synced LRCLIB records for 3 slices | M5 |
| 2026-10-11 corpus | 540 LRCLIB records in 20 categories | M5, compared with the earlier run |
| Cache | 129 LRCLIB answers (116 search pages, 13 gets), plus 823 iTunes and 984 Deezer answers | the twin, M9, the C8 estimate, the findings |
| LRCLIB's server source | `tranxuanthang/lrclib`, read locally | how both endpoints match and rank |

The 16 slices, with their track counts:

| Slice | Tracks | Slice | Tracks |
|---|---|---|---|
| africa-caribbean-europe | 25 | kpop-jpop-anime | 30 |
| classical-soundtrack-instrumental | 28 | latin | 30 |
| country-folk-songwriter | 30 | middle-east-south-asia | 30 |
| cpop-southeast-asia | 30 | pop-anglo | 30 |
| edge-metadata | 22 | rnb-soul-gospel-funk | 30 |
| electronic-dance-lofi | 30 | rock-metal-punk | 30 |
| hiphop-rap | 30 | russian-cis-uzbek | 30 |
| indie-slowcore-shoegaze-emo | 30 | jazz | 30 |

The 2026-10-11 corpus covers 20 categories:

- popular music: pop, classic rock, metal, electronic, Latin;
- hip-hop: fast, slow;
- country and folk, R&B and soul, jazz standards, opera and art song;
- regional: K-pop, J-pop and anime, Mandarin and Cantonese, Russian and
  Ukrainian, Arabic, Turkish and Hindi;
- edge cases: tracks over 7 minutes, short tracks and long intros, live and
  remastered variants, duets and choirs.

## Findings

They are ranked by what they cost a listener and by how sure the evidence is.

### 1. Word timing: LRCLIB has almost none, and Isla drops some of what reaches it

**What the catalogue holds:**

| Set | Records | Word-timed |
|---|---|---|
| Cached LRCLIB answers | 1,899 distinct (1,016 synced, 716 flagged instrumental) | 0: no `hasWordSync`, no word tags in `syncedLyrics` |
| Pool | 901 synced | 0 (one record's `lyricsfile` has a `words:` key on 39 lines, each an empty list) |
| 2026-10-11 corpus | 540 | 2 (below) |

In all, 2 of 1,441 corpus records (0.14 %) are word-timed:

- **LRCLIB 36877652** (Mandarin) is enhanced LRC, with 543 word tags across
  all 44 lines. LRCLIB flags it `hasWordSync: false`.
- **LRCLIB 36979903** is flagged `hasWordSync: true`, but has words on only
  2 of its 61 lines.

**What Isla does with them:**

- **Word karaoke needs a word-timed timeline.** Isla draws it only for a
  `.word` timeline whose precision was measured, with the setting on
  (`Sources/IslaKit/UI/LyricsPresentation.swift:99-105`). Almost every LRCLIB
  answer is a `.line` timeline, drawn fully lit.
- **Isla can read only enhanced LRC (F-B).** `lyricsfile` is never decoded
  (`Sources/IslaKit/Services/OnlineLyrics.swift:32-36`). Every record that
  LRCLIB itself flags `hasWordSync` has its words in `lyricsfile`, and for
  those the server builds a line-only `syncedLyrics`.
- **Only the first play animates (F-A).** Isla now reads LRCLIB 36877652
  (M5 L1); on 2026-10-11 it refused it.
  - The fresh path keeps the parsed granularity (`OnlineLyrics.swift:171`).
    With precision sync and karaoke on, that record animates word by word on
    the play that fetched it.
  - The cache rebuilds every hit as `.line` (`OnlineLyrics.swift:524`). Isla
    asks the cache first on every track change
    (`LyricsCoordinator.swift:455`), so every later play is line by line.
  - The type's doc comment says every online timeline is `.line`
    (`OnlineLyrics.swift:15-17`). So the code disagrees with its own
    contract.

  C1 settles this toward word timing. Settling it toward the doc comment is a
  one-line change too.
- **`lyricsfile` line ends add almost nothing.** In 51,072 of 51,106 pool
  pairs, a line's `end_ms` is the next line's start. One record in 901 ends
  lines earlier than that. Line ends reach Isla as LRC's empty stamps
  instead.

**What this means.** Decoding `lyricsfile` (F-B) and keeping word granularity
in the cache (F-A, candidate C1) are correct and small. Today they reach 2
records in 1,441. Word-by-word lyrics for most songs need one of two things:

- **A source with word timing.** Word-timed catalogues exist elsewhere:
  NetEase's yrc, QQ Music's QRC, Musixmatch's richsync and Apple Music's
  syllable TTML. Each sits behind terms of service or an account, so adding
  one is a product decision. Like Lyrics itself, it would be recorded in
  `checklist.md` and ship off by default.
- **An estimate.** Words could be spread through each line by syllable. Isla
  deliberately draws no timing that the file did not hold: a line without
  words is lit whole (`LyricSweep.drawnFraction`, `LyricSweep.swift:389-396`).
  So an estimate is a product decision too. The lab could not score one
  anyway, because there is no word-timed truth to score it against.

**The word sweep itself is sound (M5 L5).** It was tested on synthetic
syllable-timed words: 46,765 lines in the pool. It fails no invariant. At
120 Hz its edge trails the true word edge by 4.2 ms at the median and 8.3 ms
at p95. The 2026-10-11 corpus (24,230 lines) gives the same figures. L5's
set of real words is the `lyricsfile` words alone (2 lines), so the enhanced
LRC record is not in it.

### 2. A 429 stops lookups for hours, and Isla's retries spend what is left (F-H)

These are all the LRCLIB answers the lab got, by time in UTC (local time is
five hours ahead):

| Time (UTC) | What happened |
|---|---|
| 08:03–08:24 | 107 searches answered, about five a minute |
| 08:40–08:49 | 12 gets answered, then three 429s |
| 09:1x | 1 get answered |
| 10:05–10:06 | 3 answered, then a 429 on the fourth and on every retry |
| 10:45 | 1 answered, then a 429 |
| 11:15–11:16 | 6 answered, then a 429 |
| 11:46 | none: the first request drew a 429, and the collector was stopped |

From 10:45 the collector stopped at the first 429, so each probe cost LRCLIB
one refused request. It waited 30 to 60 minutes between probes.

Two things the owner should know about this run:

- **The lab once changed address family to get past the limit.** Earlier the
  same day it moved from IPv6 to IPv4 after the IPv6 address drew 429s. SPEC
  records this as a gray area. It was not repeated.
- **Isla on this Mac shares the address.** Its online lyrics are on. While the
  lab spent the allowance, Isla's own lookups for songs it had not cached
  could fail. Cached songs were unaffected.

**What Isla does on a 429:**

- `read` turns any status that is neither 2xx nor 404 into `.failed`
  (`OnlineLyrics.swift:114-115`).
- `lookUp` returns `.failed` on a failed `/api/get` without searching
  (`OnlineLyrics.swift:219`).
- A failed search makes the lookup `.failed` when nothing else matched.
- `LyricsCoordinator` asks again after 5, 30 and 120 s while the same song
  plays (`LyricsCoordinator.swift:123`, `:250-260`), with up to three
  requests each time. One song that keeps failing can spend 12 requests.

A listener skipping through a playlist spends one to three requests a song.
The limiter counts refused requests (SPEC, politeness amendments), so the 5 s
retry lands inside the refusal it extends. Everyone behind one address — a
household, an office — shares the allowance.

**Recommendation.** Make a 429 its own outcome:

- Do not retry it on the per-song ladder.
- Back off the whole client for a long window: 30 minutes, or `Retry-After`
  when LRCLIB sends one.
- Keep showing cached lyrics meanwhile.

A fake transport in a unit test covers this without any LRCLIB traffic.

### 3. Uploads of one song disagree about when lines start (M9)

`Scripts/lyric-match-lab/noise.py` measured this from the cached pages (SPEC,
"M9 from the cached pages"):

- 46 tracks had a page and a known length.
- In 28 of them, two or more synced uploads matched the song within 2 s of
  its length. Those 257 uploads hold only 44 distinct timelines. Most uploads
  are copies of another, so choosing among copies changes nothing.
- 8 songs had distinct timelines that share at least 5 lines: 29 pairs.

| Between two distinct uploads | p50 | p90 | Share past a threshold |
|---|---|---|---|
| Constant offset | 0.01 s | 0.39 s | 21 % over 0.3 s, 3 % over 1 s |
| Line jitter after the offset | 0.04 s | 0.48 s | 15 % of lines over 0.25 s |

The sample is small and covers two slices (africa-caribbean-europe, 6 songs;
country-folk-songwriter, 2), so read the shares as an order of magnitude.

What they say: for a sizable minority of songs, whichever upload Isla picks
may be a third of a second away from another upload of the same song. That is
larger than the 0.20 s lead the owner tunes by ear. Sync Here fixes a constant
offset by hand, but not per-line jitter. On the matcher's side, the lever is
picking the upload closest to the consensus (M10), and it cannot be scored
until Isla's lookups are recorded.

### 4. One record in nine is stamped for a longer cut (M5 L10)

101 of 893 pool records with a length (11.3 %) have stamps more than 3 s past
their own listed length. The median overrun is 43 s. On the 2026-10-11 corpus
it is 61 of 535 (11.4 %), with a median of 56 s. Of those 61, the overrun
is:

- 3–10 s for 6;
- 10–30 s for 19;
- 30–60 s for 7;
- more than a minute for 29.

By category (2026-10-11 corpus, 15 to 48 tracks each):

| Category | Records stamped for a longer cut |
|---|---|
| short tracks and long intros | 6 of 15 |
| electronic with sparse vocals | 8 of 38 |
| J-pop and anime | 5 of 25 |
| Latin | 5 of 25 |
| jazz standards, classic rock, slow trap, duets and choirs | none |

Isla already handles this:

- It flags such a timeline (`LyricTimeline.overrun`, above
  `OnlineLyrics.durationTolerance` of 3 s).
- It prefers a row that fits.
- It offers Sync Here.

### 5. Isla's clock and parser are exact (M5)

M5 reruns the 2026-10-11 timing tests (`LyricAccuracyLab*`) on today's code.
It uses two corpora: the pool, which those tests have never seen, and the
2026-10-11 corpus. The third column is the earlier run's final rerun.

| Test | Pool, today (901) | 2026-10-11 corpus, today (540) | 2026-10-11 corpus, final rerun that day |
|---|---|---|---|
| L1 parse | 895 accepted; 46,765 lines exact to the ms; 0 text mismatches; 0 sung lines lost | 537 accepted; 0 refused that the reference reads; 24,230 lines exact | 536 accepted; 1 refused (36877652); 24,186 lines exact |
| L2 index | 204.3 M one-ms steps and 1.79 M seeks: 0 disagreements | 154.0 M steps, 1.07 M seeks: 0 | 153.7 M steps, 1.07 M seeks: 0 |
| L3 frame grid, perfect clock | 60 Hz p50 8.2, max 16.7 ms; 120 Hz p50 4.1, max 8.3 ms | 60 Hz p50 8.3, max 16.7 ms; 120 Hz p50 4.2, max 8.3 ms | the same |
| L5 word sweep | 0 invariant failures; edge lag p50 4.2, p95 8.3 ms at 120 Hz | the same | the same |
| L6 gaps | stale p50 0 s a track, p99 1.3 s; 1 mid-song gap (19 s) and 1 outro (11 s) lit over 8 s | stale p50 0 s; 0 mid-song gaps, 2 outros over 8 s | stale p50 0 s; 0 mid-song gaps, 2 outros |
| L8 surfaces | 1.64 M samples on three surfaces: 0 disagreements | 0.94 M: 0 | 0.94 M: 0 |
| L9 reading lead (Auto) | 44,301 of 45,870 line changes turn early; p5/p50/p95 0.336/0.408/0.500 s; 683 pulled under 0.30 s by the 45 % rule | 22,686 of 23,693; 0.336/0.412/0.500 s; 140 pulled under 0.30 s | a test added after that run |
| L10 longer cut | 101 of 893 (11.3 %), median overrun 43 s | 61 of 535 (11.4 %), median 56 s | a test added after that run |

L4 (timers) and L7 (lead calibration) do not depend on the lyrics and were
not rerun; the values from 2026-10-11 stand.

The pool's L6 verdict is `fail` because of one mid-song gap (19 s) and one
outro (11 s). Both are measured against `lyricsfile` line ends. Against LRC's
empty stamps, no pool track has a line lit more than 1.3 s too long in total.

The raw reports are `reports/m5-pool.json` and
`reports/m5-accuracy-2026-10-11.json` in the corpus root.

### 6. LRCLIB's two endpoints, and its 20-row cap (F-C, F-D)

- **`/api/get` returns the oldest match.** It takes the oldest upload whose
  normalised title, artist and album (when sent) match, within 2 s of the
  length. In LRCLIB's track repository this is `ORDER BY tracks.id LIMIT 1`.
  In 5 of the 7 found gets in the cache, that upload was on neither full
  search page for the same title and artist.
- **`/api/search` returns 20 rows.** They are the top 20 by BM25 over title
  and artist, ranked neither by length nor with synced uploads first. 98 of
  116 cached pages (84 %) are full.
- **An instrumental oldest upload stops Isla.** Isla returns no lyrics without
  searching (`OnlineLyrics.swift:208-213`). The mechanism is real, but the
  sample shows no case of it:
  - On the cached pages, uploads of a vocal song that match it in title and
    within 2 s of length are never flagged instrumental: 0 of 270, across 30
    songs.
  - On all vocal-song pages, 33 of 1,356 rows are flagged instrumental,
    against 748 of 767 on the pages of instrumental pieces.

  Candidate C4 searches anyway.

### 7. The album on `/api/get`: open (F-E, C8)

When a player names an album, LRCLIB's exact query requires the record's
album to match. Replaying LRCLIB's rule over the cached pages first suggested
that the album costs most tracks their exact answer. The twin's validation
then showed that a full page cannot settle this: older uploads past row 20
exist. Where a complete page makes the answer certain:

- Apple's album name cost the exact answer for 1 of 3 tracks.
- Deezer's cost it for 0 of 5.

Where the answer depends on the page, the counts are 16 of 20 and 15 of 20.
H8 is open, and C8 (send no album) waits for recorded traffic. SPEC, C8
amendment, has the tables.

### 8. Smaller findings

- **F-F: normalisation is Latin-only.** LRCLIB folds Latin diacritics only
  (ı→i, ø→o, ß→s). It leaves ё, й and Greek accents alone, and treats U+02BB
  and U+2018 as letters, not apostrophes. A player that writes "е" for "ё",
  or the reverse, misses the exact query. In this data the hazard is rare:
  ʻ appears in 1 of 465 harvest identities, ß in 1 of 901 pooled records,
  and ё nowhere.
- **F-G: the artist test is a substring test.** "sia" is inside "asia"
  (`OnlineLyrics.swift:334`). The title and the 3 s length window must also
  match, so this is rare. Candidate C7 matches whole words.
- **A bare `+` in a query is harmless (H3, refuted).** LRCLIB reads it as a
  space, the same as `%2B`.

## Candidates

Each candidate is a patch under `candidates/` that the lab branch never
applies (SPEC, "Counterfactual scoring"). Each was built in a scratch
worktree, and the 49 tests of `LyricsCoordinatorTests`,
`OnlineLyricsSearchTests` and `OnlineLyricsTests` ran against it:

- They all pass with each patch except C4 and C8.
- With C4, the one test that asserts the behaviour C4 changes
  (`testAnInstrumentalIsNotSearched`) fails, as intended.
- With C8, the one test that asserts the album is sent
  (`testTheRequestCarriesTheRecordingAndNothingElse`) fails, as intended.

| Candidate | Change | Finding | Scored |
|---|---|---|---|
| C1 | the cache keeps each hit's granularity | F-A | no |
| C3 | a search row's length may be 5 s off (was 3) | H6 | no |
| C4 | an instrumental `/api/get` answer no longer ends the lookup | F-C | no |
| C5 | a trailing ` - From …` is an edition in `baseTitle` | H5 | no |
| C6 | `primaryArtist` drops ` - Topic`, splits on `;` and ` / `, drops a leading `The ` | H5 | no |
| C7 | the artist must match on whole words | F-G | no |
| C8 | `/api/get` is sent without `album_name` | F-E, H8 | no |

None is scored, because a score needs Isla's recorded lookups. 4 of the 375
lookups are recorded; the rest are uncached.

## Recommendations

In order:

1. **Handle 429 apart from failures (F-H).** This protects every listener, not
   just the lab, and needs no LRCLIB traffic to build or test.
2. **Decide on a word-timed source.** It is the only route to word-by-word
   lyrics for most songs. It is the owner's call, because of terms of
   service, accounts and the privacy default.
3. **Then land C1 and decode `lyricsfile` (F-B).** Both are small and correct,
   but they reach almost nothing until a word-timed source exists.
4. **Record Isla's lookups from a local LRCLIB (below), or once LRCLIB
   answers again.** Then score every candidate in one replay. C8 goes first,
   because its page-bound signal is the largest (finding 7).
5. **After recording, measure M10.** It shows whether picking the upload
   closest to the consensus beats Isla's pick, given the spread in finding 3.

## What is owed

| Measurement | Needs |
|---|---|
| M1 accuracy, M2 perturbation robustness, M4 readability, M6 variant robustness, M10 selection | Isla's lookups for the 375 sampled variants: up to about 1,100 LRCLIB requests, fewer where the resolver already holds the answer |
| M3 word-timing fidelity, and scoring an estimate | word-timed truth: a word-timed source (finding 1) |
| The delay between a lit line and the heard voice | audio, so the owner's ear on real hardware; the lead stays 0.20 s by the owner's calibration |
| Hardware checks | the redesign checklist's run sheet |

There are two ways to get Isla's lookups:

- **A local LRCLIB, the practical way.** LRCLIB publishes database dumps
  (about 44.3 GiB gzipped). With a dump, the twin answers both endpoints
  exactly, for every harvested track, and no request leaves the machine. It
  needs the owner's permission and more free disk than the 54 GB this Mac has
  now.
- **LRCLIB's allowance returns.** A polite collector records the canonical
  lookups first: one pass at a time, 15 s apart, stopping at the first 429.
  At today's 1 to 6 answers per half hour this takes days. Even a fresh
  allowance covers only part of it: the day's first burst gave 119 answers
  before the refusals began.

## How to rerun

```bash
# Timing (M5), on any corpus of LRCLIB JSON records; no network
ISLA_LYRIC_CORPUS=<corpus> ISLA_LYRIC_REPORT=<report.json> swift test --filter 'LyricAccuracyLab'

# Catalogue timing noise (M9) from the cached pages; no network
python3 -I Scripts/lyric-match-lab/noise.py --root ~/code/_tools/isla-lyrics-lab

# The twin's validation against LRCLIB's own answers; no network
python3 -I Scripts/lyric-match-lab/twin.py validate --root ~/code/_tools/isla-lyrics-lab

# The lab's own tests
python3 -I Scripts/lyric-match-lab/selftest.py
```

Recording Isla's lookups and scoring a candidate are in SPEC: "The Swift
harness" and "Counterfactual scoring".

## Lab defects found and fixed in this run

The lab itself went through adversarial review before any of its verdicts
were trusted. Three reviews found defects in the lab, not in Isla, and each
fix is pinned by a test in `selftest.py` or `LyricMatchLabSelfTests`:

- **Truth.** A karaoke upload under another artist counted as a recoverable
  miss. A romaji or translated copy counted as the song. Accuracy depended on
  what Isla's own queries returned.
- **Requests.** LRCLIB requests are now paced 7.5 s apart, and 15 s while
  collecting. A request the resolver and Isla share is asked once. The first
  429 closes the host. A transport failure no longer reads as an answer.
- **Inputs.** The canonical lookups sent the harvest's research notes as the
  album name. They now send a real album name or none.
- **Scoring.** A candidate is now compared with a replay of the unpatched
  code over the same cache, never with a fresh run. A lookup unscorable on
  either side is neither a gain nor a loss.

The third review's fixes are on `feat/lyrics-match-lab-fixes-2`, pending
their own review and merge.
