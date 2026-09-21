#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --package-path "$ROOT" >/dev/null
BUILD="$(swift build --package-path "$ROOT" --show-bin-path)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/isla-lrc-validator-XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

# How IslaKit is linked into a standalone tool, and why it is asked for rather
# than assumed.
#
# This enumerated one `.o` per source file under `$BUILD/IslaKit.build`, to keep
# objects for deleted sources — old network-lyrics code — from leaking back in.
# The toolchain's newer build system emits a single merged `IslaKit.o` beside
# the swiftmodule in the products directory and no per-source objects at all, so
# the loop failed outright on "missing IslaKit object" and took this script and
# `measure-sync.sh` down with it. The merged object is built from the current
# sources by definition, which answers the original worry better than the loop
# did. Both layouts are handled so an older toolchain still works.
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

swiftc -parse-as-library -enable-testing "$ROOT/Scripts/validate-lrc.swift" \
  -I "$MODULE_PATH" "${OBJECTS[@]}" \
  -framework Carbon -o "$OUT/validate-lrc"
"$OUT/validate-lrc" "$@"
