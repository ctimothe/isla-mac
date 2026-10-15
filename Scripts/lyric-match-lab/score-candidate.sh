#!/bin/bash
# Score one candidate change to Isla's lyric lookup beside the baseline, over
# the same recorded LRCLIB traffic. Specified in
# docs/audits/2026-10-15-lyrics-match-lab/SPEC.md (amendment "Counterfactual
# scoring").
#
#   bash Scripts/lyric-match-lab/score-candidate.sh <root> <worktree> <name> [patch]
#
# <worktree> is a scratch checkout of this branch that is not the one the
# baseline runs in: the patch is applied there, scored, and reverted, so the
# checkout a --record run builds from is never touched. With no patch the
# worktree is scored as it is (the baseline's replay, a control).
#
# The run is replay only: no network. A candidate that asks LRCLIB something
# no earlier run asked gets `uncached` for that lookup, and compare.py lists it
# under `needs_recording`. Results go to <root>/cf-<name>/ and the reports to
# <root>/cf-<name>-reports/, beside the baseline's results/ and reports/,
# which are only read.
#
# The baseline a candidate is compared with is the control: a replay of the
# unpatched code over the very same cache, scored first with
#
#   bash Scripts/lyric-match-lab/score-candidate.sh <root> <worktree> control
#
# which writes <root>/cf-control/ and <root>/cf-control-reports/ and is itself
# compared with the record run (<root>/reports and <root>/results). A candidate
# (a patch given) uses cf-control as its base when cf-control and
# cf-control-reports exist, or the run BASE_RESULTS names, and is refused when
# there is neither: the record run is not a base for a candidate, because the
# record and its replay can differ and that difference would show up as the
# candidate's effect (third review, m11). A candidate reads BASE_RESULTS only;
# BASE_REPORTS alone is refused, since the base is classified again from its
# results (fourth review, N3). A candidate named control, or named so that
# cf-<name> is its base, is refused: it would overwrite the base (N4). The
# worktree must be clean before the patch goes on, as it must be after (N5).
#
# Both sides are judged against one pool (third review, M1): the candidate is
# classified with the base's results as `--pool-results`, and the base is
# classified again, into <root>/cf-<name>-base-reports, with the candidate's.
# A record that only one run's queries returned is then a record both are
# judged against, and `usable` means the same thing on both sides. The control
# keeps the record run as it is: there is no second run to pool it with.
#
# The patch touches Sources/ in the scratch worktree alone. The lab branch
# itself never changes Sources/ (SPEC "The gate"): the candidates are evidence
# for later fixes, kept as patches under docs/audits/.../candidates/.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -lt 3 ]; then
  echo "usage: bash Scripts/lyric-match-lab/score-candidate.sh <root> <worktree> <name> [patch]" >&2
  exit 2
fi
LAB="$(cd "$1" && pwd)"
WT="$(cd "$2" && pwd)"
NAME="$3"
PATCH="${4:-}"
case "$NAME" in
  ""|*/*|*\\*|.*) echo "name must be a plain word, got: $NAME" >&2; exit 2 ;;
esac
if [ "$WT" = "$(cd "$HERE/../.." && pwd)" ]; then
  echo "refusing to patch the checkout this script runs from: use a scratch worktree" >&2
  exit 2
fi
if [ -n "$(git -C "$WT" status --porcelain -- Sources)" ]; then
  echo "$WT has uncommitted changes under Sources/: refusing to stack a patch on them" >&2
  exit 2
fi
BASE_REPORTS_NAME="${BASE_REPORTS:-}"
BASE_RESULTS_NAME="${BASE_RESULTS:-}"
if [ -n "$PATCH" ]; then
  # A candidate is compared with a base that is re-classified from its results
  # (below), so BASE_RESULTS is the only variable it reads. BASE_REPORTS alone
  # used to skip the control default and fall through to the record run, which
  # is exactly the base m11 forbids (fourth review, N3).
  if [ -z "$BASE_RESULTS_NAME" ]; then
    if [ -n "$BASE_REPORTS_NAME" ]; then
      echo "BASE_REPORTS is not read for a candidate: name the base run with BASE_RESULTS (or set neither" \
           "to use the control)" >&2
      exit 2
    elif [ -d "$LAB/cf-control-reports" ] && [ -d "$LAB/cf-control" ]; then
      BASE_RESULTS_NAME="cf-control"
    else
      echo "no control to compare $NAME with: score the control first (the same command with the name" \
           "control and no patch), or name another base with BASE_RESULTS" >&2
      exit 2
    fi
  fi
  # The run deletes and rewrites cf-$NAME, so it must not be the base it is
  # compared with: a patched "control" would become every later candidate's
  # base (fourth review, N4).
  if [ "$NAME" = "control" ] || [ "cf-$NAME" = "$BASE_RESULTS_NAME" ]; then
    echo "refusing to run a patch as $NAME: cf-$NAME is the base ($BASE_RESULTS_NAME) it would overwrite;" \
         "the control is the run with no patch, so give the candidate another name" >&2
    exit 2
  fi
  # The same whole-tree check the exit trap runs, before the patch is applied:
  # dirt that predates the run would otherwise be blamed on the patch (N5).
  if [ -n "$(git -C "$WT" status --porcelain)" ]; then
    echo "$WT has uncommitted changes: refusing to stack a patch on them:" >&2
    git -C "$WT" status --porcelain >&2
    exit 2
  fi
  PATCH="$(cd "$(dirname "$PATCH")" && pwd)/$(basename "$PATCH")"
  git -C "$WT" apply --check "$PATCH" || { echo "patch does not apply: $PATCH" >&2; exit 2; }
  git -C "$WT" apply "$PATCH"
  # Reverse the patch itself, not `checkout -- Sources`: a patch can touch
  # Tests/ and add files, and a checkout reverts neither. Then check, and fail
  # loudly if the scratch worktree is not what it was (third review, m11).
  restore() {
    local code=$?
    git -C "$WT" apply -R "$PATCH" || echo "could not reverse $PATCH in $WT" >&2
    if [ -n "$(git -C "$WT" status --porcelain)" ]; then
      echo "$WT is not clean after reversing the patch; fix it by hand before the next run:" >&2
      git -C "$WT" status --porcelain >&2
      exit 1
    fi
    exit $code
  }
  trap restore EXIT
else
  BASE_REPORTS_NAME="${BASE_REPORTS_NAME:-reports}"
  BASE_RESULTS_NAME="${BASE_RESULTS_NAME:-results}"
fi

OUT="cf-$NAME"
REPORTS="cf-$NAME-reports"
echo "candidate $NAME: ${PATCH:-no patch (control)}"
ISLA_MATCH_OUT="$OUT" ISLA_MATCH_REPORTS="$REPORTS" bash "$WT/Scripts/lyric-match-lab.sh" "$LAB"
STATUS=$?
if [ ! -s "$LAB/$OUT/isla-lookups.jsonl" ]; then
  echo "no $OUT/isla-lookups.jsonl: the candidate did not run" >&2
  exit 1
fi
if [ -n "$PATCH" ]; then
  # One pool for both sides: each run is classified with the other's responses.
  python3 "$HERE/classify.py" --root "$LAB" --results "$OUT" --reports "$REPORTS" \
    --pool-results "$BASE_RESULTS_NAME" >/dev/null || exit 1
  BASE_POOLED="cf-$NAME-base-reports"
  python3 "$HERE/classify.py" --root "$LAB" --results "$BASE_RESULTS_NAME" --reports "$BASE_POOLED" \
    --pool-results "$OUT" >/dev/null || exit 1
  python3 "$HERE/compare.py" --root "$LAB" --base "$BASE_POOLED" --base-results "$BASE_RESULTS_NAME" \
    --candidate "$REPORTS" --candidate-results "$OUT"
else
  python3 "$HERE/classify.py" --root "$LAB" --results "$OUT" --reports "$REPORTS" >/dev/null || exit 1
  python3 "$HERE/compare.py" --root "$LAB" --base "$BASE_REPORTS_NAME" --base-results "$BASE_RESULTS_NAME" \
    --candidate "$REPORTS" --candidate-results "$OUT"
fi
COMPARED=$?
if [ "$COMPARED" -ne 0 ]; then exit "$COMPARED"; fi
exit $((STATUS != 0))
