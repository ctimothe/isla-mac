#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Read from the pin file, never duplicated here. A second copy of the commit
# meant bumping the pin left this cloning the old one, silently — while
# test-provenance, which checks the pin against itself, still passed.
PIN="$ROOT/UPSTREAM_CYCLOP_VERSION"
COMMIT="$(sed -n 's/^UPSTREAM_COMMIT=//p' "$PIN")"
UPSTREAM_VERSION="$(sed -n 's/^UPSTREAM_VERSION=//p' "$PIN")"
UPSTREAM_URL="$(sed -n 's/^UPSTREAM_URL=//p' "$PIN")"
[ -n "$COMMIT" ] && [ -n "$UPSTREAM_VERSION" ] && [ -n "$UPSTREAM_URL" ] || {
    echo "UPSTREAM_CYCLOP_VERSION is missing a required field" >&2
    exit 1
}
REFERENCE_CHECKOUT="$(mktemp -d)"
trap 'rm -rf "$REFERENCE_CHECKOUT"' EXIT

git clone --quiet "$UPSTREAM_URL.git" "$REFERENCE_CHECKOUT/source"
git -C "$REFERENCE_CHECKOUT/source" checkout --quiet "$COMMIT"
test "$(git -C "$REFERENCE_CHECKOUT/source" rev-parse HEAD)" = "$COMMIT"
bash "$REFERENCE_CHECKOUT/source/Scripts/bundle.sh" release

mkdir -p "$ROOT/build/reference"
rm -rf "$ROOT/build/reference/Cyclop.app"
cp -R "$REFERENCE_CHECKOUT/source/build/Cyclop.app" "$ROOT/build/reference/Cyclop.app"

echo "  ✓ built Cyclop $UPSTREAM_VERSION reference at $COMMIT"
