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
if [ -n "$PATCH" ]; then
  PATCH="$(cd "$(dirname "$PATCH")" && pwd)/$(basename "$PATCH")"
  git -C "$WT" apply --check "$PATCH" || { echo "patch does not apply: $PATCH" >&2; exit 2; }
  git -C "$WT" apply "$PATCH"
  trap 'git -C "$WT" checkout -- Sources' EXIT
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
python3 "$HERE/classify.py" --root "$LAB" --results "$OUT" --reports "$REPORTS" >/dev/null || exit 1
python3 "$HERE/compare.py" --root "$LAB" --base reports --candidate "$REPORTS" --candidate-results "$OUT"
exit $((STATUS != 0))
