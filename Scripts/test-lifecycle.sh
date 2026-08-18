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

# Let the application start its media child before testing parent shutdown.
for _ in $(seq 1 50); do
    pgrep -f "$HELPER" >/dev/null && break
    sleep 0.1
done
pgrep -f "$HELPER" >/dev/null

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

for _ in $(seq 1 50); do
    ! pgrep -f "$HELPER" >/dev/null && break
    sleep 0.1
done
if pgrep -f "$HELPER" >/dev/null; then
    echo "orphan Dynamic Island media helper" >&2
    exit 1
fi

echo "  ✓ application and media helper terminate together"
