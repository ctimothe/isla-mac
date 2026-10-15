#!/usr/bin/env python3
"""Offline self-test for the lyrics match lab's resolver and oracle.

    python3 Scripts/lyric-match-lab/selftest.py          # all tests
    python3 Scripts/lyric-match-lab/selftest.py -v       # one line per test
    python3 Scripts/lyric-match-lab/selftest.py OracleTests.test_cluster_conflict

Stdlib unittest, no network, no files outside a temp directory. Every lyric in
here is synthetic (made-up words); the lab's rule is that real lyric text lives
only under the corpus root, and a test file is in git.
"""
from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import random
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import calibrate  # noqa: E402
import common  # noqa: E402
import oracle  # noqa: E402
import resolve  # noqa: E402


def dump(path: str, data) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle)


def slurp(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def quiet_run(*args, **kwargs):
    """resolve.run prints progress; keep it out of the test report."""
    with contextlib.redirect_stdout(io.StringIO()):
        return resolve.run(*args, **kwargs)


def synthetic_words(seed: int, count: int) -> list:
    rng = random.Random(seed)
    syllables = ["ka", "to", "mi", "re", "su", "no", "la", "vi", "ze", "bo", "ru", "fa", "ni", "po", "da"]
    return ["".join(rng.choice(syllables) for _ in range(rng.randint(2, 3))) + str(rng.randint(0, 9))
            for _ in range(count)]


def synthetic_lines(seed: int, lines: int = 24, per_line: int = 6) -> list:
    words = synthetic_words(seed, lines * per_line)
    return [" ".join(words[i * per_line:(i + 1) * per_line]) for i in range(lines)]


def synced(lines: list, step: float = 8.0, tail: str = "") -> str:
    out = []
    for i, text in enumerate(lines):
        t = i * step
        out.append(f"[{int(t // 60):02d}:{t % 60:05.2f}]{text}")
    return "\n".join(out) + (tail and "\n" + tail)


def record(rid: int, title: str, artist: str, lines: list, duration: float, **extra) -> dict:
    row = {"id": rid, "trackName": title, "artistName": artist, "albumName": "Alb",
           "duration": duration, "instrumental": False, "plainLyrics": "\n".join(lines),
           "syncedLyrics": synced(lines), "lyricsfile": None}
    row.update(extra)
    return row


class CommonTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_cache_key_is_sha256_of_exact_url(self):
        url = "https://lrclib.net/api/get?track_name=A%20B&artist_name=C"
        self.assertEqual(common.url_key(url), hashlib.sha256(url.encode()).hexdigest())
        self.assertNotEqual(common.url_key(url), common.url_key(url + "&"))
        self.assertTrue(common.cache_path(self.root, url).endswith(common.url_key(url) + ".json"))
        self.assertIn(os.path.join("cache", "isla"), common.cache_path(self.root, url, "isla"))

    def test_cache_round_trip_and_file_shape(self):
        url = "https://example.test/x?a=1"
        path = common.write_cache(self.root, url, 200, b'{"a": "\xc3\xa9"}')
        entry = json.loads(slurp(path))
        self.assertEqual(sorted(entry), ["body_b64", "fetched_at", "status", "url"])
        hit = common.read_cache(self.root, url)
        self.assertEqual((hit.status, hit.body, hit.cached), (200, b'{"a": "\xc3\xa9"}', True))
        self.assertEqual(hit.json(), {"a": "é"})

    def test_read_cache_reads_isla_directory_and_rejects_url_mismatch(self):
        url = "https://example.test/y"
        common.write_cache(self.root, url, 404, b"{}", sub="isla")
        self.assertIsNone(common.read_cache(self.root, url, "py"))
        self.assertEqual(common.read_cache(self.root, url, "isla").status, 404)
        self.assertEqual(common.read_any_cache(self.root, url).status, 404)
        path = common.cache_path(self.root, "https://example.test/other", "py")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        dump(path, {"url": "https://example.test/not-this", "status": 200, "body_b64": "", "fetched_at": "x"})
        self.assertIsNone(common.read_cache(self.root, "https://example.test/other"))

    def test_offline_miss_never_touches_network(self):
        with mock.patch.object(common, "_http_get", side_effect=AssertionError("network used")):
            self.assertIsNone(common.fetch("https://example.test/miss", self.root, offline=True))
            self.assertIsNone(common.fetch_json("https://example.test/miss", self.root, offline=True))
        common.write_cache(self.root, "https://example.test/hit", 200, b"[1]", sub="isla")
        with mock.patch.object(common, "_http_get", side_effect=AssertionError("network used")):
            self.assertEqual(common.fetch_json("https://example.test/hit", self.root, offline=True), (200, [1]))

    def test_build_url_uses_percent20_and_keeps_order(self):
        url = common.build_url("https://h/api", [("q", "a b&c"), ("z", "é")])
        self.assertEqual(url, "https://h/api?q=a%20b%26c&z=%C3%A9")

    def _fetch_with(self, replies, url="https://example.test/r", **kwargs):
        gate = common.HostGate(0.0)
        with mock.patch.dict(common._gates, {"example.test": gate}), \
                mock.patch.dict(common._refused_in_a_row, {}, clear=True), \
                mock.patch.object(common, "_tripped", set()), \
                mock.patch.object(common, "_http_get", side_effect=list(replies)) as http, \
                mock.patch.object(common.time, "sleep") as sleep:
            result = common.fetch(url, self.root, stats=common.Stats(), **kwargs)
        return result, http.call_count, [c.args[0] for c in sleep.call_args_list], gate

    def test_a_host_trips_after_three_requests_in_a_row_end_on_429(self):
        # The fourth lookup never reaches the network: a limiter in a long ban
        # counts every refused request, so poking it only extends the ban.
        gate = common.HostGate(0.0, sleep=lambda seconds: None)  # its 60 s hold is not waited out
        refused = [(429, b"", 0.0)] * 4
        with mock.patch.dict(common._gates, {"example.test": gate}), \
                mock.patch.dict(common._refused_in_a_row, {}, clear=True), \
                mock.patch.object(common, "_tripped", set()), \
                mock.patch.object(common, "_http_get", side_effect=refused * 3 + [(200, b"[]", 0.0)]) as http, \
                mock.patch.object(common.time, "sleep"), \
                mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            for n in range(3):
                self.assertIsNone(common.fetch(f"https://example.test/t{n}", self.root, stats=common.Stats()))
            self.assertIsNone(common.fetch("https://example.test/t3", self.root, stats=common.Stats()))
            self.assertEqual(http.call_count, 12)
            self.assertIn("[trip] example.test", out.getvalue())
            # Other hosts are untouched.
            self.assertFalse(common.tripped("https://other.test/x"))

    def test_stop_at_429_spends_one_refused_request_and_closes_the_host(self):
        # A collector probing a banned limiter on a schedule: the first 429 is
        # the only refusal the probe costs. No retry, and the next lookup on
        # that host never reaches the network.
        gate = common.HostGate(0.0, sleep=lambda seconds: None)
        with mock.patch.dict(common._gates, {"example.test": gate}), \
                mock.patch.dict(common._refused_in_a_row, {}, clear=True), \
                mock.patch.object(common, "_tripped", set()), \
                mock.patch.object(common, "STOP_AT_429", True), \
                mock.patch.object(common, "_http_get", side_effect=[(429, b"", 0.0), (200, b"[]", 0.0)]) as http, \
                mock.patch.object(common.time, "sleep") as sleep, \
                mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            self.assertIsNone(common.fetch("https://example.test/s0", self.root, stats=common.Stats()))
            self.assertIsNone(common.fetch("https://example.test/s1", self.root, stats=common.Stats()))
            self.assertEqual(http.call_count, 1)
            self.assertEqual(sleep.call_count, 0)
            self.assertIn("[throttle] example.test 429 #1", out.getvalue())
            self.assertIn("[trip] example.test: stopped at the first 429", out.getvalue())
            self.assertFalse(common.tripped("https://other.test/x"))
        self.assertIsNone(common.read_cache(self.root, "https://example.test/s0"))

    def test_an_answer_between_refusals_keeps_the_host_open(self):
        gate = common.HostGate(0.0, sleep=lambda seconds: None)  # its 60 s hold is not waited out
        refused = [(429, b"", 0.0)] * 4
        replies = refused * 2 + [(200, b"[]", 0.0)] + refused * 2 + [(200, b"[]", 0.0)]
        with mock.patch.dict(common._gates, {"example.test": gate}), \
                mock.patch.dict(common._refused_in_a_row, {}, clear=True), \
                mock.patch.object(common, "_tripped", set()), \
                mock.patch.object(common, "_http_get", side_effect=replies), \
                mock.patch.object(common.time, "sleep"), \
                mock.patch("sys.stdout", new_callable=io.StringIO):
            results = [common.fetch(f"https://example.test/o{n}", self.root, stats=common.Stats()) for n in range(6)]
        self.assertEqual([r.status if r else None for r in results], [None, None, 200, None, None, 200])

    def test_retries_5xx_after_2_8_30_seconds_and_429_after_30_60_120(self):
        result, calls, sleeps, _ = self._fetch_with(
            [(429, b"", 0.0), (503, b"", 0.0), (500, b"", 0.0), (200, b"[]", 0.0)])
        self.assertEqual(result.status, 200)
        self.assertEqual((calls, sleeps), (4, [30.0, 8.0, 30.0]))
        self.assertIsNotNone(common.read_cache(self.root, "https://example.test/r"))

    def test_exhausted_retries_return_none_and_cache_nothing(self):
        result, calls, sleeps, gate = self._fetch_with([(429, b"", 0.0)] * 4, url="https://example.test/e")
        self.assertIsNone(result)
        self.assertEqual((calls, sleeps), (4, [30.0, 60.0, 120.0]))
        self.assertIsNone(common.read_cache(self.root, "https://example.test/e"))
        self.assertGreater(gate.factor, 1.0)  # the host is slowed after throttling

    def test_404_is_cached_and_network_failure_is_not(self):
        result, calls, _, _ = self._fetch_with([(404, b'{"message":"x"}', 0.0)], url="https://example.test/n")
        self.assertEqual((result.status, calls), (404, 1))
        self.assertEqual(common.read_cache(self.root, "https://example.test/n").status, 404)
        result, calls, _, _ = self._fetch_with([(None, b"", 0.0)] * 3, url="https://example.test/f")
        self.assertIsNone(result)
        self.assertEqual(calls, 2)  # a dead network is tried once more, not four times
        self.assertIsNone(common.read_cache(self.root, "https://example.test/f"))

    def test_the_cache_holds_2xx_400_and_404_and_a_403_is_a_failed_fetch(self):
        """Second review, finding 6: the two caches disagreed about 400, and a 403 reached the caller as an answer."""
        for status in (200, 204, 400, 404):
            url = f"https://example.test/status/{status}"
            result, calls, _, _ = self._fetch_with([(status, b"{}", 0.0)], url=url)
            self.assertEqual((result.status, calls), (status, 1), status)
            self.assertEqual(common.read_cache(self.root, url).status, status)
        self.assertEqual(sorted(common.CACHEABLE_STATUSES), [400, 404])
        for status in (401, 403, 410):
            url = f"https://example.test/status/{status}"
            result, calls, _, _ = self._fetch_with([(status, b"{}", 0.0)], url=url)
            self.assertIsNone(common.read_cache(self.root, url), status)
            self.assertEqual(calls, 1)
            # 403 never reaches the caller as an answer; the other refusals still do (uncached)
            self.assertEqual(result is None, status == 403, status)

    def test_truncated_body_is_retried_like_a_5xx(self):
        result, calls, sleeps, _ = self._fetch_with([(common.TRUNCATED, b"", 0.0), (200, b"[]", 0.0)],
                                                    url="https://example.test/t")
        self.assertEqual((result.status, calls, sleeps), (200, 2, [2.0]))

    def test_validate_rejects_error_envelope_served_as_200(self):
        bad = (200, b'{"error": {"code": 4}}', 0.0)
        result, calls, _, _ = self._fetch_with([bad, bad, bad, bad], url="https://example.test/v",
                                               validate=lambda s, b: b"error" not in b)
        self.assertIsNone(result)
        self.assertIsNone(common.read_cache(self.root, "https://example.test/v"))

    def test_gate_enforces_gap_and_adapts(self):
        now = [0.0]
        slept = []
        gate = common.HostGate(0.6, clock=lambda: now[0], sleep=lambda s: (slept.append(s), now.__setitem__(0, now[0] + s)))
        with gate:
            pass
        now[0] += 0.1
        with gate:
            pass
        self.assertAlmostEqual(slept[0], 0.5)
        gate.throttled()
        gate.throttled()
        self.assertAlmostEqual(gate.effective_gap, 2.4)
        for _ in range(60):
            gate.succeeded()
        self.assertEqual(gate.factor, 1.0)
        gate.hold(60)
        with gate:
            pass
        self.assertGreaterEqual(now[0], 60)

    def test_endpoint_gate_keeps_its_own_gap_and_its_hosts(self):
        now = [0.0]
        slept = []
        clock = lambda: now[0]
        sleep = lambda s: (slept.append(s), now.__setitem__(0, now[0] + s))
        host = common.HostSlot(1.0)
        search = common.HostGate(7.5, clock=clock, sleep=sleep, host=host)
        get = common.HostGate(1.0, clock=clock, sleep=sleep, host=host)
        with search:
            pass
        with get:  # the host's gap holds across endpoints
            pass
        self.assertAlmostEqual(slept[-1], 1.0)
        with search:  # the search's own gap counts from the last search
            pass
        self.assertAlmostEqual(now[0], 7.5)
        self.assertIs(search._lock, get._lock)

    def test_gate_keys_name_lrclib_search_alone(self):
        self.assertEqual(common.gate_key("https://lrclib.net/api/search?q=a"), "lrclib.net/api/search")
        self.assertEqual(common.gate_key("https://lrclib.net/api/get?track_name=a"), "lrclib.net")
        self.assertEqual(common.gate_key("https://itunes.apple.com/search?term=a"), "itunes.apple.com")
        search = common.gate_for("https://lrclib.net/api/search?q=a")
        get = common.gate_for("https://lrclib.net/api/get?track_name=a")
        self.assertIsNot(search, get)
        self.assertEqual(search.gap, 7.5)
        self.assertEqual(get.gap, 7.5)
        self.assertIs(search._lock, get._lock)

    def test_known_host_gaps(self):
        self.assertEqual(common.HOST_GAPS, {"lrclib.net": 7.5, "itunes.apple.com": 3.2, "api.deezer.com": 0.25})
        self.assertEqual(common.ENDPOINT_GAPS, {"lrclib.net/api/search": 7.5})
        self.assertEqual(common.RETRY_DELAYS, (2.0, 8.0, 30.0))
        self.assertEqual(common.USER_AGENT, "isla-lyrics-lab/0.2 (https://github.com/ctimothe/isla-mac)")


class OracleTests(unittest.TestCase):
    def test_normalize_text(self):
        n = oracle.normalize_text
        self.assertEqual(n("Don’t  Stop!"), "dont stop")
        self.assertEqual(n("Beyoncé"), "beyonce")
        self.assertEqual(n("ＡＢＣ　Ｄ"), "abc d")
        self.assertEqual(n("Ёлка"), n("елка"))
        self.assertEqual(n("Oʻzbek"), n("O'zbek"))
        self.assertEqual(n("강남스타일"), "강남스타일")      # Hangul must not decompose into jamo
        self.assertEqual(n("が"), "が")                      # kana keeps its dakuten
        self.assertEqual(n("नमस्ते"), "नमस्ते")                # Indic vowel signs survive
        self.assertEqual(n("Søren Łukasz"), "soren lukasz")
        self.assertEqual(n("a_b-c.d"), "a b c d")
        self.assertEqual(n(""), "")

    def test_normalize_title(self):
        t = oracle.normalize_title
        self.assertEqual(t("Song (Remastered 2011)"), "song")
        self.assertEqual(t("Song - 2011 Remaster"), "song")
        self.assertEqual(t("Song - Remastered 2011 - Live"), "song")
        self.assertEqual(t("Song [Live at X] feat. Someone"), "song")
        self.assertEqual(t("Song（Radio Edit）"), "song")
        self.assertEqual(t("Song 「Live」"), "song")
        self.assertEqual(t("Song - Part Two"), "song part two")     # a subtitle is not an edition
        self.assertEqual(t("(Untitled)"), "untitled")               # all-bracket title falls back
        self.assertEqual(t("Song (Feat. A) (Remix)"), "song")
        self.assertNotEqual(t("÷"), t("×"))
        self.assertNotEqual(t("÷"), "")

    def test_title_match_variants(self):
        self.assertTrue(oracle.title_match(["Hello"], "Hello - Remastered"))
        self.assertTrue(oracle.title_match(["Hochesh?"], "hochesh"))
        self.assertFalse(oracle.title_match(["Hello"], "Hello Goodbye"))
        self.assertFalse(oracle.title_match(["÷"], "×"))
        self.assertFalse(oracle.title_match([], "Hello"))

    def test_artist_match(self):
        m = oracle.artist_match
        self.assertTrue(m(["The Beatles"], "Beatles"))
        self.assertTrue(m(["Queen"], "Queen, David Bowie"))
        self.assertTrue(m(["David Bowie"], "Queen & David Bowie"))
        self.assertTrue(m(["Simon & Garfunkel"], "Simon and Garfunkel"))
        self.assertTrue(m(["Radiohead"], "Radiohead - Topic"))
        self.assertTrue(m(["Zemfira", "Земфира"], "Zemfira"))
        self.assertFalse(m(["Radiohead"], "TLC"))
        self.assertFalse(m(["Bad Bunny"], "Bad"))          # a lone short token must equal
        self.assertFalse(m([], "Anyone"))
        self.assertFalse(m(["BTS"], ""))

    def test_cyrillic_aliases(self):
        self.assertEqual(oracle.transliterate_cyrillic("Земфира"), "zemfira")
        self.assertEqual(oracle.transliterate_cyrillic("Хочешь"), "khochesh'")   # soft sign
        self.assertEqual(oracle.transliterate_cyrillic("Ёлка"), "yelka")
        self.assertEqual(oracle.transliterate_cyrillic("Привіт", ukrainian=True), "pryvit")
        self.assertEqual(oracle.transliterate_cyrillic("Қазақ"), "qazaq")
        self.assertEqual(oracle.latin_aliases("Hello"), [])
        self.assertTrue(oracle.title_match(oracle.latin_aliases("Хочешь?"), "Hochesh"))
        self.assertTrue(oracle.artist_match(oracle.latin_aliases("Земфира"), "Zemfira"))

    def test_lyric_text_strips_all_markup(self):
        rec = {"syncedLyrics": "[ar:Someone]\n[00:01.00]<00:01.00>alpha <00:01.50>beta\n[00:05.5][00:09.25]gamma\n[01:00.000]"}
        self.assertEqual(oracle.lyric_text(rec), "alpha beta\ngamma")
        self.assertEqual(oracle.lyric_text({"plainLyrics": "one two", "syncedLyrics": "[00:01.00]other"}), "one two")
        self.assertEqual(oracle.lyric_text({}), "")

    def test_last_stamp_ignores_instrumental_markers(self):
        rec = {"syncedLyrics": "[00:10.00]sung line\n[03:58.00]♪\n[04:10.00]"}
        self.assertEqual(oracle.last_stamp(rec), 10.0)
        self.assertEqual(oracle.sung_stamps({"syncedLyrics": "[00:05.00][00:15.50]chorus"}), [5.0, 15.5])
        self.assertIsNone(oracle.last_stamp({"plainLyrics": "words"}))

    def test_fingerprint_and_containment(self):
        a = synthetic_lines(1)
        fp = oracle.fingerprint("\n".join(a))
        self.assertEqual(oracle.containment(fp, fp), 1.0)
        # a record missing its last third still sits inside the full text
        part = oracle.fingerprint("\n".join(a[:16]))
        self.assertEqual(oracle.containment(part, fp), 1.0)
        # reordered lines cost only the shingles that straddle a line boundary
        shuffled = a[12:] + a[:12]
        self.assertGreater(oracle.containment(oracle.fingerprint("\n".join(shuffled)), fp), 0.9)
        other = oracle.fingerprint("\n".join(synthetic_lines(2)))
        self.assertLess(oracle.containment(fp, other), 0.2)
        self.assertEqual(oracle.containment(fp, frozenset()), 0.0)
        self.assertEqual(oracle.containment(None, fp), 0.0)

    def test_tiny_texts_only_match_when_identical(self):
        one, two = oracle.fingerprint("la la"), oracle.fingerprint("la la la la")
        self.assertEqual(oracle.containment(one, one), 1.0)
        self.assertEqual(oracle.containment(one, oracle.fingerprint("la la ba")), 0.0)
        self.assertEqual(len(oracle.fingerprint("solo")), 1)
        self.assertEqual(two, frozenset(["la la la"]))

    @staticmethod
    def thai_like(seed: int, chars: int = 1000) -> str:
        """Made-up text in the Thai script: random consonants and vowels, in lines of 25."""
        rng = random.Random(seed)
        alphabet = [chr(c) for c in range(0x0E01, 0x0E2F)] + [chr(c) for c in (0x0E30, 0x0E32, 0x0E34, 0x0E35, 0x0E40)]
        text = "".join(rng.choice(alphabet) for _ in range(chars))
        return "\n".join(text[i:i + 25] for i in range(0, chars, 25))

    @staticmethod
    def han_like(seed: int, chars: int = 1000) -> str:
        rng = random.Random(seed)
        text = "".join(chr(0x4E00 + rng.randint(0, 400)) for _ in range(chars))
        return "\n".join(text[i:i + 25] for i in range(0, chars, 25))

    def test_ngram_size_is_a_per_family_table(self):
        self.assertEqual(oracle.NGRAM_TABLE["THAI"], ("char", 7))
        self.assertEqual(oracle.NGRAM_TABLE["CJK"], ("char", 5))
        thai, han = self.thai_like(1, 60), self.han_like(1, 60)
        self.assertTrue(all(len(x) == 7 for x in oracle.fingerprint(thai)))
        self.assertTrue(all(len(x) == 5 for x in oracle.fingerprint(han)))
        self.assertTrue(all(len(x) == 5 for x in oracle.fingerprint("あいうえお かきくけこさしすせそ")))     # kana: the CJK family
        hangul = oracle.fingerprint("가나 다라 마바 사아 자차 카타")
        self.assertTrue(all(x.count(" ") == 2 for x in hangul), hangul)        # word 3-shingles, not characters
        self.assertEqual(oracle.shingle_for("HANGUL"), ("word", 3))
        self.assertEqual(oracle.shingle_for("LATIN"), ("word", 3))
        # an explicit n overrides the table for one call
        self.assertTrue(all(len(x) == 2 for x in oracle.fingerprint(thai, ngram=2)))
        # a text shorter than n is one shingle, itself
        self.assertEqual(oracle.fingerprint("สวัสดี"), frozenset(["สวัสดี"]))

    def test_unrelated_spaceless_texts_stay_below_wrong(self):
        """F1: unrelated Thai texts of 1,000 characters shared about half of their bigrams, so
        other songs joined the cluster. At the table's n they share almost nothing."""
        for make, family in ((self.thai_like, "THAI"), (self.han_like, "CJK")):
            bigram, table = [], []
            for seed in range(40):
                a, b = make(2 * seed), make(2 * seed + 1)
                bigram.append(oracle.containment(oracle.fingerprint(a, ngram=2), oracle.fingerprint(b, ngram=2)))
                table.append(oracle.containment(oracle.fingerprint(a), oracle.fingerprint(b)))
            self.assertLess(max(table), oracle.thresholds(family)[1], family)
            if family == "THAI":
                self.assertGreater(sorted(bigram)[20], 0.3, "the failure the bigram table had")
        # the same text, with a tenth of its lines missing, is still the same song
        thai = self.thai_like(9)
        part = "\n".join(thai.split("\n")[:36])
        self.assertEqual(oracle.containment(oracle.fingerprint(part), oracle.fingerprint(thai)), 1.0)

    def test_thresholds_default_and_per_family(self):
        self.assertEqual(oracle.thresholds("LATIN"), (0.6, 0.2))
        self.assertEqual(oracle.thresholds("THAI"), (0.6, 0.2))
        self.assertEqual(oracle.thresholds("NOT-A-FAMILY"), oracle.DEFAULT_THRESHOLDS)
        with mock.patch.dict(oracle.THRESHOLD_TABLE, {"THAI": (0.5, 0.25)}):
            self.assertEqual(oracle.thresholds("THAI"), (0.5, 0.25))
            self.assertEqual(oracle.thresholds("LATIN"), (0.6, 0.2))

    def test_cluster_reads_the_threshold_of_the_winning_family(self):
        a = synthetic_lines(60, 40)
        near = a[:22] + synthetic_lines(61, 18)      # shares a bit over half of its shingles with `a`
        c = [self._cand(1, a), self._cand(2, near)]
        score = oracle.containment(c[1]["fp"], c[0]["fp"])
        self.assertTrue(0.4 < score < 0.6, score)
        self.assertIn("anchor-conflict", oracle.cluster(c, [1, 2])["notes"])           # 0.6 for LATIN
        with mock.patch.dict(oracle.THRESHOLD_TABLE, {"LATIN": (0.4, 0.1)}):
            r = oracle.cluster(c, [1, 2])
        self.assertEqual((r["notes"], sorted(r["cluster_ids"])), ([], [1, 2]))
        # an explicit threshold still wins
        self.assertIn("anchor-conflict", oracle.cluster(c, [1, 2], threshold=0.9)["notes"])

    def test_calibration_file_precedence(self):
        with tempfile.TemporaryDirectory() as root:
            oracle.reset_calibration()
            self.addCleanup(oracle.reset_calibration)
            self.assertFalse(oracle.load_calibration(root))                       # no file: the table
            thai = self.thai_like(3, 200)
            self.assertTrue(all(len(x) == 7 for x in oracle.fingerprint(thai)))
            path = os.path.join(root, oracle.CALIBRATION_FILE)
            os.makedirs(os.path.dirname(path))
            dump(path, {"families": {
                "THAI": {"recommended": {"ngram": 3, "same": 0.5, "wrong": 0.25}},
                "CJK": {"recommended": {"ngram": 99, "same": 0.2, "wrong": 0.9}},      # malformed: ignored
                "LATIN": {"null": {}},                                                  # no recommendation
            }})
            self.assertTrue(oracle.load_calibration(root))
            # the file beats the table, for the family it names ...
            self.assertTrue(all(len(x) == 3 for x in oracle.fingerprint(thai)))
            self.assertEqual(oracle.thresholds("THAI"), (0.5, 0.25))
            self.assertEqual(oracle.active_params()["source"], "calibration")
            # ... and an explicit n beats the file; anything it does not name keeps the table
            self.assertTrue(all(len(x) == 2 for x in oracle.fingerprint(thai, ngram=2)))
            self.assertEqual(oracle.shingle_for("CJK"), ("char", 5))
            self.assertEqual(oracle.thresholds("CJK"), (0.6, 0.2))
            self.assertEqual(oracle.thresholds("LATIN"), (0.6, 0.2))
            # a broken file falls back to the table
            with open(path, "w") as handle:
                handle.write("{not json")
            self.assertFalse(oracle.load_calibration(root))
            self.assertEqual(oracle.shingle_for("THAI"), ("char", 7))

    def test_dominant_script(self):
        d = oracle.dominant_script
        samples = {"LATIN": "hello world", "CYRILLIC": "привет мир", "HANGUL": "안녕하세요",
                   "HIRAGANA": "こんにちは", "KATAKANA": "アイドル", "CJK": "東京大学",
                   "ARABIC": "مرحبا", "HEBREW": "שלום", "DEVANAGARI": "नमस्ते", "GURMUKHI": "ਸਤ ਸ੍ਰੀ",
                   "TAMIL": "வணக்கம்", "THAI": "สวัสดี", "GREEK": "γεια σας"}
        for script, text in samples.items():
            self.assertEqual(d(text), script, text)
        self.assertEqual(d("ＡＢＣ"), "LATIN")          # full-width folds to Latin
        self.assertEqual(d("123 !!!"), "")
        self.assertEqual(d("hello мир мир"), "CYRILLIC")
        self.assertEqual(oracle.script_family("HIRAGANA"), oracle.script_family("CJK"))

    def test_han_kana_and_hangul_weigh_two_and_a_half_letters(self):
        """F2: one Hangul or Han character used to weigh the same as one Latin letter, so a
        Korean lyric that was half English read as Latin."""
        korean_half_english = "사랑해 너를 " * 4 + "love you baby " * 3      # 20 Hangul characters, 33 Latin letters
        self.assertEqual(oracle.dominant_script(korean_half_english), "HANGUL")
        weights = oracle.script_weights(korean_half_english)
        self.assertEqual(weights["HANGUL"], 20 * oracle.CHARACTER_SCRIPT_WEIGHT)
        self.assertEqual(weights["LATIN"], 33)
        self.assertEqual(oracle.dominant_script("あい abcd"), "HIRAGANA")           # 5 against 4 (2 against 4 before)
        self.assertEqual(oracle.dominant_script("東京大学 ok"), "CJK")
        self.assertEqual(oracle.dominant_script("abcd efgh ij"), "LATIN")
        self.assertAlmostEqual(oracle.family_share("한 abcd", "HANGUL"), 2.5 / 6.5)
        by_family = oracle.script_weights("あい ア 日本", by_family=True)
        self.assertEqual(by_family, {"CJK": 5 * 2.5})

    def _cand(self, rid, lines, script=None, **extra):
        text = "\n".join(lines)
        return dict({"id": rid, "fp": oracle.fingerprint(text), "script": script or oracle.dominant_script(text),
                     "instrumental": False}, **extra)

    def test_cluster_basic_adds_matching_non_anchor(self):
        base = synthetic_lines(10)
        c = [self._cand(1, base), self._cand(2, base[:18]), self._cand(3, synthetic_lines(11))]
        r = oracle.cluster(c, [1])
        self.assertEqual(r["truth_status"], "ok")
        self.assertEqual(sorted(r["cluster_ids"]), [1, 2])
        self.assertEqual(r["containment"][2], 1.0)
        self.assertLess(r["containment"][3], 0.2)
        self.assertEqual(r["notes"], [])

    def test_cluster_no_anchor(self):
        r = oracle.cluster([self._cand(1, synthetic_lines(1))], [])
        self.assertEqual((r["truth_status"], r["cluster_ids"], r["alt_script_ids"]), ("no-anchor", [], []))
        r = oracle.cluster([self._cand(1, synthetic_lines(1))], [99])
        self.assertEqual(r["truth_status"], "no-anchor")

    def test_cluster_conflict_takes_largest_mutually_similar_group(self):
        a, b = synthetic_lines(20), synthetic_lines(21)
        c = [self._cand(1, a), self._cand(2, a[:20]), self._cand(3, a[2:]), self._cand(4, b),
             self._cand(5, b[:12]), self._cand(6, a[:10])]
        r = oracle.cluster(c, [1, 2, 3, 4, 5])
        self.assertIn("anchor-conflict", r["notes"])
        self.assertEqual(sorted(r["anchor_ids"]), [1, 2, 3])
        self.assertEqual(sorted(r["cluster_ids"]), [1, 2, 3, 6])
        self.assertNotIn(4, r["cluster_ids"])

    def test_cluster_conflict_is_deterministic_on_a_tie(self):
        a, b = synthetic_lines(30), synthetic_lines(31)
        first = oracle.cluster([self._cand(1, a), self._cand(2, b)], [1, 2])
        second = oracle.cluster([self._cand(2, b), self._cand(1, a)], [2, 1])
        self.assertEqual(first["cluster_ids"], second["cluster_ids"])
        self.assertIn("anchor-conflict", first["notes"])

    def test_cluster_alt_script_is_not_a_conflict(self):
        latin = synthetic_lines(40)
        han = ["".join(random.Random(i).choice("天地玄黄宇宙洪荒日月盈昃") for _ in range(30)) for i in range(6)]
        c = [self._cand(1, han), self._cand(2, han[:5]), self._cand(3, latin)]
        r = oracle.cluster(c, [1, 2, 3])
        self.assertEqual(r["alt_script_ids"], [3])
        self.assertEqual(sorted(r["cluster_ids"]), [1, 2])
        self.assertNotIn("anchor-conflict", r["notes"])
        # an even split goes to the language's own script
        r = oracle.cluster([self._cand(1, han), self._cand(3, latin)], [1, 3], prefer_script="LATIN")
        self.assertEqual(r["cluster_ids"], [3])
        self.assertEqual(r["alt_script_ids"], [1])
        # and so does an outnumbered one: two romanised uploads do not make a
        # Japanese song's single native record the alternative
        c = [self._cand(1, han), self._cand(3, latin), self._cand(4, latin[:5])]
        r = oracle.cluster(c, [1, 3, 4], prefer_script="CJK")
        self.assertEqual(r["cluster_ids"], [1])
        self.assertEqual(sorted(r["alt_script_ids"]), [3, 4])
        # with no anchor in the expected script, the majority decides
        r = oracle.cluster([self._cand(3, latin), self._cand(4, latin[:5])], [3, 4], prefer_script="CJK")
        self.assertEqual(sorted(r["cluster_ids"]), [3, 4])
        self.assertEqual(oracle.expected_script("ja", "Idol"), "CJK")
        self.assertEqual(oracle.expected_script("", "привет"), "CYRILLIC")

    @staticmethod
    def mixed_korean(seed: int, hangul_words: int, latin_words: int = 8, lines: int = 20) -> list:
        """Made-up lines of Hangul words (two syllables each) among made-up Latin ones."""
        rng = random.Random(seed)
        latin = synthetic_words(seed, lines * latin_words)
        out = []
        for i in range(lines):
            words = ["".join(chr(0xAC00 + rng.randint(0, 2000)) for _ in range(2)) for _ in range(hangul_words)]
            out.append(" ".join(words + latin[i * latin_words:(i + 1) * latin_words]))
        return out

    def _analyzed(self, rid, lines):
        info = oracle.analyze_record({"plainLyrics": "\n".join(lines)})
        return {"id": rid, "fp": info["fp"], "script": info["script"], "script_weights": info["script_weights"],
                "instrumental": False, "text": info["text"]}

    @staticmethod
    def japanese_with_latin(seed: int, lines: int = 24, latin_per_line: int = 35) -> tuple:
        """(pure Japanese lines, the same lines each followed by made-up Latin words).

        The second is Latin-dominant by weighted letters and still holds about a
        quarter of them in Japanese, which is the reviewer's repro."""
        rng = random.Random(seed)
        kana = [chr(c) for c in range(0x3042, 0x3093)]
        pure = ["".join(rng.choice(kana) for _ in range(30)) for _ in range(lines)]
        latin = synthetic_words(seed + 1, lines * latin_per_line)
        mixed = [pure[i] + " " + " ".join(latin[i * latin_per_line:(i + 1) * latin_per_line]) for i in range(lines)]
        return pure, mixed

    def test_an_anchor_moved_into_the_expected_script_is_compared_in_that_script(self):
        """Second review, finding 1: a Latin-dominant anchor with a quarter of its weighted letters
        in Japanese keeps the word 3-shingles of its own dominant family, so it shared nothing with
        a pure-Japanese anchor's character 5-grams and the track became anchor-conflict."""
        pure, mixed = self.japanese_with_latin(500)
        japanese = self._analyzed(1, pure)
        latin_heavy = self._analyzed(2, mixed)
        self.assertEqual(latin_heavy["script"], "LATIN")
        share = oracle.family_share(latin_heavy["script_weights"], "CJK")
        self.assertTrue(0.2 <= share < 0.5, share)
        # a non-anchor row of the same song, also Latin-dominant, and an unrelated Latin row
        _, mixed_more = self.japanese_with_latin(500, latin_per_line=40)
        candidate = self._analyzed(3, mixed_more[:18])
        rng = random.Random(501)
        unrelated = self._analyzed(4, [" ".join("".join(rng.choice("abcdefghijklmnopqrstuvwxyz")
                                                          for _ in range(rng.randint(3, 8))) for _ in range(12))
                                       for _ in range(20)])
        result = oracle.cluster([japanese, latin_heavy, candidate, unrelated], [1, 2], prefer_script="CJK")
        self.assertEqual(result["notes"], [])
        self.assertEqual(sorted(result["anchor_ids"]), [1, 2])
        self.assertEqual(result["alt_script_ids"], [])
        self.assertEqual(sorted(result["cluster_ids"]), [1, 2, 3])
        self.assertEqual(result["group_family"], "CJK")
        self.assertGreaterEqual(result["containment"][2], oracle.thresholds("CJK")[0])
        # the record keeps the fingerprint it came with outside a group that names no text
        bare = [{k: v for k, v in c.items() if k != "text"} for c in (japanese, latin_heavy)]
        self.assertIn("anchor-conflict", oracle.cluster(bare, [1, 2], prefer_script="CJK")["notes"])
        # without the expected script, or without weights to move it by, the pair splits cleanly
        # (a tie between families goes to the alphabetically first)
        split = oracle.cluster([japanese, latin_heavy], [1, 2])
        self.assertEqual((split["notes"], split["alt_script_ids"], split["group_family"]), ([], [2], "CJK"))
        unweighted = oracle.cluster([japanese, dict(latin_heavy, script_weights=None)], [1, 2], prefer_script="CJK")
        self.assertEqual((unweighted["notes"], unweighted["alt_script_ids"]), ([], [2]))
        self.assertEqual(oracle.cluster([self._analyzed(9, synthetic_lines(1))], [9])["group_family"], "LATIN")

    def test_cluster_expected_script_wins_at_a_fifth_of_the_weighted_letters(self):
        """F2: a Korean lyric that is mostly English read as Latin, and with two romanised
        copies the romanised group became the truth."""
        korean = self._analyzed(1, self.mixed_korean(70, hangul_words=3))
        self.assertEqual(korean["script"], "LATIN")
        self.assertGreaterEqual(oracle.family_share(korean["script_weights"], "HANGUL"), 0.2)
        romanised = synthetic_lines(71, 20)
        copies = [self._analyzed(2, romanised), self._analyzed(3, romanised[:16])]
        r = oracle.cluster([korean] + copies, [1, 2, 3], prefer_script="HANGUL")
        self.assertEqual((r["cluster_ids"], sorted(r["alt_script_ids"]), r["notes"]), ([1], [2, 3], []))
        # below a fifth the song is not written in the expected script: the romanised group wins
        thin = self._analyzed(1, self.mixed_korean(70, hangul_words=1))
        self.assertLess(oracle.family_share(thin["script_weights"], "HANGUL"), 0.2)
        r = oracle.cluster([thin] + copies, [1, 2, 3], prefer_script="HANGUL")
        self.assertEqual(sorted(r["cluster_ids"]), [2, 3])
        self.assertIn("anchor-conflict", r["notes"])
        # with no expected script nothing changes
        r = oracle.cluster([korean] + copies, [1, 2, 3])
        self.assertEqual(sorted(r["cluster_ids"]), [2, 3])

    def test_cluster_instrumental_anchor_has_no_text(self):
        c = [{"id": 1, "fp": frozenset(), "script": "", "instrumental": True}]
        r = oracle.cluster(c, [1])
        self.assertEqual((r["truth_status"], r["cluster_ids"]), ("ok", [1]))

    LYRICSFILE_WORDS = (
        "version: '1.0'\nmetadata:\n  title: T\nlines:\n"
        "- text: alpha beta\n  start_ms: 1000\n  end_ms: 2000\n  words:\n"
        "  - text: alpha\n    start_ms: 1000\n    end_ms: 1500\n"
        "  - text: beta\n    start_ms: 1500\n    end_ms: 2000\n"
        "- text: gamma\n  start_ms: 2000\n  end_ms: 3000\nplain: |-\n  alpha beta\n  gamma\n")

    def test_lyricsfile_reader(self):
        lines = oracle.parse_lyricsfile(self.LYRICSFILE_WORDS)
        self.assertEqual([l["text"] for l in lines], ["alpha beta", "gamma"])
        self.assertEqual([(w["text"], w["start_ms"], w["end_ms"]) for w in lines[0]["words"]],
                         [("alpha", 1000, 1500), ("beta", 1500, 2000)])
        self.assertEqual(lines[1]["words"], [])
        indented = ("lines:\n  - text: alpha beta\n    start_ms: 1000\n    words:\n"
                    "      - text: alpha\n        start_ms: 1000\n      - text: beta\n        start_ms: 1500\n"
                    "  - text: gamma\n    start_ms: 2000\n")
        parsed = oracle.parse_lyricsfile(indented)
        self.assertEqual([(l["text"], len(l["words"])) for l in parsed], [("alpha beta", 2), ("gamma", 0)])
        quoted = "lines:\n- text: ''\n  start_ms: 5\n- text: \"it's\"\n  start_ms: 6\nplain: x\n"
        self.assertEqual([l["text"] for l in oracle.parse_lyricsfile(quoted)], ["", "it's"])

    def test_word_timing_kind(self):
        enhanced = {"syncedLyrics": "[00:01.00]<00:01.00>alpha <00:01.50>beta"}
        words = {"lyricsfile": self.LYRICSFILE_WORDS, "syncedLyrics": "[00:01.00]alpha beta"}
        both = {"lyricsfile": self.LYRICSFILE_WORDS, "syncedLyrics": enhanced["syncedLyrics"]}
        empty_words = {"lyricsfile": "lines:\n- text: a\n  words: []\n  start_ms: 1\n", "syncedLyrics": "[00:01.00]a"}
        self.assertEqual(oracle.word_timing_kind(enhanced), "enhanced-lrc")
        self.assertEqual(oracle.word_timing_kind(words), "lyricsfile-words")
        self.assertEqual(oracle.word_timing_kind(both), "both")
        self.assertIsNone(oracle.word_timing_kind(empty_words))
        self.assertIsNone(oracle.word_timing_kind({"hasWordSync": True}))


def harvest(**overrides):
    base = {"title": "Song One", "title_latin": "", "artists": ["Artist A"], "artists_latin": [""],
            "featured": [], "album": "Alb", "year": 2000, "language": "en", "vocal": "full",
            "pick": "popular", "tags": [], "source_url": "https://example.test", "why": "x"}
    base.update(overrides)
    return base


def track(index=1, slice_id="pop-anglo", **overrides):
    return resolve.normalize_harvest(harvest(**overrides), slice_id, index)


APPLE = {"trackName": "Song One", "artistName": "Artist A", "collectionName": "Apple Alb",
         "duration": 200.0, "trackId": 1, "primaryGenreName": "Pop", "storefront": "us"}
DEEZER = {"title": "Song One", "title_short": "Song One", "title_version": "", "artist": "Artist A",
          "album": "Deezer Alb", "duration": 199, "id": 2}


class VariantTests(unittest.TestCase):
    def names(self, variants):
        return [v["variant"] for v in variants]

    def test_player_ids(self):
        self.assertEqual(resolve.PLAYER_IDS, {
            "canonical": "lab", "latin-alt": "lab", "no-album": "lab", "apple": "com.apple.Music",
            "apple-us": "com.apple.Music", "deezer": "com.deezer.deezer-desktop",
            "spotify-style": "com.spotify.client"})

    def test_get_url_is_the_canonical_variants_own_first_lookup(self):
        # One request serves the truth pool and Isla's first lookup, so the
        # get asks exactly what the canonical variant asks: every credited
        # artist, and a duration rounded the way Swift rounds it.
        t = track(title="Duet", artists=["Artist A", "Artist B"])
        canonical = resolve.build_variants(t, APPLE, None)[0]
        self.assertEqual(canonical["artist"], "Artist A, Artist B")
        url = resolve.lrclib_get_url(t, 214.5, "Alb")
        self.assertEqual(url, "https://lrclib.net/api/get?track_name=Duet"
                              "&artist_name=Artist%20A%2C%20Artist%20B&album_name=Alb&duration=215")
        self.assertEqual(resolve.isla_seconds(213.5), "214")   # round() would say 214 too
        self.assertEqual(resolve.isla_seconds(214.5), "215")   # round() would say 214
        self.assertEqual(resolve.isla_seconds(214.49), "214")

    def test_track_ids_are_slice_slash_zero_padded_index(self):
        self.assertEqual(track(index=4, slice_id="jazz")["track_id"], "jazz/004")

    def test_canonical_album_falls_back_to_apple_then_deezer(self):
        t = track(album="")
        self.assertEqual(resolve.canonical_album(t, APPLE, DEEZER), "Apple Alb")
        self.assertEqual(resolve.canonical_album(t, None, DEEZER), "Deezer Alb")
        self.assertEqual(resolve.canonical_album(t, None, None), "")
        self.assertEqual(resolve.canonical_album(track(album="Own"), APPLE, DEEZER), "Own")
        v = {x["variant"]: x for x in resolve.build_variants(t, APPLE, DEEZER)}
        self.assertEqual(v["canonical"]["album"], "Apple Alb")
        self.assertEqual(v["spotify-style"]["album"], "Apple Alb")

    def test_no_album_variant_only_for_every_fourth_index(self):
        for index, expected in ((0, True), (1, False), (3, False), (4, True), (8, True)):
            variants = resolve.build_variants(track(index=index), APPLE, DEEZER)
            self.assertEqual("no-album" in self.names(variants), expected, index)
        v = {x["variant"]: x for x in resolve.build_variants(track(index=0), APPLE, DEEZER)}
        self.assertEqual((v["no-album"]["album"], v["no-album"]["title"], v["no-album"]["player_id"]),
                         ("", "Song One", "lab"))
        self.assertEqual(v["no-album"]["duration"], v["canonical"]["duration"])

    def test_variant_rows_follow_the_spec_table(self):
        t = track(artists=["A", "B"], artists_latin=["", ""], featured=["F"])
        us = dict(APPLE, trackName="Song One (US)", artistName="A US", collectionName="US Alb", duration=201.0)
        v = {x["variant"]: x for x in resolve.build_variants(t, APPLE, DEEZER, us)}
        self.assertEqual(v["canonical"]["artist"], "A, B")
        self.assertEqual(v["canonical"]["duration"], 200.0)
        self.assertEqual((v["apple"]["title"], v["apple"]["album"], v["apple"]["duration"]),
                         ("Song One", "Apple Alb", 200.0))
        self.assertEqual((v["apple-us"]["title"], v["apple-us"]["artist"], v["apple-us"]["duration"]),
                         ("Song One (US)", "A US", 201.0))
        self.assertEqual((v["deezer"]["artist"], v["deezer"]["album"], v["deezer"]["duration"]),
                         ("Artist A", "Deezer Alb", 199))
        self.assertEqual(v["spotify-style"]["artist"], "A, B, F")  # featured artists are credited too
        self.assertEqual(v["spotify-style"]["title"], "Song One (feat. F)")
        for row in v.values():
            self.assertEqual(sorted(row), ["album", "artist", "duration", "player_id", "slice", "title",
                                            "track_id", "variant"])

    def test_duration_falls_back_to_deezer_then_zero(self):
        v = {x["variant"]: x for x in resolve.build_variants(track(), None, DEEZER)}
        self.assertEqual(v["canonical"]["duration"], 199)
        v = {x["variant"]: x for x in resolve.build_variants(track(), None, None)}
        self.assertEqual(v["canonical"]["duration"], 0)

    def test_latin_alt_only_from_harvest_given_forms(self):
        cyr = track(title="Хочешь?", artists=["Земфира"], artists_latin=[""], title_latin="")
        self.assertNotIn("latin-alt", self.names(resolve.build_variants(cyr, APPLE, DEEZER)))
        given = track(title="Хочешь?", artists=["Земфира"], artists_latin=["Zemfira"], title_latin="Hochesh?")
        v = {x["variant"]: x for x in resolve.build_variants(given, APPLE, DEEZER)}
        self.assertEqual((v["latin-alt"]["title"], v["latin-alt"]["artist"], v["latin-alt"]["player_id"]),
                         ("Hochesh?", "Zemfira", "lab"))
        self.assertNotIn("latin-alt", self.names(resolve.build_variants(track(), APPLE, DEEZER)))
        mixed = track(artists=["A", "B"], artists_latin=["", "Bee"])
        v = {x["variant"]: x for x in resolve.build_variants(mixed, APPLE, DEEZER)}
        self.assertEqual(v["latin-alt"]["artist"], "A, Bee")

    def test_empty_strings_in_harvest_are_handled(self):
        t = resolve.normalize_harvest({"title": "X", "artists": ["A", "B"], "artists_latin": [""]}, "s", 0)
        self.assertEqual(t["artists_latin"], ["", ""])
        self.assertEqual(t["album"], "")
        self.assertEqual(resolve.latin_forms(t), ("X", "A", False))
        self.assertTrue(resolve.build_variants(t, None, DEEZER))

    def test_spotify_style_editions(self):
        t = track(title="Bohemian Rhapsody")

        def title(apple_name=None, deezer=None, harvest_title=None):
            tr = track(title=harvest_title) if harvest_title else t
            apple = dict(APPLE, trackName=apple_name) if apple_name else None
            return resolve.spotify_title(tr, apple, deezer)

        self.assertEqual(title("Bohemian Rhapsody (Remastered 2011)"), "Bohemian Rhapsody - Remastered 2011")
        self.assertEqual(title("Bohemian Rhapsody - 2011 Remaster"), "Bohemian Rhapsody - Remastered 2011")
        self.assertEqual(title("Bohemian Rhapsody - Remastered"), "Bohemian Rhapsody - Remastered")
        self.assertEqual(title("Bohemian Rhapsody (Live)"), "Bohemian Rhapsody - Live")
        self.assertEqual(title("Bohemian Rhapsody (Radio Edit)"), "Bohemian Rhapsody - Radio Edit")
        self.assertEqual(title(deezer=dict(DEEZER, title_version="(Radio Edit)")), "Bohemian Rhapsody - Radio Edit")
        self.assertEqual(title(harvest_title="Song (Live)"), "Song - Live")
        # "live" in the title itself is not an edition
        self.assertEqual(title("Live Forever", harvest_title="Live Forever"), "Live Forever")
        # a parenthetical that is part of the title stays
        self.assertEqual(title(harvest_title="(I Can't Get No) Satisfaction - Remastered 2002"),
                         "(I Can't Get No) Satisfaction - Remastered 2002")
        self.assertEqual(resolve.spotify_title(track(title="Song (feat. X)"), None, None), "Song (feat. X)")
        self.assertEqual(resolve.spotify_title(track(featured=["B", "C"]), None, None), "Song One (feat. B, C)")
        self.assertIn("editions", resolve.SPOTIFY_STYLE)

    def test_storefront_table(self):
        s = resolve.storefront
        self.assertEqual([s("kpop-jpop-anime", "ko"), s("kpop-jpop-anime", "ja"), s("kpop-jpop-anime", "en")],
                         ["kr", "jp", "us"])
        self.assertEqual(s("cpop-southeast-asia", "th"), "tw")
        self.assertEqual(s("russian-cis-uzbek", "uz"), "kz")
        self.assertEqual([s("middle-east-south-asia", x) for x in ("ar", "tr", "hi", "ta", "fa")],
                         ["ae", "tr", "in", "in", "us"])
        self.assertEqual([s("latin", "es"), s("latin", "pt")], ["mx", "br"])
        self.assertEqual([s("africa-caribbean-europe", x) for x in ("fr", "de", "it", "yo")],
                         ["fr", "de", "it", "ng"])
        self.assertEqual(s("jazz", "zxx"), "us")


class DuplicateAndHarvestTests(unittest.TestCase):
    def test_duplicates_keep_the_earliest_and_not_editions(self):
        a = track(index=0, slice_id="s1", title="Miles on It", artists=["Marshmello", "Kane Brown"])
        b = track(index=3, slice_id="s2", title="MILES ON IT!", artists=["marshmello"])
        c = track(index=4, slice_id="s2", title="Wonderwall - Remastered", artists=["Oasis"])
        d = track(index=5, slice_id="s2", title="Wonderwall", artists=["Oasis"])
        e = track(index=6, slice_id="s2", title="Miles on It", artists=["Someone Else"])
        kept, dropped = resolve.split_duplicates([a, b, c, d, e])
        self.assertEqual([t["track_id"] for t in kept], ["s1/000", "s2/004", "s2/005", "s2/006"])
        self.assertEqual(dropped[0]["reason"], "duplicate")
        self.assertEqual((dropped[0]["track_id"], dropped[0]["duplicate_of"]), ("s2/003", "s1/000"))

    def test_check_harvest_flags_anomalies(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "slices"))
            tracks = [harvest(title=f"T{i}", artists=[f"A{i}"], artists_latin=[""]) for i in range(21)]
            tracks[0]["tags"] = ["not-a-tag"]
            tracks[1]["vocal"] = "maybe"
            del tracks[2]["year"]
            tracks[3]["artists"] = []
            dump(os.path.join(root, "slices", "pop.json"), {"slice": "wrong-name", "tracks": tracks})
            dump(os.path.join(root, "slices", "_scratch.json"), {"slice": "x", "tracks": [harvest()]})
            report = resolve.check_harvest(root)
            text = "\n".join(report["anomalies"])
            self.assertEqual(report["totals"]["tracks"], 21)      # the _ file is skipped
            for needle in ("differs from file name", "outside the vocabulary", "vocal 'maybe'",
                           "missing year", "empty or blank artists"):
                self.assertIn(needle, text)


class ResolveEndToEndTests(unittest.TestCase):
    """The whole of resolve.run, offline, over a hand-made cache."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        os.makedirs(os.path.join(self.root, "slices"))
        self.lines = synthetic_lines(100)
        self.other = synthetic_lines(101)

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, url, body, status=200):
        common.write_cache(self.root, url, status, json.dumps(body).encode())

    def build(self):
        a = harvest(title="Song One", artists=["Artist A"], album="Alb")
        dup = harvest(title="song one", artists=["artist a"])
        gone = harvest(title="Nothing Here", artists=["Nobody"], album="")
        dump(os.path.join(self.root, "slices", "pop-anglo.json"), {"slice": "pop-anglo", "tracks": [a, dup, gone]})
        ta = resolve.normalize_harvest(a, "pop-anglo", 0)
        tc = resolve.normalize_harvest(gone, "pop-anglo", 2)
        apple_hit = {"trackName": "Song One", "artistName": "Artist A", "collectionName": "Alb",
                     "trackTimeMillis": 200000, "trackId": 9, "primaryGenreName": "Pop"}
        self.put(resolve.itunes_url("Song One Alb", "us"), {"resultCount": 1, "results": [apple_hit]})
        self.put(resolve.deezer_structured_url("Song One", "Artist A"), {"data": [
            {"title": "Song One", "title_short": "Song One", "title_version": "", "duration": 199, "id": 5,
             "artist": {"name": "Artist A"}, "album": {"title": "Alb"}}]})
        rows = [
            record(1, "Song One", "Artist A", self.lines, 200.0),
            record(2, "Song One", "Artist A", self.lines, 205.0),
            record(3, "Song One", "Somebody Else", self.other, 200.0),
            record(4, "Song One (Live)", "Artist A", self.lines[:20], 201.0,
                   syncedLyrics=synced(self.lines[:20]).replace("]", "]<00:01.00>", 1)),
            record(5, "Song One", "Artist A", self.lines, 200.0,
                   syncedLyrics=synced(self.lines, tail="[05:00.00]last words at the very end")),
            record(6, "Unrelated", "Artist A", self.other, 200.0),
        ]
        rows[4]["lyricsfile"] = "lines:\n- text: a\n  start_ms: 1\n  words:\n  - text: a\n    start_ms: 1\n    end_ms: 2\n"
        urls = resolve.lrclib_search_urls(ta)
        self.put(urls["search:track_artist"], rows[:4])
        self.put(urls["search:q"], rows[3:])
        self.put(resolve.lrclib_get_url(ta, 200.0, "Alb"), rows[0])
        for term, cc in ((f"{tc['title']} {tc['artists'][0]}", "us"),):
            self.put(resolve.itunes_url(term, cc), {"resultCount": 0, "results": []})
        self.put(resolve.deezer_structured_url("Nothing Here", "Nobody"), {"data": []})
        self.put(resolve.deezer_plain_url("Nothing Here", "Nobody"), {"data": []})

    def read(self, name):
        return [json.loads(l) for l in slurp(os.path.join(self.root, "resolved", name)).splitlines()]

    def test_offline_resolution(self):
        self.build()
        summary = quiet_run(self.root, offline=True)
        tracks, variants, dropped = self.read("tracks.jsonl"), self.read("variants.jsonl"), self.read("dropped.jsonl")
        self.assertEqual([t["track_id"] for t in tracks], ["pop-anglo/000"])
        self.assertEqual({d["track_id"]: d["reason"].split(":")[0] for d in dropped},
                         {"pop-anglo/001": "duplicate", "pop-anglo/002": "itunes"})
        line = tracks[0]
        self.assertEqual(line["apple"]["duration"], 200.0)
        self.assertEqual(line["deezer"]["duration"], 199)
        self.assertIsNone(line["apple_us"])
        by_id = {c["id"]: c for c in line["candidates"]}
        self.assertEqual(sorted(by_id), [1, 2, 3, 4, 5, 6])
        self.assertTrue(by_id[1]["anchor"] and by_id[2]["anchor"])
        self.assertFalse(by_id[3]["identity"])            # same title, other artist
        self.assertFalse(by_id[6]["identity"])
        truth = line["truth"]
        self.assertEqual(sorted(truth["cluster_ids"]), [1, 2, 4, 5])   # 3 and 6 carry other lyrics
        self.assertEqual(by_id[4]["word_timing"], "enhanced-lrc")
        self.assertEqual(by_id[5]["word_timing"], "lyricsfile-words")
        # 1: exact fit. 2: 5 s off is "near". 4: 1 s off but a live cut with a shorter text still fits.
        # 5: right length, but a sung line stamped at 300 s overruns a 200 s variant.
        canonical = truth["per_variant"]["canonical"]
        self.assertEqual(canonical["synced_fit"], [1, 4])
        self.assertEqual(canonical["synced_near"], [2])
        self.assertEqual(truth["per_variant"]["deezer"]["duration"], 199)
        self.assertEqual(truth["truth_status"], "ok")
        self.assertFalse(truth["instrumental_expected"])
        self.assertTrue(os.path.exists(os.path.join(self.root, "wordtimed", "pop-anglo", "4.json")))
        word = json.loads(slurp(os.path.join(self.root, "wordtimed", "pop-anglo", "5.json")))
        self.assertEqual((word["track_id"], word["same_song"]), ("pop-anglo/000", True))
        kinds = [v["variant"] for v in variants]
        self.assertEqual(kinds, ["canonical", "no-album", "apple", "deezer", "spotify-style"])
        self.assertEqual(summary["total"]["resolved"], 1)
        self.assertEqual(summary["total"]["duplicates"], 1)
        self.assertEqual(summary["total"]["dropped"], 2)
        self.assertEqual(summary["slices"]["pop-anglo"]["word_timed_records"], 2)
        self.assertEqual(summary["total"]["synced_fit_available"]["canonical"],
                         {"tracks": 1, "with_synced_fit": 1})
        self.assertTrue((os.path.join(self.root, "resolved", "summary.json")))
        # nothing in the jsonl outputs may carry lyric text
        blob = "".join(slurp(os.path.join(self.root, "resolved", n))
                       for n in ("tracks.jsonl", "variants.jsonl", "dropped.jsonl"))
        self.assertNotIn(self.lines[0].split()[0] + " " + self.lines[0].split()[1], blob)

    def test_rerun_with_a_slice_filter_keeps_other_slices(self):
        self.build()
        quiet_run(self.root, offline=True)
        dump(os.path.join(self.root, "slices", "jazz.json"), {"slice": "jazz", "tracks": []})
        quiet_run(self.root, slices=["jazz"], offline=True)
        self.assertEqual([t["track_id"] for t in self.read("tracks.jsonl")], ["pop-anglo/000"])

    def test_scratch_slices_need_naming(self):
        self.build()
        os.rename(os.path.join(self.root, "slices", "pop-anglo.json"), os.path.join(self.root, "slices", "_dev.json"))
        self.assertEqual(resolve.load_slices(self.root, None, None), [])
        self.assertEqual(len(resolve.load_slices(self.root, ["_dev"], None)[0][1]), 3)
        self.assertEqual(len(resolve.load_slices(self.root, ["_dev"], 2)[0][1]), 2)

    def test_sample_keeps_stress_picks_and_harvest_indices(self):
        # Every slice lists its popular picks first; --limit would drop the
        # stress picks, --sample keeps the first of each kind in harvest order.
        picks = ["popular"] * 5 + ["stress"] * 3
        tracks = [resolve.normalize_harvest(harvest(title=f"T{i}", pick=p), "jazz", i) for i, p in enumerate(picks)]
        chosen = resolve.sample_tracks(tracks, 2, 2)
        self.assertEqual([t["track_id"] for t in chosen], ["jazz/000", "jazz/001", "jazz/005", "jazz/006"])
        self.assertEqual(len(resolve.sample_tracks(tracks, 9, 9)), 8)

    def test_apple_us_is_a_variant_only_when_the_us_names_differ(self):
        t = resolve.normalize_harvest(harvest(title="Хочешь?", artists=["Земфира"], album="", language="ru"),
                                      "russian-cis-uzbek", 1)
        home = {"trackName": "Хочешь?", "artistName": "Земфира", "collectionName": "A",
                "trackTimeMillis": 198000, "trackId": 1, "primaryGenreName": "Rock"}
        us = dict(home, trackName="Khochesh?", artistName="Zemfira")
        plan = [f"{t['title']} {t['artists'][0]}"]
        apple = resolve._apple_entry(home, "kz")
        self.put(resolve.itunes_url(plan[0], "us"), {"resultCount": 1, "results": [us]})
        entry, status = resolve.resolve_apple_us(t, apple, plan, self.root, True)
        self.assertEqual((status, entry["trackName"], entry["artistName"]), ("different", "Khochesh?", "Zemfira"))
        self.put(resolve.itunes_url(plan[0], "us"), {"resultCount": 1, "results": [home]})
        self.assertEqual(resolve.resolve_apple_us(t, apple, plan, self.root, True), (None, "same"))
        self.assertEqual(resolve.resolve_apple_us(t, resolve._apple_entry(home, "us"), plan, self.root, True),
                         (None, "n/a"))
        self.assertEqual(resolve.resolve_apple_us(t, apple, ["unseen term"], self.root, True),
                         (None, "unanswered"))

    def test_latin_only_upload_of_a_cyrillic_song_anchors_through_aliases(self):
        t = resolve.normalize_harvest(harvest(title="Хочешь?", artists=["Земфира"], album=""), "s", 0)
        titles, artists = resolve.identity_titles(t, None, None), resolve.identity_artists(t, None, None)
        self.assertTrue(oracle.title_match(titles, "Hochesh") and oracle.artist_match(artists, "Zemfira"))
        self.assertEqual(t["title_latin"], "")   # the harvest gave no Latin form; the alias is what matches


# ---------------------------------------------------------------------------
# Phase 2: analysis.py and classify.py
# ---------------------------------------------------------------------------

import analysis  # noqa: E402
import classify  # noqa: E402


def han_lines(seed: int, count: int = 8, width: int = 30) -> list:
    rng = random.Random(seed)
    return ["".join(chr(0x4E00 + rng.randint(0, 600)) for _ in range(width)) for _ in range(count)]


def enhanced(lines_words: list, step: float = 4.0, tail: bool = True) -> str:
    """Enhanced LRC: each entry is a list of (word, offset_in_line) for one line."""
    out = []
    for i, words in enumerate(lines_words):
        t0 = i * step
        body = ""
        for word, offset in words:
            t = t0 + offset
            body += f"<{int(t // 60):02d}:{t % 60:06.3f}>{word} "
        if tail:
            t = t0 + step
            body = body.rstrip() + f"<{int(t // 60):02d}:{t % 60:06.3f}>"
        out.append(f"[{int(t0 // 60):02d}:{t0 % 60:05.2f}]{body.rstrip() if not tail else body}")
    return "\n".join(out)


class AnalysisTests(unittest.TestCase):
    def test_percentile_and_summary(self):
        self.assertEqual(analysis.percentile([1, 2, 3, 4, 5], 50), 3.0)
        self.assertAlmostEqual(analysis.percentile([0, 10], 90), 9.0)
        self.assertIsNone(analysis.percentile([], 50))
        cell = analysis.summarize([0.05, 0.2, 0.3, 0.6], (0.1, 0.25))
        self.assertEqual((cell["n"], cell["within_100ms"], cell["within_250ms"]), (4, 0.25, 0.5))

    def test_syllables_by_script(self):
        s = analysis.syllables
        self.assertEqual([s("hello"), s("make"), s("table"), s("strength")], [2, 1, 2, 1])
        self.assertEqual(s("привет"), 2)
        self.assertEqual(s("アイドル"), 4)
        self.assertEqual(s("きょう"), 2)          # small ょ merges with き
        self.assertEqual(s("안녕하세요"), 5)
        self.assertEqual(s("नमस्ते"), 3)          # the virama kills a vowel
        self.assertEqual(s("東京"), 2)
        self.assertEqual(s("..."), 1)
        self.assertEqual(analysis.letters("ab,c"), 3)

    def test_estimators(self):
        words = ["a", "bb", "cccc"]
        self.assertEqual(analysis.estimate_starts(words, 10, 17, "E0"), [10, 10, 10])
        self.assertEqual(analysis.estimate_starts(words, 0, 3, "E1"), [0.0, 1.0, 2.0])
        self.assertEqual(analysis.estimate_starts(words, 0, 7, "E2"), [0.0, 1.0, 3.0])
        # E4 caps the time one syllable may take: the line finishes early
        syl = [analysis.syllables(w) for w in ("banana", "tomato")]
        e3 = analysis.estimate_starts(["banana", "tomato"], 0, 12, "E3")
        e4 = analysis.estimate_starts(["banana", "tomato"], 0, 12, "E4", 0.3)
        self.assertEqual(e3[1], 6.0)
        self.assertAlmostEqual(e4[1], syl[0] * 0.3)
        self.assertLess(e4[1], e3[1])

    def test_tempo_buckets(self):
        self.assertEqual([analysis.tempo_bucket(x) for x in (1.0, 3.0, 4.9, 5.0, 7.0, 12.0)],
                         ["<3", "3-5", "3-5", "5-7", ">7", ">7"])

    LYRICSFILE = ("lines:\n- text: one two three\n  start_ms: 1000\n  end_ms: 9000\n  words:\n"
                  "  - text: one\n    start_ms: 1000\n    end_ms: 2000\n"
                  "  - text: two\n    start_ms: 3000\n    end_ms: 4000\n"
                  "  - text: three\n    start_ms: 5000\n    end_ms: 6000\n"
                  "- text: next line\n  start_ms: 6500\n  end_ms: 9000\n  words:\n"
                  "  - text: next\n    start_ms: 6500\n  - text: line\n    start_ms: 7500\n")

    def test_lyricsfile_word_line_span_ends_at_the_next_line_never_at_its_own_end(self):
        """F9: a line-only lyric has no word-timed true end, so the span an estimator is given
        ends where the next line starts. The record's own end_ms used to cut it short."""
        lines = analysis.lyricsfile_lines(self.LYRICSFILE)
        self.assertEqual([[w for w, _ in l.words] for l in lines], [["one", "two", "three"], ["next", "line"]])
        self.assertEqual((lines[0].start, lines[0].next_start, lines[0].own_end, lines[0].end), (1.0, 6.5, 9.0, 6.5))
        self.assertIsNone(lines[1].end)           # the last line has no next stamp: no span, nothing scored
        early = analysis.lyricsfile_lines(
            "lines:\n- text: a b\n  start_ms: 1000\n  end_ms: 3000\n  words:\n"
            "  - text: a\n    start_ms: 1000\n  - text: b\n    start_ms: 2000\n"
            "- text: c d\n  start_ms: 8000\n  words:\n  - text: c\n    start_ms: 8000\n  - text: d\n    start_ms: 9000\n")
        self.assertEqual((early[0].own_end, early[0].end), (3.0, 8.0))   # min(next, own) would have said 3.0

    def test_enhanced_lines_glue_fragments_and_read_gap_ends(self):
        text = ("[00:00.00]<00:00.000>he<00:00.400>llo <00:01.000>wor<00:01.500>ld <00:02.000>x<00:03.000>\n"
                "[00:04.00]<00:04.000>next <00:05.000>one\n[00:07.00]\n[00:08.00]<00:08.000>last<00:09.500>")
        lines = analysis.enhanced_lines(text)
        self.assertEqual([[w for w, _ in l.words] for l in lines], [["hello", "world", "x"], ["next", "one"], ["last"]])
        self.assertEqual(lines[0].words[1], ("world", 1.0))      # the word keeps its first fragment's time
        self.assertEqual((lines[0].next_start, lines[0].own_end, lines[0].end), (4.0, 3.0, 4.0))
        self.assertEqual(lines[1].next_start, 7.0)                # the empty gap stamp ends the line
        self.assertIsNone(lines[2].end)            # no stamp after it, and the tag's 9.5 is the true last-word end
        cjk = analysis.enhanced_lines("[00:00.00]<00:00.000>天<00:00.500>地<00:01.000>玄<00:01.500>")
        self.assertEqual(len(cjk[0].words), 3)                    # spaceless: every segment is a word

    def test_lyricsfile_words_win_over_enhanced_tags(self):
        record = {"lyricsfile": self.LYRICSFILE, "syncedLyrics": "[00:00.00]<00:00.000>zzz<00:01.000>"}
        lines, source = analysis.word_lines(record)
        self.assertEqual(source, "lyricsfile-words")
        self.assertEqual(analysis.word_lines({"syncedLyrics": "[00:01.00]plain"})[1], None)

    def _timed_record(self, rid, estimator=None, seed=1, track=None):
        """Eight lines of four words with real (jittered) onsets, or onsets an estimator made."""
        rng = random.Random(seed)
        words = synthetic_words(seed, 32)
        entries = []
        for i in range(8):
            ws = words[i * 4:(i + 1) * 4]
            if estimator:
                offsets = analysis.estimate_starts(ws, 0.0, 4.0, estimator)
            else:
                offsets = [0.0, 0.6 + rng.random() * 0.4, 1.6 + rng.random() * 0.4, 2.6 + rng.random() * 0.4]
            entries.append(list(zip(ws, offsets)))
        out = {"id": rid, "syncedLyrics": enhanced(entries)}
        if track:
            out["track_id"] = track
        return out

    def test_estimation_study_scores_and_flags_estimator_made_records(self):
        study = analysis.EstimationStudy()
        # odd-indexed tracks are scored, even-indexed tune E4's cap
        self.assertTrue(study.add_record("pop-anglo", self._timed_record(1, track="pop-anglo/001")))
        self.assertTrue(study.add_record("pop-anglo", self._timed_record(2, "E1", seed=2, track="pop-anglo/003")))
        self.assertTrue(study.add_record("pop-anglo", self._timed_record(3, seed=3, track="pop-anglo/002")))
        self.assertFalse(study.add_record("pop-anglo", self._timed_record(1)))       # duplicate id
        result = study.result()
        self.assertEqual(result["records"], 3)
        self.assertEqual(result["estimator_made_records"]["E1"], 1)
        self.assertEqual(result["estimator_made_ids"], [2])
        # each record's last line has no following stamp, so no span: 7 of its 8 lines are scored
        self.assertEqual(result["lines"], 21)
        self.assertEqual(result["words_scored"], 21 * 3)
        everything, real = result["overall_all_records"], result["overall_excluding_estimator_made"]
        self.assertGreater(real["E1"]["p50"], everything["E1"]["p50"])      # the self-made record flatters E1
        self.assertEqual(real["E0"]["n"], 7 * 3)                              # record 1 alone is real and odd
        self.assertEqual(everything["E0"]["n"], 14 * 3)                       # records 1 and 2
        self.assertIn("pop-anglo", result["by_slice"])
        self.assertIn("LATIN", result["by_script_family"])
        self.assertTrue(result["by_tempo_syllables_per_second"])
        self.assertEqual([row["cap"] for row in result["e4_curve"]], analysis.CAPS)
        self.assertIn(result["e4_best_cap"], analysis.CAPS)

    def test_e4_cap_is_tuned_on_even_tracks_and_scored_on_odd_ones(self):
        """F9: the cap was picked on the same errors it was then scored on."""
        study = analysis.EstimationStudy()
        study.add_record("pop-anglo", self._timed_record(1, seed=1, track="pop-anglo/000"))     # tunes
        study.add_record("pop-anglo", self._timed_record(2, seed=2, track="pop-anglo/002"))     # tunes
        study.add_record("pop-anglo", self._timed_record(3, seed=3, track="pop-anglo/001"))     # scored
        result = study.result()
        split = result["split"]
        self.assertEqual(split["e4_cap_tuned_on"], "even-indexed tracks")
        self.assertEqual(split["all_figures_scored_on"], "odd-indexed tracks")
        self.assertEqual(split["records_and_words_by_half"], {"even": {"records": 2, "words": 42},
                                                              "odd": {"records": 1, "words": 21}})
        self.assertEqual(result["e4_curve"][0]["n"], 42)                    # the curve is the tuning half's
        self.assertEqual(result["overall_all_records"]["E3"]["n"], 21)      # the figures are the scored half's
        self.assertEqual(result["overall_all_records"]["E4"]["n"], 21)
        self.assertEqual(result["overall_all_records"]["E4"]["cap"], result["e4_best_cap"])
        # a corpus with only odd tracks has nothing to tune on: E4 is withheld, not tuned on its own data
        odd_only = analysis.EstimationStudy()
        odd_only.add_record("pop-anglo", self._timed_record(3, seed=3, track="pop-anglo/001"))
        self.assertIsNone(odd_only.result()["e4_best_cap"])
        self.assertNotIn("E4", odd_only.result()["overall_all_records"])
        # with no track_id the record id's parity stands in
        by_id = analysis.EstimationStudy()
        by_id.add_record("pop-anglo", self._timed_record(4, seed=4))
        self.assertEqual(by_id.records[4]["half"], "even")
        self.assertEqual(by_id.records[4]["half_basis"], "record-id")

    def test_interpolated_word_starts_are_never_scored(self):
        """F9: only a word whose start is a tag in the record is scored; a second word inside one
        tagged segment starts at a share of the segment the lab made up."""
        text = ("[00:00.00]<00:00.000>alpha <00:01.000>beta gamma <00:02.000>delta\n"
                "[00:04.00]<00:04.000>eps <00:05.000>zeta\n[00:08.00]")
        lines = analysis.enhanced_lines(text)
        self.assertEqual([w for w, _ in lines[0].words], ["alpha", "beta", "gamma", "delta"])
        self.assertEqual(lines[0].exact, [True, True, False, True])
        self.assertEqual(lines[1].exact, [True, True])
        study = analysis.EstimationStudy()
        study.add_record("x", {"id": 1, "track_id": "x/001", "syncedLyrics": text})
        result = study.result()
        self.assertEqual(result["words_scored"], 2 + 1)                    # beta and delta; zeta
        self.assertEqual(result["interpolated_words_not_scored"], 1)       # gamma
        # a lyricsfile word always has a stated start
        self.assertEqual(analysis.lyricsfile_lines(self.LYRICSFILE)[0].exact, [True, True, True])

    def test_span_end_is_the_next_stamp_so_the_true_last_word_end_is_not_leaked(self):
        """F9: with the old end, an estimator was handed the record's own last-word end."""
        words = [(w, k * 0.5) for k, w in enumerate(["aa", "bb", "cc"])]
        text = enhanced([words, words], step=4.0, tail=True)         # each line's last tag closes at 4.0: own_end
        line = analysis.enhanced_lines(text)[0]
        self.assertEqual((line.own_end, line.next_start), (4.0, 4.0))
        text = ("[00:00.00]<00:00.000>aa <00:00.500>bb <00:01.000>cc<00:01.500>\n"
                "[00:04.00]<00:04.000>dd <00:04.500>ee <00:05.000>ff<00:05.500>\n[00:09.00]")
        first = analysis.enhanced_lines(text)[0]
        self.assertEqual((first.own_end, first.end), (1.5, 4.0))    # the span runs to the next line, not to 1.5

    def test_pair_noise_separates_offset_from_jitter(self):
        base = [(float(i * 4), f"line {i}") for i in range(20)]
        shifted = [(t + 2.0 + (0.1 if i % 2 else -0.1), text) for i, (t, text) in enumerate(base)]
        noise = analysis.pair_noise(shifted, base)
        self.assertAlmostEqual(noise["offset"], 2.0, places=1)
        self.assertAlmostEqual(statistics_median(noise["residuals"]), 0.1, places=2)
        self.assertEqual(noise["aligned"], 20)
        self.assertIsNone(analysis.pair_noise(base[:3], base))                    # too few shared lines
        other = [(t, f"other {i}") for i, (t, _) in enumerate(base)]
        self.assertIsNone(analysis.pair_noise(other, base))

    def test_align_uses_equal_blocks_only(self):
        a = [(0.0, "x"), (1.0, "a"), (2.0, "b"), (3.0, "y")]
        b = [(0.0, "a"), (1.0, "b"), (2.0, "z")]
        self.assertEqual(analysis.align(a, b), [(1, 0), (2, 1)])

    def test_select_pairs_caps_at_ten_and_spreads(self):
        pairs = analysis.select_pairs(list(range(8)))
        self.assertEqual(len(pairs), analysis.MAX_PAIRS_PER_TRACK)
        self.assertGreater(len({x for p in pairs for x in p}), 4)
        self.assertEqual(len(analysis.select_pairs([1, 2, 3])), 3)

    def test_consensus_deviation_names_the_outlier(self):
        base = [(float(i * 4), f"line {i}") for i in range(12)]
        records = {1: base, 2: [(t + 0.05, x) for t, x in base], 3: [(t - 0.05, x) for t, x in base],
                   4: [(t + 1.5, x) for t, x in base]}
        dev = analysis.consensus_deviation(records)
        self.assertEqual(max(dev, key=dev.get), 4)
        self.assertLess(dev[1], 0.1)
        self.assertEqual(analysis.consensus_deviation({1: base, 2: base}), {1: None, 2: None})

    def test_identical_timelines_collapse_to_one_record(self):
        """F10: LRCLIB mirrors one upload onto many releases. Copies agree to the millisecond; two
        of them are one vote, not two."""
        base = [(float(i * 4), f"line {i}") for i in range(12)]
        copy = [(t + 0.004, x) for t, x in base]            # the same stamps to 10 ms
        different = [(t + 0.5, x) for t, x in base]
        kept, groups = analysis.collapse_identical({7: base, 3: copy, 9: different, 5: base})
        self.assertEqual(sorted(kept), [3, 9])               # the lowest id keeps its group
        self.assertEqual({k: sorted(v) for k, v in groups.items()}, {3: [3, 5, 7], 9: [9]})
        kept, _ = analysis.collapse_identical({7: base, 3: copy, 9: different}, prefer=7)
        self.assertEqual(sorted(kept), [7, 9])               # the record being scored stays
        tally = analysis.DuplicateTally()
        tally.add(groups)
        self.assertEqual(tally.result(), {"records_before": 4, "unique_timelines": 2,
                                          "group_sizes": {"1": 1, "3": 1}})

    def test_consensus_leaves_the_scored_record_out_of_its_own_median(self):
        a = [(float(i * 4), f"line {i}") for i in range(12)]
        b = [(t + 1.0, x) for t, x in a]
        c = [(t + 2.0, x) for t, x in a]
        dev = analysis.consensus_deviation({1: a, 2: b, 3: c})
        # a against the median of b and c (1.5 s late) is 1.5 s; with itself in the median it was 1.0 s
        self.assertEqual((dev[1], dev[2], dev[3]), (1.5, 0.0, 1.5))

    def test_noise_study_counts_copies_once(self):
        base = [(float(i * 4), f"line {i}") for i in range(12)]
        records = {1: base, 2: [(t + 0.002, x) for t, x in base], 3: [(t + 1.0, x) for t, x in base],
                   4: [(t - 1.0, x) for t, x in base], 5: base}
        study = analysis.NoiseStudy()
        study.add_track("jazz", records, chosen_id=5)
        cell = study.result()["all"]
        self.assertEqual(cell["pairs"], 3)                   # 3 unique timelines: 3 pairs, not 10
        self.assertEqual(study.duplicate_report(), {"records_before": 5, "unique_timelines": 3,
                                                    "group_sizes": {"1": 2, "3": 1}})
        self.assertEqual(cell["consensus"]["tracks"], 1)     # the chosen copy stands for its group
        # copies alone give no pair at all: perfect agreement is not evidence
        mirrored = analysis.NoiseStudy()
        mirrored.add_track("jazz", {1: base, 2: base, 3: [(t + 0.001, x) for t, x in base]})
        self.assertEqual(mirrored.result(), {})

    def test_noise_study_rank_of_chosen(self):
        base = [(float(i * 4), f"line {i}") for i in range(12)]
        records = {1: base, 2: [(t + 0.05, x) for t, x in base], 3: [(t - 0.05, x) for t, x in base],
                   4: [(t + 1.5, x) for t, x in base]}
        study = analysis.NoiseStudy()
        study.add_track("jazz", records, chosen_id=4)
        study.add_track("jazz", records, chosen_id=1)
        cell = study.result()["all"]
        self.assertEqual(cell["tracks_with_pairs"], 2)
        self.assertEqual(cell["consensus"]["tracks"], 2)
        self.assertEqual(cell["consensus"]["share_chosen_is_closest"], 0.5)
        self.assertGreater(cell["share_offset_over_1s"], 0.0)

    def test_selection_study(self):
        study = analysis.SelectionStudy()
        fit = [{"id": 1, "duration": 200.0, "word_timing": None}, {"id": 2, "duration": 202.0, "word_timing": "enhanced-lrc"}]
        study.add_case("canonical", fit[0], fit, 200.0, {1: 0.4, 2: 0.1})
        study.add_case("canonical", fit[1], fit, 200.0, {1: 0.4, 2: 0.1})
        cell = study.result()["canonical"]
        self.assertEqual(cell["cases"], 2)
        self.assertEqual(cell["picked_closest_length"], 0.5)
        self.assertEqual(cell["median_length_gain_s_when_not_closest"], 2.0)
        self.assertEqual((cell["word_timed_available_cases"], cell["picked_word_timed_when_available"]), (2, 0.5))
        self.assertEqual(cell["picked_closest_to_consensus"], 0.5)
        self.assertAlmostEqual(cell["median_consensus_gain_s_when_not_closest"], 0.3)


def statistics_median(values):
    import statistics
    return statistics.median(values)


def seed_track(root, index, h, get_row, ta_rows, q_rows, apple_ms=200000, answer_q=True, slice_id="pop-anglo"):
    """Put the cached answers resolve.run needs for one harvested track.
    `answer_q=False` leaves the `q` search unanswered (an LRCLIB query that
    failed, which the resolver notes as lrclib-unanswered)."""
    def put(url, body, status=200):
        common.write_cache(root, url, status, json.dumps(body).encode())
    t = resolve.normalize_harvest(h, slice_id, index)
    hit = {"trackName": h["title"], "artistName": h["artists"][0], "collectionName": "Alb",
           "trackTimeMillis": apple_ms, "trackId": index, "primaryGenreName": "Pop"}
    put(resolve.itunes_url(f"{h['title']} Alb", "us"), {"resultCount": 1, "results": [hit]})
    urls = resolve.lrclib_search_urls(t)
    put(urls["search:track_artist"], ta_rows)
    if answer_q:
        put(urls["search:q"], q_rows)
    get = resolve.lrclib_get_url(t, apple_ms / 1000.0, "Alb")
    if get_row is None:
        put(get, {"message": "not found"}, 404)
    else:
        put(get, get_row)


class LabFixture(unittest.TestCase):
    """A synthetic corpus root: eight tracks resolved offline, fabricated
    Isla lookups against them, then classify.run over the lot. Each track is
    built so exactly one verdict rule is the interesting one."""

    root = None
    report = None

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = cls.tmp.name
        os.makedirs(os.path.join(cls.root, "slices"))
        cls.build()
        with contextlib.redirect_stdout(io.StringIO()):
            resolve.run(cls.root, offline=True)
            cls.write_results()
            cls.report = classify.run(cls.root)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    # -- building -----------------------------------------------------------

    @classmethod
    def put_py(cls, url, body, status=200):
        common.write_cache(cls.root, url, status, json.dumps(body).encode())

    @classmethod
    def seed(cls, index, h, get_row, ta_rows, q_rows, apple_ms=200000, answer_q=True):
        seed_track(cls.root, index, h, get_row, ta_rows, q_rows, apple_ms, answer_q=answer_q)

    @classmethod
    def build(cls):
        cls.alpha = synthetic_lines(200)
        cls.other = synthetic_lines(201)
        half = cls.alpha[:12] + synthetic_lines(202)[:12]
        cls.half = half
        tracks = [
            harvest(title="Alpha Song", artists=["Artist A"], album="Alb", pick="popular", tags=["feat"]),
            harvest(title="Beta Song", artists=["Artist B"], album="Alb", vocal="none", language="zxx", pick="stress", tags=["instrumental"]),
            harvest(title="Gamma Song", artists=["Artist G"], album="Alb"),
            harvest(title="Delta Song", artists=["Artist D"], album="Alb"),
            harvest(title="Echo Song", artists=["Artist E"], album="Alb"),
            harvest(title="Fox Song", artists=["Artist F"], album="Alb", language="ja"),
            harvest(title="Golf Song", artists=["Artist Q"], album="Alb"),
            harvest(title="Hotel Song", artists=["Artist H"], album="Alb"),
            harvest(title="India Song", artists=["Artist I"], album="Alb"),
            harvest(title="Juliet Song", artists=["Artist J"], album="Alb"),
            harvest(title="Kilo Song", artists=["Artist K"], album="Alb"),
            harvest(title="Lima Song", artists=["Artist L"], album="Alb", vocal="none", language="zxx"),
            harvest(title="Mike Song", artists=["Artist M"], album="Alb"),
            harvest(title="November Song", artists=["Artist N"], album="Alb"),
            harvest(title="Oscar Song", artists=["Artist O"], album="Alb"),
        ]
        dump(os.path.join(cls.root, "slices", "pop-anglo.json"), {"slice": "pop-anglo", "tracks": tracks})
        word_row = record(4, "Alpha Song", "Artist A", cls.alpha[:20], 201.0,
                          syncedLyrics=enhanced([[(w, k * 0.7) for k, w in enumerate(l.split()[:4])]
                                                 for l in cls.alpha[:20]]))
        cls.rows = {
            1: record(1, "Alpha Song", "Artist A", cls.alpha, 200.0),
            2: record(2, "Alpha Song", "Artist A", cls.alpha, 205.0),
            3: record(3, "Alpha Song", "Other Band", cls.other, 200.0),
            4: word_row,
        }
        cls.seed(0, tracks[0], cls.rows[1], [cls.rows[2], cls.rows[4]], [cls.rows[3]])
        instr = record(11, "Beta Song", "Artist B", [], 180.0, instrumental=True, plainLyrics="", syncedLyrics="")
        mislabel = record(12, "Beta Song", "Artist B", synthetic_lines(210), 180.0)
        cls.rows.update({11: instr, 12: mislabel})
        cls.seed(1, tracks[1], None, [instr, mislabel], [], 180000)
        plain = record(21, "Gamma Song", "Artist G", synthetic_lines(220), 200.0, syncedLyrics="")
        cls.rows[21] = plain
        cls.seed(2, tracks[2], None, [plain], [])
        ghost = record(999, "Delta Song", "Artist D", synthetic_lines(230), 200.0)
        cls.rows[999] = ghost
        cls.seed(3, tracks[3], None, [], [])
        echo = record(31, "Echo Song", "Artist E", synthetic_lines(240), 250.0)
        cls.rows[31] = echo
        cls.seed(4, tracks[4], None, [], [echo], 250000)
        han = han_lines(1)
        cls.rows.update({41: record(41, "Fox Song", "Artist F", han, 200.0),
                         42: record(42, "Fox Song", "Artist F", han[:6], 200.0),
                         43: record(43, "Fox Song", "Artist F", synthetic_lines(250), 200.0)})
        cls.seed(5, tracks[5], None, [cls.rows[41], cls.rows[42], cls.rows[43]], [])
        cls.rows[51] = record(51, "Golf Song", "Artist Q", synthetic_lines(260), 205.0)
        cls.seed(6, tracks[6], None, [cls.rows[51]], [])
        cls.rows[61] = record(61, "Hotel Song", "Artist H", cls.alpha, 200.0)
        cls.rows[62] = record(62, "Hotel Song", "Artist H", half, 200.0)
        cls.seed(7, tracks[7], None, [cls.rows[61]], [])
        # 8: nothing in the resolver's pool, and the only record Isla saw has another title.
        cls.rows[801] = record(801, "Elsewhere Song", "Artist I", synthetic_lines(270), 200.0)
        cls.seed(8, tracks[8], None, [], [])
        # 9: the only right-length record is a karaoke upload under another artist.
        juliet = synthetic_lines(280)
        cls.rows[91] = record(91, "Juliet Song", "Artist J", juliet, 230.0)
        cls.rows[92] = record(92, "Juliet Song (Karaoke)", "Karaoke Band", juliet, 200.0)
        cls.seed(9, tracks[9], None, [cls.rows[91], cls.rows[92]], [])
        # 10: two uploads under the right title and artist that are different songs.
        cls.rows[101] = record(101, "Kilo Song", "Artist K", synthetic_lines(290), 200.0)
        cls.rows[102] = record(102, "Kilo Song", "Artist K", synthetic_lines(291), 200.0)
        cls.seed(10, tracks[10], None, [cls.rows[101], cls.rows[102]], [])
        # 11: an instrumental by LRCLIB's own flag; the lyrics Isla showed are not in the pool.
        cls.rows[111] = record(111, "Lima Song", "Artist L", [], 180.0, instrumental=True, plainLyrics="", syncedLyrics="")
        cls.rows[112] = record(112, "Some Other Title", "Artist Z", synthetic_lines(300), 180.0)
        cls.rows[113] = record(113, "Lima Song", "Artist L", synthetic_lines(301), 180.0)
        cls.seed(11, tracks[11], None, [cls.rows[111]], [], 180000)
        # 12: no anchor, and one LRCLIB search went unanswered.
        cls.rows[121] = record(121, "Unrelated Title", "Artist Y", synthetic_lines(310), 200.0)
        cls.seed(12, tracks[12], None, [], [], answer_q=False)
        # 13: a right-length record exists; Isla's requests were refused or failed.
        cls.rows[131] = record(131, "November Song", "Artist N", synthetic_lines(320), 200.0)
        cls.seed(13, tracks[13], None, [cls.rows[131]], [])
        # 14: the right-length record is stamped 30 s past its own end (a longer cut's timing).
        cls.rows[141] = record(141, "Oscar Song", "Artist O", synthetic_lines(330), 200.0,
                               syncedLyrics=synced(synthetic_lines(330), step=10.0))
        cls.seed(14, tracks[14], None, [cls.rows[141]], [])

    @classmethod
    def isla_response(cls, name, body, status=200):
        url = f"https://lrclib.net/api/{name}"
        common.write_cache(cls.root, url, status, json.dumps(body).encode(), sub="isla")
        return {"key": common.url_key(url), "path": "/api/" + name.split("?")[0], "status": status, "cached": True}

    @classmethod
    def write_results(cls):
        variants = {(v["track_id"], v["variant"]): v for v in
                    (json.loads(l) for l in slurp(os.path.join(cls.root, "resolved", "variants.jsonl")).splitlines())}

        def lookup(tid, variant, outcome, chosen=None, requests=(), longer=False, gran="line"):
            base = variants.get((f"pop-anglo/{tid:03d}", variant)) or variants[(f"pop-anglo/{tid:03d}", "canonical")]
            return {"track_id": f"pop-anglo/{tid:03d}", "variant": variant,
                    "identity": {"player_id": base["player_id"], "title": base["title"], "artist": base["artist"],
                                 "album": base["album"], "duration": base["duration"]},
                    "outcome": outcome, "chosen_id": chosen, "chosen_ambiguous": [], "chosen_via": "get" if chosen else None,
                    "granularity": gran if outcome == "found" else None, "lines": 24 if chosen else None,
                    "overrun": False, "timed_for_longer": longer, "requests": list(requests), "ms": 5}

        r = cls.isla_response

        def refused(status):
            return {"key": None, "path": "/api/get", "status": status, "cached": True}
        rows = cls.rows
        rows_out = [
            lookup(0, "canonical", "found", 1, [r("get?alpha", rows[1])]),
            lookup(0, "no-album", "none", None, [r("search?alpha-empty", [])]),
            lookup(0, "apple", "found", 3, [r("search?alpha-wrong", [rows[3]])]),
            lookup(0, "spotify-style", "none", None, [r("search?alpha-rejected", [rows[1]])]),
            lookup(0, "deezer", "found", 1, [r("get?alpha-longer", rows[1])], longer=True),
            lookup(0, "apple-us", "failed"), lookup(0, "latin-alt", "unreadable"),
            lookup(0, "x-uncached", "uncached"), lookup(0, "x-unrecovered", "found", None, [r("search?alpha-unrec", [rows[3]])]),
            lookup(1, "canonical", "found", 12, [r("search?beta", [rows[12]])]),
            lookup(1, "apple", "none", None, [r("search?beta-none", [])]),
            lookup(2, "canonical", "none", None, [r("search?gamma", [rows[21]])]),
            lookup(3, "canonical", "none", None, [r("get?delta", {"message": "x"}, 404)]),
            lookup(3, "apple", "found", 999, [r("search?delta", [rows[999]])]),
            lookup(4, "canonical", "none", None, [r("get?echo", {"message": "x"}, 404)]),
            lookup(5, "canonical", "found", 43, [r("search?fox-latin", [rows[43]])]),
            lookup(5, "apple", "found", 41, [r("search?fox-han", [rows[41]])], gran="word"),
            lookup(6, "canonical", "none", None, [r("get?golf", {"message": "x"}, 404)]),
            lookup(7, "canonical", "found", 62, [r("search?hotel", [rows[62]])]),
            lookup(8, "canonical", "found", 801, [r("search?india", [rows[801]])]),
            lookup(9, "canonical", "none", None, [r("get?juliet", {"message": "x"}, 404)]),
            lookup(9, "apple", "found", 92, [r("search?juliet-karaoke", [cls.rows[92]])]),
            lookup(10, "canonical", "found", 101, [r("search?kilo", [rows[101]])]),
            lookup(10, "apple", "none", None, [r("get?kilo", {"message": "x"}, 404)]),
            lookup(11, "canonical", "found", 112, [r("search?lima", [rows[112]])]),
            lookup(11, "apple", "none", None, [r("search?lima-none", [])]),
            lookup(11, "deezer", "found", 113, [r("search?lima-mislabel", [rows[113]])]),
            lookup(12, "canonical", "none", None, [r("get?mike", {"message": "x"}, 404)]),
            lookup(12, "apple", "found", 121, [r("search?mike", [rows[121]])]),
            lookup(13, "canonical", "failed", None, [refused(400)]),
            lookup(13, "apple", "failed", None, [refused(500)]),
            lookup(13, "deezer", "failed", None, [refused(404)]),
            lookup(13, "spotify-style", "failed", None, [refused(429)]),
            lookup(13, "latin-alt", "failed", None),
            lookup(14, "canonical", "none", None, [r("search?oscar", [rows[141]])]),
            lookup(14, "apple", "none", None, [r("get?oscar", {"message": "x"}, 404)]),
            lookup(14, "deezer", "found", 141, [r("search?oscar-longer", [rows[141]])], longer=True),
        ]
        os.makedirs(os.path.join(cls.root, "results"), exist_ok=True)
        with open(os.path.join(cls.root, "results", "isla-lookups.jsonl"), "w", encoding="utf-8") as handle:
            for row in rows_out:
                handle.write(json.dumps(row) + "\n")
        pert = [
            {"track_id": "pop-anglo/000", "perturbation": "t-feat", "applicable": True, "base_id": 1, "picked_id": 1},
            {"track_id": "pop-anglo/000", "perturbation": "t-feat", "applicable": True, "base_id": 1, "picked_id": 2},
            {"track_id": "pop-anglo/000", "perturbation": "a-comma", "applicable": True, "base_id": 1, "picked_id": None},
            {"track_id": "pop-anglo/000", "perturbation": "a-comma", "applicable": True, "base_id": 1, "picked_id": 3},
            {"track_id": "pop-anglo/000", "perturbation": "c-upper", "applicable": True, "base_id": 3, "picked_id": 1},
            {"track_id": "pop-anglo/000", "perturbation": "c-upper", "applicable": False, "base_id": 1, "picked_id": 1},
            {"track_id": "pop-anglo/000", "perturbation": "d-plus-3.5", "applicable": True, "base_id": 1, "picked_id": None},
            # F4: both null is not applicable; a new pick from nothing is found-new or switched-wrong;
            # losing a wrong base is a good outcome; leaving the cluster for the other script is switched-alt.
            {"track_id": "pop-anglo/000", "perturbation": "s-latin", "applicable": True, "base_id": None, "picked_id": None},
            {"track_id": "pop-anglo/000", "perturbation": "s-latin", "applicable": True, "base_id": None, "picked_id": 1},
            {"track_id": "pop-anglo/000", "perturbation": "s-latin", "applicable": True, "base_id": None, "picked_id": 3},
            {"track_id": "pop-anglo/000", "perturbation": "s-latin", "applicable": True, "base_id": 3, "picked_id": None},
            {"track_id": "pop-anglo/005", "perturbation": "s-latin", "applicable": True, "base_id": 41, "picked_id": 43},
            {"track_id": "pop-anglo/005", "perturbation": "s-latin", "applicable": True, "base_id": 41, "picked_id": None},
        ]
        with open(os.path.join(cls.root, "results", "perturbations.jsonl"), "w", encoding="utf-8") as handle:
            for row in pert:
                handle.write(json.dumps(row) + "\n")
        dump(os.path.join(cls.root, "results", "word-fidelity.json"), {"parsed": 3, "verdict": "pass", "summary": "ok"})
        dump(os.path.join(cls.root, "results", "readability.json"), {"lines": 10})

    # -- reading ------------------------------------------------------------

    @classmethod
    def verdicts(cls):
        import csv
        out = {}
        with open(os.path.join(cls.root, "reports", "rows.csv"), encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                out[(row["track_id"], row["variant"])] = row
        return out


class ClassifyTests(LabFixture):
    def v(self, tid, variant):
        return self.verdicts()[(f"pop-anglo/{tid:03d}", variant)]

    def test_resolver_truth_the_cases_rest_on(self):
        tracks = [json.loads(l) for l in slurp(os.path.join(self.root, "resolved", "tracks.jsonl")).splitlines()]
        by = {t["track_id"]: t["truth"] for t in tracks}
        self.assertEqual(sorted(by["pop-anglo/000"]["cluster_ids"]), [1, 2, 4])
        self.assertEqual(by["pop-anglo/001"]["truth_status"], "instrumental")
        self.assertEqual(by["pop-anglo/003"]["truth_status"], "no-anchor")
        self.assertTrue(by["pop-anglo/002"]["plain_only"])
        self.assertEqual(by["pop-anglo/005"]["alt_script_ids"], [43])
        self.assertEqual(by["pop-anglo/006"]["per_variant"]["canonical"]["synced_near"], [51])
        self.assertEqual(by["pop-anglo/010"]["truth_status"], "truth-uncertain")     # F2: anchors contradict
        self.assertIn("anchor-conflict", by["pop-anglo/010"]["notes"])
        self.assertEqual(by["pop-anglo/012"]["truth_status"], "no-anchor")           # F7: and a search went unanswered
        self.assertTrue(any(n.startswith("lrclib-unanswered") for n in by["pop-anglo/012"]["notes"]))
        self.assertEqual(by["pop-anglo/001"]["instrumental_disagreement"], "harvest-none-lrclib-lyrics")   # F8

    def test_verdicts(self):
        expected = {
            (0, "canonical"): "correct", (0, "apple"): "wrong-song", (0, "deezer"): "correct-longer-cut",
            (0, "no-album"): "miss-unqueried", (0, "spotify-style"): "miss-rejected",
            (0, "apple-us"): "failed", (0, "latin-alt"): "unreadable", (0, "x-uncached"): "uncached",
            (0, "x-unrecovered"): "unrecovered",
            # F8: the harvest says instrumental and LRCLIB holds lyrics: neither is the truth.
            (1, "canonical"): "disputed", (1, "apple"): "disputed",
            (2, "canonical"): "miss-plain-only",
            # F7: the resolver's pool had no anchor; the record Isla's own answers held anchors it.
            (3, "canonical"): "miss-unqueried", (3, "apple"): "correct",
            (4, "canonical"): "miss-unqueried",
            (5, "canonical"): "alt-script", (5, "apple"): "correct",
            (6, "canonical"): "miss-tolerance",
            (7, "canonical"): "uncertain",
            (8, "canonical"): "unjudged",
            (9, "canonical"): "miss-text-only",                                   # F3
            (10, "canonical"): "truth-uncertain", (10, "apple"): "truth-uncertain",  # F2
            (11, "canonical"): "wrong-song", (11, "apple"): "correct-none",
            (11, "deezer"): "wrong-song",
            (12, "canonical"): "truth-incomplete", (12, "apple"): "truth-incomplete",  # F7
            (13, "canonical"): "failed-request", (13, "apple"): "failed",       # F5
            (13, "deezer"): "failed", (13, "spotify-style"): "failed", (13, "latin-alt"): "failed",
            (14, "canonical"): "miss-rejected", (14, "apple"): "miss-unqueried",  # F13
            (14, "deezer"): "correct-longer-cut",
        }
        actual = {k: self.v(*k)["verdict"] for k in expected}
        self.assertEqual(actual, expected)

    def test_flags_and_evidence_columns(self):
        beta = self.v(1, "canonical")
        self.assertEqual(beta["flags"], "instrumental-fp;catalogue-mislabel;was-wrong-song")
        self.assertEqual(beta["truth_status"], "instrumental")
        self.assertEqual(self.v(11, "canonical")["flags"], "instrumental-fp")
        self.assertEqual(self.v(11, "deezer")["flags"], "instrumental-fp;catalogue-mislabel")
        self.assertEqual(self.v(3, "apple")["flags"], "anchor-promoted")
        self.assertEqual(self.v(13, "canonical")["flags"], "http-400")
        self.assertEqual(self.v(14, "canonical")["flags"], "overrun-only")
        self.assertEqual((self.v(14, "canonical")["isla_saw_fit"], self.v(14, "apple")["isla_saw_fit"]),
                         ("true", "false"))
        self.assertEqual((self.v(9, "canonical")["fit_n"], self.v(9, "canonical")["fit_identity_n"]), ("1", "0"))
        wrong = self.v(0, "apple")
        self.assertEqual(float(wrong["containment"]), 0.0)
        self.assertEqual((self.v(0, "no-album")["isla_saw_fit"], self.v(0, "spotify-style")["isla_saw_fit"]),
                         ("false", "true"))
        self.assertEqual(self.v(0, "canonical")["fit_n"], "2")        # records 1 and 4
        self.assertEqual(self.v(0, "canonical")["near_n"], "1")       # record 2 is 5 s off
        self.assertEqual(self.v(0, "deezer")["timed_for_longer"], "true")
        uncertain = float(self.v(7, "canonical")["containment"])
        self.assertTrue(0.2 < uncertain < 0.6, uncertain)
        self.assertEqual(self.v(2, "canonical")["cluster_n"], "1")

    def test_csv_columns_and_no_lyric_text(self):
        header = slurp(os.path.join(self.root, "reports", "rows.csv")).splitlines()[0].split(",")
        self.assertEqual(header, classify.CSV_COLUMNS)
        needle = self.alpha[0].split()[0]
        for name in ("rows.csv", "match-lab-report.json", "diagnose-input.jsonl"):
            self.assertNotIn(self.alpha[0], slurp(os.path.join(self.root, "reports", name)), name)
        self.assertNotIn(self.alpha[3], slurp(os.path.join(self.root, "reports", "match-lab-report.json")))
        self.assertTrue(needle)

    def test_headline_counts(self):
        m1 = self.report["M1"]
        canonical = m1["canonical"]
        # canonical lookups: 0 correct, 1 disputed, 2 plain, 3 unqueried (anchored from Isla's answers),
        # 4 unqueried, 5 alt, 6 tolerance, 7 uncertain, 8 unjudged, 9 text-only, 10 truth-uncertain,
        # 11 wrong (an instrumental), 12 truth-incomplete, 13 failed-request, 14 rejected (overrun-only)
        self.assertEqual(canonical["lookups"], 15)
        self.assertEqual(canonical["verdicts"]["correct"], 1)
        # tracks 0, 4, 5 (alt has fit via 41/42), 7, 13 (failed-request counts as a miss), 14; track 3,
        # anchored from Isla's own answers, is out of the headline and counted apart (second review, finding 2)
        self.assertEqual(canonical["usable"], 6)
        self.assertEqual(canonical["accuracy"], round(1 / 6, 4))
        self.assertEqual(canonical["shown"], 4)          # correct, alt-script, uncertain, and track 11's lyrics
        self.assertEqual(canonical["wrong"], 2)          # wrong-song + uncertain
        self.assertEqual(canonical["wrong_rate"], 0.5)
        self.assertEqual(canonical["recoverable_misses"], 2)   # tracks 4 and 14 (3 is promoted)
        self.assertEqual(canonical["text_only_misses"], 1)
        self.assertEqual(canonical["excluded_from_scoring"],
                         {"truth-uncertain": 1, "truth-incomplete": 1, "disputed": 1, "anchor-promoted": 1})
        self.assertEqual(m1["overall"]["excluded_from_scoring"],
                         {"truth-uncertain": 2, "truth-incomplete": 2, "disputed": 2, "anchor-promoted": 2})
        # the promoted track's lookups keep their verdicts and are scored on their own
        promoted = m1["anchor_promoted"]
        self.assertEqual((promoted["lookups"], promoted["usable"], promoted["correct"], promoted["accuracy"]),
                         (2, 2, 1, 0.5))
        self.assertEqual(promoted["verdicts"], {"correct": 1, "miss-unqueried": 1})
        self.assertEqual(m1["verdict"], "fail")
        for cut_name in ("by_slice", "by_variant", "by_slice_variant", "by_pick", "by_tag", "by_script_family"):
            self.assertTrue(m1[cut_name], cut_name)
        self.assertIn("pop-anglo | canonical", m1["by_slice_variant"])
        self.assertEqual(sorted(m1["by_pick"]), ["popular", "stress"])
        self.assertIn("instrumental", m1["by_tag"])
        self.assertIn("CJK", m1["by_script_family"])
        self.assertEqual([(u["track_id"], u["variant"]) for u in m1["unjudged"]], [("pop-anglo/008", "canonical")])
        self.assertEqual(m1["anchor_promoted_tracks"], 1)

    def test_diagnose_input(self):
        rows = [json.loads(l) for l in slurp(os.path.join(self.root, "reports", "diagnose-input.jsonl")).splitlines()]
        by = {(r["track_id"], r["variant"]): r for r in rows}
        self.assertEqual(set(r["verdict"] for r in rows) <= set(classify.DIAGNOSE), True)
        self.assertNotIn(("pop-anglo/000", "canonical"), by)            # correct is not diagnosed
        tolerance = by[("pop-anglo/006", "canonical")]
        self.assertEqual((tolerance["verdict"], tolerance["fit_ids"]), ("miss-tolerance", [51]))
        unqueried = by[("pop-anglo/004", "canonical")]
        self.assertEqual(unqueried["fit_ids"], [31])
        self.assertEqual(unqueried["found_by"], {"31": ["search:q"]})
        self.assertEqual(len(unqueried["request_keys"]), 1)
        self.assertEqual(sorted(unqueried["identity"]), ["album", "artist", "duration", "player_id", "title"])
        wrong = by[("pop-anglo/000", "apple")]
        self.assertEqual((wrong["chosen_id"], wrong["cluster_ids"]), (3, [1, 2, 4]))
        self.assertEqual(by[("pop-anglo/014", "canonical")]["fit_ids"], [141])             # the overrun-fit
        self.assertEqual(by[("pop-anglo/014", "apple")]["found_by"], {"141": ["search:track_artist"]})
        self.assertNotIn(("pop-anglo/009", "canonical"), by)                            # text-only is reported, not diagnosed
        self.assertIn(("pop-anglo/000", "x-unrecovered"), by)
        self.assertNotIn(("pop-anglo/001", "apple"), by)                # correct-none is not diagnosed

    def test_matched_corpus_format(self):
        base = os.path.join(self.root, "matched")
        names = sorted((d, f) for d in os.listdir(base) for f in os.listdir(os.path.join(base, d)))
        # canonical correct/alt-script picks: 1 (track 0) and 43 (track 5); the wrong, uncertain and nothing are not matched
        self.assertEqual(names, [("pop-anglo", "1.json"), ("pop-anglo", "43.json")])
        row = json.loads(slurp(os.path.join(base, "pop-anglo", "1.json")))
        self.assertEqual((row["id"], row["category"]), (1, "pop-anglo"))
        for key in ("duration", "syncedLyrics", "trackName"):
            self.assertIn(key, row)
        self.assertEqual(self.report["M5"]["records"], 2)

    def test_perturbation_buckets(self):
        m2 = self.report["M2"]["perturbations"]
        self.assertEqual((m2["t-feat"]["kept"], m2["t-feat"]["applicable"]), (2, 2))     # 2 is in the cluster
        self.assertEqual(m2["a-comma"]["lost"], 1)
        self.assertEqual(m2["a-comma"]["switched-wrong"], 1)
        self.assertEqual(m2["a-comma"]["examples"]["switched-wrong"], ["pop-anglo/000"])
        self.assertEqual(m2["c-upper"]["switched-ok"], 1)
        self.assertEqual(m2["c-upper"]["applicable"], 1)                                  # the inapplicable row is out
        self.assertEqual(self.report["M2"]["verdict"], "fail")                            # 2 switched-wrong of 10

    def test_variant_transition_matrix(self):
        m6 = self.report["M6"]
        self.assertEqual(m6["transitions"]["apple"]["correct"], {"wrong-song": 1})       # track 0
        lost = m6["lost_by_variant"]["apple"]
        self.assertEqual((lost["tracks"], lost["examples"]), (1, ["pop-anglo/000"]))
        self.assertEqual(lost["by_verdict"], {"wrong-song": 1})
        self.assertNotIn("apple-us", m6["lost_by_variant"])                               # failed lookups are not losses
        # F5: nor are they in the denominator: apple-us, x-uncached and x-unrecovered gave no answer
        for name in ("apple-us", "x-uncached", "x-unrecovered"):
            self.assertNotIn(name, m6["comparable_by_variant"])
        self.assertEqual(m6["comparable_by_variant"]["apple"], 1)

    def test_sections_and_verbatim_merges(self):
        for name in ("M1", "M2", "M3", "M3a", "M4", "M5", "M6", "M9", "M10"):
            section = self.report[name]
            self.assertIn(section["verdict"], ("pass", "concern", "fail", "info", "incomplete"), name)
            self.assertTrue(section["summary"], name)
        self.assertEqual(self.report["M3a"]["parsed"], 3)
        self.assertEqual(self.report["M4"]["lines"], 10)
        self.assertEqual(self.report["M4"]["verdict"], "info")                            # added: the file had none
        saved = json.loads(slurp(os.path.join(self.root, "reports", "match-lab-report.json")))
        self.assertEqual(saved["M1"]["summary"], self.report["M1"]["summary"])

    def test_coverage_counts_word_timed_tracks_and_granularity(self):
        cov = self.report["M3"]["coverage_by_slice"]["pop-anglo"]
        self.assertEqual(cov["tracks"], 15)
        self.assertEqual(cov["tracks_with_word_timed_record_in_cluster"], 1)
        self.assertEqual(cov["found_lookups_by_granularity"].get("word"), 1)
        self.assertEqual(self.report["M3"]["estimation"]["records"], 1)

    def test_missing_inputs_degrade_instead_of_failing(self):
        with tempfile.TemporaryDirectory() as empty:
            os.makedirs(os.path.join(empty, "resolved"))
            open(os.path.join(empty, "resolved", "tracks.jsonl"), "w").close()
            with contextlib.redirect_stdout(io.StringIO()):
                report = classify.run(empty)
            self.assertEqual(report["M1"]["verdict"], "info")
            self.assertEqual(report["M3a"]["verdict"], "info")
            self.assertTrue(os.path.exists(os.path.join(empty, "reports", "rows.csv")))

    def test_rerun_is_stable_and_removes_stale_matched_files(self):
        stale = os.path.join(self.root, "matched", "pop-anglo", "123456.json")
        dump(stale, {"id": 123456})
        with contextlib.redirect_stdout(io.StringIO()):
            again = classify.run(self.root)
        self.assertFalse(os.path.exists(stale))
        self.assertEqual(again["M1"]["summary"], self.report["M1"]["summary"])

    # -- the adversarial review's fixes, one test each ------------------------------

    def test_usable_excludes_unrecovered_and_environment_failures_but_not_failed_requests(self):
        usable = {k: self.v(*k)["usable"] for k in
                  [(0, "x-unrecovered"), (0, "x-uncached"), (0, "apple-us"), (13, "apple"), (13, "canonical"),
                   (9, "canonical"), (14, "canonical"), (0, "canonical")]}
        self.assertEqual(usable, {
            (0, "x-unrecovered"): "false",     # F12: like failed, nothing can be said of Isla
            (0, "x-uncached"): "false", (0, "apple-us"): "false", (13, "apple"): "false",
            (13, "canonical"): "true",         # F5: a 400 is a refusal of Isla's own request
            (9, "canonical"): "false",         # F3: a karaoke upload is not recoverable
            (14, "canonical"): "true",         # F13: an overrun-fit Isla would have shown is
            (0, "canonical"): "true"})

    def test_usable_is_decided_from_the_truth_not_from_what_isla_showed(self):
        """Second review, finding 3: `correct` used to be usable with no fit while every other outcome
        needed one, so Isla showing a karaoke upload under another artist grew the denominator and
        showing nothing did not."""
        shown, nothing = self.v(9, "apple"), self.v(9, "canonical")
        self.assertEqual((shown["verdict"], nothing["verdict"]), ("correct", "miss-text-only"))
        self.assertEqual((shown["usable"], nothing["usable"]), ("false", "false"))
        self.assertEqual(self.report["M1"]["overall"]["correct_without_fit"], 1)
        self.assertEqual(self.report["M1"]["canonical"]["correct_without_fit"], 0)
        # where an identity-matching fit exists the lookup is usable whatever Isla did
        self.assertEqual([self.v(0, name)["usable"] for name in ("canonical", "apple", "no-album", "deezer")],
                         ["true"] * 4)
        # and an overrun-only record that Isla showed flagged, or did not show, is usable alike
        self.assertEqual([self.v(14, name)["usable"] for name in ("canonical", "apple", "deezer")], ["true"] * 3)

    def test_text_only_fit_is_reported_apart_from_recoverable_misses(self):
        self.assertEqual(self.v(9, "canonical")["verdict"], "miss-text-only")
        canonical = self.report["M1"]["canonical"]
        self.assertEqual(canonical["text_only_misses"], 1)
        self.assertNotIn("pop-anglo/009", [d["track_id"] for d in
                                           map(json.loads, slurp(os.path.join(
                                               self.root, "reports", "diagnose-input.jsonl")).splitlines())])

    def test_perturbation_denominators_and_new_buckets(self):
        cell = self.report["M2"]["perturbations"]["s-latin"]
        self.assertEqual(cell["applicable"], 5)                    # the both-null row is not applicable
        self.assertEqual((cell["found-new"], cell["switched-wrong"], cell["dropped-wrong"],
                          cell["switched-alt"], cell["lost"]), (1, 1, 1, 1, 1))
        self.assertEqual(cell["base_in_cluster"], 2)
        self.assertEqual(cell["lost_share"], 0.5)                  # of the rows with a base pick in the cluster
        self.assertEqual(self.report["M2"]["both_null_rows"], 1)
        self.assertIn("lost <= 0.02 of the rows whose base pick is in the song",
                      self.report["M2"]["thresholds"]["pass"])

    def test_perturbation_verdict_rules_on_synthetic_rows(self):
        clusters, alts = {"t": {1, 2}}, {"t": {9}}

        def verdict(rows):
            return classify.perturbation_section(
                [dict(r, track_id="t", applicable=True, perturbation="c-x") for r in rows], clusters, alts)

        self.assertEqual(verdict([{"base_id": 1, "picked_id": 1}] * 50 + [{"base_id": None, "picked_id": None}] * 50
                                 )["verdict"], "pass")
        # base null with a pick in the cluster is good; outside it is switched-wrong
        self.assertEqual(verdict([{"base_id": None, "picked_id": 2}] * 3)["perturbations"]["c-x"]["found-new"], 3)
        self.assertEqual(verdict([{"base_id": None, "picked_id": 5}] * 3)["verdict"], "fail")
        # a wrong base lost is not a loss
        self.assertEqual(verdict([{"base_id": 5, "picked_id": None}, {"base_id": 1, "picked_id": 1}])["verdict"], "pass")
        # the lost share is over rows with a base in the cluster, not all applicable rows
        lost = verdict([{"base_id": 1, "picked_id": None}] + [{"base_id": 5, "picked_id": None}] * 99)
        self.assertEqual(lost["perturbations"]["c-x"]["lost_share"], 1.0)
        self.assertEqual(lost["verdict"], "concern")

    def test_m2_buckets_treat_alt_script_as_the_song_and_a_wrong_to_wrong_move_as_no_new_harm(self):
        """Second review, finding 7: a base outside the cluster moving to a different outside row, and an
        alt-script base moving to another alt-script row, were switched-wrong and fed the 0.01 fail threshold."""
        clusters, alts = {"t": {1, 2}}, {"t": {8, 9}}

        def cell(rows):
            section = classify.perturbation_section(
                [dict(r, track_id="t", applicable=True, perturbation="c-x") for r in rows], clusters, alts)
            return section, section["perturbations"]["c-x"]

        section, c = cell([{"base_id": 5, "picked_id": 6}] * 100 + [{"base_id": 1, "picked_id": 1}] * 100)
        self.assertEqual((c["wrong-to-wrong"], c["switched-wrong"], section["verdict"]), (100, 0, "pass"))
        self.assertEqual(c["wrong-to-wrong_share"], 0.5)
        self.assertEqual(c["base_in_cluster"], 100)                     # the wrong bases had nothing to lose
        # an alt-script base: another alt row or the cluster is fine, nothing is lost, outside is wrong
        _, c = cell([{"base_id": 8, "picked_id": 9}, {"base_id": 8, "picked_id": 1}, {"base_id": 8, "picked_id": None},
                     {"base_id": 8, "picked_id": 5}])
        self.assertEqual((c["kept"], c["lost"], c["switched-wrong"], c["base_in_cluster"]), (2, 1, 1, 4))
        # the right song in another script replacing a wrong base is an improvement, not wrong
        _, c = cell([{"base_id": 5, "picked_id": 9}, {"base_id": 1, "picked_id": 9}])
        self.assertEqual((c["switched-ok"], c["switched-alt"], c["switched-wrong"]), (1, 1, 0))
        # a real switch still fails the section
        section, c = cell([{"base_id": 1, "picked_id": 5}] + [{"base_id": 1, "picked_id": 1}] * 10)
        self.assertEqual((c["switched-wrong"], section["verdict"]), (1, "fail"))

    def test_alternate_results_and_reports_directories(self):
        """F18: a candidate run is scored beside the baseline, and never replaces matched/."""
        results_dir = os.path.join(self.root, "results")
        exp = os.path.join(self.root, "candidate")
        os.makedirs(exp, exist_ok=True)
        rows = [json.loads(l) for l in slurp(os.path.join(results_dir, "isla-lookups.jsonl")).splitlines()]
        # the candidate shows nothing for track 0's canonical lookup
        for row in rows:
            if (row["track_id"], row["variant"]) == ("pop-anglo/000", "canonical"):
                row.update(outcome="none", chosen_id=None, chosen_via=None)
        with open(os.path.join(exp, "isla-lookups.jsonl"), "w", encoding="utf-8") as handle:
            for row in rows:
                handle.write(json.dumps(row) + "\n")
        baseline_report = slurp(os.path.join(self.root, "reports", "match-lab-report.json"))
        baseline_csv = slurp(os.path.join(self.root, "reports", "rows.csv"))
        sentinel = os.path.join(self.root, "matched", "pop-anglo", "sentinel.json")
        dump(sentinel, {"id": 0})
        with contextlib.redirect_stdout(io.StringIO()):
            report = classify.run(self.root, results_name="candidate", reports_name="candidate-reports")
        out = os.path.join(self.root, "candidate-reports")
        self.assertEqual(sorted(os.listdir(out)), ["diagnose-input.jsonl", "match-lab-report.json", "rows.csv"])
        self.assertEqual(slurp(os.path.join(self.root, "reports", "match-lab-report.json")), baseline_report)
        self.assertEqual(slurp(os.path.join(self.root, "reports", "rows.csv")), baseline_csv)
        self.assertTrue(os.path.exists(sentinel), "matched/ was cleared by an experiment")
        self.assertEqual(report["M1"]["canonical"]["verdicts"].get("correct", 0), 0)    # the candidate lost it
        self.assertEqual(self.report["M1"]["canonical"]["verdicts"]["correct"], 1)
        self.assertFalse(report["meta"]["matched_written"])
        self.assertEqual((report["meta"]["results_dir"], report["meta"]["reports_dir"]), ("candidate", "candidate-reports"))
        self.assertEqual(report["M5"]["records"], 0)
        # inputs absent from the alternate results directory degrade, they do not fall back to results/
        self.assertEqual(report["M3a"]["verdict"], "info")
        self.assertFalse(report["meta"]["inputs"]["candidate/perturbations.jsonl"])
        # the command line takes the same names, and refuses a path
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(classify.main(["--root", self.root, "--results", "candidate",
                                            "--reports", "candidate-reports"]), 0)
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                classify.main(["--root", self.root, "--reports", "../escape"])
        self.assertFalse(os.path.exists(os.path.join(os.path.dirname(self.root), "escape")))
        os.remove(sentinel)
        # the default reports directory still rewrites matched/
        with contextlib.redirect_stdout(io.StringIO()):
            classify.run(self.root)
        self.assertEqual(sorted(os.listdir(os.path.join(self.root, "matched", "pop-anglo"))), ["1.json", "43.json"])

    def test_same_and_wrong_come_from_the_families_table(self):
        """F1: SAME and WRONG are per script family. The Hotel Song pick holds about half of the
        cluster's shingles: uncertain at 0.6/0.2, the same song at 0.4/0.1."""
        self.assertEqual(self.v(7, "canonical")["verdict"], "uncertain")
        with mock.patch.dict(oracle.THRESHOLD_TABLE, {"LATIN": (0.4, 0.1)}):
            with contextlib.redirect_stdout(io.StringIO()):
                report = classify.run(self.root, reports_name="threshold-reports")
        rows = {}
        import csv
        with open(os.path.join(self.root, "threshold-reports", "rows.csv"), encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                rows[(row["track_id"], row["variant"])] = row
        self.assertEqual(rows[("pop-anglo/007", "canonical")]["verdict"], "correct")
        self.assertNotEqual(report["M1"]["canonical"]["verdicts"], self.report["M1"]["canonical"]["verdicts"])

    def test_readability_drops_wrong_song_lookups(self):
        """F15: the per-lookup rows let M4 leave out the lyrics of a different song."""
        entry = lambda tid, durations, ratios: {
            "track_id": tid, "slice": "pop-anglo", "lines": len(durations), "durations": durations,
            "cps": [10.0] * len(durations), "sps": [3.0] * len(durations), "low_confidence": 0,
            "surfaces": {"band@560": {"ratios": ratios, "widths": [r * 100 for r in ratios], "rows": [],
                                       "overflow": sum(1 for r in ratios if r > 1)}}}
        data = {"summary": "s", "all": {"surfaces": {"band@560": {"available_pt": 100}}},
                "per_lookup": [entry("a/1", [0.5, 5.0, 4.0], [0.5, 0.6, 0.7]),
                               entry("a/2", [0.2, 0.3, 0.4], [1.5, 1.6, 1.7])]}
        path = os.path.join(self.root, "readability-test.json")
        dump(path, data)
        everything = classify.readability_section(path, set())["without_wrong_song"]
        without = classify.readability_section(path, {"a/2"})["without_wrong_song"]
        self.assertEqual((everything["lookups_excluded"], without["lookups_excluded"]), (0, 1))
        self.assertEqual(everything["all"]["lines"], 6)
        self.assertEqual(without["all"]["lines"], 3)
        self.assertAlmostEqual(without["all"]["share_under_0_6_s"], 1 / 3, places=3)
        self.assertAlmostEqual(everything["all"]["share_under_0_6_s"], 4 / 6, places=3)
        self.assertEqual(without["all"]["surfaces"]["band@560"]["overflow_lines"], 0)
        self.assertEqual(everything["all"]["surfaces"]["band@560"]["overflow_lines"], 3)
        # an older file without per-lookup rows says so instead of guessing
        dump(path, {"summary": "s", "all": {"surfaces": {}}})
        self.assertFalse(classify.readability_section(path, {"a/2"})["without_wrong_song"]["available"])
        os.remove(path)


class ReviewLab(unittest.TestCase):
    """A small synthetic corpus a test builds track by track: `add` the tracks, `seal`
    resolves them offline, `lookup` fabricates what Isla did, `classify` scores it.
    The second adversarial review's findings each get one here."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name
        os.makedirs(os.path.join(self.root, "slices"))
        self.entries = []
        self.counter = 0
        self.variants = {}

    def add(self, title, get_row, ta_rows, q_rows, answer_q=True, apple_ms=200000, **harvest_fields):
        h = harvest(title=title, artists=["Artist " + title.split()[0]], album="Alb", **harvest_fields)
        self.entries.append((h, get_row, ta_rows, q_rows, answer_q, apple_ms))
        return len(self.entries) - 1

    def pool(self, index, get_row=None, ta_rows=(), q_rows=()):
        """What the resolver's queries returned for track `index`."""
        h, _, _, _, answer_q, apple_ms = self.entries[index]
        self.entries[index] = (h, get_row, list(ta_rows), list(q_rows), answer_q, apple_ms)

    def row(self, rid, index, lines, duration=200.0, **extra):
        title, artist = self.entries[index][0]["title"], self.entries[index][0]["artists"][0]
        return record(rid, title, artist, lines, duration, **extra)

    def seal(self):
        dump(os.path.join(self.root, "slices", "pop-anglo.json"),
             {"slice": "pop-anglo", "tracks": [e[0] for e in self.entries]})
        for index, (h, get_row, ta_rows, q_rows, answer_q, apple_ms) in enumerate(self.entries):
            seed_track(self.root, index, h, get_row, ta_rows, q_rows, apple_ms, answer_q=answer_q)
        quiet_run(self.root, offline=True)
        for line in slurp(os.path.join(self.root, "resolved", "variants.jsonl")).splitlines():
            v = json.loads(line)
            self.variants[(v["track_id"], v["variant"])] = v

    def tracks(self):
        return {t["track_id"]: t for t in map(json.loads, slurp(os.path.join(self.root, "resolved", "tracks.jsonl")).splitlines())}

    def lookup(self, index, variant, outcome, chosen=None, answers=(), status=200, requests=None):
        tid = f"pop-anglo/{index:03d}"
        base = self.variants.get((tid, variant)) or self.variants[(tid, "canonical")]
        made = []
        for body in answers:
            self.counter += 1
            url = f"https://lrclib.net/api/search?review={self.counter}"
            common.write_cache(self.root, url, status, json.dumps(body).encode(), sub="isla")
            made.append({"key": common.url_key(url), "path": "/api/search", "status": status, "cached": True})
        return {"track_id": tid, "variant": variant,
                "identity": {"player_id": base["player_id"], "title": base["title"], "artist": base["artist"],
                             "album": base["album"], "duration": base["duration"]},
                "outcome": outcome, "chosen_id": chosen, "chosen_ambiguous": [],
                "chosen_via": "search" if chosen else None,
                "granularity": "line" if chosen else None, "lines": 24 if chosen else None,
                "overrun": False, "timed_for_longer": False,
                "requests": made if requests is None else requests, "ms": 1}

    def classify(self, lookups, **kwargs):
        os.makedirs(os.path.join(self.root, "results"), exist_ok=True)
        with open(os.path.join(self.root, "results", "isla-lookups.jsonl"), "w", encoding="utf-8") as handle:
            for row in lookups:
                handle.write(json.dumps(row) + "\n")
        with contextlib.redirect_stdout(io.StringIO()):
            report = classify.run(self.root, **kwargs)
        import csv
        with open(os.path.join(self.root, kwargs.get("reports_name", "reports"), "rows.csv"), encoding="utf-8", newline="") as handle:
            self.rows = {(r["track_id"], r["variant"]): r for r in csv.DictReader(handle)}
        return report

    def verdict(self, index, variant="canonical"):
        return self.rows[(f"pop-anglo/{index:03d}", variant)]["verdict"]


class DisputedTruthTests(ReviewLab):
    def test_an_instrumental_disagreement_either_way_takes_the_track_out_of_scoring(self):
        """Second review, finding 4: only harvest-none-lrclib-lyrics was disputed. A vocal song whose
        LRCLIB anchors are all instrumental, and anchors that disagree about the flag, are as doubtful."""
        lyrics = synthetic_lines(600)
        flat = dict(instrumental=True, plainLyrics="", syncedLyrics="")
        a = self.add("Alpha Flag", None, [], [])
        b = self.add("Bravo Flag", None, [], [])
        c = self.add("Charlie Flag", None, [], [])
        rows = {1: self.row(1, a, [], **flat),
                2: self.row(2, b, [], **flat), 3: self.row(3, b, lyrics),
                4: self.row(4, c, synthetic_lines(601))}
        self.pool(a, ta_rows=[rows[1]])
        self.pool(b, ta_rows=[rows[2], rows[3]])
        self.pool(c, ta_rows=[rows[4]])
        self.seal()
        truth = {tid: t["truth"] for tid, t in self.tracks().items()}
        self.assertEqual(truth["pop-anglo/000"]["instrumental_disagreement"], "harvest-vocal-lrclib-instrumental")
        self.assertEqual(truth["pop-anglo/001"]["instrumental_disagreement"], "mixed-anchor-flags")
        self.assertIsNone(truth["pop-anglo/002"]["instrumental_disagreement"])
        report = self.classify([
            self.lookup(a, "canonical", "none"), self.lookup(a, "apple", "found", 99, [[rows[4]]]),
            self.lookup(b, "canonical", "found", 3, [[rows[3]]]),
            self.lookup(c, "canonical", "found", 4, [[rows[4]]])])
        self.assertEqual([self.verdict(a), self.verdict(a, "apple"), self.verdict(b), self.verdict(c)],
                         ["disputed", "disputed", "disputed", "correct"])
        canonical = report["M1"]["canonical"]
        self.assertEqual(canonical["excluded_from_scoring"], {"disputed": 2})
        self.assertEqual((canonical["usable"], canonical["shown"]), (1, 1))


class PromotionTests(ReviewLab):
    def test_promoted_tracks_leave_the_headline_and_an_unanswered_one_is_never_promoted(self):
        """Second review, finding 2: promotion rescued only no-anchor tracks where Isla's own responses held
        an identity record, so on them Isla could be right or reject what it saw but never fail to ask."""
        promoted = self.add("Alpha Promo", None, [], [])
        unanswered = self.add("Bravo Promo", None, [], [], answer_q=False)
        plain = self.add("Charlie Promo", None, [], [])
        rows = {1: self.row(1, promoted, synthetic_lines(610)), 5: self.row(5, unanswered, synthetic_lines(611)),
                7: self.row(7, plain, synthetic_lines(612))}
        self.pool(plain, ta_rows=[rows[7]])
        self.seal()
        self.assertEqual(self.tracks()["pop-anglo/001"]["truth"]["truth_status"], "no-anchor")
        report = self.classify([
            self.lookup(promoted, "canonical", "found", 1, [[rows[1]]]),
            self.lookup(promoted, "apple", "none", None, [[]]),
            self.lookup(unanswered, "canonical", "found", 5, [[rows[5]]]),
            self.lookup(plain, "canonical", "found", 7, [[rows[7]]]),
            self.lookup(plain, "apple", "none", None, [[]])])
        # verdicts stay in rows.csv
        self.assertEqual([self.verdict(promoted), self.verdict(promoted, "apple"), self.verdict(unanswered),
                          self.verdict(plain), self.verdict(plain, "apple")],
                         ["correct", "miss-unqueried", "truth-incomplete", "correct", "miss-unqueried"])
        self.assertIn("anchor-promoted", self.rows[("pop-anglo/000", "canonical")]["flags"])
        self.assertNotIn("anchor-promoted", self.rows[("pop-anglo/001", "canonical")]["flags"])
        m1 = report["M1"]
        # the headline holds the one ordinary track only
        self.assertEqual((m1["overall"]["usable"], m1["overall"]["correct"], m1["overall"]["accuracy"]), (2, 1, 0.5))
        self.assertEqual(m1["overall"]["verdicts"], {"correct": 1, "miss-unqueried": 1, "truth-incomplete": 1})
        self.assertEqual(m1["overall"]["excluded_from_scoring"], {"truth-incomplete": 1, "anchor-promoted": 2})
        self.assertEqual(m1["canonical"]["excluded_from_scoring"], {"truth-incomplete": 1, "anchor-promoted": 1})
        self.assertEqual((m1["canonical"]["usable"], m1["canonical"]["accuracy"]), (1, 1.0))
        for name in ("by_slice", "by_variant", "by_pick", "by_script_family"):
            cell = m1[name]
            self.assertEqual(sum(c["usable"] for c in cell.values()), 2, name)
        self.assertEqual(m1["by_variant"]["apple"]["usable"], 1)
        # and they are scored on their own
        self.assertEqual(m1["anchor_promoted"]["verdicts"], {"correct": 1, "miss-unqueried": 1})
        self.assertEqual((m1["anchor_promoted"]["usable"], m1["anchor_promoted"]["accuracy"]), (2, 0.5))
        self.assertEqual(m1["anchor_promoted_tracks"], 1)


class RefusedStatusTests(ReviewLab):
    def test_a_403_is_not_a_refusal_of_isla_s_request(self):
        """Second review, finding 6: neither cache keeps a 403 and the harness reads it as a miss, so the
        classifier must not call a lookup that saw one a failed-request."""
        a = self.add("Alpha Refuse", None, [], [])
        row = self.row(1, a, synthetic_lines(650))
        self.pool(a, ta_rows=[row])
        self.seal()
        refused = lambda status: [{"key": None, "path": "/api/get", "status": status, "cached": False}]
        report = self.classify([self.lookup(a, "canonical", "failed", requests=refused(403)),
                                self.lookup(a, "apple", "failed", requests=refused(400)),
                                self.lookup(a, "deezer", "failed", requests=refused(401))])
        self.assertEqual([self.verdict(a, v) for v in ("canonical", "apple", "deezer")],
                         ["failed", "failed-request", "failed-request"])
        self.assertEqual(report["M1"]["overall"]["failed_request"], 2)


class BoundsTests(ReviewLab):
    def test_accuracy_bounds_count_every_lookup_that_might_have_been_usable(self):
        """Second review, finding 5: the printed 'between X and as_computed' was not an upper bound, and
        M1 could pass with lookups the harness could not attribute or resolver queries unanswered."""
        a = self.add("Alpha Bound", None, [], [])
        b = self.add("Bravo Bound", None, [], [])
        c = self.add("Charlie Bound", None, [], [])
        rows = {i: self.row(i, i - 1, synthetic_lines(620 + i)) for i in (1, 2, 3)}
        for index in (a, b, c):
            self.pool(index, ta_rows=[rows[index + 1]])
        self.seal()
        report = self.classify([
            self.lookup(a, "canonical", "found", 1, [[rows[1]]]),
            self.lookup(b, "canonical", "found", None, [[rows[2]]]),          # unrecovered
            self.lookup(c, "canonical", "failed")])                           # an environment failure
        canonical = report["M1"]["canonical"]
        self.assertEqual((canonical["usable"], canonical["correct"], canonical["unscorable_possibly_usable"]), (1, 1, 1))
        self.assertEqual(canonical["accuracy_bounds"], {"lower": 0.5, "upper": 1.0, "as_computed": 1.0})
        self.assertEqual(report["M1"]["accuracy_bounds"]["canonical"], canonical["accuracy_bounds"])
        self.assertEqual(report["M1"]["verdict"], "incomplete")           # as good as a pass, but one answer is missing
        self.assertIn("[50.0%, 100.0%]", report["M1"]["summary"])
        # the same without the unattributable lookup is a pass, and the bounds close
        report = self.classify([self.lookup(a, "canonical", "found", 1, [[rows[1]]])])
        self.assertEqual(report["M1"]["verdict"], "pass")
        self.assertEqual(report["M1"]["canonical"]["accuracy_bounds"], {"lower": 1.0, "upper": 1.0, "as_computed": 1.0})

    def test_an_unanswered_resolver_query_on_an_anchored_track_makes_m1_incomplete(self):
        a = self.add("Alpha Gap", None, [], [], answer_q=False)
        b = self.add("Bravo Gap", None, [], [])
        rows = {1: self.row(1, a, synthetic_lines(630)), 2: self.row(2, b, synthetic_lines(631))}
        self.pool(a, ta_rows=[rows[1]])
        self.pool(b, ta_rows=[rows[2]])
        self.seal()
        notes = self.tracks()["pop-anglo/000"]["truth"]["notes"]
        self.assertTrue(any(n.startswith("lrclib-unanswered") for n in notes))
        lookups = [self.lookup(a, "canonical", "found", 1, [[rows[1]]]),
                   self.lookup(b, "canonical", "found", 2, [[rows[2]]])]
        report = self.classify(lookups)
        self.assertEqual(report["M1"]["canonical"]["accuracy"], 1.0)
        self.assertEqual((report["M1"]["verdict"], report["M1"]["lrclib_unanswered_tracks"]), ("incomplete", 1))
        self.assertIn("1 anchored tracks had an LRCLIB query go unanswered", report["M1"]["summary"])
        report = self.classify(lookups[1:])
        self.assertEqual((report["M1"]["verdict"], report["M1"]["lrclib_unanswered_tracks"]), ("pass", 0))


class SoleAnchorFromGetTests(ReviewLab):
    def test_tracks_anchored_only_by_the_get_query_are_flagged_and_cut_apart(self):
        """Second review, finding 11: the resolver's /api/get is Isla's own canonical query, so a record only
        it returned can be the sole anchor and make Isla's canonical pick correct by construction."""
        a = self.add("Alpha Get", None, [], [])
        b = self.add("Bravo Get", None, [], [])
        c = self.add("Charlie Get", None, [], [])
        rows = {i: self.row(i, i - 1, synthetic_lines(640 + i)) for i in (1, 2, 3)}
        self.pool(a, get_row=rows[1])                              # only /api/get
        self.pool(b, ta_rows=[rows[2]])                            # only a search
        self.pool(c, get_row=rows[3], ta_rows=[rows[3]])           # both
        self.seal()
        sources = {t: [x["source_queries"] for x in line["candidates"] if x["anchor"]] for t, line in self.tracks().items()}
        self.assertEqual(sources["pop-anglo/000"], [["get"]])
        self.assertEqual(sources["pop-anglo/001"], [["search:track_artist"]])
        self.assertEqual(sources["pop-anglo/002"], [["get", "search:track_artist"]])
        report = self.classify([self.lookup(i, "canonical", "found", i + 1, [[rows[i + 1]]]) for i in (a, b, c)])
        flagged = [self.rows[(f"pop-anglo/{i:03d}", "canonical")]["flags"] for i in (a, b, c)]
        self.assertEqual(flagged, ["sole-anchor-from-get", "", ""])
        cuts = report["M1"]["by_sole_anchor_from_get"]
        self.assertEqual((cuts["yes"]["lookups"], cuts["yes"]["usable"], cuts["no"]["lookups"], cuts["no"]["usable"]),
                         (1, 1, 2, 2))
        self.assertEqual(report["M1"]["canonical"]["usable"], 3)           # flagged, never excluded
        self.assertEqual(report["M1"]["flag_counts"]["sole-anchor-from-get"], 1)


class TruthFamilyTests(unittest.TestCase):
    """classify.Truth reads the group's script family from the oracle's cluster, and
    fingerprints every record it compares in that family (second review, findings 1 and 8)."""

    URL = "https://lrclib.net/api/search?q=family"

    def build(self, rows, anchor_ids, group_family=None, language="ja"):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        common.write_cache(tmp.name, self.URL, 200, json.dumps(rows).encode())
        track = {"track_id": "pop-anglo/000", "slice": "pop-anglo",
                 "harvest": {k: v for k, v in resolve.normalize_harvest(
                     harvest(title="Family Song", artists=["Family Artist"], album="Alb", language=language),
                     "pop-anglo", 0).items() if k not in ("track_id", "slice", "index")},
                 "apple": None, "deezer": None, "apple_us": None,
                 "candidates": [{"id": r["id"], "anchor": r["id"] in anchor_ids} for r in rows],
                 "truth": {"truth_status": "ok", "cluster_ids": list(anchor_ids), "alt_script_ids": [], "notes": []},
                 "lrclib_urls": {"search:q": self.URL}}
        if group_family is not None:
            track["truth"]["group_family"] = group_family
        return tmp.name, track

    def rows(self):
        pure, mixed = OracleTests.japanese_with_latin(510)
        _, more = OracleTests.japanese_with_latin(510, latin_per_line=40)
        # the Latin-dominant anchor comes first, as a first anchor in id order can
        return [record(1, "Family Song", "Family Artist", mixed, 200.0),
                record(2, "Family Song", "Family Artist", pure, 200.0),
                record(3, "Family Song", "Family Artist", more[:18], 200.0)]

    def test_group_family_is_the_clusters_choice_not_the_first_anchors_script(self):
        rows = self.rows()
        with mock.patch.dict(oracle.THRESHOLD_TABLE, {"CJK": (0.5, 0.15), "LATIN": (0.7, 0.3)}):
            # an old tracks.jsonl: no group_family stored, so the anchors are clustered again
            root, track = self.build(rows, [1, 2])
            truth = classify.Truth(root, track)
            self.assertEqual(oracle.dominant_script(oracle.lyric_text(rows[0])), "LATIN")
            self.assertEqual((truth.group_family, truth.same, truth.wrong), ("CJK", 0.5, 0.15))
            # a new one: the resolver's own answer is read as it is
            root, track = self.build(rows, [1, 2], group_family="CJK")
            self.assertEqual(classify.Truth(root, track).group_family, "CJK")
            # and the anchors, whatever their own script, are shingled as the group is
            self.assertTrue(all(" " not in shingle for fp in truth.anchor_fps.values() for shingle in fp))
            info = truth.info(3, rows[2])
            self.assertGreaterEqual(truth.containment(3, info), 0.5)
            self.assertEqual(info["script"], "LATIN")

    def test_resolver_writes_the_group_family_into_the_truth(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "slices"))
            h = harvest(title="Family Song", artists=["Family Artist"], album="Alb", language="ja")
            dump(os.path.join(root, "slices", "pop-anglo.json"), {"slice": "pop-anglo", "tracks": [h]})
            pure, mixed = OracleTests.japanese_with_latin(511)
            seed_track(root, 0, h, record(1, "Family Song", "Family Artist", mixed, 200.0),
                       [record(2, "Family Song", "Family Artist", pure, 200.0)], [])
            quiet_run(root, offline=True)
            line = json.loads(slurp(os.path.join(root, "resolved", "tracks.jsonl")).splitlines()[0])
            self.assertEqual(line["truth"]["group_family"], "CJK")
            self.assertNotIn("anchor-conflict", line["truth"]["notes"])
            self.assertEqual(line["truth"]["truth_status"], "ok")
            self.assertEqual(sorted(line["truth"]["cluster_ids"]), [1, 2])


class MiniLab(unittest.TestCase):
    """One track, resolved offline, with whatever lookups a test writes."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        os.makedirs(os.path.join(self.root, "slices"))
        self.lines = synthetic_lines(400)
        self.row = record(1, "Mini Song", "Artist Mini", self.lines, 200.0)
        dump(os.path.join(self.root, "slices", "pop-anglo.json"),
             {"slice": "pop-anglo", "tracks": [harvest(title="Mini Song", artists=["Artist Mini"], album="Alb")]})
        seed_track(self.root, 0, harvest(title="Mini Song", artists=["Artist Mini"], album="Alb"),
                   self.row, [], [])
        quiet_run(self.root, offline=True)

    def tearDown(self):
        self.tmp.cleanup()

    def lookup(self, variant, outcome, chosen=None):
        url = f"https://lrclib.net/api/get?mini-{variant}"
        common.write_cache(self.root, url, 200, json.dumps(self.row).encode(), sub="isla")
        return {"track_id": "pop-anglo/000", "variant": variant,
                "identity": {"player_id": "lab", "title": "Mini Song", "artist": "Artist Mini", "album": "Alb",
                             "duration": 200.0},
                "outcome": outcome, "chosen_id": chosen, "chosen_ambiguous": [], "chosen_via": "get" if chosen else None,
                "granularity": "line" if chosen else None, "lines": 24, "overrun": False, "timed_for_longer": False,
                "requests": [{"key": common.url_key(url), "path": "/api/get", "status": 200, "cached": True}], "ms": 1}

    def classify(self, rows):
        os.makedirs(os.path.join(self.root, "results"), exist_ok=True)
        with open(os.path.join(self.root, "results", "isla-lookups.jsonl"), "w", encoding="utf-8") as handle:
            for row in rows:
                handle.write(json.dumps(row) + "\n")
        with contextlib.redirect_stdout(io.StringIO()):
            return classify.run(self.root)

    def test_m1_is_incomplete_not_pass_when_a_lookup_is_uncached(self):
        """F6: the lookups the cache could not answer might have been wrong."""
        complete = self.classify([self.lookup("canonical", "found", 1)])
        self.assertEqual(complete["M1"]["verdict"], "pass")
        self.assertEqual(complete["M1"]["canonical"]["accuracy_bounds"],
                         {"lower": 1.0, "upper": 1.0, "as_computed": 1.0})
        partial = self.classify([self.lookup("canonical", "found", 1), self.lookup("canonical-b", "uncached")])
        self.assertEqual(partial["M1"]["verdict"], "incomplete")
        self.assertIn("uncached", partial["M1"]["summary"])
        self.assertEqual(partial["M1"]["overall"]["uncached"], 1)
        # 1 correct of 1 usable; the uncached lookup may have been a usable miss (lower 1/2) or a
        # usable hit (upper 2/2)
        self.assertEqual(partial["M1"]["overall"]["accuracy_bounds"], {"lower": 0.5, "upper": 1.0, "as_computed": 1.0})
        self.assertEqual(partial["M1"]["accuracy_bounds"]["overall"]["lower"], 0.5)
        self.assertIn("[50.0%, 100.0%]", partial["M1"]["summary"])
        self.assertEqual(partial["meta"]["verdict_values"], "pass | concern | fail | info | incomplete")
        # a fail stays a fail
        failing = self.classify([self.lookup("canonical", "none"), self.lookup("canonical-b", "uncached")])
        self.assertEqual(failing["M1"]["verdict"], "fail")

    def test_unrecovered_and_failed_leave_the_usable_count(self):
        report = self.classify([self.lookup("canonical", "found", 1), self.lookup("apple", "found", None),
                                self.lookup("deezer", "failed")])
        overall = report["M1"]["overall"]
        self.assertEqual(overall["usable"], 1)               # only the correct canonical lookup
        self.assertEqual(overall["verdicts"], {"correct": 1, "failed": 1, "unrecovered": 1})
        # M6 leaves both out of the denominator as well
        self.assertEqual(report["M6"]["comparable_by_variant"], {})
        self.assertEqual(report["M6"]["lost_by_variant"], {})


class CalibrateTests(unittest.TestCase):
    """calibrate.py over a synthetic corpus: Thai-script and Latin made-up texts."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        os.makedirs(os.path.join(self.root, "resolved"))
        oracle.reset_calibration()
        self.addCleanup(oracle.reset_calibration)
        tracks = []
        for i in range(14):
            thai = OracleTests.thai_like(100 + i, 900)
            latin = "\n".join(synthetic_lines(500 + i, 20))
            for family, text in (("th", thai), ("en", latin)):
                tid = f"pop-anglo/{family}{i:02d}"
                title, artist = f"Title {family}{i}", f"Artist {family}{i}"
                rows = [
                    {"id": i * 10 + 1, "trackName": title, "artistName": artist, "duration": 200.0, "instrumental": False,
                     "plainLyrics": text, "syncedLyrics": ""},
                    # the same song, a little different, 1 s longer: a positive pair
                    {"id": i * 10 + 2, "trackName": title + " (Remastered)", "artistName": artist, "duration": 201.0,
                     "instrumental": False, "plainLyrics": "\n".join(text.split("\n")[:30]), "syncedLyrics": ""},
                    # the same text 20 s longer: not within 3 s of the others, so no positive pair
                    {"id": i * 10 + 3, "trackName": title, "artistName": artist, "duration": 221.0, "instrumental": False,
                     "plainLyrics": text, "syncedLyrics": ""},
                    # an instrumental and a record by someone else: never used
                    {"id": i * 10 + 4, "trackName": title, "artistName": artist, "duration": 200.0, "instrumental": True,
                     "plainLyrics": "", "syncedLyrics": ""},
                    {"id": i * 10 + 5, "trackName": title, "artistName": "Somebody Else", "duration": 200.0,
                     "instrumental": False, "plainLyrics": text, "syncedLyrics": ""},
                ]
                url = f"https://lrclib.net/api/search?q={tid}"
                common.write_cache(self.root, url, 200, json.dumps(rows).encode())
                tracks.append({
                    "track_id": tid, "slice": "pop-anglo",
                    "harvest": {"title": title, "title_latin": "", "artists": [artist], "artists_latin": [""]},
                    "apple": None, "apple_us": None, "deezer": None,
                    "candidates": [{"id": r["id"], "anchor": r["id"] in (i * 10 + 1, i * 10 + 2, i * 10 + 3)}
                                   for r in rows],
                    "lrclib_urls": {"search:q": url}, "truth": {}})
        with open(os.path.join(self.root, "resolved", "tracks.jsonl"), "w", encoding="utf-8") as handle:
            for t in tracks:
                handle.write(json.dumps(t) + "\n")

    def tearDown(self):
        self.tmp.cleanup()

    def run_calibrate(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(calibrate.main(["--root", self.root, "--max-pairs", "300"]), 0)
        return out.getvalue(), json.loads(slurp(os.path.join(self.root, "reports", "oracle-calibration.json")))

    def test_distributions_per_family_and_n(self):
        printed, result = self.run_calibrate()
        self.assertEqual(sorted(result["families"]), ["LATIN", "THAI"])
        thai = result["families"]["THAI"]
        self.assertEqual(sorted(thai["null"]), ["2", "3", "4", "5", "6"])             # character candidates
        self.assertEqual(sorted(result["families"]["LATIN"]["null"]), ["2", "3", "4"])   # word candidates
        for cell in list(thai["null"].values()) + list(thai["positive"].values()):
            self.assertEqual(sorted(k for k in cell if k.startswith("p")), ["p1", "p5", "p50", "p95", "p99"])
        # null: anchors of different tracks, capped by --max-pairs
        self.assertEqual(thai["null"]["2"]["n"], 300)
        # positive: per track the identity records within 3 s of each other: ids 1 and 2 only
        self.assertEqual(thai["positive"]["2"]["n"], 14)
        self.assertGreater(thai["null"]["2"]["p50"], oracle.DEFAULT_THRESHOLDS[1])   # the bigram failure, reproduced
        self.assertLess(thai["null"]["5"]["p99"], 0.05)
        self.assertGreater(thai["positive"]["5"]["p5"], 0.9)                  # the shorter copy sits inside the longer
        # the table in force when the numbers were taken
        self.assertEqual(thai["table"]["ngram"], 7)
        # it prints numbers only
        for line in printed.splitlines():
            self.assertNotIn("Title", line)
            self.assertNotIn("Artist", line)

    def test_recommendation_and_file(self):
        _, result = self.run_calibrate()
        rec = result["families"]["THAI"]["recommended"]
        # the smallest n whose null p99 is under 0.2 with the positive p5 at least 0.5: 3 over a 49-symbol alphabet
        self.assertEqual(rec["ngram"], 3)
        self.assertTrue(rec["meets_target"])
        self.assertEqual((rec["same"], rec["wrong"]), (0.6, 0.2))
        self.assertEqual(result["families"]["LATIN"]["recommended"]["ngram"], 2)
        self.assertEqual(result["precedence"].split(",")[0], "families[F].recommended")
        # the oracle loads it: the file replaces the table for those families
        self.assertTrue(oracle.load_calibration(self.root))
        self.assertEqual(oracle.shingle_for("THAI"), ("char", 3))
        self.assertEqual(oracle.shingle_for("LATIN"), ("word", 2))
        self.assertEqual(oracle.shingle_for("CJK"), ("char", 5))

    def test_a_family_with_too_few_pairs_gets_no_recommendation(self):
        lines = [json.loads(l) for l in slurp(os.path.join(self.root, "resolved", "tracks.jsonl")).splitlines()]
        keep = [t for t in lines if t["track_id"].startswith("pop-anglo/th") and int(t["track_id"][-2:]) < 2]
        with open(os.path.join(self.root, "resolved", "tracks.jsonl"), "w", encoding="utf-8") as handle:
            for t in keep:
                handle.write(json.dumps(t) + "\n")
        _, result = self.run_calibrate()
        thai = result["families"]["THAI"]
        self.assertEqual(thai["null"]["3"]["n"], 9)                            # 2 tracks of 3 anchors: 9 pairs
        self.assertIsNone(thai["recommended"])
        self.assertFalse(oracle.load_calibration(self.root))                   # nothing to load; the table stays

    def test_a_noisy_family_is_not_recommended_an_n_it_cannot_support(self):
        """When no candidate keeps the null under 0.2, the least bad is named and flagged."""
        # two symbols only: every n-gram collides across unrelated songs
        for line in slurp(os.path.join(self.root, "resolved", "tracks.jsonl")).splitlines():
            t = json.loads(line)
            if not t["track_id"].startswith("pop-anglo/th"):
                continue
            index = int(t["track_id"][-2:])
            rng = random.Random(index)
            text = "".join(rng.choice("กข") for _ in range(300))
            rows = [{"id": index * 10 + 1, "trackName": t["harvest"]["title"], "artistName": t["harvest"]["artists"][0],
                     "duration": 200.0, "instrumental": False, "plainLyrics": text, "syncedLyrics": ""}]
            common.write_cache(self.root, t["lrclib_urls"]["search:q"], 200, json.dumps(rows).encode())
        _, result = self.run_calibrate()
        rec = result["families"]["THAI"]["recommended"]
        self.assertFalse(rec["meets_target"])
        self.assertEqual(rec["ngram"], 6)                                      # the largest n has the lowest p99
        self.assertEqual((rec["wrong"], rec["same"]), (0.9, 1.0))              # WRONG moves up to the measured p99
        self.assertTrue(oracle.load_calibration(self.root))                    # and the pair is one the oracle accepts


class RunnerScriptTests(unittest.TestCase):
    """Scripts/lyric-match-lab.sh with a stand-in `swift` that records its calls and writes the
    files the real cases would. Nothing is built and nothing runs against the network."""

    SCRIPT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lyric-match-lab.sh")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = self.tmp.name
        self.root = os.path.join(base, "root")
        self.bin = os.path.join(base, "bin")
        self.log = os.path.join(base, "swift.log")
        for directory in (os.path.join(self.root, "resolved"), os.path.join(self.root, "reports"),
                          os.path.join(self.root, "results"), self.bin, os.path.join(base, "tmp")):
            os.makedirs(directory)
        with open(os.path.join(self.root, "resolved", "variants.jsonl"), "w") as handle:
            handle.write("{}\n")
        with open(os.path.join(self.root, "reports", "diagnose-input.jsonl"), "w") as handle:
            handle.write("{}\n")      # left by an earlier run: stale against the lookups about to be rewritten
        with open(os.path.join(self.bin, "swift"), "w") as handle:
            handle.write('''#!/bin/bash
echo "out=$ISLA_MATCH_OUT reports=$ISLA_MATCH_REPORTS record=${ISLA_MATCH_RECORD:-} $*" >> "$FAKE_LOG"
out="$ISLA_MATCH_LAB/$ISLA_MATCH_OUT"
mkdir -p "$out"
case "$*" in
  *LyricMatchLabLookupTests*) echo fresh > "$out/isla-lookups.jsonl" ;;
  *LyricMatchLabPerturbationTests*) echo fresh > "$out/perturbations.jsonl"; echo fresh > "$out/word-fidelity.json"; echo fresh > "$out/readability.json"; echo fresh > "$out/sweep-edge.json" ;;
  *LyricMatchLabDiagnosisTests*) echo fresh > "$out/diagnosis.jsonl" ;;
esac
''')
        os.chmod(os.path.join(self.bin, "swift"), 0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *args, **env):
        environment = {"PATH": f"{self.bin}:/usr/bin:/bin", "FAKE_LOG": self.log,
                       "TMPDIR": os.path.join(self.tmp.name, "tmp"), "HOME": self.tmp.name}
        environment.update(env)
        done = subprocess.run(["/bin/bash", self.SCRIPT, self.root, *args], env=environment,
                              capture_output=True, text=True)
        calls = slurp(self.log).splitlines() if os.path.exists(self.log) else []
        return done, calls

    def test_plain_and_record_runs_do_not_run_the_diagnosis(self):
        """F17: the diagnose-input on disk describes the lookups this run replaces."""
        for args in ((), ("--record",)):
            if os.path.exists(self.log):
                os.remove(self.log)
            done, calls = self.run_script(*args)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(len(calls), 2, calls)
            self.assertFalse(any("LyricMatchLabDiagnosisTests" in c for c in calls), calls)
            self.assertIn("diagnosis not run", done.stdout)
            self.assertFalse(os.path.exists(os.path.join(self.root, "results", "diagnosis.jsonl")))
        self.assertIn("record=1", calls[0])

    def test_diagnose_only_runs_it_without_the_record_switch(self):
        done, calls = self.run_script("--diagnose-only", ISLA_MATCH_RECORD="1")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(len(calls), 1)
        self.assertIn("LyricMatchLabDiagnosisTests", calls[0])
        self.assertIn("record= ", calls[0])
        self.assertTrue(os.path.exists(os.path.join(self.root, "results", "diagnosis.jsonl")))

    def test_output_directory_is_passed_through_and_only_its_stale_files_are_removed(self):
        """F18: a candidate run writes beside the baseline, and clears only its own directory."""
        for directory in ("results", "candidate"):
            os.makedirs(os.path.join(self.root, directory), exist_ok=True)
            for name in ("isla-lookups.jsonl", "perturbations.jsonl", "word-fidelity.json", "readability.json",
                         "sweep-edge.json"):
                with open(os.path.join(self.root, directory, name), "w") as handle:
                    handle.write("stale\n")
        done, calls = self.run_script(ISLA_MATCH_OUT="candidate")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertTrue(all(c.startswith("out=candidate ") for c in calls), calls)
        for name in ("isla-lookups.jsonl", "perturbations.jsonl", "word-fidelity.json", "readability.json"):
            self.assertEqual(slurp(os.path.join(self.root, "results", name)), "stale\n", name)
            self.assertEqual(slurp(os.path.join(self.root, "candidate", name)), "fresh\n", name)
        self.assertIn("classify.py", done.stdout)
        self.assertIn("--results candidate", done.stdout)

    def test_diagnose_only_reads_the_named_reports_directory(self):
        os.remove(os.path.join(self.root, "reports", "diagnose-input.jsonl"))
        done, calls = self.run_script("--diagnose-only", ISLA_MATCH_OUT="candidate")
        self.assertEqual(done.returncode, 2)                      # reports/ has nothing for it
        os.makedirs(os.path.join(self.root, "candidate-reports"))
        with open(os.path.join(self.root, "candidate-reports", "diagnose-input.jsonl"), "w") as handle:
            handle.write("{}\n")
        done, calls = self.run_script("--diagnose-only", ISLA_MATCH_OUT="candidate", ISLA_MATCH_REPORTS="candidate-reports")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("out=candidate reports=candidate-reports", calls[0])
        self.assertTrue(os.path.exists(os.path.join(self.root, "candidate", "diagnosis.jsonl")))

    def test_a_path_is_not_a_directory_name(self):
        for bad in ("../elsewhere", "a/b", "..", "."):
            done, calls = self.run_script(ISLA_MATCH_OUT=bad)
            self.assertEqual(done.returncode, 2, bad)
            self.assertEqual(calls, [])


class CompareTests(unittest.TestCase):
    """compare.py ranks a changed verdict by what a listener sees."""

    def test_a_wrong_song_ranks_below_nothing_and_unscorable_is_never_a_gain(self):
        import compare
        self.assertEqual(compare.judge("miss-unqueried", "correct"), "gain")
        self.assertEqual(compare.judge("correct", "wrong-song"), "loss")
        self.assertEqual(compare.judge("wrong-song", "miss-rejected"), "gain")
        self.assertEqual(compare.judge("miss-catalogue", "miss-unqueried"), "same")
        self.assertEqual(compare.judge("correct", "uncached"), "unscorable")
        self.assertEqual(compare.judge("uncached", "correct"), "unscorable")
        self.assertEqual(compare.judge("truth-uncertain", "truth-uncertain"), "same")

    def test_lookups_are_joined_and_counted(self):
        import compare
        columns = ["track_id", "variant", "slice", "pick", "title", "artist", "duration",
                   "verdict", "chosen_id", "chosen_via", "flags"]

        def write(directory, rows, lookups):
            os.makedirs(directory)
            with open(os.path.join(directory, "rows.csv"), "w", encoding="utf-8") as handle:
                handle.write(",".join(columns) + "\n")
                for r in rows:
                    handle.write(",".join(str(r.get(c, "")) for c in columns) + "\n")
            dump(os.path.join(directory, "match-lab-report.json"),
                 {"M1": {"canonical": {"accuracy": 0.5}, "overall": {"accuracy": 0.5}}})
            with open(os.path.join(directory, "isla-lookups.jsonl"), "w", encoding="utf-8") as handle:
                for row in lookups:
                    handle.write(json.dumps(row) + "\n")

        with tempfile.TemporaryDirectory() as root:
            base = [{"track_id": "s/001", "variant": "canonical", "slice": "s", "verdict": "miss-unqueried"},
                    {"track_id": "s/002", "variant": "canonical", "slice": "s", "verdict": "correct", "chosen_id": 7}]
            cand = [{"track_id": "s/001", "variant": "canonical", "slice": "s", "verdict": "correct", "chosen_id": 9},
                    {"track_id": "s/002", "variant": "canonical", "slice": "s", "verdict": "uncached"}]
            write(os.path.join(root, "base"), base, [{"track_id": "s/001", "variant": "canonical", "requests": [1, 2]}])
            write(os.path.join(root, "cand"), cand, [{"track_id": "s/001", "variant": "canonical", "requests": [1, 2, 3]}])
            result = compare.compare(root, "base", "cand", "base", "cand")
        self.assertEqual(result["totals"]["gain"], 1)
        self.assertEqual(result["totals"]["unscorable"], 1)
        self.assertEqual(result["transitions"], {"correct -> uncached": 1, "miss-unqueried -> correct": 1})
        self.assertEqual([r["track_id"] for r in result["needs_recording"]], ["s/002"])
        self.assertEqual(result["requests"]["candidate"]["requests"], 3)


if __name__ == "__main__":
    unittest.main()
