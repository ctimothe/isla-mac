#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Dynamic Island.app"
BINARY="$APP/Contents/MacOS/DynamicIsland"
HELPER="$APP/Contents/Resources/libdynamicislandmedia.dylib"

test -x "$BINARY"
test -f "$HELPER"

APP_PID=""
trap '[ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true' EXIT

"$BINARY" >/dev/null 2>&1 &
APP_PID=$!
# The process is tracked by PID below. Removing it from Bash's job table keeps
# the expected SIGTERM from printing a misleading `Terminated: 15` diagnostic.
disown "$APP_PID" 2>/dev/null || true
for _ in $(seq 1 50); do
    kill -0 "$APP_PID" 2>/dev/null && break
    sleep 0.1
done
kill -0 "$APP_PID" 2>/dev/null

# Only children of *this* launch count. `pgrep -f` matches the dylib path in
# any perl command line, so an orphan left by a previously crashed run — or a
# concurrent measure-performance run against the same build directory —
# satisfied this wait and then failed the orphan check below as if it were ours.
helpers_of() { pgrep -P "$1" -f "$HELPER" 2>/dev/null; }

# Anything already holding that path predates this run and is not ours to
# judge; note it so a stale orphan is not mistaken for a clean machine.
PRE_EXISTING="$(pgrep -f "$HELPER" 2>/dev/null | sort || true)"
if [ -n "$PRE_EXISTING" ]; then
    echo "  note: helper processes from an earlier run are already present" >&2
fi

# Let the application start its media child before testing parent shutdown.
for _ in $(seq 1 50); do
    helpers_of "$APP_PID" >/dev/null && break
    sleep 0.1
done
helpers_of "$APP_PID" >/dev/null || {
    echo "the application never started its media helper" >&2
    exit 1
}
OUR_HELPERS="$(helpers_of "$APP_PID" | sort)"

kill -TERM "$APP_PID"
for _ in $(seq 1 50); do
    ! kill -0 "$APP_PID" 2>/dev/null && break
    sleep 0.1
done
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "Dynamic Island did not terminate within 5 seconds" >&2
    exit 1
fi
APP_PID=""

# Judged on the specific pids this launch produced, not on whatever else on
# the machine happens to match the path.
still_running() {
    for pid in $OUR_HELPERS; do
        kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}
for _ in $(seq 1 50); do
    still_running || break
    sleep 0.1
done
if still_running; then
    echo "orphan Dynamic Island media helper" >&2
    exit 1
fi

echo "  ✓ application and media helper terminate together"
