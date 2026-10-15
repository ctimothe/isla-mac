#!/usr/bin/env python3
"""Probe the oracle's n-gram sizes with stand-in text, never with lyrics.

    python3 standin_probe.py [--pairs 400] [--langs th,ja,zh_TW,zh_CN,ko]

The null question: how much of one text's n-grams does an UNRELATED text of
about 1,000 characters contain? Lyrics are copyrighted and live only under the
corpus root, so this uses text that is free to read and unrelated by
construction: macOS's own UI translations,
`/System/Library/**/<lang>.lproj/*.strings`, read with `plutil`. Two pools:

  core   the apps under /System/Library/CoreServices (a small vocabulary)
  wide   every bundle under /System/Library and /Library/Apple (a larger one,
         but one that repeats the same formulaic phrases in hundreds of bundles,
         so a harsher null)

Each pair is two texts built from random strings of the pool, the two drawn from
disjoint halves of its bundles, kept to strings that are at least 70 % in the
language's script. Prints, per pool, language and n, the p50, p95 and p99 of
containment between the two. Numbers only. Read-only; no network.

The oracle's table (oracle.NGRAM_TABLE) holds the smallest n whose p99 is under
0.2 on both pools.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import sys
from typing import Dict, List

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import analysis  # noqa: E402
import oracle  # noqa: E402

TARGET_CHARS = 1000
FAMILY = {"th": "THAI", "ja": "CJK", "zh_TW": "CJK", "zh_CN": "CJK", "ko": "HANGUL"}
SPACELESS_N = (2, 3, 4, 5, 6, 7, 8)
WORD_N = (2, 3, 4)
# (directories to search, find -path pattern)
POOLS = {
    "core": (["/System/Library/CoreServices"], "*.app/Contents/Resources/{lang}.lproj/*.strings"),
    "wide": (["/System/Library", "/Library/Apple"], "*/{lang}.lproj/*.strings"),
}


def read_strings(path: str) -> List[str]:
    done = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True)
    if done.returncode:
        return []
    try:
        data = json.loads(done.stdout)
    except ValueError:
        return []
    return [v for v in data.values() if isinstance(v, str) and len(v) >= 2]


def bundle_of(path: str, lang: str) -> str:
    parts = path.split("/")
    return "/".join(parts[:parts.index(f"{lang}.lproj")])


def load_pool(pool: str, lang: str) -> Dict[str, List[str]]:
    family = FAMILY[lang]
    by_bundle: Dict[str, set] = {}
    roots, pattern = POOLS[pool]
    found = subprocess.run(["find", *[r for r in roots if os.path.isdir(r)], "-path", pattern.format(lang=lang)],
                           capture_output=True, text=True).stdout.split("\n")
    for path in filter(None, found):
        for value in read_strings(path):
            if oracle.family_share(value, family) >= 0.7:
                by_bundle.setdefault(bundle_of(path, lang), set()).add(value)
    return {bundle: sorted(values) for bundle, values in by_bundle.items() if values}


def make_pairs(by_bundle: Dict[str, List[str]], pairs: int, rng: random.Random) -> List[tuple]:
    names = sorted(by_bundle)
    out = []
    for _ in range(pairs):
        rng.shuffle(names)
        half = len(names) // 2
        texts = []
        for group in (names[:half], names[half:]):
            lines, size = [], 0
            while size < TARGET_CHARS:
                value = rng.choice(by_bundle[rng.choice(group)])
                lines.append(value)
                size += len(value.replace(" ", ""))
            texts.append("\n".join(lines))
        out.append(tuple(texts))
    return out


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Null containment of unrelated stand-in texts, per n.")
    parser.add_argument("--pairs", type=int, default=400)
    parser.add_argument("--langs", default=",".join(FAMILY))
    parser.add_argument("--seed", type=int, default=11)
    args = parser.parse_args(argv)
    for pool in POOLS:
        for lang in [l for l in args.langs.split(",") if l in FAMILY]:
            by_bundle = load_pool(pool, lang)
            if len(by_bundle) < 2:
                print(f"{pool:5s} {lang:6s} no strings found")
                continue
            texts = make_pairs(by_bundle, args.pairs, random.Random(args.seed))
            kind = oracle.NGRAM_TABLE.get(FAMILY[lang], oracle.DEFAULT_SHINGLE)[0]
            for n in (SPACELESS_N if kind == "char" else WORD_N):
                values = [oracle.containment(oracle.fingerprint(a, ngram=n), oracle.fingerprint(b, ngram=n))
                          for a, b in texts]
                print(f"{pool:5s} {lang:6s} {FAMILY[lang]:7s} n={n} pairs={len(values)} "
                      f"p50={analysis.percentile(values, 50):.3f} p95={analysis.percentile(values, 95):.3f} "
                      f"p99={analysis.percentile(values, 99):.3f}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
