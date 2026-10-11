#!/bin/bash
# The headless visual lab: every surface Isla draws, rendered to PNG without a
# running app, plus the animation curves sampled at 1 ms and an accessibility
# dump per render. See docs/audits/2026-10-11-visual-lab/README.md.
#
# Nothing here touches the desktop. No window is ordered on screen, no event
# is posted, the screen is never captured, Isla is never launched, and no DI_*
# hook is read. The lab answers its own defaults from a volatile domain, uses
# a private pasteboard, and refuses every network request in-process.
#
#   bash Scripts/visual-lab.sh                 # renders into build/visual-lab
#   bash Scripts/visual-lab.sh /some/folder    # renders there instead
#   bash Scripts/visual-lab.sh /some/folder VisualLabPillTests   # one case
#
# Run by hand, never as a gate: `./scripts/check` runs the same test target
# and every lab case skips itself there, because ISLA_VISUAL_OUT is unset.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build/visual-lab}"
FILTER="${2:-VisualLab}"
case "$OUT" in
  /*) ;;
  *) OUT="$PWD/$OUT" ;;
esac

# A fresh folder for a full run, so the manifest only lists what this run
# drew. A single case adds to what is there.
if [ "$FILTER" = "VisualLab" ]; then
  rm -rf "$OUT"
fi
mkdir -p "$OUT"

cd "$ROOT"
started=$(date +%s)
ISLA_VISUAL_OUT="$OUT" swift test --disable-sandbox --filter "$FILTER"
elapsed=$(( $(date +%s) - started ))

count=$(find "$OUT" -name '*.png' -not -path "$OUT/contact-sheets/*" | wc -l | tr -d ' ')
echo
echo "visual lab: $count renders in ${elapsed}s"
echo "  manifest        $OUT/manifest.json"
echo "  contact sheets  $OUT/contact-sheets/"
echo "  animation       $OUT/animation/metrics.json and one CSV per curve"
echo "  accessibility   $OUT/a11y/"
