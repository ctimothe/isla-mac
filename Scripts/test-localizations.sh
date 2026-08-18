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

root = pathlib.Path(sys.argv[1])

def keys(locale: str) -> set[str]:
    text = (root / "Resources" / f"{locale}.lproj" / "Localizable.strings").read_text()
    return set(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', text, re.M))

english = keys("en")
russian = keys("ru")
assert english == russian, sorted(english ^ russian)
print(f"  ✓ en/ru localization keys match ({len(english)} keys)")
PY
