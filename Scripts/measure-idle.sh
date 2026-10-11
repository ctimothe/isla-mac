#!/bin/bash
# Awake-idle cost of the running Isla, for one scenario the owner sets by hand.
#
# Run by hand, never a gate. It samples the Isla that is already running —
# it never launches, quits, clicks or otherwise drives the app — with `top`
# every 5 s, and prints medians for the app and its media helper: CPU percent,
# idle wake-ups per second, context switches per second, physical footprint
# and resident size. Live session S17 runs it once per scenario (panel closed
# and idle for 5 min, panel closed with music playing, then 1 min each on the
# Music, Settings, Shelf and Clipboard tabs while playing), and checklist.md
# §Manual parity gates holds the result as the budget later work is held to.
#
# Why this exists (F-054): the only recorded wake-up figure came from the
# process's lifetime counter divided by its uptime, which averages hours of
# display sleep — when every sampler is stood down — into the number. While
# the display is awake the repeating timers alone are about 11 fires a second
# (PointerWatcher 8 Hz, ClipboardStore 2 Hz, the geometry watchdog, the feed
# watchdog, the helper heartbeat). So the display is held awake with
# `caffeinate -d` for exactly the length of the run, and the rates come from
# counter deltas between samples, never from the lifetime total. The lifetime
# average is still printed, labelled, so the two can be told apart.
#
# How to read it. `top`'s IDLEW counts only the wake-ups that took a core out
# of idle; a timer whose tolerance let the kernel fold it into somebody else's
# wake-up is not counted. It therefore depends on how busy the rest of the Mac
# is, and is good for before/after on the same machine and load, not as an
# absolute timer count. CSW (context switches) counts every time a thread of
# the process was scheduled, coalesced or not, and is the closer proxy for
# "how often do our timers fire". powermetrics would split this further but
# needs sudo, which a by-hand script should not ask for.
#
# usage: Scripts/measure-idle.sh <scenario> [samples]
#   scenario  a label for the record, e.g. closed-idle, closed-playing,
#             tab-music, tab-settings, tab-shelf, tab-clipboard
#   samples   5 s samples to take after a 5 s baseline; default 60 (5 min).
#             Use 12 for the 1 min per-tab scenarios.
set -euo pipefail

INTERVAL=5

usage() {
    echo "usage: $0 <scenario> [samples]   (samples of ${INTERVAL} s, default 60 = 5 min)" >&2
    exit 2
}

SCENARIO="${1:-}"
SAMPLES="${2:-60}"
[ -n "$SCENARIO" ] || usage
[[ "$SAMPLES" =~ ^[0-9]+$ ]] && [ "$SAMPLES" -ge 2 ] || usage

# Exactly one Isla. A second one is the duplicate-registration bug S17 also
# checks for, and sampling whichever pgrep lists first would measure the
# wrong process half the time.
APP_PIDS="$(pgrep -x Isla || true)"
if [ -z "$APP_PIDS" ]; then
    echo "Isla is not running. Start it from /Applications, set the scenario by hand, then rerun." >&2
    exit 1
fi
if [ "$(printf '%s\n' "$APP_PIDS" | wc -l | tr -d ' ')" -ne 1 ]; then
    echo "More than one Isla is running (pids: $(printf '%s ' "$APP_PIDS" | tr '\n' ' ')); quit the extra copies first." >&2
    exit 1
fi
APP_PID="$APP_PIDS"
# The helper is a child of this Isla, so a stale orphan from an earlier run is
# not sampled as ours. It can be absent (a fallback build, or mid-restart);
# then only the app is reported and the output says so.
HELPER_PID="$(pgrep -P "$APP_PID" -f libislamedia 2>/dev/null | head -n 1 || true)"

APP_BINARY="$(ps -o comm= -p "$APP_PID" | sed 's/^ *//')"
APP_PLIST="${APP_BINARY%/Contents/MacOS/*}/Contents/Info.plist"
APP_VERSION="unknown"
if [ -f "$APP_PLIST" ]; then
    APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PLIST" 2>/dev/null || echo '?') ($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP_PLIST" 2>/dev/null || echo '?'))"
fi

RAW_TOP="$(mktemp)"
RAW_RSS="$(mktemp)"
TOP_PID=""
CAFFEINATE_PID=""

cleanup() {
    [ -z "$TOP_PID" ] || kill "$TOP_PID" 2>/dev/null || true
    [ -z "$CAFFEINATE_PID" ] || kill "$CAFFEINATE_PID" 2>/dev/null || true
    rm -f "$RAW_TOP" "$RAW_RSS"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Held only while this script runs (-w), so nothing outlives the measurement.
caffeinate -d -w $$ &
CAFFEINATE_PID=$!

TOP_ARGS=(-l "$((SAMPLES + 1))" -s "$INTERVAL" -pid "$APP_PID")
[ -z "$HELPER_PID" ] || TOP_ARGS+=(-pid "$HELPER_PID")
TOP_ARGS+=(-stats "pid,cpu,idlew,csw,mem")

echo "==> $SCENARIO: ${SAMPLES} × ${INTERVAL} s after a ${INTERVAL} s baseline, Isla pid $APP_PID${HELPER_PID:+, helper pid $HELPER_PID}. Leave the Mac alone."
top "${TOP_ARGS[@]}" > "$RAW_TOP" 2>/dev/null &
TOP_PID=$!

# top's MEM column is the physical footprint (what Activity Monitor shows);
# the 88 MB budget and Scripts/measure-performance.sh use ps's resident size,
# so sample that alongside rather than mixing the two metrics.
while kill -0 "$TOP_PID" 2>/dev/null; do
    rss="$(ps -o rss= -p "$APP_PID" 2>/dev/null | tr -d ' ' || true)"
    [ -z "$rss" ] || echo "$rss" >> "$RAW_RSS"
    sleep "$INTERVAL"
done
wait "$TOP_PID" || true
TOP_PID=""

# A relaunch mid-run would splice two processes into one median.
if [ "$(pgrep -x Isla | head -n 1 || true)" != "$APP_PID" ]; then
    echo "Isla quit or relaunched during the run; nothing recorded." >&2
    exit 1
fi
APP_ETIME="$(ps -o etime= -p "$APP_PID" | tr -d ' ')"

python3 - "$RAW_TOP" "$RAW_RSS" "$SCENARIO" "$SAMPLES" "$INTERVAL" \
    "$APP_PID" "${HELPER_PID:-}" "$APP_VERSION" "$APP_ETIME" <<'PY'
import datetime
import re
import statistics
import sys

raw_top, raw_rss, scenario, samples, interval, app_pid, helper_pid, version, etime = sys.argv[1:]
samples = int(samples)
interval = float(interval)

STAMP = re.compile(r"^(\d{4}/\d\d/\d\d \d\d:\d\d:\d\d)")
ROW = re.compile(r"^(\d+)\s+([\d.]+)\s+(\d+)\S*\s+(\d+)\S*\s+([\d.]+)([BKMG])")
UNIT_MB = {"B": 1 / 1048576, "K": 1 / 1024, "M": 1.0, "G": 1024.0}

# One entry per top sample: its time and {pid: (cpu, idlew, csw, footprint MB)}.
blocks = []
for line in open(raw_top):
    stamp = STAMP.match(line)
    if stamp:
        blocks.append((datetime.datetime.strptime(stamp.group(1), "%Y/%m/%d %H:%M:%S"), {}))
        continue
    row = ROW.match(line)
    if row and blocks:
        pid, cpu, idlew, csw, mem, unit = row.groups()
        blocks[-1][1][pid] = (float(cpu), int(idlew), int(csw), float(mem) * UNIT_MB[unit])

if len(blocks) < 2:
    sys.exit("top produced fewer than two samples; nothing to report")


def summarise(pid):
    """Medians over the run. The first block is only the baseline: top's first
    CPU column has no previous sample to diff against and always reads 0.0,
    and the counters need a starting value to take deltas from."""
    cpu, idle_rate, csw_rate, footprint = [], [], [], []
    for (t0, before), (t1, after) in zip(blocks, blocks[1:]):
        if pid not in after:
            continue
        cpu.append(after[pid][0])
        footprint.append(after[pid][3])
        if pid in before:
            seconds = (t1 - t0).total_seconds() or interval
            idle_rate.append((after[pid][1] - before[pid][1]) / seconds)
            csw_rate.append((after[pid][2] - before[pid][2]) / seconds)
    if not cpu:
        return None
    return {
        "covered": len(cpu),
        "cpu": statistics.median(cpu),
        "cpu_max": max(cpu),
        "idle": statistics.median(idle_rate) if idle_rate else float("nan"),
        "csw": statistics.median(csw_rate) if csw_rate else float("nan"),
        "footprint": statistics.median(footprint),
    }


def seconds_of(etime):
    """ps etime is [[dd-]hh:]mm:ss."""
    days, _, clock = etime.rpartition("-")
    parts = [int(p) for p in clock.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    return (int(days) if days else 0) * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2]


rss = [int(v) / 1024 for v in open(raw_rss).read().split() if v.isdigit()]
app = summarise(app_pid)
helper = summarise(helper_pid) if helper_pid else None
if app is None:
    sys.exit("top never reported Isla; nothing to report")

lifetime_idle = blocks[-1][1][app_pid][1]
uptime = seconds_of(etime)

print()
print(f"scenario {scenario} · {datetime.date.today().isoformat()} · Isla {version} · "
      f"{app['covered']} of {samples} samples × {interval:.0f} s · display held awake")
print(f"{'':8}{'CPU % med':>10}{'max':>6}{'idle wake/s':>13}{'switches/s':>12}{'footprint MB':>14}{'RSS MB':>8}")
rows = [("Isla", app, statistics.median(rss) if rss else float("nan"))]
if helper:
    rows.append(("helper", helper, float("nan")))
for name, s, rss_mb in rows:
    rss_text = f"{rss_mb:8.1f}" if rss_mb == rss_mb else f"{'-':>8}"
    print(f"{name:8}{s['cpu']:10.1f}{s['cpu_max']:6.1f}{s['idle']:13.2f}{s['csw']:12.1f}"
          f"{s['footprint']:14.1f}{rss_text}")
if not helper_pid:
    print("helper  not running when the run started; the app is reported alone")
elif helper is None or helper["covered"] < app["covered"]:
    print("helper  restarted or exited during the run; its row covers only the samples it was alive for")
print(f"since launch (display sleep included): {lifetime_idle} idle wake-ups over "
      f"{uptime / 3600:.1f} h = {lifetime_idle / uptime if uptime else float('nan'):.2f}/s")
print()
print("for checklist.md:")
line = (f"  - {datetime.date.today().isoformat()} {scenario} (Isla {version}, "
        f"{samples} × {interval:.0f} s): CPU {app['cpu']:.1f} %, {app['idle']:.2f} idle wake-ups/s, "
        f"{app['csw']:.0f} switches/s, RSS {statistics.median(rss) if rss else float('nan'):.0f} MB")
if helper:
    line += f"; helper CPU {helper['cpu']:.1f} %, {helper['idle']:.2f} idle wake-ups/s, {helper['csw']:.0f} switches/s"
print(line)
PY
