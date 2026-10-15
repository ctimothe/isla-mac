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

Third review (M3): a candidate must not win by making lookups unanswerable. The
headline carries the accuracy bounds on both sides; a paired accuracy is taken
over the lookups usable on both sides (`paired`, with the lookups unscorable on
exactly one side and their transitions); and the result is `incomplete` while
`needs_recording` is non-empty or any lookup moved from a scorable verdict to
uncached, unrecovered, failed or unjudged. M4: a lookup either run flagged
`anchor-promoted` is judged against a truth each run built from its own
answers, so it is in no gain, loss or cut here and is tallied under
`anchor_promoted`.

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

import analysis  # noqa: E402
import classify  # noqa: E402

RANK = {
    "correct": 3, "correct-none": 3,
    "correct-longer-cut": 2, "alt-script": 2,
    "miss-rejected": 1, "miss-unqueried": 1, "miss-text-only": 1, "miss-tolerance": 1,
    "miss-plain-only": 1, "miss-catalogue": 1, "failed-request": 1, "unreadable": 1,
    "wrong-song": 0, "uncertain": 0,
}
UNSCORABLE = set(classify.NO_JUDGEMENT) | set(classify.EXCLUDED_TRUTH) | {"unjudged"}
HEADLINE = ("lookups", "usable", "correct", "accuracy", "accuracy_bounds", "shown", "wrong", "wrong_rate",
            "wrong_rate_bounds", "recoverable_misses", "recoverable_of_usable", "uncached", "unrecovered",
            "unscorable_possibly_usable", "correct_without_fit", "failed_request")
# Moving from a verdict that was scored to one of these hides a loss behind a
# figure that rises or holds (M3).
LOSS_HIDING = ("uncached", "unrecovered", "failed", "unjudged")

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
    if isinstance(before, dict) and isinstance(after, dict):
        return {k: delta(before.get(k), after.get(k)) for k in before if k in after}
    return None


def is_promoted(*rows: dict) -> bool:
    return any(classify.PROMOTED_FLAG in (r.get("flags") or "").split(";") for r in rows)


def usable(row: dict) -> bool:
    return row.get("usable") == "true"


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
    promoted = {"lookups": 0, "gain": 0, "loss": 0, "same": 0, "unscorable": 0}
    hidden: Dict[str, int] = {}
    paired = {scope: {"n": 0, "base_correct": 0, "candidate_correct": 0, "one_side": 0, "transitions": {}}
              for scope in ("canonical", "overall")}
    for key in sorted(set(before_rows) & set(after_rows)):
        b, a = before_rows[key], after_rows[key]
        if a["verdict"] == "uncached" and b["verdict"] != "uncached":
            needs_recording.append({"track_id": key[0], "variant": key[1], "before": b["verdict"]})
        if b["verdict"] not in UNSCORABLE and a["verdict"] in LOSS_HIDING:
            name = f"{b['verdict']} -> {a['verdict']}"
            hidden[name] = hidden.get(name, 0) + 1
        moved = b["verdict"] != a["verdict"] or b["chosen_id"] != a["chosen_id"]
        if is_promoted(b, a):
            # Judged against a truth each run built from its own answers: a
            # transition measures whether Isla found an identity match, never
            # whether it was right (third review, M4). Own tally, no other figure.
            promoted["lookups"] += 1
            if moved:
                verdict = judge(b["verdict"], a["verdict"])
                promoted[verdict] += 1
            continue
        for scope in ("overall", "canonical") if key[1] == "canonical" else ("overall",):
            cell = paired[scope]
            if usable(b) and usable(a):
                cell["n"] += 1
                cell["base_correct"] += 1 if b["verdict"] == "correct" else 0
                cell["candidate_correct"] += 1 if a["verdict"] == "correct" else 0
            elif (b["verdict"] in UNSCORABLE) != (a["verdict"] in UNSCORABLE):
                cell["one_side"] += 1
                name = f"{b['verdict']} -> {a['verdict']}"
                cell["transitions"][name] = cell["transitions"].get(name, 0) + 1
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
    paired_report = {}
    for scope, cell in paired.items():
        base_accuracy = analysis.share(cell["base_correct"], cell["n"])
        candidate_accuracy = analysis.share(cell["candidate_correct"], cell["n"])
        paired_report[scope] = {
            "n_paired": cell["n"], "base_accuracy": base_accuracy, "candidate_accuracy": candidate_accuracy,
            "delta": delta(base_accuracy, candidate_accuracy),
            "unscorable_on_one_side": cell["one_side"],
            "unscorable_transitions": dict(sorted(cell["transitions"].items(), key=lambda kv: (-kv[1], kv[0]))),
        }
    return {
        "base": {"reports": base, "results": base_results},
        "candidate": {"reports": candidate, "results": candidate_results},
        "headline": headline,
        "paired": paired_report,
        # True while the figures above could still move: a candidate lookup the
        # cache could not answer, or one that went from a scored verdict to a
        # lookup nobody can attribute or judge (M3).
        "incomplete": bool(needs_recording or hidden),
        "scored_to_unscorable": dict(sorted(hidden.items(), key=lambda kv: (-kv[1], kv[0]))),
        "anchor_promoted": promoted,
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


def _range(cell: dict) -> str:
    """`[lower, upper]` of a bounds cell, or '-' when a side has none (an older report)."""
    def one(bounds) -> str:
        return "-" if not isinstance(bounds, dict) else f"[{_pct(bounds.get('lower'))}, {_pct(bounds.get('upper'))}]"
    return f"{one(cell['base'])} -> {one(cell['candidate'])}"


def summary(result: dict) -> str:
    c = result["headline"]["canonical"]
    t = result["totals"]
    p = result["paired"]["canonical"]
    lines = [
        f"candidate {result['candidate']['reports']} against {result['base']['reports']}: "
        f"{result['lookups_joined']} lookups joined"
        + ("  INCOMPLETE: the figures below can still move (lookups to record, or scored lookups that "
           "became unscorable)" if result["incomplete"] else ""),
        f"  canonical accuracy {_pct(c['accuracy']['base'])} -> {_pct(c['accuracy']['candidate'])}, "
        f"bounds {_range(c['accuracy_bounds'])}, "
        f"wrong rate {_pct(c['wrong_rate']['base'])} -> {_pct(c['wrong_rate']['candidate'])}, "
        f"bounds {_range(c['wrong_rate_bounds'])}, "
        f"recoverable misses {c['recoverable_misses']['base']} -> {c['recoverable_misses']['candidate']}",
        f"  paired canonical accuracy {_pct(p['base_accuracy'])} -> {_pct(p['candidate_accuracy'])} over "
        f"{p['n_paired']} lookups usable on both sides; {p['unscorable_on_one_side']} unscorable on exactly one",
        f"  every variant: gained {t['gain']}, lost {t['loss']}, unscorable {t['unscorable']}, "
        f"changed at the same rank {t['changed_same_rank']}",
        f"  anchor-promoted lookups, tallied apart: {result['anchor_promoted']}",
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
