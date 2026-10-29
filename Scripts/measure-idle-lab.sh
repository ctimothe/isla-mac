#!/bin/bash
# What each resting state of the island costs, without the installed Isla.
#
# Run by hand, never a gate. It runs `IdleCostLab` (Tests/IslaKitTests), which
# builds the island's own panel at an alpha of 0.02, deaf to the pointer, and
# holds it in each state — shut and paused, shut and playing, shut with the
# lyric caption, open on each page — for a fixed time, reading the process's
# CPU, the main thread's, the main run loop's wake-ups and the kernel's
# wake-up counters. Isla itself is never launched, quit or signalled, so this
# can run while the owner works; `Scripts/measure-idle.sh` is the same question
# asked of the running app, and is the one that sees the always-on timers.
#
# Needs a window-server session (a display link and a composited window), so
# it runs outside the shell sandbox. Compare two builds on the same Mac and
# load, one after the other: a figure from a busy Mac is not a figure from a
# quiet one.
#
# usage: Scripts/measure-idle-lab.sh <label> [out-folder]
#   ISLA_IDLE_SECONDS  seconds per state (default 15)
#   ISLA_IDLE_STATES   a comma-separated subset, e.g. floor,shut-caption
#   ISLA_IDLE_BUNDLE   a test bundle built earlier, to measure a before
#   ISLA_IDLE_DUMP     set to 1 to write each state's main run loop (its timers)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="${1:-}"
[ -n "$LABEL" ] || { echo "usage: $0 <label> [out-folder]" >&2; exit 2; }
OUT="${2:-$ROOT/build/idle-lab}"
case "$OUT" in
  /*) ;;
  *) OUT="$PWD/$OUT" ;;
esac
mkdir -p "$OUT"

cd "$ROOT"
if [ -n "${ISLA_IDLE_BUNDLE:-}" ]; then
  ISLA_VISUAL_OUT="$OUT/visual" ISLA_IDLE_OUT="$OUT" ISLA_IDLE_LABEL="$LABEL" \
    xcrun xctest -XCTest IslaKitTests.IdleCostLab/testIdleCost "$ISLA_IDLE_BUNDLE"
else
  ISLA_VISUAL_OUT="$OUT/visual" ISLA_IDLE_OUT="$OUT" ISLA_IDLE_LABEL="$LABEL" \
    swift test -c release -Xswiftc -enable-testing --disable-sandbox --filter IdleCostLab
fi
echo
echo "idle-cost lab: $OUT/idle-$LABEL.json"
