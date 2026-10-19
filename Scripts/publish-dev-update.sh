#!/bin/bash
# Publishes the committed checkout as a dev build to the local update feed, so
# the running Isla offers it on the island and installs it with its own Update
# Now. Run after a change is committed and green, instead of install.sh. Never
# a gate.
#
#   bash Scripts/publish-dev-update.sh             # build, sign and publish
#   bash Scripts/publish-dev-update.sh --dry-run   # say what would be published
#   bash Scripts/publish-dev-update.sh --enable    # also point Isla at the feed
#   bash Scripts/publish-dev-update.sh --replace   # publish over a build this
#                                                  # checkout does not contain
#
# The owner asked on 2026-10-19 that every change reach the running app through
# Isla's own update rather than a reinstall each time (plan
# docs/development/plans/2026-10-19-dev-update-channel.md). The feed is a folder
# the installed Isla reads exactly as a rehearsal reads its own
# (UpdateSource.localFeed): a release.json shaped like GitHub's releases/latest
# and file:// assets confined to the folder. What may be installed does not
# change: the image must carry the feed key's signature, and the staged app
# must be Isla, newer, a greater build and signed as the running copy is.
#
# The feed has a key pair of its own, not the release key: the private half in
# the login keychain as "Isla Dev Update Signing", the public half committed as
# Resources/update-dev-public-key.txt and put in every build as
# IslaDevUpdatePublicKey. A copy following the feed trusts that key and only
# that key (UpdateSignature.trustedKey), so a day of dev builds never reads the
# release key and a dev build's signature installs nowhere else. Losing it
# costs one install.sh after a new pair is made:
#
#   swift Scripts/update-signing.swift create-key --dev Resources/update-dev-public-key.txt
#
# The feed is $ISLA_DEV_FEED, or .dev-updates in the main checkout (git-ignored,
# 0700). Isla follows it once `defaults read com.ctimothe.isla updates.localFeed`
# names it, which --enable writes; Isla reads the setting at launch, so the
# first time it takes one relaunch. Leaving the channel:
#
#   defaults delete com.ctimothe.isla updates.localFeed
#
# then bundle.sh and install.sh, since a dev build's build number may be above
# the next public release's, which Update Now would refuse.
#
# Versions: VERSION from Scripts/version (three numbers) with a fourth part
# added. The fourth part is one past the greater of the installed app's and the
# feed's last release's fourth parts, each counted as 0 unless its first three
# numbers are VERSION's, so every dev build is newer than the last and older
# than the next real release (0.3.0.7 < 0.3.1). An installed app already past
# VERSION (0.3.1 against 0.3.0) is refused rather than offered an older build.
# The build is one past the greater of the installed and last-published builds.
#
# The feed folder is the script's own: made with a .isla-dev-feed marker, and
# a folder that already holds other files and no marker is refused, so
# ISLA_DEV_FEED naming ~/Downloads by mistake neither changes its permissions
# nor prunes an Isla image that happens to be there. Only four-part dev images
# are ever pruned.
#
# It never launches, quits or installs anything. Whatever happens, it removes
# the build from build/ and unregisters it, as rehearse-update.sh does: one Isla
# on the Mac, the one in /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLED="/Applications/Isla.app"
KEY_FILE="$ROOT/Resources/update-dev-public-key.txt"
KEY_SERVICE="Isla Dev Update Signing"
APP="$ROOT/build/app.noindex/Isla.app"
DOMAIN="com.ctimothe.isla"
SETTING="updates.localFeed"
KEEP_IMAGES=2
NOTES_LIMIT=10
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

fail() { echo "!!! $*" >&2; exit 1; }

DRY_RUN=0
ENABLE=0
REPLACE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --enable) ENABLE=1 ;;
        --replace) REPLACE=1 ;;
        -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) fail "unknown argument '$arg' (try --dry-run, --enable or --replace)" ;;
    esac
done

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

# The fourth part of $1 when its first three are $2, else 0.
dev_part() {
    case "$1" in
        "$2") echo 0 ;;
        "$2".*) local rest="${1#"$2".}"; case "$rest" in ''|*[!0-9]*) echo 0 ;; *) echo $((10#$rest)) ;; esac ;;
        *) echo 0 ;;
    esac
}

is_dotted() { case "$1" in ''|*[!0-9.]*|.*|*.|*..*) return 1 ;; *) return 0 ;; esac; }
is_whole() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# 1. What is being published: a committed tree, never work in progress.
cd "$ROOT"
[ -z "$(git status --porcelain --untracked-files=normal)" ] \
    || fail "the checkout has uncommitted changes; commit them (and run the tests) first"
COMMIT="$(git rev-parse HEAD)"
BASE="$(sed -n 's/^VERSION=//p' Scripts/version)"
is_dotted "$BASE" || fail "Scripts/version has no VERSION= line of dotted numbers"
[ "$(echo "$BASE" | tr -cd . | wc -c | tr -d ' ')" = 2 ] || fail "VERSION=$BASE is not three numbers; a dev build adds the fourth"

# 2. The feed.
COMMON="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
MAIN_CHECKOUT="$(dirname "$COMMON")"
FEED="${ISLA_DEV_FEED:-$MAIN_CHECKOUT/.dev-updates}"
case "$FEED" in /*) ;; *) fail "ISLA_DEV_FEED must be an absolute path, got '$FEED'" ;; esac
# Links resolved, as Isla resolves the setting: the release's file URLs must
# name the folder Isla confines them to, not a path that only leads there
# (/var is /private/var).
[ -d "$FEED" ] && FEED="$(cd "$FEED" && pwd -P)"
case "$FEED" in *[!A-Za-z0-9_./-]*) fail "the feed path has characters that do not belong in a file URL: $FEED" ;; esac

# 3. The feed's last release, if any: its version, build and commit.
LAST_VERSION=""
LAST_BUILD=0
LAST_COMMIT=""
if [ -f "$FEED/release.json" ]; then
    read -r LAST_VERSION LAST_BUILD LAST_COMMIT < <(/usr/bin/python3 -I - "$FEED/release.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        r = json.load(f)
    print(str(r.get("tag_name", "")).lstrip("v") or "-", int(r.get("isla_build", 0)), r.get("isla_commit") or "-")
except Exception:
    print("- 0 -")
PY
)
    [ "$LAST_VERSION" = "-" ] && LAST_VERSION=""
    [ "$LAST_COMMIT" = "-" ] && LAST_COMMIT=""
fi

# A checkout that does not contain the last published commit — another
# worktree's branch, or one cut before it — would replace the running app with
# code that lacks what the owner installed last, under a higher version, with
# nothing on the island to say so (Codex review, 2026-10-19). Refused unless
# --replace says that is the point.
if [ -n "$LAST_COMMIT" ] && ! git merge-base --is-ancestor "$LAST_COMMIT" HEAD 2>/dev/null; then
    LAST_WHERE="$(git name-rev --name-only --no-undefined "$LAST_COMMIT" 2>/dev/null || echo "a commit no branch here contains")"
    if [ "$REPLACE" = 1 ]; then
        echo "    replacing the last published build ($LAST_VERSION, ${LAST_COMMIT:0:7} on $LAST_WHERE), which this checkout does not contain"
    else
        fail "the last published build ($LAST_VERSION, ${LAST_COMMIT:0:7} on $LAST_WHERE) is not in this checkout, so installing this one would take its changes away. Merge it in first, or run again with --replace if that is the point"
    fi
fi

# 4. The installed app, which the new build must be newer than.
PLIST="$INSTALLED/Contents/Info.plist"
[ -f "$PLIST" ] || fail "Isla is not installed at $INSTALLED; bootstrap once with: bash Scripts/bundle.sh release && bash Scripts/install.sh"
MAKE_KEY="swift Scripts/update-signing.swift create-key --dev Resources/update-dev-public-key.txt"
[ -s "$KEY_FILE" ] || fail "$KEY_FILE is missing; make the feed's key pair with: $MAKE_KEY, commit it, then bootstrap with bundle.sh and install.sh"
security find-generic-password -s "$KEY_SERVICE" -a ed25519 >/dev/null 2>&1 \
    || fail "the login keychain has no \"$KEY_SERVICE\" key for $KEY_FILE; restore it, or make a new pair (remove the file, run: $MAKE_KEY), commit it and reinstall once"
WANT_KEY="$(tr -d '[:space:]' < "$KEY_FILE")"
HAVE_KEY="$(/usr/libexec/PlistBuddy -c 'Print :IslaDevUpdatePublicKey' "$PLIST" 2>/dev/null || true)"
[ "$HAVE_KEY" = "$WANT_KEY" ] || fail "the installed Isla has no matching IslaDevUpdatePublicKey, so it cannot accept a dev build; bootstrap with bundle.sh and install.sh"
HAVE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
HAVE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || true)"
is_dotted "$HAVE_VERSION" || fail "the installed Isla's version is '$HAVE_VERSION', not dotted numbers"
is_whole "$HAVE_BUILD" || fail "the installed Isla's build is '$HAVE_BUILD', not a whole number"

N_INSTALLED="$(dev_part "$HAVE_VERSION" "$BASE")"
N_LAST=0
[ -n "$LAST_VERSION" ] && N_LAST="$(dev_part "$LAST_VERSION" "$BASE")"
N=$(( (N_INSTALLED > N_LAST ? N_INSTALLED : N_LAST) + 1 ))
NEW_VERSION="$BASE.$N"
NEW_BUILD=$(( (10#$HAVE_BUILD > LAST_BUILD ? 10#$HAVE_BUILD : LAST_BUILD) + 1 ))
version_greater "$NEW_VERSION" "$HAVE_VERSION" \
    || fail "$NEW_VERSION is not newer than the installed $HAVE_VERSION (Scripts/version is behind the installed app), so Update Now would refuse it"

# 5. The notes: commit subjects since the last published commit, newest first,
# at most ten, conventional prefixes taken off. The island shows the first.
if [ -n "$LAST_COMMIT" ] && git merge-base --is-ancestor "$LAST_COMMIT" HEAD 2>/dev/null; then
    RANGE="$LAST_COMMIT..HEAD"
else
    RANGE="$(git merge-base HEAD main 2>/dev/null || echo HEAD~1)..HEAD"
fi
SUBJECTS="$(git log --no-merges --format=%s -n "$NOTES_LIMIT" "$RANGE" 2>/dev/null || true)"
[ -n "$SUBJECTS" ] || SUBJECTS="$(git log --format=%s -n 1 HEAD)"
NOTES="$(printf '%s\n' "$SUBJECTS" | awk '
    { sub(/^[a-z]+(\([^)]*\))?!?: +/, ""); if (length($0)) print "- " toupper(substr($0, 1, 1)) substr($0, 2) }
')"

echo "==> Isla $NEW_VERSION (build $NEW_BUILD) from $(git rev-parse --short HEAD) on $(git rev-parse --abbrev-ref HEAD)"
echo "    installed: $HAVE_VERSION (build $HAVE_BUILD)${LAST_VERSION:+, last published: $LAST_VERSION (build $LAST_BUILD)}"
echo "    feed: $FEED"
echo "    notes:"
printf '%s\n' "$NOTES" | sed 's/^/      /'

CURRENT_SETTING="$(defaults read "$DOMAIN" "$SETTING" 2>/dev/null || true)"
if [ "$DRY_RUN" = 1 ]; then
    [ "$CURRENT_SETTING" = "$FEED" ] || echo "    (Isla is not following this feed yet: --enable writes the setting)"
    echo "==> dry run: nothing built, nothing written"
    exit 0
fi

# 6. The folder: the script's own (the marker), the user's own, writable by
# nobody else, or Isla ignores it.
MARKER_NAME=".isla-dev-feed"
mkdir -p "$FEED"
FEED="$(cd "$FEED" && pwd -P)"
[ "$(stat -f %u "$FEED")" = "$(id -u)" ] || fail "$FEED is not owned by $(id -un), so Isla would ignore it"
if [ ! -e "$FEED/$MARKER_NAME" ]; then
    [ -z "$(ls -A "$FEED")" ] \
        || fail "$FEED already holds files and was not made by this script (no $MARKER_NAME); name a new or empty folder in ISLA_DEV_FEED"
    : > "$FEED/$MARKER_NAME"
fi
chmod 700 "$FEED"

[ ! -e "$ROOT/build/Isla-$NEW_VERSION.dmg" ] \
    || fail "$ROOT/build/Isla-$NEW_VERSION.dmg already exists and would be overwritten. Move it first."

STAGE="$(mktemp -d "$FEED/.publish-XXXXXX")"
cleanup() {
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    rm -rf "$APP" "$ROOT/build/Isla-$NEW_VERSION.dmg" "$STAGE"
}
trap cleanup EXIT

# 7. Built and packed as a release is, at the dev version.
ISLA_VERSION_OVERRIDE="$NEW_VERSION" ISLA_BUILD_OVERRIDE="$NEW_BUILD" bash "$ROOT/Scripts/bundle.sh" release
[ -d "$APP" ] || fail "the build left no app at $APP"
ISLA_VERSION_OVERRIDE="$NEW_VERSION" SKIP_BUNDLE=1 bash "$ROOT/Scripts/dmg.sh"
IMAGE="Isla-$NEW_VERSION.dmg"
mv "$ROOT/build/$IMAGE" "$STAGE/$IMAGE"
SIZE="$(stat -f %z "$STAGE/$IMAGE")"
[ "$SIZE" -le $(( 100 * 1024 * 1024 )) ] || fail "the image is $SIZE bytes; Update Now refuses an image over 100 MB"

# 8. Signed with the feed's key (macOS may ask once to allow the keychain read),
# and checked against the committed public key before anything reaches the feed.
swift "$ROOT/Scripts/update-signing.swift" sign --dev "$STAGE/$IMAGE" > "$STAGE/$IMAGE.sig"
swift "$ROOT/Scripts/update-signing.swift" verify "$KEY_FILE" "$STAGE/$IMAGE" "$STAGE/$IMAGE.sig" >/dev/null \
    || fail "the signature does not verify against $KEY_FILE"
SIG_SIZE="$(stat -f %z "$STAGE/$IMAGE.sig")"

# 9. The image and signature first, then the release renamed in last, so the
# watching Isla never reads a release whose files are not there yet.
mv "$STAGE/$IMAGE" "$FEED/$IMAGE"
mv "$STAGE/$IMAGE.sig" "$FEED/$IMAGE.sig"
/usr/bin/python3 -I "$ROOT/Scripts/dev-feed-release.py" \
    "$STAGE/release.json" "$FEED" "$NEW_VERSION" "$NEW_BUILD" "$COMMIT" "$SIZE" "$SIG_SIZE" "$NOTES"
mv -f "$STAGE/release.json" "$FEED/release.json"

# 10. Only the newest images stay: the one just published and the one before,
# which an install already under way may still be reading. Only dev images
# (four-part versions) are candidates.
# Never fatal: release.json is already live, and under pipefail a grep that
# matched nothing would report a publish that happened as a failure.
{ ls -t "$FEED"/Isla-*.dmg 2>/dev/null \
    | grep -E '/Isla-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.dmg$' \
    | tail -n +$((KEEP_IMAGES + 1)) | while read -r old; do
    rm -f "$old" "$old.sig"
done; } || true

echo "==> published Isla $NEW_VERSION (build $NEW_BUILD) to $FEED"

if [ "$ENABLE" = 1 ] && [ "$CURRENT_SETTING" != "$FEED" ]; then
    defaults write "$DOMAIN" "$SETTING" -string "$FEED"
    CURRENT_SETTING="$FEED"
    echo "==> Isla now follows $FEED. It reads this at launch: quit and reopen Isla once, and it offers this build on the island."
elif [ "$CURRENT_SETTING" = "$FEED" ]; then
    echo "    the running Isla offers it on the island within a second or two"
else
    echo "    Isla is not following this feed: run again with --enable, then reopen Isla once"
fi
