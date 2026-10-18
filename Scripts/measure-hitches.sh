#!/bin/bash
# How the island's own morphs behave on a real screen — open, close, a surface
# change, an alert folding in — with the Mac idle, with one `yes` per core (the
# brief's recipe) and with three per core, and what a 50 ms block of the main
# thread costs mid-morph (redesign spec §19.12, "the island lags while I work").
#
# Run by hand, never a gate: it needs a window-server session, so it must run
# outside the shell sandbox, and `./scripts/check` runs the same test class
# with ISLA_HITCH_OUT unset, where every case skips itself.
#
# It never launches, quits, clicks or signals Isla. It builds the same view
# stack in a throwaway panel at the notch (alpha 0.02, mouse events ignored),
# drives the morphs from the view model under a real NSApplication.run(), and
# reads the display link and the main thread's CPU time. It starts the `yes`
# processes itself and ends them: when the case finishes, and here again on any
# exit, by the pids it wrote down.
#
# Built in release with testing enabled: SwiftUI and AppKit are the system's
# either way, but the app's own view bodies are not, and a debug build of
# those is a different animation.
#
#   bash Scripts/measure-hitches.sh <label> [out-folder]
#   ISLA_HITCH_SCENARIOS=open-close ISLA_HITCH_LOADS=saturated \
#     ISLA_HITCH_CYCLES=12 bash Scripts/measure-hitches.sh after
#
#   scenarios: rest-playing, rest-paused, open-close, open-close-lyrics,
#              surface-change, alert, open-stall, alert-stall   (default: all)
#   loads:     idle, stressed, saturated                       (default: all)
#   ISLA_HITCH_CYCLES   measured cycles per step, after two of warm-up (default 8)
#   ISLA_HITCH_BUNDLE   a test bundle built earlier (a copy of
#                       .build/release/IslaPackageTests.xctest), to measure the
#                       code as it was without rebuilding it
#
# The result is <out-folder>/hitches-<label>.json and the table on stdout. The
# load average at the start is recorded with it: on a Mac that is already busy
# the "idle" runs are not idle, and only runs at similar load compare.
#
# Columns: hitch/s is Apple's hitch time in ms per second of morph, from the
# display link; missed is frames of the display's rate (120 Hz where it is
# ProMotion) the main thread did not deliver; cpu is the main thread's CPU
# time over the 1 s window; gap is the longest gap between display-link
# callbacks. The *-stall scenarios block the main thread for 50 ms, 120 ms in,
# which costs the frames that wait on it wherever it falls. What the outline
# itself does meanwhile cannot be read from this process (see the header of
# OutlineHitchLab.swift); R8d-H1 in checklist.md is that check.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="${1:-}"
[ -n "$LABEL" ] || { echo "usage: $0 <label> [out-folder]" >&2; exit 2; }
OUT="${2:-$ROOT/build/hitch-lab}"
case "$OUT" in
  /*) ;;
  *) OUT="$PWD/$OUT" ;;
esac
mkdir -p "$OUT"

cleanup() {
  # Only what the case wrote down, and only if it still is a `yes`: a pid
  # file can outlive its processes, and pids are reused.
  if [ -f "$OUT/stress.pids" ]; then
    while read -r pid; do
      [ -n "$pid" ] || continue
      if [ "$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ')" = "/usr/bin/yes" ]; then
        kill "$pid" 2>/dev/null || true
      fi
    done < "$OUT/stress.pids"
    rm -f "$OUT/stress.pids"
  fi
}
trap cleanup EXIT INT TERM

cd "$ROOT"
if [ -n "${ISLA_HITCH_BUNDLE:-}" ]; then
  # A test bundle built earlier (a copy of .build/release/IslaPackageTests.xctest
  # taken before a change), so a before and an after can be measured one after
  # the other on the same Mac without rebuilding the old code.
  ISLA_VISUAL_OUT="$OUT/visual" ISLA_HITCH_OUT="$OUT" ISLA_HITCH_LABEL="$LABEL" \
    xcrun xctest -XCTest IslaKitTests.OutlineHitchLab/testMorphHitches "$ISLA_HITCH_BUNDLE"
else
  ISLA_VISUAL_OUT="$OUT/visual" ISLA_HITCH_OUT="$OUT" ISLA_HITCH_LABEL="$LABEL" \
    swift test -c release -Xswiftc -enable-testing --disable-sandbox --filter OutlineHitchLab
fi
echo
echo "hitch lab: $OUT/hitches-$LABEL.json"
