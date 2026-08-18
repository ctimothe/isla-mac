#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
targets=(
    "$ROOT/Sources"
    "$ROOT/Resources"
    "$ROOT/Scripts/bundle.sh"
    "$ROOT/Scripts/dmg.sh"
    "$ROOT/Scripts/release.sh"
    "$ROOT/Scripts/test-helper.sh"
)
if [ -f "$ROOT/Scripts/make-icon.swift" ]; then
    targets+=("$ROOT/Scripts/make-icon.swift")
fi

if rg -n -i 'cyclop|com\.cyclop|libcyclopmedia' "${targets[@]}"; then
    echo "forbidden upstream product identity remains" >&2
    exit 1
fi

rg -q 'dev.dynamicisland.app' "$ROOT/Scripts/bundle.sh"
rg -q 'Dynamic Island.app' "$ROOT/Scripts/bundle.sh"
rg -q 'libdynamicislandmedia.dylib' "$ROOT/Scripts/bundle.sh"
