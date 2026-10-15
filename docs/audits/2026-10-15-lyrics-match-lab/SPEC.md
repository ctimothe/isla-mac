# Lyrics match lab: specification

Written 2026-10-15. This is the contract every part of the lab follows: the
harvest, the Python resolver and classifier, and the Swift harness.

## Why a second lab

The 2026-10-11 Lyrics Accuracy Lab (`docs/audits/2026-10-11-lyrics-lab/`)
fetched 540 LRCLIB records **by id** and measured what Isla does with a record
it has already been handed: parsing, the line index, the clock, gaps, the
lead, and agreement between surfaces. By the end of that program it reported
no defects except the lead.

It never asked the question a listener asks first: **does Isla find the right
lyrics for the song that is playing?** That run picked songs that were already
in LRCLIB, so a catalogue gap could not show up. It also skipped Isla's
matcher, so a wrong song or a near miss could not show up either. It also had
only 2 real word-timed lines, so it never measured word-by-word timing.

This lab starts from what people actually play, in 16 genre and region slices.
Each song goes through Isla's real `OnlineLyrics.lookUp` with the metadata
real players report. The lab then scores the answer against an oracle that
does not share Isla's matching code.

## Questions (sections of the report)

- **M1 Lookup outcome:** for every (track, player variant), whether Isla showed:
  - the right song;
  - the right song timed for another cut;
  - the same song in another script;
  - a wrong song;
  - nothing, while a usable record existed;
  - nothing, because the catalogue has nothing usable.

  Reported per slice and per variant.
- **M2 Matcher stress, pure:** Isla's client-side matcher
  (`OnlineLyrics.bestCandidate`) over the search rows Isla's own canonical
  lookup received, with the identity perturbed in the realistic ways players
  differ. Edition suffixes, feat. placement, artist joiners, apostrophes,
  diacritics, width, case, transliteration, and durations at the tolerance
  edges are the perturbations. This section makes no network calls.
- **M3 Word timing:**
  - **Coverage:** in each slice, how many tracks have a word-timed record at
    all, and how many Isla can use.
  - **Fidelity:** whether Isla's parsers turn word-timed records into
    `.word` timelines with the right word starts.
  - **Estimation:** for line-only lyrics, how far each candidate estimator
    lands from real word onsets. The candidates spread a line's time across
    its words by:
    - equal shares for each word;
    - character count;
    - syllable count;
    - syllable count with a cap.
- **M4 Readability under stress:**
  - line duration, characters per second and syllables per second for each
    slice;
  - the share of lines too short to read;
  - the share of lines wider than the closed island's caption and the stage
    row, measured with the real fonts.
- **M5 Rerun of L1–L8:** the 2026-10-11 harness (`Scripts/lyric-lab.sh`) run
  unchanged on the records Isla actually chose here.
- **M6 Variant robustness:** songs that a canonical query finds but at least
  one real player's metadata loses.
- **M9 Catalogue timing noise:** where LRCLIB holds two or more independent
  synced records of the same song and length, the lab aligns their lines by
  text. It reports the constant offset and the residual jitter between them.
  This is the catalogue's own accuracy floor, measured without audio. It also
  shows whether choosing the record closest to the consensus would beat
  Isla's choice.
- **M10 Selection quality:** among several correct candidates, whether Isla
  picked the best one. Best means a better length fit, word timing, and
  closeness to the consensus.

The lab cannot measure the delay between a line lighting and the voice being
heard, because that needs audio. It is listed as owed to the owner.

## Layout

The corpus root is **`~/code/_tools/isla-lyrics-lab/`**. It is outside git
because it holds copyrighted lyric text. Nothing under it is ever committed.

```
slices/<slice>.json            harvest output, one file per slice (schema below)
conventions.json               what each player reports to Now Playing (research)
cache/py/<sha256(url)>.json    HTTP replay cache written by the Python resolver
cache/isla/<sha256(url)>.json  HTTP replay cache written by the Swift harness
resolved/tracks.jsonl          one line per resolved track: harvest + services + truth
resolved/variants.jsonl        one line per (track, variant) identity to look up
resolved/dropped.jsonl         harvested tracks no service could confirm, and why
wordtimed/<slice>/<id>.json    full LRCLIB objects that carry word timing
results/isla-lookups.jsonl     Swift: what Isla did for each (track, variant)
results/perturbations.jsonl    Swift: M2 rows
results/word-fidelity.json     Swift: M3 parser fidelity
results/readability.json       Swift: M4
matched/<slice>/<id>.json      Python, after the Swift run: the records Isla chose,
                               in the 2026-10-11 lab's corpus format, for M5
reports/match-lab-report.json  Python classifier: every section, numbers only
reports/rows.csv               Python classifier: one row per lookup with its verdict
```

**Cache file format** (both caches):

```json
{"url": "...", "status": 200, "body_b64": "...", "fetched_at": "ISO-8601"}
```

- The key is the lowercase hex SHA-256 of the exact URL string as sent.
- A network failure is never cached.
- An HTTP 404 is cached, because it is LRCLIB's answer for no record.
- *Amended 2026-10-15:* the Swift harness also looks a request up in the
  resolver's spelling (`MatchLab.resolverForm`): the same names and values in
  the same order, percent-encoded as Python's `quote(safe="")` does.
  URLComponents leaves `'()!,:;@/?$*` bare and Python does not, so an
  identical request had two keys and LRCLIB was asked twice. A bare `+` is a
  space to the server, so it is never matched to the resolver's `%2B`. An
  answer found this way is copied to `cache/isla` under Isla's own key, so
  every key a results file names is a file that exists.

## Rules for everything in the lab

- **Copyright.**
  - Lyric text lives only under the corpus root.
  - Reports, CSVs, logs and anything in git carry numbers, LRCLIB ids,
    titles and artist names, never a lyric line.
- **Politeness.** One process talks to a host at a time, with these minimum
  gaps between requests:

  | Host | Gap |
  |---|---|
  | `lrclib.net` | 1.0 s (raised from 0.6 s on 2026-10-15: both dev runs drew 429s at 0.6 s) |
  | `lrclib.net/api/search` | 7.5 s, on top of the host's 1.0 s (added 2026-10-15: the search endpoint answered 429 whenever requests came closer than about 6 s apart, which reads as about ten a minute) |
  | `lrclib.net`, every endpoint | 7.5 s (amended 2026-10-15, superseding the 1.0 s above: after a cooldown, `/api/get` at 1.0 s drew a 429 after five requests, so one limiter of about ten a minute covers the host) |
  | `itunes.apple.com` | 3.2 s |
  | `api.deezer.com` | 0.25 s |

  - Retry 429 and 5xx up to 3 times, backing off 2, 8 and 30 s. (Amended
    2026-10-15: a 429 backs off 30, 60 and 120 s instead. LRCLIB's limiter
    counts the requests it refuses, so quick retries only extended the ban.)
  - The resolver and the Swift harness never run against LRCLIB at the same
    time.
  - *Amended 2026-10-15, the collection budget.* At about ten requests a
    minute the full corpus needs about 2,100–2,500 LRCLIB requests (a cache-only
    count), four to six hours. Collection therefore runs in passes over
    `resolve.py --sample P,S` (the first P popular and S stress picks of every
    slice; ids keep their harvest index), each pass a resolver run and then a
    `--record` run, so every pass leaves a complete, scorable corpus that the
    next one extends. `--gap lrclib.net=<s>` and `ISLA_MATCH_LRCLIB_GAP=<s>`
    slow LRCLIB down for a run, and never below the table.
  - The lab's own requests send the User-Agent
    `isla-lyrics-lab/0.2 (https://github.com/ctimothe/isla-mac)`. Isla's
    requests in the Swift harness keep Isla's own User-Agent, because they
    are Isla's requests.
- **The running Mac.**
  - Nothing launches, kills or drives Isla.
  - No `DI_*` hook is set.
  - No screenshots are taken.
  - No test touches `UserDefaults.standard`, a real player, an audio device
    or the Accessibility prompt.
- **The gate.**
  - Every new Swift test throws `XCTSkip` unless `ISLA_MATCH_LAB` names the
    corpus root, so `./scripts/check` never runs or reads the lab.
  - No file under `Sources/` changes: the lab measures the shipped
    behaviour.
  - No new file may contain the words banned by `Scripts/test-branding.sh`.
- **Dependencies.** The Python is stdlib only (python3 3.15 is installed),
  with no pip and no third-party modules.

## Slices (16, about 30 harvested tracks each)

| # | slice id | covers |
|---|---|---|
| 1 | `pop-anglo` | US/UK/AU/CA pop hits 1980–2025 |
| 2 | `hiphop-rap` | US/UK hip-hop, fast and dense flows, drill, trap |
| 3 | `rock-metal-punk` | classic and hard rock, metal with harsh vocals, punk, grunge, long prog |
| 4 | `indie-slowcore-shoegaze-emo` | indie, slowcore, shoegaze (buried vocals), emo, bedroom pop |
| 5 | `rnb-soul-gospel-funk` | soul, 90s–now R&B, neo-soul, gospel and choirs, funk and disco |
| 6 | `country-folk-songwriter` | country, bluegrass, folk, Americana, wordy singer-songwriters |
| 7 | `jazz` | vocal standards, bossa nova, scat, and instrumentals named like vocal songs |
| 8 | `classical-soundtrack-instrumental` | movements, arias, choral, film and game scores, piano |
| 9 | `electronic-dance-lofi` | EDM, house, techno, DnB, vocal chops, remixes, lo-fi instrumentals |
| 10 | `latin` | reggaeton, Latin trap, bachata, salsa, regional Mexican, Brazilian, Spanish pop |
| 11 | `kpop-jpop-anime` | K-pop, J-pop, anime themes, vocaloid; Hangul, kana, kanji versus romanised titles |
| 12 | `cpop-southeast-asia` | Mandopop, Cantopop, Thai, Vietnamese, Indonesian, Filipino |
| 13 | `russian-cis-uzbek` | Russian rock, pop and rap, Ukrainian, Kazakh, Uzbek (oʻ and gʻ), Cyrillic versus Latin |
| 14 | `middle-east-south-asia` | Arabic, Persian, Turkish, Hebrew, Hindi/Bollywood, Punjabi, Tamil |
| 15 | `africa-caribbean-europe` | Afrobeats, Amapiano, Bongo Flava, reggae and dancehall, French, German, Italian, Nordic |
| 16 | `edge-metadata` | live, remaster, radio edit, remix, covers, same title as another song, very long, very short, symbol titles |

Within each slice:
- At least 20 tracks are **popular**. Each one cites a chart or list URL
  showing it is widely played.
- Up to 10 are **stress** picks, each with tags and a one-line reason.
- An artist appears at most twice.

## Harvest schema (`slices/<slice>.json`)

```json
{"slice": "kpop-jpop-anime", "harvested_by": "H6", "tracks": [{
  "title": "紅蓮華",                 // as on the original release, native script
  "title_latin": "Gurenge",          // romanised/English form services show; "" if the same
  "artists": ["LiSA"],               // credited main artists, native script, primary first
  "artists_latin": ["LiSA"],         // same order; "" entries where identical
  "featured": [],                    // featured artists, native script
  "album": "紅蓮華",
  "year": 2019,
  "language": "ja",                  // ISO 639-1; "zxx" for no lyrics
  "vocal": "full",                   // full | sparse | none
  "pick": "popular",                 // popular | stress
  "tags": ["non-latin-title", "chart-top"],
  "source_url": "https://...",
  "why": "Oricon 2020 year-end #3"
}]}
```

The tag vocabulary is:

| Kind | Tags |
|---|---|
| Rhythm and density | `fast-rap`, `dense-lyrics`, `melisma`, `sparse-vocals` |
| Time | `long-gaps`, `long-intro`, `very-long`, `very-short` |
| Version | `instrumental`, `live`, `remaster`, `radio-edit`, `remix`, `cover` |
| Title clashes | `same-title-other-song` |
| Credits | `feat`, `multi-artist` |
| Script and characters | `non-latin-title`, `non-latin-artist`, `mixed-script`, `rtl`, `diacritics`, `symbols-in-title`, `numeric-title`, `parenthetical-title` |
| Vocal style | `duet`, `choir`, `spoken-word`, `harsh-vocals` |
| Form | `repeated-chorus`, `medley`, `classical-movement`, `soundtrack` |
| Other | `explicit-clean`, `chart-top`, `other-language-version` |

## Resolution (`Scripts/lyric-match-lab/resolve.py`)

For each harvested track:

1. **Apple Music identity.**
   - Search `https://itunes.apple.com/search?term=…&entity=song&limit=10&country=<cc>`
     in the slice's storefront:

     | Slice | Storefront |
     |---|---|
     | `kpop-jpop-anime` | `kr` for Korean tracks, `jp` for Japanese |
     | `cpop-southeast-asia` | `tw` |
     | `russian-cis-uzbek` | `kz` |
     | `middle-east-south-asia` | `ae` for Arabic, `tr` for Turkish, `in` for Indian, `us` otherwise |
     | `latin` | `mx`, or `br` for Portuguese |
     | `africa-caribbean-europe` | `ng`, or `fr`/`de`/`it` by language |
     | every other slice | `us` |

   - If the storefront has no match, try `us`.
   - Pick the best match by the lab's own normalizer.
   - Keep `trackName`, `artistName`, `collectionName`, `trackTimeMillis`,
     `trackId` and `primaryGenreName`.
2. **Deezer identity.**
   - Search `https://api.deezer.com/search?q=artist:"…" track:"…"`, then a
     plain `q=` fallback.
   - Keep `title`, `title_short`, `title_version`, `artist.name`,
     `album.title`, `duration` (integer seconds) and `id`.
3. **Drop.** A track neither service can confirm (artist and title both
   matching) goes to `dropped.jsonl` with the reason. It is probably invented
   or too obscure, and is not scored.
4. **LRCLIB candidates.**
   - Collect them with these queries:
     - `GET /api/get` (canonical title, primary artist, album, Apple
       duration); *amended 2026-10-15:* every credited artist joined with
       ", " and the duration rounded half away from zero, which is exactly
       the canonical variant's first lookup, so one request serves the truth
       pool and Isla;
     - `GET /api/search?track_name=&artist_name=`;
     - `GET /api/search?q=<title> <artist>`;
     - the same two searches with the Latin forms, when they differ.
   - De-duplicate by `id`.
   - Search rows carry `syncedLyrics`, `plainLyrics`, `lyricsfile`,
     `hasWordSync`, `instrumental` and `duration`.
5. **Oracle**, independent of Isla's matcher: it shares no code with
   `OnlineLyrics.comparable`, `baseTitle` or `primaryArtist`.
   - *Normalizer:*
     - NFKC, casefold, and removal of combining marks;
     - punctuation and symbols turned into spaces;
     - spaces collapsed.

     For titles it also removes:
     - bracketed segments of any bracket family;
     - `feat.`/`ft.`/`featuring` clauses;
     - a trailing ` - <edition>`.
   - *Anchor records:*
     - The normalized title equals the native or Latin title, or the
       Apple/Deezer title.
     - Any harvested artist, native or Latin, or the Apple/Deezer artist, is
       a token subsequence of the record's normalized artist, or the reverse.
   - *Text fingerprint:* a record's words are taken from `plainLyrics`, or
     from `syncedLyrics` with the stamps stripped.
     - For text without spaces (Han, kana, Thai) the shingles are character
       bigrams.
     - Otherwise they are word 3-shingles, falling back to word bigrams for
       short texts.
   - *Similarity:* containment |A∩B| / min(|A|,|B|).
   - *Same-song cluster:* the anchors plus every candidate with containment
     of at least 0.6 against any anchor.
   - *Other script or translation:* the title and artist match, but the
     record's dominant script differs from the anchors' dominant script.
   - *Expected instrumental:* the harvest says `vocal: none`, or an LRCLIB
     anchor has `instrumental: true`. Any disagreement is recorded.
6. **Truth per variant duration.** `synced_fit` holds the ids of same-song
   records that have synced lyrics, where:
   - the record's duration is within 3 s of the variant's duration, and
   - the last sung stamp is no later than duration + 3 s.

   `synced_near` covers 3–10 s. `plain_only` is true when the cluster has
   plain lyrics only.
7. **Variants** (`variants.jsonl`, up to five per track):

   | Variant | Title | Artist | Album | Duration |
   |---|---|---|---|---|
   | `canonical` | harvest title | `", "`-joined harvest artists | harvest album | Apple, else Deezer, else 0 |
   | `apple` | iTunes `trackName` | iTunes `artistName` | iTunes `collectionName` | iTunes `trackTimeMillis` / 1000 |
   | `deezer` | Deezer `title` | Deezer `artist.name` | Deezer `album.title` | Deezer `duration` |
   | `spotify-style` | see below | all credited artists joined `", "` | harvest album | Apple duration |
   | `latin-alt` | Latin forms | Latin forms | harvest album | Apple duration |

   - `spotify-style` builds its title from:
     - the canonical title;
     - ` - <Edition>` when Apple or Deezer names a remaster, live or edit;
     - ` (feat. A, B)` when there are featured artists.

     Its rules sit in one table at the top of the script and are adjusted to
     `conventions.json`.
   - `latin-alt` exists only when the native and Latin forms differ.

   Each line is
   `{track_id, slice, variant, player_id, title, artist, album, duration}`,
   where `track_id` is a stable slug such as `kpop-jpop-anime/014`.
8. **Word timing.** Every candidate whose `lyricsfile` holds word entries, or
   whose `syncedLyrics` holds `<mm:ss.xx>` word tags, is written under
   `wordtimed/<slice>/<id>.json`, whether it is same-song or not.

> **Amended 2026-10-15 (after the harvest).** The harvest delivered 465
> tracks, which fell short of the plan in four ways:
> - 149 have no album and 130 no year;
> - only 16 of the 58 non-Latin titles carry a Latin form;
> - 2 tracks appear twice;
> - only 32 are instrumental.
>
> The resolution changes as follows:
> - **Duplicates.** A track whose normalized title and primary artist repeat
>   an earlier one goes to `dropped.jsonl` as `duplicate`.
> - **Canonical album.** `canonical` takes the harvest album, else Apple's
>   `collectionName`, else Deezer's album. This keeps the album-less request
>   out of the canonical figures; the `no-album` variant measures it instead.
> - **New variant `no-album`.** This is `canonical` with the album empty, for
>   every fourth track (index % 4 == 0). Players that report no album do
>   exist: browsers and radio. Isla then omits `album_name` from `/api/get`.
> - **New variant `apple-us`.** This is the iTunes result from the `us`
>   storefront, for tracks resolved in another storefront whose US title or
>   artist differs. It is what an English-locale account sees, and is often
>   romanised.
> - **Oracle aliases.** The Latin forms of a track now include a
>   deterministic BGN/PCGN transliteration of Cyrillic titles and artists,
>   and the `apple-us` names. Without them, Latin-only LRCLIB uploads of a
>   Cyrillic song had no anchor. These aliases feed anchor matching only.
>   They never become a variant, except where the harvest gave a Latin form.

## The Swift harness (`Tests/IslaKitTests/LyricMatchLab*.swift`, `Scripts/lyric-match-lab.sh`)

It runs only with `ISLA_MATCH_LAB=<root>`. Live requests on a cache miss are
allowed only when `ISLA_MATCH_RECORD=1`; otherwise a miss is recorded as
`uncached`.

- **Lookups (M1/M6).**
  - For each line of `variants.jsonl`, call
    `OnlineLyrics.lookUp(identity, transport: replay)` in sequence.
  - Recover the id of the record behind the returned timeline: parse each
    record the lookup received through Isla's own path, and take the one
    whose lines match.
  - Write one line to `isla-lookups.jsonl`:
    `{track_id, variant, identity, outcome (found|none|failed|unreadable|uncached), chosen_id, chosen_via (get|search), granularity, lines, overrun, timed_for_longer, requests:[{key, path, status, cached}], ms}`.
- **Perturbations (M2).**
  - For each track whose canonical lookup ran a search, take the rows of
    every search response that lookup received.
  - Call `OnlineLyrics.bestCandidate(in: rows, for: perturbed)` for each
    perturbation and record the id it picks:

    | Kind | Perturbations |
    |---|---|
    | Title suffixes | ` - Remastered 2011`, ` (Remastered 2009)`, ` - Radio Edit`, ` (feat. X)`, ` (Official Video)` |
    | Artist forms | `A, B`; `A & B`; `A feat. B`; `A x B`; `A - Topic`; `The ` added or removed |
    | Characters | curly and straight apostrophes swapped; diacritics stripped; upper case; full-width forms; doubled spaces |
    | Script | the Latin title and artist |
    | Duration | +2.5 s, +3.5 s, −3.5 s |
- **Word fidelity (M3).**
  - Parse every `wordtimed/` record through Isla's own path, as an online
    answer and, for enhanced LRC, as a local document.
  - Compare the result with the lab's independent `LyricsFile` and
    `ReferenceLRC` readers in `LyricAccuracyLabSupport.swift`:
    - the granularity Isla produced;
    - words matched;
    - the error in each word's start;
    - any refusals.
- **Readability (M4).**
  - Use the timeline Isla chose for each `canonical` lookup.
  - Report line durations, characters per second, and syllables per second
    (from a per-script heuristic).
  - Report the share of lines under 0.6 s and under 1.0 s.
  - Report the share of lines wider than the closed island's one-line caption
    and the stage row, at their real widths and fonts as the code defines
    them, measured with AppKit text layout.

## Classification (`Scripts/lyric-match-lab/classify.py`)

The classifier joins `isla-lookups.jsonl` with the truth. Each lookup gets one
verdict:

| Verdict | Meaning |
|---|---|
| `correct` | in the same-song cluster and no overrun past tolerance |
| `correct-longer-cut` | same song, overrun beyond 3 s |
| `alt-script` | same song in another script or translation |
| `wrong-song` | containment ≤ 0.2 against the cluster, or any lyric for an expected instrumental (flagged `instrumental-fp`) |
| `uncertain` | containment between 0.2 and 0.6 |
| `miss-rejected` | Isla returned nothing, though one of the responses Isla itself received held a `synced_fit` record (a client-side matcher defect) |
| `miss-unqueried` | Isla returned nothing; a `synced_fit` record exists, but none of Isla's queries returned it (a query-construction defect) |
| `miss-tolerance` | only `synced_near` records exist |
| `miss-plain-only` | the cluster has plain lyrics only, which are not shown by design |
| `miss-catalogue` | no usable record |
| `correct-none` | an expected instrumental, and nothing shown |
| `unreadable` | Isla's parser refused the record |
| `failed` / `uncached` | no answer could be obtained |

The headline figures are worked out for each slice and variant:
- **Accuracy:** `correct` / (every lookup where a usable answer existed).
- **Wrong rate:** `wrong-song` + `correct-longer-cut` + `uncertain`, out of
  everything shown.
- **Recoverable misses:** `miss-rejected` + `miss-unqueried`.

M3 estimation, M9 and M10 are computed here from the cached records.
`matched/` is written here for M5.
