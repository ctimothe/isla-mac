#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMIT="7ab60c8198681ea6c895fa55458448efb6e4c36e"
REFERENCE_CHECKOUT="$(mktemp -d)"
trap 'rm -rf "$REFERENCE_CHECKOUT"' EXIT

git clone --quiet https://github.com/akalikbergenov/cyclop.git "$REFERENCE_CHECKOUT/source"
git -C "$REFERENCE_CHECKOUT/source" checkout --quiet "$COMMIT"
test "$(git -C "$REFERENCE_CHECKOUT/source" rev-parse HEAD)" = "$COMMIT"
bash "$REFERENCE_CHECKOUT/source/Scripts/bundle.sh" release

mkdir -p "$ROOT/build/reference"
rm -rf "$ROOT/build/reference/Cyclop.app"
cp -R "$REFERENCE_CHECKOUT/source/build/Cyclop.app" "$ROOT/build/reference/Cyclop.app"

echo "  ✓ built Cyclop 0.6.5 reference at $COMMIT"
