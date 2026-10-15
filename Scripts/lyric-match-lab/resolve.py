#!/usr/bin/env python3
"""Resolve harvested tracks into ground truth for the lyrics match lab.

Phase 1 of the lab (docs/audits/2026-10-15-lyrics-match-lab/SPEC.md,
"Resolution"). For every harvested track it asks Apple Music (iTunes search)
and Deezer who the song is, collects LRCLIB candidates, decides with the
independent oracle (oracle.py) which of them are the same song, and writes the
identities Isla will be asked about.

    python3 resolve.py --root <root> [--slices a,b] [--limit N] [--offline]

    --root     corpus root (default ~/code/_tools/isla-lyrics-lab)
    --slices   comma list of slice ids or slice file names; a file starting
               with "_" (such as _dev.json) is read only when named here
    --limit    at most N tracks from each slice
    --check-harvest  parse the slice files, print counts and schema anomalies,
               then stop: no network, nothing written
    --offline  answer from cache/ alone; a miss is "unknown", the network is
               never touched. Re-resolves after an oracle change at no cost.

Stage A runs three threads at once, because each talks to a different host:
iTunes, Deezer, and the LRCLIB searches (which need no duration). Stage B then
runs /api/get with the Apple duration, one track at a time, and the oracle.
Rerunning is cheap: every response is in cache/py/ and failures are never
cached, so a rerun retries exactly what failed.

Writes under <root>: resolved/{tracks,variants,dropped}.jsonl,
resolved/summary.json, wordtimed/<slice>/<id>.json. When --slices is given the
named slices' lines replace their old ones and every other slice is kept.
No lyric text is written outside cache/ and wordtimed/.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import threading
import time
import unicodedata
from typing import Dict, List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import common  # noqa: E402
import oracle  # noqa: E402

DEFAULT_ROOT = os.path.expanduser("~/code/_tools/isla-lyrics-lab")

# --------------------------------------------------------------------------
# Tunable tables
# --------------------------------------------------------------------------

# How Spotify names the edition of a song, as the `spotify-style` variant
# spells it. Tune this against conventions.json; nothing else in the script
# knows the shapes. `editions` is ordered and the first rule whose regex hits
# the edition text (bracket contents and the " - …" tail of the Apple, Deezer
# and harvest titles) decides the suffix; `{year}` is the regex's `year` group.
SPOTIFY_STYLE = {
    "artist_joiner": ", ",
    "feat": " (feat. {names})",
    "feat_joiner": ", ",
    "editions": {
        "remastered-year": (r"remaster(?:ed)?\D{0,12}(?P<year>(?:19|20)\d\d)", " - Remastered {year}"),
        "year-remaster": (r"(?P<year>(?:19|20)\d\d)\D{0,12}remaster(?:ed)?", " - Remastered {year}"),
        "remastered": (r"remaster(?:ed)?", " - Remastered"),
        "live": (r"\blive\b", " - Live"),
        "radio-edit": (r"\bradio\s+(?:edit|version|mix)\b", " - Radio Edit"),
    },
}

# The `player_id` Isla sees for each variant: what the player reports as the
# bundle id of the app playing.
PLAYER_IDS = {
    "canonical": "lab",
    "latin-alt": "lab",
    "apple": "com.apple.Music",
    "deezer": "com.deezer.deezer-desktop",
    "spotify-style": "com.spotify.client",
    "no-album": "lab",
    "apple-us": "com.apple.Music",
}
VARIANT_ORDER = ["canonical", "no-album", "apple", "apple-us", "deezer", "spotify-style", "latin-alt"]
NO_ALBUM_EVERY = 4  # SPEC amendment: the no-album variant runs for index % 4 == 0

INDIAN_LANGUAGES = {"hi", "pa", "ta", "te", "ml", "kn", "mr", "bn", "gu", "ur", "ne", "or", "as"}

FIT_TOLERANCE = 3.0   # seconds, SPEC step 6
NEAR_TOLERANCE = 10.0
CLUSTER_THRESHOLD = 0.6


def storefront(slice_id: str, language: str) -> str:
    """iTunes storefront for a track (SPEC step 1 table)."""
    lang = (language or "").lower()
    if slice_id == "kpop-jpop-anime":
        return "jp" if lang == "ja" else "kr" if lang == "ko" else "us"
    if slice_id == "cpop-southeast-asia":
        return "tw"
    if slice_id == "russian-cis-uzbek":
        return "kz"
    if slice_id == "middle-east-south-asia":
        if lang == "ar":
            return "ae"
        if lang == "tr":
            return "tr"
        return "in" if lang in INDIAN_LANGUAGES else "us"
    if slice_id == "latin":
        return "br" if lang == "pt" else "mx"
    if slice_id == "africa-caribbean-europe":
        return lang if lang in ("fr", "de", "it") else "ng"
    return "us"


# --------------------------------------------------------------------------
# Harvest
# --------------------------------------------------------------------------

def normalize_harvest(raw: dict, slice_id: str, index: int) -> dict:
    """A harvested track with every field present, so later code never guards."""
    track = dict(raw)
    track["title"] = track.get("title") or ""
    track["title_latin"] = track.get("title_latin") or ""
    track["artists"] = list(track.get("artists") or [])
    latin = list(track.get("artists_latin") or [])
    track["artists_latin"] = (latin + [""] * len(track["artists"]))[:len(track["artists"])]
    track["featured"] = list(track.get("featured") or [])
    track["album"] = track.get("album") or ""
    track["language"] = track.get("language") or ""
    track["vocal"] = track.get("vocal") or "full"
    track["tags"] = list(track.get("tags") or [])
    track["track_id"] = f"{slice_id}/{index:03d}"
    track["slice"] = slice_id
    track["index"] = index
    return track


def load_slices(root: str, only: Optional[List[str]], limit: Optional[int]):
    """[(slice_id, [track, …])] in file-name order.

    A file starting with "_" is a scratch slice and is read only when named.
    Names match the file stem or the `slice` field. Tracks are numbered in
    harvest order from 0, before --limit trims them, so an id never changes
    when a run is limited.
    """
    directory = os.path.join(root, "slices")
    names = sorted(n for n in os.listdir(directory) if n.endswith(".json")) if os.path.isdir(directory) else []
    out = []
    for name in names:
        stem = name[:-5]
        with open(os.path.join(directory, name), encoding="utf-8") as handle:
            data = json.load(handle)
        slice_id = data.get("slice") or stem
        if only is None:
            if name.startswith("_"):
                continue
        elif stem not in only and slice_id not in only:
            continue
        tracks = [normalize_harvest(t, slice_id, i) for i, t in enumerate(data.get("tracks") or [])]
        out.append((slice_id, tracks[:limit] if limit else tracks))
    return out


TAG_VOCABULARY = {
    "fast-rap", "dense-lyrics", "melisma", "sparse-vocals", "long-gaps", "long-intro", "very-long",
    "very-short", "instrumental", "live", "remaster", "radio-edit", "remix", "cover",
    "same-title-other-song", "feat", "multi-artist", "non-latin-title", "non-latin-artist",
    "mixed-script", "rtl", "diacritics", "symbols-in-title", "numeric-title", "parenthetical-title",
    "duet", "choir", "spoken-word", "harsh-vocals", "repeated-chorus", "medley",
    "classical-movement", "soundtrack", "explicit-clean", "chart-top", "other-language-version",
}


def check_harvest(root: str, only: Optional[List[str]] = None) -> dict:
    """Parse the slice files and report schema anomalies. Offline, read-only.

    Anomalies are findings, not errors: a track the resolver can still handle
    (empty album, year 0) is counted so the owner knows how much of the corpus
    leans on the services instead of the harvest.
    """
    directory = os.path.join(os.path.expanduser(root), "slices")
    report = {"slices": {}, "anomalies": [], "totals": {}}
    anomalies = report["anomalies"]
    totals: Dict[str, int] = {}

    def bump(key: str, n: int = 1):
        totals[key] = totals.get(key, 0) + n

    names = sorted(n for n in os.listdir(directory) if n.endswith(".json")) if os.path.isdir(directory) else []
    titles_seen: Dict[tuple, str] = {}
    for name in names:
        stem = name[:-5]
        if (only is None and name.startswith("_")) or (only is not None and stem not in only):
            continue
        try:
            with open(os.path.join(directory, name), encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError) as error:
            anomalies.append(f"{name}: unreadable ({error})")
            continue
        slice_id = data.get("slice")
        if slice_id != stem:
            anomalies.append(f"{name}: slice field {slice_id!r} differs from file name")
        raw_tracks = data.get("tracks")
        if not isinstance(raw_tracks, list):
            anomalies.append(f"{name}: no tracks list")
            continue
        info = {"tracks": len(raw_tracks), "popular": 0, "stress": 0, "vocal_none": 0, "no_album": 0,
                "year_0": 0, "non_latin_title": 0, "non_latin_title_without_latin": 0,
                "empty_artists_latin_entries": 0}
        artist_counts: Dict[str, int] = {}
        for i, raw in enumerate(raw_tracks):
            where = f"{slice_id}/{i:03d}"
            if not isinstance(raw, dict):
                anomalies.append(f"{where}: not an object")
                continue
            track = normalize_harvest(raw, stem, i)
            for key, kind in (("title", str), ("artists", list), ("artists_latin", list), ("featured", list),
                              ("album", str), ("year", int), ("language", str), ("vocal", str),
                              ("pick", str), ("tags", list), ("source_url", str), ("why", str)):
                if key not in raw:
                    anomalies.append(f"{where}: missing {key}")
                elif not isinstance(raw[key], kind):
                    anomalies.append(f"{where}: {key} is {type(raw[key]).__name__}, expected {kind.__name__}")
            if not track["title"].strip():
                anomalies.append(f"{where}: empty title")
            if not track["artists"] or not all(isinstance(a, str) and a.strip() for a in track["artists"]):
                anomalies.append(f"{where}: empty or blank artists")
            raw_latin = raw.get("artists_latin")
            if isinstance(raw_latin, list):
                if raw_latin and len(raw_latin) != len(track["artists"]):
                    anomalies.append(f"{where}: artists_latin has {len(raw_latin)} entries for {len(track['artists'])} artists")
                info["empty_artists_latin_entries"] += sum(1 for a in raw_latin if a == "")
            if track["vocal"] not in ("full", "sparse", "none"):
                anomalies.append(f"{where}: vocal {track['vocal']!r}")
            if raw.get("pick") not in ("popular", "stress"):
                anomalies.append(f"{where}: pick {raw.get('pick')!r}")
            else:
                info[raw["pick"]] += 1
            unknown = [t for t in track["tags"] if t not in TAG_VOCABULARY]
            if unknown:
                anomalies.append(f"{where}: tags outside the vocabulary {unknown}")
            if raw.get("pick") == "popular" and not (raw.get("source_url") or "").startswith("http"):
                anomalies.append(f"{where}: popular pick without a source_url")
            if raw.get("language") and not re.fullmatch(r"[a-z]{2,3}", raw["language"]):
                anomalies.append(f"{where}: language {raw['language']!r}")
            if track["vocal"] == "none" and track["language"] not in ("zxx", ""):
                anomalies.append(f"{where}: vocal none but language {track['language']!r}")
            if track["vocal"] == "none":
                info["vocal_none"] += 1
            if not track["album"]:
                info["no_album"] += 1
            if not raw.get("year"):
                info["year_0"] += 1
            if oracle.dominant_script(track["title"]) not in ("LATIN", ""):
                info["non_latin_title"] += 1
                if not track["title_latin"]:
                    info["non_latin_title_without_latin"] += 1
            for artist in track["artists"][:1]:
                artist_counts[artist] = artist_counts.get(artist, 0) + 1
            key = duplicate_key(track)
            if key[0] and key in titles_seen:
                anomalies.append(f"{where}: repeats {titles_seen[key]} (will be dropped as duplicate)")
            titles_seen.setdefault(key, where)
        for artist, n in artist_counts.items():
            if n > 2:
                anomalies.append(f"{slice_id}: {artist!r} is primary artist of {n} tracks (limit 2)")
        if info["popular"] < 20:
            anomalies.append(f"{slice_id}: only {info['popular']} popular picks (plan: 20)")
        if info["stress"] > 10:
            anomalies.append(f"{slice_id}: {info['stress']} stress picks (plan: at most 10)")
        report["slices"][stem] = info
        for key, value in info.items():
            bump(key, value)
    report["totals"] = totals
    report["totals"]["slices"] = len(report["slices"])
    return report


def latin_forms(track: dict):
    """(title, primary artist, differs) in Latin script, falling back to native."""
    title = track["title_latin"] or track["title"]
    artist = (track["artists_latin"][0] if track["artists_latin"] else "") or \
        (track["artists"][0] if track["artists"] else "")
    primary = track["artists"][0] if track["artists"] else ""
    return title, artist, (title != track["title"] or artist != primary)


def _with_aliases(names: List[str]) -> List[str]:
    out = list(names)
    for name in names:
        out.extend(oracle.latin_aliases(name))
    return out


def track_titles(track: dict) -> List[str]:
    """Harvest titles plus the BGN/PCGN aliases of any Cyrillic one."""
    return _with_aliases([t for t in (track["title"], track["title_latin"]) if t])


def track_artists(track: dict) -> List[str]:
    return _with_aliases([n for n in track["artists"] + track["artists_latin"] if n])


def identity_titles(track: dict, apple: Optional[dict], deezer: Optional[dict],
                    apple_us: Optional[dict] = None) -> List[str]:
    """Every spelling that may anchor a record. The aliases and the `apple-us`
    names serve anchor matching only (SPEC amendment); no variant is built
    from them."""
    titles = track_titles(track)
    for service in (apple, apple_us):
        if service:
            titles.append(service["trackName"])
    if deezer:
        titles += [deezer["title"], deezer.get("title_short") or ""]
    return [t for t in titles if t]


def identity_artists(track: dict, apple: Optional[dict], deezer: Optional[dict],
                     apple_us: Optional[dict] = None) -> List[str]:
    """Credited main artists only: a featured artist's catalogue is not this song."""
    names = track_artists(track)
    for service in (apple, apple_us):
        if service:
            names.append(service["artistName"])
    if deezer:
        names.append(deezer["artist"])
    return [n for n in names if n]


# --------------------------------------------------------------------------
# Apple Music and Deezer
# --------------------------------------------------------------------------

def itunes_url(term: str, country: str) -> str:
    return common.build_url("https://itunes.apple.com/search", [
        ("term", term), ("entity", "song"), ("limit", "10"), ("country", country)])


def deezer_structured_url(title: str, artist: str) -> str:
    return common.build_url("https://api.deezer.com/search", [
        ("q", f'artist:"{artist}" track:"{title}"')])


def deezer_plain_url(title: str, artist: str) -> str:
    return common.build_url("https://api.deezer.com/search", [("q", f"{title} {artist}")])


def _itunes_ok(status: int, body: bytes) -> bool:
    try:
        return isinstance(json.loads(body.decode("utf-8")).get("results"), list)
    except (ValueError, AttributeError, UnicodeDecodeError):
        return False


def _deezer_ok(status: int, body: bytes) -> bool:
    """Deezer reports quota exhaustion as HTTP 200 with an `error` object."""
    try:
        data = json.loads(body.decode("utf-8"))
        return isinstance(data, dict) and "error" not in data and isinstance(data.get("data"), list)
    except (ValueError, UnicodeDecodeError):
        return False


_SUSPECT_WORDS = {"live", "remix", "karaoke", "instrumental", "tribute", "cover", "acoustic",
                  "demo", "version", "mix", "edit", "slowed", "sped", "reverb", "lofi"}


# A hit scoring at least this is the recording the harvest means (exact title,
# or the harvest's own album), so the remaining queries are not spent.
GOOD_ENOUGH = 2


def pick_best(track: dict, results: List[dict], read, extra_titles=()):
    """`(result, score)` of the result that confirms identity (title AND artist)
    and looks most like the original recording, or `(None, None)`.

    `read(result)` returns `(titles, artist, album)`. A tie goes to the earlier
    result because services rank by popularity, which favours the original
    over a karaoke cover that happens to share the title.
    """
    wanted_titles = track_titles(track) + list(extra_titles)
    names = track_artists(track)
    plain_wanted = {oracle.normalize_text(t) for t in wanted_titles if t}
    allowed = set(oracle.normalize_text(" ".join(wanted_titles + track["tags"])).split())
    album_wanted = oracle.normalize_text(track["album"])
    best, best_score = None, None
    for position, result in enumerate(results):
        titles, artist, album = read(result)
        if not any(oracle.title_match(wanted_titles, t) for t in titles):
            continue
        if not oracle.artist_match(names, artist):
            continue
        score = 0
        if any(oracle.normalize_text(t) in plain_wanted for t in titles):
            score += 3
        if album_wanted and oracle.normalize_text(album) == album_wanted:
            score += 2
        extra = set(oracle.normalize_text(titles[0]).split()) - allowed
        score -= len(extra & _SUSPECT_WORDS)
        if best_score is None or score > best_score:
            best, best_score = result, score
    return best, best_score


def resolve_apple(track: dict, root: str, offline: bool) -> dict:
    """{"status": found|none|failed, "apple": {...}|None, "queries": n}.

    Tries the storefront (title and album first, then title and artist), then `us`; with the
    Latin spelling too when it differs, because the catalogue may list a
    romanised title.
    """
    primary = track["artists"][0] if track["artists"] else ""
    latin_title, latin_artist, differs = latin_forms(track)
    terms = [f"{track['title']} {primary}".strip()]
    if differs:
        terms.append(f"{latin_title} {latin_artist}".strip())
    country = storefront(track["slice"], track["language"])
    plan = [(country, t) for t in terms] + ([("us", t) for t in terms] if country != "us" else [])
    if track["album"]:
        # Title and album, no artist, goes first. Naming the artist lets a
        # popular song's covers and acoustic EP cuts outrank the original
        # ("Creep" came back as "Creep (Acoustic)"), and artist plus album
        # returns the album's other tracks instead of the song.
        plan.insert(0, (country, f"{track['title']} {track['album']}"))
    unanswered = 0
    best, best_score, best_queries = None, None, 0
    for index, (cc, term) in enumerate(plan):
        reply = common.fetch_json(itunes_url(term, cc), root, offline=offline, validate=_itunes_ok)
        if reply is None:
            unanswered += 1
            continue
        results = (reply[1] or {}).get("results") or []
        hit, score = pick_best(track, results, lambda r: ([r.get("trackName") or ""], r.get("artistName") or "",
                                                          r.get("collectionName") or ""))
        if hit and (best_score is None or score > best_score):
            best, best_score, best_queries = dict(hit, _storefront=cc), score, index + 1
        # A weak hit (an acoustic EP cut, a cover) is kept as a fallback while
        # the other queries look for the original.
        if best_score is not None and best_score >= GOOD_ENOUGH:
            break
    if best:
        entry = _apple_entry(best, best["_storefront"])
        us, us_status = resolve_apple_us(track, entry, terms, root, offline)
        return {"status": "found", "queries": best_queries, "apple": entry,
                "apple_us": us, "apple_us_status": us_status}
    return {"status": "failed" if unanswered == len(plan) else "none", "apple": None,
            "apple_us": None, "apple_us_status": "n/a",
            "queries": len(plan), "unanswered": unanswered}


def _apple_entry(hit: dict, country: str) -> dict:
    millis = hit.get("trackTimeMillis")
    return {
        "trackName": hit.get("trackName") or "",
        "artistName": hit.get("artistName") or "",
        "collectionName": hit.get("collectionName") or "",
        "duration": round(millis / 1000.0, 3) if millis else 0,
        "trackId": hit.get("trackId"),
        "primaryGenreName": hit.get("primaryGenreName") or "",
        "storefront": country,
    }


def resolve_apple_us(track: dict, apple: dict, terms: List[str], root: str, offline: bool):
    """The `us` storefront's answer for a track resolved elsewhere: what an
    English-locale account sees, often romanised ("Hochesh" for "Хочешь").

    `(entry_or_None, status)`. Kept only when its title or artist differs from
    the home storefront's, because an identical answer would add a variant that
    measures nothing. The first term is the plain title and artist one, which
    the `us` fallback of resolve_apple may already have cached.
    """
    if apple["storefront"] == "us":
        return None, "n/a"
    unanswered = 0
    for term in terms:
        reply = common.fetch_json(itunes_url(term, "us"), root, offline=offline, validate=_itunes_ok)
        if reply is None:
            unanswered += 1
            continue
        results = (reply[1] or {}).get("results") or []
        hit, _ = pick_best(track, results, lambda r: ([r.get("trackName") or ""], r.get("artistName") or "",
                                                      r.get("collectionName") or ""))
        if hit:
            entry = _apple_entry(hit, "us")
            if entry["trackName"] != apple["trackName"] or entry["artistName"] != apple["artistName"]:
                return entry, "different"
            return None, "same"
    return None, "unanswered" if unanswered == len(terms) else "none"


def resolve_deezer(track: dict, root: str, offline: bool) -> dict:
    primary = track["artists"][0] if track["artists"] else ""
    latin_title, latin_artist, differs = latin_forms(track)
    urls = [deezer_structured_url(track["title"], primary), deezer_plain_url(track["title"], primary)]
    if differs:
        urls += [deezer_structured_url(latin_title, latin_artist), deezer_plain_url(latin_title, latin_artist)]
    unanswered = 0
    best, best_score, best_queries = None, None, 0
    for index, url in enumerate(urls):
        reply = common.fetch_json(url, root, offline=offline, validate=_deezer_ok)
        if reply is None:
            unanswered += 1
            continue
        results = (reply[1] or {}).get("data") or []
        hit, score = pick_best(track, results, lambda r: (
            [r.get("title") or "", r.get("title_short") or ""],
            (r.get("artist") or {}).get("name") or "",
            (r.get("album") or {}).get("title") or ""))
        if hit and (best_score is None or score > best_score):
            best, best_score, best_queries = hit, score, index + 1
        if best_score is not None and best_score >= GOOD_ENOUGH:
            break
    if best:
        return {"status": "found", "queries": best_queries, "deezer": {
            "title": best.get("title") or "",
            "title_short": best.get("title_short") or "",
            "title_version": best.get("title_version") or "",
            "artist": (best.get("artist") or {}).get("name") or "",
            "album": (best.get("album") or {}).get("title") or "",
            "duration": best.get("duration") or 0,
            "id": best.get("id"),
        }}
    return {"status": "failed" if unanswered == len(urls) else "none", "deezer": None,
            "queries": len(urls), "unanswered": unanswered}


# --------------------------------------------------------------------------
# LRCLIB
# --------------------------------------------------------------------------

LRCLIB = "https://lrclib.net/api"


def lrclib_search_urls(track: dict) -> Dict[str, str]:
    """The search queries, which need no duration. Keys name them in
    `source_queries`; the Latin pair exists only when the Latin forms differ."""
    primary = track["artists"][0] if track["artists"] else ""
    urls = {
        "search:track_artist": common.build_url(f"{LRCLIB}/search", [
            ("track_name", track["title"]), ("artist_name", primary)]),
        "search:q": common.build_url(f"{LRCLIB}/search", [("q", f"{track['title']} {primary}".strip())]),
    }
    latin_title, latin_artist, differs = latin_forms(track)
    if differs:
        urls["search:track_artist:latin"] = common.build_url(f"{LRCLIB}/search", [
            ("track_name", latin_title), ("artist_name", latin_artist)])
        urls["search:q:latin"] = common.build_url(f"{LRCLIB}/search", [
            ("q", f"{latin_title} {latin_artist}".strip())])
    return urls


def lrclib_get_url(track: dict, duration: float, album: Optional[str] = None) -> str:
    """/api/get with the canonical identity and the Apple duration. Album and
    duration are left out when unknown rather than sent empty."""
    params = [("track_name", track["title"]),
              ("artist_name", track["artists"][0] if track["artists"] else "")]
    album = track["album"] if album is None else album
    if album:
        params.append(("album_name", album))
    if duration and duration > 0:
        params.append(("duration", str(int(round(duration)))))
    return common.build_url(f"{LRCLIB}/get", params)


def prefetch_lrclib(track: dict, root: str, offline: bool) -> dict:
    """Stage A: put the searches in the cache. Rows are re-read in stage B
    rather than held here, so 480 tracks of lyric text never sit in memory."""
    failed = []
    for key, url in lrclib_search_urls(track).items():
        if common.fetch(url, root, offline=offline) is None:
            failed.append(key)
    return {"failed": failed}


def collect_rows(track: dict, root: str, offline: bool, get_url: str, failed_searches: List[str]):
    """({id: row}, {id: [source query keys]}, [failed keys]) with duplicates merged.

    Rows from different queries describe the same record; the first one seen
    is kept and any field it lacks is filled from the others (the search rows
    carry `lyricsfile`, the /get row may not).
    """
    rows: Dict[int, dict] = {}
    sources: Dict[int, List[str]] = {}
    failed = list(failed_searches)

    def absorb(key: str, row: dict):
        if not isinstance(row, dict) or row.get("id") is None:
            return
        rid = row["id"]
        if rid not in rows:
            rows[rid] = dict(row)
            sources[rid] = []
        else:
            for field, value in row.items():
                if rows[rid].get(field) in (None, "") and value not in (None, ""):
                    rows[rid][field] = value
        if key not in sources[rid]:
            sources[rid].append(key)

    reply = common.fetch_json(get_url, root, offline=offline)
    if reply is None:
        failed.append("get")
    elif reply[0] == 200 and isinstance(reply[1], dict):
        absorb("get", reply[1])
    for key, url in lrclib_search_urls(track).items():
        if key in failed_searches:
            continue
        reply = common.fetch_json(url, root, offline=offline)
        if reply is None:
            failed.append(key)
        elif reply[0] == 200 and isinstance(reply[1], list):
            for row in reply[1]:
                absorb(key, row)
    return rows, sources, failed


# --------------------------------------------------------------------------
# Variants
# --------------------------------------------------------------------------

_FEAT_BRACKET_RE = re.compile(r"^\s*(?:feat|ft|featuring)\b\.?\s*(?P<names>.+?)\s*$", re.IGNORECASE)
_EDITION_RULES = [(name, re.compile(rx, re.IGNORECASE), template)
                  for name, (rx, template) in SPOTIFY_STYLE["editions"].items()]


def _is_edition_text(text: str) -> bool:
    return any(rx.search(text) for _, rx, _ in _EDITION_RULES)


def edition_parts(title: str) -> List[str]:
    """Bracket contents and " - …" tails of a title: where editions are named,
    and the only place "live" means an edition rather than a word of the title
    ("Live Forever")."""
    parts: List[str] = []

    def note(inner, whole):
        parts.append(inner)
        return None

    oracle.replace_brackets(unicodedata.normalize("NFKC", title), note)
    segments = re.split(r"\s[-–—]\s", title)
    parts.extend(segments[1:])
    return parts


def strip_editions(title: str) -> str:
    """The title without edition or feat. brackets and edition tails; other
    parentheticals stay."""
    def decide(inner, whole):
        if _is_edition_text(inner) or _FEAT_BRACKET_RE.match(inner):
            return " "
        return None

    text = oracle.replace_brackets(title, decide)
    while True:
        head, sep, tail = re.sub(r"\s[–—]\s", " - ", text).rpartition(" - ")
        if sep and head.strip() and (_is_edition_text(tail) or _FEAT_BRACKET_RE.match(tail)):
            text = head
        else:
            break
    return " ".join(text.split()) or title


def featured_from_title(title: str) -> List[str]:
    names: List[str] = []

    def note(inner, whole):
        match = _FEAT_BRACKET_RE.match(inner)
        if match:
            names.extend(n.strip() for n in re.split(r",|&|\band\b", match.group("names")) if n.strip())
        return None

    oracle.replace_brackets(title, note)
    return names


def spotify_title(track: dict, apple: Optional[dict], deezer: Optional[dict]) -> str:
    """The title as Spotify spells it: base title, " - <Edition>", " (feat. …)"."""
    sources = [track["title"]]
    if apple:
        sources.append(apple["trackName"])
    if deezer:
        sources += [deezer["title"], deezer.get("title_version") or ""]
    edition_text = " | ".join(part for s in sources for part in edition_parts(s))
    # Deezer's title_version is an edition by itself, with no bracket around it.
    if deezer and deezer.get("title_version"):
        edition_text += " | " + deezer["title_version"]
    suffix = ""
    for _, rx, template in _EDITION_RULES:
        match = rx.search(edition_text)
        if match:
            year = match.groupdict().get("year") or ""
            suffix = template.format(year=year).rstrip()
            break
    title = strip_editions(track["title"]) + suffix
    names = track["featured"] or featured_from_title(track["title"])
    if names:
        title += SPOTIFY_STYLE["feat"].format(names=SPOTIFY_STYLE["feat_joiner"].join(names))
    return title


def canonical_album(track: dict, apple: Optional[dict], deezer: Optional[dict]) -> str:
    """The harvest album, else Apple's collectionName, else Deezer's album.

    149 harvested tracks have no album; leaving the canonical variant without
    one would fold the album-less request into the canonical figures, which the
    `no-album` variant exists to measure separately (SPEC amendment).
    """
    return track["album"] or (apple or {}).get("collectionName") or (deezer or {}).get("album") or ""


def build_variants(track: dict, apple: Optional[dict], deezer: Optional[dict],
                   apple_us: Optional[dict] = None) -> List[dict]:
    """The identities to look up, up to seven (SPEC step 7 and its amendment)."""
    apple_duration = apple["duration"] if apple else 0
    deezer_duration = deezer["duration"] if deezer else 0
    fallback = apple_duration or deezer_duration or 0
    joiner = SPOTIFY_STYLE["artist_joiner"]
    album = canonical_album(track, apple, deezer)

    def line(variant, title, artist, album_, duration):
        return {"track_id": track["track_id"], "slice": track["slice"], "variant": variant,
                "player_id": PLAYER_IDS[variant], "title": title, "artist": artist,
                "album": album_, "duration": duration}

    canonical_artist = ", ".join(track["artists"])
    variants = [line("canonical", track["title"], canonical_artist, album, fallback)]
    if track["index"] % NO_ALBUM_EVERY == 0:
        variants.append(line("no-album", track["title"], canonical_artist, "", fallback))
    if apple:
        variants.append(line("apple", apple["trackName"], apple["artistName"],
                             apple["collectionName"], apple_duration))
    if apple_us:
        variants.append(line("apple-us", apple_us["trackName"], apple_us["artistName"],
                             apple_us["collectionName"], apple_us["duration"]))
    if deezer:
        variants.append(line("deezer", deezer["title"], deezer["artist"], deezer["album"], deezer_duration))
    # "All credited artists" (SPEC table) includes the featured ones: Spotify's
    # own API lists a featured artist among the track's artists, so leaving
    # them out made the exact query's artist easier to match than Spotify's
    # metadata is (adversarial review, 2026-10-15).
    featured = track["featured"] or featured_from_title(track["title"])
    credited = list(track["artists"]) + [name for name in featured if name not in track["artists"]]
    variants.append(line("spotify-style", spotify_title(track, apple, deezer),
                         joiner.join(credited), album, fallback))
    # latin-alt is limited to Latin forms the harvest gave. The BGN/PCGN
    # aliases are guesses about spelling and must not become a request Isla is
    # blamed for.
    latin_title, _, _ = latin_forms(track)
    latin_artists = [latin or native for latin, native in zip(track["artists_latin"], track["artists"])]
    if latin_title != track["title"] or latin_artists != track["artists"]:
        variants.append(line("latin-alt", latin_title, ", ".join(latin_artists), album, fallback))
    return variants


# --------------------------------------------------------------------------
# Truth
# --------------------------------------------------------------------------

def truth_for(track: dict, variants: List[dict], candidates: List[dict], result: dict) -> dict:
    """The `truth` object of a tracks.jsonl line.

    `candidates` carry has_synced / has_plain / duration / last_stamp /
    instrumental / anchor / identity; `result` is oracle.cluster's answer.
    """
    notes = list(result["notes"])
    by_id = {c["id"]: c for c in candidates}
    anchors = [a for a in result["anchor_ids"] if a in by_id]
    lyric_anchors = [a for a in anchors if not by_id[a]["instrumental"] and by_id[a]["_has_text"]]
    instrumental_anchors = [a for a in anchors if by_id[a]["instrumental"]]
    harvest_none = track["vocal"] == "none"
    # Expected instrumental: the harvest says so, or LRCLIB has anchors and not
    # one of them has words. One stray instrumental flag among records with
    # lyrics is a mislabelled record, not a verdict on the song.
    expected = harvest_none or bool(anchors and not lyric_anchors)
    disagreement = None
    if harvest_none and lyric_anchors:
        disagreement = "harvest-none-lrclib-lyrics"
    elif not harvest_none and anchors and not lyric_anchors:
        disagreement = "harvest-vocal-lrclib-instrumental"
    elif lyric_anchors and instrumental_anchors:
        disagreement = "mixed-anchor-flags"
    status = "instrumental" if expected else result["truth_status"]
    members = [by_id[i] for i in result["cluster_ids"] if i in by_id]

    per_variant = {}
    for variant in variants:
        duration = variant["duration"]
        fit, near = [], []
        if status == "ok" and duration > 0:
            for c in members:
                if not c["has_synced"]:
                    continue
                delta = round(abs(c["duration"] - duration), 3)
                if delta <= FIT_TOLERANCE and c["last_stamp"] is not None \
                        and c["last_stamp"] <= duration + FIT_TOLERANCE:
                    fit.append((delta, c["id"]))
                elif FIT_TOLERANCE < delta <= NEAR_TOLERANCE:
                    near.append((delta, c["id"]))
        elif status == "ok":
            notes.append(f"no-duration:{variant['variant']}")
        per_variant[variant["variant"]] = {
            "duration": duration,
            "synced_fit": [i for _, i in sorted(fit)],
            "synced_near": [i for _, i in sorted(near)],
        }
    plain_only = bool(members) and status == "ok" and not any(c["has_synced"] for c in members) \
        and any(c["has_plain"] for c in members)
    return {
        "truth_status": status,
        "cluster_ids": result["cluster_ids"],
        "alt_script_ids": result["alt_script_ids"],
        "instrumental_expected": expected,
        "instrumental_disagreement": disagreement,
        "plain_only": plain_only,
        "per_variant": per_variant,
        "notes": notes,
    }


def analyze_track(track: dict, apple: Optional[dict], deezer: Optional[dict], root: str,
                  offline: bool, failed_searches: List[str], apple_us: Optional[dict] = None):
    """Stage B for one track: /api/get, the candidate pool, the oracle.

    Returns (tracks.jsonl line, variants, wordtimed [(row, in_cluster)]).
    """
    variants = build_variants(track, apple, deezer, apple_us)
    duration = (apple or {}).get("duration") or (deezer or {}).get("duration") or 0
    get_url = lrclib_get_url(track, duration, canonical_album(track, apple, deezer))
    rows, sources, failed = collect_rows(track, root, offline, get_url, failed_searches)

    titles = identity_titles(track, apple, deezer, apple_us)
    artists = identity_artists(track, apple, deezer, apple_us)
    analyzed = {}
    for rid, row in rows.items():
        info = oracle.analyze_record(row)
        info["identity"] = oracle.title_match(titles, row.get("trackName") or "") and \
            oracle.artist_match(artists, row.get("artistName") or "")
        analyzed[rid] = info
    # The instrumental flag trumps any placeholder text a record carries.
    pool = [{"id": rid, "fp": frozenset() if i["instrumental"] else i["fp"], "script": i["script"],
             "instrumental": i["instrumental"]} for rid, i in analyzed.items()]
    anchors = [rid for rid, i in analyzed.items() if i["identity"]]
    prefer = oracle.expected_script(track["language"], track["title"])
    result = oracle.cluster(pool, anchors, prefer_script=prefer, threshold=CLUSTER_THRESHOLD)

    candidates = []
    for rid in sorted(rows):
        row, info = rows[rid], analyzed[rid]
        candidates.append({
            "id": rid,
            "trackName": row.get("trackName") or "",
            "artistName": row.get("artistName") or "",
            "albumName": row.get("albumName") or "",
            "duration": row.get("duration") or 0,
            "instrumental": info["instrumental"],
            "has_synced": info["has_synced"],
            "has_plain": info["has_plain"],
            "word_timing": info["word_timing"],
            "last_stamp": info["last_stamp"],
            "anchor": rid in result["anchor_ids"],
            "identity": info["identity"],
            "containment": result["containment"].get(rid),
            "script": info["script"],
            "source_queries": sources[rid],
            "_has_text": bool(info["fp"]),
        })
    truth = truth_for(track, variants, candidates, result)
    if failed:
        truth["notes"].append("lrclib-unanswered:" + ",".join(sorted(set(failed))))
    urls = dict(lrclib_search_urls(track))
    urls["get"] = get_url
    line = {
        "track_id": track["track_id"], "slice": track["slice"], "index": track["index"],
        "harvest": {k: v for k, v in track.items() if k not in ("track_id", "slice", "index")},
        "apple": apple, "apple_us": apple_us, "deezer": deezer,
        "candidates": [{k: v for k, v in c.items() if k != "_has_text"} for c in candidates],
        "truth": truth,
        "lrclib_urls": urls,
        "lrclib_unanswered": sorted(set(failed)),
    }
    in_cluster = set(result["cluster_ids"])
    wordtimed = [(rows[c["id"]], c["id"] in in_cluster) for c in candidates if c["word_timing"]]
    return line, variants, wordtimed


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

def write_json(path: str, data) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)


def write_jsonl(path: str, rows: List[dict]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=False) + "\n")
    os.replace(tmp, path)


def read_jsonl(path: str) -> List[dict]:
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def merge_rows(path: str, fresh: List[dict], replaced_slices, replace_all: bool) -> List[dict]:
    """Fresh lines, plus the old lines of slices this run did not touch."""
    kept = [] if replace_all else [r for r in read_jsonl(path) if r.get("slice") not in replaced_slices]
    return kept + fresh


def write_wordtimed(root: str, track: dict, rows) -> int:
    count = 0
    for row, same_song in rows:
        path = os.path.join(root, "wordtimed", track["slice"], f"{row['id']}.json")
        record = dict(row)
        previous = None
        if os.path.exists(path):
            try:
                with open(path, encoding="utf-8") as handle:
                    previous = json.load(handle)
            except (OSError, ValueError):
                previous = None
        ids = [track["track_id"]]
        # One record can be a candidate of two tracks (a cover, a duplicate
        # title); keep every owner instead of letting the last write win.
        if previous and previous.get("track_id") != track["track_id"]:
            ids = list(dict.fromkeys((previous.get("track_ids") or [previous.get("track_id")]) + ids))
            same_song = bool(same_song or previous.get("same_song"))
        record.update({"track_id": ids[0], "track_ids": ids, "same_song": same_song})
        write_json(path, record)
        count += 1
    return count


def distribution(sizes: List[int]) -> Dict[str, int]:
    out: Dict[str, int] = {}
    for size in sizes:
        key = str(size) if size < 5 else "5+"
        out[key] = out.get(key, 0) + 1
    return dict(sorted(out.items()))


def summarize(tracks: List[dict], dropped: List[dict]) -> dict:
    """Counts per slice, then overall, from the final line sets."""
    slices: Dict[str, dict] = {}

    def bucket(slice_id: str) -> dict:
        return slices.setdefault(slice_id, {
            "harvested": 0, "resolved": 0, "dropped": 0, "apple_found": 0, "deezer_found": 0,
            "lrclib_candidates": 0, "lrclib_candidates_per_track_max": 0,
            "cluster_sizes": [], "synced_fit_available": {}, "plain_only": 0, "no_anchor": 0,
            "instrumental_expected": 0, "instrumental_disagreements": {}, "duplicates": 0,
            "word_timed_records": 0, "word_timed_same_song": 0, "tracks_with_word_timing": 0,
            "lrclib_unanswered_tracks": 0, "alt_script_tracks": 0, "anchor_conflicts": 0,
        })

    for row in dropped:
        b = bucket(row["slice"])
        b["harvested"] += 1
        b["dropped"] += 1
        b["duplicates"] += 1 if row.get("reason") == "duplicate" else 0
    for row in tracks:
        b = bucket(row["slice"])
        b["harvested"] += 1
        b["resolved"] += 1
        b["apple_found"] += 1 if row["apple"] else 0
        b["deezer_found"] += 1 if row["deezer"] else 0
        cands = row["candidates"]
        truth = row["truth"]
        b["lrclib_candidates"] += len(cands)
        b["lrclib_candidates_per_track_max"] = max(b["lrclib_candidates_per_track_max"], len(cands))
        b["cluster_sizes"].append(len(truth["cluster_ids"]))
        for variant, data in truth["per_variant"].items():
            counter = b["synced_fit_available"].setdefault(variant, {"tracks": 0, "with_synced_fit": 0})
            counter["tracks"] += 1
            counter["with_synced_fit"] += 1 if data["synced_fit"] else 0
        b["plain_only"] += 1 if truth["plain_only"] else 0
        b["no_anchor"] += 1 if truth["truth_status"] == "no-anchor" else 0
        b["instrumental_expected"] += 1 if truth["instrumental_expected"] else 0
        if truth["instrumental_disagreement"]:
            kind = truth["instrumental_disagreement"]
            b["instrumental_disagreements"][kind] = b["instrumental_disagreements"].get(kind, 0) + 1
        timed = [c for c in cands if c["word_timing"]]
        b["word_timed_records"] += len(timed)
        b["word_timed_same_song"] += sum(1 for c in timed if c["id"] in truth["cluster_ids"])
        b["tracks_with_word_timing"] += 1 if timed else 0
        b["lrclib_unanswered_tracks"] += 1 if row.get("lrclib_unanswered") else 0
        b["alt_script_tracks"] += 1 if truth["alt_script_ids"] else 0
        b["anchor_conflicts"] += 1 if "anchor-conflict" in truth["notes"] else 0
    total = {"disagreement_kinds": {}}
    for slice_id, b in slices.items():
        b["cluster_size_distribution"] = distribution(b.pop("cluster_sizes"))
    numeric = ["harvested", "resolved", "dropped", "duplicates", "apple_found", "deezer_found", "lrclib_candidates",
               "plain_only", "no_anchor", "instrumental_expected", "word_timed_records",
               "word_timed_same_song", "tracks_with_word_timing", "lrclib_unanswered_tracks",
               "alt_script_tracks", "anchor_conflicts"]
    for key in numeric:
        total[key] = sum(b[key] for b in slices.values())
    fit: Dict[str, dict] = {}
    for b in slices.values():
        for variant, counter in b["synced_fit_available"].items():
            agg = fit.setdefault(variant, {"tracks": 0, "with_synced_fit": 0})
            agg["tracks"] += counter["tracks"]
            agg["with_synced_fit"] += counter["with_synced_fit"]
        for kind, n in b["instrumental_disagreements"].items():
            total["disagreement_kinds"][kind] = total["disagreement_kinds"].get(kind, 0) + n
    total["synced_fit_available"] = fit
    total["cluster_size_distribution"] = distribution(
        [len(r["truth"]["cluster_ids"]) for r in tracks])
    return {"slices": dict(sorted(slices.items())), "total": total}


# --------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------

_print_lock = threading.Lock()


def progress(label: str, done: int, total: int) -> None:
    if done % 25 == 0 or done == total:
        with _print_lock:
            print(f"[{label}] {done}/{total}", flush=True)


STAGE_A_JOBS = ("itunes", "deezer", "lrclib")


def stage_a(tracks: List[dict], root: str, offline: bool, only: Optional[List[str]] = None):
    """iTunes, Deezer and the LRCLIB searches, one thread each; `only` runs a
    subset (--warm), whose stores the others then lack."""
    stores = {"itunes": {}, "deezer": {}, "lrclib": {}}
    jobs = {"itunes": resolve_apple, "deezer": resolve_deezer, "lrclib": prefetch_lrclib}

    def work(name: str):
        for done, track in enumerate(tracks, 1):
            try:
                stores[name][track["track_id"]] = jobs[name](track, root, offline)
            except Exception as error:  # one bad track must not end a 480-track run
                stores[name][track["track_id"]] = {"status": "error", "error": repr(error),
                                                   "failed": ["exception"], "apple": None, "deezer": None}
                with _print_lock:
                    print(f"[{name}] {track['track_id']}: {error!r}", flush=True)
            progress(name, done, len(tracks))

    names = [n for n in STAGE_A_JOBS if only is None or n in only]
    threads = [threading.Thread(target=work, args=(n,), name=n, daemon=True) for n in names]
    for t in threads:
        t.start()
    for t in threads:
        while t.is_alive():
            t.join(0.5)
    return stores


def duplicate_key(track: dict):
    primary = track["artists"][0] if track["artists"] else ""
    # normalize_text, not normalize_title: the edge-metadata slice deliberately
    # holds "Wonderwall - Remastered" next to "Wonderwall", and stripping
    # editions here would drop those stress picks as duplicates.
    return oracle.normalize_text(track["title"]), oracle.normalize_artist(primary)


def split_duplicates(tracks: List[dict]):
    """(kept, dropped lines): a track whose normalized title and primary artist
    repeat an earlier one is dropped as `duplicate` before any request is spent
    on it (SPEC amendment). "Earlier" is harvest order across the slices of
    this run, so a --slices subset only sees its own repeats."""
    seen: Dict[tuple, str] = {}
    kept: List[dict] = []
    dropped: List[dict] = []
    for track in tracks:
        key = duplicate_key(track)
        if key[0] and key in seen:
            dropped.append({"track_id": track["track_id"], "slice": track["slice"], "index": track["index"],
                            "title": track["title"], "artists": track["artists"],
                            "reason": "duplicate", "duplicate_of": seen[key]})
            continue
        seen.setdefault(key, track["track_id"])
        kept.append(track)
    return kept, dropped


def drop_reason(apple_result: dict, deezer_result: dict) -> str:
    def describe(name: str, result: dict) -> str:
        status = result.get("status")
        if status == "failed":
            return f"{name}: no answer ({'uncached' if result.get('unanswered') else 'failed'})"
        if status == "error":
            return f"{name}: error"
        suffix = f", {result['unanswered']} of {result['queries']} queries unanswered" \
            if result.get("unanswered") else ""
        return f"{name}: no title and artist match in {result.get('queries', 0)} queries{suffix}"

    return "; ".join([describe("itunes", apple_result), describe("deezer", deezer_result)])


def run(root: str, slices: Optional[List[str]] = None, limit: Optional[int] = None,
        offline: bool = False, warm: Optional[List[str]] = None) -> dict:
    root = os.path.expanduser(root)
    loaded = load_slices(root, slices, limit)
    if not loaded:
        print(f"no slices to resolve under {root}/slices", flush=True)
    everything = [t for _, ts in loaded for t in ts]
    tracks, dropped = split_duplicates(everything)
    started = time.time()
    print(f"resolving {len(tracks)} tracks from {len(loaded)} slice(s)"
          f"{' (offline)' if offline else ''}; {len(dropped)} duplicate(s) dropped", flush=True)
    if warm:
        # Fills the cache for the named hosts and stops: stage B needs every
        # host, so nothing is resolved or written. A full run afterwards reads
        # these answers back from the cache.
        stage_a(tracks, root, offline, warm)
        stats = common.STATS
        print(f"warmed {','.join(warm)} in {time.time() - started:.0f}s: live requests {stats.live} "
              f"{dict(stats.by_host)}, cache hits {stats.cache_hits}, failed {stats.failures}, "
              f"throttled {dict(stats.throttles)}", flush=True)
        return {}
    stores = stage_a(tracks, root, offline) if tracks else {"itunes": {}, "deezer": {}, "lrclib": {}}

    lines: List[dict] = []
    variant_lines: List[dict] = []
    wordtimed_count = 0
    for done, track in enumerate(tracks, 1):
        tid = track["track_id"]
        apple_result = stores["itunes"].get(tid) or {"status": "error"}
        deezer_result = stores["deezer"].get(tid) or {"status": "error"}
        apple, deezer = apple_result.get("apple"), deezer_result.get("deezer")
        if not apple and not deezer:
            dropped.append({"track_id": tid, "slice": track["slice"], "index": track["index"],
                            "title": track["title"], "artists": track["artists"],
                            "reason": drop_reason(apple_result, deezer_result)})
        else:
            try:
                failed = (stores["lrclib"].get(tid) or {}).get("failed") or []
                line, variants, timed = analyze_track(track, apple, deezer, root, offline, failed,
                                                      apple_result.get("apple_us"))
                if apple_result.get("apple_us_status") == "unanswered":
                    line["truth"]["notes"].append("apple-us-unanswered")
                lines.append(line)
                variant_lines.extend(variants)
                wordtimed_count += write_wordtimed(root, track, timed)
            except Exception as error:
                dropped.append({"track_id": tid, "slice": track["slice"], "index": track["index"],
                                "title": track["title"], "artists": track["artists"],
                                "reason": f"resolver error: {error!r}"})
                with _print_lock:
                    print(f"[resolve] {tid}: {error!r}", flush=True)
        progress("resolve", done, len(tracks))

    touched = {sid for sid, _ in loaded}
    replace_all = slices is None
    out = os.path.join(root, "resolved")
    all_tracks = merge_rows(os.path.join(out, "tracks.jsonl"), lines, touched, replace_all)
    all_dropped = merge_rows(os.path.join(out, "dropped.jsonl"), dropped, touched, replace_all)
    all_variants = merge_rows(os.path.join(out, "variants.jsonl"), variant_lines, touched, replace_all)
    write_jsonl(os.path.join(out, "tracks.jsonl"), all_tracks)
    write_jsonl(os.path.join(out, "dropped.jsonl"), all_dropped)
    write_jsonl(os.path.join(out, "variants.jsonl"), all_variants)
    summary = summarize(all_tracks, all_dropped)
    write_json(os.path.join(out, "summary.json"), summary)

    stats = common.STATS
    print(f"done in {time.time() - started:.0f}s: {len(lines)} resolved, {len(dropped)} dropped, "
          f"{len(variant_lines)} variants, {wordtimed_count} word-timed records written; "
          f"live requests {stats.live} {dict(stats.by_host)}, cache hits {stats.cache_hits}, "
          f"failed {stats.failures}, throttled {dict(stats.throttles)}", flush=True)
    return summary


def apply_gaps(overrides: List[str]) -> None:
    """--gap KEY=SECONDS: a host (`itunes.apple.com`) or an endpoint
    (`lrclib.net/api/search`). Only ever slower than the SPEC's gap, which is
    a floor, not a suggestion."""
    for item in overrides:
        key, _, value = item.partition("=")
        seconds = float(value)
        table = common.ENDPOINT_GAPS if "/" in key else common.HOST_GAPS
        floor = table.get(key, common.HOST_GAPS.get(key.split("/")[0], common.DEFAULT_GAP))
        if seconds < floor:
            raise SystemExit(f"--gap {item}: below the SPEC's {floor} s for {key}")
        table[key] = seconds


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Resolve harvested tracks for the lyrics match lab.")
    parser.add_argument("--root", default=DEFAULT_ROOT)
    parser.add_argument("--slices", help="comma list of slice ids or file names")
    parser.add_argument("--limit", type=int, help="at most N tracks per slice")
    parser.add_argument("--offline", action="store_true", help="cache only, never the network")
    parser.add_argument("--check-harvest", action="store_true",
                        help="validate the slice files and print anomalies; no network, writes nothing")
    parser.add_argument("--warm", help="comma list of stage A jobs (itunes, deezer, lrclib) to run alone: "
                        "fills the cache, resolves nothing, writes no outputs")
    parser.add_argument("--gap", action="append", default=[], metavar="KEY=SECONDS",
                        help="slow a host or endpoint down, e.g. lrclib.net/api/search=12 (repeatable)")
    args = parser.parse_args(argv)
    apply_gaps(args.gap)
    warm = [w.strip() for w in args.warm.split(",") if w.strip()] if args.warm else None
    if warm and not set(warm) <= set(STAGE_A_JOBS):
        parser.error(f"--warm takes {', '.join(STAGE_A_JOBS)}")
    only = [s.strip() for s in args.slices.split(",") if s.strip()] if args.slices else None
    if args.check_harvest:
        report = check_harvest(args.root, only)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0
    run(args.root, only, args.limit, args.offline, warm)
    return 0


if __name__ == "__main__":
    sys.exit(main())
