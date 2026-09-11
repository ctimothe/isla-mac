#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for locale in en ru; do
    test -s "$ROOT/Resources/$locale.lproj/Localizable.strings"
    plutil -lint "$ROOT/Resources/$locale.lproj/Localizable.strings"
done

python3 - "$ROOT" <<'PY'
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


en_keys, en_values = entries("en")
ru_keys, ru_values = entries("ru")

# 1. Duplicates within one table. plutil -lint passes these and keeps one
# entry silently, so the table and the code can disagree about which.
for locale, keys in (("en", en_keys), ("ru", ru_keys)):
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
# The welcome keeps its strings in Copy.english and localises them through a
# variable, so the literals never appear inside localized(...) either.
welcome = root / "Sources" / "IslaKit" / "UI" / "WelcomePane.swift"
match = re.search(r"static let english = Copy\((.*?)\)", welcome.read_text(), re.S)
if match is None:
    fail("WelcomePane.swift: Copy.english block not found, cannot scrape welcome keys")
else:
    used |= set(re.findall(r'"((?:[^"\\]|\\.)*)"', match.group(1)))

table = set(en_keys)
for key in sorted(used - table):
    fail(f"used in Sources but absent from the tables: {key!r}")
for key in sorted(table - used):
    fail(f"in the tables but unused in Sources: {key!r}")

# The two tables must still carry exactly the same keys.
if set(en_keys) != set(ru_keys):
    fail(f"en/ru key drift: {sorted(set(en_keys) ^ set(ru_keys))}")

# 3. Format specifiers must match between the locales, in order and in count:
# a reordered or dropped %@ crashes or mislabels at format time.
specifier = re.compile(r"%(?:\d+\$)?[#0\- +I]*(?:\d+)?(?:\.\d+)?[hljztL]*[@a-zA-Z]")
for key in sorted(set(en_values) & set(ru_values)):
    en_specs = specifier.findall(en_values[key])
    ru_specs = specifier.findall(ru_values[key])
    if en_specs != ru_specs:
        fail(f"specifier drift for {key!r}: en {en_specs} vs ru {ru_specs}")

if failures:
    print("localizations gate failed:")
    for failure in failures:
        print(f"  ✗ {failure}")
    sys.exit(1)

print(f"  ✓ en/ru localization keys match ({len(table)} keys, no duplicates, no drift, specifiers agree)")
PY
