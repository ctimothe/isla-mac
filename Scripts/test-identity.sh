#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/app.noindex/Isla.app"
PLIST="$APP/Contents/Info.plist"

test -x "$APP/Contents/MacOS/Isla"
test -f "$APP/Contents/Resources/libislamedia.dylib"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' "$PLIST")" = "Isla"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")" = "com.ctimothe.isla"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$PLIST")" = "Isla"
test "$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$PLIST")" = "15.0"
# CFBundleVersion is the monotonic build number from Scripts/version, a whole
# number, and the short version is the marketing one. It used to repeat the
# marketing version, which gave an updater nothing it could compare.
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
case "$BUILD" in
    ''|*[!0-9]*) echo "CFBundleVersion '$BUILD' is not a whole number" >&2; exit 1 ;;
esac
test "$BUILD" = "$(sed -n 's/^BUILD=//p' "$ROOT/Scripts/version")"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")" = "$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version")"
