#!/usr/bin/env python3
"""The synced LRCLIB records the lab's cache already holds, as a corpus for
the 2026-10-11 Lyrics Accuracy Lab (Scripts/lyric-lab.sh).

    python3 pool.py --root <root> [--out pool]

Writes <root>/<out>/<slice>/<lrclib_id>.json, each one LRCLIB's object exactly
as it came back (syncedLyrics, lyricsfile, hasWordSync, duration, ...), and
<root>/<out>/_summary.json, which holds counts only. A record goes under the
slice of the first harvested track whose resolver query returned it, in
harvest order. Only records with synced lyrics are written, because the
accuracy lab measures timing.

Cache reads only, never the network. That is the point: the timing and
word-level measurements run on what LRCLIB has already answered, so they do
not wait for a limiter that is refusing this address (SPEC amendment "The pool
corpus"). The pool is broader than what Isla shows: it is every synced record
in the top 20 that LRCLIB's search returned for the lab's queries, plus the
records `/api/get` returned. `matched/` stays the corpus of records Isla chose.

The output holds lyric text, so it lives only under the corpus root. Nothing
this script prints carries a lyric line.
"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import re
import sys
from typing import Dict, List

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import common  # noqa: E402
import resolve  # noqa: E402

# An enhanced-LRC word stamp inside syncedLyrics, `<mm:ss.xx>`: the only way an
# old-style upload carries word timing, and the form Isla's parser reads.
WORD_TAG = re.compile(r"<\d{1,2}:\d{2}(?:\.\d{1,3})?>")


def track_urls(track: dict, root: str) -> List[str]:
    """The resolver's LRCLIB URLs for a track: its searches, and the get it
    builds from the cached Apple or Deezer length (no get without one)."""
    with contextlib.redirect_stdout(io.StringIO()):
        apple_result = resolve.resolve_apple(track, root, True)
        deezer_result = resolve.resolve_deezer(track, root, True)
    apple, deezer = apple_result.get("apple"), deezer_result.get("deezer")
    urls = list(resolve.lrclib_search_urls(track).values())
    if apple or deezer:
        duration = (apple or {}).get("duration") or (deezer or {}).get("duration") or 0
        urls.append(resolve.lrclib_get_url(track, duration, resolve.canonical_album(track, apple, deezer)))
    return urls


def records(response: common.Response) -> List[dict]:
    """The LRCLIB objects in one answer: a search page's rows, or a get's one."""
    data = response.json()
    rows = data if isinstance(data, list) else [data]
    return [r for r in rows if isinstance(r, dict) and isinstance(r.get("id"), int)]


def build(root: str, out: str = "pool") -> dict:
    tracks = [t for _, ts in resolve.load_slices(root, None, None) for t in ts]
    seen = set()
    per_slice: Dict[str, int] = {}
    totals = {"tracks": len(tracks), "queries": 0, "answered": 0, "records_seen": 0,
              "written": 0, "plain_or_instrumental_skipped": 0,
              "has_word_sync": 0, "enhanced_lrc_word_tags": 0}
    for track in tracks:
        for url in track_urls(track, root):
            totals["queries"] += 1
            hit = common.read_any_cache(root, url)
            if hit is None or hit.status != 200:
                continue
            totals["answered"] += 1
            for row in records(hit):
                if row["id"] in seen:
                    continue
                seen.add(row["id"])
                totals["records_seen"] += 1
                if not row.get("syncedLyrics") or row.get("instrumental"):
                    totals["plain_or_instrumental_skipped"] += 1
                    continue
                totals["has_word_sync"] += bool(row.get("hasWordSync"))
                totals["enhanced_lrc_word_tags"] += bool(WORD_TAG.search(row["syncedLyrics"]))
                resolve.write_json(os.path.join(root, out, track["slice"], f"{row['id']}.json"), row)
                per_slice[track["slice"]] = per_slice.get(track["slice"], 0) + 1
                totals["written"] += 1
    summary = {"totals": totals, "per_slice": dict(sorted(per_slice.items()))}
    resolve.write_json(os.path.join(root, out, "_summary.json"), summary)
    return summary


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Write the cached synced LRCLIB records as an accuracy-lab corpus.")
    parser.add_argument("--root", default=os.path.expanduser("~/code/_tools/isla-lyrics-lab"))
    parser.add_argument("--out", default="pool")
    args = parser.parse_args(argv)
    if not args.out or "/" in args.out or args.out.startswith((".", "_")):
        parser.error(f"--out must be a plain directory name, got {args.out!r}")
    summary = build(args.root, args.out)
    t = summary["totals"]
    print(f"pool: {t['written']} synced records from {t['answered']} cached answers to {t['queries']} queries "
          f"({t['tracks']} tracks); word timing: hasWordSync {t['has_word_sync']}, "
          f"enhanced-LRC tags {t['enhanced_lrc_word_tags']}")
    for name, n in summary["per_slice"].items():
        print(f"  {name}: {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
