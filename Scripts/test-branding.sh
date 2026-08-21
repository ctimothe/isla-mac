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

# ripgrep where it exists, grep everywhere else. The gate has to be runnable on
# a machine that has not installed anything, or it is a gate in name only.
if command -v rg >/dev/null; then
    scan() { rg -n -i "$1" "${@:2}"; }
else
    scan() { grep -rniE "$1" "${@:2}"; }
fi

# The exit status is three-valued: 0 found, 1 no match, 2 error. Branching on
# truthiness alone treated an error as "nothing found", so an unreadable or
# renamed target made this gate pass green — with forbidden matches printed
# above it. Match explicitly on the three cases instead.
set +e
matches="$(scan 'cyclop|com\.cyclop|libcyclopmedia' "${targets[@]}")"
status=$?
set -e
case "$status" in
    0)
        echo "$matches"
        echo "forbidden upstream product identity remains" >&2
        exit 1
        ;;
    1) ;;
    *)
        echo "rg failed while scanning for upstream identity (exit $status)" >&2
        exit 1
        ;;
esac

grep -q 'dev.dynamicisland.app' "$ROOT/Scripts/bundle.sh"
grep -q 'Dynamic Island.app' "$ROOT/Scripts/bundle.sh"
grep -q 'libdynamicislandmedia.dylib' "$ROOT/Scripts/bundle.sh"

echo "  ✓ product identity is original throughout"
