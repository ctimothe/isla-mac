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
            local helper_rss=0
            cpu="$(ps -p "$CURRENT_PID" -o %cpu= | tr -d ' ')"
            rss="$(ps -p "$CURRENT_PID" -o rss= | tr -d ' ')"
            helper_pid="$(pgrep -f "$helper" | head -n 1 || true)"
            if [ -n "$helper_pid" ]; then
                helper_rss="$(ps -p "$helper_pid" -o rss= | tr -d ' ')"
            fi
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
    return [float(row[key]) for row in rows if row["label"] == label]

ref_cpu = values("reference", "cpu")
product_cpu = values("product", "cpu")
ref_rss = statistics.median(values("reference", "rss_kb"))
product_rss = statistics.median(values("product", "rss_kb"))
ref_helper = statistics.median(values("reference", "helper_rss_kb"))
product_helper = statistics.median(values("product", "helper_rss_kb"))
ref_bundle = int(values("reference", "bundle_kb")[0])
product_bundle = int(values("product", "bundle_kb")[0])
ref_icon = int(values("reference", "icon_bytes")[0])
product_icon = int(values("product", "icon_bytes")[0])
icon_variance_kb = max(0, product_icon - ref_icon + 1023) // 1024
bundle_limit = ref_bundle + icon_variance_kb

checks = {
    "Dynamic Island idle CPU is 0.0% for all samples": max(product_cpu) == 0.0,
    "Dynamic Island application RSS is no greater than Cyclop": product_rss <= ref_rss,
    "Dynamic Island helper RSS is no greater than Cyclop": product_helper <= ref_helper,
    "Bundle difference is limited to original icon variance": product_bundle <= bundle_limit,
}

try:
    model = subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip()
except Exception:
    model = "unknown"
commit = subprocess.check_output(["git", "-C", root, "rev-parse", "HEAD"], text=True).strip()
lines = [
    "# Cyclop 0.6.5 / Dynamic Island performance comparison",
    "",
    f"- Machine: `{model}`",
    f"- macOS: `{platform.mac_ver()[0]}`",
    "- Cyclop commit: `7ab60c8198681ea6c895fa55458448efb6e4c36e`",
    f"- Dynamic Island commit: `{commit}`",
    "- Samples: 3 runs × 60 one-second samples after 3 seconds warm-up",
    f"- Command: `bash Scripts/measure-performance.sh \"{reference_app}\" \"{product_app}\" \"{report}\"`",
    "",
    "| Metric | Cyclop 0.6.5 | Dynamic Island |",
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
