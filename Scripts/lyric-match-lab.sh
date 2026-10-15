#!/bin/bash
# The Lyrics Match Lab, Swift side: does Isla find the right lyrics for the
# song that is playing? Specified in docs/audits/2026-10-15-lyrics-match-lab/SPEC.md.
#
#   bash Scripts/lyric-match-lab.sh <root>              # replay only: no network
#   bash Scripts/lyric-match-lab.sh <root> --record     # fetch cache misses from LRCLIB
#   bash Scripts/lyric-match-lab.sh <root> --diagnose-only   # just the diagnosis case
#   ISLA_MATCH_LAB=<root> bash Scripts/lyric-match-lab.sh
#
# <root> is the corpus root (~/code/_tools/isla-lyrics-lab/): resolved/variants.jsonl,
# wordtimed/<slice>/<id>.json and the cache/isla/ replay cache. It is outside git
# because it holds lyric text. The run writes under <root>/results/ and, with
# --record, <root>/cache/isla/. It never writes anywhere else, and what it
# writes holds numbers, LRCLIB ids, titles and artist names, never a lyric line.
#
# Two `swift test` runs, because the second reads what the first wrote:
#   1. LyricMatchLabLookupTests      -> results/isla-lookups.jsonl        (M1/M6)
#   2. LyricMatchLabPerturbationTests -> results/perturbations.jsonl      (M2)
#      LyricMatchLabWordTests         -> results/word-fidelity.json       (M3 fidelity)
#      LyricMatchLabReadabilityTests  -> results/readability.json         (M4)
#   3. LyricMatchLabDiagnosisTests    -> results/diagnosis.jsonl           (why a record
#      was accepted or refused; reads reports/diagnose-input.jsonl, which the Python
#      classifier writes AFTER the first two, so a plain run runs this only if the
#      file is already there. No network at all: cache reads only, even with --record.)
#
# The cases live in Tests/IslaKitTests/LyricMatchLab*.swift and skip themselves
# unless ISLA_MATCH_LAB is set, so ./scripts/check never runs them.
#
# Politeness (SPEC): --record talks to lrclib.net, one request at a time, at
# least 1.0 s apart and searches at least 7.5 s apart, retrying a 5xx after 2,
# 8 and 30 s and a 429 after 30, 60 and 120 s; a 429 that outlives that is a
# miss (`uncached`), never an answer. Never run it while the Python resolver
# is talking to LRCLIB: one process per host.
# A network failure is never cached, so rerunning --record fills exactly the gaps.
#
# Knobs:
#   ISLA_MATCH_MAX_LIVE=N   stop making live requests after N (a development
#                           guard); a lookup that needed one is reported `uncached`
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LAB="${ISLA_MATCH_LAB:-}"
RECORD=0
DIAGNOSE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --record) RECORD=1 ;;
    --diagnose-only) DIAGNOSE_ONLY=1 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) LAB="$arg" ;;
  esac
done

if [ -z "$LAB" ] || [ ! -d "$LAB" ]; then
  echo "usage: bash Scripts/lyric-match-lab.sh <root> [--record | --diagnose-only]" >&2
  exit 2
fi
LAB="$(cd "$LAB" && pwd)"
if [ "$DIAGNOSE_ONLY" = 1 ] && [ "$RECORD" = 1 ]; then
  echo "--diagnose-only never records: the diagnosis reads the cache and nothing else" >&2
  exit 2
fi
if [ "$DIAGNOSE_ONLY" = 0 ] && [ ! -s "$LAB/resolved/variants.jsonl" ]; then
  echo "no $LAB/resolved/variants.jsonl: run the resolver first" >&2
  exit 2
fi
mkdir -p "$LAB/results"

# The diagnosis case, alone or as the third invocation. It makes no network
# call whatever the mode, so the record switch is cleared for it.
run_diagnosis() {
  ISLA_MATCH_RECORD= ISLA_MATCH_LAB="$LAB" \
    swift test --package-path "$ROOT" --disable-sandbox --filter LyricMatchLabDiagnosisTests >"$LOG3" 2>&1
  local status=$?
  grep -E "^LYRIC-MATCH|error:|Executed" "$LOG3" || true
  return $status
}

LOG3="$(mktemp "${TMPDIR:-/tmp}/lyric-match-lab-diagnosis.XXXXXX")"

if [ "$DIAGNOSE_ONLY" = 1 ]; then
  if [ ! -s "$LAB/reports/diagnose-input.jsonl" ]; then
    echo "no $LAB/reports/diagnose-input.jsonl: the classifier writes it" >&2
    exit 2
  fi
  echo "mode:   diagnose only (cache reads, no network)"
  echo "root:   $LAB"
  rm -f "$LAB/results/diagnosis.jsonl"
  run_diagnosis
  STATUS=$?
  [ -s "$LAB/results/diagnosis.jsonl" ] || { echo "  MISSING results/diagnosis.jsonl (see $LOG3)" >&2; STATUS=1; }
  exit $((STATUS != 0))
fi

if [ "$RECORD" = 1 ]; then
  export ISLA_MATCH_RECORD=1
  echo "mode:   record (cache misses are fetched live)"
else
  unset ISLA_MATCH_RECORD
  echo "mode:   replay (cache misses are reported as uncached)"
fi
echo "root:   $LAB"

LOG1="$(mktemp "${TMPDIR:-/tmp}/lyric-match-lab-lookups.XXXXXX")"
LOG2="$(mktemp "${TMPDIR:-/tmp}/lyric-match-lab-sections.XXXXXX")"
echo "logs:   $LOG1 $LOG2"

# A stale result from an earlier run would read as this run's if a case failed
# before writing; remove the four this script owns.
rm -f "$LAB/results/isla-lookups.jsonl" "$LAB/results/perturbations.jsonl" \
      "$LAB/results/word-fidelity.json" "$LAB/results/readability.json"

ISLA_MATCH_LAB="$LAB" \
  swift test --package-path "$ROOT" --disable-sandbox --filter LyricMatchLabLookupTests >"$LOG1" 2>&1
STATUS1=$?
grep -E "^MATCH-LAB|error:|Executed" "$LOG1" || true

STATUS2=0
if [ -s "$LAB/results/isla-lookups.jsonl" ]; then
  ISLA_MATCH_LAB="$LAB" \
    swift test --package-path "$ROOT" --disable-sandbox \
      --filter LyricMatchLabPerturbationTests \
      --filter LyricMatchLabWordTests \
      --filter LyricMatchLabReadabilityTests >"$LOG2" 2>&1
  STATUS2=$?
  grep -E "^MATCH-LAB|error:|Executed" "$LOG2" || true
else
  echo "!!! the lookups wrote no results; the other sections need them. See $LOG1" >&2
  STATUS2=1
fi

STATUS3=0
if [ -s "$LAB/reports/diagnose-input.jsonl" ]; then
  rm -f "$LAB/results/diagnosis.jsonl"
  run_diagnosis
  STATUS3=$?
else
  echo "(no reports/diagnose-input.jsonl yet: run the classifier, then --diagnose-only)"
fi

echo
echo "summary:"
{ grep -h "^MATCH-LAB" "$LOG1" "$LOG2" 2>/dev/null | grep -v "lookups [0-9]*/" || true; } | sed 's/^MATCH-LAB /  /'
for f in isla-lookups.jsonl perturbations.jsonl word-fidelity.json readability.json; do
  [ -s "$LAB/results/$f" ] || echo "  MISSING results/$f" >&2
done
{ grep -h "^LYRIC-MATCH" "$LOG3" 2>/dev/null || true; } | sed 's/^LYRIC-MATCH /  /'

if [ "$STATUS1" -ne 0 ] || [ "$STATUS2" -ne 0 ] || [ "$STATUS3" -ne 0 ]; then
  exit 1
fi
exit 0
