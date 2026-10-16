#!/bin/bash
# Makes everything an update rehearsal needs and prints the steps to run it by
# hand. Run by the owner, never a gate, never by an agent.
#
#   bash Scripts/rehearse-update.sh              # next patch version, build + 1
#   bash Scripts/rehearse-update.sh 0.3.5 12     # a chosen version and build
#
# Update Now has only ever replaced an app in a test folder. Two things are not
# proven until it replaces the launched one in /Applications: that macOS App
# Management lets an app without a Developer ID rewrite its own bundle there,
# and that the relaunch (a shell waiting for the old process, then /usr/bin/open)
# brings it back. A real GitHub release cannot be used for this, so this builds a
# later version of Isla, packs and signs it exactly as Scripts/release.sh does,
# and writes a `release.json` shaped like GitHub's `releases/latest` into a
# folder. The installed Isla, started with DI_UPDATE_REHEARSAL=<that folder>,
# takes its release from the folder instead of from GitHub; everything after the
# download is the code a real update runs.
#
# It never launches, quits or installs anything. It does build (Scripts/bundle.sh,
# with the rehearsal-only version override), and it removes the rehearsal build
# from build/app.noindex and unregisters it afterwards, so no second Isla with the
# rehearsal version stays known to the system.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLED="/Applications/Isla.app"
KEY_FILE="$ROOT/Resources/update-public-key.txt"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

fail() { echo "!!! $*" >&2; exit 1; }

# 1. The installed app can only accept what the update key signs.
security find-generic-password -s "Isla Update Signing" -a ed25519 >/dev/null 2>&1 \
    || fail "the update signing key is not in the login keychain; run: bash Scripts/make-update-key.sh"
[ -s "$KEY_FILE" ] || fail "$KEY_FILE is missing; run: bash Scripts/make-update-key.sh"
[ -f "$INSTALLED/Contents/Info.plist" ] || fail "Isla is not installed at $INSTALLED; run: bash Scripts/bundle.sh release && bash Scripts/install.sh"
WANT_KEY="$(tr -d '[:space:]' < "$KEY_FILE")"
HAVE_KEY="$(/usr/libexec/PlistBuddy -c 'Print :IslaUpdatePublicKey' "$INSTALLED/Contents/Info.plist" 2>/dev/null || true)"
[ "$HAVE_KEY" = "$WANT_KEY" ] || fail "the installed Isla has no matching IslaUpdatePublicKey, so it cannot accept the rehearsal. Rebuild and install first: bash Scripts/bundle.sh release && bash Scripts/install.sh"

# 2. The version: the next patch of Scripts/version, build + 1, unless given.
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version")"
BUILD="$(sed -n 's/^BUILD=//p' "$ROOT/Scripts/version")"
[ -n "$VERSION" ] || fail "Scripts/version has no VERSION="
case "$BUILD" in ''|*[!0-9]*) fail "Scripts/version needs a whole-number BUILD=" ;; esac
if [ -n "${1:-}" ]; then
    NEW_VERSION="$1"
else
    NEW_VERSION="${VERSION%.*}.$(( ${VERSION##*.} + 1 ))"
fi
NEW_BUILD="${2:-$(( BUILD + 1 ))}"
case "$NEW_VERSION" in ''|*[!0-9.]*|.*|*.|*..*) fail "version must be dotted numbers, got '$NEW_VERSION'" ;; esac
case "$NEW_BUILD" in ''|*[!0-9]*) fail "build must be a whole number, got '$NEW_BUILD'" ;; esac
[ "$NEW_BUILD" -gt "$BUILD" ] || fail "the rehearsal build ($NEW_BUILD) must be greater than $BUILD, or the update is refused as not newer"

# The folder the rehearsal lives in: fresh, and a plain path (it goes into file URLs).
FOLDER="${TMPDIR:-/tmp}"
FOLDER="$(cd "$FOLDER" && pwd -P)/isla-rehearsal-$NEW_VERSION"
case "$FOLDER" in *[!A-Za-z0-9_./-]*) fail "the rehearsal folder path has characters that do not belong in a file URL: $FOLDER" ;; esac
[ ! -e "$FOLDER" ] || fail "$FOLDER already exists; remove it or pick another version"
mkdir -p "$FOLDER/pack"

# 3. Build it as the later version, copy it out and leave no second Isla behind.
echo "==> building Isla $NEW_VERSION (build $NEW_BUILD) for the rehearsal"
ISLA_VERSION_OVERRIDE="$NEW_VERSION" ISLA_BUILD_OVERRIDE="$NEW_BUILD" bash "$ROOT/Scripts/bundle.sh" release
APP="$ROOT/build/app.noindex/Isla.app"
[ -d "$APP" ] || fail "the build left no app at $APP"
ditto "$APP" "$FOLDER/pack/Isla.app"
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
rm -rf "$APP"

# 4. The disk image.
DMG="$FOLDER/Isla-$NEW_VERSION.dmg"
hdiutil create -volname "Isla $NEW_VERSION" -srcfolder "$FOLDER/pack" -format UDZO "$DMG" >/dev/null
rm -rf "$FOLDER/pack"
SIZE="$(stat -f %z "$DMG")"
[ "$SIZE" -le $(( 100 * 1024 * 1024 )) ] || fail "the image is $SIZE bytes; Update Now refuses an image over 100 MB"

# 5. Signed with the update key, and checked against the committed public key.
swift "$ROOT/Scripts/update-signing.swift" sign "$DMG" > "$DMG.sig"
swift "$ROOT/Scripts/update-signing.swift" verify "$KEY_FILE" "$DMG" "$DMG.sig" >/dev/null \
    || fail "the signature does not verify against $KEY_FILE"
SIG_SIZE="$(stat -f %z "$DMG.sig")"

# 6. The release, shaped like GitHub's releases/latest.
cat > "$FOLDER/release.json" <<JSON
{
  "tag_name": "v$NEW_VERSION",
  "html_url": "https://github.com/ctimothe/isla-mac/releases/tag/v$NEW_VERSION",
  "draft": false,
  "prerelease": false,
  "body": "Rehearsal build made by Scripts/rehearse-update.sh.",
  "assets": [
    {"name": "Isla-$NEW_VERSION.dmg", "size": $SIZE, "browser_download_url": "file://$FOLDER/Isla-$NEW_VERSION.dmg"},
    {"name": "Isla-$NEW_VERSION.dmg.sig", "size": $SIG_SIZE, "browser_download_url": "file://$FOLDER/Isla-$NEW_VERSION.dmg.sig"}
  ]
}
JSON

# 7. The steps. Nothing below is run for you.
cat <<STEPS

Rehearsal ready: Isla $NEW_VERSION (build $NEW_BUILD), in $FOLDER

  1. Quit Isla: Settings > Quit Isla.
  2. Start the installed Isla in rehearsal mode:

       open --env DI_UPDATE_REHEARSAL=$FOLDER $INSTALLED

  3. Settings > About > Check for Updates, then Update Now.

What to look for:
  - the card shows "Rehearsal: update from a local folder", then the progress
    bar, Verifying..., Installing..., Restarting Isla...
  - Isla comes back by itself, and Settings > About says Version $NEW_VERSION
  - whether macOS showed any "Isla was prevented from modifying apps" message or
    an App Management prompt (write down what it said)
  - Volume and Brightness still works, without granting Accessibility again

Afterwards, both of these must print nothing:

       ls -a /Applications | grep Isla-update
       hdiutil info | grep -i isla

To go back to the real build:

       bash Scripts/install.sh

and remove the rehearsal folder when you are done: rm -rf $FOLDER
STEPS
