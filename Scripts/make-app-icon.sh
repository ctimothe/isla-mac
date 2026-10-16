#!/bin/bash
# Compiles the app icon's one source, Resources/AppIcon.icon (an Apple Icon
# Composer package), into the two files the bundle carries:
#
#   Resources/Assets.car    the layered icon, compiled by actool. macOS 26
#                           and later draw it themselves, so the glass, the
#                           light/dark/clear appearances and the tinted one
#                           all come from the system rather than a baked image.
#   Resources/AppIcon.icns  the flattened fallback, every size from 16 to
#                           1024 px, rendered by Icon Composer's own ictool.
#
# actool writes an .icns too, but only at 16, 32, 128 and 256 px: an Xcode
# build leans on the catalog for everything larger. Anything that reads the
# .icns directly would scale 256 px up to fill Get Info or Quick Look on
# macOS 15, so the fallback is rendered here at every size instead.
#
# Both are committed, like the .icns before them: bundle.sh copies them
# verbatim, so a build needs neither Xcode nor network, and release.sh's
# clean-tree check can never be dirtied by a mid-build write. Run this by hand
# only when Resources/AppIcon.icon changes, and commit all three together:
# actool stamps fresh identifiers into Assets.car on every run (checked on
# 2026-10-16: two runs over the same source gave two different files, while
# the .icns came out byte-identical), so a run with no source change still
# shows a changed binary in git.
#
# Needs full Xcode 26 or later. Command Line Tools have neither actool nor
# Icon Composer, and older actool versions cannot read an .icon package.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Resources/AppIcon.icon"
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

fail() { echo "make-app-icon: $*" >&2; exit 1; }

test -f "$SOURCE/icon.json" || fail "missing icon source: $SOURCE"
test -x "$ICTOOL" || fail "Icon Composer's ictool not found at $ICTOOL (needs full Xcode 26 or later)"

# The app-icon name must equal the package's name (AppIcon.icon -> AppIcon):
# that is what bundle.sh's CFBundleIconName and CFBundleIconFile say. The
# deployment target matches LSMinimumSystemVersion, so actool also writes the
# flattened renditions macOS 15 reads from the catalog.
xcrun actool "$SOURCE" \
    --compile "$OUT" \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 15.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$OUT/partial.plist" \
    --output-format human-readable-text > "$OUT/actool.log" 2>&1 \
    || { cat "$OUT/actool.log" >&2; fail "actool failed"; }

test -f "$OUT/Assets.car" || { cat "$OUT/actool.log" >&2; fail "actool wrote no Assets.car"; }
# The names bundle.sh hard-codes into Info.plist must be the ones actool
# chose; a mismatch shows a blank icon rather than failing anywhere else.
for key in CFBundleIconName CFBundleIconFile; do
    value="$(/usr/libexec/PlistBuddy -c "Print $key" "$OUT/partial.plist" 2>/dev/null || true)"
    test "$value" = "AppIcon" || fail "actool set $key to '$value', but bundle.sh says AppIcon"
done

# Default rendition, the light system appearance a flattened icon has to pick.
# Design generation 26 is the oldest ictool offers, the closest to what a
# macOS 15 Finder expects beside its own icons.
ICONSET="$OUT/AppIcon.iconset"
mkdir "$ICONSET"
render() { # <pixels> <iconset file name>
    "$ICTOOL" "$SOURCE" --export-image --output-file "$ICONSET/$2" \
        --platform macOS --rendition Default --width "$1" --height "$1" --scale 1 \
        --design-generation 26 > "$OUT/ictool.log" 2>&1 \
        || { cat "$OUT/ictool.log" >&2; fail "ictool failed at $1 px"; }
    test -f "$ICONSET/$2" || fail "ictool wrote no $2"
}
render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png
iconutil -c icns "$ICONSET" -o "$OUT/AppIcon.icns" || fail "iconutil failed"

cp "$OUT/Assets.car" "$ROOT/Resources/Assets.car"
cp "$OUT/AppIcon.icns" "$ROOT/Resources/AppIcon.icns"
echo "==> Resources/Assets.car and Resources/AppIcon.icns rebuilt with $(xcodebuild -version | head -1)"
