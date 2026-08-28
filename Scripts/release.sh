#!/bin/bash
# Explicit publishing path: verify, Developer ID sign, notarize, tag, then upload.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" || true)"
[ -n "$VERSION" ] || { echo "!!! Scripts/version has no VERSION= line" >&2; exit 1; }
TAG="v$VERSION"
DMG="$ROOT/build/Isla-$VERSION.dmg"
NOTES="$ROOT/docs/releases/$VERSION.md"

cd "$ROOT"

fail() { echo "!!! $1" >&2; exit 1; }
require_env() { [ -n "${!1:-}" ] || fail "$1 is required"; }

# A release points at a commit, never at an uncommitted local artifact.
[ -z "$(git status --porcelain)" ] || fail "working tree is not clean"
[ -s "$NOTES" ] || fail "release notes are required at docs/releases/$VERSION.md"

command -v gh >/dev/null || fail "GitHub CLI is required: brew install gh"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated: gh auth login"
command -v xcrun >/dev/null || fail "Xcode command-line tools are required"

require_env DEVELOPER_ID_APPLICATION
require_env APPLE_ID
require_env APPLE_TEAM_ID
require_env APPLE_APP_SPECIFIC_PASSWORD
security find-identity -v -p codesigning | grep -F "$DEVELOPER_ID_APPLICATION" >/dev/null || \
    fail "Developer ID Application identity is not installed in the keychain"

git fetch --quiet origin
# The upstream has to exist before "no unpushed commits" means anything. Without
# one, `git rev-list @{u}..HEAD` errors, its output is empty, and the check
# passed vacuously — on exactly the fresh release branch it is meant to catch,
# tagging a commit that lived on no remote branch at all.
git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || \
    fail "branch has no upstream; push it first so the tag names a commit on the remote"
[ -z "$(git rev-list '@{u}..HEAD')" ] || \
    fail "unpushed commits would make the tag unavailable on GitHub"
if git rev-parse "$TAG" >/dev/null 2>&1; then
    fail "tag $TAG already exists; increment Scripts/version"
fi

echo "==> local release gates"
swift test
bash Scripts/test-provenance.sh
bash Scripts/test-branding.sh
bash Scripts/test-localizations.sh
bash Scripts/bundle.sh release
# After the bundle, not before it: these three read the built app.
bash Scripts/test-identity.sh
bash Scripts/test-helper.sh
bash Scripts/test-package.sh
# Both of these were documented as gates and run by nothing: the orphan-helper
# regression test-lifecycle exists to catch could ship in a release that had
# just run every scripted gate green.
bash Scripts/test-lifecycle.sh
APP="$ROOT/build/Isla.app"
[ -d "$APP" ] || fail "bundle was not built: $APP"

echo "==> notarize the app"
# The app is notarized and stapled *before* it goes into the image. Stapling
# only the DMG left the copy the user drags to /Applications with no ticket of
# its own, so its first launch had to reach Apple — and failed offline or behind
# a firewall.
APP_ZIP="$ROOT/build/Isla-$VERSION-app.zip"
rm -f "$APP_ZIP"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$APP_ZIP"

# Packaged only now, around the stapled app, and told not to rebuild it:
# dmg.sh used to run bundle.sh again from scratch, so the disk image carried a
# second build that none of the gates above had ever seen.
echo "==> package the stapled app"
SKIP_BUNDLE=1 bash Scripts/dmg.sh
[ -f "$DMG" ] || fail "disk image was not built: $DMG"

echo "==> sign and notarize $DMG"
codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG"
xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> tag $TAG"
# Tagged here rather than before notarization. The tag used to be pushed first,
# with minutes of notarization and an asset upload still ahead of it, so any
# failure in between stranded a tag on the remote — and the rerun then died on
# "tag already exists; increment Scripts/version", advice that would ship a
# version bump for a release that never happened.
git tag -a "$TAG" -m "Isla $VERSION"
git push --quiet origin "$TAG"

# If anything fails from here on, the tag goes back where it was rather than
# blocking every retry. Wired to a trap rather than to the one call site that
# used to have it: every step between the push and the release — resolving the
# repo, hashing the image, generating notes — can fail transiently, and each
# one used to strand a tag on the remote with no way back but a manual delete.
published=0
rollback_tag() {
    [ "$published" = "1" ] && return
    echo "!!! publishing failed — removing tag $TAG" >&2
    git push --quiet --delete origin "$TAG" 2>/dev/null || true
    git tag -d "$TAG" >/dev/null 2>&1 || true
}
trap 'rollback_tag' ERR

echo "==> GitHub release"
REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
# Line 1, not line 2. This read `sed -n 2p` back when the tag was created before
# this point and therefore occupied line 1 itself; with tagging moved after
# notarization, `$TAG` is now on line 1 and line 2 is the release *before* the
# previous one — so generated notes spanned two releases.
# `|| true` because grep exits 1 when there is nothing to filter out — the very
# first release of a repository — and under `pipefail` that killed the script
# after the tag had already been pushed and before the rollback was reachable.
PREVIOUS="$(git tag --sort=-v:refname | grep -Fxv "$TAG" | sed -n 1p || true)"
GENERATE_ARGS=(-f "tag_name=$TAG")
if [ -n "$PREVIOUS" ]; then
    GENERATE_ARGS+=(-f "previous_tag_name=$PREVIOUS")
fi
GENERATED="$(gh api "repos/$REPO/releases/generate-notes" \
    "${GENERATE_ARGS[@]}" --jq '.body' 2>/dev/null || true)"

BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
cp "$NOTES" "$BODY"
SUM="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
printf '\n\n**SHA-256** `%s`\n\nVerify with `shasum -a 256 Isla-%s.dmg`.\n' \
    "$SUM" "$VERSION" >> "$BODY"
[ -n "$GENERATED" ] && printf '\n\n---\n\n%s\n' "$GENERATED" >> "$BODY"

gh release create "$TAG" "$DMG" \
    --title "Isla $VERSION" \
    --notes-file "$BODY" \
    --latest
published=1
trap - ERR

gh release view "$TAG" --json url --jq '"==> released: " + .url'
