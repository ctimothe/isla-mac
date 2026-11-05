#!/bin/bash
# Lists, and with --apply moves aside, the empty preference files the unit
# tests' throwaway defaults suites left in ~/Library/Preferences.
#
#   bash Scripts/clean-test-plists.sh           # dry run: count and a sample
#   bash Scripts/clean-test-plists.sh --apply   # move them into a dated folder
#
# Every `UserDefaults(suiteName:)` a test makes writes a file named after the
# suite, and `removePersistentDomain(forName:)` empties it without deleting it.
# By 2026-11-05 the owner's Mac held about 96,900 of them, and each gate run
# added about 580 more. Nothing reads them; they only slow the folder down.
#
# A file is taken only when both hold: its name is one of the test suites'
# own patterns below, and it holds no keys at all. The app's own domain
# (com.ctimothe.isla.plist) never matches. --apply never deletes: it moves the
# files into ~/Library/Isla Test Plists/<date>/ and prints the command that
# puts them back.
set -euo pipefail

APPLY=0
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        -h|--help) sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument '$arg' (try --apply)" >&2; exit 2 ;;
    esac
done

PREFS="$HOME/Library/Preferences"
DEST="$HOME/Library/Isla Test Plists/$(date '+%Y-%m-%d-%H%M%S')"

/usr/bin/python3 -I - "$PREFS" "$APPLY" "$DEST" <<'PY'
import os, plistlib, re, shutil, sys

prefs, apply, dest = sys.argv[1], sys.argv[2] == "1", sys.argv[3]

# The tests' suite names. Each pattern needs a segment after the prefix, so
# the app's own com.ctimothe.isla.plist can never match.
patterns = [
    r"com\.ctimothe\.isla\.[A-Za-z0-9_-]+\..+",                     # com.ctimothe.isla.<area>.<uuid or test>
    r"[A-Za-z]+Tests\.[0-9A-Fa-f-]{36}",                           # ShelfStoreTests.<uuid>
    r"[A-Za-z]+Tests[0-9A-Fa-f-]{36}",                             # HotKeyTests<uuid>
    r"TranslateRig\.[0-9A-Fa-f-]{36}",
    r"isla-tests-[A-Za-z0-9-]+",
    r"isla-capture-folders[A-Za-z0-9.-]*",
    r"isla\.test\.[A-Za-z0-9.-]+",
]
matcher = re.compile(r"^(?:" + "|".join(patterns) + r")\.plist$")

def empty(path):
    try:
        with open(path, "rb") as handle:
            value = plistlib.load(handle)
    except Exception:
        return False
    return isinstance(value, dict) and not value

taken = []
for name in sorted(os.listdir(prefs)):
    if name == "com.ctimothe.isla.plist" or not matcher.match(name):
        continue
    path = os.path.join(prefs, name)
    if os.path.isfile(path) and not os.path.islink(path) and empty(path):
        taken.append(name)

print(f"{len(taken)} empty test-suite plists in {prefs}")
for name in taken[:10]:
    print(f"  {name}")
if len(taken) > 10:
    print(f"  … and {len(taken) - 10} more")

if not apply:
    print("dry run: nothing moved (run again with --apply to move them aside)")
    sys.exit(0)
if not taken:
    sys.exit(0)

os.makedirs(dest, exist_ok=True)
for name in taken:
    shutil.move(os.path.join(prefs, name), os.path.join(dest, name))
print(f"moved {len(taken)} files to {dest}")
print("to put them back:")
print(f"  find '{dest}' -name '*.plist' -print0 | xargs -0 -J % mv % '{prefs}/'")
PY
