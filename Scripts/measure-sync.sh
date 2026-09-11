#!/bin/bash
# Ground-truth position-sync measurement against a live Spotify.
#
# Runs the real pipeline — the shipped helper, NowPlayingFeed, and
# MediaController's actual anchor/adopt/tick logic — in-process, and samples
# it at 5Hz against Spotify's own scriptable player position, which is the
# clock its UI renders. Scripted events cover the edges: pause, resume, a
# forward seek, a large backward seek, and a sub-threshold backward one. Word
# columns sample a word-tier fixture for the playing track (its cached lyrics
# when they carry word timing, else a synthetic grid), gating steady word-edge
# error under 0.3s and zero word movement while paused.
#
# This exists because the position code has now twice been "fixed" on
# reasoning alone and been wrong about the result. Claims about sync accuracy
# are made from this harness's numbers or not at all.
#
# Requires: Spotify running with a track. WILL pause and seek the music.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/sync-probe-XXXXXX")"
# Every other script here sets one; this one leaked a compiled binary and a copy
# of the helper dylib into /tmp on every run.
trap 'rm -rf "$OUT"' EXIT

# The probe writes here, and only this run can see it. It used to write a fixed
# /tmp/sync-probe.csv through a `try?` that swallowed failures, so a run that
# could not write its results silently analysed the previous run's file and
# printed those numbers as this run's ground truth.
CSV="$OUT/sync-probe.csv"
export SYNC_PROBE_CSV="$CSV"

swift build --package-path "$ROOT" >/dev/null
# Asked for, not assumed: the hard-coded arm64 path failed outright on an Intel
# Mac and under Rosetta.
BUILD="$(swift build --package-path "$ROOT" --show-bin-path)"
swiftc -parse-as-library "$ROOT/Scripts/sync-probe/SyncProbe.swift" \
  -I "$BUILD/Modules" "$BUILD"/IslaKit.build/*.o \
  -framework Carbon -o "$OUT/sync-probe"
cp "$ROOT/build/Isla.app/Contents/Resources/libislamedia.dylib" "$OUT/" 2>/dev/null \
  || { echo "run Scripts/bundle.sh first (needs the helper dylib)"; exit 1; }

osascript -e 'tell application "Spotify" to play' >/dev/null
"$OUT/sync-probe"

[ -s "$CSV" ] || { echo "!!! the probe produced no results at $CSV" >&2; exit 1; }

python3 - "$CSV" <<'PY'
import csv, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
if not rows:
    raise SystemExit("!!! no samples recorded")
print(f"\n{len(rows)} samples  (delta = ours - truth; negative = we run behind)")

STEADY = (-0.5, 0.2)
PHASE = (-0.6, 0.6)
phases = [(0,8,"steady play"),(8,12,"paused"),(12,18,"resumed"),
          (18,26,"after SEEK+30"),(26,34,"after SEEK-10"),(34,45,"after SEEK-1.5")]

failures = []
for a, b, label in phases:
    ds = [float(r["delta"]) for r in rows if a <= float(r["t"]) < b]
    if not ds:
        failures.append(f"{label}: no samples")
        continue
    median = statistics.median(ds)
    print(f"  {label:16} median={median:+.3f}  mean={statistics.mean(ds):+.3f}"
          f"  min={min(ds):+.3f}  max={max(ds):+.3f}")
    low, high = STEADY if label == "steady play" else PHASE
    if not (low <= median <= high):
        failures.append(f"{label}: median {median:+.3f} outside [{low}, {high}]")

# Word gate: the probe's word-edge error column speaks in lyric units — how far
# apart the two clocks' current words start. Steady median under 0.3s, and the
# paused clock must not move at all (no index or fraction drift while paused).
werrs = [float(r["werr"]) for r in rows if 0 <= float(r["t"]) < 8]
if not werrs:
    failures.append("word-edge: no steady samples")
else:
    wmedian = statistics.median(werrs)
    print(f"  word-edge steady median={wmedian:.3f}  max={max(werrs):.3f}")
    if wmedian >= 0.3:
        failures.append(f"word-edge: steady median {wmedian:.3f} >= 0.3")
# The first second after the pause event is the transition — the final
# readings landing — so the freeze is judged on the settled remainder.
paused = [r for r in rows if 9 <= float(r["t"]) < 12]
if not paused:
    failures.append("paused words: no samples")
else:
    widx = {r["wordOurs"] for r in paused}
    fracs = [float(r["fracOurs"]) for r in paused]
    drift = max(fracs) - min(fracs)
    print(f"  paused words: {len(widx)} distinct word(s), fraction drift={drift:.4f}")
    if len(widx) != 1 or drift != 0:
        failures.append("paused words: clock moved while paused")

print("\ngate: steady-play median within [-0.5, +0.2]; every phase median within [-0.6, +0.6]")
print("gate: steady word-edge median < 0.3; zero word movement while paused")
# Actually enforced. The bounds above used to be printed and nothing more: the
# medians were computed, never compared, and the script exited 0 with sync
# seconds out.
if failures:
    for failure in failures:
        print(f"  FAIL {failure}")
    raise SystemExit(1)
print("  PASS")
PY
