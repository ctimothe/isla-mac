#!/bin/bash
# What each surface costs the main thread to build and lay out: the work a
# swap does inside its first frame. See the header of
# Tests/IslaKitTests/MountCostLab.swift.
#
# Run by hand, never a gate: `./scripts/check` runs the same test class with
# ISLA_MOUNT_OUT unset, where it skips itself. Unlike measure-hitches.sh it
# needs no window on screen, no `yes` processes and no idle Mac: nothing is
# ordered in, Isla is never launched and no DI_* hook is read. CPU time on the
# main thread's own clock does not depend on what else the Mac is doing, so a
# before and after on the same Mac compare; the median of 15 builds, after two
# that warm the process, is the number.
#
# Built in release with testing enabled, as the hitch lab is: the app's own
# view bodies in a debug build are a different cost.
#
#   bash Scripts/measure-mounts.sh <label> [out-folder]
#   ISLA_MOUNT_ONLY=settings-lyrics ISLA_MOUNT_RUNS=600 bash Scripts/measure-mounts.sh profile
#     (one surface in a loop, long enough to `sample` the xctest process)
#
# The result is <out-folder>/mounts-<label>.json and .txt, and the table on
# stdout.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="${1:-}"
[ -n "$LABEL" ] || { echo "usage: $0 <label> [out-folder]" >&2; exit 2; }
OUT="${2:-$ROOT/build/mount-lab}"
case "$OUT" in
  /*) ;;
  *) OUT="$PWD/$OUT" ;;
esac
mkdir -p "$OUT"
cd "$ROOT"
# The lab reuses the visual lab's session, which wants an output folder.
ISLA_VISUAL_OUT="$OUT/visual" ISLA_MOUNT_OUT="$OUT" ISLA_MOUNT_LABEL="$LABEL" \
  swift test -c release -Xswiftc -enable-testing --disable-sandbox --filter MountCostLab
