#!/usr/bin/env python3
"""Calibrate the oracle's n-gram size and SAME/WRONG thresholds on the corpus.

    python3 calibrate.py --root <root> [--max-pairs 4000] [--seed 20261015]

Why: the oracle fingerprints a lyric as shingles (oracle.NGRAM_TABLE) and calls
two records the same song at containment >= SAME and different at <= WRONG.
Whether 0.6 and 0.2 mean that depends on the script. Spaceless scripts have far
fewer distinct n-grams, so unrelated Thai texts shared half their bigrams (the
review of 2026-10-15 measured a median 0.61). This reads the corpus and says,
per script family and per candidate n, what the numbers actually are.

Reads   resolved/tracks.jsonl and the replay caches (via classify.pool_rows).
Writes  reports/oracle-calibration.json
Prints  numbers only: family, n, sample size and the percentiles. No title, no
        artist and no lyric text, and neither file has any.

Two distributions per family and per n:

  null      containment between anchor records of DIFFERENT tracks of the same
            family: texts of different songs. It must sit below WRONG.
  positive  containment between two records of the SAME track that both pass
            the oracle's title and artist match, both have lyric text, are not
            instrumental, and whose durations are within 3 s of each other:
            texts of one song. It must sit above SAME.

Each is summarised by p1, p5, p50, p95 and p99. The recommendation, per family:

  ngram   the smallest candidate n whose null p99 is under 0.2 and whose
          positive p5 is at least 0.5 (positive p5 is not required when the
          corpus holds no positive pairs for the family). When no candidate
          qualifies, the candidate with the lowest null p99 (the larger n on a
          tie), and `meets_target` is false.
  wrong   0.2, or the null p99 at the chosen n rounded up to 0.05 when higher,
          never above 0.9.
  same    0.6, or lower when the positive p5 at the chosen n is: the p5 rounded
          down to 0.05, never closer than 0.1 to `wrong`.

A family with fewer than MIN_PAIRS null pairs gets the distributions and no
recommendation; the table stays in force for it.

Precedence when the oracle runs (oracle.load_calibration): a family's
`recommended` entry in this file, then oracle.NGRAM_TABLE / THRESHOLD_TABLE.
Re-run resolve.py --offline and classify.py after writing the file, so truth and
verdicts use the same fingerprint.
"""
from __future__ import annotations

import argparse
import datetime
import itertools
import json
import math
import os
import random
import sys
from typing import Dict, List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import analysis  # noqa: E402
import classify  # noqa: E402
import oracle  # noqa: E402
import resolve  # noqa: E402

CHAR_CANDIDATES = (2, 3, 4, 5, 6)
WORD_CANDIDATES = (2, 3, 4)
MIN_PAIRS = 30
NULL_CEILING = 0.2        # the default WRONG: unrelated texts must stay under it
POSITIVE_FLOOR = 0.5
FIT_S = 3.0
PERCENTILES = (1, 5, 50, 95, 99)
MAX_POSITIVE_PER_TRACK = 6


def round_up(value: float, step: float = 0.05) -> float:
    return round(math.ceil(value / step - 1e-9) * step, 2)


def round_down(value: float, step: float = 0.05) -> float:
    return round(math.floor(value / step + 1e-9) * step, 2)


def describe(values: List[float]) -> dict:
    out: dict = {"n": len(values)}
    for p in PERCENTILES:
        value = analysis.percentile(values, p)
        out[f"p{p}"] = None if value is None else round(value, 4)
    return out


def candidates_for(family: str) -> tuple:
    kind = oracle.NGRAM_TABLE.get(family, oracle.DEFAULT_SHINGLE)[0]
    return CHAR_CANDIDATES if kind == "char" else WORD_CANDIDATES


class Corpus:
    """Texts by family, loaded once, with fingerprints cached per n."""

    def __init__(self):
        self.texts: Dict[tuple, str] = {}              # (track_id, record id) -> text
        self.family: Dict[tuple, str] = {}
        self.anchors: Dict[str, List[tuple]] = {}      # family -> keys of anchor records
        self.positive: Dict[str, List[tuple]] = {}     # family -> pairs of keys
        self._fp: Dict[tuple, frozenset] = {}

    def fingerprint(self, key: tuple, n: int) -> frozenset:
        cached = self._fp.get((key, n))
        if cached is None:
            cached = oracle.fingerprint(self.texts[key], ngram=n)
            self._fp[(key, n)] = cached
        return cached

    def add_track(self, root: str, track: dict, rng: random.Random) -> None:
        tid = track["track_id"]
        harvest = track.get("harvest") or {}
        titles = resolve.identity_titles(harvest, track.get("apple"), track.get("deezer"), track.get("apple_us"))
        artists = resolve.identity_artists(harvest, track.get("apple"), track.get("deezer"), track.get("apple_us"))
        anchor_ids = {c["id"] for c in track.get("candidates") or [] if c.get("anchor")}
        identity_keys: Dict[str, List[tuple]] = {}
        durations: Dict[tuple, float] = {}
        for rid, row in classify.pool_rows(root, track).items():
            if row.get("instrumental"):
                continue
            text = oracle.lyric_text(row)
            if not oracle.normalize_text(text):
                continue
            family = oracle.script_family(oracle.dominant_script(text))
            if not family:
                continue
            key = (tid, rid)
            self.texts[key] = text
            self.family[key] = family
            if rid in anchor_ids:
                self.anchors.setdefault(family, []).append(key)
            if oracle.title_match(titles, row.get("trackName") or "") \
                    and oracle.artist_match(artists, row.get("artistName") or ""):
                identity_keys.setdefault(family, []).append(key)
                durations[key] = float(row.get("duration") or 0)
        for family, keys in identity_keys.items():
            pairs = [(a, b) for a, b in itertools.combinations(sorted(keys, key=str), 2)
                     if abs(durations[a] - durations[b]) <= FIT_S]
            rng.shuffle(pairs)
            self.positive.setdefault(family, []).extend(pairs[:MAX_POSITIVE_PER_TRACK])


def null_pairs(keys: List[tuple], limit: int, rng: random.Random) -> List[tuple]:
    """Up to `limit` pairs of records from different tracks, drawn without bias
    toward the tracks that hold many anchors."""
    by_track: Dict[str, List[tuple]] = {}
    for key in keys:
        by_track.setdefault(key[0], []).append(key)
    tracks = sorted(by_track)
    if len(tracks) < 2:
        return []
    sizes = [len(v) for v in by_track.values()]
    total = (sum(sizes) ** 2 - sum(x * x for x in sizes)) // 2          # pairs of records from different tracks
    pairs, seen = [], set()
    attempts = 0
    while len(pairs) < min(limit, total) and attempts < limit * 20:
        attempts += 1
        t1, t2 = rng.sample(tracks, 2)
        a, b = rng.choice(by_track[t1]), rng.choice(by_track[t2])
        if (a, b) in seen or (b, a) in seen:
            continue
        seen.add((a, b))
        pairs.append((a, b))
    return pairs


def recommend(null: Dict[int, dict], positive: Dict[int, dict]) -> Optional[dict]:
    usable = {n: cell for n, cell in null.items() if cell["n"] >= MIN_PAIRS and cell["p99"] is not None}
    if not usable:
        return None

    def positive_ok(n: int) -> bool:
        cell = positive.get(n)
        return cell is None or cell["n"] == 0 or (cell["p5"] is not None and cell["p5"] >= POSITIVE_FLOOR)

    meets = [n for n in sorted(usable) if usable[n]["p99"] < NULL_CEILING and positive_ok(n)]
    if meets:
        chosen, meets_target = meets[0], True
    else:
        chosen = min(sorted(usable), key=lambda n: (usable[n]["p99"], -n))
        meets_target = False
    wrong = min(0.9, max(0.2, round_up(usable[chosen]["p99"])))
    same = 0.6
    pos = positive.get(chosen)
    if pos and pos["n"] and pos["p5"] is not None:
        same = min(0.6, max(round_up(wrong + 0.1), round_down(pos["p5"])))
    same = min(1.0, max(same, round(wrong + 0.1, 2)))
    return {"ngram": chosen, "same": round(same, 2), "wrong": round(wrong, 2), "meets_target": meets_target,
            "basis": f"null p99 {usable[chosen]['p99']} at n={chosen}"
                     + (f", positive p5 {pos['p5']}" if pos and pos["n"] else ", no positive pairs")}


def calibrate(root: str, max_pairs: int = 4000, seed: int = 20261015) -> dict:
    root = os.path.expanduser(root)
    rng = random.Random(seed)
    corpus = Corpus()
    tracks = classify.read_jsonl(os.path.join(root, "resolved", "tracks.jsonl"))
    for track in tracks:
        corpus.add_track(root, track, rng)
    families: Dict[str, dict] = {}
    for family in sorted(set(corpus.anchors) | set(corpus.positive)):
        kind = oracle.NGRAM_TABLE.get(family, oracle.DEFAULT_SHINGLE)[0]
        pairs = null_pairs(corpus.anchors.get(family, []), max_pairs, rng)
        positives = corpus.positive.get(family, [])
        null_cells: Dict[int, dict] = {}
        positive_cells: Dict[int, dict] = {}
        for n in candidates_for(family):
            null_cells[n] = describe([oracle.containment(corpus.fingerprint(a, n), corpus.fingerprint(b, n))
                                      for a, b in pairs])
            positive_cells[n] = describe([oracle.containment(corpus.fingerprint(a, n), corpus.fingerprint(b, n))
                                          for a, b in positives])
        families[family] = {
            "kind": kind,
            "table": {"ngram": oracle.NGRAM_TABLE.get(family, oracle.DEFAULT_SHINGLE)[1],
                      "thresholds": list(oracle.THRESHOLD_TABLE.get(family, oracle.DEFAULT_THRESHOLDS))},
            "records": sum(1 for k, f in corpus.family.items() if f == family),
            "null": {str(n): cell for n, cell in null_cells.items()},
            "positive": {str(n): cell for n, cell in positive_cells.items()},
            "recommended": recommend(null_cells, positive_cells),
        }
    return {
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "seed": seed, "max_null_pairs_per_family": max_pairs, "tracks": len(tracks),
        "definitions": {
            "null": "containment between anchor records of different tracks of one family",
            "positive": "containment between two records of one track that pass the oracle's title and artist "
                        "match, have lyric text, and are within 3 s of each other's duration",
        },
        "precedence": "families[F].recommended, if present, replaces oracle.NGRAM_TABLE[F] and "
                      "oracle.THRESHOLD_TABLE[F]; every other family keeps the table",
        "families": families,
    }


def print_numbers(result: dict) -> None:
    print(f"calibration: {result['tracks']} tracks, seed {result['seed']}")
    for family, entry in result["families"].items():
        print(f"{family} ({entry['kind']}, {entry['records']} records, table n={entry['table']['ngram']})")
        for n in entry["null"]:
            nu, po = entry["null"][n], entry["positive"][n]
            print(f"  n={n}  null  pairs={nu['n']:5d} " + " ".join(f"p{p}={nu[f'p{p}']}" for p in PERCENTILES))
            print(f"        positive pairs={po['n']:5d} " + " ".join(f"p{p}={po[f'p{p}']}" for p in PERCENTILES))
        rec = entry["recommended"]
        print("  recommended: " + (f"n={rec['ngram']} same={rec['same']} wrong={rec['wrong']} "
                                   f"meets_target={rec['meets_target']} ({rec['basis']})"
                                   if rec else "none (too few null pairs)"))


def write(root: str, result: dict) -> str:
    path = os.path.join(os.path.expanduser(root), oracle.CALIBRATION_FILE)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    classify.write_json(path, result)
    return path


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Calibrate the oracle's n-gram size and thresholds.")
    parser.add_argument("--root", required=True)
    parser.add_argument("--max-pairs", type=int, default=4000, help="null pairs per family (default 4000)")
    parser.add_argument("--seed", type=int, default=20261015)
    args = parser.parse_args(argv)
    oracle.reset_calibration()   # measure against the table, not a previous calibration
    result = calibrate(args.root, args.max_pairs, args.seed)
    print_numbers(result)
    print("wrote " + write(args.root, result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
