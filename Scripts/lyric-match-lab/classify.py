#!/usr/bin/env python3
"""Classify what Isla did against the oracle's truth: the lab's report (phase 2).

    python3 classify.py --root <root> [--results <dir>] [--reports <dir>] [--no-calibration]

Joins `<results>/isla-lookups.jsonl` (written by the Swift harness) with
`resolved/tracks.jsonl` (written by resolve.py) and gives every lookup one
verdict (SPEC "Classification", made exact in the rules below). Offline: it
reads the two replay caches and never opens a socket.

Reads   resolved/{tracks,variants}.jsonl  <results>/{isla-lookups,perturbations}.jsonl
        <results>/{word-fidelity,readability}.json  wordtimed/<slice>/<id>.json
        cache/py/ and cache/isla/ (LRCLIB rows, by URL and by the Swift run's keys)
        reports/oracle-calibration.json (optional; see oracle.load_calibration)
Writes  <reports>/match-lab-report.json   every section, numbers only
        <reports>/rows.csv                one row per lookup with its verdict
        <reports>/diagnose-input.jsonl    the lookups a Swift case re-examines
        matched/<slice>/<id>.json         the records Isla chose, in the 2026-10-11
                                          lab's corpus format, for M5

`--results` and `--reports` (default `results` and `reports`) name directories
under the root. They let a candidate change to Isla be scored beside the
baseline over the same cache. `--pool-results DIR` (repeatable) names more
results directories whose responses join the known pool of each track (see
"Same-song and fit records" below), so a baseline and a candidate are judged
against one pool: Scripts/lyric-match-lab/score-candidate.sh passes each run
the other's directory. `matched/` is the M5 corpus of the baseline: it
is written only when `--reports` is the default `reports`, so an experiment
never overwrites it.

Nothing written under the reports directory carries a lyric line. matched/ and
wordtimed/ do, and stay under the corpus root.

Verdicts (M1)
  correct              chosen record is in the same-song cluster; not timed for a longer cut
  correct-longer-cut   same song, but Isla itself says it is timed for a longer version
  alt-script           same song in another script, or a translation
  wrong-song           containment <= WRONG with the cluster; or any lyric for an expected
                       instrumental (flag instrumental-fp; catalogue-mislabel if the record
                       is a title-and-artist match)
  uncertain            containment between WRONG and SAME
  unrecovered          Isla showed lyrics but the harness could not say which record
                       (excluded from usable, like failed)
  unjudged             lyrics shown for a track with no anchor record (listed, not scored)
  miss-rejected        nothing shown, a fit record that also matches the track's title and
                       artist was in Isla's own responses; also (flag overrun-only) when the
                       only such record is an overrun-fit that Isla would have shown
                       flagged as timed for a longer cut
  miss-unqueried       nothing shown, such a fit record exists but no query of Isla's
                       returned it (flag overrun-only: it is an overrun-fit)
  miss-text-only       nothing shown, a record of the same lyrics fits the length but its
                       title or artist differs (a karaoke upload under another artist);
                       reported, not recoverable, not usable
  miss-tolerance       nothing shown, only near records (3-10 s off) exist
  miss-plain-only      nothing shown, the cluster has plain lyrics only
  miss-catalogue       nothing shown, nothing usable exists
  correct-none         an expected instrumental, nothing shown
  failed-request       Isla's request drew a 4xx other than 403, 404 and 429 (a deterministic
                       refusal of Isla's own request): an Isla outcome, a miss in usable
                       when a fit exists
  truth-uncertain      the track's anchors contradict each other (anchor-conflict): excluded
  truth-incomplete     no anchor and an LRCLIB query went unanswered: excluded
  disputed             the harvest and LRCLIB disagree about instrumental (either way): excluded;
                       anchors that disagree among themselves are scored, as a cut (third review, M2)
  unreadable           taken as the harness reported it
  failed / uncached    no answer could be obtained (an environment failure): excluded

The last three of those (truth-uncertain, truth-incomplete, disputed) are
track-level: every lookup of the track that reached an answer gets the verdict,
and none of them is in the accuracy or wrong-rate denominators. They are counted
separately under `excluded_from_scoring`.

"Same-song" and "fit" records are the union of the resolver's pool and the
known pool of the track: the records in the responses to every lookup of that
track in the results being classified and in each `--pool-results` directory
(third review, M1). What Isla saw is still this lookup's own responses, which
keeps `miss-rejected` (the fit was in them) apart from `miss-unqueried` (it was
not, though a sibling lookup found it). A response record joins the
cluster when its containment against the group anchors is at least SAME (per
script family, oracle.thresholds). "Fit" is judged against the lookup's own
variant duration: within 3 s, last sung stamp no later than duration + 3. A
track the resolver found no anchor for is anchored here from Isla's own
responses: any record in any of its lookups' answers that matches the title and
artist and has lyric text.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import shutil
import statistics
import sys
from typing import Dict, List, Optional, Sequence

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import analysis  # noqa: E402
import common  # noqa: E402
import oracle  # noqa: E402
import resolve  # noqa: E402

DEFAULT_ROOT = resolve.DEFAULT_ROOT

SAME, WRONG = oracle.DEFAULT_THRESHOLDS   # per-family values: oracle.thresholds(family)
FIT_S = 3.0
NEAR_S = 10.0

SHOWN = ("correct", "correct-longer-cut", "alt-script", "wrong-song", "uncertain")
WRONG_RATE_VERDICTS = ("wrong-song", "correct-longer-cut", "uncertain")
RECOVERABLE = ("miss-rejected", "miss-unqueried")
# Verdicts about the truth, not about Isla: never in a denominator.
EXCLUDED_TRUTH = ("truth-uncertain", "truth-incomplete", "disputed")
# `instrumental_disagreement` values (resolve.truth_for) that make a track disputed.
# `mixed-anchor-flags` is not among them (third review, M2): one stray
# instrumental flag among records with lyrics is a mislabelled record, not a
# verdict on the song, and the resolver's `expected` is False on such a track.
# Isla's early exit on it (an instrumental /api/get is an answer, so it never
# searches) is a real failure the lab has to surface; it is a cut, not an
# exclusion.
DISPUTES = ("harvest-none-lrclib-lyrics", "harvest-vocal-lrclib-instrumental")
MIXED_FLAG = "mixed-anchor-flags"
# Verdicts for which nothing can be said of Isla at all.
NO_JUDGEMENT = ("failed", "uncached", "unrecovered")
# HTTP statuses that are LRCLIB's ordinary answer, a rate limit, or a gateway
# refusing the lab's client (403: neither side caches it, and the harness reads
# it as a miss, so it normally never appears), not a refusal of Isla's request.
BENIGN_STATUSES = (403, 404, 429)
DIAGNOSE = ("miss-rejected", "miss-unqueried", "miss-tolerance", "wrong-song", "uncertain",
            "correct-longer-cut", "alt-script", "unrecovered")
MATCHED_VERDICTS = ("correct", "correct-longer-cut", "alt-script")
DEFAULT_RESULTS = "results"
DEFAULT_REPORTS = "reports"

# Section verdict thresholds, stated here so the report can print them.
THRESHOLDS = {
    "M1": {"pass": "canonical accuracy >= 0.90, wrong rate <= 0.02, recoverable misses <= 0.02 of usable, "
                   "no lookup that might have been usable left uncached, unrecovered or failed, and no "
                   "unanswered LRCLIB query on an anchored, scored track",
           "fail": "canonical accuracy < 0.75 or wrong rate > 0.05",
           "incomplete": "the result would be a pass but a lookup is uncached or unrecovered, or an anchored "
                         "track had an LRCLIB query go unanswered: the missing answers could move it, so M1 "
                         "reports accuracy bounds [lower, upper] instead"},
    "M2": {"pass": "no switched-wrong and lost <= 0.02 of the rows whose base pick is in the song (cluster "
                   "or alt-script), switched-alt <= 0.02 of the rows whose base pick is in the cluster itself "
                   "(duration edges excluded); wrong-to-wrong and found-alt are reported and are in no "
                   "threshold",
           "fail": "switched-wrong > 0.01 of applicable rows (rows where both base and pick are null "
                   "are not applicable)"},
    "M6": {"pass": "no variant loses more than 0.05 of the tracks canonical gets right, over the lookups "
                   "usable on both sides (failed, uncached and unrecovered variant lookups are in neither "
                   "count; promoted tracks are tallied apart)",
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
        self.notes = list(self.truth.get("notes") or [])
        self.status = self.truth.get("truth_status")
        # A tracks.jsonl written before the resolver knew `truth-uncertain`
        # says "ok" beside an anchor-conflict note; read it the same way.
        if self.status == "ok" and "anchor-conflict" in self.notes:
            self.status = "truth-uncertain"
        self.promoted = False
        self.pool = pool_rows(root, track)
        # What the resolver's own queries returned. `pool` grows when a track is
        # promoted, and M1's `fit_outside_resolver_pool` needs the original.
        self.resolver_pool_ids = set(self.pool)
        self.infos: Dict[int, dict] = {}
        self.cluster = set(self.truth.get("cluster_ids") or [])
        self.alt = set(self.truth.get("alt_script_ids") or [])
        self.candidates = {c["id"]: c for c in track.get("candidates") or []}
        self.titles = resolve.identity_titles(self.harvest, track.get("apple"), track.get("deezer"),
                                              track.get("apple_us"))
        self.artists = resolve.identity_artists(self.harvest, track.get("apple"), track.get("deezer"),
                                                track.get("apple_us"))
        anchors = [c for c in self.candidates.values() if c.get("anchor")]
        self.anchored = bool(anchors)
        self.unanswered = any(str(n).startswith("lrclib-unanswered") for n in self.notes)
        # The resolver's /api/get is Isla's own canonical query, so a record
        # only that query returned can be the one anchor and make Isla's
        # canonical pick correct by construction (second review, finding 11).
        # Only the group's anchors count: a romaji anchor from a search must not
        # hide that the group's only anchor came from /api/get (third review, m5).
        group_anchors = [c for c in anchors if c["id"] in self.cluster and c["id"] not in self.alt]
        self.sole_anchor_from_get = bool(group_anchors) and all(
            c.get("source_queries") == ["get"] for c in group_anchors)
        self.anchor_fps: Dict[int, frozenset] = {}
        self.group_family = ""
        self.same, self.wrong = oracle.thresholds("")
        anchor_infos: Dict[int, dict] = {}
        # Only the group's anchors, as `promote()` keeps only `result["anchor_ids"]`
        # (third review, B1). An alt-script anchor used to stay in, re-shingled
        # in the group's family, so a second romaji upload that only Isla's
        # answer held matched it, joined the members and scored `correct`.
        for cid, cand in self.candidates.items():
            if cand.get("anchor") and cid in self.pool and cid in self.cluster and cid not in self.alt:
                info = self.info(cid, self.pool[cid])
                if info["fp"] and not info["instrumental"]:
                    anchor_infos[cid] = info
        # The family the oracle's cluster chose, not the first anchor's own
        # dominant script: an anchor moved into the expected script keeps a
        # different dominant one, and the thresholds and the alt-script test
        # belong to the group (second review, finding 8). A tracks.jsonl from
        # before the resolver wrote it is clustered again over its anchors.
        family = self.truth.get("group_family") or ""
        if not family and anchor_infos:
            family = self._cluster_family(anchor_infos)
        self._set_family(family)
        self.anchor_fps = {cid: self.group_fp(info) for cid, info in anchor_infos.items()}

    def _cluster_family(self, anchor_infos: Dict[int, dict]) -> str:
        pool = [{"id": rid, "fp": i["fp"], "text": i["text"], "script": i["script"],
                 "script_weights": i["script_weights"], "instrumental": False}
                for rid, i in anchor_infos.items()]
        prefer = oracle.expected_script(self.harvest.get("language") or "", self.harvest.get("title") or "")
        return oracle.cluster(pool, list(anchor_infos), prefer_script=prefer)["group_family"]

    def _set_family(self, family: str) -> None:
        self.group_family = family or ""
        self.same, self.wrong = oracle.thresholds(self.group_family)

    def foreign_script(self, info: dict) -> bool:
        """True when the record is written in another script than the group's,
        by the oracle's own rule: fewer than EXPECTED_SCRIPT_SHARE of its
        weighted letters in the group's family (third review, B1 and m12)."""
        return bool(self.group_family and info["fp"]
                    and oracle.family_share(info["script_weights"], self.group_family) < oracle.EXPECTED_SCRIPT_SHARE)

    def is_alt_script(self, rid: int, info: dict) -> bool:
        """The song in another script than the group's: one of the oracle's alt
        anchors, or any record matching the track's identity that is written in
        another script. M1's verdict and M2's alt set both ask this, so they
        cannot disagree about a romaji copy Isla's own queries returned (fourth
        review, N1)."""
        return rid in self.alt or bool(info["identity"] and self.foreign_script(info))

    def group_fp(self, info: dict) -> frozenset:
        """The record's fingerprint in the group's family, so that it and the
        anchors are shingled alike however each one's own script reads."""
        if not info["fp"] or not self.group_family:
            return info["fp"]
        cache = info.setdefault("_fp_by_family", {})
        if self.group_family not in cache:
            cache[self.group_family] = oracle.fingerprint(info["text"], family=self.group_family)
        return cache[self.group_family]

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
        mine = self.group_fp(info)
        return round(max(oracle.containment(mine, fp) for fp in others), 3)

    def promote(self, isla_rows_of_track: Dict[int, dict]) -> bool:
        """Anchor a track the resolver found no anchor for, from Isla's answers.

        The resolver's pool comes from its own queries; Isla's queries differ
        (a different album, a different artist string) and can return the one
        record the resolver never saw. Any such record that matches the
        track's title and artist and has lyric text becomes an anchor, and the
        cluster is built as usual (adversarial review F7). Without this a
        shown lyric was `unjudged` and a miss was `miss-catalogue` while the
        record was sitting in Isla's own responses.
        """
        if self.status != "no-anchor" or not isla_rows_of_track:
            return False
        # An unanswered query means the catalogue cannot be called empty or
        # known: the track stays truth-incomplete however a record in Isla's
        # answers looks (second review, finding 2a).
        if any(str(n).startswith("lrclib-unanswered") for n in self.notes):
            return False
        everything = dict(self.pool)
        for rid, row in isla_rows_of_track.items():
            everything.setdefault(rid, row)
        infos = {rid: self.info(rid, row) for rid, row in everything.items()}
        anchors = [rid for rid in isla_rows_of_track
                   if infos[rid]["identity"] and infos[rid]["fp"] and not infos[rid]["instrumental"]]
        if not anchors:
            return False
        pool = [{"id": rid, "fp": frozenset() if i["instrumental"] else i["fp"], "script": i["script"],
                 "script_weights": i["script_weights"], "instrumental": i["instrumental"], "text": i["text"]}
                for rid, i in infos.items()]
        prefer = oracle.expected_script(self.harvest.get("language") or "", self.harvest.get("title") or "")
        result = oracle.cluster(pool, anchors, prefer_script=prefer)
        if result["truth_status"] != "ok":
            return False
        self.pool = everything
        self.cluster = set(result["cluster_ids"])
        self.alt = set(result["alt_script_ids"])
        self._set_family(result["group_family"])
        self.anchor_fps = {aid: self.group_fp(infos[aid]) for aid in result["anchor_ids"]
                           if aid in infos and infos[aid]["fp"]}
        self.status = "truth-uncertain" if "anchor-conflict" in result["notes"] else "ok"
        self.promoted = True
        return True

    def exclusion(self) -> Optional[str]:
        """The track-level verdict that takes the track out of scoring, if any.

        disputed: the harvest and LRCLIB disagree about whether the song has
        words (the harvest says instrumental and LRCLIB holds lyrics, or the
        harvest says vocal and LRCLIB's anchors are all instrumental), so
        neither side can be called the truth (second review, finding 4).
        Anchors that disagree among themselves about the flag are not
        disputed (third review, M2; see DISPUTES). truth-uncertain: the anchors
        contradict each other. truth-incomplete: no anchor, and an LRCLIB query
        went unanswered, so the catalogue cannot be called empty.
        """
        if self.truth.get("instrumental_disagreement") in DISPUTES:
            return "disputed"
        if self.status == "truth-uncertain":
            return "truth-uncertain"
        if self.status == "no-anchor" and any(str(n).startswith("lrclib-unanswered") for n in self.notes):
            return "truth-incomplete"
        return None


def judge(truth: Truth, lookup: dict, rows: Dict[int, dict], known: Optional[Dict[int, dict]] = None) -> dict:
    """The verdict of one lookup and the evidence behind it. See the module
    docstring for the rules; `rows` are the records in this lookup's own
    responses (what Isla saw) and `known` is the records in the responses to
    every lookup of the track that was classified or named by --pool-results
    (what the truth may use). `known` defaults to `rows`."""
    t = truth.truth
    variant = lookup["variant"]
    duration = float((lookup.get("identity") or {}).get("duration") or 0)
    outcome = lookup.get("outcome")
    flags: List[str] = []

    known = dict(rows) if known is None else known
    everything = dict(truth.pool)
    for source in (known, rows):
        for rid, row in source.items():
            everything.setdefault(rid, row)
    infos = {rid: truth.info(rid, row) for rid, row in everything.items()}

    members = set(truth.cluster)
    for rid in list(known) + [r for r in rows if r not in known]:
        info = infos[rid]
        if rid in members or rid in truth.alt or not info["fp"] or info["instrumental"]:
            continue
        # A record in another script is the alt-script outcome, never the song
        # itself: the oracle's group holds no romaji copy, so a second one that
        # only Isla's answer held must not join it (third review, B1).
        if truth.foreign_script(info):
            continue
        score = truth.containment(rid, info)
        if score is not None and score >= truth.same:
            members.add(rid)

    synced = [rid for rid in members if infos[rid]["has_synced"] and rid not in truth.alt]
    fit, near, overrun_fit = [], [], []
    if duration <= 0:
        fit = [(0.0, rid) for rid in synced]
        flags.append("no-duration")
    else:
        for rid in synced:
            info = infos[rid]
            delta = round(abs(info["duration"] - duration), 3)
            last = info["last_stamp"]
            if delta <= FIT_S and last is not None and last <= duration + FIT_S:
                fit.append((delta, rid))
            elif FIT_S < delta <= NEAR_S:
                near.append((delta, rid))
            # A right-length record stamped more than 3 s past the end: Isla
            # still shows it, flagged as timed for a longer cut (F13).
            if delta <= FIT_S and last is not None and last > duration + FIT_S and info["identity"]:
                overrun_fit.append((delta, rid))
    fit_ids = [rid for _, rid in sorted(fit)]
    near_ids = [rid for _, rid in sorted(near)]
    overrun_ids = [rid for _, rid in sorted(overrun_fit)]
    # Recoverable means a record Isla's matcher could accept: its title and
    # artist must also match. A fit by content alone (a karaoke upload under
    # another artist) is `miss-text-only` (F3).
    fit_identity_ids = [rid for rid in fit_ids if infos[rid]["identity"]]
    saw_fit = bool(set(fit_identity_ids) & set(rows))
    saw_overrun = bool(set(overrun_ids) & set(rows))
    plain_only = bool(members) and not any(infos[r]["has_synced"] for r in members) \
        and any(infos[r]["has_plain"] for r in members)

    chosen_id = lookup.get("chosen_id")
    status = truth.status
    expected_instrumental = bool(t.get("instrumental_expected"))
    containment: Optional[float] = None
    verdict: str

    if lookup.get("chosen_ambiguous"):
        flags.append("ambiguous-recovery")
    if truth.promoted:
        flags.append(PROMOTED_FLAG)
    if truth.sole_anchor_from_get:
        flags.append(SOLE_GET_FLAG)
    if t.get("instrumental_disagreement") == MIXED_FLAG:
        flags.append(MIXED_FLAG)

    if outcome in ("unreadable", "uncached"):
        verdict = outcome
    elif outcome == "failed":
        refused = sorted({r["status"] for r in lookup.get("requests") or []
                          if isinstance(r.get("status"), int) and 400 <= r["status"] < 500
                          and r["status"] not in BENIGN_STATUSES})
        if refused:
            verdict = "failed-request"
            flags.append(f"http-{refused[0]}")
        else:
            verdict = "failed"
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
            elif truth.is_alt_script(chosen_id, chosen):
                same = None
            elif containment is not None and containment >= truth.same:
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
            elif containment is not None and containment > truth.wrong:
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
        elif fit_identity_ids:
            verdict = "miss-rejected" if saw_fit else "miss-unqueried"
        elif overrun_ids:
            verdict = "miss-rejected" if saw_overrun else "miss-unqueried"
            flags.append("overrun-only")
        elif fit_ids:
            verdict = "miss-text-only"
        elif near_ids:
            verdict = "miss-tolerance"
        elif plain_only:
            verdict = "miss-plain-only"
        else:
            verdict = "miss-catalogue"
            if synced:
                flags.append("synced-off-length")
            if any(str(n).startswith("lrclib-unanswered") for n in truth.notes):
                flags.append("lrclib-unanswered")

    exclusion = truth.exclusion()
    if exclusion and (outcome in ("found", "none") or verdict == "failed-request"):
        flags.append(f"was-{verdict}")
        verdict = exclusion

    judged_usable = verdict not in NO_JUDGEMENT and verdict not in EXCLUDED_TRUTH
    # Whether a right answer was within Isla's reach is a fact about the
    # catalogue and the variant's length, decided before Isla's outcome is
    # looked at (second review, finding 3). It used to let a `correct` verdict
    # stand without any fit while every other outcome needed one, so the
    # denominator grew with Isla's own successes.
    truth_usable = (not expected_instrumental and status not in ("no-anchor", "truth-uncertain")
                    and (bool(fit_identity_ids) or bool(overrun_ids)))
    # A lookup that gave no answer, or none the harness could attribute, might
    # have been usable: it bounds the accuracy (counts()). Tracks the truth
    # never scores, and expected instrumentals, can not have been. Third review:
    # a plain `failed` lookup is one too (m2); an unrecovered lookup has its
    # responses on disk, so the truth says whether it could have been usable
    # (m1); and an uncached or failed one on a track with no anchor that was not
    # promoted could not have been, because any answer that made it usable would
    # have promoted the track, which takes it out of M1 (m1).
    maybe_usable = (verdict in ("uncached", "unrecovered", "failed") and not expected_instrumental
                    and exclusion is None and status != "truth-uncertain")
    if verdict == "unrecovered":
        maybe_usable = maybe_usable and truth_usable
    elif verdict in ("uncached", "failed"):
        maybe_usable = maybe_usable and status != "no-anchor"
    usable = truth_usable and judged_usable
    # Whether the only record that makes the lookup usable came from a response
    # and not from the resolver's pool, which M1 reports as a cut (third review).
    # A promoted track has no resolver pool to speak of and is tallied apart.
    fit_basis = set(fit_identity_ids) or set(overrun_ids)
    if usable and not truth.promoted and fit_basis and not (fit_basis & truth.resolver_pool_ids):
        flags.append(FIT_OUTSIDE_FLAG)
    return {
        "verdict": verdict, "flags": flags, "containment": containment,
        "fit_ids": fit_ids, "fit_identity_ids": fit_identity_ids, "near_ids": near_ids,
        "overrun_ids": overrun_ids,
        "isla_saw_fit": saw_fit or (saw_overrun and verdict in RECOVERABLE),
        "cluster_ids": sorted(members), "alt_n": len(truth.alt),
        "chosen_info": infos.get(chosen_id) if chosen_id is not None else None,
        "infos": infos, "everything": everything, "members": members,
        # Usable: the truth holds an identity-matching fit record for the
        # variant's length (or an identity-matching overrun-fit Isla would have
        # shown flagged), and the lookup reached an answer on a track whose
        # truth is not in doubt. A `correct` verdict without such a record is
        # not usable; counts() reports it as `correct_without_fit`.
        "usable": usable,
        "maybe_usable": maybe_usable,
    }


# --------------------------------------------------------------------------
# Counting
# --------------------------------------------------------------------------

PROMOTED_FLAG = "anchor-promoted"
SOLE_GET_FLAG = "sole-anchor-from-get"
FIT_OUTSIDE_FLAG = "fit-outside-resolver-pool"


def counts(rows: List[dict], keep_promoted: bool = False) -> dict:
    """Headline figures (SPEC "Classification") for a set of lookup results.

    Lookups of a track the classifier anchored itself from Isla's responses
    (flag `anchor-promoted`) are counted apart, under `excluded_from_scoring`,
    and are in no other figure: promotion rescued only tracks where Isla's own
    responses held the record, so on those Isla could only be right or reject
    what it saw, never fail to ask, and accuracy over them is inflated one way
    (second review, finding 2). `keep_promoted` counts them, for the separate
    `anchor_promoted` entry.
    """
    promoted = [r for r in rows if PROMOTED_FLAG in r["flags"]]
    scored = rows if keep_promoted else [r for r in rows if PROMOTED_FLAG not in r["flags"]]
    verdicts: Dict[str, int] = {}
    for r in scored:
        verdicts[r["verdict"]] = verdicts.get(r["verdict"], 0) + 1
    usable = [r for r in scored if r["usable"]]
    correct = sum(1 for r in usable if r["verdict"] == "correct")
    shown = sum(verdicts.get(v, 0) for v in SHOWN)
    wrong = sum(verdicts.get(v, 0) for v in WRONG_RATE_VERDICTS)
    recoverable = sum(verdicts.get(v, 0) for v in RECOVERABLE)
    uncached = verdicts.get("uncached", 0)
    unrecovered = verdicts.get("unrecovered", 0)
    # Lookups that gave no answer, or none the harness could attribute, and
    # might have been usable: the accuracy lies between counting every one as
    # a usable miss and counting none of them.
    unscorable = sum(1 for r in scored if r.get("maybe_usable"))
    # The wrong rate is over lyrics shown, and an unrecovered lookup showed
    # lyrics nobody could attribute: it lies between counting none of them
    # wrong and every one (third review, m7). Only on a scorable track: on a
    # no-anchor one a recovered pick is `unjudged` and in no `shown`, so an
    # unrecovered row there cannot be a wrong pick that is missing from it
    # (fourth review, N7).
    unrecovered_n = sum(1 for r in scored
                        if r["verdict"] == "unrecovered" and r.get("truth_status") != "no-anchor")
    excluded = {v: verdicts[v] for v in EXCLUDED_TRUTH if verdicts.get(v)}
    if promoted and not keep_promoted:
        excluded["anchor-promoted"] = len(promoted)
    return {
        "lookups": len(rows),
        "usable": len(usable),
        "correct": correct,
        "accuracy": analysis.share(correct, len(usable)),
        "uncached": uncached,
        "unrecovered": unrecovered,
        "unscorable_possibly_usable": unscorable,
        # A `correct` verdict on a lookup with no identity-matching fit record
        # is not usable (the denominator is decided from the truth alone); it
        # is counted here so it is not lost.
        "correct_without_fit": sum(1 for r in scored if r["verdict"] == "correct" and not r["usable"]),
        "accuracy_bounds": {
            "lower": analysis.share(correct, len(usable) + unscorable),
            "upper": analysis.share(correct + unscorable, len(usable) + unscorable),
            "as_computed": analysis.share(correct, len(usable)),
        },
        "shown": shown,
        "wrong": wrong,
        "wrong_rate": analysis.share(wrong, shown),
        "wrong_rate_bounds": {
            "lower": analysis.share(wrong, shown + unrecovered_n),
            "upper": analysis.share(wrong + unrecovered_n, shown + unrecovered_n),
            "as_computed": analysis.share(wrong, shown),
        },
        # Usable only through a record the resolver's own queries never
        # returned (third review, M1): a measure of how much of the accuracy
        # rests on what Isla's queries found.
        "fit_outside_resolver_pool": sum(1 for r in scored if FIT_OUTSIDE_FLAG in r["flags"]),
        "recoverable_misses": recoverable,
        "recoverable_of_usable": analysis.share(
            sum(1 for r in usable if r["verdict"] in RECOVERABLE), len(usable)),
        "text_only_misses": verdicts.get("miss-text-only", 0),
        "failed_request": verdicts.get("failed-request", 0),
        "excluded_from_scoring": excluded,
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

def perturbation_section(rows: List[dict], clusters: Dict[str, set], alts: Optional[Dict[str, set]] = None) -> dict:
    """M2 buckets. `base` is the pick for the unperturbed identity, `picked`
    the pick for the perturbed one. A pick is "in the song" when it is in the
    cluster or an alt-script record of it; the cluster alone is "in the cluster".

      kept            same pick; or base and pick both in the song (alt-script
                      counts as the song on the base side: nothing is lost in
                      moving between its records)
      lost            base in the song, nothing picked
      switched-ok     base outside the song, pick in the cluster or alt-script (a wrong
                      base replaced by the right song)
      switched-alt    base in the cluster, pick an alt-script record
      switched-wrong  base in the song, pick outside it; or base null and the
                      pick in neither the cluster nor the alt-script records
      wrong-to-wrong  base outside the song, a different pick outside it: the
                      matcher was wrong before and still is, which the
                      perturbation did not cause. Not in the verdict thresholds
      found-new       base null, pick in the cluster (a good outcome)
      found-alt       base null, pick an alt-script record: the song in
                      another script, no worse than found-new and no worse
                      than the wrong-to-switched-ok move. No threshold reads
                      it (third review, M5: `s-latin` produced exactly this
                      and failed the section)
      dropped-wrong   base outside the song, nothing picked (a good outcome)

    A row with both picks null is not applicable. `lost` is divided by the rows
    whose base pick is in the song (the cell key `base_in_cluster` counts them),
    since only those had anything to lose. `switched-alt` is divided by the rows
    whose base pick is in the cluster itself (`base_in_cluster_only`): an
    alt-script base cannot switch to alt, so counting it diluted the 0.02
    threshold (third review, m6).
    """
    buckets = ("kept", "lost", "switched-wrong", "switched-ok", "switched-alt", "found-new", "found-alt",
               "dropped-wrong", "wrong-to-wrong")
    alts = alts or {}
    per: Dict[str, dict] = {}
    both_null = 0
    for r in rows:
        if not r.get("applicable"):
            continue
        cluster = clusters.get(r["track_id"])
        if cluster is None:
            continue
        alt = alts.get(r["track_id"]) or set()
        base, picked = r.get("base_id"), r.get("picked_id")
        if base is None and picked is None:
            both_null += 1
            continue
        base_in_song = base is not None and (base in cluster or base in alt)
        if picked == base:
            outcome = "kept"
        elif base is None:
            outcome = "found-new" if picked in cluster else ("found-alt" if picked in alt else "switched-wrong")
        elif picked is None:
            outcome = "lost" if base_in_song else "dropped-wrong"
        elif picked in cluster:
            outcome = "kept" if base_in_song else "switched-ok"
        elif picked in alt:
            if base in cluster:
                outcome = "switched-alt"
            elif base in alt:
                outcome = "kept"
            else:
                outcome = "switched-ok"      # a wrong base replaced by the right song in another script
        elif base_in_song:
            outcome = "switched-wrong"
        else:
            outcome = "wrong-to-wrong"
        cell = per.setdefault(r["perturbation"], {"applicable": 0, "base_in_cluster": 0, "base_in_cluster_only": 0,
                                                 **{b: 0 for b in buckets},
                                                 "examples": {"lost": [], "switched-wrong": []}})
        cell["applicable"] += 1
        cell["base_in_cluster"] += 1 if base_in_song else 0
        cell["base_in_cluster_only"] += 1 if base is not None and base in cluster else 0
        cell[outcome] += 1
        if outcome in ("lost", "switched-wrong") and len(cell["examples"][outcome]) < 5:
            cell["examples"][outcome].append(r["track_id"])
    for cell in per.values():
        for b in buckets:
            cell[f"{b}_share"] = analysis.share(cell[b], cell["applicable"])
        # The lost share is over rows with something to lose.
        cell["lost_share"] = analysis.share(cell["lost"], cell["base_in_cluster"])
        cell["switched-alt_share_of_base_in_cluster"] = analysis.share(cell["switched-alt"], cell["base_in_cluster"])
        cell["switched-alt_share_of_base_in_cluster_only"] = analysis.share(cell["switched-alt"],
                                                                           cell["base_in_cluster_only"])
    ordinary = [c for k, c in per.items() if not k.startswith("d-")]
    applicable = sum(c["applicable"] for c in ordinary)
    base_in = sum(c["base_in_cluster"] for c in ordinary)
    base_in_only = sum(c["base_in_cluster_only"] for c in ordinary)
    lost = sum(c["lost"] for c in ordinary)
    wrong = sum(c["switched-wrong"] for c in ordinary)
    alt_switch = sum(c["switched-alt"] for c in ordinary)
    total = sum(c["applicable"] for c in per.values())
    if not total:
        return section("info", "no applicable perturbation rows", perturbations={}, both_null_rows=both_null)
    if applicable and wrong / applicable > 0.01:
        verdict = "fail"
    elif wrong or (base_in and lost / base_in > 0.02) or (base_in_only and alt_switch / base_in_only > 0.02):
        verdict = "concern"
    else:
        verdict = "pass"
    worst = max(per.items(), key=lambda kv: (kv[1]["switched-wrong"] + kv[1]["lost"]))
    return section(
        verdict,
        f"{total} applicable perturbations across {len(per)} kinds ({both_null} rows with no pick on either side "
        f"left out); excluding duration edges {lost} lost of {base_in} with a base pick in the cluster, "
        f"{alt_switch} of {base_in_only} switched to another script, and {wrong} switched to a wrong song out of {applicable}; "
        f"worst kind {worst[0]} ({worst[1]['lost']} lost, {worst[1]['switched-wrong']} switched-wrong).",
        perturbations=dict(sorted(per.items())),
        both_null_rows=both_null,
        duration_edges_excluded_from_verdict=sorted(k for k in per if k.startswith("d-")),
        thresholds=THRESHOLDS["M2"],
    )


def variant_section(results: List[dict]) -> dict:
    """M6: the tracks canonical gets right, and what each variant does with them.

    Third review, m8. Only a variant lookup that could have been right counts
    against canonical: both the canonical and the variant lookup must be
    `usable` (a record fits the variant's length and the lookup reached an
    answer). A variant whose length has no fit in the catalogue is reported
    apart, as `non_usable_variant_misses`, and is no loss. Tracks the
    classifier anchored itself are tallied under `anchor_promoted`: on them
    canonical's correctness is partly by construction.
    """
    by_track: Dict[str, Dict[str, dict]] = {}
    for r in results:
        by_track.setdefault(r["track_id"], {})[r["variant"]] = r
    matrix: Dict[str, Dict[str, Dict[str, int]]] = {}
    ordinary = _variant_tally()
    promoted = _variant_tally()
    for tid, variants in by_track.items():
        base = variants.get("canonical")
        if not base:
            continue
        tally = promoted if PROMOTED_FLAG in base["flags"] else ordinary
        right = base["verdict"] == "correct" and base["usable"]
        tally["base_right"] += 1 if right else 0
        for name, r in variants.items():
            if name == "canonical":
                continue
            cell = matrix.setdefault(name, {}).setdefault(base["verdict"], {})
            cell[r["verdict"]] = cell.get(r["verdict"], 0) + 1
            # A variant lookup that got no answer (failed, uncached) or could
            # not be attributed (unrecovered) says nothing about Isla: it is
            # in neither the lost count nor the denominator it is divided by.
            if not right or r["verdict"] in NO_JUDGEMENT:
                continue
            if not r["usable"]:
                if r["verdict"] != "correct":
                    tally["non_usable"][name] = tally["non_usable"].get(name, 0) + 1
                continue
            tally["comparable"][name] = tally["comparable"].get(name, 0) + 1
            if r["verdict"] != "correct":
                entry = tally["lost"].setdefault(name, {"tracks": 0, "by_verdict": {}, "examples": []})
                entry["tracks"] += 1
                entry["by_verdict"][r["verdict"]] = entry["by_verdict"].get(r["verdict"], 0) + 1
                if len(entry["examples"]) < 10:
                    entry["examples"].append(tid)
    for tally in (ordinary, promoted):
        for name, entry in tally["lost"].items():
            entry["of_canonical_correct_with_this_variant"] = tally["comparable"].get(name, 0)
            entry["share"] = analysis.share(entry["tracks"], tally["comparable"].get(name, 0))
    if not matrix:
        return section("info", "no canonical lookups to compare against", transitions={}, lost_by_variant={})
    lost, comparable = ordinary["lost"], ordinary["comparable"]
    worst = max(lost.items(), key=lambda kv: kv[1]["share"] or 0, default=None)
    worst_share = (worst[1]["share"] or 0) if worst else 0
    verdict = "fail" if worst_share >= 0.20 else "concern" if worst_share >= 0.05 else "pass"
    summary = (f"{ordinary['base_right']} tracks where canonical is correct and usable; "
               + (f"the variant that loses most is {worst[0]} ({worst[1]['tracks']} of "
                  f"{worst[1]['of_canonical_correct_with_this_variant']}, {round(worst_share * 100, 1)}%)."
                  if worst else "no variant loses any.")
               + (f" {promoted['base_right']} promoted tracks are tallied apart." if promoted["base_right"] else ""))
    return section(verdict, summary, transitions=matrix, lost_by_variant=dict(sorted(lost.items())),
                   comparable_by_variant=dict(sorted(comparable.items())),
                   non_usable_variant_misses=dict(sorted(ordinary["non_usable"].items())),
                   anchor_promoted={"canonical_correct": promoted["base_right"],
                                    "lost_by_variant": dict(sorted(promoted["lost"].items())),
                                    "comparable_by_variant": dict(sorted(promoted["comparable"].items())),
                                    "non_usable_variant_misses": dict(sorted(promoted["non_usable"].items()))},
                   thresholds=THRESHOLDS["M6"])


def _variant_tally() -> dict:
    return {"base_right": 0, "lost": {}, "comparable": {}, "non_usable": {}}


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

CSV_COLUMNS = ["track_id", "slice", "pick", "tags", "vocal", "language",
               "variant", "player_id", "title", "artist", "album", "duration",
               "outcome", "verdict", "flags", "chosen_id", "chosen_via", "containment", "timed_for_longer",
               "truth_status", "fit_n", "fit_identity_n", "overrun_fit_n", "near_n", "isla_saw_fit",
               "cluster_n", "alt_n", "usable", "notes"]


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


def plain_dirname(name: str) -> str:
    """A directory name under the root: no separators, no `..`."""
    if not name or name in (".", "..") or "/" in name or "\\" in name or os.path.isabs(name):
        raise ValueError(f"{name!r} is not a plain directory name")
    return name


def nearest_rank_summary(values: List[float]) -> dict:
    """The Swift harness's `LabStats.summary`: nearest-rank percentiles."""
    if not values:
        return {"n": 0}
    ordered = sorted(values)

    def rank(p: float) -> float:
        index = max(0, math.ceil(p * len(ordered)) - 1)
        return ordered[min(index, len(ordered) - 1)]

    return {"n": len(ordered), "min": ordered[0], "p50": rank(0.5), "p95": rank(0.95), "p99": rank(0.99),
            "max": ordered[-1], "mean": sum(ordered) / len(ordered)}


def _readability_cell(entries: List[dict], surface_available: Dict[str, float]) -> dict:
    lines = sum(e["lines"] for e in entries)
    durations = [d for e in entries for d in e.get("durations", [])]
    surfaces = {}
    for key, available in surface_available.items():
        ratios = [x for e in entries for x in (e.get("surfaces", {}).get(key, {}).get("ratios") or [])]
        widths = [x for e in entries for x in (e.get("surfaces", {}).get(key, {}).get("widths") or [])]
        rows = [x for e in entries for x in (e.get("surfaces", {}).get(key, {}).get("rows") or [])]
        overflow = sum(e.get("surfaces", {}).get(key, {}).get("overflow", 0) for e in entries)
        surfaces[key] = {"available_pt": available, "overflow_lines": overflow,
                         "overflow_share": analysis.share(overflow, lines),
                         "width_pt": nearest_rank_summary(widths),
                         "width_over_available": nearest_rank_summary(ratios),
                         "rows_if_wrapped_for_overflowing_lines": nearest_rank_summary(rows)}
    return {
        "tracks": len(entries), "lines": lines,
        "line_duration_s": nearest_rank_summary(durations),
        "graphemes_per_second": nearest_rank_summary([x for e in entries for x in e.get("cps", [])]),
        "syllables_per_second": nearest_rank_summary([x for e in entries for x in e.get("sps", [])]),
        "share_under_0_6_s": analysis.share(sum(1 for d in durations if d < 0.6), lines),
        "share_under_1_0_s": analysis.share(sum(1 for d in durations if d < 1.0), lines),
        "surfaces": surfaces,
    }


def readability_section(path: str, wrong_song_tracks: set) -> dict:
    """M4, merged from the harness file, plus the same figures without the
    canonical lookups whose verdict is wrong-song (adversarial review F15):
    readability of lyrics for a different song is not a finding about the
    right ones. The harness writes one entry per lookup under `per_lookup`;
    an older file without it keeps the unfiltered figures and says so."""
    data = verbatim(path, "M4 readability")
    entries = data.get("per_lookup")
    if not isinstance(entries, list):
        if isinstance(data.get("all"), dict):
            data["without_wrong_song"] = {"available": False, "reason":
                                          "the file has no per_lookup entries; rerun the Swift harness"}
        return data
    kept = [e for e in entries if isinstance(e, dict) and e.get("track_id") not in wrong_song_tracks]
    surface_available = {k: v.get("available_pt", 0) for k, v in
                         ((data.get("all") or {}).get("surfaces") or {}).items()}
    by_slice: Dict[str, List[dict]] = {}
    for entry in kept:
        by_slice.setdefault(str(entry.get("slice") or ""), []).append(entry)
    data["without_wrong_song"] = {
        "available": True,
        "lookups_excluded": len(entries) - len(kept),
        "lookups_kept": len(kept),
        "all": _readability_cell(kept, surface_available),
        "slices": {k: _readability_cell(v, surface_available) for k, v in sorted(by_slice.items())},
    }
    data["per_lookup"] = len(entries)   # the raw rows stay in the harness file, not in the report
    kept_lines = data["without_wrong_song"]["all"]["lines"]
    data["summary"] = (data.get("summary") or "") + (
        f" | without wrong-song lookups ({len(entries) - len(kept)} excluded): {kept_lines} lines, "
        f"under 0.6 s {_pct(data['without_wrong_song']['all']['share_under_0_6_s'])}")
    return data


def run(root: str, results_name: str = DEFAULT_RESULTS, reports_name: str = DEFAULT_REPORTS,
        calibration: bool = True, pool_results: Sequence[str] = ()) -> dict:
    root = os.path.expanduser(root)
    results_name, reports_name = plain_dirname(results_name), plain_dirname(reports_name)
    pool_results = [plain_dirname(name) for name in pool_results]
    results_dir = os.path.join(root, results_name)
    reports_dir = os.path.join(root, reports_name)
    # `matched/` is the M5 corpus of the baseline run. An experiment (an
    # alternate reports directory) reads and scores but never replaces it.
    write_matched = reports_name == DEFAULT_REPORTS
    oracle.reset_calibration()
    if calibration:
        oracle.load_calibration(root)
    params_now = oracle.active_params()
    params_mismatch = 0
    tracks = read_jsonl(os.path.join(root, "resolved", "tracks.jsonl"))
    lookups = read_jsonl(os.path.join(results_dir, "isla-lookups.jsonl"))
    perturbations = read_jsonl(os.path.join(results_dir, "perturbations.jsonl"))
    by_track: Dict[str, List[dict]] = {}
    for lookup in lookups:
        by_track.setdefault(lookup["track_id"], []).append(lookup)
    # The lookups of other runs whose responses join each track's known pool
    # (third review, M1). Their verdicts are not computed; only their rows are
    # read, the way this run's own are.
    pool_by_track: Dict[str, List[dict]] = {}
    pool_lookups = 0
    for name in pool_results:
        for lookup in read_jsonl(os.path.join(root, name, "isla-lookups.jsonl")):
            if "track_id" in lookup:
                pool_by_track.setdefault(lookup["track_id"], []).append(lookup)
                pool_lookups += 1

    matched_root = os.path.join(root, "matched")
    if write_matched and os.path.isdir(matched_root):
        shutil.rmtree(matched_root)  # generated output; a stale record must not outlive its verdict
    matched_ids: set = set()

    results: List[dict] = []
    diagnose: List[dict] = []
    clusters: Dict[str, set] = {}
    alts: Dict[str, set] = {}
    wrong_song_tracks: set = set()
    noise = analysis.NoiseStudy()
    selection = analysis.SelectionStudy()
    selection_duplicates = analysis.DuplicateTally()
    promoted_tracks = 0
    unanswered_anchored = 0
    coverage: Dict[str, dict] = {}
    consensus_cache: Dict[tuple, Dict] = {}

    for track in tracks:
        tid, slice_id = track["track_id"], track["slice"]
        truth = Truth(root, track)
        if track.get("oracle_params") and track["oracle_params"] != params_now:
            params_mismatch += 1
        harvest = truth.harvest
        track_lookups = by_track.get(tid, [])
        # An unanswered query on an anchored track matters only while the
        # track is scored at all (third review, m4).
        if track_lookups and truth.anchored and truth.unanswered and truth.exclusion() is None:
            unanswered_anchored += 1
        responses = [isla_rows(root, lookup) for lookup in track_lookups]
        # The known pool of the track: every lookup's responses here and in
        # each --pool-results directory. Usable and promotion are decided from
        # it; what Isla saw is still its own lookup's `responses` (M1).
        known: Dict[int, dict] = {}
        for rows_of_lookup in responses:
            for row in rows_of_lookup.values():
                absorb(known, row)
        for other in pool_by_track.get(tid, []):
            for row in isla_rows(root, other).values():
                absorb(known, row)
        if truth.status == "no-anchor":
            if truth.promote(known):
                promoted_tracks += 1
        family = oracle.script_family(oracle.expected_script(harvest.get("language") or "", harvest.get("title") or ""))
        cov = coverage.setdefault(slice_id, {
            "tracks": 0, "tracks_with_word_timed_record_in_cluster": 0,
            "tracks_canonical_chosen_word_timed": 0, "canonical_found": 0,
            "found_lookups_by_granularity": {}, "found_canonical_by_granularity": {}})
        cov["tracks"] += 1
        if any(truth.candidates.get(i, {}).get("word_timing") for i in truth.cluster):
            cov["tracks_with_word_timed_record_in_cluster"] += 1
        canonical_judged = None
        track_infos: Dict[int, dict] = {}
        for lookup, rows in zip(track_lookups, responses):
            j = judge(truth, lookup, rows, known)
            track_infos = j["infos"]      # the resolver's pool and the known pool: the same set on every lookup
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
                "truth_status": truth.status, "fit_n": len(j["fit_ids"]),
                "fit_identity_n": len(j["fit_identity_ids"]), "overrun_fit_n": len(j["overrun_ids"]),
                "near_n": len(j["near_ids"]), "isla_saw_fit": j["isla_saw_fit"],
                "cluster_n": len(j["cluster_ids"]), "alt_n": len(truth.alt),
                "notes": truth.truth.get("notes") or [], "usable": j["usable"],
                "maybe_usable": j["maybe_usable"],
            }
            results.append(result)
            if variant == "canonical" and j["verdict"] == "wrong-song":
                wrong_song_tracks.add(tid)

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
                    if write_matched:
                        path = os.path.join(matched_root, slice_id, f"{lookup['chosen_id']}.json")
                        os.makedirs(os.path.dirname(path), exist_ok=True)
                        with open(path, "w", encoding="utf-8") as handle:
                            json.dump(dict(row, category=slice_id), handle, ensure_ascii=False)

            # M10: of several correct records, did Isla pick the best?
            if variant in ("canonical", "apple") and j["verdict"] == "correct" and len(j["fit_ids"]) >= 2 \
                    and j["chosen_info"] is not None:
                fit_key = tuple(sorted(j["fit_ids"]))
                cache_key = (fit_key, lookup["chosen_id"])
                if cache_key not in consensus_cache:
                    # Copies of one timeline are one vote, and the chosen
                    # record stays in its group so it can be scored.
                    unique, groups = analysis.collapse_identical(
                        {rid: analysis.sung(j["everything"][rid]) for rid in fit_key}, prefer=lookup["chosen_id"])
                    selection_duplicates.add(groups)
                    consensus_cache[cache_key] = analysis.expand_deviations(
                        analysis.consensus_deviation(unique), groups)
                    if len(consensus_cache) > 4:
                        consensus_cache.pop(next(iter(consensus_cache)))
                info = j["infos"]
                selection.add_case(
                    variant,
                    {"id": lookup["chosen_id"], "duration": info[lookup["chosen_id"]]["duration"],
                     "word_timing": info[lookup["chosen_id"]]["word_timing"]},
                    [{"id": rid, "duration": info[rid]["duration"], "word_timing": info[rid]["word_timing"]}
                     for rid in fit_key],
                    float(identity.get("duration") or 0), consensus_cache[cache_key])

            if j["verdict"] in DIAGNOSE:
                entry = {
                    "track_id": tid, "variant": variant, "verdict": j["verdict"],
                    "identity": {"player_id": identity.get("player_id"), "title": identity.get("title"),
                                 "artist": identity.get("artist"), "album": identity.get("album"),
                                 "duration": identity.get("duration")},
                    "request_keys": [r["key"] for r in lookup.get("requests") or [] if r.get("key")],
                    "fit_ids": j["near_ids"] if j["verdict"] == "miss-tolerance"
                    else (j["fit_identity_ids"] or j["overrun_ids"] if j["verdict"] in RECOVERABLE else j["fit_ids"]),
                    "chosen_id": lookup.get("chosen_id"),
                    "cluster_ids": j["cluster_ids"],
                }
                if j["verdict"] == "miss-unqueried":
                    entry["found_by"] = {str(rid): truth.candidates.get(rid, {}).get("source_queries", [])
                                         for rid in entry["fit_ids"]}
                diagnose.append(entry)

        # M2 needs the cluster as the canonical lookup saw it.
        clusters[tid] = canonical_judged[1]["members"] if canonical_judged else set(truth.cluster)
        # Every record that is the song in another script, by the predicate M1's
        # verdict uses: the oracle's alt anchors and any identity-matching record
        # in another script that only Isla's queries returned. Resolver anchors
        # alone made a romaji pick `switched-wrong` in M2 while M1 called it
        # `alt-script` (fourth review, N1).
        alts[tid] = set(truth.alt) | {rid for rid, info in track_infos.items() if truth.is_alt_script(rid, info)}

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
                # NoiseStudy folds identical timelines into one record itself.
                noise.add_track(slice_id, {rid: analysis.sung(everything[rid]) for rid in ids},
                                canonical_judged[0].get("chosen_id") if canonical_judged else None)

    # ---- sections ----
    canonical = [r for r in results if r["variant"] == "canonical"]
    m1_counts = counts(results)
    canon_counts = counts(canonical)
    promoted_rows = [r for r in results if PROMOTED_FLAG in r["flags"]]
    # A pass needs every answer. A lookup the cache could not answer, one the
    # harness could not attribute, or an LRCLIB query of the resolver's that
    # went unanswered on a track that has an anchor could each move the
    # figures, so the result is incomplete (second review, finding 5). Third
    # review, m4: only a lookup that might have been usable counts, and `failed`
    # is one (m2); one on an excluded track, or one the truth shows could not
    # have been usable, cannot move the figure.
    unscored_total = m1_counts["unscorable_possibly_usable"]
    if not results:
        m1 = section("info", f"no lookups: {results_name}/isla-lookups.jsonl is absent or empty")
    else:
        acc, wr, rec = canon_counts["accuracy"], canon_counts["wrong_rate"], canon_counts["recoverable_of_usable"]
        if acc is None:
            verdict = "info"
        elif acc < 0.75 or (wr or 0) > 0.05:
            verdict = "fail"
        elif acc >= 0.90 and (wr or 0) <= 0.02 and (rec or 0) <= 0.02:
            verdict = "incomplete" if (unscored_total or unanswered_anchored) else "pass"
        else:
            verdict = "concern"
        slice_cut = cut(canonical, lambda r: r["slice"])
        worst = min(((k, v["accuracy"]) for k, v in slice_cut.items() if v["accuracy"] is not None),
                    key=lambda kv: kv[1], default=None)
        bounds = canon_counts["accuracy_bounds"]
        m1 = section(
            verdict,
            f"{len(results)} lookups ({len(canonical)} canonical). Canonical accuracy "
            f"{_pct(acc)} of {canon_counts['usable']} usable, wrong rate {_pct(wr)} of {canon_counts['shown']} shown, "
            f"recoverable misses {canon_counts['recoverable_misses']} ({_pct(rec)} of usable)"
            + (f"; weakest slice {worst[0]} at {_pct(worst[1])}" if worst else "")
            + (f"; {canon_counts['unscorable_possibly_usable']} canonical lookups uncached, unrecovered or failed, "
               f"canonical accuracy in [{_pct(bounds['lower'])}, {_pct(bounds['upper'])}]"
               if canon_counts["unscorable_possibly_usable"] else "")
            + (f"; {unscored_total} lookups uncached, unrecovered or failed, accuracy over every lookup in "
               f"[{_pct(m1_counts['accuracy_bounds']['lower'])}, {_pct(m1_counts['accuracy_bounds']['upper'])}]"
               if unscored_total else "")
            + (f"; {unanswered_anchored} anchored tracks had an LRCLIB query go unanswered" if unanswered_anchored else "")
            + (f"; excluded from scoring: {m1_counts['excluded_from_scoring']}"
               if m1_counts["excluded_from_scoring"] else "")
            + ".",
            overall=m1_counts, canonical=canon_counts,
            accuracy_bounds={"overall": m1_counts["accuracy_bounds"], "canonical": canon_counts["accuracy_bounds"]},
            excluded_from_scoring={"overall": m1_counts["excluded_from_scoring"],
                                   "canonical": canon_counts["excluded_from_scoring"]},
            anchor_promoted_tracks=promoted_tracks,
            # The promoted tracks' lookups, scored as they would have been:
            # not in the headline above or any cut below.
            anchor_promoted=counts(promoted_rows, keep_promoted=True),
            lrclib_unanswered_tracks=unanswered_anchored,
            by_slice=cut(results, lambda r: r["slice"]),
            by_variant=cut(results, lambda r: r["variant"]),
            by_slice_variant=cut(results, lambda r: f"{r['slice']} | {r['variant']}"),
            by_pick=cut(results, lambda r: r["pick"]),
            by_tag=cut(results, lambda r: r["tags"] or ["(none)"]),
            by_script_family=cut(results, lambda r: r["script_family"]),
            # Accuracy with and without the tracks whose every anchor only
            # Isla's own canonical query (/api/get) returned.
            by_sole_anchor_from_get=cut(results, lambda r: "yes" if SOLE_GET_FLAG in r["flags"] else "no"),
            # Tracks whose anchors disagree about the instrumental flag: scored,
            # and cut apart, since Isla's early exit on a mislabelled record is
            # a real failure on exactly them (third review, M2).
            by_mixed_anchor_flags=cut(results, lambda r: "yes" if MIXED_FLAG in r["flags"] else "no"),
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
        f"{estimation['records']} word-timed records ({estimation['lines']} lines, {estimation['words_scored']} words scored, "
        f"{estimation['interpolated_words_not_scored']} interpolated words left unscored). E4's cap was tuned on "
        f"even-indexed tracks and every figure below is scored on odd-indexed ones; "
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
        if allcell else "no track has two independent synced records to compare"), by_slice=noise_result,
        duplicate_timelines=noise.duplicate_report())

    sel = selection.result()
    sel_all = sel.get("all")
    m10 = section("info", (
        f"{sel_all['cases']} correct lookups with 2+ fit records: Isla picked the closest length in "
        f"{_pct(sel_all['picked_closest_length'])}, a word-timed record in {_pct(sel_all['picked_word_timed_when_available'])} "
        f"of {sel_all['word_timed_available_cases']} cases where one existed, the consensus-closest in "
        f"{_pct(sel_all['picked_closest_to_consensus'])} of {sel_all['consensus_cases']}."
        if sel_all else "no correct lookup had two fit records"), by_variant=sel,
        duplicate_timelines=selection_duplicates.result())

    report = {
        "meta": {
            "root": root, "tracks": len(tracks), "lookups": len(lookups), "perturbation_rows": len(perturbations),
            "matched_records": len(matched_ids), "matched_written": write_matched,
            "diagnose_rows": len(diagnose),
            "results_dir": results_name, "reports_dir": reports_name,
            "pool_results": pool_results, "pool_results_lookups": pool_lookups,
            "oracle": params_now, "oracle_params_mismatch_tracks": params_mismatch,
            "inputs": {name: os.path.exists(os.path.join(root, *name.split("/"))) for name in (
                "resolved/tracks.jsonl", f"{results_name}/isla-lookups.jsonl",
                f"{results_name}/perturbations.jsonl", f"{results_name}/word-fidelity.json",
                f"{results_name}/readability.json")},
            "thresholds": THRESHOLDS,
            "verdict_values": "pass | concern | fail | info | incomplete",
        },
        "M1": m1,
        "M2": perturbation_section(perturbations, clusters, alts),
        "M3": m3,
        "M3a": verbatim(os.path.join(results_dir, "word-fidelity.json"), "M3a word fidelity"),
        "M4": readability_section(os.path.join(results_dir, "readability.json"), wrong_song_tracks),
        "M5": section("info", (f"{len(matched_ids)} chosen records written under matched/ for the 2026-10-11 lab's rerun."
                               if write_matched else
                               f"{len(matched_ids)} chosen records would be written; matched/ is left alone because "
                               f"--reports is {reports_name}, not {DEFAULT_REPORTS}."),
                      records=len(matched_ids) if write_matched else 0,
                      by_slice=_count(os.path.join(matched_root, d) for d in os.listdir(matched_root))
                      if write_matched and os.path.isdir(matched_root) else {}),
        "M6": variant_section(results),
        "M9": m9,
        "M10": m10,
    }

    os.makedirs(reports_dir, exist_ok=True)
    write_json(os.path.join(reports_dir, "match-lab-report.json"), report)
    write_csv(os.path.join(reports_dir, "rows.csv"), results)
    with open(os.path.join(reports_dir, "diagnose-input.jsonl"), "w", encoding="utf-8") as handle:
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


def _dirname_arg(value: str) -> str:
    try:
        return plain_dirname(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Classify Isla's lookups against the oracle's truth.")
    parser.add_argument("--root", default=DEFAULT_ROOT)
    parser.add_argument("--results", default=DEFAULT_RESULTS, type=_dirname_arg,
                        help="directory under the root the Swift harness wrote (ISLA_MATCH_OUT); default results")
    parser.add_argument("--reports", default=DEFAULT_REPORTS, type=_dirname_arg,
                        help="directory under the root to write the report, rows.csv and diagnose-input.jsonl "
                        "to; matched/ is written only for the default reports")
    parser.add_argument("--pool-results", action="append", default=[], type=_dirname_arg,
                        help="a results directory under the root whose responses join each track's known pool "
                        "(repeatable); a baseline and a candidate are each classified with the other's")
    parser.add_argument("--no-calibration", action="store_true",
                        help="ignore reports/oracle-calibration.json and use the built-in n-gram table")
    args = parser.parse_args(argv)
    run(args.root, args.results, args.reports, calibration=not args.no_calibration, pool_results=args.pool_results)
    return 0


if __name__ == "__main__":
    sys.exit(main())
