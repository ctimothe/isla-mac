#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Isla.app"
PLIST="$APP/Contents/Info.plist"

test -x "$APP/Contents/MacOS/Isla"
test -f "$APP/Contents/Resources/libislamedia.dylib"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' "$PLIST")" = "Isla"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")" = "com.ctimothe.isla"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$PLIST")" = "Isla"
test "$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$PLIST")" = "15.0"
