#!/usr/bin/env python3
"""Corpus-level analyses for the lyrics match lab (phase 2). Imported by classify.py.

    M3 estimation  how far candidate word-timing estimators land from real word onsets
    M9             catalogue timing noise: how much independent synced records of one song disagree
    M10            selection quality: did Isla pick the best of several correct records

Pure functions and small accumulator classes; nothing here reads the disk or the
network. classify.py loads records and feeds them in, one track at a time, so
no more than one track's lyric text is in memory at once. Reports built from
these hold numbers only.
"""
from __future__ import annotations

import difflib
import itertools
import math
import re
import statistics
import unicodedata
from typing import Dict, Iterable, List, Optional, Tuple

import oracle

# --------------------------------------------------------------------------
# Statistics
# --------------------------------------------------------------------------

def percentile(values: List[float], p: float) -> Optional[float]:
    """Linear-interpolated percentile (p in 0..100); None for no data."""
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return float(ordered[0])
    rank = (len(ordered) - 1) * p / 100.0
    low, high = int(math.floor(rank)), int(math.ceil(rank))
    return float(ordered[low] + (ordered[high] - ordered[low]) * (rank - low))


def share(count: int, total: int) -> Optional[float]:
    return round(count / total, 4) if total else None


def summarize(values: List[float], within: Tuple[float, ...] = ()) -> dict:
    """n, p50, p90, and the share of values at or below each `within` bound."""
    out = {"n": len(values), "p50": _r(percentile(values, 50)), "p90": _r(percentile(values, 90))}
    for bound in within:
        out[f"within_{int(round(bound * 1000))}ms"] = share(sum(1 for v in values if v <= bound), len(values))
    return out


def _r(value: Optional[float], digits: int = 4) -> Optional[float]:
    return None if value is None else round(value, digits)


# --------------------------------------------------------------------------
# Syllables
# --------------------------------------------------------------------------

_LATIN_VOWELS = set("aeiouyàáâäãåæèéêëìíîïòóôöõøùúûüýÿœ")
_CYRILLIC_VOWELS = set("аеёиоуыэюяіїєәөұү")
_GREEK_VOWELS = set("αεηιουωάέήίόύώϊϋΐΰ")
_SMALL_KANA = set("ゃゅょぁぃぅぇぉゎャュョァィゥェォヮ")
_THAI_CONSONANTS = {chr(c) for c in range(0x0E01, 0x0E2F)}


def _vowel_groups(word: str, vowels: set) -> int:
    count, previous = 0, False
    for ch in word:
        is_vowel = ch in vowels
        if is_vowel and not previous:
            count += 1
        previous = is_vowel
    return count


def syllables(word: str) -> int:
    """Syllables (morae for Japanese) of one word, by a per-script heuristic.

    Deliberately crude: what the lab needs is a weight that grows with how long
    a word takes to sing, and a count that is wrong by one on an English word
    changes the estimators' ranking far less than the choice of weight does.
    Always at least 1.
    """
    text = unicodedata.normalize("NFKC", word or "").casefold()
    count = 0
    latin_run: List[str] = []
    cyr_run: List[str] = []
    greek_run: List[str] = []
    indic_letters = 0
    indic_virama = 0
    other_letters = 0
    for ch in text:
        script = oracle.char_script(ch)
        category = unicodedata.category(ch)
        if script == "LATIN":
            latin_run.append(ch)
        elif script == "CYRILLIC":
            cyr_run.append(ch)
        elif script == "GREEK":
            greek_run.append(ch)
        elif script == "CJK":
            count += 1
        elif script in ("HIRAGANA", "KATAKANA"):
            if ch not in _SMALL_KANA:
                count += 1
        elif ch in "ーっッ":
            count += 1
        elif script == "HANGUL":
            count += 1 if "가" <= ch <= "힣" else 0
            other_letters += 0 if "가" <= ch <= "힣" else 1
        elif script == "THAI":
            count += 1 if ch in _THAI_CONSONANTS else 0
        elif script in ("ARABIC", "HEBREW"):
            other_letters += 1
        elif "VIRAMA" in _safe_name(ch) or "PULLI" in _safe_name(ch):
            indic_virama += 1
        elif script and category.startswith("L"):
            indic_letters += 1
    # A trailing virama or pulli kills the inherent vowel of the consonant
    # before it, so that letter adds no syllable.
    latin_word = "".join(latin_run)
    groups = _vowel_groups(latin_word, _LATIN_VOWELS)
    if groups > 1 and latin_word.endswith("e") and not latin_word.endswith(("le", "ee", "ye")):
        groups -= 1  # silent final e: "make", "time"
    count += groups
    count += _vowel_groups("".join(cyr_run), _CYRILLIC_VOWELS)
    count += _vowel_groups("".join(greek_run), _GREEK_VOWELS)
    count += max(0, indic_letters - indic_virama)
    count += (other_letters + 1) // 2
    return max(1, count)


def _safe_name(ch: str) -> str:
    try:
        return unicodedata.name(ch)
    except ValueError:
        return ""


def letters(word: str) -> int:
    """Letters and digits in a word, at least 1 (the E2 weight)."""
    return max(1, sum(1 for ch in word if ch.isalnum()))


# --------------------------------------------------------------------------
# Word-timed records -> lines of words
# --------------------------------------------------------------------------

_TAG_RE = re.compile(r"<(\d{1,3}):(\d{2})(?:[.:,](\d{1,3}))?>")
_LINE_STAMP_RE = re.compile(r"^\s*\[(\d{1,3}):(\d{2})(?:[.:,](\d{1,3}))?\]")


def _seconds(minutes: str, seconds: str, fraction: Optional[str]) -> float:
    value = int(minutes) * 60 + int(seconds)
    if fraction:
        value += int(fraction) / (10 ** len(fraction))
    return float(value)


class WordLine:
    """One sung line of a word-timed record: `words` is `[(text, start_s)]`.

    `exact[i]` is True when word i's start is a timestamp the record states
    (a lyricsfile word entry, or the tag opening its segment). A word that
    shares a tagged segment with the word before it only has a start the lab
    interpolated by character share; scoring an estimator against that is
    scoring it against another estimate, so such a word is never scored.
    """

    def __init__(self, words: List[Tuple[str, float]], next_start: Optional[float], own_end: Optional[float],
                 exact: Optional[List[bool]] = None):
        self.words = words
        self.next_start = next_start
        self.own_end = own_end
        self.exact = list(exact) if exact is not None else [True] * len(words)

    @property
    def start(self) -> float:
        return self.words[0][1]

    @property
    def end(self) -> Optional[float]:
        """The span the estimators spread the line over: where the next line
        (or the LRC's own empty stamp, which is the next stamp) starts, and
        nothing else. `own_end`, the true end of the last word, is never used:
        a line-only lyric, which is what an estimator is applied to, does not
        have it, so using it would hand the estimators the answer
        (adversarial review F9). None for a last line with no stamp after it.
        """
        if self.next_start is not None and self.next_start > self.start:
            return self.next_start
        return None


def lyricsfile_lines(raw: str) -> List[WordLine]:
    parsed = oracle.parse_lyricsfile(raw)
    out: List[WordLine] = []
    for i, line in enumerate(parsed):
        words = [(w["text"], w["start_ms"] / 1000.0) for w in line["words"]
                 if w["start_ms"] is not None and (w["text"] or "").strip()]
        if not words:
            continue
        own_end = line["end_ms"] / 1000.0 if line["end_ms"] is not None else None
        nxt = None
        if i + 1 < len(parsed):
            following = parsed[i + 1]
            starts = [t for t in (following["start_ms"],
                                  following["words"][0]["start_ms"] if following["words"] else None)
                      if t is not None]
            nxt = min(starts) / 1000.0 if starts else None
        out.append(WordLine(words, nxt, own_end, [True] * len(words)))
    return out


def enhanced_lines(synced: str) -> List[WordLine]:
    """Word lines from enhanced LRC (`[mm:ss.xx]<t>word <t>word <t>`).

    A tag opens a segment of text. A segment that starts with no whitespace and
    follows text that ended with none is the middle of a word (some uploads tag
    every letter), so it joins the word before it; the word keeps its first
    fragment's time. A tag with no text after it is the line's own end. Lines
    of spaceless scripts treat every segment as a word.
    """
    raw_lines = (synced or "").split("\n")
    stamps = []
    for raw in raw_lines:
        match = _LINE_STAMP_RE.match(raw)
        stamps.append(_seconds(*match.groups()) if match else None)
    out: List[WordLine] = []
    for i, raw in enumerate(raw_lines):
        match = _LINE_STAMP_RE.match(raw)
        if not match:
            continue
        body = raw[match.end():]
        tags = list(_TAG_RE.finditer(body))
        if not tags:
            continue
        segments: List[Tuple[float, str]] = []
        own_end = None
        for k, tag in enumerate(tags):
            stop = tags[k + 1].start() if k + 1 < len(tags) else len(body)
            text = body[tag.end():stop]
            when = _seconds(*tag.groups())
            if text == "" and k + 1 == len(tags):
                own_end = when
            elif text != "":
                segments.append((when, text))
        spaceless = oracle.dominant_script(" ".join(t for _, t in segments)) in oracle.NO_SPACE_SCRIPTS
        words: List[Tuple[str, float]] = []
        exact: List[bool] = []
        glue = False  # the previous segment ended mid-word
        for k, (when, text) in enumerate(segments):
            span_end = segments[k + 1][0] if k + 1 < len(segments) else (own_end if own_end else when)
            pieces = re.findall(r"\s+|\S+", text)
            cursor = when
            total = max(1, len(text))
            first_word_of_segment = True
            for piece in pieces:
                if piece.isspace():
                    glue = False
                    first_word_of_segment = False  # leading space: the word starts after the tag
                else:
                    if spaceless:
                        words.append((piece, cursor))
                        exact.append(first_word_of_segment)
                    elif glue and words:
                        words[-1] = (words[-1][0] + piece, words[-1][1])
                    else:
                        words.append((piece, cursor))
                        # Only the word that opens a segment starts at a tag;
                        # the next words of the segment start at a share of it.
                        exact.append(first_word_of_segment)
                    first_word_of_segment = False
                    glue = not spaceless
                cursor += (span_end - when) * len(piece) / total if span_end > when else 0.0
        if not words:
            continue
        later = [s for s in stamps[i + 1:] if s is not None]
        out.append(WordLine(words, later[0] if later else None, own_end, exact))
    return out


def word_lines(record: dict) -> Tuple[List[WordLine], Optional[str]]:
    """The record's word-timed lines and where they came from. lyricsfile words
    win; enhanced-LRC tags are the fallback (SPEC for M3 estimation)."""
    lines = lyricsfile_lines(record.get("lyricsfile") or "") if "words:" in (record.get("lyricsfile") or "") else []
    if lines:
        return lines, "lyricsfile-words"
    lines = enhanced_lines(record.get("syncedLyrics") or "")
    return (lines, "enhanced-lrc") if lines else ([], None)


# --------------------------------------------------------------------------
# M3 estimation
# --------------------------------------------------------------------------

ESTIMATORS = ["E0", "E1", "E2", "E3", "E4"]
CAPS = [0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50]
MIN_ESTIMATOR_MADE_LINES = 5
ESTIMATOR_MADE_TOLERANCE = 0.01  # seconds: a median error this small means the record is itself an estimate
TEMPO_BUCKETS = [("<3", 0.0, 3.0), ("3-5", 3.0, 5.0), ("5-7", 5.0, 7.0), (">7", 7.0, float("inf"))]


def estimate_starts(words: List[str], start: float, end: float, estimator: str, cap: Optional[float] = None) -> List[float]:
    """Where an estimator puts each word's start inside the line span.

    E0 lights every word at the line start (today's line mode). E1 gives each
    word an equal share, E2 a share by letters, E3 by syllables. E4 is E3 with
    a ceiling on the time one syllable may take, so a line sung quickly then
    left to ring finishes early instead of stretching the last word.
    """
    span = max(0.0, end - start)
    if estimator == "E0":
        return [start] * len(words)
    if estimator == "E1":
        weights = [1.0] * len(words)
    elif estimator == "E2":
        weights = [float(letters(w)) for w in words]
    else:
        weights = [float(syllables(w)) for w in words]
    total = sum(weights)
    if estimator == "E4":
        per_syllable = min(span / total, cap if cap is not None else 0.35)
        out, running = [], 0.0
        for weight in weights:
            out.append(start + running * per_syllable)
            running += weight
        return out
    out, running = [], 0.0
    for weight in weights:
        out.append(start + span * running / total)
        running += weight
    return out


def tempo_bucket(syllables_per_second: float) -> str:
    for name, low, high in TEMPO_BUCKETS:
        if low <= syllables_per_second < high:
            return name
    return TEMPO_BUCKETS[-1][0]


def track_parity(record: dict) -> Tuple[int, str]:
    """(parity, how) of the track a word-timed record belongs to.

    The split that keeps E4's cap honest: the cap is tuned on even-indexed
    tracks and scored on odd-indexed ones. The index is the number after the
    slash in `track_id` ("jazz/014" is 14). A record with no usable track_id
    falls back to the parity of its LRCLIB id, which is just as arbitrary and
    just as stable.
    """
    tid = str(record.get("track_id") or "")
    tail = tid.rsplit("/", 1)[-1]
    if tail.isdigit():
        return int(tail) % 2, "track-index"
    try:
        return int(record.get("id")) % 2, "record-id"
    except (TypeError, ValueError):
        return 0, "record-id"


class EstimationStudy:
    """Collects absolute word-start errors per estimator, cut four ways.

    A cell key is `(scope, value, subset, half)` with scope in all / slice /
    script / tempo, subset all-records / real-records, and half "even" or
    "odd" (the parity of the record's track index). E4's cap is tuned on the
    even half and every figure the report quotes is scored on the odd half, so
    no estimator is judged on the data its parameter was fitted to.

    Errors exclude each line's first word (all estimators agree on it by
    construction), lines with fewer than two words or no known span, and any
    word whose start is not a timestamp the record states (`WordLine.exact`).
    """

    def __init__(self):
        self.records: Dict[int, dict] = {}
        self.errors: Dict[tuple, Dict[str, List[float]]] = {}
        self.estimator_made: Dict[str, int] = {"E1": 0, "E2": 0, "E3": 0}
        self.skipped_lines = 0
        self.lines = 0
        self.words = 0
        self.interpolated_words_skipped = 0
        self.flagged_ids: List[int] = []
        self.half_counts: Dict[str, Dict[str, int]] = {"even": {"records": 0, "words": 0}, "odd": {"records": 0, "words": 0}}

    def _bucket(self, key: tuple) -> Dict[str, List[float]]:
        return self.errors.setdefault(key, {name: [] for name in ESTIMATORS[:4]} | {f"E4@{c:.2f}": [] for c in CAPS})

    def add_record(self, slice_id: str, record: dict) -> bool:
        """Returns False when the record has no usable word lines or repeats an id."""
        rid = record.get("id")
        if rid in self.records:
            return False
        lines, source = word_lines(record)
        script = oracle.script_family(oracle.dominant_script(oracle.lyric_text(record)))
        parity, parity_basis = track_parity(record)
        half = "even" if parity == 0 else "odd"
        rows = []  # (line, words, end, tempo, scored positions)
        for line in lines:
            end = line.end
            texts = [w for w, _ in line.words]
            if len(texts) < 2 or end is None or end <= line.start:
                self.skipped_lines += 1
                continue
            scored = [i for i in range(1, len(texts)) if line.exact[i]]
            self.interpolated_words_skipped += (len(texts) - 1) - len(scored)
            if not scored:
                self.skipped_lines += 1
                continue
            syl = sum(syllables(w) for w in texts)
            rows.append((line, texts, end, syl / (end - line.start), scored))
        if not rows:
            return False
        # Is this record itself the output of an estimator? Some uploads
        # spread a line's time over its words by a formula and call it word
        # sync. Measuring an estimator against such a record would reward it
        # for matching its own kind, so those records are flagged and the
        # report gives the figures with and without them. Only words with a
        # stated start are compared, or a record's own interpolation would
        # flag it as made by the estimator that interpolates the same way.
        made = None
        if len(rows) >= MIN_ESTIMATOR_MADE_LINES:
            for name in ("E1", "E2", "E3"):
                deviations = []
                for line, texts, end, _, scored in rows:
                    guess = estimate_starts(texts, line.start, end, name)
                    deviations.extend(abs(guess[i] - line.words[i][1]) for i in scored)
                if deviations and statistics.median(deviations) <= ESTIMATOR_MADE_TOLERANCE:
                    made = name
                    break
        if made:
            self.estimator_made[made] += 1
            self.flagged_ids.append(rid)
        self.records[rid] = {"slice": slice_id, "source": source, "lines": len(rows), "estimator_made": made,
                             "half": half, "half_basis": parity_basis}
        self.half_counts[half]["records"] += 1
        scopes_base = [("slice", slice_id), ("script", script)]
        for line, texts, end, tempo, scored in rows:
            self.lines += 1
            self.words += len(scored)
            self.half_counts[half]["words"] += len(scored)
            bucket_name = tempo_bucket(tempo)
            actual = [line.words[i][1] for i in scored]
            estimates = {name: [estimate_starts(texts, line.start, end, name)[i] for i in scored]
                         for name in ESTIMATORS[:4]}
            for cap in CAPS:
                all_e4 = estimate_starts(texts, line.start, end, "E4", cap)
                estimates[f"E4@{cap:.2f}"] = [all_e4[i] for i in scored]
            scopes = [("all", "all")] + scopes_base + [("tempo", bucket_name)]
            for scope in scopes:
                bucket = self._bucket((scope[0], scope[1], "all-records", half))
                real = None if made else self._bucket((scope[0], scope[1], "real-records", half))
                for name, guesses in estimates.items():
                    errors = [abs(g - a) for g, a in zip(guesses, actual)]
                    bucket[name].extend(errors)
                    if real is not None:
                        real[name].extend(errors)
        return True

    def best_cap(self, key: tuple = ("all", "all", "all-records", "even")) -> Tuple[Optional[float], List[dict]]:
        """The cap with the lowest median error on the tuning (even) half, and
        that half's whole curve."""
        bucket = self.errors.get(key)
        if not bucket:
            return None, []
        curve = []
        for cap in CAPS:
            values = bucket[f"E4@{cap:.2f}"]
            row = {"cap": cap}
            row.update(summarize(values, (0.1, 0.25)))
            curve.append(row)
        best = min((r for r in curve if r["p50"] is not None), key=lambda r: (r["p50"], r["p90"] or 0), default=None)
        return (best["cap"] if best else None), curve

    def _cell(self, key: tuple, best_cap: Optional[float]) -> dict:
        """E0-E3 and E4 at `best_cap`, scored on the odd half (key's `half`)."""
        bucket = self.errors.get(key)
        if not bucket:
            return {}
        out = {}
        for name in ESTIMATORS[:4]:
            out[name] = summarize(bucket[name], (0.1, 0.25))
        if best_cap is not None:
            out["E4"] = dict(summarize(bucket[f"E4@{best_cap:.2f}"], (0.1, 0.25)), cap=best_cap)
        return out

    def result(self) -> dict:
        best, curve = self.best_cap()
        best_real, curve_real = self.best_cap(("all", "all", "real-records", "even"))
        cuts: Dict[str, dict] = {"slice": {}, "script": {}, "tempo": {}}
        for (scope, value, subset, half), _ in sorted(self.errors.items()):
            if scope in cuts and subset == "all-records" and half == "odd":
                cuts[scope][value] = self._cell((scope, value, subset, half), best)
        return {
            "records": len(self.records),
            "records_by_source": _count(r["source"] for r in self.records.values()),
            "records_by_slice": _count(r["slice"] for r in self.records.values()),
            "estimator_made_records": dict(self.estimator_made),
            "estimator_made_ids": sorted(self.flagged_ids),
            "lines": self.lines,
            "words_scored": self.words,
            "interpolated_words_not_scored": self.interpolated_words_skipped,
            "lines_without_span_or_words": self.skipped_lines,
            "split": {
                "e4_cap_tuned_on": "even-indexed tracks",
                "all_figures_scored_on": "odd-indexed tracks",
                "index": "the number after the slash in track_id (record id when there is none)",
                "records_and_words_by_half": self.half_counts,
            },
            "overall_all_records": self._cell(("all", "all", "all-records", "odd"), best),
            "overall_excluding_estimator_made": self._cell(("all", "all", "real-records", "odd"), best_real),
            "e4_best_cap": best,
            "e4_curve": curve,
            "e4_best_cap_excluding_estimator_made": best_real,
            "e4_curve_excluding_estimator_made": curve_real,
            "by_slice": cuts["slice"],
            "by_script_family": cuts["script"],
            "by_tempo_syllables_per_second": cuts["tempo"],
        }


def _count(values: Iterable) -> dict:
    out: Dict = {}
    for v in values:
        out[str(v)] = out.get(str(v), 0) + 1
    return dict(sorted(out.items()))


# --------------------------------------------------------------------------
# M9 catalogue timing noise and consensus
# --------------------------------------------------------------------------

MIN_ALIGNED = 5          # lines two records must share before a pair says anything
MAX_PAIRS_PER_TRACK = 10
MIN_CONSENSUS_RECORDS = 3


def sung(record: dict) -> List[Tuple[float, str]]:
    """`[(stamp, normalized text)]` for the lines alignment compares."""
    out = []
    for stamp, text in oracle.synced_lines(record):
        key = oracle.normalize_text(text)
        if key:
            out.append((stamp, key))
    return out


def align(a: List[Tuple[float, str]], b: List[Tuple[float, str]]) -> List[Tuple[int, int]]:
    """Index pairs of lines with equal normalized text, in order (equal blocks only)."""
    matcher = difflib.SequenceMatcher(None, [t for _, t in a], [t for _, t in b], autojunk=False)
    pairs = []
    for block in matcher.get_matching_blocks():
        pairs.extend((block.a + k, block.b + k) for k in range(block.size))
    return pairs


def pair_noise(a: List[Tuple[float, str]], b: List[Tuple[float, str]]) -> Optional[dict]:
    """Constant offset and residual jitter between two records of one song.

    Δ = t_a − t_b over aligned lines; the offset is the median Δ (a whole
    record shifted by some seconds is a different upload offset, not jitter)
    and each residual is |Δ − offset|.
    """
    pairs = align(a, b)
    if len(pairs) < MIN_ALIGNED:
        return None
    deltas = [a[i][0] - b[j][0] for i, j in pairs]
    offset = statistics.median(deltas)
    return {"offset": offset, "residuals": [abs(d - offset) for d in deltas], "aligned": len(pairs)}


def select_pairs(ids: List) -> List[Tuple]:
    """At most MAX_PAIRS_PER_TRACK pairs, spread over the id list so one
    record does not appear in all of them."""
    pairs = list(itertools.combinations(sorted(ids, key=str), 2))
    if len(pairs) <= MAX_PAIRS_PER_TRACK:
        return pairs
    step = math.ceil(len(pairs) / MAX_PAIRS_PER_TRACK)
    return pairs[::step][:MAX_PAIRS_PER_TRACK]


DUPLICATE_ROUNDING_S = 0.01


def collapse_identical(lines_by_id: Dict, prefer=None) -> Tuple[Dict, Dict]:
    """Keep one record per group of identical timelines.

    LRCLIB holds many copies of one timeline (one upload mirrored onto several
    releases). Two such copies agree to the millisecond, which M9 would read as
    perfect catalogue accuracy and M10's consensus as two independent votes
    (adversarial review F10). Records whose stamp sequences are equal once
    rounded to 10 ms form a group; the group keeps `prefer` when it is a member
    (the record being scored), else its lowest id.

    Returns (kept records, {kept id: [every id in its group]}).
    """
    groups: Dict[tuple, List] = {}
    for rid in sorted(lines_by_id, key=str):
        key = tuple(round(stamp / DUPLICATE_ROUNDING_S) for stamp, _ in lines_by_id[rid])
        groups.setdefault(key, []).append(rid)
    kept: Dict = {}
    members: Dict = {}
    for ids in groups.values():
        keeper = prefer if prefer in ids else ids[0]
        kept[keeper] = lines_by_id[keeper]
        members[keeper] = ids
    return kept, members


class DuplicateTally:
    """How many records collapsed into how many timelines, and the group sizes."""

    def __init__(self):
        self.before = 0
        self.after = 0
        self.sizes: Dict[int, int] = {}

    def add(self, members: Dict) -> None:
        for ids in members.values():
            self.before += len(ids)
            self.after += 1
            self.sizes[len(ids)] = self.sizes.get(len(ids), 0) + 1

    def result(self) -> dict:
        return {"records_before": self.before, "unique_timelines": self.after,
                "group_sizes": {str(k): v for k, v in sorted(self.sizes.items())}}


def consensus_deviation(lines_by_id: Dict) -> Dict:
    """Each record's median |stamp − consensus| over the lines it shares.

    The reference is the record with the most lines. Every other record is
    aligned to it by text. A record is scored against the median of the OTHER
    records' stamps for each line (its own stamp is left out, or a record
    would pull the consensus toward itself and look better than it is), and a
    line has a consensus when at least MIN_CONSENSUS_RECORDS - 1 others carry
    it. Records covering fewer than MIN_ALIGNED consensus lines get None.
    Fewer than MIN_CONSENSUS_RECORDS records give None for all.
    """
    if len(lines_by_id) < MIN_CONSENSUS_RECORDS:
        return {rid: None for rid in lines_by_id}
    ref_id = sorted(lines_by_id, key=lambda r: (-len(lines_by_id[r]), str(r)))[0]
    ref = lines_by_id[ref_id]
    stamps: Dict[int, Dict] = {i: {ref_id: ref[i][0]} for i in range(len(ref))}
    for rid, lines in lines_by_id.items():
        if rid == ref_id:
            continue
        for i, j in align(ref, lines):
            stamps[i][rid] = lines[j][0]
    out = {}
    for rid in lines_by_id:
        deviations = []
        for by in stamps.values():
            if rid not in by:
                continue
            others = [t for r, t in by.items() if r != rid]
            if len(others) >= MIN_CONSENSUS_RECORDS - 1:
                deviations.append(abs(by[rid] - statistics.median(others)))
        out[rid] = statistics.median(deviations) if len(deviations) >= MIN_ALIGNED else None
    return out


def expand_deviations(deviations: Dict, members: Dict) -> Dict:
    """Give every record of a collapsed group its keeper's deviation."""
    out = {}
    for keeper, ids in members.items():
        for rid in ids:
            out[rid] = deviations.get(keeper)
    return out


class NoiseStudy:
    """M9: offsets and jitter between independent records, and where Isla's
    pick sits against the consensus. Per slice and overall."""

    def __init__(self):
        self.offsets: Dict[str, List[float]] = {}
        self.residuals: Dict[str, List[float]] = {}
        self.pairs: Dict[str, int] = {}
        self.tracks_with_pairs: Dict[str, int] = {}
        self.consensus: Dict[str, dict] = {}
        self.duplicates = DuplicateTally()

    def add_track(self, slice_id: str, lines_by_id: Dict, chosen_id=None) -> None:
        # Identical timelines are one record, before pairing and before the
        # consensus; the chosen record stays when its group is collapsed.
        lines_by_id, members = collapse_identical(lines_by_id, prefer=chosen_id)
        self.duplicates.add(members)
        ids = list(lines_by_id)
        done = 0
        for a, b in select_pairs(ids):
            noise = pair_noise(lines_by_id[a], lines_by_id[b])
            if noise is None:
                continue
            done += 1
            for key in (slice_id, "all"):
                self.offsets.setdefault(key, []).append(abs(noise["offset"]))
                self.residuals.setdefault(key, []).extend(noise["residuals"])
                self.pairs[key] = self.pairs.get(key, 0) + 1
        if done:
            for key in (slice_id, "all"):
                self.tracks_with_pairs[key] = self.tracks_with_pairs.get(key, 0) + 1
        if chosen_id is None or chosen_id not in lines_by_id:
            return
        deviations = consensus_deviation(lines_by_id)
        mine = deviations.get(chosen_id)
        known = {r: d for r, d in deviations.items() if d is not None}
        if mine is None or len(known) < MIN_CONSENSUS_RECORDS:
            return
        best = min(known.values())
        rank = 1 + sum(1 for d in known.values() if d < mine - 1e-9)
        for key in (slice_id, "all"):
            cell = self.consensus.setdefault(key, {"chosen": [], "best": [], "rank": [], "fit": [], "best_picked": 0})
            cell["chosen"].append(mine)
            cell["best"].append(best)
            cell["rank"].append(rank)
            cell["fit"].append(len(known))
            cell["best_picked"] += 1 if rank == 1 else 0

    def result(self) -> dict:
        out = {}
        for key in sorted(self.pairs):
            offsets, residuals = self.offsets[key], self.residuals[key]
            cell = {
                "pairs": self.pairs[key],
                "tracks_with_pairs": self.tracks_with_pairs.get(key, 0),
                "abs_offset_s": summarize(offsets),
                "share_offset_over_0.3s": share(sum(1 for v in offsets if v > 0.3), len(offsets)),
                "share_offset_over_1s": share(sum(1 for v in offsets if v > 1.0), len(offsets)),
                "residual_s": summarize(residuals),
                "share_residual_over_0.25s": share(sum(1 for v in residuals if v > 0.25), len(residuals)),
            }
            c = self.consensus.get(key)
            if c:
                cell["consensus"] = {
                    "tracks": len(c["chosen"]),
                    "chosen_median_deviation_s": summarize(c["chosen"]),
                    "best_fit_median_deviation_s": summarize(c["best"]),
                    "rank_of_chosen": summarize([float(r) for r in c["rank"]]),
                    "share_chosen_is_closest": share(c["best_picked"], len(c["chosen"])),
                    "median_fit_records": _r(statistics.median(c["fit"]), 2),
                }
            out[key] = cell
        return out

    def duplicate_report(self) -> dict:
        return self.duplicates.result()


# --------------------------------------------------------------------------
# M10 selection quality
# --------------------------------------------------------------------------

class SelectionStudy:
    """M10: of several correct records, did Isla pick the best one?

    One case per `correct` canonical or apple lookup with at least two fit
    records. Three tests, each with the gain had Isla picked best:
      length     the smallest |duration − variant duration|
      word       a word-timed record, when any fit record has one
      consensus  the smallest median deviation from the other records' stamps
    """

    def __init__(self):
        self.cases: Dict[str, dict] = {}

    def add_case(self, variant: str, chosen: dict, fit: List[dict], target: float, deviations: Dict) -> None:
        """`chosen`/`fit` entries: `{id, duration, word_timing}`."""
        for key in (variant, "all"):
            cell = self.cases.setdefault(key, {
                "n": 0, "length_best": 0, "length_gain": [], "word_possible": 0, "word_picked": 0,
                "consensus_n": 0, "consensus_best": 0, "consensus_gain": []})
            cell["n"] += 1
            deltas = {r["id"]: abs(r["duration"] - target) for r in fit}
            mine = deltas.get(chosen["id"], abs(chosen["duration"] - target))
            best = min(deltas.values())
            if mine <= best + 1e-9:
                cell["length_best"] += 1
            else:
                cell["length_gain"].append(mine - best)
            if any(r["word_timing"] for r in fit):
                cell["word_possible"] += 1
                cell["word_picked"] += 1 if chosen["word_timing"] else 0
            known = {r: d for r, d in deviations.items() if d is not None}
            if chosen["id"] in known and len(known) >= 2:
                cell["consensus_n"] += 1
                if known[chosen["id"]] <= min(known.values()) + 0.005:
                    cell["consensus_best"] += 1
                else:
                    cell["consensus_gain"].append(known[chosen["id"]] - min(known.values()))

    def result(self) -> dict:
        out = {}
        for key, c in sorted(self.cases.items()):
            out[key] = {
                "cases": c["n"],
                "picked_closest_length": share(c["length_best"], c["n"]),
                "median_length_gain_s_when_not_closest": _r(percentile(c["length_gain"], 50)),
                "word_timed_available_cases": c["word_possible"],
                "picked_word_timed_when_available": share(c["word_picked"], c["word_possible"]),
                "consensus_cases": c["consensus_n"],
                "picked_closest_to_consensus": share(c["consensus_best"], c["consensus_n"]),
                "median_consensus_gain_s_when_not_closest": _r(percentile(c["consensus_gain"], 50)),
            }
        return out
