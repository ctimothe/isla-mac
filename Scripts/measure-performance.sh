#!/bin/bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <Cyclop.app> <Dynamic Island.app> <report.md>" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFERENCE_APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
PRODUCT_APP="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
REPORT="$3"
RAW="$(mktemp)"
CURRENT_PID=""
CURRENT_HELPER=""

cleanup() {
    if [ -n "$CURRENT_PID" ]; then
        kill -TERM "$CURRENT_PID" 2>/dev/null || true
        wait "$CURRENT_PID" 2>/dev/null || true
    fi
    if [ -n "$CURRENT_HELPER" ]; then
        pkill -f "$CURRENT_HELPER" 2>/dev/null || true
    fi
    rm -f "$RAW"
}
trap cleanup EXIT

echo 'label,run,sample,cpu,rss_kb,helper_rss_kb,bundle_kb,icon_bytes' > "$RAW"

sample_app() {
    local label="$1"
    local app="$2"
    local plist="$app/Contents/Info.plist"
    local executable
    local binary
    local helper
    local bundle_kb
    local icon_bytes

    test -f "$plist"
    executable="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$plist")"
    binary="$app/Contents/MacOS/$executable"
    helper="$(find "$app/Contents/Resources" -maxdepth 1 -name 'lib*media.dylib' -print -quit)"
    test -x "$binary"
    test -f "$helper"
    bundle_kb="$(du -sk "$app" | awk '{print $1}')"
    icon_bytes="$(stat -f '%z' "$app/Contents/Resources/AppIcon.icns" 2>/dev/null || echo 0)"
    CURRENT_HELPER="$helper"

    for run in 1 2 3; do
        echo "==> $label run $run/3"
        "$binary" >/dev/null 2>&1 &
        CURRENT_PID=$!
        sleep 3
        for point in $(seq 1 60); do
            kill -0 "$CURRENT_PID" 2>/dev/null || {
                echo "$label exited during sampling" >&2
                exit 1
            }
            local cpu
            local rss
            local helper_pid
            local helper_rss=""
            # The process can exit between the kill -0 above and these reads,
            # and under set -e that aborted the whole measurement with no
            # diagnostic. Treat it as what it is: the run ended early.
            cpu="$(ps -p "$CURRENT_PID" -o %cpu= | tr -d ' ' || true)"
            rss="$(ps -p "$CURRENT_PID" -o rss= | tr -d ' ' || true)"
            if [ -z "$cpu" ] || [ -z "$rss" ]; then
                echo "$label exited during sampling" >&2
                exit 1
            fi
            # Scoped to this launch's children, so a stale orphan from an
            # earlier run or a concurrent measurement is not sampled as ours.
            helper_pid="$(pgrep -P "$CURRENT_PID" -f "$helper" 2>/dev/null | head -n 1 || true)"
            if [ -n "$helper_pid" ]; then
                helper_rss="$(ps -p "$helper_pid" -o rss= | tr -d ' ' || true)"
            fi
            # An absent helper is recorded as absent, never as "0 KB". Zeros
            # entered the median and dragged it down, so a helper that never
            # spawned turned the comparison gate green for the exact failure it
            # exists to catch.
            [ -n "$helper_rss" ] || helper_rss=""
            echo "$label,$run,$point,$cpu,$rss,$helper_rss,$bundle_kb,$icon_bytes" >> "$RAW"
            sleep 1
        done
        kill -TERM "$CURRENT_PID"
        wait "$CURRENT_PID" 2>/dev/null || true
        CURRENT_PID=""
        sleep 1
        if pgrep -f "$helper" >/dev/null; then
            echo "$label helper survived its parent" >&2
            exit 1
        fi
    done
    CURRENT_HELPER=""
}

sample_app reference "$REFERENCE_APP"
sample_app product "$PRODUCT_APP"
mkdir -p "$(dirname "$REPORT")"

python3 - "$RAW" "$REPORT" "$REFERENCE_APP" "$PRODUCT_APP" "$ROOT" <<'PY'
import csv
import pathlib
import platform
import statistics
import subprocess
import sys

raw, report, reference_app, product_app, root = sys.argv[1:]
rows = list(csv.DictReader(open(raw, newline="")))

def values(label, key):
    return [float(row[key]) for row in rows if row["label"] == label and row[key] != ""]


def helper_values(label):
    """Samples where the helper was actually running.

    Missing samples used to be written as 0 and averaged in, which is how a
    helper that never spawned produced a median of zero and passed the "no
    greater than Cyclop" comparison."""
    seen = [row for row in rows if row["label"] == label]
    live = [float(row["helper_rss_kb"]) for row in seen if row["helper_rss_kb"] not in ("", "0")]
    return live, len(seen)

ref_cpu = values("reference", "cpu")
product_cpu = values("product", "cpu")
ref_rss = statistics.median(values("reference", "rss_kb"))
product_rss = statistics.median(values("product", "rss_kb"))
ref_helper_samples, ref_helper_total = helper_values("reference")
product_helper_samples, product_helper_total = helper_values("product")
# A helper that was running for less than most of the window is not something
# to take a median of; say so rather than quietly comparing noise.
helper_coverage = 0.5
ref_helper_ok = len(ref_helper_samples) >= ref_helper_total * helper_coverage
product_helper_ok = len(product_helper_samples) >= product_helper_total * helper_coverage
ref_helper = statistics.median(ref_helper_samples) if ref_helper_samples else 0.0
product_helper = statistics.median(product_helper_samples) if product_helper_samples else 0.0
ref_bundle = int(values("reference", "bundle_kb")[0])
product_bundle = int(values("product", "bundle_kb")[0])
ref_icon = int(values("reference", "icon_bytes")[0])
product_icon = int(values("product", "icon_bytes")[0])
icon_variance_kb = max(0, product_icon - ref_icon + 1023) // 1024
bundle_limit = ref_bundle + icon_variance_kb

checks = {
    # Compared against the reference, not against an absolute 0.0. A single
    # 0.1% sample — one Spotlight poke, one coalesced timer — used to fail the
    # entire run, while the reference's own CPU was collected and never
    # actually compared to anything.
    "Dynamic Island peak idle CPU is no worse than Cyclop": max(product_cpu) <= max(max(ref_cpu), 0.1),
    "Dynamic Island application RSS is no greater than Cyclop": product_rss <= ref_rss,
    "Both helpers ran for most of the sampling window": ref_helper_ok and product_helper_ok,
    "Dynamic Island helper RSS is no greater than Cyclop": product_helper <= ref_helper,
    "Bundle difference is limited to original icon variance": product_bundle <= bundle_limit,
}

try:
    model = subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip()
except Exception:
    model = "unknown"
commit = subprocess.check_output(["git", "-C", root, "rev-parse", "HEAD"], text=True).strip()
# Read from the pin file rather than baked in here, so bumping the pin cannot
# leave the report labelled with an upstream version it did not measure.
pin = dict(
    line.split("=", 1)
    for line in pathlib.Path(root, "UPSTREAM_CYCLOP_VERSION").read_text().splitlines()
    if "=" in line
)
upstream_version = pin.get("UPSTREAM_VERSION", "?")
upstream_commit = pin.get("UPSTREAM_COMMIT", "?")
lines = [
    f"# Cyclop {upstream_version} / Dynamic Island performance comparison",
    "",
    f"- Machine: `{model}`",
    f"- macOS: `{platform.mac_ver()[0]}`",
    f"- Cyclop {upstream_version}: `{upstream_commit}`",
    f"- Dynamic Island commit: `{commit}`",
    "- Samples: 3 runs × 60 one-second samples after 3 seconds warm-up",
    f"- Command: `bash Scripts/measure-performance.sh \"{reference_app}\" \"{product_app}\" \"{report}\"`",
    "",
    f"| Metric | Cyclop {upstream_version} | Dynamic Island |",
    "| --- | ---: | ---: |",
    f"| Peak idle CPU | {max(ref_cpu):.1f}% | {max(product_cpu):.1f}% |",
    f"| Median app RSS | {ref_rss / 1024:.2f} MiB | {product_rss / 1024:.2f} MiB |",
    f"| Median helper RSS | {ref_helper / 1024:.2f} MiB | {product_helper / 1024:.2f} MiB |",
    f"| Bundle payload | {ref_bundle / 1024:.2f} MiB | {product_bundle / 1024:.2f} MiB |",
    f"| App icon | {ref_icon} bytes | {product_icon} bytes |",
    "",
    "## Gates",
    "",
]
lines.extend(f"- [{'x' if passed else ' '}] {name}" for name, passed in checks.items())
pathlib.Path(report).write_text("\n".join(lines) + "\n")
if not all(checks.values()):
    raise SystemExit(1)
PY
