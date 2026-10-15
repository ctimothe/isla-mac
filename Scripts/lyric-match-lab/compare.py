#!/usr/bin/env python3
"""Score a candidate change to Isla beside the baseline, lookup by lookup.

    python3 compare.py --root <root> --base reports --candidate <reports-dir> \
        [--base-results results] [--candidate-results <results-dir>]

Both report directories are classify.py output over the same cache: rows.csv
and match-lab-report.json. The results directories are what the Swift harness
wrote (ISLA_MATCH_OUT); they give each lookup's requests. `--candidate-results`
defaults to the candidate's reports name with a trailing "-reports" removed,
which is how Scripts/lyric-match-lab/score-candidate.sh names the pair.

Each (track_id, variant) lookup is joined across the two runs. A lookup whose
verdict changed is ranked by what a listener sees: the right song (correct,
correct-none) over the right song with a caveat (correct-longer-cut,
alt-script) over nothing shown (every miss, failed-request, unreadable) over a
wrong or doubtful song (wrong-song, uncertain). A wrong song ranks below
nothing at all: words that are not the song mislead, where an empty stage only
disappoints.

A lookup that cannot be judged on either side (failed, uncached, unrecovered,
unjudged, or a track-level exclusion) is counted apart and is never a gain or a
loss. An `uncached` candidate lookup asked a question the cache holds no answer
for: the candidate needs a --record run before it can be scored there, and the
lookups are listed under `needs_recording`.

Writes <root>/<candidate>/compare.json and prints a summary. Like everything
in the lab it carries numbers, LRCLIB ids, titles and artist names, never a
lyric line.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from typing import Dict, List, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import classify  # noqa: E402

RANK = {
    "correct": 3, "correct-none": 3,
    "correct-longer-cut": 2, "alt-script": 2,
    "miss-rejected": 1, "miss-unqueried": 1, "miss-text-only": 1, "miss-tolerance": 1,
    "miss-plain-only": 1, "miss-catalogue": 1, "failed-request": 1, "unreadable": 1,
    "wrong-song": 0, "uncertain": 0,
}
UNSCORABLE = set(classify.NO_JUDGEMENT) | set(classify.EXCLUDED_TRUTH) | {"unjudged"}
HEADLINE = ("lookups", "usable", "correct", "accuracy", "shown", "wrong", "wrong_rate",
            "recoverable_misses", "recoverable_of_usable", "uncached", "failed_request")

Key = Tuple[str, str]


def read_rows(path: str) -> Dict[Key, dict]:
    with open(path, encoding="utf-8", newline="") as handle:
        return {(r["track_id"], r["variant"]): r for r in csv.DictReader(handle)}


def read_lookups(path: str) -> Dict[Key, dict]:
    out: Dict[Key, dict] = {}
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                row = json.loads(line)
                out[(row["track_id"], row["variant"])] = row
    return out


def read_headline(path: str) -> dict:
    with open(path, encoding="utf-8") as handle:
        m1 = json.load(handle).get("M1", {})
    return {scope: {k: (m1.get(scope) or {}).get(k) for k in HEADLINE} for scope in ("canonical", "overall")}


def delta(before, after):
    if isinstance(before, (int, float)) and isinstance(after, (int, float)):
        return round(after - before, 6)
    return None


def judge(before: str, after: str) -> str:
    """gain, loss, same or unscorable for one lookup."""
    if before in UNSCORABLE or after in UNSCORABLE:
        return "same" if before == after else "unscorable"
    if before not in RANK or after not in RANK:
        return "same" if before == after else "unscorable"
    if RANK[after] > RANK[before]:
        return "gain"
    if RANK[after] < RANK[before]:
        return "loss"
    return "same"


def tally(rows: List[dict], key: str) -> Dict[str, Dict[str, int]]:
    out: Dict[str, Dict[str, int]] = {}
    for r in rows:
        cell = out.setdefault(r[key], {"gain": 0, "loss": 0, "unscorable": 0, "changed_same_rank": 0})
        cell[r["judgement"] if r["judgement"] != "same" else "changed_same_rank"] += 1
    return dict(sorted(out.items()))


def compare(root: str, base: str, candidate: str, base_results: str, candidate_results: str) -> dict:
    before_rows = read_rows(os.path.join(root, base, "rows.csv"))
    after_rows = read_rows(os.path.join(root, candidate, "rows.csv"))
    before_lookups = read_lookups(os.path.join(root, base_results, "isla-lookups.jsonl"))
    after_lookups = read_lookups(os.path.join(root, candidate_results, "isla-lookups.jsonl"))

    changed: List[dict] = []
    transitions: Dict[str, int] = {}
    totals = {"gain": 0, "loss": 0, "unscorable": 0, "changed_same_rank": 0}
    needs_recording: List[dict] = []
    for key in sorted(set(before_rows) & set(after_rows)):
        b, a = before_rows[key], after_rows[key]
        if a["verdict"] == "uncached" and b["verdict"] != "uncached":
            needs_recording.append({"track_id": key[0], "variant": key[1], "before": b["verdict"]})
        moved = b["verdict"] != a["verdict"] or b["chosen_id"] != a["chosen_id"]
        if not moved:
            continue
        verdict = judge(b["verdict"], a["verdict"])
        if b["verdict"] != a["verdict"]:
            name = f"{b['verdict']} -> {a['verdict']}"
            transitions[name] = transitions.get(name, 0) + 1
        totals[verdict if verdict != "same" else "changed_same_rank"] += 1
        changed.append({
            "track_id": key[0], "variant": key[1], "slice": a["slice"], "pick": a["pick"],
            "title": a["title"], "artist": a["artist"], "duration": a["duration"],
            "before": b["verdict"], "after": a["verdict"],
            "chosen_before": b["chosen_id"] or None, "chosen_after": a["chosen_id"] or None,
            "via_before": b["chosen_via"] or None, "via_after": a["chosen_via"] or None,
            "flags_after": a["flags"] or None, "judgement": verdict,
        })

    def requests(lookups: Dict[Key, dict]) -> dict:
        sent = sum(len(row.get("requests") or []) for row in lookups.values())
        uncached = sum(1 for row in lookups.values() if row.get("outcome") == "uncached")
        return {"lookups": len(lookups), "requests": sent, "uncached_lookups": uncached}

    before_headline = read_headline(os.path.join(root, base, "match-lab-report.json"))
    after_headline = read_headline(os.path.join(root, candidate, "match-lab-report.json"))
    headline = {
        scope: {k: {"base": before_headline[scope][k], "candidate": after_headline[scope][k],
                    "delta": delta(before_headline[scope][k], after_headline[scope][k])} for k in HEADLINE}
        for scope in ("canonical", "overall")
    }
    only = sorted(set(before_rows) ^ set(after_rows))
    return {
        "base": {"reports": base, "results": base_results},
        "candidate": {"reports": candidate, "results": candidate_results},
        "headline": headline,
        "lookups_joined": len(set(before_rows) & set(after_rows)),
        "lookups_in_one_run_only": len(only),
        "totals": totals,
        "transitions": dict(sorted(transitions.items(), key=lambda kv: (-kv[1], kv[0]))),
        "by_variant": tally(changed, "variant"),
        "by_slice": tally(changed, "slice"),
        "requests": {"base": requests(before_lookups), "candidate": requests(after_lookups)},
        "needs_recording": needs_recording,
        "changed": changed,
    }


def _pct(value: Optional[float]) -> str:
    return "-" if value is None else f"{value * 100:.1f}%"


def summary(result: dict) -> str:
    c = result["headline"]["canonical"]
    t = result["totals"]
    lines = [
        f"candidate {result['candidate']['reports']} against {result['base']['reports']}: "
        f"{result['lookups_joined']} lookups joined",
        f"  canonical accuracy {_pct(c['accuracy']['base'])} -> {_pct(c['accuracy']['candidate'])}, "
        f"wrong rate {_pct(c['wrong_rate']['base'])} -> {_pct(c['wrong_rate']['candidate'])}, "
        f"recoverable misses {c['recoverable_misses']['base']} -> {c['recoverable_misses']['candidate']}",
        f"  every variant: gained {t['gain']}, lost {t['loss']}, unscorable {t['unscorable']}, "
        f"changed at the same rank {t['changed_same_rank']}",
        f"  requests {result['requests']['base']['requests']} -> {result['requests']['candidate']['requests']}; "
        f"needs a --record run for {len(result['needs_recording'])} lookups",
    ]
    for name, n in list(result["transitions"].items())[:12]:
        lines.append(f"    {n:4d}  {name}")
    return "\n".join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Score a candidate change to Isla beside the baseline.")
    parser.add_argument("--root", default=classify.DEFAULT_ROOT)
    parser.add_argument("--base", default=classify.DEFAULT_REPORTS, type=classify._dirname_arg)
    parser.add_argument("--candidate", required=True, type=classify._dirname_arg)
    parser.add_argument("--base-results", default=classify.DEFAULT_RESULTS, type=classify._dirname_arg)
    parser.add_argument("--candidate-results", default=None, type=classify._dirname_arg)
    args = parser.parse_args(argv)
    candidate_results = args.candidate_results or (
        args.candidate[: -len("-reports")] if args.candidate.endswith("-reports") else args.candidate)
    result = compare(args.root, args.base, args.candidate, args.base_results, candidate_results)
    classify.write_json(os.path.join(args.root, args.candidate, "compare.json"), result)
    print(summary(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
