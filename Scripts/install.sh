#!/bin/bash
# Installs the app Scripts/bundle.sh assembled into /Applications, replacing
# the copy there, and opens it.
#
# One copy, in one place. Opening the bundle straight from build/ registered
# it with LaunchServices beside the installed one, and every such launch left
# another "Isla" in Spotlight and another candidate for the Spotify sign-in
# callback — three of them on 2026-09-21. The built bundle is unregistered
# here, so the only Isla the system knows is the one in /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/app.noindex/Isla.app"
DEST="/Applications/Isla.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[ -d "$APP" ] || { echo "!!! no app at $APP — run: bash Scripts/bundle.sh release" >&2; exit 1; }

if pgrep -x Isla >/dev/null; then
    pkill -x Isla || true
    for _ in $(seq 1 50); do
        pgrep -x Isla >/dev/null || break
        sleep 0.1
    done
fi

rm -rf "$DEST"
# ditto keeps the signature, the extended attributes and the symlinks intact.
ditto "$APP" "$DEST"
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$DEST"

open "$DEST"
echo "==> installed and opened $DEST"
