#!/usr/bin/env python3
"""HTTP replay cache and polite per-host fetching for the lyrics match lab.

Shared by resolve.py (phase 1) and classify.py (phase 2). Stdlib only.

The cache (SPEC "Cache file format"): one JSON file per exact URL string,
`<root>/cache/<sub>/<sha256(url)>.json`, holding
`{"url", "status", "body_b64", "fetched_at"}`. `sub` is `py` for what this
package writes and `isla` for what the Swift harness writes; reads try both,
so a response either side already paid for is never fetched twice.

    import common
    resp = common.fetch(url, root)                  # live on a miss
    resp = common.fetch(url, root, offline=True)    # None on a miss, never the network
    hit  = common.read_cache(root, url, "isla")     # one cache directory only

Politeness (SPEC "Rules for everything in the lab"): one request at a time to a
host, a minimum gap after the previous one, 429/5xx retried after 2, 8 and
30 s. A network failure, an exhausted retry and any other transient answer are
never cached; an HTTP 404 is (it is LRCLIB's answer for "no record").
"""
from __future__ import annotations

import base64
import datetime
import gzip
import hashlib
import http.client
import json
import os
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Callable, NamedTuple, Optional

USER_AGENT = "isla-lyrics-lab/0.2 (https://github.com/ctimothe/isla-mac)"

# IPv4 first. LRCLIB and iTunes both publish AAAA records, and on 2026-10-15
# LRCLIB answered this Mac's IPv6 address with 429 while its IPv4 address got
# 200 (the per-address ban outlived the development runs). urllib has no Happy
# Eyeballs: it tries the addresses in getaddrinfo order, IPv6 first, so every
# request walked into the ban, the gate backed off eightfold and the first full
# run fetched 5 iTunes and 27 LRCLIB answers in 25 minutes while Deezer, which
# is IPv4 only, raced ahead. IPv6 is still used for a host that has no IPv4.
_system_getaddrinfo = socket.getaddrinfo


def _ipv4_first(host, port, family=0, type=0, proto=0, flags=0):
    answers = _system_getaddrinfo(host, port, family, type, proto, flags)
    ipv4 = [answer for answer in answers if answer[0] == socket.AF_INET]
    return ipv4 or answers


socket.getaddrinfo = _ipv4_first

# Minimum seconds between two requests to one host. A host not listed here
# gets DEFAULT_GAP rather than none, so a typo in a URL cannot hammer a service.
HOST_GAPS = {
    # 7.5 s for every LRCLIB endpoint, not only search: on 2026-10-15 a
    # cooled-down run of /api/get at 1.0 s drew a 429 after five requests, so
    # one limiter of about ten a minute covers the whole host.
    "lrclib.net": 7.5,
    "itunes.apple.com": 3.2,
    "api.deezer.com": 0.25,
}
DEFAULT_GAP = 1.0
# Endpoints with a budget of their own, paced apart from the rest of their
# host; every request still keeps its host's gap as well. LRCLIB's search
# answered 429 whenever requests came closer than about six seconds apart
# (2026-10-15: the adaptive gate decayed from 8.8 s to 4.3 s spacing and drew
# a 429 each time it dipped under 6 s), which reads as about ten requests a
# minute; 7.5 s keeps a fifth of that in hand.
ENDPOINT_GAPS = {
    "lrclib.net/api/search": 7.5,
}
RETRY_DELAYS = (2.0, 8.0, 30.0)
# A 429 waits far longer than a 5xx. LRCLIB's limiter counts the requests it
# refuses (2026-10-15: retries 2, 8 and 30 s apart all drew 429, and a run
# that kept poking during the ban got one answer a minute), so a quick retry
# only extends the ban it is waiting out.
THROTTLE_DELAYS = (30.0, 60.0, 120.0)
RETRY_AFTER_CAP = 60.0  # caps the server's Retry-After, never our own delays
TIMEOUT = 30
TRUNCATED = 599       # synthetic status for a body cut short mid-transfer
THROTTLE_HOLD = 60.0  # seconds a host stays closed after a request ends on 429
# After this many requests in a row ran out of retries on 429, a host gets no
# more live requests for the rest of the run. Its limiter is in a long ban and
# every refused request extends it (2026-10-15: a run that kept poking got one
# answer a minute); the lookups left go unanswered, which is never cached, so
# the next run asks again once the ban has passed.
TRIP_AFTER = 3
# LAB_STOP_AT_429=1 trips a host on its first 429: no retry, no second refused
# request. On 2026-10-15 LRCLIB let three requests through after an hour's
# cool-down and refused the fourth, so the 30/60/120 s retries and the three
# requests TRIP_AFTER spends were all refusals that extend the ban. A collector
# that probes a banned limiter on a schedule sets this, and each probe then
# costs the limiter one refused request.
STOP_AT_429 = os.environ.get("LAB_STOP_AT_429") == "1"

# Statuses that are an answer rather than a hiccup. 400 is deterministic for a
# URL and 404 is LRCLIB's "no record"; both would come back identically. The
# cache holds exactly these and every 2xx, and the Swift harness's
# ReplayTransport.cachesStatus holds the same set, so a record run and its
# replay agree (second review, finding 6).
CACHEABLE_STATUSES = (400, 404)
# Anything else that is not transient is refused (third review, m3). A 403 is
# a gateway or a throttle refusing this client; a 401 or a 410 is no more
# LRCLIB's word on the URL. None of them is cached or reaches the caller as an
# answer: it is a failed fetch here (`refuses_status`) and a miss in the Swift
# harness (ReplayTransport.refusesStatus, the same predicate), so a record run
# and its replay agree. It used to be 403 alone, and a 401 or 410 was an
# answer in the record run that the replay could not give. Each one also counts
# toward TRIP_AFTER (`_note_outcome`), like a request that ran out of retries on
# 429: a gateway that blocks every request spent the whole live budget against a
# host that allows about ten a minute (third review, m12).


def refuses_status(url: str, status: Optional[int]) -> bool:
    """True when `status` is an answer nobody keeps and nobody retries: not 2xx,
    not 400 or 404, and not transient (no answer, 429, 5xx, iTunes's 403)."""
    if status is None or 200 <= status < 300 or status in CACHEABLE_STATUSES:
        return False
    return not _is_transient(url, status)


class Response(NamedTuple):
    status: int
    body: bytes
    cached: bool

    def json(self):
        """The body as JSON, or None when it is not JSON (a 404 page, say)."""
        try:
            return json.loads(self.body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None


# --------------------------------------------------------------------------
# Cache
# --------------------------------------------------------------------------

def url_key(url: str) -> str:
    """Lowercase hex SHA-256 of the URL exactly as sent."""
    return hashlib.sha256(url.encode("utf-8")).hexdigest()


def cache_path(root: str, url: str, sub: str = "py") -> str:
    return os.path.join(root, "cache", sub, url_key(url) + ".json")


def read_cache(root: str, url: str, sub: str = "py") -> Optional[Response]:
    """One cache directory only; None when absent or unreadable.

    A file whose recorded url differs from the one asked for is a miss, not an
    answer: a hand-copied or truncated file must not poison a replay.
    """
    path = cache_path(root, url, sub)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            entry = json.load(handle)
        if entry.get("url") != url:
            return None
        return Response(int(entry["status"]), base64.b64decode(entry["body_b64"]), True)
    except (OSError, ValueError, KeyError, TypeError):
        return None


def write_cache(root: str, url: str, status: int, body: bytes, sub: str = "py") -> str:
    """Atomic write (temp file, then rename): a killed run leaves no half file."""
    path = cache_path(root, url, sub)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    entry = {
        "url": url,
        "status": status,
        "body_b64": base64.b64encode(body).decode("ascii"),
        "fetched_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    }
    tmp = f"{path}.{os.getpid()}.{threading.get_ident()}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(entry, handle)
    os.replace(tmp, path)
    return path


def read_any_cache(root: str, url: str) -> Optional[Response]:
    return read_cache(root, url, "py") or read_cache(root, url, "isla")


def build_url(base: str, params) -> str:
    """`base?k=v&…` with %20 for spaces, in the order given.

    quote (not quote_plus) because the Swift harness reproduces these strings
    and %20 is what URLComponents emits; the cache key is the exact string.
    """
    pairs = params.items() if isinstance(params, dict) else params
    return base + "?" + urllib.parse.urlencode(list(pairs), quote_via=urllib.parse.quote)


# --------------------------------------------------------------------------
# Rate limiting
# --------------------------------------------------------------------------

class HostGate:
    """Holds a host for the whole of one request, retries included, then keeps
    it closed for `gap` seconds.

    A lock rather than a token bucket because the SPEC says one process talks
    to a host at a time: three threads asking lrclib.net queue up, and a 429
    backoff delays all of them instead of letting the others walk into it.

    The gap adapts. LRCLIB rate-limits by IP with a ban that outlasts the
    advertised Retry-After (four attempts over 40 s all got 429 on 2026-10-15),
    so each 429 doubles the effective gap (up to 8x), every success decays it
    back toward the SPEC minimum, and a request that exhausted its retries
    closes the host for a minute so the next track does not walk into the ban.
    """

    MAX_FACTOR = 8.0

    def __init__(self, gap: float, clock: Callable[[], float] = time.monotonic,
                 sleep: Callable[[float], None] = time.sleep,
                 host: Optional["HostSlot"] = None):
        self.gap = gap
        self.factor = 1.0
        self._clock = clock
        self._sleep = sleep
        # An endpoint gate shares its host's lock, so one request is in flight
        # per host however many endpoints it has, and keeps the host's gap.
        self._host = host
        self._lock = host.lock if host is not None else threading.Lock()
        self._released_at: Optional[float] = None
        self._hold_until = 0.0

    @property
    def effective_gap(self) -> float:
        return self.gap * self.factor

    def __enter__(self):
        self._lock.acquire()
        ready = self._hold_until
        if self._released_at is not None:
            ready = max(ready, self._released_at + self.effective_gap)
        if self._host is not None and self._host.released_at is not None:
            ready = max(ready, self._host.released_at + self._host.gap)
        wait = ready - self._clock()
        if wait > 0:
            self._sleep(wait)
        return self

    def __exit__(self, *exc):
        self._released_at = self._clock()
        if self._host is not None:
            self._host.released_at = self._released_at
        self._lock.release()
        return False

    # Called by the holder of the gate, between its own requests.
    def throttled(self) -> None:
        self.factor = min(self.factor * 2.0, self.MAX_FACTOR)

    def succeeded(self) -> None:
        self.factor = max(1.0, self.factor * 0.9)
        if self.factor < 1.05:
            self.factor = 1.0

    def hold(self, seconds: float) -> None:
        self._hold_until = max(self._hold_until, self._clock() + seconds)


class HostSlot:
    """What every endpoint gate of one host shares: the lock that keeps one
    request in flight per host, and the time the last of them finished."""

    def __init__(self, gap: float):
        self.gap = gap
        self.lock = threading.Lock()
        self.released_at: Optional[float] = None


_gates: dict = {}
_host_slots: dict = {}
_gates_lock = threading.Lock()
_refused_in_a_row: dict = {}   # host -> requests in a row that ended on 429
_tripped: set = set()          # hosts that get no more live requests this run


def tripped(url: str) -> bool:
    with _gates_lock:
        return (urllib.parse.urlsplit(url).hostname or "").lower() in _tripped


def _note_outcome(url: str, refused: bool) -> None:
    """Counts requests that ran out of retries on 429, or drew a refused status
    (`refuses_status`), in a row per host, and trips the host at TRIP_AFTER.
    Any answer resets the count."""
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    with _gates_lock:
        if not refused:
            _refused_in_a_row[host] = 0
            return
        _refused_in_a_row[host] = _refused_in_a_row.get(host, 0) + 1
        if _refused_in_a_row[host] < TRIP_AFTER or host in _tripped:
            return
        _tripped.add(host)
    print(f"[trip] {host}: {TRIP_AFTER} requests in a row ran out of retries on 429 or were refused; "
          f"no live request goes to it for the rest of this run", flush=True)


def _trip_now(url: str) -> None:
    """STOP_AT_429: the host's first 429 closes it for the rest of the run."""
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    with _gates_lock:
        if host in _tripped:
            return
        _tripped.add(host)
    print(f"[trip] {host}: stopped at the first 429 (LAB_STOP_AT_429); "
          f"no live request goes to it for the rest of this run", flush=True)


def gate_key(url: str) -> str:
    """The endpoint when it has a gap of its own (ENDPOINT_GAPS), else the host."""
    parts = urllib.parse.urlsplit(url)
    host = (parts.hostname or "").lower()
    endpoint = host + parts.path
    return endpoint if endpoint in ENDPOINT_GAPS else host


def gate_for(url: str) -> HostGate:
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    key = gate_key(url)
    with _gates_lock:
        gate = _gates.get(key)
        if gate is None:
            slot = _host_slots.get(host)
            if slot is None:
                slot = _host_slots[host] = HostSlot(HOST_GAPS.get(host, DEFAULT_GAP))
            gate = _gates[key] = HostGate(ENDPOINT_GAPS.get(key, slot.gap), host=slot)
        return gate


class Stats:
    """Live request counter: the dev budget is spent in requests, retries included."""

    def __init__(self):
        self._lock = threading.Lock()
        self.live = 0
        self.by_host: dict = {}
        self.cache_hits = 0
        self.failures = 0
        self.throttles: dict = {}

    def request(self, url: str):
        host = urllib.parse.urlsplit(url).hostname or ""
        with self._lock:
            self.live += 1
            self.by_host[host] = self.by_host.get(host, 0) + 1

    def hit(self):
        with self._lock:
            self.cache_hits += 1

    def failed(self):
        with self._lock:
            self.failures += 1

    def throttled(self, url: str):
        """Counts a 429 and says so in the log: the fetch loop retries quietly
        otherwise, and a run that is being refused looks merely slow."""
        key = gate_key(url)
        with self._lock:
            self.throttles[key] = self.throttles.get(key, 0) + 1
            count = self.throttles[key]
        print(f"[throttle] {key} 429 #{count}", flush=True)


STATS = Stats()


# --------------------------------------------------------------------------
# Fetching
# --------------------------------------------------------------------------

def _http_get(url: str):
    """(status, body, retry_after_seconds). status None means no HTTP answer."""
    request = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT,
        "Accept": "application/json",
        # Asked for on purpose: behind the sandbox proxy a large chunked
        # identity body (an LRCLIB search page) arrives as IncompleteRead(0),
        # while the gzip form of the same response reads fine.
        "Accept-Encoding": "gzip",
    })
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as reply:
            body = reply.read()
            if (reply.headers.get("Content-Encoding") or "").lower() == "gzip":
                body = gzip.decompress(body)
            return reply.status, body, 0.0
    except urllib.error.HTTPError as error:
        try:
            body = error.read()
            if (error.headers.get("Content-Encoding") or "").lower() == "gzip":
                body = gzip.decompress(body)
        except Exception:
            body = b""
        retry_after = 0.0
        try:
            retry_after = float(error.headers.get("Retry-After", "0") or 0)
        except (TypeError, ValueError):
            pass
        return error.code, body, retry_after
    except http.client.IncompleteRead:
        # The server answered and the connection died mid-body (seen behind the
        # sandbox proxy on 100 KB+ search pages, about half the time). That is
        # a flaky answer, not a dead network, so it gets the 5xx treatment:
        # a full backoff schedule rather than the single retry of a down host.
        return TRUNCATED, b"", 0.0
    except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError, EOFError):
        # RemoteDisconnected is an HTTPException, not an OSError.
        return None, b"", 0.0


def _is_transient(url: str, status: Optional[int]) -> bool:
    if status is None or status == 429 or 500 <= status < 600:
        return True
    # iTunes answers 403 when it is throttling, and the same URL succeeds
    # later; any other host's 403 is a real refusal.
    return status == 403 and (urllib.parse.urlsplit(url).hostname or "") == "itunes.apple.com"


def fetch(url: str, root: str, *, offline: bool = False,
          validate: Optional[Callable[[int, bytes], bool]] = None,
          stats: Stats = STATS) -> Optional[Response]:
    """The response for `url`, from the cache or, unless `offline`, the network.

    Returns None when the answer cannot be had: a cache miss while offline, or
    a network failure / throttle that outlasted the retries. Callers treat None
    as "unknown", never as "no record" (that is a cached 404).

    `validate(status, body)` rejects a 200 whose body is an error envelope (the
    Deezer quota reply is HTTP 200); a rejected body is treated like a 5xx.
    """
    hit = read_any_cache(root, url)
    if hit is not None:
        stats.hit()
        return hit
    if offline:
        return None
    if tripped(url):
        stats.failed()
        return None
    gate = gate_for(url)
    with gate:
        # Another thread may have fetched the same URL while this one queued.
        hit = read_any_cache(root, url)
        if hit is not None:
            stats.hit()
            return hit
        for attempt in range(len(RETRY_DELAYS) + 1):
            stats.request(url)
            status, body, retry_after = _http_get(url)
            if status is not None and validate is not None and 200 <= status < 300 \
                    and not validate(status, body):
                status = 502
            if status is not None and (200 <= status < 300 or status in CACHEABLE_STATUSES):
                gate.succeeded()
                _note_outcome(url, refused=False)
                write_cache(root, url, status, body)
                return Response(status, body, False)
            if refuses_status(url, status):
                stats.failed()
                _note_outcome(url, refused=True)
                return None
            if status == 429:
                gate.throttled()
                stats.throttled(url)
                if STOP_AT_429:
                    stats.failed()
                    gate.hold(THROTTLE_HOLD)
                    _trip_now(url)
                    return None
            # A dead network does not heal in 40 s of retries: try once more, then stop.
            last = attempt == len(RETRY_DELAYS) or (status is None and attempt >= 1)
            if last:
                stats.failed()
                if status == 429:
                    gate.hold(THROTTLE_HOLD)
                    _note_outcome(url, refused=True)
                return None
            delays = THROTTLE_DELAYS if status == 429 else RETRY_DELAYS
            time.sleep(max(delays[attempt], min(retry_after, RETRY_AFTER_CAP)))
    return None


def fetch_json(url: str, root: str, *, offline: bool = False,
               validate: Optional[Callable[[int, bytes], bool]] = None):
    """`(status, parsed_body_or_None)`, or None when no answer could be had."""
    response = fetch(url, root, offline=offline, validate=validate)
    if response is None:
        return None
    return response.status, response.json()
