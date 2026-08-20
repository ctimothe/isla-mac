#!/bin/bash
# Ground-truth position-sync measurement against a live Spotify.
#
# Runs the real pipeline — the shipped helper, NowPlayingFeed, and
# MediaController's actual anchor/adopt/tick logic — in-process, and samples
# it at 5Hz against Spotify's own scriptable player position, which is the
# clock its UI renders. Scripted events cover the edges: pause, resume, a
# forward seek, a large backward seek, and a sub-threshold backward one.
#
# This exists because the position code has now twice been "fixed" on
# reasoning alone and been wrong about the result. Claims about sync accuracy
# are made from this harness's numbers or not at all.
#
# Requires: Spotify running with a track. WILL pause and seek the music.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d /tmp/sync-probe-XXXX)"

swift build --package-path "$ROOT" >/dev/null
BUILD="$ROOT/.build/arm64-apple-macosx/debug"
swiftc -parse-as-library "$ROOT/Scripts/sync-probe/SyncProbe.swift" \
  -I "$BUILD/Modules" "$BUILD"/DynamicIslandKit.build/*.o \
  -framework Carbon -o "$OUT/sync-probe"
cp "$ROOT/build/Dynamic Island.app/Contents/Resources/libdynamicislandmedia.dylib" "$OUT/" 2>/dev/null \
  || { echo "run Scripts/bundle.sh first (needs the helper dylib)"; exit 1; }

osascript -e 'tell application "Spotify" to play' >/dev/null
"$OUT/sync-probe"

python3 - <<'PY'
import csv, statistics
rows = list(csv.DictReader(open("/tmp/sync-probe.csv")))
print(f"\n{len(rows)} samples  (delta = ours - truth; negative = we run behind)")
for a, b, label in [(0,8,"steady play"),(8,12,"paused"),(12,18,"resumed"),
                    (18,26,"after SEEK+30"),(26,34,"after SEEK-10"),(34,45,"after SEEK-1.5")]:
    ds = [float(r["delta"]) for r in rows if a <= float(r["t"]) < b]
    if ds:
        print(f"  {label:16} median={statistics.median(ds):+.3f}  mean={statistics.mean(ds):+.3f}"
              f"  min={min(ds):+.3f}  max={max(ds):+.3f}")
print("\ngate: steady-play median within [-0.5, +0.2]; every phase median within [-0.6, +0.6]")
PY
