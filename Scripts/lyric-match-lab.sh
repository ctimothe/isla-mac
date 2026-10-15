#!/bin/bash
# The Lyrics Match Lab, Swift side: does Isla find the right lyrics for the
# song that is playing? Specified in docs/audits/2026-10-15-lyrics-match-lab/SPEC.md.
#
#   bash Scripts/lyric-match-lab.sh <root>              # replay only: no network
#   bash Scripts/lyric-match-lab.sh <root> --record     # fetch cache misses from LRCLIB
#   bash Scripts/lyric-match-lab.sh <root> --diagnose-only   # just the diagnosis case
#   ISLA_MATCH_LAB=<root> bash Scripts/lyric-match-lab.sh
#   ISLA_MATCH_OUT=candidate bash Scripts/lyric-match-lab.sh <root>   # results in <root>/candidate/
#
# <root> is the corpus root (~/code/_tools/isla-lyrics-lab/): resolved/variants.jsonl,
# wordtimed/<slice>/<id>.json and the cache/isla/ replay cache. It is outside git
# because it holds lyric text. The run writes under <root>/results/ (or ISLA_MATCH_OUT) and, with
# --record, <root>/cache/isla/. It never writes anywhere else, and what it
# writes holds numbers, LRCLIB ids, titles and artist names, never a lyric line.
#
# Two `swift test` runs, because the second reads what the first wrote:
#   1. LyricMatchLabLookupTests      -> results/isla-lookups.jsonl        (M1/M6)
#   2. LyricMatchLabPerturbationTests -> results/perturbations.jsonl      (M2)
#      LyricMatchLabWordTests         -> results/word-fidelity.json       (M3 fidelity)
#      LyricMatchLabReadabilityTests  -> results/readability.json         (M4)
#      LyricMatchLabSweepTests        -> results/sweep-edge.json          (M3b: is the
#      highlight on a word when it is sung)
#   3. LyricMatchLabDiagnosisTests    -> results/diagnosis.jsonl           (why a record
#      was accepted or refused; reads reports/diagnose-input.jsonl, which the Python
#      classifier writes AFTER the first two). It runs ONLY with --diagnose-only: a
#      plain or --record run is about to rewrite the lookups, so any diagnose-input
#      already on disk describes the previous run's lookups and would be diagnosed
#      against the wrong answers. Run the classifier on the fresh results, then
#      --diagnose-only. No network at all: cache reads only.
#
# "results" above is ISLA_MATCH_OUT (default `results`), a plain directory name
# under <root>. Setting it scores a candidate change to Isla beside the baseline
# over the same cache: the lab reads and writes <root>/<ISLA_MATCH_OUT>/ and
# removes only that directory's four stale files. ISLA_MATCH_REPORTS (default
# `reports`) names where the diagnosis case reads diagnose-input.jsonl; give the
# classifier the same two names: classify.py --results <OUT> --reports <REPORTS>.
#
# The cases live in Tests/IslaKitTests/LyricMatchLab*.swift and skip themselves
# unless ISLA_MATCH_LAB is set, so ./scripts/check never runs them.
#
# Politeness (SPEC): --record talks to lrclib.net, one request at a time, at
# least 7.5 s apart (LRCLIB allows about ten a minute), retrying a 5xx after 2,
# 8 and 30 s and a 429 after 30, 60 and 120 s; a 429 that outlives that is a
# miss (`uncached`), never an answer. Never run it while the Python resolver
# is talking to LRCLIB: one process per host.
# A network failure is never cached, so rerunning --record fills exactly the gaps.
#
# Knobs:
#   ISLA_MATCH_MAX_LIVE=N   stop making live requests after N (a development
#                           guard); a lookup that needed one is reported `uncached`
#   ISLA_MATCH_LRCLIB_GAP=S keep S seconds between LRCLIB requests instead of
#                           7.5, to probe a limiter that has just refused this
#                           address; a value under 7.5 is ignored
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LAB="${ISLA_MATCH_LAB:-}"
OUT="${ISLA_MATCH_OUT:-results}"
REPORTS="${ISLA_MATCH_REPORTS:-reports}"
for name in "$OUT" "$REPORTS"; do
  case "$name" in
    ""|.|..|*/*|*\\*) echo "ISLA_MATCH_OUT/ISLA_MATCH_REPORTS must be a plain directory name, got: $name" >&2; exit 2 ;;
  esac
done
export ISLA_MATCH_OUT="$OUT" ISLA_MATCH_REPORTS="$REPORTS"
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
mkdir -p "$LAB/$OUT"

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
  if [ ! -s "$LAB/$REPORTS/diagnose-input.jsonl" ]; then
    echo "no $LAB/$REPORTS/diagnose-input.jsonl: the classifier writes it" >&2
    exit 2
  fi
  echo "mode:   diagnose only (cache reads, no network)"
  echo "root:   $LAB"
  rm -f "$LAB/$OUT/diagnosis.jsonl"
  run_diagnosis
  STATUS=$?
  [ -s "$LAB/$OUT/diagnosis.jsonl" ] || { echo "  MISSING $OUT/diagnosis.jsonl (see $LOG3)" >&2; STATUS=1; }
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
# before writing; remove the five this script owns, from the directory this run
# writes to (ISLA_MATCH_OUT), never from another one.
rm -f "$LAB/$OUT/isla-lookups.jsonl" "$LAB/$OUT/perturbations.jsonl" \
      "$LAB/$OUT/word-fidelity.json" "$LAB/$OUT/readability.json" "$LAB/$OUT/sweep-edge.json"

ISLA_MATCH_LAB="$LAB" \
  swift test --package-path "$ROOT" --disable-sandbox --filter LyricMatchLabLookupTests >"$LOG1" 2>&1
STATUS1=$?
grep -E "^MATCH-LAB|error:|Executed" "$LOG1" || true

STATUS2=0
if [ -s "$LAB/$OUT/isla-lookups.jsonl" ]; then
  ISLA_MATCH_LAB="$LAB" \
    swift test --package-path "$ROOT" --disable-sandbox \
      --filter LyricMatchLabPerturbationTests \
      --filter LyricMatchLabWordTests \
      --filter LyricMatchLabReadabilityTests \
      --filter LyricMatchLabSweepTests >"$LOG2" 2>&1
  STATUS2=$?
  grep -E "^MATCH-LAB|error:|Executed" "$LOG2" || true
else
  echo "!!! the lookups wrote no results; the other sections need them. See $LOG1" >&2
  STATUS2=1
fi

# The diagnosis case is not run here: a diagnose-input.jsonl already on disk
# was written for the lookups this run just replaced.
STATUS3=0
echo "(diagnosis not run: classify.py --root \"$LAB\" --results $OUT --reports $REPORTS on these results, then --diagnose-only)"

echo
echo "summary:"
{ grep -h "^MATCH-LAB" "$LOG1" "$LOG2" 2>/dev/null | grep -v "lookups [0-9]*/" || true; } | sed 's/^MATCH-LAB /  /'
for f in isla-lookups.jsonl perturbations.jsonl word-fidelity.json readability.json sweep-edge.json; do
  [ -s "$LAB/$OUT/$f" ] || echo "  MISSING $OUT/$f" >&2
done
{ grep -h "^LYRIC-MATCH" "$LOG3" 2>/dev/null || true; } | sed 's/^LYRIC-MATCH /  /'

if [ "$STATUS1" -ne 0 ] || [ "$STATUS2" -ne 0 ] || [ "$STATUS3" -ne 0 ]; then
  exit 1
fi
exit 0
