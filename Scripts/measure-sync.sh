#!/bin/bash
# Ground-truth position-sync measurement against a live scriptable player.
#
# Runs the real pipeline — the shipped helper, NowPlayingFeed, and
# MediaController's actual anchor/adopt/tick logic — in-process, and samples
# it at 5Hz against Apple Music's or Spotify's own scriptable player position,
# clock its UI renders. Scripted events cover the edges: pause, resume, a
# forward seek, a large backward seek, and a sub-threshold backward one. Word
# columns sample exactly the enhanced LRC fixture selected for the playing
# track, reporting word-edge disagreement and gating zero word movement while
# paused.
#
# This exists because the position code has now twice been "fixed" on
# reasoning alone and been wrong about the result. Claims about sync accuracy
# are made from this harness's numbers or not at all.
#
# Set SYNC_PLAYER=spotify or SYNC_PLAYER=music (Spotify is the default), and
# SYNC_LRC_FIXTURE=/absolute/path/file.lrc for the exact track under test.
# Requires that player running with a track. WILL pause and seek the music, then restore it.
set -euo pipefail
SYNC_PLAYER="${SYNC_PLAYER:-spotify}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="${SYNC_LRC_FIXTURE:-}"
if [[ "$FIXTURE" != /* ]] || [ ! -r "$FIXTURE" ]; then
  echo "SYNC_LRC_FIXTURE must name a readable absolute enhanced-LRC file" >&2
  exit 2
fi
VALIDATION="$(bash "$ROOT/Scripts/validate-lrc.sh" "$FIXTURE")" || exit $?
if ! grep -qx 'granularity: word' <<<"$VALIDATION"; then
  echo "SYNC_LRC_FIXTURE must contain enhanced word timestamps" >&2
  exit 2
fi
export SYNC_LRC_FIXTURE="$FIXTURE"
case "$SYNC_PLAYER" in
  spotify) PLAYER_BUNDLE_ID="com.spotify.client"; PLAYER_PROCESS="Spotify" ;;
  music) PLAYER_BUNDLE_ID="com.apple.Music"; PLAYER_PROCESS="Music" ;;
  *) echo "SYNC_PLAYER must be spotify or music" >&2; exit 2 ;;
esac
if ! pgrep -x "$PLAYER_PROCESS" >/dev/null; then
  echo "$PLAYER_PROCESS must already be running with a track" >&2
  exit 2
fi
export SYNC_PLAYER
ORIGINAL_STATE=""
ORIGINAL_POSITION=""
if original="$(osascript -e "tell application id \"$PLAYER_BUNDLE_ID\" to return (player state as text) & \"|\" & (player position as text)" 2>/dev/null)"; then
  ORIGINAL_STATE="${original%%|*}"
  ORIGINAL_POSITION="${original#*|}"
fi
OUT="$(mktemp -d "${TMPDIR:-/tmp}/sync-probe-XXXXXX")"
# Every other script here sets one; this one leaked a compiled binary and a copy
# of the helper dylib into /tmp on every run.
restore_player() {
  [ -n "$ORIGINAL_POSITION" ] || return
  osascript -e "tell application id \"$PLAYER_BUNDLE_ID\" to set player position to $ORIGINAL_POSITION" >/dev/null 2>&1 || true
  case "$ORIGINAL_STATE" in
    playing) osascript -e "tell application id \"$PLAYER_BUNDLE_ID\" to play" >/dev/null 2>&1 || true ;;
    *) osascript -e "tell application id \"$PLAYER_BUNDLE_ID\" to pause" >/dev/null 2>&1 || true ;;
  esac
}
cleanup() {
  restore_player
  rm -rf "$OUT"
}
trap cleanup EXIT

# The probe writes here, and only this run can see it. It used to write a fixed
# /tmp/sync-probe.csv through a `try?` that swallowed failures, so a run that
# could not write its results silently analysed the previous run's file and
# printed those numbers as this run's ground truth.
CSV="${SYNC_PROBE_CSV:-$OUT/sync-probe.csv}"
export SYNC_PROBE_CSV="$CSV"
REPORT="${SYNC_PROBE_REPORT:-/dev/stdout}"

swift build --package-path "$ROOT" >/dev/null
# Asked for, not assumed: the hard-coded arm64 path failed outright on an Intel
# Mac and under Rosetta.
BUILD="$(swift build --package-path "$ROOT" --show-bin-path)"
# The probe must link exactly the active IslaKit target, never obsolete
# implementations left in .build. The newer toolchain emits one merged
# `IslaKit.o` and no per-source objects; the older one emitted a `.o` per
# source. See the same note in `Scripts/validate-lrc.sh`.
OBJECTS=()
MODULE_PATH="$BUILD"
if [ -f "$BUILD/IslaKit.o" ]; then
  OBJECTS=("$BUILD/IslaKit.o")
else
  [ -d "$BUILD/Modules" ] && MODULE_PATH="$BUILD/Modules"
  while IFS= read -r source; do
    object="$BUILD/IslaKit.build/$(basename "$source").o"
    [ -f "$object" ] || { echo "missing IslaKit object: $object" >&2; exit 1; }
    OBJECTS+=("$object")
  done < <(find "$ROOT/Sources/IslaKit" -type f -name '*.swift' | sort)
fi
swiftc -parse-as-library -enable-testing "$ROOT/Scripts/sync-probe/SyncProbe.swift" \
  -I "$MODULE_PATH" "${OBJECTS[@]}" \
  -framework Carbon -o "$OUT/sync-probe"
cp "$ROOT/build/Isla.app/Contents/Resources/libislamedia.dylib" "$OUT/" 2>/dev/null \
  || { echo "run Scripts/bundle.sh first (needs the helper dylib)"; exit 1; }

osascript -e "tell application id \"$PLAYER_BUNDLE_ID\" to play" >/dev/null
"$OUT/sync-probe"

[ -s "$CSV" ] || { echo "!!! the probe produced no results at $CSV" >&2; exit 1; }

python3 - "$CSV" <<'PY' | tee "$REPORT"
import csv, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
if not rows:
    raise SystemExit("!!! no samples recorded")
print(f"\n{len(rows)} samples  (delta = ours - truth; negative = we run behind)")

def percentile95(values):
    values = sorted(values)
    return values[max(0, int(len(values) * 0.95 + 0.999999) - 1)]

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

# Diagnostic: the probe's word-edge column reports how far apart the two
# clocks' current word starts land. It cannot gate correctness: the synthetic
# grid intentionally reports up to one word interval around a boundary. The
# measured lyric-surface p95 below is the accuracy gate. The paused clock must
# still not move at all (no index or fraction drift while paused).
werrs = [float(r["werr"]) for r in rows if 0 <= float(r["t"]) < 8]
if not werrs:
    failures.append("word-edge: no steady samples")
else:
    wmedian = statistics.median(werrs)
    print(f"  word-edge steady median={wmedian:.3f}  max={max(werrs):.3f}")

# Word animation stands on the same measured screen clock. Judge that clock
# at p95 rather than only its median: a rare 300ms miss is visible even when
# the average looks good.
timing_errors = [abs(float(r["surfaceDelta"])) for r in rows if 0 <= float(r["t"]) < 8]
if not timing_errors:
    failures.append("word timing: no steady samples")
else:
    timing_p95 = percentile95(timing_errors)
    print(f"  word-timing steady p95={timing_p95:.3f}s")
    if timing_p95 > 0.150:
        failures.append(f"word timing: p95 {timing_p95:.3f}s > 0.150s")
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
print("diagnostic: word-edge disagreement; gate: zero word movement while paused")
print("gate: Apple Music and Spotify word timing steady p95 <= 0.150s")
# Actually enforced. The bounds above used to be printed and nothing more: the
# medians were computed, never compared, and the script exited 0 with sync
# seconds out.
if failures:
    for failure in failures:
        print(f"  FAIL {failure}")
    raise SystemExit(1)
print("  PASS")
PY
