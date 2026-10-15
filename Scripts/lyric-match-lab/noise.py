#!/usr/bin/env python3
"""M9 from the cache alone: how far independent LRCLIB uploads of one song and
one length disagree in their line stamps.

    python3 noise.py --root <root>

For each harvested track with a cached track-and-artist search page, the
synced, non-instrumental rows form one cluster when their title equals the
track's after LRCLIB's normalisation (twin.prepare_input), their artist
contains the track's primary artist as a phrase, and their length is within
2 s of the track's (Apple's, else Deezer's). analysis.NoiseStudy, the
classifier's own M9 code, then collapses identical timelines, aligns each
pair by line text, and reports the constant offset and the residual jitter
(SPEC M9). Two records that do not share enough lines never form a pair, so a
cover that slipped into a cluster does not count.

Why not the classifier: its M9 needs resolved tracks with oracle truth, and
LRCLIB stopped answering this address before most of the sample was resolved
(SPEC, "a ban is not a rate"). The cached pages are enough for this question.

Limits: a cluster holds only the uploads in the first 20 rows the search
returned, which are the best-ranked for the title and artist, not a random
sample of the catalogue.

Cache reads only, never the network. Writes <root>/reports/noise-from-pages.json;
nothing written or printed carries a lyric line.
"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import analysis  # noqa: E402
import common  # noqa: E402
import resolve  # noqa: E402
import twin  # noqa: E402

WINDOW = 2.0


def cluster(track: dict, rows: list, duration: float) -> dict:
    title = twin.prepare_input(track["title"])
    primary = twin.tokens(twin.prepare_input(track["artists"][0] if track["artists"] else ""))
    lines_by_id = {}
    for row in rows:
        if not isinstance(row, dict) or row.get("instrumental") or not row.get("syncedLyrics"):
            continue
        if twin.prepare_input(row.get("trackName")) != title:
            continue
        if not twin.contains_phrase(twin.tokens(twin.prepare_input(row.get("artistName"))), primary):
            continue
        length = row.get("duration")
        if not isinstance(length, (int, float)) or abs(length - duration) > WINDOW:
            continue
        lines = analysis.sung(row)
        if lines:
            lines_by_id[row["id"]] = lines
    return lines_by_id


def run(root: str) -> dict:
    study = analysis.NoiseStudy()
    tracks = clusters = records = 0
    # Which slices the pages cover: the collector answered slices in file
    # order before LRCLIB refused it, so the coverage is not the corpus's.
    by_slice = {}
    for _, slice_tracks in resolve.load_slices(root, None, None):
        for track in slice_tracks:
            url = resolve.lrclib_search_urls(track).get("search:track_artist")
            hit = common.read_any_cache(root, url) if url else None
            if hit is None or hit.status != 200:
                continue
            with contextlib.redirect_stdout(io.StringIO()):
                apple = resolve.resolve_apple(track, root, True).get("apple")
                deezer = resolve.resolve_deezer(track, root, True).get("deezer")
            duration = (apple or {}).get("duration") or (deezer or {}).get("duration") or 0
            if not duration:
                continue
            tracks += 1
            cell = by_slice.setdefault(track["slice"], {"tracks": 0, "clusters": 0})
            cell["tracks"] += 1
            lines_by_id = cluster(track, hit.json() or [], duration)
            if len(lines_by_id) >= 2:
                clusters += 1
                cell["clusters"] += 1
                records += len(lines_by_id)
                study.add_track(track["slice"], lines_by_id)
    summary = {
        "tracks_with_a_page_and_a_length": tracks,
        "clusters_of_two_or_more": clusters,
        "records_in_clusters": records,
        "by_slice": by_slice,
        "duplicates": study.duplicate_report(),
        "noise": study.result(),
    }
    out = os.path.join(root, "reports", "noise-from-pages.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2, sort_keys=True)
    return summary


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="M9 catalogue timing noise from the cached search pages.")
    parser.add_argument("--root", default=os.path.expanduser("~/code/_tools/isla-lyrics-lab"))
    args = parser.parse_args(argv)
    print(json.dumps(run(args.root), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
