#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$ROOT/UPSTREAM_CYCLOP_VERSION"
NOTICE="$ROOT/THIRD_PARTY_NOTICES.md"

grep -qx 'UPSTREAM_VERSION=0.6.5' "$PIN"
grep -qx 'UPSTREAM_COMMIT=7ab60c8198681ea6c895fa55458448efb6e4c36e' "$PIN"
grep -qx 'UPSTREAM_URL=https://github.com/akalikbergenov/cyclop' "$PIN"
grep -q 'MIT License' "$NOTICE"
grep -q 'Copyright (c) 2026 akalikbergenov' "$NOTICE"
# The glyphs ship Hugeicons' drawings and islandcn's recipes; both licences
# ask for their notice to travel with the copies.
grep -q 'Copyright (c) 2025 Hugeicons' "$NOTICE"
grep -q 'Copyright (c) 2026 Leo' "$NOTICE"
test ! -e "$ROOT/docs/panel.png"
