#!/bin/bash
# The Lyrics Accuracy Lab: how exact Isla's lyric clock is, measured across a
# corpus of real LRCLIB answers.
#
#   bash Scripts/lyric-lab.sh <corpus-dir> [report.json]
#   ISLA_LYRIC_CORPUS=<dir> ISLA_LYRIC_REPORT=<file> bash Scripts/lyric-lab.sh
#
# The corpus is a directory of <category>/<lrclib_id>.json, each one LRCLIB's
# full object (syncedLyrics, lyricsfile, hasWordSync, duration, ...).
# Directories starting with "_" are ignored. The run reads the corpus and never
# writes to it; the report holds numbers and LRCLIB ids, never lyric text.
#
# The cases live in Tests/IslaKitTests/LyricAccuracyLab*.swift and skip
# themselves unless ISLA_LYRIC_CORPUS is set, so ./scripts/check never runs
# them. Each case's doc comment states its method; the report JSON states,
# per section, what was measured, what was assumed, and a verdict.
#
# Knobs:
#   ISLA_LYRIC_STRICT=1   turn every finding into a test failure (default:
#                         record findings in the report, fail only on a
#                         harness error)
#   ISLA_LYRIC_TIMERS=N   real timers per condition in L4 (default 300)
#
# L4 runs a CPU burner on every core for about a minute: expect the fans.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CORPUS="${ISLA_LYRIC_CORPUS:-${1:-}}"
REPORT="${ISLA_LYRIC_REPORT:-${2:-/private/tmp/claude-501/-Users-ctimothe-code-projects-production-dynamic-island/48ae4d81-9edf-4a35-a3fd-12960e5f9d5e/scratchpad/lyric-lab-report.json}}"

if [ -z "$CORPUS" ] || [ ! -d "$CORPUS" ]; then
  echo "usage: bash Scripts/lyric-lab.sh <corpus-dir> [report.json]" >&2
  exit 2
fi
CORPUS="$(cd "$CORPUS" && pwd)"
mkdir -p "$(dirname "$REPORT")"
# A fresh report per run: each case merges its own section, and a section left
# over from an earlier run would read as this run's.
rm -f "$REPORT"

LOG="$(mktemp "${TMPDIR:-/tmp}/lyric-lab.XXXXXX")"
echo "corpus: $CORPUS"
echo "report: $REPORT"
echo "log:    $LOG"

ISLA_LYRIC_CORPUS="$CORPUS" ISLA_LYRIC_REPORT="$REPORT" \
  swift test --package-path "$ROOT" --disable-sandbox --filter LyricAccuracyLab >"$LOG" 2>&1
STATUS=$?
grep -E "^LYRIC-LAB|error:|Executed" "$LOG" || true

if [ ! -s "$REPORT" ]; then
  echo "!!! no report was written; see $LOG" >&2
  exit 1
fi
python3 - "$REPORT" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
meta = report.get("meta", {})
print(f"\n{meta.get('tracks', '?')} tracks, harness {meta.get('harnessVersion', '?')}")
for key in sorted(k for k in report if k != "meta"):
    section = report[key]
    print(f"  {key:32} {section.get('verdict', '-'):12} {section.get('summary', '')}")
PY
exit $STATUS
