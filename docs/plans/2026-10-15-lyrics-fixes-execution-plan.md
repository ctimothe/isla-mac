# Lyrics fixes — execution plan (2026-10-15)

Turns the Lyrics Match Lab's findings
(`docs/audits/2026-10-15-lyrics-match-lab/REPORT.md`) into work that can be
landed, in order. Every step names its branch, the code it touches, the tests
written first, how it is verified and who reviews it. Nothing here is started
until the owner says go; the three owner decisions are at the end.

Code references are to `main` at `e20b9d5` (0.3.0) for the lookup and cache,
and to `feat/redesign-r5-hud` at `33bf2ed` for the stage. `OnlineLyrics.swift`
and `LyricsCoordinator.swift` are byte-identical on both, so phases 1 and 2
branch from `main` and merge into the redesign chain without conflict.

## Order at a glance

| # | Fix | Tier | Branch (from) | Waits on | Ships |
|---|---|---|---|---|---|
| 1 | LRCLIB rate limits: stop at a 429, honour Retry-After | 2 | `fix/lyrics-rate-limit` (`main`) | nothing | alone, as 0.3.1 |
| 2 | Cached word timing survives; lyricsfile words decoded | 2 | `fix/lyrics-word-timing` (`main` after 1 merges) | phase 1 merged | with the next release after 0.3.1 |
| 3 | Lyric column wraps a long line to two rows | 2 | `fix/redesign-lyrics-two-rows` (`feat/redesign-r5-hud`) | D1 | with the redesign |
| 4 | Score match accuracy (M1) and candidates C3–C8 | — | lab branch | D2, and the LRCLIB ban lifting | each winner as its own Tier 2 fix |
| 5 | A licensed word-timed source | — | none (research) | D3 | not before a decision |

Phases 1–3 are implemented one at a time, never in parallel: phases 1 and 2
both edit `OnlineLyrics.swift`. If D1 arrives while phase 2 is running,
phase 3 goes next, because it fixes more visible damage (13–19 % of lyric lines
cut at 560 pt, against word timing in 2 of 1,441 records).

Every phase ends the same way, per `CLAUDE.md` §"After each change":

1. The phase's filtered tests pass (`swift test --filter …`).
2. The full gate passes: `./scripts/check`, run with the
   `com.apple.dt.xctest.tool` defaults domain exported, deleted and imported
   back afterwards. That domain leaks `showLyrics=1` into tests (memory
   "isla-test-machine-leaks").
3. A commit with the ctimothe identity and no trailers.
4. `bash Scripts/bundle.sh release`, then `bash Scripts/install.sh`.
   Never `open` the build copy.

No subagent launches, kills or drives Isla, sets a `DI_*` hook, runs
`./scripts/check` or `test-helper.sh`, or touches `UserDefaults.standard`. The
driver runs the gate and the install.

---

## Phase 1 — rate limits (`fix/lyrics-rate-limit`)

**Why.** LRCLIB itself answers overload with `503` plus `Retry-After: 1`
(`server/src/errors.rs:78-90`). The `429`s that banned this address on
2026-10-15 come from a layer in front of the server. Isla treats both like any
other failure:

- `read()` maps every non-2xx except 404 to `.failed`
  (`OnlineLyrics.swift:114-115`);
- the search loop `continue`s past a failed query (`OnlineLyrics.swift:228-245`);
- the coordinator then retries that one song at 5, 30 and 120 s
  (`LyricsCoordinator.swift:123`, `:250-260`, `:473`).

Under a 429, each song therefore costs about 4 requests, plus up to 3 retries,
and the next song starts the same again. The fix follows the official
guidance:

- RFC 9110 §10.2.3 and §15.6.4, and RFC 6585 §4: honour Retry-After, given
  either as delay-seconds or as an HTTP-date;
- AWS Builders' Library: retry at one layer only;
- Google Cloud: capped exponential backoff with jitter.

**Behaviour after the fix.**

- **A 503 with Retry-After ≤ 5 s:** wait that long and send the same request
  once more. A second 503, or a 503 with a longer or missing Retry-After,
  returns `.failed`, and today's per-song ladder takes over.
- **A 429 on any request (exact query or search):** the lookup stops at once
  and sends no further requests. It returns a new outcome,
  `.limited(retryAfter: TimeInterval?)`. If an earlier request in the same
  lookup already found an answer that runs past the track's end, that answer
  is returned instead, by today's rule that a found lyric is never turned into
  a miss; the next song's first request meets the 429 and arms the pause.
- **Any 5xx during the search** (after the 503 rule above) also stops the
  search loop. The next query would meet the same overloaded server.
- **Retry-After is read in both RFC forms.** A delay in seconds, or an
  HTTP-date measured against the response's own `Date` header (or the local
  clock when that header is missing). An unparseable value counts as absent.
  Values over 24 h are held to 24 h, so a nonsense header cannot silence
  lyrics for longer.
- **A client-wide pause, owned by `LyricsCoordinator`.** The pause lasts for
  Retry-After when given. Otherwise it is 60 s, doubling with each consecutive
  429, capped at 30 min. The first 2xx resets the backoff. The jitter is
  "equal jitter": a draw between half the backoff and all of it. Full jitter
  was planned first, but a draw near zero would re-ask straight into the same
  429. (Amended 2026-10-15, while briefing phase 1.)
- **While paused:**
  - no lookup reaches the network;
  - cached hits and believed misses still show;
  - nothing is cached as a miss;
  - no per-song ladder runs;
  - `refreshOldHit` (`LyricsCoordinator.swift:499`) is also held.

  When the pause ends, one wake asks about the song now playing, and only that
  song.
- **What the user sees** while paused is today's failed state
  (`onlineFailed = true`). There are no new strings, so `en`/`ru` parity is
  untouched.
- **The pause lives in memory only.** A relaunch forgets it. This is accepted:
  the first request after a relaunch meets the 429 again and re-arms it.
  Persisting it would mean `UserDefaults`, which the tests must not touch.

**Code.**

- `OnlineLyrics.swift`:
  - the `Outcome` case;
  - status checks in `lookUp` (`:206`) and in the search loop (`:231`);
  - a `retryAfter(from: HTTPURLResponse, now: Date)` parser;
  - an injected `sleep: @Sendable (Duration) async -> Void` for the 503 wait,
    so tests never sleep.
- `OnlineLyricsCache.remember` (`:545`) treats `.limited` like `.failed`
  and stores nothing.
- `LyricsCoordinator.swift`:
  - a small `OnlineLyricsPause` value: `until`, consecutive count, and an
    injected jitter `(ClosedRange<Double>) -> Double`;
  - checks in `lookUpOnlineIfNeeded` and `refreshOldHit`;
  - `scheduleRetry` is skipped while paused.
- Every `switch` over `Outcome` is reviewed. The compiler finds them; today
  they are `OnlineLyrics.swift:219` and `:566`.

**Tests, written first** (fake transport and an injected clock; no network, no
real sleep):

- `OnlineLyricsTests`:
  - `testA429OnTheExactQueryStopsTheLookUp`: 1 transport call, outcome
    `.limited`.
  - `testA429OnASearchStopsTheRemainingQueries`: calls stop at the 429.
  - `testRetryAfterReadsSecondsAndAnHTTPDate`, and the unparseable case.
  - `testA503WithAShortRetryAfterIsAskedOnceMore`: 2 calls, then found.
  - `testASecond503Fails`, and `testA503WithALongRetryAfterFailsWithoutWaiting`.
- `LyricsCoordinatorTests`:
  - `testALimitedAnswerPausesEveryLookUp`: a second song during the pause makes
    0 transport calls.
  - `testNoRetryLadderRunsWhilePaused`.
  - `testCachedLyricsStillShowWhilePaused`.
  - `testALimitedAnswerIsNeverRememberedAsAMiss`.
  - `testBackoffDoublesAndCapsWithoutRetryAfter`.
  - `testASuccessResetsTheBackoff`.
  - `testThePauseEndingAsksOnlyTheSongPlaying`.

**Verify.**

```bash
swift test --filter OnlineLyricsTests
swift test --filter LyricsCoordinatorTests
```

Then the gate, commit, bundle and install. A live check against LRCLIB is not
part of this, because of the ban.

**Agents.** One implementer (Sonnet, high), briefed with this section. Then one
adversarial reviewer (Opus, high), told to find any path that still sends a
request after a 429. Whoever wrote the change never reviews it.

**Ships alone** as 0.3.1 when the owner says ship. After it merges, merge
`main` into `feat/redesign-r5-hud` and into `feat/lyrics-match-lab`, each with
an explicit merge commit.

---

## Phase 2 — word timing that survives (`fix/lyrics-word-timing`)

**Why.** A fresh lookup keeps an enhanced LRC's `.word` granularity, but the
cache rebuilds every hit as `.line` (`OnlineLyrics.swift:524`), so every later
play of the song loses karaoke. Isla also never reads LRCLIB's `lyricsfile`
field, which is the only place most word timing on LRCLIB lives. The lab's
reader reproduced `syncedLyrics` line starts exactly: 46,765 of 46,765 in the
pool and 24,229 of 24,230 in the 2026-10-11 corpus. Today's reach is small
(2 of 1,441 records carry words), so this phase is about correctness and
readiness, not visible change.

**Simpler than candidate C1.** C1 stores a new `granularity` field in each
cache entry. That is not needed: entries already persist each line's `words`
(`LyricsStore.Line` is `Codable` with `words`). Granularity is a pure function
of the lines, the one `LocalLyricsDocument.granularity` already uses (`:73-75`):

```swift
lines.contains { !$0.words.isEmpty } ? .word : .line
```

Move that rule to one home, `LyricTimeline.granularity(of:)`, and have both the
document and `OnlineLyricsCache.cached` call it. The result:

- the cache format stays at 3, with no new field;
- no old hit is fetched again (a format bump would have re-asked LRCLIB about
  up to 1,000 cached songs);
- old hits that already hold words get karaoke back immediately.

This is also why the phase is Tier 2, not Tier 3: nothing persisted changes
shape. If review finds that a format bump is needed after all, the phase
becomes Tier 3 (worktree, written plan, Codex review) before it continues.

**lyricsfile.**

- **Decode it.** Add `lyricsfile: String?` to `OnlineLyrics.Response` and
  `SearchRow`.
- **Port the lab's reader** (`LyricsFile.parse`, `LyricAccuracyLabSupport.swift`,
  from line 474) into `Sources/IslaKit/Services/` as `LRCLIBLyricsFile`. It is
  line-based, reads only `lines: [{text, start_ms, end_ms, words?}]`, does no
  recursion and no general YAML, and runs in linear time.
- **Use it only when it carries words.** At least one line must have words,
  starts must be non-decreasing, and every word must sit inside its line.
  Otherwise the `syncedLyrics` path runs exactly as today. Map it to
  `LyricsStore.Line` and `LyricWord`, so `reachable`, `fits` and `overrun`
  apply unchanged.
- **Cap the input.** A `lyricsfile` over 256 KB is ignored.
- **Fix the doc comment** at `OnlineLyrics.swift:15-17`. It still says every
  online timeline is `.line`, which has been false for enhanced LRC all along.
  Rewrite it to state what Isla now reads.

**Tests, written first.** Fixtures are synthetic text, never real lyrics.

- `OnlineLyricsTests`:
  - `testACachedHitWithWordsComesBackAsWordTiming`;
  - `testACachedHitWithoutWordsStaysLineTiming`;
  - `testAHitCachedBeforeThisChangeWithWordsRegainsWordTiming` (a format-3
    entry written by hand).
- New `LRCLIBLyricsFileTests`:
  - lines and words decode;
  - a file without words is not used;
  - out-of-order starts fall back;
  - a word outside its line falls back;
  - oversize input is ignored;
  - malformed YAML returns nothing and never crashes.
- `OnlineLyricsTests`: `testLyricsfileWordsWinOverLineOnlySyncedLyrics` and
  `testSyncedLyricsStillRunsWhenLyricsfileIsAbsent`.
- Lab check (not a gate): rerun the L5 word-sweep lab test on the branch. Its
  report field `reachableForLRCLIB` should then read reachable after the cache.

**Verify.**

```bash
swift test --filter OnlineLyricsTests
swift test --filter LRCLIBLyricsFileTests
```

Then the gate, commit, bundle and install.

**Agents.** One implementer (Sonnet, medium): the brief states what done looks
like. Two reviewers:

- Opus (high), because the change parses untrusted network input;
- Codex (`codex exec review --base main`), the second model family.

---

## Phase 3 — two-row lyric column (`fix/redesign-lyrics-two-rows`)

**Why.** The redesign's stage draws one row per line (`lineLimit: 1`,
`LyricsStage.swift:613`, in a fixed `.frame(height: pitch)` at `:406`). At the
default 560 pt width, the column beside the cover cuts 13–19 % of lyric lines
(fast rap 46 %). 0.3.0's stage wraps to two rows (`main:LyricsStage.swift:504`).
Apple's HIG asks to keep truncation to a minimum.

Counted directly, a two-row column would still cut:

- **at 560 pt:** 0.15 % of lines (pool 0.26 %);
- **at 480 pt:** 3.3 % (3.1 %).

Hence D1.

**Change, pending D1.**

- **Rows wrap.** Each row takes `lineLimit: 2` (or 3 in the column below the
  width D1 picks), with `.fixedSize(horizontal: false, vertical: true)`.
- **Row count is laid out at the sung weight.** It is measured with the
  `.bold` metrics for every row, context rows included. A line must not grow a
  row at the moment it lights: column context is `.semibold` and the sung line
  `.bold` (`Metrics`, `LyricsStage.swift`), and the wider weight is the one
  that wraps.
- **Row height becomes `pitch × rows`.** The slot model stays: one slot per
  line or interlude, so `LyricSweep.slotIndex` and its clock arithmetic are
  untouched. The comment at `:382-384` saying every slot is the same height is
  rewritten.
- **Scroll anchor uses the reading row's own height.** `anchorUnit` and `air`
  (`:375-376`, defined at `:333` and `:343`) now take the height of the row being held
  instead of the fixed pitch. Otherwise a two-row line lands half a row off the
  reading centre: the error is `(0.5 − anchor) × slot`, which the existing doc
  comment already derives. `scrollPosition(id:anchor:)` itself handles mixed
  heights, as 0.3.0's stage shows (`main:LyricsStage.swift:342`).
- **Translated rows** (`metrics.slot(translated:)`) keep their own second row,
  and a wrapped line adds to it.
- **Spec.** Amend `docs/plans/2026-10-15-redesign-spec.md` §5.1 in place,
  dated, citing the lab figures. Never rewrite the original text.

**Tests, written first.**

- `LyricsStageScrollTests`: anchor unit and air for a two-row reading row; a
  two-row line lands centred.
- `LyricsStageRenderTests`: at 560 pt, a long synthetic line renders in two
  rows with no ellipsis; at 480 pt, the D1 behaviour.
- A row does not change height when it lights.
- Lab check: rerun the M4 readability lab test on the branch. Expected:
  column@560 cut share ≤ 0.15 % (pool ≤ 0.26 %), and the 480 figure D1 chose.

**Verify.**

```bash
swift test --filter LyricsStage
```

Then the gate, bundle and install. Add one owner check to `checklist.md`
§"Redesign — 2026-10-15": on notch hardware, a long line at 560 pt and at
480 pt, read while it plays.

**Agents.** One implementer (Sonnet, high). One reviewer (Opus, medium): the
anchor maths needs judgement across the stage.

**Ships with the redesign.** It must land before the redesign chain merges.

---

## Phase 4 — match accuracy (M1) and candidates C3–C8

**Why.** Whether Isla picks the right lyrics (M1) is what the lab was asked
for. M1 needs Isla's lookups answered as LRCLIB would answer them. The live
service banned this address, so the plan is a local copy.

**Steps** (the driver runs them, one network process, nothing in parallel):

1. **With D2:** download the LRCLIB database dump.
   - It is about 44.3 GiB gzipped; 56 GiB is free on 2026-10-15.
   - The uncompressed size is not yet known. Confirm it with the owner before
     downloading. If it will not fit, decompress while downloading onto an
     external disk.
   - Download only after `~/code/_tools/isla-lyrics-lab/logs/probes.tsv` shows
     the ban has lifted. Stop at the first 429, and never change address or
     client to get around one.
2. **Build LRCLIB's own server** from the source already extracted
   (`cargo` is installed), pointed at the dump, on localhost.
3. **Validate the local twin.** Its answers to the 129 cached LRCLIB answers
   must match (`Scripts/lyric-match-lab/twin.py`) before anything is scored.
4. **Record Isla's lookups for every corpus** against localhost through the
   injected transport. Lyric text stays under `~/code/_tools/isla-lyrics-lab/`.
5. **Score.** First a control run
   (`bash Scripts/lyric-match-lab/score-candidate.sh <root> <worktree> control`),
   then C3–C8 one at a time. M10 (consensus pick) is scored the same way.
6. **Land each winner** as its own Tier 2 branch from `main`, with the
   candidate's own test made permanent.

**Agents.** None for the network steps. A Sonnet (medium) implementer per
winning candidate, with an Opus (medium) review.

---

## Phase 5 — a licensed word-timed source (research only)

Apple Music and Spotify offer no lyrics API. Musixmatch's plans and terms could
not be read and are unverified. If D3 says go, one read-only scout
(Haiku, high, web only, one host at a time) collects terms, price and
word-timing coverage. That leads to a written decision, not code. Anything that
results must follow `CLAUDE.md`'s rule for capabilities that leave the machine:
record it in `checklist.md` and default it to off.

---

## No change needed

Each was checked by the lab and the reviews:

- the User-Agent;
- L10's length handling;
- the timing maths (M5);
- LRCLIB record 36777161;
- Latin-only normalisation, which is upstream behaviour.

## Owner decisions

- **D1 — the two-row lyric column.**
  - Approve amending spec §5.1 so a line may take two rows.
  - Choose how 480 pt is handled: a third row in the column below some width,
    or a wider column there. The two-row column still cuts 3.3 % of lines at
    480 pt.
- **D2 — the LRCLIB dump.**
  - Permission to download it (about 44.3 GiB gzipped; uncompressed size to
    confirm).
  - Where it lives, if the disk is short.
- **D3 — a licensed source.** Whether phase 5 is worth starting.

Phase 1 needs no decision, only a go. It then ships when the owner says ship.
