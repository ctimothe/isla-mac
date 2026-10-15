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
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

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
                mock.patch.object(common, "_http_get", side_effect=list(replies)) as http, \
                mock.patch.object(common.time, "sleep") as sleep:
            result = common.fetch(url, self.root, stats=common.Stats(), **kwargs)
        return result, http.call_count, [c.args[0] for c in sleep.call_args_list], gate

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

    def test_fingerprint_uses_bigrams_for_spaceless_scripts(self):
        rng = random.Random(7)
        han = "".join(rng.choice("天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往秋收冬藏") for _ in range(80))
        fp = oracle.fingerprint(han[:40] + "\n" + han[40:])
        self.assertTrue(all(len(s) == 2 for s in fp))
        self.assertEqual(oracle.containment(oracle.fingerprint(han[:50]), fp), 1.0)
        kana = oracle.fingerprint("あいうえお かきくけこ")
        self.assertTrue(all(len(s) == 2 for s in kana))

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

    def test_lyricsfile_word_lines_span_ends_at_the_earlier_of_next_and_own_end(self):
        lines = analysis.lyricsfile_lines(self.LYRICSFILE)
        self.assertEqual([[w for w, _ in l.words] for l in lines], [["one", "two", "three"], ["next", "line"]])
        self.assertEqual((lines[0].start, lines[0].next_start, lines[0].own_end, lines[0].end), (1.0, 6.5, 9.0, 6.5))
        self.assertEqual(lines[1].end, 9.0)       # the last line: its own end only

    def test_enhanced_lines_glue_fragments_and_read_gap_ends(self):
        text = ("[00:00.00]<00:00.000>he<00:00.400>llo <00:01.000>wor<00:01.500>ld <00:02.000>x<00:03.000>\n"
                "[00:04.00]<00:04.000>next <00:05.000>one\n[00:07.00]\n[00:08.00]<00:08.000>last<00:09.500>")
        lines = analysis.enhanced_lines(text)
        self.assertEqual([[w for w, _ in l.words] for l in lines], [["hello", "world", "x"], ["next", "one"], ["last"]])
        self.assertEqual(lines[0].words[1], ("world", 1.0))      # the word keeps its first fragment's time
        self.assertEqual((lines[0].next_start, lines[0].own_end, lines[0].end), (4.0, 3.0, 3.0))
        self.assertEqual(lines[1].next_start, 7.0)                # the empty gap stamp ends the line
        self.assertEqual(lines[2].end, 9.5)
        cjk = analysis.enhanced_lines("[00:00.00]<00:00.000>天<00:00.500>地<00:01.000>玄<00:01.500>")
        self.assertEqual(len(cjk[0].words), 3)                    # spaceless: every segment is a word

    def test_lyricsfile_words_win_over_enhanced_tags(self):
        record = {"lyricsfile": self.LYRICSFILE, "syncedLyrics": "[00:00.00]<00:00.000>zzz<00:01.000>"}
        lines, source = analysis.word_lines(record)
        self.assertEqual(source, "lyricsfile-words")
        self.assertEqual(analysis.word_lines({"syncedLyrics": "[00:01.00]plain"})[1], None)

    def _timed_record(self, rid, estimator=None, seed=1):
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
        return {"id": rid, "syncedLyrics": enhanced(entries)}

    def test_estimation_study_scores_and_flags_estimator_made_records(self):
        study = analysis.EstimationStudy()
        self.assertTrue(study.add_record("pop-anglo", self._timed_record(1)))
        self.assertTrue(study.add_record("pop-anglo", self._timed_record(2, "E1", seed=2)))
        self.assertFalse(study.add_record("pop-anglo", self._timed_record(1)))       # duplicate id
        result = study.result()
        self.assertEqual(result["records"], 2)
        self.assertEqual(result["estimator_made_records"]["E1"], 1)
        self.assertEqual(result["estimator_made_ids"], [2])
        self.assertEqual(result["lines"], 16)
        self.assertEqual(result["words_scored"], 16 * 3)
        everything, real = result["overall_all_records"], result["overall_excluding_estimator_made"]
        self.assertGreater(real["E1"]["p50"], everything["E1"]["p50"])      # the self-made record flatters E1
        self.assertEqual(real["E0"]["n"], 8 * 3)
        self.assertIn("pop-anglo", result["by_slice"])
        self.assertIn("LATIN", result["by_script_family"])
        self.assertTrue(result["by_tempo_syllables_per_second"])
        self.assertEqual([row["cap"] for row in result["e4_curve"]], analysis.CAPS)
        self.assertIn(result["e4_best_cap"], analysis.CAPS)

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
    def seed(cls, index, h, get_row, ta_rows, q_rows, apple_ms=200000):
        t = resolve.normalize_harvest(h, "pop-anglo", index)
        hit = {"trackName": h["title"], "artistName": h["artists"][0], "collectionName": "Alb",
               "trackTimeMillis": apple_ms, "trackId": index, "primaryGenreName": "Pop"}
        cls.put_py(resolve.itunes_url(f"{h['title']} Alb", "us"), {"resultCount": 1, "results": [hit]})
        urls = resolve.lrclib_search_urls(t)
        cls.put_py(urls["search:track_artist"], ta_rows)
        cls.put_py(urls["search:q"], q_rows)
        get = resolve.lrclib_get_url(t, apple_ms / 1000.0, "Alb")
        if get_row is None:
            cls.put_py(get, {"message": "not found"}, 404)
        else:
            cls.put_py(get, get_row)

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

    def test_verdicts(self):
        expected = {
            (0, "canonical"): "correct", (0, "apple"): "wrong-song", (0, "deezer"): "correct-longer-cut",
            (0, "no-album"): "miss-unqueried", (0, "spotify-style"): "miss-rejected",
            (0, "apple-us"): "failed", (0, "latin-alt"): "unreadable", (0, "x-uncached"): "uncached",
            (0, "x-unrecovered"): "unrecovered",
            (1, "canonical"): "wrong-song", (1, "apple"): "correct-none",
            (2, "canonical"): "miss-plain-only",
            (3, "canonical"): "miss-catalogue", (3, "apple"): "unjudged",
            (4, "canonical"): "miss-unqueried",
            (5, "canonical"): "alt-script", (5, "apple"): "correct",
            (6, "canonical"): "miss-tolerance",
            (7, "canonical"): "uncertain",
        }
        actual = {k: self.v(*k)["verdict"] for k in expected}
        self.assertEqual(actual, expected)

    def test_flags_and_evidence_columns(self):
        beta = self.v(1, "canonical")
        self.assertEqual(beta["flags"], "instrumental-fp;catalogue-mislabel")
        self.assertEqual(beta["truth_status"], "instrumental")
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
        # canonical lookups: 0 correct, 1 wrong, 2 plain, 3 catalogue, 4 unqueried, 5 alt, 6 tolerance, 7 uncertain
        self.assertEqual(canonical["lookups"], 8)
        self.assertEqual(canonical["verdicts"]["correct"], 1)
        self.assertEqual(canonical["usable"], 4)        # tracks 0, 4, 5(alt has fit via 41/42), 7
        self.assertEqual(canonical["shown"], 4)          # correct, wrong, alt-script, uncertain
        self.assertEqual(canonical["wrong"], 2)          # wrong-song + uncertain
        self.assertEqual(canonical["wrong_rate"], 0.5)
        self.assertEqual(canonical["recoverable_misses"], 1)
        self.assertEqual(m1["verdict"], "fail")
        for cut_name in ("by_slice", "by_variant", "by_slice_variant", "by_pick", "by_tag", "by_script_family"):
            self.assertTrue(m1[cut_name], cut_name)
        self.assertIn("pop-anglo | canonical", m1["by_slice_variant"])
        self.assertEqual(sorted(m1["by_pick"]), ["popular", "stress"])
        self.assertIn("instrumental", m1["by_tag"])
        self.assertIn("CJK", m1["by_script_family"])
        self.assertEqual([u["variant"] for u in m1["unjudged"]], ["apple"])

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
        self.assertEqual(self.report["M2"]["verdict"], "fail")                            # 1 switched-wrong of 5

    def test_variant_transition_matrix(self):
        m6 = self.report["M6"]
        self.assertEqual(m6["transitions"]["apple"]["correct"], {"wrong-song": 1})       # track 0
        lost = m6["lost_by_variant"]["apple"]
        self.assertEqual((lost["tracks"], lost["examples"]), (1, ["pop-anglo/000"]))
        self.assertEqual(lost["by_verdict"], {"wrong-song": 1})
        self.assertNotIn("apple-us", m6["lost_by_variant"])                               # failed lookups are not losses

    def test_sections_and_verbatim_merges(self):
        for name in ("M1", "M2", "M3", "M3a", "M4", "M5", "M6", "M9", "M10"):
            section = self.report[name]
            self.assertIn(section["verdict"], ("pass", "concern", "fail", "info"), name)
            self.assertTrue(section["summary"], name)
        self.assertEqual(self.report["M3a"]["parsed"], 3)
        self.assertEqual(self.report["M4"]["lines"], 10)
        self.assertEqual(self.report["M4"]["verdict"], "info")                            # added: the file had none
        saved = json.loads(slurp(os.path.join(self.root, "reports", "match-lab-report.json")))
        self.assertEqual(saved["M1"]["summary"], self.report["M1"]["summary"])

    def test_coverage_counts_word_timed_tracks_and_granularity(self):
        cov = self.report["M3"]["coverage_by_slice"]["pop-anglo"]
        self.assertEqual(cov["tracks"], 8)
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


if __name__ == "__main__":
    unittest.main()
