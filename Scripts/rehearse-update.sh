#!/bin/bash
# Makes everything an update rehearsal needs and prints the steps to run it by
# hand. Run by the owner, never a gate, never by an agent.
#
#   bash Scripts/rehearse-update.sh              # the installed version's next patch, build + 1
#   bash Scripts/rehearse-update.sh 0.3.5 12     # a chosen version and build
#
# Update Now has only ever replaced an app in a test folder. Two things are not
# proven until it replaces the launched one in /Applications: that macOS App
# Management lets an app without a Developer ID rewrite its own bundle there,
# and that the relaunch (a shell waiting for the old process, then /usr/bin/open)
# brings it back. A real GitHub release cannot be used for this, so this builds a
# later version of Isla, packs it with Scripts/dmg.sh (the layout of a release
# image: HFS+, the app and an Applications link), signs it with the update key,
# and writes a `release.json` shaped like GitHub's `releases/latest` into a
# folder. The installed Isla, started with DI_UPDATE_REHEARSAL=<that folder>,
# takes its release from the folder instead of from GitHub; everything after the
# download is the code a real update runs.
#
# The rehearsal version is "newer" than the INSTALLED app, whatever
# Scripts/version says: that is what Update Now compares against.
#
# It never launches, quits or installs anything. It does build (Scripts/bundle.sh
# with the rehearsal-only version override). Whatever happens, even on a failure,
# it removes the fake-version build from build/ and unregisters it: a later
# install.sh must never install a build called 0.3.1 that is not 0.3.1, which
# would make the real 0.3.1 read as not newer. So afterwards build/ has no app,
# and the way back is bundle.sh and install.sh, below.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLED="/Applications/Isla.app"
KEY_FILE="$ROOT/Resources/update-public-key.txt"
APP="$ROOT/build/app.noindex/Isla.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

fail() { echo "!!! $*" >&2; exit 1; }

# Dotted numbers compared as numbers, each part in base 10 so "08" is eight.
version_greater() {
    local IFS=.
    local -a a=($1) b=($2)
    local i x y n=${#a[@]}
    [ ${#b[@]} -gt "$n" ] && n=${#b[@]}
    for ((i = 0; i < n; i++)); do
        x=$((10#${a[i]:-0})); y=$((10#${b[i]:-0}))
        [ "$x" -gt "$y" ] && return 0
        [ "$x" -lt "$y" ] && return 1
    done
    return 1
}

# 1. The installed app can only accept what the update key signs.
security find-generic-password -s "Isla Update Signing" -a ed25519 >/dev/null 2>&1 \
    || fail "the update signing key is not in the login keychain; run: bash Scripts/make-update-key.sh"
[ -s "$KEY_FILE" ] || fail "$KEY_FILE is missing; run: bash Scripts/make-update-key.sh"
PLIST="$INSTALLED/Contents/Info.plist"
[ -f "$PLIST" ] || fail "Isla is not installed at $INSTALLED; run: bash Scripts/bundle.sh release && bash Scripts/install.sh"
WANT_KEY="$(tr -d '[:space:]' < "$KEY_FILE")"
HAVE_KEY="$(/usr/libexec/PlistBuddy -c 'Print :IslaUpdatePublicKey' "$PLIST" 2>/dev/null || true)"
[ "$HAVE_KEY" = "$WANT_KEY" ] || fail "the installed Isla has no matching IslaUpdatePublicKey, so it cannot accept the rehearsal. Rebuild and install first: bash Scripts/bundle.sh release && bash Scripts/install.sh"

# 2. The version: the installed app's next patch and build + 1, unless given.
HAVE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
HAVE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || true)"
case "$HAVE_VERSION" in ''|*[!0-9.]*|.*|*.|*..*) fail "the installed Isla's version is '$HAVE_VERSION', not dotted numbers" ;; esac
case "$HAVE_BUILD" in ''|*[!0-9]*) fail "the installed Isla's build is '$HAVE_BUILD', not a whole number" ;; esac
if [ -n "${1:-}" ]; then
    NEW_VERSION="$1"
else
    NEW_VERSION="${HAVE_VERSION%.*}.$(( 10#${HAVE_VERSION##*.} + 1 ))"
    # A version of one number has no "%.*" to cut: it is its own last part.
    [ "$HAVE_VERSION" = "${HAVE_VERSION%.*}" ] && NEW_VERSION="$(( 10#$HAVE_VERSION + 1 ))"
fi
NEW_BUILD="${2:-$(( 10#$HAVE_BUILD + 1 ))}"
case "$NEW_VERSION" in ''|*[!0-9.]*|.*|*.|*..*) fail "version must be dotted numbers, got '$NEW_VERSION'" ;; esac
case "$NEW_BUILD" in ''|*[!0-9]*) fail "build must be a whole number, got '$NEW_BUILD'" ;; esac
version_greater "$NEW_VERSION" "$HAVE_VERSION" || fail "$NEW_VERSION is not newer than the installed $HAVE_VERSION, so Update Now would refuse it"
[ $(( 10#$NEW_BUILD )) -gt $(( 10#$HAVE_BUILD )) ] || fail "build $NEW_BUILD is not greater than the installed $HAVE_BUILD, so Update Now would refuse it"

# The folder the rehearsal lives in: fresh, and a plain path (it goes into file URLs).
FOLDER="${TMPDIR:-/tmp}"
FOLDER="$(cd "$FOLDER" && pwd -P)/isla-rehearsal-$NEW_VERSION"
case "$FOLDER" in *[!A-Za-z0-9_./-]*) fail "the rehearsal folder path has characters that do not belong in a file URL: $FOLDER" ;; esac
[ ! -e "$FOLDER" ] || fail "$FOLDER already exists; remove it or pick another version"

# From here a failure leaves nothing behind: the fake-version build and its image
# are removed and unregistered, and the half-made folder goes with them. Only a
# finished run keeps its folder.
FINISHED=0
cleanup() {
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    rm -rf "$APP" "$ROOT/build/Isla-$NEW_VERSION.dmg"
    [ "$FINISHED" = 1 ] || rm -rf "$FOLDER"
}
trap cleanup EXIT
mkdir -p "$FOLDER"

# 3. Build it as the later version, and pack it as a release is packed.
echo "==> building Isla $NEW_VERSION (build $NEW_BUILD) for the rehearsal"
ISLA_VERSION_OVERRIDE="$NEW_VERSION" ISLA_BUILD_OVERRIDE="$NEW_BUILD" bash "$ROOT/Scripts/bundle.sh" release
[ -d "$APP" ] || fail "the build left no app at $APP"
ISLA_VERSION_OVERRIDE="$NEW_VERSION" SKIP_BUNDLE=1 bash "$ROOT/Scripts/dmg.sh"
DMG="$FOLDER/Isla-$NEW_VERSION.dmg"
mv "$ROOT/build/Isla-$NEW_VERSION.dmg" "$DMG"
SIZE="$(stat -f %z "$DMG")"
[ "$SIZE" -le $(( 100 * 1024 * 1024 )) ] || fail "the image is $SIZE bytes; Update Now refuses an image over 100 MB"

# 4. Signed with the update key, and checked against the committed public key.
swift "$ROOT/Scripts/update-signing.swift" sign "$DMG" > "$DMG.sig"
swift "$ROOT/Scripts/update-signing.swift" verify "$KEY_FILE" "$DMG" "$DMG.sig" >/dev/null \
    || fail "the signature does not verify against $KEY_FILE"
SIG_SIZE="$(stat -f %z "$DMG.sig")"

# 5. The release, shaped like GitHub's releases/latest.
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
FINISHED=1

# 6. The steps. Nothing below is run for you.
cat <<STEPS

Rehearsal ready: Isla $NEW_VERSION (build $NEW_BUILD), in $FOLDER
(the installed Isla is $HAVE_VERSION, build $HAVE_BUILD)

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

To go back to the real build (this script removed the rehearsal build from
build/, so it has to be built again):

       bash Scripts/bundle.sh release && bash Scripts/install.sh

and remove the rehearsal folder when you are done: rm -rf $FOLDER
STEPS
