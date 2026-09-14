#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --package-path "$ROOT" >/dev/null
BUILD="$(swift build --package-path "$ROOT" --show-bin-path)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/isla-lrc-validator-XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

# SwiftPM leaves objects for removed source files in .build. Link only the
# current IslaKit sources so deleted network-lyrics objects cannot leak back
# into this standalone tool.
OBJECTS=()
while IFS= read -r source; do
  object="$BUILD/IslaKit.build/$(basename "$source").o"
  [ -f "$object" ] || { echo "missing IslaKit object: $object" >&2; exit 1; }
  OBJECTS+=("$object")
done < <(find "$ROOT/Sources/IslaKit" -type f -name '*.swift' | sort)

swiftc -parse-as-library -enable-testing "$ROOT/Scripts/validate-lrc.swift" \
  -I "$BUILD/Modules" "${OBJECTS[@]}" \
  -framework Carbon -o "$OUT/validate-lrc"
"$OUT/validate-lrc" "$@"
