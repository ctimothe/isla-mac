#!/usr/bin/env python3
"""An offline stand-in for LRCLIB, "the twin": LRCLIB's own matching rules (its
open-source server, downloaded 2026-10-15) applied to the answers LRCLIB has
already given the lab.

    python3 twin.py validate --root <root>
    python3 twin.py prepare  --root <root> [--twin twin] [--fresh]
    python3 twin.py fill     --root <root> [--twin twin] [--results results]
    python3 twin.py tiers    --root <root> [--twin twin] [--results results] [--reports reports]

Why it exists. From 2026-10-15 LRCLIB answers this address about once per half
hour (SPEC, "a ban is not a rate"), so Isla's lookups cannot be recorded live
and a candidate fix cannot be scored at all. The twin answers the requests Isla
would make from what LRCLIB has already said, and says how sure it is.

How it answers, never touching the network:

  /api/search  The real cached page when the same query was asked, after
               LRCLIB's own normalisation, so two spellings of one query are
               one query. Otherwise the rows of a cached page that covers the
               query, filtered by the query's constraints. LRCLIB's search
               makes the filter exact: track and artist are phrases, AND-ed,
               and `q` is every token in any column (search_index/query.rs),
               so a query whose phrases contain a page's phrases can only
               match a subset of that page's records.
  /api/get     The rule in track_repository.rs:147-217 over every record seen:
               name, artist and, when sent, album equal after prepare_input,
               duration within 2 s, and the oldest track id wins.

Tiers, from most to least sure. Every answer `fill` writes is listed in
twin-answers.jsonl with its tier.

  real      LRCLIB's own answer to this query
  complete  a covering page has fewer than 20 rows, so LRCLIB returned every
            record the query can match
  ranked    get only: a full page for the same title and artist whose last
            row is not an exact title-and-artist match, on the theory that
            exact matches outscore longer titles
  partial   only full pages cover the query
  unknown   nothing seen covers the query

Only `real` and `complete` are served. The validation (2026-10-15) found the
other two wrong too often to stand in for LRCLIB: in 5 of 7 cached gets that
found a record, the record was an old upload on neither full page that
covered the query, so a page cut at row 20 says little about what lies past
it. An unserved answer is still listed with what it would have said, but the
harness reads a miss and the lookup is `uncached`, never a guess.

Known gaps. The Unicode versions differ: Python's, Perl's 13 behind the
tokenizer's marks, and the server's Rust. A derived page keeps the covering
page's row order, which approximates BM25's. Production
LRCLIB may differ from its open-source code; its rate limiter is not in it.

Where it writes. `prepare` makes <root>/<twin>/ with a TWIN marker, a copy of
the real cache, the slices and the oracle's calibration. `resolve.py --offline
--root <root>/<twin>` then writes that root's own resolved/. `fill` writes the
twin's answers into the copy only, so the real cache never holds a guess, and
a replay of the twin root needs no server and no network. The Swift harness
reads the twin root like any other root (ISLA_MATCH_LAB), in replay mode. Each
round logs the requests no file answers; `fill` answers those it can, and the
next round goes one request further (the get, then the searches).

Nothing printed carries a lyric line. The twin root holds lyric text, so it
lives under the corpus root.
"""
from __future__ import annotations

import argparse
import base64
import collections
import csv
import datetime
import json
import os
import shutil
import sys
import urllib.parse
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import common  # noqa: E402

HOST = "lrclib.net"
ORIGIN = "https://lrclib.net"
PAGE_SIZE = 20        # search_index.rs:21, TopDocs::with_limit(20)
GET_WINDOW = 2.0      # track_repository.rs:184-189, duration ± 2.0
MARKER = "TWIN"
MANIFEST = "twin-answers.jsonl"
TIER_ORDER = ("real", "complete", "ranked", "partial", "unknown")
SERVED = ("real", "complete")   # the only tiers written into the twin root's cache
NOT_FOUND = json.dumps({"code": 404, "name": "TrackNotFound",
                        "message": "Failed to find specified track"}).encode("utf-8")
DEFAULT_ROOT = os.path.expanduser("~/code/_tools/isla-lyrics-lab")

# utils.rs:10-27
TO_SPACE = set("`~!@#$%^&*()_|+-=?;:\",.<>{}[]\\/\x00\n")
TO_REMOVE = ("'", "’")

# secular 1.0.1's lower_lay_string, which prepare_input starts with. Its table
# comes from the `sm` list in the crate's generate.js, the classic diacritics
# map: a Latin letter with a mark, a stroke or a hook maps to its base letter,
# and so do the circled and fullwidth forms. The generator skips multi-letter
# bases, so æ, œ, ǆ and the like stay as they are, and every other character is
# only lowercased: Cyrillic й and ё and Greek accents keep their marks, and a
# decomposed mark stays a separate character. (2026-10-15: an NFKD shortcut
# here stripped й and missed ı -> i; the validation caught the second.)
LAY_LISTS = {
    "a": "ⓐａẚàáâầấẫẩãāăằắẵẳȧǡäǟảåǻǎȁȃạậặḁąⱥɐ", "b": "ⓑｂḃḅḇƀƃɓ",
    "c": "ⓒｃćĉċčçḉƈȼꜿↄ", "d": "ⓓｄḋďḍḑḓḏđƌɖɗꝺ",
    "e": "ⓔｅèéêềếễểẽēḕḗĕėëẻěȅȇẹệȩḝęḙḛɇɛǝ", "f": "ⓕｆḟƒꝼ",
    "g": "ⓖｇǵĝḡğġǧģǥɠꞡᵹꝿ", "h": "ⓗｈĥḣḧȟḥḩḫẖħⱨⱶɥ",
    "i": "ⓘｉìíîĩīĭİïḯỉǐȉȋịįḭɨı", "j": "ⓙｊĵǰɉ", "k": "ⓚｋḱǩḳķḵƙⱪꝁꝃꝅꞣ",
    "l": "ⓛｌŀĺľḷḹļḽḻſłƚɫⱡꝉꞁꝇ", "m": "ⓜｍḿṁṃɱɯ", "n": "ⓝｎǹńñṅňṇņṋṉƞɲŉꞑꞥ",
    "o": "ⓞｏòóôồốỗổõṍȭṏōṑṓŏȯȱöȫỏőǒȍȏơờớỡởợọộǫǭøǿɔꝋꝍɵ", "p": "ⓟｐṕṗƥᵽꝑꝓꝕ",
    "q": "ⓠｑɋꝗꝙ", "r": "ⓡｒŕṙřȑȓṛṝŗṟɍɽꝛꞧꞃ", "s": "ⓢｓßśṥŝṡšṧṣṩșşȿꞩꞅẛ",
    "t": "ⓣｔṫẗťṭțţṱṯŧƭʈⱦꞇ", "u": "ⓤｕùúûũṹūṻŭüǜǘǖǚủůűǔȕȗưừứữửựụṳųṷṵʉ",
    "v": "ⓥｖṽṿʋꝟʌ", "w": "ⓦｗẁẃŵẇẅẘẉⱳ", "x": "ⓧｘẋẍ", "y": "ⓨｙỳýŷỹȳẏÿỷẙỵƴɏỿ",
    "z": "ⓩｚźẑżžẓẕƶȥɀⱬꝣ",
}
LAY = {letter: base for base, letters in LAY_LISTS.items() for letter in letters}

# Tantivy's SimpleTokenizer keeps runs of `char::is_alphanumeric`: the
# Alphabetic property, which takes in the vowel signs of Indic, Arabic, Hebrew
# and Thai script, or a Numeric category. str.isalnum misses those marks, so
# these are the BMP combining marks (Mn, Mc) that are Alphabetic, from Perl's
# Unicode 13 tables (`chr($c) =~ /\p{Mn}|\p{Mc}/ && chr($c) =~ /\p{Alphabetic}/`).
# A virama (U+094D) is not among them, so it splits a word, as in Tantivy.
ALPHABETIC_MARK_RANGES = """
    345 5B0-5BD 5BF 5C1-5C2 5C4-5C5 5C7 610-61A 64B-657 659-65F 670 6D6-6DC 6E1-6E4 6E7-6E8
    6ED 711 730-73F 7A6-7B0 816-817 81B-823 825-827 829-82C 8D4-8DF 8E3-8E9 8F0-903 93A-93B
    93E-94C 94E-94F 955-957 962-963 981-983 9BE-9C4 9C7-9C8 9CB-9CC 9D7 9E2-9E3 A01-A03
    A3E-A42 A47-A48 A4B-A4C A51 A70-A71 A75 A81-A83 ABE-AC5 AC7-AC9 ACB-ACC AE2-AE3 AFA-AFC
    B01-B03 B3E-B44 B47-B48 B4B-B4C B56-B57 B62-B63 B82 BBE-BC2 BC6-BC8 BCA-BCC BD7 C00-C03
    C3E-C44 C46-C48 C4A-C4C C55-C56 C62-C63 C81-C83 CBE-CC4 CC6-CC8 CCA-CCC CD5-CD6 CE2-CE3
    D00-D03 D3E-D44 D46-D48 D4A-D4C D57 D62-D63 D81-D83 DCF-DD4 DD6 DD8-DDF DF2-DF3 E31
    E34-E3A E4D EB1 EB4-EB9 EBB-EBC ECD F71-F81 F8D-F97 F99-FBC 102B-1036 1038 103B-103E
    1056-1059 105E-1060 1062-1064 1067-106D 1071-1074 1082-108D 108F 109A-109D 1712-1713
    1732-1733 1752-1753 1772-1773 17B6-17C8 1885-1886 18A9 1920-192B 1930-1938 1A17-1A1B
    1A55-1A5E 1A61-1A74 1ABF-1AC0 1B00-1B04 1B35-1B43 1B80-1B82 1BA1-1BA9 1BAC-1BAD
    1BE7-1BF1 1C24-1C36 1DE7-1DF4 2DE0-2DFF A674-A67B A69E-A69F A802 A80B A823-A827
    A880-A881 A8B4-A8C3 A8C5 A8FF A926-A92A A947-A952 A980-A983 A9B4-A9BF A9E5 AA29-AA36
    AA43 AA4C-AA4D AA7B-AA7D AAB0 AAB2-AAB4 AAB7-AAB8 AABE AAEB-AAEF AAF5 ABE3-ABEA FB1E
"""


def _ranges(text: str) -> List[Tuple[int, int]]:
    out = []
    for item in text.split():
        low, _, high = item.partition("-")
        out.append((int(low, 16), int(high or low, 16)))
    return out


ALPHABETIC_MARKS = frozenset(c for low, high in _ranges(ALPHABETIC_MARK_RANGES) for c in range(low, high + 1))


# --------------------------------------------------------------------------
# LRCLIB's normalisation
# --------------------------------------------------------------------------

def prepare_input(text: Optional[str]) -> str:
    """prepare_input (utils.rs:21): lower_lay_string (LAY), the listed
    punctuation to spaces, apostrophes removed, lowercase, whitespace
    collapsed."""
    lay = "".join(LAY.get(c) or LAY.get(c.lower()) or c.lower() for c in text or "")
    spaced = "".join(" " if c in TO_SPACE else c for c in lay)
    for mark in TO_REMOVE:
        spaced = spaced.replace(mark, "")
    return " ".join(spaced.lower().split())


def process_param(value: Optional[str]) -> Optional[str]:
    """process_param (utils.rs:89): prepared, and None when nothing is left."""
    if value is None:
        return None
    return prepare_input(value) or None


def _token_char(c: str) -> bool:
    return c.isalnum() or ord(c) in ALPHABETIC_MARKS


def tokens(prepared: Optional[str]) -> Tuple[str, ...]:
    """Tantivy's SimpleTokenizer and LowerCaser over a prepared string."""
    out: List[str] = []
    current: List[str] = []
    for c in prepared or "":
        if _token_char(c):
            current.append(c)
        elif current:
            out.append("".join(current))
            current = []
    if current:
        out.append("".join(current))
    return tuple(t.lower() for t in out)


def contains_phrase(haystack: Sequence[str], phrase: Sequence[str]) -> bool:
    """Whether `phrase` appears in `haystack` as consecutive tokens. An empty
    phrase matches nothing, as an empty FTS5 phrase does (query.rs:66)."""
    n = len(phrase)
    if n == 0:
        return False
    target = tuple(phrase)
    return any(tuple(haystack[i:i + n]) == target for i in range(len(haystack) - n + 1))


FIELDS = ("name", "artist", "album")


def row_prepared(row: dict) -> Dict[str, str]:
    return {
        "name": prepare_input(row.get("trackName") or row.get("name")),
        "artist": prepare_input(row.get("artistName")),
        "album": prepare_input(row.get("albumName")),
    }


# --------------------------------------------------------------------------
# Queries and pages
# --------------------------------------------------------------------------

class Query:
    """A search or a get as LRCLIB reads it: parameters prepared, `+` decoded
    to a space as axum's Query does, and `q` winning over the fields."""

    def __init__(self, kind: str, fields: Dict[str, Optional[str]], q: Optional[str] = None,
                 duration: Optional[float] = None):
        self.kind = kind
        self.fields = fields
        self.q = q
        self.duration = duration

    def key(self) -> tuple:
        if self.kind == "search":
            if self.q:
                return ("search", "q", self.q)
            return ("search",) + tuple(self.fields.get(f) for f in FIELDS)
        return ("get",) + tuple(self.fields.get(f) for f in FIELDS) + (self.duration,)

    def constraints(self) -> Dict[str, Tuple[str, ...]]:
        return {f: tokens(v) for f, v in self.fields.items() if v is not None}


def parse(url: str) -> Optional[Query]:
    parts = urllib.parse.urlsplit(url)
    if (parts.hostname or "").lower() != HOST:
        return None
    params = urllib.parse.parse_qs(parts.query, keep_blank_values=True)

    def first(name: str) -> Optional[str]:
        values = params.get(name)
        return values[0] if values else None

    fields = {"name": process_param(first("track_name")),
              "artist": process_param(first("artist_name")),
              "album": process_param(first("album_name"))}
    if parts.path == "/api/search":
        return Query("search", fields, q=process_param(first("q")))
    if parts.path == "/api/get":
        raw = first("duration")
        try:
            duration = float(raw) if raw not in (None, "") else None
        except ValueError:
            duration = None
        return Query("get", fields, duration=duration)
    return None


class Page:
    """One cached search answer: its query and its rows in served order."""

    def __init__(self, query: Query, rows: List[dict]):
        self.query = query
        self.rows = rows
        self.complete = len(rows) < PAGE_SIZE


def covers(page: Page, query: Query) -> bool:
    """Whether every record `query` can match is also matched by the page's
    query, so the page holds them all when it is complete.

    A field query covers when each of the page's phrases is a consecutive run
    inside the query's value for the same field; a `q` page covers when each
    of its tokens is among the query's constrained tokens. A get's equality is
    stronger than a phrase, so the same test serves both. The twin answers a
    `q` search only from its own page (Isla never sends one)."""
    if query.kind == "search" and query.q:
        return False
    want = query.constraints()
    if page.query.q:
        have: Set[str] = set()
        for value in want.values():
            have.update(value)
        needed = tokens(page.query.q)
        return bool(needed) and all(t in have for t in needed)
    for field in FIELDS:
        phrase = page.query.fields.get(field)
        if phrase is None:
            continue
        value = want.get(field)
        if value is None or not contains_phrase(value, tokens(phrase)):
            return False
    return True


def matches_search(row: dict, query: Query) -> bool:
    prepared = row_prepared(row)
    return all(contains_phrase(tokens(prepared[f]), value) for f, value in query.constraints().items())


def matches_get(row: dict, query: Query) -> bool:
    prepared = row_prepared(row)
    if prepared["name"] != query.fields.get("name") or prepared["artist"] != query.fields.get("artist"):
        return False
    album = query.fields.get("album")
    if album is not None and prepared["album"] != album:
        return False
    if query.duration is not None:
        length = row.get("duration")
        if not isinstance(length, (int, float)):
            return False
        if not query.duration - GET_WINDOW <= length <= query.duration + GET_WINDOW:
            return False
    return True


def ids(rows: Iterable[dict]) -> List[int]:
    return [r["id"] for r in rows if isinstance(r, dict) and isinstance(r.get("id"), int)]


def _rows(body: bytes) -> Optional[list]:
    try:
        data = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    return data if isinstance(data, list) else None


def _object(body: bytes) -> Optional[dict]:
    try:
        data = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    return data if isinstance(data, dict) else None


# --------------------------------------------------------------------------
# The twin
# --------------------------------------------------------------------------

class Twin:
    def __init__(self):
        self.pages: Dict[tuple, Page] = {}
        self.gets: Dict[tuple, Tuple[int, bytes]] = {}
        self.records: Dict[int, dict] = {}

    def add(self, url: str, status: int, body: bytes, include_gets: bool = True) -> None:
        query = parse(url)
        if query is None:
            return
        if query.kind == "search":
            rows = _rows(body) if status == 200 else None
            if rows is None:
                return
            rows = [r for r in rows if isinstance(r, dict) and isinstance(r.get("id"), int)]
            self.pages.setdefault(query.key(), Page(query, rows))
            for row in rows:
                self.records.setdefault(row["id"], row)
        elif include_gets and status in (200, 404):
            self.gets.setdefault(query.key(), (status, body))
            obj = _object(body) if status == 200 else None
            if obj is not None and isinstance(obj.get("id"), int):
                self.records.setdefault(obj["id"], obj)

    @classmethod
    def from_entries(cls, entries: Iterable[Tuple[str, int, bytes]], include_gets: bool = True) -> "Twin":
        twin = cls()
        for url, status, body in entries:
            twin.add(url, status, body, include_gets)
        return twin

    # -- answers --------------------------------------------------------

    def answer(self, url: str) -> Tuple[str, Optional[int], Optional[bytes], List[int]]:
        """(tier, status, body, ids); status and body are None for `unknown`."""
        query = parse(url)
        if query is None:
            return "unknown", None, None, []
        if query.kind == "search":
            return self.search(query)
        return self.get(query)

    def search(self, query: Query) -> Tuple[str, Optional[int], Optional[bytes], List[int]]:
        page = self.pages.get(query.key())
        if page is not None:
            return "real", 200, json.dumps(page.rows).encode("utf-8"), ids(page.rows)
        if query.q or query.fields.get("name") is None:
            return "unknown", None, None, []
        covering = [p for p in self.pages.values() if covers(p, query)]
        if not covering:
            return "unknown", None, None, []
        complete = [p for p in covering if p.complete]
        source = complete[:1] if complete else covering
        seen: Set[int] = set()
        rows: List[dict] = []
        for p in source:
            for row in p.rows:
                if row["id"] not in seen and matches_search(row, query):
                    seen.add(row["id"])
                    rows.append(row)
        rows = rows[:PAGE_SIZE]
        return ("complete" if complete else "partial"), 200, json.dumps(rows).encode("utf-8"), ids(rows)

    def get_tier(self, query: Query) -> str:
        covering = [p for p in self.pages.values() if covers(p, query)]
        if not covering:
            return "unknown"
        if any(p.complete for p in covering):
            return "complete"
        name, artist = query.fields.get("name"), query.fields.get("artist")
        for p in covering:
            fields = p.query.fields
            if p.query.q or fields.get("album") is not None or not p.rows:
                continue
            if tokens(fields.get("name")) != tokens(name) or tokens(fields.get("artist")) != tokens(artist):
                continue
            last = row_prepared(p.rows[-1])
            if not (last["name"] == name and last["artist"] == artist):
                return "ranked"
        return "partial"

    def get(self, query: Query) -> Tuple[str, Optional[int], Optional[bytes], List[int]]:
        real = self.gets.get(query.key())
        if real is not None:
            status, body = real
            obj = _object(body) if status == 200 else None
            return "real", status, body, ids([obj] if obj else [])
        if query.fields.get("name") is None or query.fields.get("artist") is None:
            return "unknown", None, None, []
        tier = self.get_tier(query)
        if tier == "unknown":
            return "unknown", None, None, []
        candidates = [r for r in self.records.values() if matches_get(r, query)]
        if not candidates:
            return tier, 404, NOT_FOUND, []
        best = min(candidates, key=lambda r: r["id"])
        return tier, 200, json.dumps(best).encode("utf-8"), [best["id"]]


# --------------------------------------------------------------------------
# The cache
# --------------------------------------------------------------------------

def cache_entries(root: str, skip: Optional[Set[str]] = None) -> List[Tuple[str, int, bytes]]:
    """Every readable LRCLIB answer in <root>/cache/{py,isla}, sorted by file
    name so two runs over one cache build the same twin."""
    out = []
    for sub in ("py", "isla"):
        directory = os.path.join(root, "cache", sub)
        if not os.path.isdir(directory):
            continue
        for name in sorted(os.listdir(directory)):
            if not name.endswith(".json") or (skip and name[:-5] in skip):
                continue
            try:
                with open(os.path.join(directory, name), "r", encoding="utf-8") as handle:
                    entry = json.load(handle)
                url = entry["url"]
                if (urllib.parse.urlsplit(url).hostname or "").lower() != HOST:
                    continue
                out.append((url, int(entry["status"]), base64.b64decode(entry["body_b64"])))
            except (OSError, ValueError, KeyError, TypeError):
                continue
    return out


def read_manifest(twin_root: str) -> Dict[str, dict]:
    path = os.path.join(twin_root, MANIFEST)
    entries: Dict[str, dict] = {}
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line:
                    entry = json.loads(line)
                    entries[entry["key"]] = entry
    return entries


def require_twin(root: str, name: str) -> str:
    if not name or "/" in name or name.startswith((".", "_")):
        raise SystemExit(f"--twin must be a plain directory name, got {name!r}")
    twin_root = os.path.join(root, name)
    if not os.path.exists(os.path.join(twin_root, MARKER)):
        raise SystemExit(f"{twin_root} is not a twin root (no {MARKER} marker); run `twin.py prepare` first")
    return twin_root


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def validate(root: str) -> dict:
    """How often the twin, built from the cached search pages alone, gives
    LRCLIB's own answer.

    Gets: every cached /api/get answer is predicted from a twin that never saw
    a get answer. Pages: every cached field search is derived from a twin
    without that page (leave one out), and the row sets are compared."""
    entries = cache_entries(root)
    twin = Twin.from_entries(entries, include_gets=False)
    gets = collections.Counter()
    seen_urls: Set[str] = set()
    for url, status, body in entries:
        query = parse(url)
        if query is None or query.kind != "get" or status not in (200, 404) or url in seen_urls:
            continue
        seen_urls.add(url)
        tier, got_status, _, got_ids = twin.get(query)
        obj = _object(body) if status == 200 else None
        real_ids = ids([obj] if obj else [])
        if tier == "unknown":
            outcome = "unanswered"
        elif got_status == status and got_ids == real_ids:
            outcome = "agree"
        elif status == 200 and got_status == 404:
            outcome = "twin-404-lrclib-found"
        elif status == 404 and got_status == 200:
            outcome = "twin-found-lrclib-404"
        else:
            outcome = "other-record"
        gets[(tier, outcome)] += 1

    pages = collections.Counter()
    page_list = [(k, p) for k, p in twin.pages.items() if not p.query.q]
    for key, page in page_list:
        rest = Twin()
        for other_key, other in twin.pages.items():
            if other_key != key:
                rest.pages[other_key] = other
                for row in other.rows:
                    rest.records.setdefault(row["id"], row)
        tier, _, body, got_ids = rest.search(page.query)
        if tier == "unknown":
            pages[(tier, "unanswered")] += 1
            continue
        real, got = set(ids(page.rows)), set(got_ids)
        outcome = ("same" if real == got else "twin-subset" if got < real
                   else "twin-superset" if got > real else "differ")
        pages[(tier, outcome)] += 1

    def table(counter):
        return {f"{tier} {outcome}": n for (tier, outcome), n in sorted(counter.items())}

    summary = {
        "cache": {"lrclib_answers": len(entries), "search_pages": len(twin.pages),
                  "records": len(twin.records), "complete_pages": sum(p.complete for p in twin.pages.values())},
        "gets": table(gets),
        "pages_leave_one_out": table(pages),
    }
    out = os.path.join(root, "reports", "twin-validation.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2, sort_keys=True)
    return summary


def prepare(root: str, name: str = "twin", fresh: bool = False) -> str:
    if not name or "/" in name or name.startswith((".", "_")):
        raise SystemExit(f"--twin must be a plain directory name, got {name!r}")
    twin_root = os.path.join(root, name)
    if os.path.exists(twin_root):
        if not os.path.exists(os.path.join(twin_root, MARKER)):
            raise SystemExit(f"{twin_root} exists and is not a twin root; refusing to touch it")
        if not fresh:
            raise SystemExit(f"{twin_root} exists; pass --fresh to rebuild it from the real cache")
        shutil.rmtree(twin_root)
    os.makedirs(twin_root)
    for sub in ("py", "isla"):
        source = os.path.join(root, "cache", sub)
        if os.path.isdir(source):
            shutil.copytree(source, os.path.join(twin_root, "cache", sub))
    if os.path.isdir(os.path.join(root, "slices")):
        shutil.copytree(os.path.join(root, "slices"), os.path.join(twin_root, "slices"))
    for relative in ("conventions.json", os.path.join("reports", "oracle-calibration.json")):
        source = os.path.join(root, relative)
        if os.path.exists(source):
            os.makedirs(os.path.dirname(os.path.join(twin_root, relative)) or twin_root, exist_ok=True)
            shutil.copy2(source, os.path.join(twin_root, relative))
    twin = Twin.from_entries(cache_entries(twin_root))
    marker = {
        "made": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "source_root": os.path.abspath(root),
        "lrclib_answers_copied": len(cache_entries(twin_root)),
        "search_pages": len(twin.pages), "get_answers": len(twin.gets), "records": len(twin.records),
        "note": "An offline twin of LRCLIB (Scripts/lyric-match-lab/twin.py). Answers listed in "
                f"{MANIFEST} are the twin's, not LRCLIB's.",
    }
    with open(os.path.join(twin_root, MARKER), "w", encoding="utf-8") as handle:
        json.dump(marker, handle, indent=2, sort_keys=True)
    return twin_root


def fill(root: str, name: str = "twin", results: str = "results") -> dict:
    """Answers each LRCLIB request the last replay of the twin root missed."""
    twin_root = require_twin(root, name)
    manifest = read_manifest(twin_root)
    twin = Twin.from_entries(cache_entries(twin_root, skip={k for k, e in manifest.items() if e.get("served")}))
    path = os.path.join(twin_root, results, "isla-lookups.jsonl")
    if not os.path.exists(path):
        raise SystemExit(f"no {path}: replay the twin root with the Swift harness first")
    misses: Dict[str, str] = {}
    mismatched = 0
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            row = json.loads(line)
            for request in row.get("requests", []):
                if request.get("cached") or request.get("status") is not None:
                    continue
                url = ORIGIN + request["path"]
                if common.url_key(url) != request["key"]:
                    mismatched += 1
                    continue
                misses.setdefault(request["key"], url)
    tally = collections.Counter()
    with open(os.path.join(twin_root, MANIFEST), "a", encoding="utf-8") as log:
        for key, url in misses.items():
            if manifest.get(key, {}).get("served"):
                continue
            tier, status, body, got_ids = twin.answer(url)
            query = parse(url)
            served = tier in SERVED
            tally[tier if served else f"{tier} (not served)"] += 1
            if served:
                common.write_cache(twin_root, url, status, body, sub="py")
            # What a tier the twin does not serve would have said is kept for
            # the report; only the served answers reach the cache.
            entry = {"key": key, "kind": query.kind if query else None, "tier": tier,
                     "served": served, "status": status, "ids": got_ids}
            if manifest.get(key) != entry:
                manifest[key] = entry
                log.write(json.dumps(entry, sort_keys=True) + "\n")
    return {"misses": len(misses), "answered": {t: n for t, n in sorted(tally.items())},
            "url_key_mismatches": mismatched}


def lookup_tier(row: dict, manifest: Dict[str, dict]) -> str:
    """The least sure answer among a lookup's requests. A cached request the
    twin did not write is a copy of LRCLIB's own answer."""
    worst = "real"
    for request in row.get("requests", []):
        entry = manifest.get(request["key"])
        if request.get("cached"):
            tier = entry["tier"] if entry else "real"
        else:
            tier = entry["tier"] if entry and not entry.get("served") else "unknown"
        if TIER_ORDER.index(tier) > TIER_ORDER.index(worst):
            worst = tier
    return worst


def tiers(root: str, name: str = "twin", results: str = "results", reports: str = "reports") -> dict:
    """Verdicts by tier: what the twin's run says, split by how sure it is."""
    twin_root = require_twin(root, name)
    manifest = read_manifest(twin_root)
    verdicts: Dict[Tuple[str, str], dict] = {}
    rows_path = os.path.join(twin_root, reports, "rows.csv")
    if os.path.exists(rows_path):
        with open(rows_path, "r", encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                verdicts[(row.get("track_id"), row.get("variant"))] = row
    by_tier = collections.defaultdict(collections.Counter)
    by_variant = collections.defaultdict(collections.Counter)
    with open(os.path.join(twin_root, results, "isla-lookups.jsonl"), "r", encoding="utf-8") as handle:
        for line in handle:
            row = json.loads(line)
            tier = lookup_tier(row, manifest)
            judged = verdicts.get((row["track_id"], row["variant"]), {})
            verdict = judged.get("verdict") or row.get("outcome")
            usable = str(judged.get("usable", "")).lower() in ("true", "1")
            by_tier[tier][verdict] += 1
            if tier in SERVED:
                by_variant[row["variant"]][verdict + (" (usable)" if usable else "")] += 1
    return {"by_tier": {t: dict(sorted(c.items())) for t, c in sorted(by_tier.items(), key=lambda kv: TIER_ORDER.index(kv[0]))},
            "trusted_by_variant": {v: dict(sorted(c.items())) for v, c in sorted(by_variant.items())}}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="An offline twin of LRCLIB for the lyrics match lab.")
    parser.add_argument("command", choices=("validate", "prepare", "fill", "tiers"))
    parser.add_argument("--root", default=DEFAULT_ROOT)
    parser.add_argument("--twin", default="twin")
    parser.add_argument("--results", default="results")
    parser.add_argument("--reports", default="reports")
    parser.add_argument("--fresh", action="store_true", help="prepare: rebuild an existing twin root")
    args = parser.parse_args(argv)
    for value in (args.results, args.reports):
        if not value or "/" in value or value.startswith("."):
            parser.error(f"{value!r} is not a plain directory name")
    if args.command == "validate":
        result = validate(args.root)
    elif args.command == "prepare":
        result = {"twin_root": prepare(args.root, args.twin, args.fresh)}
    elif args.command == "fill":
        result = fill(args.root, args.twin, args.results)
    else:
        result = tiers(args.root, args.twin, args.results, args.reports)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
