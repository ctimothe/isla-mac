#!/bin/bash
# Decides whether the checked-out commit is a release, and what it is called.
# The release workflow runs it on every merge to main (.github/workflows/release.yml,
# plan 2026-10-20-updates-for-everyone); a person can run it to see the answer.
#
#   bash Scripts/next-release.sh           # prints release=, version=, build=, reason=
#   bash Scripts/next-release.sh --write   # also rewrites Scripts/version and writes
#                                          # docs/releases/<version>.md when it is missing
#
# Why it exists: the owner asked on 2026-10-20 that whatever is merged to main
# reaches every user's island. Nobody should have to remember to bump
# Scripts/version or write notes for that to happen, and nobody can be trusted
# to always remember, so this works out both from the tags.
#
# The rules:
#   - Nothing to release when no file the app is built from changed since the
#     newest tag (APP_PATHS). A docs-only merge is not a release.
#   - VERSION is the next patch after the newest tag, unless Scripts/version
#     already names a higher one that no tag has yet. That is how a person
#     picks 0.4.0: set VERSION=0.4.0 in a pull request and the next release
#     takes it.
#   - BUILD only goes up: the greater of Scripts/version's BUILD and every tag's
#     build plus one, read the way Scripts/release.sh reads them.
#   - Notes: docs/releases/<version>.md if a person wrote one. Otherwise they
#     are made from the feat/fix/perf subjects since the newest tag. "What's
#     new" comes first because the island's offer reads its one line from the
#     first prose line (UpdateOffer.summary). The made file ends with a marker,
#     so a retry after a failed release writes it again rather than shipping
#     notes that miss the commits merged since.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WRITE=0
[ "${1:-}" = "--write" ] && WRITE=1

APP_PATHS=(Sources Resources Package.swift Package.resolved Scripts/bundle.sh Scripts/dmg.sh)
MARKER="<!-- written by Scripts/next-release.sh; replace it with your own notes if you like -->"

fail() { echo "next-release: $*" >&2; exit 1; }
is_three() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
# Whether $1 is a later version than $2, both three dotted numbers.
greater() {
    local -a a b
    IFS=. read -ra a <<<"$1"
    IFS=. read -ra b <<<"$2"
    for i in 0 1 2; do
        [ "$((10#${a[$i]}))" -gt "$((10#${b[$i]}))" ] && return 0
        [ "$((10#${a[$i]}))" -lt "$((10#${b[$i]}))" ] && return 1
    done
    return 1
}

FILE_VERSION="$(sed -n 's/^VERSION=//p' Scripts/version)"
FILE_BUILD="$(sed -n 's/^BUILD=//p' Scripts/version)"
is_three "$FILE_VERSION" || fail "Scripts/version's VERSION=$FILE_VERSION is not three dotted numbers"
[[ "$FILE_BUILD" =~ ^[0-9]+$ ]] || fail "Scripts/version's BUILD=$FILE_BUILD is not a whole number"

# The newest release tag by version, and the greatest build any tag carries.
# A tag from before BUILD= existed counts as its place in the list, as in
# Scripts/release.sh.
LAST_TAG=""
MAX_BUILD=0
ORDINAL=0
for TAG in $(git tag -l 'v[0-9]*' --sort=v:refname); do
    is_three "${TAG#v}" || continue
    ORDINAL=$((ORDINAL + 1))
    LAST_TAG="$TAG"
    TAG_BUILD="$(git show "$TAG:Scripts/version" 2>/dev/null | sed -n 's/^BUILD=//p')"
    TAG_BUILD="${TAG_BUILD:-$ORDINAL}"
    [ "$TAG_BUILD" -gt "$MAX_BUILD" ] && MAX_BUILD="$TAG_BUILD"
done

say() { printf '%s\n' "$@"; }

if [ -n "$LAST_TAG" ] && git diff --quiet "$LAST_TAG" HEAD -- "${APP_PATHS[@]}"; then
    say "release=no" "reason=nothing the app is built from changed since $LAST_TAG"
    exit 0
fi

LAST_VERSION="${LAST_TAG#v}"
if [ -z "$LAST_TAG" ] || greater "$FILE_VERSION" "$LAST_VERSION"; then
    VERSION="$FILE_VERSION"
else
    IFS=. read -r MAJOR MINOR PATCH <<<"$LAST_VERSION"
    VERSION="$MAJOR.$MINOR.$((10#$PATCH + 1))"
fi
BUILD=$(( FILE_BUILD > MAX_BUILD ? FILE_BUILD : MAX_BUILD + 1 ))

say "release=yes" "version=$VERSION" "build=$BUILD" "reason=app changed since ${LAST_TAG:-the start}"
[ "$WRITE" = 1 ] || exit 0

sed -i '' -e "s/^VERSION=.*/VERSION=$VERSION/" -e "s/^BUILD=.*/BUILD=$BUILD/" Scripts/version 2>/dev/null \
    || sed -i -e "s/^VERSION=.*/VERSION=$VERSION/" -e "s/^BUILD=.*/BUILD=$BUILD/" Scripts/version

NOTES="docs/releases/$VERSION.md"
if [ -s "$NOTES" ] && ! grep -qF "$MARKER" "$NOTES"; then
    exit 0   # a person's notes
fi
mkdir -p docs/releases
RANGE="${LAST_TAG:+$LAST_TAG..}HEAD"
CHANGES="$(git log --no-merges --format=%s "$RANGE" -- "${APP_PATHS[@]}" \
    | sed -nE 's/^(feat|fix|perf)(\([^)]*\))?!?: +//p' \
    | awk 'NF && !seen[$0]++ { print "- " toupper(substr($0, 1, 1)) substr($0, 2) }')"
[ -n "$CHANGES" ] || CHANGES="- Smaller fixes and improvements."

{
    say "## What's new" "" "$CHANGES" "" "## Install" ""
    say "Already running a release after 0.3.0? Isla offers this one on the island by itself: press **Install**." ""
    say "New to Isla, or on 0.3.0 or earlier:" ""
    say "1. Download \`Isla-$VERSION.dmg\` below, open it and drag **Isla** to **Applications**."
    if [ "${ISLA_ADHOC:-0}" = 1 ]; then
        say "2. This build is not notarized yet, so remove the download quarantine once:" ""
        say "   \`\`\`bash" "   xattr -dr com.apple.quarantine /Applications/Isla.app" "   \`\`\`" ""
        say "3. Open Isla from Applications."
    else
        say "2. Open Isla from Applications."
    fi
    # Last, not first: the island's one line is the notes' first prose line,
    # and an HTML comment there would be it.
    say "" "$MARKER"
} > "$NOTES"
