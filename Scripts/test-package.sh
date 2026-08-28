#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Isla.app"
PLIST="$APP/Contents/Info.plist"

test -x "$APP/Contents/MacOS/Isla"
test -f "$APP/Contents/Resources/libislamedia.dylib"
test -f "$APP/Contents/Resources/AppIcon.icns"
test -f "$APP/Contents/Resources/en.lproj/Localizable.strings"
test -f "$APP/Contents/Resources/ru.lproj/Localizable.strings"
test -f "$APP/Contents/Resources/Licenses/LICENSE"
test -f "$APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
grep -q 'Copyright (c) 2026 akalikbergenov' \
    "$APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")" = "com.ctimothe.isla"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$PLIST")" = "Isla"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' "$PLIST")" = "Isla"
test "$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$PLIST")" = "15.0"
codesign --verify --deep --strict "$APP"
# The calendar entitlement must stay gone: Calendar was removed from the
# product, and a binary that still claims the permission asks users for
# something it cannot use.
#
# Written out rather than as `! codesign … | grep -q`: bash's `set -e`
# deliberately ignores a command whose status is inverted with `!`, so that
# form could never fail the script — the one regression this check exists to
# catch passed it, and so did codesign erroring out entirely.
ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null)" || {
    echo "cannot read entitlements from $APP" >&2
    exit 1
}
if grep -q 'com.apple.security.personal-information.calendars' <<<"$ENTITLEMENTS"; then
    echo "calendar entitlement is back in the bundle" >&2
    exit 1
fi
# And the one entitlement that must be present. The app is signed with the
# hardened runtime, which denies in-process Apple Events without it — so losing
# this key silently kills the scripting fallback in every signed build, with
# nothing but a -1743 in the log to say so.
if ! grep -q 'com.apple.security.automation.apple-events' <<<"$ENTITLEMENTS"; then
    echo "apple-events entitlement is missing; the scripting fallback cannot work" >&2
    exit 1
fi

echo "  ✓ Isla bundle contract is complete"
