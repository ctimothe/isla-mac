#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The locales are whatever Resources/*.lproj holds, so a third language is
# held to the same rules the day its folder appears instead of passing unseen.
LOCALES=""
for lproj in "$ROOT"/Resources/*.lproj; do
    LOCALES="$LOCALES $(basename "$lproj" .lproj)"
done
export LOCALES

for locale in $LOCALES; do
    test -s "$ROOT/Resources/$locale.lproj/Localizable.strings"
    plutil -lint "$ROOT/Resources/$locale.lproj/Localizable.strings"
    test -s "$ROOT/Resources/$locale.lproj/InfoPlist.strings"
    plutil -lint "$ROOT/Resources/$locale.lproj/InfoPlist.strings"
done

# The permission prompts. Every usage description in the bundle's Info.plist
# needs a row in both InfoPlist.strings tables, the English row must say what
# Info.plist says, and neither table may carry a key Info.plist lacks. A
# prompt macOS cannot localise falls back to the plist's English, which is how
# the Apple Events prompt reached Russian users before 2026-09-23.
python3 - "$ROOT" <<'PROMPTS'
import os, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
locales = os.environ["LOCALES"].split()
plist = (root / "Scripts" / "bundle.sh").read_text()
usage = dict(re.findall(r"<key>(NS\w+UsageDescription)</key>\s*<string>([^<]*)</string>", plist))
failures = []
for locale in locales:
    text = (root / "Resources" / f"{locale}.lproj" / "InfoPlist.strings").read_text()
    table = dict(re.findall(r'^"(\w+)"\s*=\s*"((?:[^"\\]|\\.)*)";', text, re.M))
    if set(table) != set(usage):
        failures.append(f"{locale} InfoPlist.strings keys {sorted(table)} != Info.plist {sorted(usage)}")
    if locale == "en":
        for key, value in usage.items():
            if table.get(key) != value:
                failures.append(f"en InfoPlist.strings {key} differs from Info.plist")
    else:
        for key, value in table.items():
            if value == usage.get(key):
                failures.append(f"ru InfoPlist.strings leaves {key} in English")
if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
print(f"  ✓ {len(usage)} permission prompts localized in en and ru")
PROMPTS

# The Services menu. macOS reads an NSServices item's title from
# ServicesMenu.strings, keyed by the NSMenuItem default, and falls back to the
# plist's English when the table is missing, which is how "Translate in Isla"
# stayed English on a Russian Mac (G-031). Same rules as the prompts above: both
# tables exist, lint clean, carry exactly the plist's titles, the English value
# is the key, and the Russian one is not.
python3 - "$ROOT" <<'SERVICES'
import os, pathlib, re, subprocess, sys
root = pathlib.Path(sys.argv[1])
locales = os.environ["LOCALES"].split()
plist = (root / "Scripts" / "bundle.sh").read_text()
titles = set(re.findall(r"<key>NSMenuItem</key>\s*<dict><key>default</key><string>([^<]*)</string>", plist))
failures = []
if not titles:
    failures.append("bundle.sh: no NSMenuItem default found, the scrape is stale")
for locale in locales:
    path = root / "Resources" / f"{locale}.lproj" / "ServicesMenu.strings"
    if not path.is_file() or path.stat().st_size == 0:
        failures.append(f"{locale}.lproj/ServicesMenu.strings is missing")
        continue
    lint = subprocess.run(["plutil", "-lint", str(path)], capture_output=True, text=True)
    if lint.returncode != 0:
        failures.append(f"{locale} ServicesMenu.strings is not clean: {lint.stdout.strip()}{lint.stderr.strip()}")
    table = dict(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', path.read_text(), re.M))
    if set(table) != titles:
        failures.append(f"{locale} ServicesMenu.strings keys {sorted(table)} != NSMenuItem defaults {sorted(titles)}")
    for key, value in table.items():
        if locale == "en" and value != key:
            failures.append(f"en ServicesMenu.strings {key!r} is not its own value")
        if locale != "en" and value == key:
            failures.append(f"{locale} ServicesMenu.strings leaves {key!r} in English")
        if locale == "ru" and not re.search(r"[А-Яа-яЁё]", value):
            failures.append(f"ru ServicesMenu.strings {key!r} has no Russian in it")
if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
print(f"  ✓ {len(titles)} Services menu title localized in {', '.join(locales)}")
SERVICES

python3 - "$ROOT" <<'PY'
import os
import pathlib
import re
import sys
from collections import Counter

root = pathlib.Path(sys.argv[1])
failures: list[str] = []


def fail(message: str) -> None:
    failures.append(message)


def entries(locale: str) -> tuple[list[str], dict[str, str]]:
    text = (root / "Resources" / f"{locale}.lproj" / "Localizable.strings").read_text()
    # A list, not a set: a duplicated key must be reported, and a set would
    # silently collapse it the same way plutil does.
    keys = re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', text, re.M)
    values = dict(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', text, re.M))
    return keys, values


locales = os.environ["LOCALES"].split()
others = [locale for locale in locales if locale != "en"]
tables = {locale: entries(locale) for locale in locales}
en_keys, en_values = tables["en"]

# 1. Duplicates within one table. plutil -lint passes these and keeps one
# entry silently, so the table and the code can disagree about which.
for locale, (keys, _) in tables.items():
    dupes = sorted(key for key, count in Counter(keys).items() if count > 1)
    if dupes:
        fail(f"duplicate keys in {locale}.lproj: {dupes}")

# 2. Drift between the tables and the code, in either direction. Keys are the
# English text, so a reworded phrase is a new key: both tables and every call
# site move together, or this catches it.
sources = "".join(p.read_text() + "\n" for p in (root / "Sources").rglob("*.swift"))
used = set(re.findall(r'localized\(\s*"((?:[^"\\]|\\.)*)"', sources))
# SwiftUI localises string-literal Button titles by itself, without a
# localized() call at the site.
used |= set(re.findall(r'Button\(\s*"((?:[^"\\]|\\.)*)"', sources))
# So does every other SwiftUI initialiser that takes a title literal: Text,
# Label, Toggle and .help. Until K-007 only Button was scraped, so a Text("...")
# with no row in the tables passed this gate and showed in English to a Russian
# user. A literal with no letter outside an interpolation ("-", a space,
# "\(value)") is not copy and is not asked for.
for pattern in (
    r'\bText\(\s*"((?:[^"\\]|\\.)*)"',
    r'\bLabel\(\s*"((?:[^"\\]|\\.)*)"',
    r'\bToggle\(\s*"((?:[^"\\]|\\.)*)"',
    r'\.help\(\s*"((?:[^"\\]|\\.)*)"',
):
    for literal in re.findall(pattern, sources):
        if re.search(r"[^\W\d_]", re.sub(r"\\\(.*?\)", "", literal)):
            used.add(literal)
# The welcome keeps its strings in Copy.english and localises them through a
# variable, so the literals never appear inside localized(...) either.
welcome = root / "Sources" / "IslaKit" / "UI" / "WelcomePane.swift"
# To the closing parenthesis on a line of its own: the first ")" is inside
# "What's playing, with lyrics (%@)", and stopping there dropped every key after it.
match = re.search(r"static let english = Copy\((.*?)\n\s*\)", welcome.read_text(), re.S)
if match is None:
    fail("WelcomePane.swift: Copy.english block not found, cannot scrape welcome keys")
else:
    used |= set(re.findall(r'"((?:[^"\\]|\\.)*)"', match.group(1)))

# App Intents. Shortcuts, Spotlight and Siri read these titles through the
# app's Localizable table, but they are LocalizedStringResource literals, not
# localized() calls, so the scrape above never saw them. Until 2026-09-23
# every one of them showed in English to a Russian user.
intents = (root / "Sources" / "IslaKit" / "App" / "IslaIntents.swift").read_text()
intent_keys = set(re.findall(r'LocalizedStringResource = "((?:[^"\\]|\\.)*)"', intents))
intent_keys |= set(re.findall(r'IntentDescription\(\s*"((?:[^"\\]|\\.)*)"', intents))
intent_keys |= set(re.findall(r'(?:shortTitle|title): "((?:[^"\\]|\\.)*)"', intents))
intent_keys |= set(re.findall(r'case \.\w+: return "((?:[^"\\]|\\.)*)"', intents))
if not intent_keys:
    fail("IslaIntents.swift: no intent strings found, the scrape is stale")
used |= intent_keys

table = set(en_keys)
for key in sorted(used - table):
    fail(f"used in Sources but absent from the tables: {key!r}")
for key in sorted(table - used):
    fail(f"in the tables but unused in Sources: {key!r}")

# Every table must still carry exactly the same keys as English.
for locale in others:
    other_keys, _ = tables[locale]
    if set(en_keys) != set(other_keys):
        fail(f"en/{locale} key drift: {sorted(set(en_keys) ^ set(other_keys))}")

# 3. Format specifiers must match between the locales, in order and in count:
# a reordered or dropped %@ crashes or mislabels at format time.
specifier = re.compile(r"%(?:\d+\$)?[#0\- +I]*(?:\d+)?(?:\.\d+)?[hljztL]*[@a-zA-Z]")
for locale in others:
    _, other_values = tables[locale]
    for key in sorted(set(en_values) & set(other_values)):
        en_specs = specifier.findall(en_values[key])
        other_specs = specifier.findall(other_values[key])
        if en_specs != other_specs:
            fail(f"specifier drift for {key!r}: en {en_specs} vs {locale} {other_specs}")

# 4. A translation that is the English text, character for character, is a
# string nobody translated (K-007). Only names that are the same in every
# language are allowed to match.
same_in_every_language = {
    "AirDrop": "Apple's own product name, left in Latin script by Apple's Russian UI",
    "Spotify": "a brand name",
    "Isla %@": "the product name and a format value",
}
for locale in others:
    _, other_values = tables[locale]
    for key, value in sorted(other_values.items()):
        if value == key and key not in same_in_every_language:
            fail(f"{locale} leaves {key!r} in English; translate it or allowlist it with a reason")

if failures:
    print("localizations gate failed:")
    for failure in failures:
        print(f"  ✗ {failure}")
    sys.exit(1)

print(f"  ✓ en/ru localization keys match ({len(table)} keys, no duplicates, no drift, specifiers agree)")
PY
