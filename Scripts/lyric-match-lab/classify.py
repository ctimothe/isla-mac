#!/usr/bin/env python3
"""Classify what Isla did against the oracle's truth: the lab's report (phase 2).

    python3 classify.py --root <root>

Joins `results/isla-lookups.jsonl` (written by the Swift harness) with
`resolved/tracks.jsonl` (written by resolve.py) and gives every lookup one
verdict (SPEC "Classification", made exact in the rules below). Offline: it
reads the two replay caches and never opens a socket.

Reads   resolved/{tracks,variants}.jsonl  results/{isla-lookups,perturbations}.jsonl
        results/{word-fidelity,readability}.json  wordtimed/<slice>/<id>.json
        cache/py/ and cache/isla/ (LRCLIB rows, by URL and by the Swift run's keys)
Writes  reports/match-lab-report.json   every section, numbers only
        reports/rows.csv                one row per lookup with its verdict
        reports/diagnose-input.jsonl    the lookups a Swift case re-examines
        matched/<slice>/<id>.json       the records Isla chose, in the 2026-10-11
                                        lab's corpus format, for M5

Nothing written under reports/ carries a lyric line. matched/ and wordtimed/
do, and stay under the corpus root.

Verdicts (M1)
  correct              chosen record is in the same-song cluster; not timed for a longer cut
  correct-longer-cut   same song, but Isla itself says it is timed for a longer version
  alt-script           same song in another script, or a translation
  wrong-song           containment <= 0.2 with the cluster; or any lyric for an expected
                       instrumental (flag instrumental-fp; catalogue-mislabel if the record
                       is a title-and-artist match)
  uncertain            containment between 0.2 and 0.6
  unrecovered          Isla showed lyrics but the harness could not say which record
  unjudged             lyrics shown for a track with no anchor record (listed, not scored)
  miss-rejected        nothing shown, a fit record was in Isla's own responses
  miss-unqueried       nothing shown, a fit record exists but no query of Isla's returned it
  miss-tolerance       nothing shown, only near records (3-10 s off) exist
  miss-plain-only      nothing shown, the cluster has plain lyrics only
  miss-catalogue       nothing shown, nothing usable exists
  correct-none         an expected instrumental, nothing shown
  unreadable / failed / uncached   taken as the harness reported them

"Same-song" and "fit" records are the union of the resolver's pool and the
records in Isla's own responses to that lookup. A response record joins the
cluster when its containment against the group anchors is at least 0.6. "Fit"
is judged against the lookup's own variant duration: within 3 s, last sung
stamp no later than duration + 3.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
import statistics
import sys
from typing import Dict, List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import analysis  # noqa: E402
import common  # noqa: E402
import oracle  # noqa: E402
import resolve  # noqa: E402

DEFAULT_ROOT = resolve.DEFAULT_ROOT

SAME = 0.6       # containment at or above: the same song
WRONG = 0.2      # containment at or below: a different song
FIT_S = 3.0
NEAR_S = 10.0

SHOWN = ("correct", "correct-longer-cut", "alt-script", "wrong-song", "uncertain")
WRONG_RATE_VERDICTS = ("wrong-song", "correct-longer-cut", "uncertain")
RECOVERABLE = ("miss-rejected", "miss-unqueried")
DIAGNOSE = ("miss-rejected", "miss-unqueried", "miss-tolerance", "wrong-song", "uncertain",
            "correct-longer-cut", "alt-script", "unrecovered")
MATCHED_VERDICTS = ("correct", "correct-longer-cut", "alt-script")

# Section verdict thresholds, stated here so the report can print them.
THRESHOLDS = {
    "M1": {"pass": "canonical accuracy >= 0.90, wrong rate <= 0.02, recoverable misses <= 0.02 of usable",
           "fail": "canonical accuracy < 0.75 or wrong rate > 0.05"},
    "M2": {"pass": "no switched-wrong and lost <= 0.02 of applicable (duration edges excluded)",
           "fail": "switched-wrong > 0.01 of applicable"},
    "M6": {"pass": "no variant loses more than 0.05 of the tracks canonical gets right",
           "fail": "a variant loses 0.20 or more"},
}


# --------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------

def read_jsonl(path: str) -> List[dict]:
    if not os.path.exists(path):
        return []
    out = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    continue
    return out


def read_json(path: str):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def read_isla_key(root: str, key: str) -> Optional[common.Response]:
    """The response the Swift harness was served; `key` is the file name's hash.

    The harness answers from its own store first and then from the resolver's
    (both key on the SHA-256 of the exact URL), so this reads them in the same
    order. Reading only `cache/isla` would drop every row Isla was served from
    `cache/py`, and with them the evidence `isla_saw_fit` rests on.
    """
    import base64
    name = key[:-5] if key.endswith(".json") else key
    for store in ("isla", "py"):
        try:
            with open(os.path.join(root, "cache", store, name + ".json"), encoding="utf-8") as handle:
                entry = json.load(handle)
            return common.Response(int(entry["status"]), base64.b64decode(entry["body_b64"]), True)
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return None


def rows_of(response: Optional[common.Response]) -> List[dict]:
    """LRCLIB rows in a get object or a search array; [] for anything else."""
    if response is None or response.status != 200:
        return []
    data = response.json()
    if isinstance(data, dict):
        return [data] if data.get("id") is not None else []
    if isinstance(data, list):
        return [r for r in data if isinstance(r, dict) and r.get("id") is not None]
    return []


def absorb(into: Dict[int, dict], row: dict) -> None:
    rid = row["id"]
    if rid not in into:
        into[rid] = dict(row)
    else:
        for field, value in row.items():
            if into[rid].get(field) in (None, "") and value not in (None, ""):
                into[rid][field] = value


def pool_rows(root: str, track: dict) -> Dict[int, dict]:
    """The resolver's candidate rows for a track, read back from cache/py.
    Rebuilt rather than stored: tracks.jsonl holds no lyric text."""
    pool: Dict[int, dict] = {}
    for url in (track.get("lrclib_urls") or {}).values():
        for row in rows_of(common.read_any_cache(root, url)):
            absorb(pool, row)
    return pool


def isla_rows(root: str, lookup: dict) -> Dict[int, dict]:
    rows: Dict[int, dict] = {}
    for request in lookup.get("requests") or []:
        key = request.get("key")
        if key:
            for row in rows_of(read_isla_key(root, key)):
                absorb(rows, row)
    return rows


# --------------------------------------------------------------------------
# One track's truth
# --------------------------------------------------------------------------

class Truth:
    """Everything the verdicts of one track's lookups need, built once.

    Holds the lyric fingerprints of the group anchors, so a record Isla chose
    can be compared with them however it was found.
    """

    def __init__(self, root: str, track: dict):
        self.track = track
        self.harvest = track.get("harvest") or {}
        self.truth = track.get("truth") or {}
        self.pool = pool_rows(root, track)
        self.infos: Dict[int, dict] = {}
        self.cluster = set(self.truth.get("cluster_ids") or [])
        self.alt = set(self.truth.get("alt_script_ids") or [])
        self.candidates = {c["id"]: c for c in track.get("candidates") or []}
        self.titles = resolve.identity_titles(self.harvest, track.get("apple"), track.get("deezer"),
                                              track.get("apple_us"))
        self.artists = resolve.identity_artists(self.harvest, track.get("apple"), track.get("deezer"),
                                                track.get("apple_us"))
        self.anchor_fps: Dict[int, frozenset] = {}
        group_scripts: List[str] = []
        for cid, cand in self.candidates.items():
            if cand.get("anchor") and cid in self.pool:
                info = self.info(cid, self.pool[cid])
                if info["fp"] and not info["instrumental"]:
                    self.anchor_fps[cid] = info["fp"]
                    group_scripts.append(info["script"])
        self.group_family = oracle.script_family(group_scripts[0]) if group_scripts else ""

    def info(self, rid: int, row: dict) -> dict:
        cached = self.infos.get(rid)
        if cached is None:
            cached = oracle.analyze_record(row)
            cached["identity"] = oracle.title_match(self.titles, row.get("trackName") or "") and \
                oracle.artist_match(self.artists, row.get("artistName") or "")
            cached["duration"] = float(row.get("duration") or 0)
            self.infos[rid] = cached
        return cached

    def containment(self, rid: int, info: dict) -> Optional[float]:
        others = [fp for aid, fp in self.anchor_fps.items() if aid != rid]
        if not info["fp"] or not others:
            return None
        return round(max(oracle.containment(info["fp"], fp) for fp in others), 3)


def judge(truth: Truth, lookup: dict, rows: Dict[int, dict]) -> dict:
    """The verdict of one lookup and the evidence behind it. See the module
    docstring for the rules; `rows` are the records in Isla's own responses."""
    t = truth.truth
    variant = lookup["variant"]
    duration = float((lookup.get("identity") or {}).get("duration") or 0)
    outcome = lookup.get("outcome")
    flags: List[str] = []

    everything = dict(truth.pool)
    for rid, row in rows.items():
        everything.setdefault(rid, row)
    infos = {rid: truth.info(rid, row) for rid, row in everything.items()}

    members = set(truth.cluster)
    for rid in rows:
        info = infos[rid]
        if rid in members or rid in truth.alt or not info["fp"] or info["instrumental"]:
            continue
        score = truth.containment(rid, info)
        if score is not None and score >= SAME:
            members.add(rid)

    synced = [rid for rid in members if infos[rid]["has_synced"] and rid not in truth.alt]
    fit, near = [], []
    if duration <= 0:
        fit = [(0.0, rid) for rid in synced]
        flags.append("no-duration")
    else:
        for rid in synced:
            info = infos[rid]
            delta = round(abs(info["duration"] - duration), 3)
            if delta <= FIT_S and info["last_stamp"] is not None and info["last_stamp"] <= duration + FIT_S:
                fit.append((delta, rid))
            elif FIT_S < delta <= NEAR_S:
                near.append((delta, rid))
    fit_ids = [rid for _, rid in sorted(fit)]
    near_ids = [rid for _, rid in sorted(near)]
    saw_fit = bool(set(fit_ids) & set(rows))
    plain_only = bool(members) and not any(infos[r]["has_synced"] for r in members) \
        and any(infos[r]["has_plain"] for r in members)

    chosen_id = lookup.get("chosen_id")
    status = t.get("truth_status")
    expected_instrumental = bool(t.get("instrumental_expected"))
    containment: Optional[float] = None
    verdict: str

    if lookup.get("chosen_ambiguous"):
        flags.append("ambiguous-recovery")

    if outcome in ("unreadable", "failed", "uncached"):
        verdict = outcome
    elif outcome == "found":
        chosen = infos.get(chosen_id) if chosen_id is not None else None
        if chosen is not None:
            containment = truth.containment(chosen_id, chosen)
        if expected_instrumental:
            verdict = "wrong-song"
            flags.append("instrumental-fp")
            if chosen is not None and chosen["identity"]:
                flags.append("catalogue-mislabel")
        elif chosen_id is None or chosen is None:
            verdict = "unrecovered"
        elif status == "no-anchor":
            verdict = "unjudged"
        else:
            if chosen_id in members:
                same = True
            elif chosen_id in truth.alt or (chosen["identity"] and chosen["fp"]
                                            and truth.group_family
                                            and oracle.script_family(chosen["script"]) != truth.group_family):
                same = None
            elif containment is not None and containment >= SAME:
                same = True
                flags.append("late-cluster")
            else:
                same = False
            if same is None:
                verdict = "alt-script"
            elif same:
                verdict = "correct-longer-cut" if lookup.get("timed_for_longer") else "correct"
                if duration > 0 and abs(chosen["duration"] - duration) > FIT_S:
                    flags.append("off-length")
            elif containment is not None and containment > WRONG:
                verdict = "uncertain"
            else:
                verdict = "wrong-song"
    else:  # none
        if expected_instrumental:
            verdict = "correct-none"
        elif status == "no-anchor":
            verdict = "miss-catalogue"
            if rows or truth.candidates:
                flags.append("candidates-without-anchor")
        elif fit_ids:
            verdict = "miss-rejected" if saw_fit else "miss-unqueried"
        elif near_ids:
            verdict = "miss-tolerance"
        elif plain_only:
            verdict = "miss-plain-only"
        else:
            verdict = "miss-catalogue"
            if synced:
                flags.append("synced-off-length")

    return {
        "verdict": verdict, "flags": flags, "containment": containment,
        "fit_ids": fit_ids, "near_ids": near_ids, "isla_saw_fit": saw_fit,
        "cluster_ids": sorted(members), "alt_n": len(truth.alt),
        "chosen_info": infos.get(chosen_id) if chosen_id is not None else None,
        "infos": infos, "everything": everything, "members": members,
        "usable": (not expected_instrumental and status != "no-anchor"
                   and outcome not in ("failed", "uncached")
                   and (bool(fit_ids) or verdict == "correct")),
    }


# --------------------------------------------------------------------------
# Counting
# --------------------------------------------------------------------------

def counts(rows: List[dict]) -> dict:
    """Headline figures (SPEC "Classification") for a set of lookup results."""
    verdicts: Dict[str, int] = {}
    for r in rows:
        verdicts[r["verdict"]] = verdicts.get(r["verdict"], 0) + 1
    usable = [r for r in rows if r["usable"]]
    correct = sum(1 for r in usable if r["verdict"] == "correct")
    shown = sum(verdicts.get(v, 0) for v in SHOWN)
    wrong = sum(verdicts.get(v, 0) for v in WRONG_RATE_VERDICTS)
    recoverable = sum(verdicts.get(v, 0) for v in RECOVERABLE)
    return {
        "lookups": len(rows),
        "usable": len(usable),
        "correct": correct,
        "accuracy": analysis.share(correct, len(usable)),
        "shown": shown,
        "wrong": wrong,
        "wrong_rate": analysis.share(wrong, shown),
        "recoverable_misses": recoverable,
        "recoverable_of_usable": analysis.share(
            sum(1 for r in usable if r["verdict"] in RECOVERABLE), len(usable)),
        "verdicts": dict(sorted(verdicts.items())),
    }


def cut(rows: List[dict], keys) -> Dict[str, dict]:
    """counts() grouped by `keys(row)`, which returns one key or a list."""
    groups: Dict[str, List[dict]] = {}
    for r in rows:
        k = keys(r)
        for key in (k if isinstance(k, (list, tuple)) else [k]):
            groups.setdefault(str(key), []).append(r)
    return {k: counts(v) for k, v in sorted(groups.items())}


def section(verdict: str, summary: str, **data) -> dict:
    return dict({"verdict": verdict, "summary": summary}, **data)


# --------------------------------------------------------------------------
# M2 and M6
# --------------------------------------------------------------------------

def perturbation_section(rows: List[dict], clusters: Dict[str, set]) -> dict:
    buckets = ("kept", "lost", "switched-wrong", "switched-ok")
    per: Dict[str, dict] = {}
    for r in rows:
        if not r.get("applicable"):
            continue
        cluster = clusters.get(r["track_id"])
        if cluster is None:
            continue
        base, picked = r.get("base_id"), r.get("picked_id")
        if picked == base:
            outcome = "kept"
        elif base is not None and picked is None:
            outcome = "lost"
        elif picked in cluster:
            outcome = "kept" if base in cluster else "switched-ok"
        else:
            outcome = "switched-wrong"
        cell = per.setdefault(r["perturbation"], {"applicable": 0, **{b: 0 for b in buckets},
                                                 "examples": {"lost": [], "switched-wrong": []}})
        cell["applicable"] += 1
        cell[outcome] += 1
        if outcome in ("lost", "switched-wrong") and len(cell["examples"][outcome]) < 5:
            cell["examples"][outcome].append(r["track_id"])
    for cell in per.values():
        for b in buckets:
            cell[f"{b}_share"] = analysis.share(cell[b], cell["applicable"])
    ordinary = [c for k, c in per.items() if not k.startswith("d-")]
    applicable = sum(c["applicable"] for c in ordinary)
    lost = sum(c["lost"] for c in ordinary)
    wrong = sum(c["switched-wrong"] for c in ordinary)
    total = sum(c["applicable"] for c in per.values())
    if not total:
        return section("info", "no applicable perturbation rows", perturbations={})
    if applicable and wrong / applicable > 0.01:
        verdict = "fail"
    elif wrong or (applicable and lost / applicable > 0.02):
        verdict = "concern"
    else:
        verdict = "pass"
    worst = max(per.items(), key=lambda kv: (kv[1]["switched-wrong"] + kv[1]["lost"]))
    return section(
        verdict,
        f"{total} applicable perturbations across {len(per)} kinds; excluding duration edges "
        f"{lost} lost and {wrong} switched to a wrong song out of {applicable}; "
        f"worst kind {worst[0]} ({worst[1]['lost']} lost, {worst[1]['switched-wrong']} switched-wrong).",
        perturbations=dict(sorted(per.items())),
        duration_edges_excluded_from_verdict=sorted(k for k in per if k.startswith("d-")),
    )


def variant_section(results: List[dict]) -> dict:
    by_track: Dict[str, Dict[str, dict]] = {}
    for r in results:
        by_track.setdefault(r["track_id"], {})[r["variant"]] = r
    matrix: Dict[str, Dict[str, Dict[str, int]]] = {}
    lost: Dict[str, dict] = {}
    base_right = 0
    for tid, variants in by_track.items():
        base = variants.get("canonical")
        if not base:
            continue
        right = base["verdict"] == "correct"
        base_right += 1 if right else 0
        for name, r in variants.items():
            if name == "canonical":
                continue
            cell = matrix.setdefault(name, {}).setdefault(base["verdict"], {})
            cell[r["verdict"]] = cell.get(r["verdict"], 0) + 1
            if right and r["verdict"] not in ("correct", "failed", "uncached"):
                entry = lost.setdefault(name, {"tracks": 0, "by_verdict": {}, "examples": []})
                entry["tracks"] += 1
                entry["by_verdict"][r["verdict"]] = entry["by_verdict"].get(r["verdict"], 0) + 1
                if len(entry["examples"]) < 10:
                    entry["examples"].append(tid)
    comparable: Dict[str, int] = {}
    for variants in by_track.values():
        if variants.get("canonical", {}).get("verdict") == "correct":
            for name in variants:
                if name != "canonical":
                    comparable[name] = comparable.get(name, 0) + 1
    for name, entry in lost.items():
        entry["of_canonical_correct_with_this_variant"] = comparable.get(name, 0)
        entry["share"] = analysis.share(entry["tracks"], comparable.get(name, 0))
    if not matrix:
        return section("info", "no canonical lookups to compare against", transitions={}, lost_by_variant={})
    worst = max(lost.items(), key=lambda kv: kv[1]["share"] or 0, default=None)
    worst_share = (worst[1]["share"] or 0) if worst else 0
    verdict = "fail" if worst_share >= 0.20 else "concern" if worst_share >= 0.05 else "pass"
    summary = (f"{base_right} tracks where canonical is correct; "
               + (f"the variant that loses most is {worst[0]} ({worst[1]['tracks']} of "
                  f"{worst[1]['of_canonical_correct_with_this_variant']}, {round(worst_share * 100, 1)}%)."
                  if worst else "no variant loses any."))
    return section(verdict, summary, transitions=matrix, lost_by_variant=dict(sorted(lost.items())))


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

CSV_COLUMNS = ["track_id", "slice", "pick", "tags", "vocal", "language",
               "variant", "player_id", "title", "artist", "album", "duration",
               "outcome", "verdict", "flags", "chosen_id", "chosen_via", "containment", "timed_for_longer",
               "truth_status", "fit_n", "near_n", "isla_saw_fit", "cluster_n", "alt_n", "notes"]


def estimation_section(root: str, study: "analysis.EstimationStudy") -> dict:
    base = os.path.join(root, "wordtimed")
    fed = 0
    if os.path.isdir(base):
        for slice_id in sorted(os.listdir(base)):
            directory = os.path.join(base, slice_id)
            if not os.path.isdir(directory):
                continue
            for name in sorted(os.listdir(directory)):
                if name.endswith(".json"):
                    record = read_json(os.path.join(directory, name))
                    if isinstance(record, dict) and record.get("id") is not None:
                        fed += 1 if study.add_record(slice_id, record) else 0
    return study.result() | {"records_found": fed}


def verbatim(path: str, name: str) -> dict:
    data = read_json(path)
    if not isinstance(data, dict):
        return section("info", f"{name}: {os.path.basename(path)} not present (run the Swift harness)")
    data.setdefault("verdict", "info")
    data.setdefault("summary", f"{name} merged verbatim from {os.path.basename(path)}")
    return data


def run(root: str) -> dict:
    root = os.path.expanduser(root)
    tracks = read_jsonl(os.path.join(root, "resolved", "tracks.jsonl"))
    lookups = read_jsonl(os.path.join(root, "results", "isla-lookups.jsonl"))
    perturbations = read_jsonl(os.path.join(root, "results", "perturbations.jsonl"))
    by_track: Dict[str, List[dict]] = {}
    for lookup in lookups:
        by_track.setdefault(lookup["track_id"], []).append(lookup)

    matched_root = os.path.join(root, "matched")
    if os.path.isdir(matched_root):
        shutil.rmtree(matched_root)  # generated output; a stale record must not outlive its verdict
    matched_ids: set = set()

    results: List[dict] = []
    diagnose: List[dict] = []
    clusters: Dict[str, set] = {}
    noise = analysis.NoiseStudy()
    selection = analysis.SelectionStudy()
    coverage: Dict[str, dict] = {}
    consensus_cache: Dict[tuple, Dict] = {}

    for track in tracks:
        tid, slice_id = track["track_id"], track["slice"]
        truth = Truth(root, track)
        harvest = truth.harvest
        family = oracle.script_family(oracle.expected_script(harvest.get("language") or "", harvest.get("title") or ""))
        cov = coverage.setdefault(slice_id, {
            "tracks": 0, "tracks_with_word_timed_record_in_cluster": 0,
            "tracks_canonical_chosen_word_timed": 0, "canonical_found": 0,
            "found_lookups_by_granularity": {}, "found_canonical_by_granularity": {}})
        cov["tracks"] += 1
        if any(truth.candidates.get(i, {}).get("word_timing") for i in truth.cluster):
            cov["tracks_with_word_timed_record_in_cluster"] += 1
        canonical_judged = None
        for lookup in by_track.get(tid, []):
            rows = isla_rows(root, lookup)
            j = judge(truth, lookup, rows)
            identity = lookup.get("identity") or {}
            variant = lookup["variant"]
            result = {
                "track_id": tid, "slice": slice_id, "pick": harvest.get("pick") or "",
                "tags": harvest.get("tags") or [], "vocal": harvest.get("vocal") or "",
                "language": harvest.get("language") or "", "script_family": family,
                "variant": variant, "player_id": identity.get("player_id") or "",
                "title": identity.get("title") or "", "artist": identity.get("artist") or "",
                "album": identity.get("album") or "", "duration": identity.get("duration") or 0,
                "outcome": lookup.get("outcome"), "verdict": j["verdict"], "flags": j["flags"],
                "chosen_id": lookup.get("chosen_id"), "chosen_via": lookup.get("chosen_via"),
                "containment": j["containment"], "timed_for_longer": lookup.get("timed_for_longer"),
                "truth_status": truth.truth.get("truth_status"), "fit_n": len(j["fit_ids"]),
                "near_n": len(j["near_ids"]), "isla_saw_fit": j["isla_saw_fit"],
                "cluster_n": len(j["cluster_ids"]), "alt_n": len(truth.alt),
                "notes": truth.truth.get("notes") or [], "usable": j["usable"],
            }
            results.append(result)

            if lookup.get("outcome") == "found":
                gran = lookup.get("granularity") or "unknown"
                cov["found_lookups_by_granularity"][gran] = cov["found_lookups_by_granularity"].get(gran, 0) + 1
            if variant == "canonical":
                canonical_judged = (lookup, j)
                if lookup.get("outcome") == "found":
                    cov["canonical_found"] += 1
                    gran = lookup.get("granularity") or "unknown"
                    cov["found_canonical_by_granularity"][gran] = cov["found_canonical_by_granularity"].get(gran, 0) + 1
                    if j["chosen_info"] and j["chosen_info"]["word_timing"] and j["verdict"] in MATCHED_VERDICTS:
                        cov["tracks_canonical_chosen_word_timed"] += 1

            # M5: the record Isla chose, in the old corpus format.
            if variant == "canonical" and j["verdict"] in MATCHED_VERDICTS and lookup.get("chosen_id") is not None:
                row = j["everything"].get(lookup["chosen_id"])
                if row is not None and lookup["chosen_id"] not in matched_ids:
                    matched_ids.add(lookup["chosen_id"])
                    path = os.path.join(matched_root, slice_id, f"{lookup['chosen_id']}.json")
                    os.makedirs(os.path.dirname(path), exist_ok=True)
                    with open(path, "w", encoding="utf-8") as handle:
                        json.dump(dict(row, category=slice_id), handle, ensure_ascii=False)

            # M10: of several correct records, did Isla pick the best?
            if variant in ("canonical", "apple") and j["verdict"] == "correct" and len(j["fit_ids"]) >= 2 \
                    and j["chosen_info"] is not None:
                fit_key = tuple(sorted(j["fit_ids"]))
                if fit_key not in consensus_cache:
                    consensus_cache[fit_key] = analysis.consensus_deviation(
                        {rid: analysis.sung(j["everything"][rid]) for rid in fit_key})
                    if len(consensus_cache) > 4:
                        consensus_cache.pop(next(iter(consensus_cache)))
                info = j["infos"]
                selection.add_case(
                    variant,
                    {"id": lookup["chosen_id"], "duration": info[lookup["chosen_id"]]["duration"],
                     "word_timing": info[lookup["chosen_id"]]["word_timing"]},
                    [{"id": rid, "duration": info[rid]["duration"], "word_timing": info[rid]["word_timing"]}
                     for rid in fit_key],
                    float(identity.get("duration") or 0), consensus_cache[fit_key])

            if j["verdict"] in DIAGNOSE:
                entry = {
                    "track_id": tid, "variant": variant, "verdict": j["verdict"],
                    "identity": {"player_id": identity.get("player_id"), "title": identity.get("title"),
                                 "artist": identity.get("artist"), "album": identity.get("album"),
                                 "duration": identity.get("duration")},
                    "request_keys": [r["key"] for r in lookup.get("requests") or [] if r.get("key")],
                    "fit_ids": j["near_ids"] if j["verdict"] == "miss-tolerance" else j["fit_ids"],
                    "chosen_id": lookup.get("chosen_id"),
                    "cluster_ids": j["cluster_ids"],
                }
                if j["verdict"] == "miss-unqueried":
                    entry["found_by"] = {str(rid): truth.candidates.get(rid, {}).get("source_queries", [])
                                         for rid in j["fit_ids"]}
                diagnose.append(entry)

        # M2 needs the cluster as the canonical lookup saw it.
        clusters[tid] = canonical_judged[1]["members"] if canonical_judged else set(truth.cluster)

        # M9: independent synced records of one song, within 3 s of Apple's length.
        target = (track.get("apple") or {}).get("duration") or \
            ((track.get("truth") or {}).get("per_variant", {}).get("canonical") or {}).get("duration") or 0
        if target:
            source = canonical_judged[1] if canonical_judged else None
            infos = source["infos"] if source else {rid: truth.info(rid, row) for rid, row in truth.pool.items()}
            everything = source["everything"] if source else truth.pool
            ids = [rid for rid in (source["members"] if source else truth.cluster)
                   if rid in infos and infos[rid]["has_synced"] and rid not in truth.alt
                   and abs(infos[rid]["duration"] - target) <= FIT_S]
            if len(ids) >= 2:
                noise.add_track(slice_id, {rid: analysis.sung(everything[rid]) for rid in ids},
                                canonical_judged[0].get("chosen_id") if canonical_judged else None)

    # ---- sections ----
    canonical = [r for r in results if r["variant"] == "canonical"]
    m1_counts = counts(results)
    canon_counts = counts(canonical)
    if not results:
        m1 = section("info", "no lookups: results/isla-lookups.jsonl is absent or empty")
    else:
        acc, wr, rec = canon_counts["accuracy"], canon_counts["wrong_rate"], canon_counts["recoverable_of_usable"]
        if acc is None:
            verdict = "info"
        elif acc < 0.75 or (wr or 0) > 0.05:
            verdict = "fail"
        elif acc >= 0.90 and (wr or 0) <= 0.02 and (rec or 0) <= 0.02:
            verdict = "pass"
        else:
            verdict = "concern"
        slice_cut = cut(canonical, lambda r: r["slice"])
        worst = min(((k, v["accuracy"]) for k, v in slice_cut.items() if v["accuracy"] is not None),
                    key=lambda kv: kv[1], default=None)
        m1 = section(
            verdict,
            f"{len(results)} lookups ({len(canonical)} canonical). Canonical accuracy "
            f"{_pct(acc)} of {canon_counts['usable']} usable, wrong rate {_pct(wr)} of {canon_counts['shown']} shown, "
            f"recoverable misses {canon_counts['recoverable_misses']} ({_pct(rec)} of usable)"
            + (f"; weakest slice {worst[0]} at {_pct(worst[1])}." if worst else "."),
            overall=m1_counts, canonical=canon_counts,
            by_slice=cut(results, lambda r: r["slice"]),
            by_variant=cut(results, lambda r: r["variant"]),
            by_slice_variant=cut(results, lambda r: f"{r['slice']} | {r['variant']}"),
            by_pick=cut(results, lambda r: r["pick"]),
            by_tag=cut(results, lambda r: r["tags"] or ["(none)"]),
            by_script_family=cut(results, lambda r: r["script_family"]),
            unjudged=[{"track_id": r["track_id"], "variant": r["variant"], "chosen_id": r["chosen_id"]}
                      for r in results if r["verdict"] == "unjudged"][:200],
            flag_counts=_flag_counts(results),
            thresholds=THRESHOLDS["M1"],
        )

    coverage_total = {k: sum(c[k] for c in coverage.values()) for k in
                      ("tracks", "tracks_with_word_timed_record_in_cluster",
                       "tracks_canonical_chosen_word_timed", "canonical_found")}
    estimation = estimation_section(root, analysis.EstimationStudy())
    best = estimation.get("e4_best_cap")
    overall = estimation.get("overall_excluding_estimator_made") or estimation.get("overall_all_records") or {}
    m3_summary = (
        f"{estimation['records']} word-timed records ({estimation['lines']} lines, {estimation['words_scored']} words scored); "
        f"{coverage_total['tracks_with_word_timed_record_in_cluster']} of {coverage_total['tracks']} tracks have one in the cluster, "
        f"{coverage_total['tracks_canonical_chosen_word_timed']} canonical picks are word-timed."
        + (f" Median start error E0 {_ms(overall.get('E0'))}, E1 {_ms(overall.get('E1'))}, E2 {_ms(overall.get('E2'))}, "
           f"E3 {_ms(overall.get('E3'))}, E4 (cap {best}) {_ms(overall.get('E4'))}." if overall else ""))
    m3 = section("info", m3_summary, estimation=estimation, coverage_by_slice=dict(sorted(coverage.items())),
                 coverage_total=coverage_total)

    noise_result = noise.result()
    allcell = noise_result.get("all")
    m9 = section("info", (
        f"{allcell['pairs']} record pairs on {allcell['tracks_with_pairs']} tracks: median |offset| "
        f"{allcell['abs_offset_s']['p50']} s, {_pct(allcell['share_offset_over_0.3s'])} over 0.3 s, "
        f"{_pct(allcell['share_offset_over_1s'])} over 1 s; residual p50 {allcell['residual_s']['p50']} s, p90 {allcell['residual_s']['p90']} s."
        if allcell else "no track has two independent synced records to compare"), by_slice=noise_result)

    sel = selection.result()
    sel_all = sel.get("all")
    m10 = section("info", (
        f"{sel_all['cases']} correct lookups with 2+ fit records: Isla picked the closest length in "
        f"{_pct(sel_all['picked_closest_length'])}, a word-timed record in {_pct(sel_all['picked_word_timed_when_available'])} "
        f"of {sel_all['word_timed_available_cases']} cases where one existed, the consensus-closest in "
        f"{_pct(sel_all['picked_closest_to_consensus'])} of {sel_all['consensus_cases']}."
        if sel_all else "no correct lookup had two fit records"), by_variant=sel)

    report = {
        "meta": {
            "root": root, "tracks": len(tracks), "lookups": len(lookups), "perturbation_rows": len(perturbations),
            "matched_records": len(matched_ids), "diagnose_rows": len(diagnose),
            "inputs": {name: os.path.exists(os.path.join(root, *name.split("/"))) for name in (
                "resolved/tracks.jsonl", "results/isla-lookups.jsonl", "results/perturbations.jsonl",
                "results/word-fidelity.json", "results/readability.json")},
            "thresholds": THRESHOLDS,
            "verdict_values": "pass | concern | fail | info",
        },
        "M1": m1,
        "M2": perturbation_section(perturbations, clusters),
        "M3": m3,
        "M3a": verbatim(os.path.join(root, "results", "word-fidelity.json"), "M3a word fidelity"),
        "M4": verbatim(os.path.join(root, "results", "readability.json"), "M4 readability"),
        "M5": section("info", f"{len(matched_ids)} chosen records written under matched/ for the 2026-10-11 lab's rerun.",
                      records=len(matched_ids),
                      by_slice=_count(os.path.join(matched_root, d) for d in os.listdir(matched_root))
                      if os.path.isdir(matched_root) else {}),
        "M6": variant_section(results),
        "M9": m9,
        "M10": m10,
    }

    reports = os.path.join(root, "reports")
    os.makedirs(reports, exist_ok=True)
    write_json(os.path.join(reports, "match-lab-report.json"), report)
    write_csv(os.path.join(reports, "rows.csv"), results)
    with open(os.path.join(reports, "diagnose-input.jsonl"), "w", encoding="utf-8") as handle:
        for entry in diagnose:
            handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
    for name in ("M1", "M2", "M3", "M6", "M9", "M10"):
        print(f"MATCH-LAB {name} verdict={report[name]['verdict']} - {report[name]['summary']}", flush=True)
    return report


def _count(paths) -> dict:
    return {os.path.basename(p): len([f for f in os.listdir(p) if f.endswith(".json")]) for p in paths
            if os.path.isdir(p)}


def _flag_counts(results: List[dict]) -> dict:
    out: Dict[str, int] = {}
    for r in results:
        for flag in r["flags"]:
            out[flag] = out.get(flag, 0) + 1
    return dict(sorted(out.items()))


def _pct(value) -> str:
    return "n/a" if value is None else f"{round(value * 100, 1)}%"


def _ms(cell) -> str:
    return "n/a" if not cell or cell.get("p50") is None else f"{round(cell['p50'] * 1000)} ms"


def write_json(path: str, data) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(_clean(data), handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)


def _clean(value):
    """JSON has no NaN or infinity, and sets become sorted lists."""
    if isinstance(value, float):
        return None if value != value or value in (float("inf"), float("-inf")) else value
    if isinstance(value, dict):
        return {str(k): _clean(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_clean(v) for v in value]
    if isinstance(value, set):
        return sorted(_clean(v) for v in value)
    return value


def write_csv(path: str, results: List[dict]) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(CSV_COLUMNS)
        for r in results:
            row = []
            for column in CSV_COLUMNS:
                value = r.get(column)
                if isinstance(value, list):
                    value = ";".join(str(v) for v in value)
                elif isinstance(value, bool):
                    value = "true" if value else "false"
                elif value is None:
                    value = ""
                row.append(value)
            writer.writerow(row)
    os.replace(tmp, path)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Classify Isla's lookups against the oracle's truth.")
    parser.add_argument("--root", default=DEFAULT_ROOT)
    args = parser.parse_args(argv)
    run(args.root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
