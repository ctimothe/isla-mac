#!/usr/bin/env python3
"""The lab's oracle: decides which LRCLIB records are the same song.

Independent of Isla on purpose. Nothing here ports `OnlineLyrics.comparable`,
`baseTitle` or `primaryArtist`; if the lab reused Isla's matcher to grade
Isla's matcher, a shared blind spot would score as a pass. The normalizer,
the title and artist rules and the lyric fingerprint are written from the
SPEC ("Resolution", step 5) alone.

Imported by resolve.py (truth for each harvested track) and, in phase 2, by
classify.py (to fingerprint the record Isla chose and compare it with the
cluster). Stdlib only, no network. Pure functions, with one exception:
`load_calibration` reads reports/oracle-calibration.json when a caller asks.

    import oracle
    oracle.normalize_title("Song (Remastered 2011)")            # "song"
    oracle.artist_match(["Queen"], "Queen, David Bowie")         # True
    fp = oracle.fingerprint(oracle.lyric_text(record))
    oracle.containment(fp, other_fp)                             # 0.0 .. 1.0
    oracle.cluster(candidates, anchor_ids)                       # see its docstring
"""
from __future__ import annotations

import json
import os
import re
import unicodedata
from typing import Dict, FrozenSet, Iterable, List, Optional

# --------------------------------------------------------------------------
# Scripts
# --------------------------------------------------------------------------

_KNOWN_SCRIPTS = {
    "LATIN", "CYRILLIC", "GREEK", "ARABIC", "HEBREW", "DEVANAGARI", "GURMUKHI",
    "TAMIL", "THAI", "HANGUL", "HIRAGANA", "KATAKANA", "BENGALI", "TELUGU",
    "KANNADA", "MALAYALAM", "GUJARATI", "ORIYA", "SINHALA", "ARMENIAN",
    "GEORGIAN", "ETHIOPIC", "KHMER", "LAO", "MYANMAR", "TIBETAN", "SYRIAC",
    "THAANA", "MONGOLIAN",
}

# Scripts written without spaces between words: their fingerprints are
# character n-grams (NGRAM_TABLE), because word shingles of one giant "word" match nothing.
NO_SPACE_SCRIPTS = {"CJK", "HIRAGANA", "KATAKANA", "THAI", "LAO", "KHMER", "MYANMAR", "TIBETAN"}

# Han, hiragana and katakana mix freely inside one Japanese line, so for "is
# this the same script as the anchors" they are one family. Chinese against
# Japanese is not told apart; the text containment does that.
_FAMILIES = {"CJK": "CJK", "HIRAGANA": "CJK", "KATAKANA": "CJK", "BOPOMOFO": "CJK"}

# Which script a song of this language is sung in. Used only to break a tie
# when anchors split evenly between scripts; the title's own script is a poor
# guide (a Japanese song with a Latin title is still Japanese).
LANGUAGE_SCRIPT = {
    "ja": "CJK", "zh": "CJK", "yue": "CJK", "ko": "HANGUL",
    "ru": "CYRILLIC", "uk": "CYRILLIC", "be": "CYRILLIC", "kk": "CYRILLIC",
    "bg": "CYRILLIC", "sr": "CYRILLIC", "mk": "CYRILLIC", "mn": "CYRILLIC",
    "ar": "ARABIC", "fa": "ARABIC", "ur": "ARABIC", "ps": "ARABIC",
    "he": "HEBREW", "yi": "HEBREW", "hi": "DEVANAGARI", "mr": "DEVANAGARI",
    "ne": "DEVANAGARI", "pa": "GURMUKHI", "ta": "TAMIL", "te": "TELUGU",
    "kn": "KANNADA", "ml": "MALAYALAM", "bn": "BENGALI", "gu": "GUJARATI",
    "th": "THAI", "el": "GREEK", "hy": "ARMENIAN", "ka": "GEORGIAN",
}


def char_script(ch: str) -> str:
    """Script of one character from its Unicode name, "" for none/unknown."""
    try:
        name = unicodedata.name(ch)
    except ValueError:
        return ""
    first = name.split(" ", 1)[0]
    if first in _KNOWN_SCRIPTS:
        return first
    if first == "CJK" or "IDEOGRAPH" in name:
        return "CJK"
    if "LATIN" in name:
        return "LATIN"  # FULLWIDTH LATIN …, MODIFIER LETTER … LATIN
    if "KATAKANA-HIRAGANA" in name:
        return ""  # the prolonged-sound mark belongs to both kana
    if "KATAKANA" in name:
        return "KATAKANA"
    if "HIRAGANA" in name:
        return "HIRAGANA"
    if "HANGUL" in name:
        return "HANGUL"
    if first == "BOPOMOFO":
        return "BOPOMOFO"
    return ""


def script_family(script: str) -> str:
    return _FAMILIES.get(script, script)


# Han, kana and Hangul carry about a word in every character, a Latin letter
# a fraction of one, so counting letters one for one made a Korean lyric that
# is half English read as LATIN (adversarial review F2, 2026-10-15). Each such
# character weighs this many letters.
CHARACTER_SCRIPT_WEIGHT = 2.5
_HEAVY_SCRIPTS = {"CJK", "HIRAGANA", "KATAKANA", "HANGUL"}


def script_weights(text: str, by_family: bool = False) -> Dict[str, float]:
    """Weighted letters per script in `text` (family names with `by_family`).

    A Han, kana or Hangul character counts CHARACTER_SCRIPT_WEIGHT letters,
    every other letter one. Digits, punctuation and marks carry no script.
    """
    counts: Dict[str, float] = {}
    for ch in unicodedata.normalize("NFKC", text or ""):
        if not unicodedata.category(ch).startswith("L"):
            continue
        script = char_script(ch)
        if not script:
            continue
        key = script_family(script) if by_family else script
        counts[key] = counts.get(key, 0.0) + (CHARACTER_SCRIPT_WEIGHT if script in _HEAVY_SCRIPTS else 1.0)
    return counts


def dominant_script(text: str) -> str:
    """The script with the most weighted letters in `text`; "" when it has none.

    Built from character names so it needs no tables per code point. Digits,
    punctuation and marks are ignored: they carry no script. See
    `script_weights` for the weighting.
    """
    counts = script_weights(text)
    if not counts:
        return ""
    return max(counts.items(), key=lambda item: (item[1], item[0]))[0]


def family_share(text_or_weights, family: str) -> float:
    """The fraction of weighted letters that belong to script family `family`."""
    weights = text_or_weights if isinstance(text_or_weights, dict) else script_weights(text_or_weights, True)
    total = sum(weights.values())
    return (weights.get(family, 0.0) / total) if total else 0.0


def expected_script(language: str, native_title: str = "") -> str:
    """Script the song's own lyrics should be in, from its language, else its title."""
    return LANGUAGE_SCRIPT.get((language or "").lower()) or dominant_script(native_title) or "LATIN"


# --------------------------------------------------------------------------
# Normalizing
# --------------------------------------------------------------------------

# Deleted, not turned into spaces: "don't", "don’t" and "dont" must agree, and
# so must the Uzbek "oʻ" spelled with ʻ, ʼ, ' or ‘. U+02BB/02BC are letters
# (Lm) to Unicode, so they would otherwise survive and split spellings.
_APOSTROPHES = set("'’‘ʻʼʹ`´′ʽʾʿ")

# Latin letters that do not decompose, so mark-stripping leaves them alone.
_LATIN_FOLDS = str.maketrans({
    "ø": "o", "ł": "l", "đ": "d", "ð": "d", "ı": "i", "ħ": "h",
    "æ": "ae", "œ": "oe", "þ": "th",
})

# Combining marks are stripped only after these scripts. Stripping them from
# Devanagari, Thai or Hebrew would delete vowels and corrupt the word; kana
# keeps its dakuten for the same reason.
_MARK_FOLD_SCRIPTS = {"LATIN", "CYRILLIC", "GREEK"}


def normalize_text(text: str) -> str:
    """NFKC, casefold, combining marks off (Latin/Cyrillic/Greek bases),
    punctuation and symbols to spaces, apostrophes deleted, spaces collapsed.
    """
    if not text:
        return ""
    folded = unicodedata.normalize("NFKC", text).casefold()
    folded = unicodedata.normalize("NFKC", folded).translate(_LATIN_FOLDS)
    out: List[str] = []
    base_script = ""
    for ch in unicodedata.normalize("NFD", folded):
        category = unicodedata.category(ch)
        if category == "Mn":
            if base_script in _MARK_FOLD_SCRIPTS:
                continue
            out.append(ch)
        elif ch in _APOSTROPHES or category == "Cf":
            continue
        elif category[0] in "PSZ" or category == "Cc":
            out.append(" ")
        else:
            if category[0] == "L":
                base_script = char_script(ch)
            out.append(ch)
    return " ".join(unicodedata.normalize("NFC", "".join(out)).split())


_BRACKET_PAIRS = [
    ("(", ")"), ("[", "]"), ("{", "}"), ("<", ">"), ("〈", "〉"), ("《", "》"),
    ("「", "」"), ("『", "』"), ("【", "】"), ("〔", "〕"), ("〖", "〗"),
    ("⟨", "⟩"), ("«", "»"), ("‹", "›"),
]
_BRACKET_RES = [re.compile(re.escape(o) + r"[^" + re.escape(o + c) + r"]*" + re.escape(c))
                for o, c in _BRACKET_PAIRS]

_FEAT_RE = re.compile(r"\b(?:feat|ft|featuring)\b\.?.*$", re.IGNORECASE)
_DASHES = re.compile(r"\s[–—‒―−]\s")

# A trailing " - X" is dropped only when X names an edition. Titles with a real
# subtitle after a dash ("Pt. 2", "Part Two", an artist name) must keep it,
# or two different songs would collapse into one.
_EDITION_RE = re.compile(
    r"\b(?:remaster(?:ed)?|live|version|ver|edit|mix|remix|mono|stereo|deluxe|"
    r"bonus|single|album|radio|acoustic|demo|instrumental|explicit|clean|"
    r"original|soundtrack|anniversary|reprise|extended|session|sessions|"
    r"unplugged|from|karaoke|cover|outtake|rehearsal|edition|rework|remake|"
    r"(?:19|20)\d\d)\b", re.IGNORECASE)


def strip_brackets(text: str) -> str:
    """Remove every bracketed segment of every family, nested ones included."""
    changed = True
    while changed:
        changed = False
        for pattern in _BRACKET_RES:
            replaced = pattern.sub(" ", text)
            if replaced != text:
                text, changed = replaced, True
    return text


def replace_brackets(text: str, decide) -> str:
    """Rewrite bracketed segments, innermost first.

    `decide(inner, whole)` returns the replacement string, or None to keep the
    segment as it is. resolve.py uses it to take edition and feat. brackets out
    of a title while leaving "(I Can't Get No) Satisfaction" alone.
    """
    for _ in range(8):
        changed = False
        for pattern in _BRACKET_RES:
            def swap(match):
                nonlocal changed
                replacement = decide(match.group(0)[1:-1], match.group(0))
                if replacement is None:
                    return match.group(0)
                changed = True
                return replacement
            text = pattern.sub(swap, text)
        if not changed:
            break
    return text


def normalize_title(text: str) -> str:
    """Title identity: normalize_text after dropping brackets, a feat. clause
    and a trailing " - <edition>". Falls back to the plain normalization when
    stripping leaves nothing ("(Untitled)", "[ ]").
    """
    if not text:
        return ""
    prepared = _DASHES.sub(" - ", unicodedata.normalize("NFKC", text))
    stripped = strip_brackets(prepared)
    while True:
        head, sep, tail = stripped.rpartition(" - ")
        if sep and head.strip() and _EDITION_RE.search(tail):
            stripped = head
        else:
            break
    stripped = _FEAT_RE.sub("", stripped)
    result = normalize_text(stripped)
    return result or normalize_text(text) or _symbol_key(text)


def _symbol_key(text: str) -> str:
    """Titles made only of symbols ("÷", "!!!") normalize to nothing, and an
    empty string equals every other empty string. Compare their characters."""
    key = re.sub(r"\s+", "", unicodedata.normalize("NFKC", text or "").casefold())
    return "sym:" + key if key else ""


_ARTIST_SPLIT = re.compile(
    r"\s*(?:,|;|/|&|\+|×|\bfeat\.?|\bft\.?|\bfeaturing\b|\bwith\b)\s*|\s+(?:x|and|и)\s+",
    re.IGNORECASE)


def normalize_artist(text: str) -> str:
    """normalize_text without a leading "the", a " - Topic" tail or "and"."""
    if not text:
        return ""
    cleaned = re.sub(r"\s*-\s*topic\s*$", "", text, flags=re.IGNORECASE)
    tokens = [t for t in normalize_text(cleaned).split() if t != "and"]
    if len(tokens) > 1 and tokens[0] == "the":
        tokens = tokens[1:]
    return " ".join(tokens)


def _is_subsequence(needle: List[str], haystack: List[str]) -> bool:
    it = iter(haystack)
    return all(token in it for token in needle)


def _artists_related(a: str, b: str) -> bool:
    """Token subsequence either way (SPEC), with one guard: a lone short token
    ("bad", "a") must equal the other side, or it would match every artist
    whose name merely contains it."""
    if not a or not b:
        return False
    if a == b:
        return True
    ta, tb = a.split(), b.split()
    short, long_ = (ta, tb) if len(ta) <= len(tb) else (tb, ta)
    if len(short) == 1 and len(short[0]) < 4:
        return False
    return _is_subsequence(short, long_)


def artist_match(names: Iterable[str], record_artist: str) -> bool:
    """Does any of `names` (harvested, Latin, Apple, Deezer) name the record's
    artist? Each whole name is compared with the whole record artist and with
    each credited piece of it ("A, B", "A & B", "A feat. B", "A x B")."""
    record_forms = {normalize_artist(record_artist)}
    for piece in _ARTIST_SPLIT.split(record_artist or ""):
        record_forms.add(normalize_artist(piece))
    record_forms.discard("")
    for name in names:
        wanted = normalize_artist(name)
        if wanted and any(_artists_related(wanted, form) for form in record_forms):
            return True
    return False


def title_match(titles: Iterable[str], record_title: str) -> bool:
    """Equal after normalization: either plainly, or with editions, brackets and
    feat. clauses dropped on both sides."""
    plain = normalize_text(record_title) or _symbol_key(record_title)
    loose = normalize_title(record_title)
    for title in titles:
        if not title:
            continue
        if (normalize_text(title) or _symbol_key(title)) == plain or normalize_title(title) == loose:
            return True
    return False


# --------------------------------------------------------------------------
# Latin aliases of Cyrillic names (anchor matching only)
# --------------------------------------------------------------------------

# BGN/PCGN romanization of Russian, Ukrainian and Kazakh, lower case (the
# matcher casefolds anyway). Deterministic on purpose: the lab must be able to
# say why a Latin-only upload of a Cyrillic song did or did not anchor, and a
# learned or service-supplied romanization would make that unfalsifiable.
# The soft and hard signs come out as apostrophes, which normalize_text drops.
_CYR_BASE = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "ж": "zh", "з": "z",
    "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o",
    "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh",
    "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch", "ъ": "'", "ы": "y",
    "ь": "'", "э": "e", "ю": "yu", "я": "ya",
    # Ukrainian
    "ґ": "g", "і": "i", "ї": "yi",
    # Kazakh
    "ә": "a", "ғ": "gh", "қ": "q", "ң": "ng", "ө": "o", "ұ": "u", "ү": "u", "һ": "h",
}
_CYR_UKRAINIAN_OVERRIDES = {"г": "h", "и": "y"}
_CYR_YE = {"е": "e", "ё": "e", "є": "e"}   # "ye" at a word start or after a vowel/sign
_CYR_VOWELS = set("аеёиоуыэюяіїєәөұү") | {"ъ", "ь", "й"}


def _is_cyrillic_text(text: str) -> bool:
    return any(char_script(ch) == "CYRILLIC" for ch in text)


def transliterate_cyrillic(text: str, ukrainian: bool = False) -> str:
    """BGN/PCGN Latin form of a Cyrillic string; other characters pass through."""
    out: List[str] = []
    previous = ""
    for ch in (text or "").casefold():
        if ch in _CYR_YE:
            starts = (not previous) or (not previous.isalpha()) or previous in _CYR_VOWELS
            out.append("ye" if starts else "e")
        elif ch in _CYR_BASE:
            out.append(_CYR_UKRAINIAN_OVERRIDES.get(ch, _CYR_BASE[ch]) if ukrainian else _CYR_BASE[ch])
        else:
            out.append(ch)
        previous = ch
    return "".join(out)


def latin_aliases(text: str) -> List[str]:
    """Latin spellings to try for a Cyrillic title or artist; [] for any other
    text. The strict BGN/PCGN form, the same with Ukrainian letter values, and
    one loosened form (kh to h, ye to e) because uploads romanise by ear, as
    in "Hochesh" for "Хочешь". Used to find anchors only, never as an identity
    a player would send."""
    if not text or not _is_cyrillic_text(text):
        return []
    forms = [transliterate_cyrillic(text), transliterate_cyrillic(text, ukrainian=True)]
    forms.append(forms[0].replace("kh", "h").replace("ye", "e").replace("yo", "o"))
    seen, out = set(), []
    for form in forms:
        key = normalize_text(form)
        if key and key not in seen:
            seen.add(key)
            out.append(form)
    return out


# --------------------------------------------------------------------------
# Lyric text
# --------------------------------------------------------------------------

_TIME = r"\d{1,3}:\d{2}(?:[.:,]\d{1,3})?"
_STAMP_RE = re.compile(r"\[" + _TIME + r"\]")
_WORD_TAG_RE = re.compile(r"<" + _TIME + r">")
_META_TAG_RE = re.compile(
    r"\[(?:ar|ti|al|au|by|length|offset|re|ve|tool|id|la|lang|comment|#):[^\]\n]*\]",
    re.IGNORECASE)
_SYNC_LINE_RE = re.compile(r"^\s*((?:\[" + _TIME + r"\]\s*)+)(.*)$")
_STAMP_PARTS_RE = re.compile(r"\[(\d{1,3}):(\d{2})(?:[.:,](\d{1,3}))?\]")


def strip_markup(text: str) -> str:
    """Remove `[mm:ss.xx]` stamps, `<mm:ss.xx>` word tags and `[ar:…]` tags."""
    text = _META_TAG_RE.sub("", text or "")
    text = _STAMP_RE.sub("", text)
    return _WORD_TAG_RE.sub("", text)


def lyric_text(record: dict) -> str:
    """The record's words, one line per lyric line, with all timing removed.

    plainLyrics wins when present (no markup to strip); otherwise the synced
    text; otherwise the lyricsfile's line texts.
    """
    plain = (record.get("plainLyrics") or "").strip()
    if plain:
        return strip_markup(plain)
    synced = record.get("syncedLyrics") or ""
    if synced.strip():
        return "\n".join(line for line in (l.strip() for l in strip_markup(synced).split("\n")) if line)
    lines = parse_lyricsfile(record.get("lyricsfile") or "")
    return "\n".join(l["text"] for l in lines if l["text"].strip())


def _stamp_seconds(match) -> float:
    minutes, seconds, fraction = match.group(1), match.group(2), match.group(3) or ""
    value = int(minutes) * 60 + int(seconds)
    if fraction:
        value += int(fraction) / (10 ** len(fraction))
    return float(value)


def sung_stamps(record: dict) -> List[float]:
    """Start stamps (seconds) of the synced lines that carry words.

    A line of only "♪" or nothing is an instrumental break, not singing: a
    trailing "[03:58.00]" marker must not make a track look longer.
    """
    stamps: List[float] = []
    for raw in (record.get("syncedLyrics") or "").split("\n"):
        match = _SYNC_LINE_RE.match(raw)
        if not match:
            continue
        words = _WORD_TAG_RE.sub("", match.group(2))
        if not any(ch.isalnum() for ch in words):
            continue
        stamps.extend(_stamp_seconds(m) for m in _STAMP_PARTS_RE.finditer(match.group(1)))
    return stamps


def synced_lines(record: dict, include_empty: bool = False) -> List[tuple]:
    """`[(stamp_seconds, text)]` of a record's synced lines, in time order.

    A line with several stamps ("[00:10.00][00:50.00]chorus") yields one entry
    per stamp. `text` has word tags removed. Empty and music-only lines are
    dropped unless `include_empty` (the gap stamps that end a sung line).
    """
    out: List[tuple] = []
    for raw in (record.get("syncedLyrics") or "").split("\n"):
        match = _SYNC_LINE_RE.match(raw)
        if not match:
            continue
        text = _WORD_TAG_RE.sub("", match.group(2)).strip()
        if not include_empty and not any(ch.isalnum() for ch in text):
            continue
        out.extend((_stamp_seconds(m), text) for m in _STAMP_PARTS_RE.finditer(match.group(1)))
    out.sort(key=lambda item: item[0])
    return out


def last_stamp(record: dict) -> Optional[float]:
    stamps = sung_stamps(record)
    return max(stamps) if stamps else None


# --------------------------------------------------------------------------
# lyricsfile (LRCLIB's YAML) — minimal reader
# --------------------------------------------------------------------------

def _yaml_scalar(value: str) -> str:
    if value in ("~", "null"):
        return ""
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    if len(value) >= 2 and value[0] == "'" and value[-1] == "'":
        return value[1:-1].replace("''", "'")
    if value.startswith("|") or value.startswith(">"):
        return "<block>"
    return value


def _to_int(value: str) -> Optional[int]:
    try:
        return int(value)
    except ValueError:
        return None


def parse_lyricsfile(raw: str) -> List[dict]:
    """Lines of a `lyricsfile`: `{text, start_ms, end_ms, words:[{text,start_ms,end_ms}]}`.

    Only the shape LRCLIB writes is read (a `lines:` list of mappings with an
    optional nested `words:` list), mirroring the Swift reader the 2026-10-11
    lab used, because no YAML library is available and a general parser is not
    needed. Indentation tells word items from line items; a field it cannot
    read is left absent rather than guessed.
    """
    lines: List[dict] = []
    in_lines = False
    line_indent: Optional[int] = None
    word_indent: Optional[int] = None
    current: Optional[dict] = None
    word: Optional[dict] = None

    def close_word():
        nonlocal word, word_indent
        if word is not None and current is not None:
            current["words"].append(word)
        word, word_indent = None, None

    def close_line():
        nonlocal current
        close_word()
        if current is not None:
            lines.append(current)
        current = None

    for raw_line in (raw or "").split("\n"):
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        content = raw_line.strip()
        if not content:
            continue
        if not in_lines:
            if indent == 0 and content == "lines:":
                in_lines = True
            continue
        if indent == 0 and not content.startswith("-"):
            close_line()
            break
        body = content
        is_item = False
        if content.startswith("- ") or content == "-":
            is_item = True
            body = content[1:].lstrip(" ") if content != "-" else ""
            if line_indent is None:
                line_indent = indent
            if indent == line_indent:
                close_line()
                current = {"text": "", "start_ms": None, "end_ms": None, "words": []}
            else:
                close_word()
                word = {"text": "", "start_ms": None, "end_ms": None}
                word_indent = indent
        if ":" not in body:
            continue
        key, _, value = body.partition(":")
        value = value.strip()
        belongs_to_word = word is not None and (
            indent == word_indent if is_item else indent > (word_indent if word_indent is not None else 1 << 30))
        if not belongs_to_word and word is not None and not is_item:
            close_word()
        target = word if belongs_to_word else current
        if target is None:
            continue
        if key == "start_ms":
            target["start_ms"] = _to_int(value)
        elif key == "end_ms":
            target["end_ms"] = _to_int(value)
        elif key == "text":
            target["text"] = _yaml_scalar(value)
        elif key == "words":
            close_word()
    close_line()
    return lines


_ENHANCED_RE = re.compile(r"<" + _TIME + r">")


def word_timing_kind(record: dict) -> Optional[str]:
    """How a record carries word-level timing.

    "enhanced-lrc": `<mm:ss.xx>` tags inside syncedLyrics.
    "lyricsfile-words": at least one lyricsfile line with a timed word entry.
    "both": the two together. None: line timing only.
    Detection is by content, not by the `hasWordSync` flag, which is LRCLIB's
    claim; M3 asks whether a parser can actually use the data.
    """
    enhanced = bool(_ENHANCED_RE.search(record.get("syncedLyrics") or ""))
    words = False
    raw = record.get("lyricsfile") or ""
    if "words:" in raw:
        for line in parse_lyricsfile(raw):
            if any(w["start_ms"] is not None for w in line["words"]):
                words = True
                break
    if enhanced and words:
        return "both"
    if enhanced:
        return "enhanced-lrc"
    if words:
        return "lyricsfile-words"
    return None


# --------------------------------------------------------------------------
# Fingerprint
# --------------------------------------------------------------------------

# The shingle each script family is fingerprinted with: ("char", n) is a
# character n-gram over the text with its spaces removed, ("word", n) a run of
# n words. A family not listed here is space-separated and gets DEFAULT_SHINGLE,
# which includes Hangul.
#
# Why not bigrams everywhere that has no spaces: two unrelated Thai texts share
# so many bigrams that their median containment reached 0.61, above SAME, so
# other songs joined the cluster; and unrelated Japanese or Chinese texts landed
# in `uncertain`. The sizes below are the smallest n whose containment between
# unrelated texts of about 1,000 characters stays under 0.2 at the 99th
# percentile on `standin_probe.py`'s stand-in text (macOS UI strings, never
# lyrics), on both of its pools. Thai needs 7 and Han/kana 5; the numbers are in
# SPEC.md, "Amended 2026-10-15 (after the adversarial review)". Larger n makes a
# same-song pair with spelling variants score lower, so `calibrate.py` re-picks
# n per family from the real corpus, and `reports/oracle-calibration.json`
# replaces these entries when it exists and `load_calibration` was called.
NGRAM_TABLE: Dict[str, tuple] = {
    "THAI": ("char", 7),
    "CJK": ("char", 5),      # Han, hiragana, katakana and Japanese mixes (script_family folds them)
    # Spaceless abugidas, not probed: sized like Thai, whose behaviour they share.
    "LAO": ("char", 7), "KHMER": ("char", 7), "MYANMAR": ("char", 7), "TIBETAN": ("char", 7),
}
DEFAULT_SHINGLE = ("word", 3)

# (SAME, WRONG) containment per family: at or above SAME the same song, at or
# below WRONG a different one, between them uncertain. `calibrate.py` may move
# a family's pair; every other family keeps the default.
DEFAULT_THRESHOLDS = (0.6, 0.2)
THRESHOLD_TABLE: Dict[str, tuple] = {}

CALIBRATION_FILE = os.path.join("reports", "oracle-calibration.json")
# Precedence, highest first: an explicit `ngram=` argument, the family's entry
# in the loaded calibration file, then NGRAM_TABLE / THRESHOLD_TABLE.
_calibration: Dict[str, dict] = {}
_calibration_source: Optional[str] = None


def shingle_for(family: str) -> tuple:
    """("char"|"word", n) used for script family `family`."""
    override = _calibration.get(family, {}).get("ngram")
    if override:
        kind = NGRAM_TABLE.get(family, DEFAULT_SHINGLE)[0]
        return (kind, int(override))
    return NGRAM_TABLE.get(family, DEFAULT_SHINGLE)


def thresholds(family: str) -> tuple:
    """(SAME, WRONG) for script family `family`; the default pair when unlisted."""
    entry = _calibration.get(family, {})
    if "same" in entry and "wrong" in entry:
        return (float(entry["same"]), float(entry["wrong"]))
    return THRESHOLD_TABLE.get(family, DEFAULT_THRESHOLDS)


def reset_calibration() -> None:
    global _calibration_source
    _calibration.clear()
    _calibration_source = None


def load_calibration(root: str) -> bool:
    """Read `<root>/reports/oracle-calibration.json` into the overrides.

    The file is `calibrate.py`'s output; only each family's `recommended`
    object is read (`ngram`, `same`, `wrong`). A missing or malformed file, or
    a malformed entry, leaves the table in force. Returns whether any family
    was loaded. Callers must call this before fingerprinting and must call it
    for the resolver and the classifier alike, or their fingerprints disagree.
    """
    reset_calibration()
    path = os.path.join(os.path.expanduser(root), CALIBRATION_FILE)
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        families = data["families"]
    except (OSError, ValueError, KeyError, TypeError):
        return False
    if not isinstance(families, dict):
        return False
    global _calibration_source
    for family, entry in families.items():
        rec = entry.get("recommended") if isinstance(entry, dict) else None
        if not isinstance(rec, dict):
            continue
        clean: dict = {}
        n = rec.get("ngram")
        if isinstance(n, int) and not isinstance(n, bool) and 2 <= n <= 8:
            clean["ngram"] = n
        same, wrong = rec.get("same"), rec.get("wrong")
        if all(isinstance(x, (int, float)) and not isinstance(x, bool) for x in (same, wrong)) \
                and 0 < wrong < same <= 1:
            clean["same"], clean["wrong"] = float(same), float(wrong)
        if clean:
            _calibration[str(family)] = clean
    if _calibration:
        _calibration_source = path
    return bool(_calibration)


def active_params() -> dict:
    """What a fingerprint made now depends on, to record beside the truth."""
    families = sorted(set(NGRAM_TABLE) | set(THRESHOLD_TABLE) | set(_calibration))
    return {"source": "calibration" if _calibration else "table",
            "families": {f: {"shingle": list(shingle_for(f)), "thresholds": list(thresholds(f))}
                         for f in families}}


def fingerprint(text: str, ngram: Optional[int] = None, family: Optional[str] = None) -> FrozenSet[str]:
    """Shingle set of a lyric text.

    The shingle comes from the text's script family (`shingle_for`), or from
    `family` when the caller names one: two records are only comparable when
    both were shingled the same way, so a same-song group fingerprints every
    member with the group's family, whatever the member's own dominant script
    (adversarial review, second pass, finding 1). Character
    n-grams over the text with spaces removed for the spaceless scripts, word
    n-grams for the rest (3 by default). A text shorter than n is one shingle,
    its whole self. `ngram` overrides n for this call (calibrate.py probes
    with it). A shingle set is order-insensitive, so a chorus repeated three
    times or a reordered verse costs nothing.
    """
    normalized = normalize_text(text)
    if not normalized:
        return frozenset()
    if family is None:
        family = script_family(dominant_script(normalized))
    kind, n = shingle_for(family)
    if ngram is not None:
        n = ngram
    if kind == "char":
        chars = normalized.replace(" ", "")
        if len(chars) < n:
            return frozenset([chars])
        return frozenset(chars[i:i + n] for i in range(len(chars) - n + 1))
    words = normalized.split()
    if len(words) >= n:
        return frozenset(" ".join(words[i:i + n]) for i in range(len(words) - n + 1))
    return frozenset([" ".join(words)])


# Below this many shingles a "match" is an accident (a three-word chorus
# contained in anything), so only identical tiny sets count.
MIN_SHINGLES = 3


def containment(a: Optional[FrozenSet[str]], b: Optional[FrozenSet[str]]) -> float:
    """|A ∩ B| / min(|A|, |B|): how much of the shorter text the longer holds.
    min, not union, so a record missing its last verse still matches its full
    version, and a short fragment is what the lab then judges by `synced_fit`."""
    if not a or not b:
        return 0.0
    smaller = min(len(a), len(b))
    if smaller < MIN_SHINGLES:
        return 1.0 if a == b else 0.0
    return len(a & b) / smaller


# --------------------------------------------------------------------------
# Per-record analysis and clustering
# --------------------------------------------------------------------------

def analyze_record(record: dict) -> dict:
    """Everything the oracle derives from one LRCLIB row.

    `text` is the lyric itself, kept so a group can fingerprint the record
    again in its own family (see `cluster`). It lives in memory only: no caller
    writes an analysis to disk, and reports carry numbers.
    """
    text = lyric_text(record)
    stamps = sung_stamps(record)
    return {
        "text": text,
        "fp": fingerprint(text),
        "script": dominant_script(text),
        "script_weights": script_weights(text, by_family=True),
        "instrumental": bool(record.get("instrumental")),
        "has_synced": bool(stamps),
        "has_plain": bool((record.get("plainLyrics") or "").strip()),
        "last_stamp": max(stamps) if stamps else None,
        "word_timing": word_timing_kind(record),
    }


def _greedy_group(seed: str, members: List[str], fps: Dict[str, FrozenSet[str]], threshold: float) -> List[str]:
    """`seed` plus every member mutually similar to everyone already kept."""
    group = [seed]
    for other in sorted((m for m in members if m != seed), key=lambda m: (-len(fps[m]), str(m))):
        if all(containment(fps[other], fps[kept]) >= threshold for kept in group):
            group.append(other)
    return group


# A candidate whose weighted letters hold at least this share in the song's
# expected script is written in it, even when another script has more letters.
EXPECTED_SCRIPT_SHARE = 0.2


def cluster(candidates: List[dict], anchors: List, prefer_script: Optional[str] = None,
            threshold: Optional[float] = None) -> dict:
    """Same-song cluster of LRCLIB candidates.

    `candidates`: dicts with `id`, `fp` (frozenset, may be empty), `script`
    (dominant_script of the lyrics), `instrumental` and, when known,
    `script_weights` (family -> weighted letters, see `analyze_record`).
    `anchors`: ids whose title and artist matched (the caller's identity
    test). `threshold` is the SAME containment; None takes the winning script
    family's entry in the threshold table. A candidate may also carry `text`
    (the lyric): every record compared inside the winning group is then
    fingerprinted with that group's family, so an anchor moved into the
    expected script by `EXPECTED_SCRIPT_SHARE` is not compared in its own
    dominant family's shingle (a Latin-dominant anchor with a Japanese verse
    shared no word 3-shingle with a Japanese anchor's character 5-grams and
    the pair read as `anchor-conflict`). Without `text` the given `fp` stands.

    Returns:
      truth_status   "ok" or "no-anchor" (the caller upgrades to "instrumental")
      cluster_ids    anchors in the winning group, instrumental anchors, and
                     every other candidate with containment >= threshold
                     against a group anchor
      alt_script_ids anchors whose lyrics are in a different script from the
                     winning group (same title and artist, other script)
      anchor_ids     the winning anchor group
      containment    id -> best containment against the group anchors (None
                     when there is nothing to compare)
      notes          "anchor-conflict" when anchors disagreed with each other
      group_family   the script family the winning group is written in (""
                     when only instrumental anchors exist); the classifier
                     reads its thresholds and its alt-script test from it

    Anchors in different scripts are not a conflict; they are split first. The
    expected script (`prefer_script`) wins whenever any anchor holds at least
    EXPECTED_SCRIPT_SHARE of its weighted letters in it (a Korean lyric that
    is half English counts as Korean); with none, the majority script wins. Anchors in the same
    script that contradict each other (containment < threshold) are: the
    largest mutually similar group is kept and the rest are left out.
    """
    by_id = {c["id"]: c for c in candidates}
    fps = {c["id"]: c.get("fp") or frozenset() for c in candidates}
    notes: List[str] = []
    valid = [a for a in anchors if a in by_id and (fps[a] or by_id[a].get("instrumental"))]
    result = {"truth_status": "no-anchor", "cluster_ids": [], "alt_script_ids": [],
              "anchor_ids": [], "containment": {}, "notes": notes, "group_family": ""}
    if not valid:
        return result

    texted = [a for a in valid if fps[a]]
    instrumental_only = [a for a in valid if not fps[a]]
    alt_script: List = []
    group: List = []
    primary = ""
    if texted:
        families: Dict[str, List] = {}
        wanted = script_family(prefer_script or "")
        for a in texted:
            family = script_family(by_id[a].get("script") or "")
            weights = by_id[a].get("script_weights")
            if wanted and weights and family_share(weights, wanted) >= EXPECTED_SCRIPT_SHARE:
                family = wanted
            families.setdefault(family, []).append(a)
        # The song's own script wins whenever any anchor is written in it, even
        # when romanised uploads outnumber it: a J-pop song with 30 romaji
        # copies and 28 in Japanese is still a Japanese song, and showing the
        # romaji is the alt-script outcome, not the correct one. Only with no
        # anchor in the expected script does the majority decide.
        if wanted in families:
            primary = wanted
        else:
            primary = sorted(families, key=lambda f: (-len(families[f]), f))[0]
        pool = families[primary]
        alt_script = [a for a in texted if a not in pool]
        if threshold is None:
            threshold = thresholds(primary)[0]
        # From here on every record compared with the group is shingled the
        # group's way. Alt-script anchors keep their own and are not compared.
        for cid in list(fps):
            text = by_id[cid].get("text")
            own = script_family(by_id[cid].get("script") or "")
            if text and fps[cid] and cid not in alt_script and shingle_for(own) != shingle_for(primary):
                fps[cid] = fingerprint(text, family=primary)
        agree = all(containment(fps[x], fps[y]) >= threshold for x in pool for y in pool)
        if agree:
            group = list(pool)
        else:
            notes.append("anchor-conflict")
            groups = [_greedy_group(seed, pool, fps, threshold) for seed in pool]
            # Biggest group, then the one with more text behind it, then the
            # lowest id: the same input always picks the same song.
            group = sorted(groups, key=lambda g: (-len(g), -sum(len(fps[m]) for m in g),
                                                  min(str(m) for m in g)))[0]
    if threshold is None:
        threshold = DEFAULT_THRESHOLDS[0]
    members = list(group) + [a for a in instrumental_only]
    anchor_set = set(valid)
    for c in candidates:
        cid = c["id"]
        if cid in members or cid in anchor_set or not fps[cid]:
            continue
        if any(containment(fps[cid], fps[g]) >= threshold for g in group):
            members.append(cid)
    scores = {}
    for c in candidates:
        cid = c["id"]
        others = [g for g in group if g != cid]
        scores[cid] = (round(max(containment(fps[cid], fps[g]) for g in others), 3)
                       if fps[cid] and others else None)
    result.update({
        "truth_status": "ok",
        "cluster_ids": members,
        "alt_script_ids": alt_script,
        "anchor_ids": list(group) + list(instrumental_only),
        "containment": scores,
        "group_family": primary,
    })
    return result
