#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Dynamic Island.app"
PLIST="$APP/Contents/Info.plist"

test -x "$APP/Contents/MacOS/DynamicIsland"
test -f "$APP/Contents/Resources/libdynamicislandmedia.dylib"
test -f "$APP/Contents/Resources/AppIcon.icns"
test -f "$APP/Contents/Resources/en.lproj/Localizable.strings"
test -f "$APP/Contents/Resources/ru.lproj/Localizable.strings"
test -f "$APP/Contents/Resources/Licenses/LICENSE"
test -f "$APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
grep -q 'Copyright (c) 2026 akalikbergenov' \
    "$APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")" = "dev.dynamicisland.app"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$PLIST")" = "DynamicIsland"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' "$PLIST")" = "Dynamic Island"
test "$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$PLIST")" = "15.0"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" 2>&1 | \
    grep -q 'com.apple.security.personal-information.calendars'

echo "  ✓ Dynamic Island bundle contract is complete"
